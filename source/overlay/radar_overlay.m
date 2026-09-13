/*
 * radar_overlay.m — SpringBoard tweak: live radar minimap & ESP overlay.
 *
 * Reads shared memory written by ue4loadmonitor daemon and renders:
 *  - Floating touchless HUD with compact expandable menu
 *  - High-precision circular radar minimap (with FOV cone, enemy facing yaw, HP rings)
 *  - Screen laser snaplines to visible enemies
 *  - 100% touch pass-through (only floating menu button intercepts touches)
 *
 * Compatible with Zig cross-compiler (-target aarch64-macos) using raw ObjC runtime.
 */

#include <stdio.h>
#include <stdbool.h>
#include <time.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include "../daemon/radar_data.h"

/* ------------------------------------------------------------------ */
/*  ObjC Runtime Definitions (no SDK headers needed)                  */
/* ------------------------------------------------------------------ */

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef void (*IMP)(void);
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef bool BOOL;

#define YES 1
#define NO  0
#define nil ((id)0)

extern Class objc_getClass(const char *name);
extern Class objc_allocateClassPair(Class superclass, const char *name, size_t extra);
extern void  objc_registerClassPair(Class cls);
extern BOOL  class_addMethod(Class cls, SEL sel, IMP imp, const char *types);
extern id    objc_msgSend(id self, SEL op, ...);
extern SEL   sel_registerName(const char *str);

/* Geometry */
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

_Static_assert(sizeof(CGRect) == 32, "ARM64 CGRect ABI");
_Static_assert(sizeof(CGPoint) == 16, "ARM64 CGPoint ABI");

static inline CGRect CGRectMake_f(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGRect r = {{x, y}, {w, h}};
    return r;
}

static inline BOOL in_rect(CGPoint p, CGRect r) {
    return p.x >= r.origin.x && p.y >= r.origin.y &&
           p.x < (r.origin.x + r.size.width) && p.y < (r.origin.y + r.size.height);
}

/* CoreGraphics */
typedef void *CGContextRef;
extern CGContextRef UIGraphicsGetCurrentContext(void);
extern void CGContextSetRGBFillColor(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a);
extern void CGContextSetRGBStrokeColor(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a);
extern void CGContextFillEllipseInRect(CGContextRef c, CGRect rect);
extern void CGContextStrokeEllipseInRect(CGContextRef c, CGRect rect);
extern void CGContextSetLineWidth(CGContextRef c, CGFloat w);
extern void CGContextMoveToPoint(CGContextRef c, CGFloat x, CGFloat y);
extern void CGContextAddLineToPoint(CGContextRef c, CGFloat x, CGFloat y);
extern void CGContextStrokePath(CGContextRef c);
extern void CGContextFillPath(CGContextRef c);
extern void CGContextAddArc(CGContextRef c, CGFloat x, CGFloat y, CGFloat radius,
                             CGFloat startAngle, CGFloat endAngle, int clockwise);
extern void CGContextClosePath(CGContextRef c);
extern void CGContextStrokeRect(CGContextRef c, CGRect rect);
extern void CGContextFillRect(CGContextRef c, CGRect rect);
extern void NSLog(id format, ...);

/* Helper: NSString */
static id nsstr(const char *s) {
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"), s);
}

/* ------------------------------------------------------------------ */
/*  Radar Configuration                                               */
/* ------------------------------------------------------------------ */

#define RADAR_SIZE       180.0f
#define RADAR_MARGIN     16.0f
#define RADAR_RANGE      20000.0f  /* 200m in UE units */
#define DOT_SIZE         6.0f
#define RING_WIDTH       2.0f

/* State */
static int             g_shm_fd     = -1;
static radar_shared_t *g_shared     = NULL;
static uint32_t        g_last_tick   = 0;
static radar_shared_t  g_snapshot;
static double          g_changed_at;
static uint32_t        g_draws       = 0;

/* UI Elements */
static id g_window          = nil;
static id g_radar_view      = nil;
static id g_line_view       = nil;
static id g_status_label    = nil;
static id g_menu_button     = nil;
static id g_radar_button    = nil;
static id g_lines_button    = nil;
static id g_range_button    = nil;

static BOOL g_menu_open     = NO;
static BOOL g_radar_on      = YES;
static BOOL g_lines_on      = NO;
static int  g_range_mode    = 1; /* 0=100m, 1=200m, 2=400m */

static CGRect g_btn_menu_rect;
static CGRect g_btn_radar_rect;
static CGRect g_btn_lines_rect;
static CGRect g_btn_range_rect;

static void set_hidden(id view, BOOL val) {
    if (view) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(view, sel_registerName("setHidden:"), val);
    }
}

static void set_title(id button, const char *text) {
    if (button) {
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
            button, sel_registerName("setTitle:forState:"), nsstr(text), 0);
    }
}

static double monotonic_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static float current_radar_range(void) {
    if (g_range_mode == 0) return 10000.0f; /* 100m */
    if (g_range_mode == 2) return 40000.0f; /* 400m */
    return 20000.0f; /* 200m default */
}

/* ------------------------------------------------------------------ */
/*  Shared Memory IPC                                                 */
/* ------------------------------------------------------------------ */

static BOOL open_shared_memory(void) {
    if (g_shared) return YES;

    g_shm_fd = open(RADAR_FILE_PATH, O_RDONLY);
    if (g_shm_fd < 0) return NO;

    struct stat st;
    if (fstat(g_shm_fd, &st) != 0 || st.st_size < (off_t)sizeof(radar_shared_t)) {
        close(g_shm_fd);
        g_shm_fd = -1;
        return NO;
    }

    g_shared = (radar_shared_t *)mmap(NULL, sizeof(radar_shared_t),
                                       PROT_READ, MAP_SHARED, g_shm_fd, 0);
    if (g_shared == MAP_FAILED) {
        g_shared = NULL;
        close(g_shm_fd);
        g_shm_fd = -1;
        return NO;
    }
    return YES;
}

static BOOL read_snapshot(void) {
    if (!g_shared) return NO;
    for (int retry = 0; retry < 3; retry++) {
        uint32_t seq = __atomic_load_n(&g_shared->header.sequence, __ATOMIC_ACQUIRE);
        if (seq & 1) continue;
        radar_shared_t candidate;
        memcpy(&candidate, g_shared, sizeof(candidate));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        if (seq != __atomic_load_n(&g_shared->header.sequence, __ATOMIC_ACQUIRE)) continue;
        if (candidate.header.magic != RADAR_MAGIC || candidate.header.version != RADAR_VERSION ||
            candidate.header.player_count > RADAR_MAX_PLAYERS) return NO;
        g_snapshot = candidate;
        return YES;
    }
    return NO;
}

/* ------------------------------------------------------------------ */
/*  Radar View Drawing                                                */
/* ------------------------------------------------------------------ */

static void radar_drawRect(id self, SEL _cmd, CGRect rect) {
    (void)self; (void)_cmd; (void)rect;
    if (!g_radar_on) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    g_draws++;

    float radius = RADAR_SIZE / 2.0f;
    float cx = radius, cy = radius;
    float range = current_radar_range();
    float scale = (radius - 10.0f) / range;

    /* Background Circle: Frosted Dark Disc */
    CGContextSetRGBFillColor(ctx, 0.04f, 0.07f, 0.12f, 0.75f);
    CGContextFillEllipseInRect(ctx, CGRectMake_f(0, 0, RADAR_SIZE, RADAR_SIZE));

    /* Outer Accent Ring (Glowing Cyan) */
    CGContextSetRGBStrokeColor(ctx, 0.0f, 0.85f, 1.0f, 0.65f);
    CGContextSetLineWidth(ctx, 1.5f);
    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(1.0f, 1.0f, RADAR_SIZE - 2.0f, RADAR_SIZE - 2.0f));

    /* Concentric Range Rings (50%, 100%) */
    CGContextSetRGBStrokeColor(ctx, 0.25f, 0.45f, 0.65f, 0.35f);
    CGContextSetLineWidth(ctx, 0.75f);
    float r1 = (radius - 10.0f) * 0.5f;
    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(cx - r1, cy - r1, r1 * 2, r1 * 2));
    float r2 = radius - 10.0f;
    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(cx - r2, cy - r2, r2 * 2, r2 * 2));

    /* Crosshairs */
    CGContextSetRGBStrokeColor(ctx, 0.25f, 0.45f, 0.65f, 0.25f);
    CGContextSetLineWidth(ctx, 0.5f);
    CGContextMoveToPoint(ctx, cx, 8.0f);
    CGContextAddLineToPoint(ctx, cx, RADAR_SIZE - 8.0f);
    CGContextMoveToPoint(ctx, 8.0f, cy);
    CGContextAddLineToPoint(ctx, RADAR_SIZE - 8.0f, cy);
    CGContextStrokePath(ctx);

    /* View Yaw & Rotation */
    float cam_yaw = g_snapshot.header.local_rot.y;
    float cam_yaw_rad = -cam_yaw * (float)M_PI / 180.0f;
    float cos_yaw = cosf(cam_yaw_rad);
    float sin_yaw = sinf(cam_yaw_rad);

    /* Rotating Compass N Indicator */
    float north_rad = cam_yaw * (float)M_PI / 180.0f;
    float nx = cx + sinf(north_rad) * (radius - 6.0f);
    float ny = cy - cosf(north_rad) * (radius - 6.0f);
    CGContextSetRGBFillColor(ctx, 1.0f, 0.25f, 0.25f, 0.9f); /* Red N pip */
    CGContextFillEllipseInRect(ctx, CGRectMake_f(nx - 2.5f, ny - 2.5f, 5.0f, 5.0f));

    /* View Cone (60° FOV Arc) */
    float fov = g_snapshot.header.camera_fov;
    if (!isfinite(fov) || fov < 10.0f || fov > 160.0f) fov = 80.0f;
    float cone_half = (fov * 0.5f) * (float)M_PI / 180.0f;
    float cone_len = radius - 12.0f;
    float cl_x = cx + sinf(-cone_half) * cone_len;
    float cl_y = cy - cosf(-cone_half) * cone_len;
    float cr_x = cx + sinf(cone_half) * cone_len;
    float cr_y = cy - cosf(cone_half) * cone_len;

    CGContextSetRGBFillColor(ctx, 0.0f, 0.85f, 1.0f, 0.08f);
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cl_x, cl_y);
    CGContextAddLineToPoint(ctx, cr_x, cr_y);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    CGContextSetRGBStrokeColor(ctx, 0.0f, 0.85f, 1.0f, 0.35f);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cl_x, cl_y);
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cr_x, cr_y);
    CGContextStrokePath(ctx);

    /* Local Player Indicator: Center Cyan Chevron */
    CGContextSetRGBFillColor(ctx, 0.0f, 0.95f, 1.0f, 1.0f);
    CGContextMoveToPoint(ctx, cx, cy - 6.0f);
    CGContextAddLineToPoint(ctx, cx + 4.5f, cy + 4.5f);
    CGContextAddLineToPoint(ctx, cx, cy + 2.0f);
    CGContextAddLineToPoint(ctx, cx - 4.5f, cy + 4.5f);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    /* Render Player Dots */
    BOOL fresh = (monotonic_seconds() - g_changed_at < 2.0);
    uint32_t count = (fresh && g_snapshot.header.status == 2) ? g_snapshot.header.player_count : 0;
    if (count > RADAR_MAX_PLAYERS) count = RADAR_MAX_PLAYERS;
    rvec3_t lp = g_snapshot.header.local_pos;

    for (uint32_t i = 0; i < count; i++) {
        const radar_player_t *p = &g_snapshot.players[i];
        if (p->health_status == 2) continue; /* Dead */
        if (p->health <= 0.0f && p->health_max > 0.0f) continue;

        /* World delta */
        float dx = p->pos.x - lp.x;
        float dy = p->pos.y - lp.y;

        /* Rotate relative to camera view */
        float rx = dx * cos_yaw - dy * sin_yaw;
        float ry = dx * sin_yaw + dy * cos_yaw;

        /* Screen projection (screen X is world Y, screen Y is -world X) */
        float sx = ry * scale;
        float sy = -rx * scale;

        /* Clamp to radar circle */
        float max_r = radius - DOT_SIZE - 3.0f;
        float dist = sqrtf(sx * sx + sy * sy);
        BOOL is_clamped = NO;
        if (dist > max_r) {
            float c = max_r / dist;
            sx *= c;
            sy *= c;
            is_clamped = YES;
        }

        float dotx = cx + sx;
        float doty = cy + sy;

        /* Player Dot & Color */
        if (p->health_status == 1) {
            /* Knocked = Vibrant Orange */
            CGContextSetRGBFillColor(ctx, 1.0f, 0.65f, 0.0f, 1.0f);
        } else {
            /* Alive = Vivid Red */
            CGContextSetRGBFillColor(ctx, 1.0f, 0.2f, 0.25f, 1.0f);
        }

        if (is_clamped) {
            /* Clamped pointer (small diamond/arrow) */
            CGContextFillEllipseInRect(ctx, CGRectMake_f(dotx - 2.5f, doty - 2.5f, 5.0f, 5.0f));
        } else {
            /* Full Player Dot */
            CGContextFillEllipseInRect(ctx, CGRectMake_f(dotx - DOT_SIZE * 0.5f,
                                                         doty - DOT_SIZE * 0.5f,
                                                         DOT_SIZE, DOT_SIZE));

            /* Health Ring Arc around dot */
            if (p->health_max > 0.0f) {
                float hp_ratio = p->health / p->health_max;
                if (hp_ratio > 1.0f) hp_ratio = 1.0f;
                if (hp_ratio < 0.0f) hp_ratio = 0.0f;

                /* Color based on health */
                if (hp_ratio > 0.6f) {
                    CGContextSetRGBStrokeColor(ctx, 0.2f, 0.95f, 0.3f, 0.85f); /* Green */
                } else if (hp_ratio > 0.25f) {
                    CGContextSetRGBStrokeColor(ctx, 1.0f, 0.75f, 0.1f, 0.85f); /* Yellow */
                } else {
                    CGContextSetRGBStrokeColor(ctx, 1.0f, 0.15f, 0.15f, 0.9f); /* Red */
                }

                CGContextSetLineWidth(ctx, RING_WIDTH);
                float ring_r = DOT_SIZE * 0.5f + 2.0f;
                CGFloat start = -(float)M_PI * 0.5f;
                CGFloat end = start + hp_ratio * 2.0f * (float)M_PI;
                CGContextAddArc(ctx, dotx, doty, ring_r, start, end, 0);
                CGContextStrokePath(ctx);
            }

            /* Enemy Facing Direction Pip */
            float enemy_rel_yaw = (p->yaw - cam_yaw) * (float)M_PI / 180.0f;
            float px = dotx + sinf(enemy_rel_yaw) * 7.0f;
            float py = doty - cosf(enemy_rel_yaw) * 7.0f;
            CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.75f);
            CGContextSetLineWidth(ctx, 1.0f);
            CGContextMoveToPoint(ctx, dotx, doty);
            CGContextAddLineToPoint(ctx, px, py);
            CGContextStrokePath(ctx);
        }
    }
}

/* ------------------------------------------------------------------ */
/*  Player Laser Snaplines (Screen Projection ESP)                    */
/* ------------------------------------------------------------------ */

static void lines_draw(id self, SEL cmd, CGRect dirty) {
    (void)cmd; (void)dirty;
    if (!g_lines_on || !g_snapshot.header.camera_valid || g_snapshot.header.status != 2 ||
        monotonic_seconds() - g_changed_at > 2.0) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("bounds"));
    double w = bounds.size.width, h = bounds.size.height;
    if (w <= 0 || h <= 0) return;

    rvec3_t rot = g_snapshot.header.local_rot;
    rvec3_t cam = g_snapshot.header.camera_pos;
    double pitch = rot.x * M_PI / 180.0;
    double yaw   = rot.y * M_PI / 180.0;
    double roll  = rot.z * M_PI / 180.0;

    double cp = cos(pitch), sp = sin(pitch);
    double cy = cos(yaw),   sy = sin(yaw);
    double cr = cos(roll),  sr = sin(roll);

    double fov = g_snapshot.header.camera_fov;
    if (!isfinite(fov) || fov <= 10.0 || fov >= 180.0) return;
    double focal = w / (2.0 * tan(fov * M_PI / 360.0));

    CGContextSetLineWidth(ctx, 1.2f);

    uint32_t count = g_snapshot.header.player_count;
    if (count > RADAR_MAX_PLAYERS) count = RADAR_MAX_PLAYERS;

    for (uint32_t i = 0; i < count; i++) {
        const radar_player_t *p = &g_snapshot.players[i];
        if (p->health_status == 2) continue;

        double dx = p->pos.x - cam.x;
        double dy = p->pos.y - cam.y;
        double dz = p->pos.z - cam.z;

        double depth = dx * cp * cy + dy * cp * sy + dz * sp;
        if (depth <= 1.0) continue; /* Behind camera */

        double right = dx * (sr * sp * cy - cr * sy) + dy * (sr * sp * sy + cr * cy) - dz * sr * cp;
        double up    = dx * (-cr * sp * cy - sr * sy) + dy * (-cr * sp * sy + sr * cy) + dz * cr * cp;

        double x = w * 0.5 + (right * focal / depth);
        double y = h * 0.5 - (up * focal / depth);

        if (!isfinite(x) || !isfinite(y) || x < -50.0 || x > w + 50.0 || y < -50.0 || y > h + 50.0) continue;

        /* Snapline from bottom center of screen to enemy */
        if (p->health_status == 1) {
            CGContextSetRGBStrokeColor(ctx, 1.0f, 0.65f, 0.0f, 0.75f); /* Orange for knocked */
        } else {
            CGContextSetRGBStrokeColor(ctx, 0.0f, 0.9f, 1.0f, 0.75f);  /* Cyan for alive */
        }

        CGContextMoveToPoint(ctx, w * 0.5, h);
        CGContextAddLineToPoint(ctx, x, y);
        CGContextStrokePath(ctx);

        /* Small box target at enemy location */
        CGContextStrokeRect(ctx, CGRectMake_f(x - 4.0f, y - 4.0f, 8.0f, 8.0f));
    }
}

/* ------------------------------------------------------------------ */
/*  Touch Handling: 100% Pass-Through Except Floating Buttons         */
/* ------------------------------------------------------------------ */

static id window_hitTest(id self, SEL cmd, CGPoint point, id event) {
    (void)cmd; (void)event;
    /* 1. Check Menu Toggle Button */
    if (g_menu_button && !((BOOL (*)(id, SEL))objc_msgSend)(g_menu_button, sel_registerName("isHidden"))) {
        if (in_rect(point, g_btn_menu_rect)) return g_menu_button;
    }
    /* 2. Check Expanded Menu Buttons */
    if (g_menu_open) {
        if (g_radar_button && !((BOOL (*)(id, SEL))objc_msgSend)(g_radar_button, sel_registerName("isHidden"))) {
            if (in_rect(point, g_btn_radar_rect)) return g_radar_button;
        }
        if (g_lines_button && !((BOOL (*)(id, SEL))objc_msgSend)(g_lines_button, sel_registerName("isHidden"))) {
            if (in_rect(point, g_btn_lines_rect)) return g_lines_button;
        }
        if (g_range_button && !((BOOL (*)(id, SEL))objc_msgSend)(g_range_button, sel_registerName("isHidden"))) {
            if (in_rect(point, g_btn_range_rect)) return g_range_button;
        }
    }
    /* EVERYTHING ELSE IS UNTOUCHABLE -> 100% PASS-THROUGH TO GAME */
    return nil;
}

static BOOL window_pointInside(id self, SEL cmd, CGPoint point, id event) {
    return window_hitTest(self, cmd, point, event) != nil;
}

/* ------------------------------------------------------------------ */
/*  Menu Button Actions                                               */
/* ------------------------------------------------------------------ */

static void update_menu_ui(void) {
    set_hidden(g_radar_button, !g_menu_open);
    set_hidden(g_lines_button, !g_menu_open);
    set_hidden(g_range_button, !g_menu_open);

    set_title(g_menu_button, g_menu_open ? "✕ Close" : "⚡ Radar");
    set_title(g_radar_button, g_radar_on ? "Radar: ON" : "Radar: OFF");
    set_title(g_lines_button, g_lines_on ? "Lines ESP: ON" : "Lines ESP: OFF");

    const char *range_str = (g_range_mode == 0) ? "Range: 100m" :
                            (g_range_mode == 2) ? "Range: 400m" : "Range: 200m";
    set_title(g_range_button, range_str);
}

static void menu_action(id self, SEL cmd, id sender) {
    (void)self; (void)cmd;
    if (sender == g_menu_button) {
        g_menu_open = !g_menu_open;
    } else if (sender == g_radar_button) {
        g_radar_on = !g_radar_on;
    } else if (sender == g_lines_button) {
        g_lines_on = !g_lines_on;
    } else if (sender == g_range_button) {
        g_range_mode = (g_range_mode + 1) % 3;
    }
    update_menu_ui();
}

/* Helper to construct stylized buttons */
static id make_button(id target, CGRect frame, const char *text) {
    id button = ((id (*)(id, SEL, NSInteger))objc_msgSend)(
        (id)objc_getClass("UIButton"), sel_registerName("buttonWithType:"), 1);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(button, sel_registerName("setFrame:"), frame);

    id color = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)objc_getClass("UIColor"), sel_registerName("colorWithRed:green:blue:alpha:"),
        0.06, 0.10, 0.18, 0.88);
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setBackgroundColor:"), color);

    /* Rounded pill border */
    id layer = ((id (*)(id, SEL))objc_msgSend)(button, sel_registerName("layer"));
    if (layer) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel_registerName("setCornerRadius:"), 8.0);
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel_registerName("setBorderWidth:"), 1.0);
        id border_color = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)objc_getClass("UIColor"), sel_registerName("colorWithRed:green:blue:alpha:"),
            0.0, 0.75, 1.0, 0.45);
        id cg_color = ((id (*)(id, SEL))objc_msgSend)(border_color, sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setBorderColor:"), cg_color);
    }

    set_title(button, text);
    ((void (*)(id, SEL, id, SEL, NSUInteger))objc_msgSend)(
        button, sel_registerName("addTarget:action:forControlEvents:"), target, sel_registerName("menuAction:"), 64);

    id title_label = ((id (*)(id, SEL))objc_msgSend)(button, sel_registerName("titleLabel"));
    if (title_label) {
        id font = ((id (*)(id, SEL, double))objc_msgSend)(
            (id)objc_getClass("UIFont"), sel_registerName("boldSystemFontOfSize:"), 12.0);
        ((void (*)(id, SEL, id))objc_msgSend)(title_label, sel_registerName("setFont:"), font);
    }

    ((void (*)(id, SEL, id))objc_msgSend)(g_window, sel_registerName("addSubview:"), button);
    return button;
}

/* ------------------------------------------------------------------ */
/*  Timer Refresh (CADisplayLink / NSTimer at ~30 FPS)                */
/* ------------------------------------------------------------------ */

static int g_frame_counter = 0;

static void timer_tick(id self, SEL _cmd, id timer) {
    (void)self; (void)_cmd; (void)timer;
    g_frame_counter++;

    /* Rapid Shared Memory Connection */
    if (!g_shared) {
        if (g_frame_counter % 5 == 1) {
            open_shared_memory();
        }
    }

    /* Ingest IPC snapshot */
    if (g_shared && read_snapshot()) {
        if (g_snapshot.header.tick != g_last_tick) {
            g_last_tick = g_snapshot.header.tick;
            g_changed_at = monotonic_seconds();
        }
    }

    /* Update dynamic layout */
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("bounds"));
    if (bounds.size.width > 0 && bounds.size.height > 0) {
        double rx = fmax(8.0, bounds.size.width - RADAR_SIZE - RADAR_MARGIN);
        double ry = 48.0;

        /* Layout Frames */
        g_btn_menu_rect  = CGRectMake_f(rx, 8.0, RADAR_SIZE, 32.0);
        g_btn_radar_rect = CGRectMake_f(rx, 44.0, RADAR_SIZE, 34.0);
        g_btn_lines_rect = CGRectMake_f(rx, 80.0, RADAR_SIZE, 34.0);
        g_btn_range_rect = CGRectMake_f(rx, 116.0, RADAR_SIZE, 34.0);

        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_menu_button, sel_registerName("setFrame:"), g_btn_menu_rect);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_radar_button, sel_registerName("setFrame:"), g_btn_radar_rect);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_lines_button, sel_registerName("setFrame:"), g_btn_lines_rect);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_range_button, sel_registerName("setFrame:"), g_btn_range_rect);

        double radar_top = g_menu_open ? 154.0 : ry;
        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_radar_view, sel_registerName("setFrame:"),
            CGRectMake_f(rx, radar_top, RADAR_SIZE, RADAR_SIZE));
        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_status_label, sel_registerName("setFrame:"),
            CGRectMake_f(rx, radar_top + RADAR_SIZE + 2.0, RADAR_SIZE, 22.0));

        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_line_view, sel_registerName("setFrame:"), bounds);
    }

    /* Redraw views */
    if (g_radar_view) ((void (*)(id, SEL))objc_msgSend)(g_radar_view, sel_registerName("setNeedsDisplay"));
    if (g_line_view)  ((void (*)(id, SEL))objc_msgSend)(g_line_view, sel_registerName("setNeedsDisplay"));

    /* Update Status Badge (every 10 frames) */
    if (g_frame_counter % 10 == 1 && g_status_label) {
        BOOL fresh = (monotonic_seconds() - g_changed_at < 2.0);
        char label[96];
        if (!fresh) {
            snprintf(label, sizeof(label), "○ Offline");
        } else if (g_snapshot.header.status == 2) {
            snprintf(label, sizeof(label), "● Live  |  %u Enemies", g_snapshot.header.player_count);
        } else if (g_snapshot.header.status == 3) {
            snprintf(label, sizeof(label), "◌ In Lobby...");
        } else {
            snprintf(label, sizeof(label), "◌ Connecting...");
        }
        ((void (*)(id, SEL, id))objc_msgSend)(g_status_label, sel_registerName("setText:"), nsstr(label));
    }
}

/* ------------------------------------------------------------------ */
/*  Overlay Initialization                                            */
/* ------------------------------------------------------------------ */

static void init_overlay(void) {
    if (g_window) return;

    Class UIWindow_cls  = objc_getClass("UIWindow");
    Class UIView_cls    = objc_getClass("UIView");
    Class UIScreen_cls  = objc_getClass("UIScreen");
    Class UIColor_cls   = objc_getClass("UIColor");
    Class UIApp_cls     = objc_getClass("UIApplication");
    Class UIWindowScene = objc_getClass("UIWindowScene");
    Class NSTimer_cls   = objc_getClass("NSTimer");
    Class NSRunLoop_cls = objc_getClass("NSRunLoop");

    /* 1. Register Custom Touchless Window */
    Class RadarWindow = objc_allocateClassPair(UIWindow_cls, "AntigravityRadarWindow", 0);
    if (!RadarWindow) {
        RadarWindow = objc_getClass("AntigravityRadarWindow");
    } else {
        class_addMethod(RadarWindow, sel_registerName("hitTest:withEvent:"),
                        (IMP)window_hitTest, "@@:{CGPoint=dd}@");
        class_addMethod(RadarWindow, sel_registerName("pointInside:withEvent:"),
                        (IMP)window_pointInside, "B@:{CGPoint=dd}@");
        objc_registerClassPair(RadarWindow);
    }

    /* 2. Register Custom Views */
    Class RadarView = objc_allocateClassPair(UIView_cls, "AntigravityRadarHUD", 0);
    if (!RadarView) {
        RadarView = objc_getClass("AntigravityRadarHUD");
    } else {
        class_addMethod(RadarView, sel_registerName("drawRect:"),
                        (IMP)radar_drawRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        objc_registerClassPair(RadarView);
    }

    Class LineView = objc_allocateClassPair(UIView_cls, "AntigravityRadarLines", 0);
    if (!LineView) {
        LineView = objc_getClass("AntigravityRadarLines");
    } else {
        class_addMethod(LineView, sel_registerName("drawRect:"),
                        (IMP)lines_draw, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        objc_registerClassPair(LineView);
    }

    /* 3. Screen Bounds & Window Creation */
    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)UIScreen_cls, sel_registerName("mainScreen"));
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));

    id window = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)RadarWindow, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), bounds);
    g_window = window;

    /* Window Properties */
    ((void (*)(id, SEL, double))objc_msgSend)(window, sel_registerName("setWindowLevel:"), 10000001.0);

    id clearColor = ((id (*)(id, SEL))objc_msgSend)((id)UIColor_cls, sel_registerName("clearColor"));
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setUserInteractionEnabled:"), YES);

    /* 4. Scene Attachment */
    id app = ((id (*)(id, SEL))objc_msgSend)((id)UIApp_cls, sel_registerName("sharedApplication"));
    id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
    id sceneEnum = ((id (*)(id, SEL))objc_msgSend)(scenes, sel_registerName("objectEnumerator"));
    id scene;
    while ((scene = ((id (*)(id, SEL))objc_msgSend)(sceneEnum, sel_registerName("nextObject")))) {
        BOOL isWindowScene = (BOOL)(NSInteger)((id (*)(id, SEL, id))objc_msgSend)(
            scene, sel_registerName("isKindOfClass:"), UIWindowScene);
        if (isWindowScene) {
            ((id (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("setWindowScene:"), scene);
            break;
        }
    }

    /* 5. Subviews Setup (All untargeted subviews set to userInteractionEnabled: NO) */
    id lineView = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)LineView, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), bounds);
    ((void (*)(id, SEL, id))objc_msgSend)(lineView, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(lineView, sel_registerName("setOpaque:"), NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(lineView, sel_registerName("setUserInteractionEnabled:"), NO);
    g_line_view = lineView;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), lineView);

    double rx = fmax(8.0, bounds.size.width - RADAR_SIZE - RADAR_MARGIN);
    id radarView = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)RadarView, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(rx, 48.0, RADAR_SIZE, RADAR_SIZE));
    ((void (*)(id, SEL, id))objc_msgSend)(radarView, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(radarView, sel_registerName("setOpaque:"), NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(radarView, sel_registerName("setUserInteractionEnabled:"), NO);
    g_radar_view = radarView;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), radarView);

    /* Status Label */
    id statusLabel = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UILabel"), sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(rx, 48.0 + RADAR_SIZE + 2.0, RADAR_SIZE, 22.0));
    id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)UIColor_cls, sel_registerName("whiteColor"));
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, sel_registerName("setTextColor:"), whiteColor);
    id font = ((id (*)(id, SEL, double))objc_msgSend)((id)objc_getClass("UIFont"), sel_registerName("systemFontOfSize:"), 11.0);
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, sel_registerName("setFont:"), font);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(statusLabel, sel_registerName("setTextAlignment:"), 1); /* NSTextAlignmentCenter */
    ((void (*)(id, SEL, BOOL))objc_msgSend)(statusLabel, sel_registerName("setUserInteractionEnabled:"), NO);
    g_status_label = statusLabel;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), statusLabel);

    /* 6. Buttons & Menu Controller Helper */
    Class MenuHelper = objc_allocateClassPair(objc_getClass("NSObject"), "AntigravityRadarMenuHelper", 0);
    if (!MenuHelper) {
        MenuHelper = objc_getClass("AntigravityRadarMenuHelper");
    } else {
        class_addMethod(MenuHelper, sel_registerName("menuAction:"), (IMP)menu_action, "v@:@");
        class_addMethod(MenuHelper, sel_registerName("tick:"), (IMP)timer_tick, "v@:@");
        objc_registerClassPair(MenuHelper);
    }
    id helper = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)MenuHelper, sel_registerName("alloc")), sel_registerName("init"));

    g_btn_menu_rect  = CGRectMake_f(rx, 8.0, RADAR_SIZE, 32.0);
    g_btn_radar_rect = CGRectMake_f(rx, 44.0, RADAR_SIZE, 34.0);
    g_btn_lines_rect = CGRectMake_f(rx, 80.0, RADAR_SIZE, 34.0);
    g_btn_range_rect = CGRectMake_f(rx, 116.0, RADAR_SIZE, 34.0);

    g_menu_button  = make_button(helper, g_btn_menu_rect, "⚡ Radar");
    g_radar_button = make_button(helper, g_btn_radar_rect, "Radar: ON");
    g_lines_button = make_button(helper, g_btn_lines_rect, "Lines ESP: OFF");
    g_range_button = make_button(helper, g_btn_range_rect, "Range: 200m");

    set_hidden(g_radar_button, YES);
    set_hidden(g_lines_button, YES);
    set_hidden(g_range_button, YES);

    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setHidden:"), NO);
    ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("makeKeyAndVisible"));

    /* 7. Start Refresh Timer at 30 FPS */
    typedef id (*timer_fn)(id, SEL, double, id, SEL, id, BOOL);
    id timer = ((timer_fn)objc_msgSend)(
        (id)NSTimer_cls,
        sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        0.033, helper, sel_registerName("tick:"), nil, YES);

    id runloop = ((id (*)(id, SEL))objc_msgSend)((id)NSRunLoop_cls, sel_registerName("currentRunLoop"));
    id mode = nsstr("kCFRunLoopCommonModes");
    ((void (*)(id, SEL, id, id))objc_msgSend)(runloop, sel_registerName("addTimer:forMode:"), timer, mode);

    open_shared_memory();
    NSLog(nsstr("%@"), nsstr("[Radar] Overlay initialized with touch pass-through"));
}

/* ------------------------------------------------------------------ */
/*  Entry Point                                                       */
/* ------------------------------------------------------------------ */

static void deferred_init(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    init_overlay();
}

__attribute__((constructor))
static void tweak_entry(void) {
    Class Helper = objc_allocateClassPair(objc_getClass("NSObject"), "AntigravityRadarInitHelper", 0);
    if (!Helper) {
        Helper = objc_getClass("AntigravityRadarInitHelper");
    } else {
        class_addMethod(Helper, sel_registerName("deferredInit"), (IMP)deferred_init, "v@:");
        objc_registerClassPair(Helper);
    }
    id helper = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)Helper, sel_registerName("alloc")), sel_registerName("init"));
    ((void (*)(id, SEL, SEL, id, BOOL))objc_msgSend)(
        helper, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
        sel_registerName("deferredInit"), nil, NO);
}
