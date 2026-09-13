/*
 * radar_overlay.m — SpringBoard tweak: live radar HUD & snaplines.
 *
 * Reads shared memory written by ue4loadmonitor daemon and renders:
 *  - 100% Touch Pass-Through (window is completely untouchable)
 *  - Fullscreen laser snaplines to visible enemies
 *  - High-precision circular radar minimap (with view cone, health rings, enemy dots)
 *  - Dynamic orientation adaptation for Landscape and Portrait
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
/*  ObjC Runtime Definitions (no Apple SDK headers needed)            */
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
extern void CGContextClosePath(CGContextRef c);
extern void CGContextAddArc(CGContextRef c, CGFloat x, CGFloat y, CGFloat radius,
                             CGFloat startAngle, CGFloat endAngle, int clockwise);
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

static double monotonic_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
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
/*  Radar Minimap Drawing                                             */
/* ------------------------------------------------------------------ */

static void radar_drawRect(id self, SEL _cmd, CGRect rect) {
    (void)self; (void)_cmd; (void)rect;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    g_draws++;

    float radius = RADAR_SIZE / 2.0f;
    float cx = radius, cy = radius;
    float scale = (radius - 8.0f) / RADAR_RANGE;

    /* Background Circle: Translucent Dark Disc */
    CGContextSetRGBFillColor(ctx, 0.04f, 0.07f, 0.12f, 0.72f);
    CGContextFillEllipseInRect(ctx, CGRectMake_f(0, 0, RADAR_SIZE, RADAR_SIZE));

    /* Outer Neon Accent Ring */
    CGContextSetRGBStrokeColor(ctx, 0.0f, 0.85f, 1.0f, 0.65f);
    CGContextSetLineWidth(ctx, 1.5f);
    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(1.0f, 1.0f, RADAR_SIZE - 2.0f, RADAR_SIZE - 2.0f));

    /* Concentric Range Rings (50%, 100%) */
    CGContextSetRGBStrokeColor(ctx, 0.3f, 0.5f, 0.7f, 0.35f);
    CGContextSetLineWidth(ctx, 0.75f);
    float r1 = (radius - 8.0f) * 0.5f;
    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(cx - r1, cy - r1, r1 * 2, r1 * 2));
    float r2 = radius - 8.0f;
    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(cx - r2, cy - r2, r2 * 2, r2 * 2));

    /* Crosshairs */
    CGContextSetRGBStrokeColor(ctx, 0.3f, 0.5f, 0.7f, 0.25f);
    CGContextSetLineWidth(ctx, 0.5f);
    CGContextMoveToPoint(ctx, cx, 6.0f);
    CGContextAddLineToPoint(ctx, cx, RADAR_SIZE - 6.0f);
    CGContextMoveToPoint(ctx, 6.0f, cy);
    CGContextAddLineToPoint(ctx, RADAR_SIZE - 6.0f, cy);
    CGContextStrokePath(ctx);

    /* View Yaw & Rotation */
    float cam_yaw = g_snapshot.header.local_rot.y;
    float cam_yaw_rad = -cam_yaw * (float)M_PI / 180.0f;
    float cos_yaw = cosf(cam_yaw_rad);
    float sin_yaw = sinf(cam_yaw_rad);

    /* View Cone (60° FOV Arc) */
    float fov = g_snapshot.header.camera_fov;
    if (!isfinite(fov) || fov < 10.0f || fov > 160.0f) fov = 80.0f;
    float cone_half = (fov * 0.5f) * (float)M_PI / 180.0f;
    float cone_len = radius - 10.0f;
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

    /* Local Player Indicator: Center Cyan Chevron (pointing UP) */
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

        /* Rotate relative to camera view:
         * rx = Forward distance in UE
         * ry = Right distance in UE
         */
        float rx = dx * cos_yaw - dy * sin_yaw;
        float ry = dx * sin_yaw + dy * cos_yaw;

        /* Screen projection:
         * Right is +X on screen (ry * scale)
         * Forward is -Y / UP on screen (-rx * scale)
         */
        float sx = ry * scale;
        float sy = -rx * scale;

        /* Clamp to radar circle */
        float max_r = radius - DOT_SIZE - 2.0f;
        float dist = sqrtf(sx * sx + sy * sy);
        if (dist > max_r) {
            float c = max_r / dist;
            sx *= c;
            sy *= c;
        }

        float dotx = cx + sx;
        float doty = cy + sy;

        /* Player Dot Color: Knocked = Orange, Alive = Red */
        if (p->health_status == 1) {
            CGContextSetRGBFillColor(ctx, 1.0f, 0.65f, 0.0f, 1.0f);
        } else {
            CGContextSetRGBFillColor(ctx, 1.0f, 0.2f, 0.25f, 1.0f);
        }

        /* Player Dot */
        CGContextFillEllipseInRect(ctx, CGRectMake_f(dotx - DOT_SIZE * 0.5f,
                                                     doty - DOT_SIZE * 0.5f,
                                                     DOT_SIZE, DOT_SIZE));

        /* Health Ring Arc around dot */
        if (p->health_max > 0.0f) {
            float hp_ratio = p->health / p->health_max;
            if (hp_ratio > 1.0f) hp_ratio = 1.0f;
            if (hp_ratio < 0.0f) hp_ratio = 0.0f;

            if (hp_ratio > 0.5f) {
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
    }
}

/* ------------------------------------------------------------------ */
/*  Player Laser Snaplines (Screen Projection ESP)                    */
/* ------------------------------------------------------------------ */

static void lines_draw(id self, SEL cmd, CGRect dirty) {
    (void)cmd; (void)dirty;
    if (!g_snapshot.header.camera_valid || g_snapshot.header.status != 2 ||
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

    CGContextSetLineWidth(ctx, 1.5f);

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

        if (!isfinite(x) || !isfinite(y) || x < 0 || x > w || y < 0 || y > h) continue;

        /* Snapline from bottom center of screen to enemy position */
        if (p->health_status == 1) {
            CGContextSetRGBStrokeColor(ctx, 1.0f, 0.65f, 0.0f, 0.85f); /* Orange for knocked */
        } else {
            CGContextSetRGBStrokeColor(ctx, 0.0f, 0.9f, 1.0f, 0.85f);  /* Cyan for alive */
        }

        CGContextMoveToPoint(ctx, w * 0.5, h);
        CGContextAddLineToPoint(ctx, x, y);
        CGContextStrokePath(ctx);

        /* Small target circle at projected enemy position */
        CGContextSetRGBFillColor(ctx, 1.0f, 0.2f, 0.25f, 0.9f);
        CGContextFillEllipseInRect(ctx, CGRectMake_f(x - 3.5f, y - 3.5f, 7.0f, 7.0f));
    }
}

/* ------------------------------------------------------------------ */
/*  Touch Handling: 100% Pass-Through Unconditionally                 */
/* ------------------------------------------------------------------ */

static BOOL window_pointInside(id self, SEL cmd, CGPoint point, id event) {
    (void)self; (void)cmd; (void)point; (void)event;
    /* 100% UNTOUCHABLE: Passes all touches directly to the underlying game/SpringBoard */
    return NO;
}

/* ------------------------------------------------------------------ */
/*  Timer Refresh (at ~30 FPS)                                        */
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

    /* Dynamic orientation layout adaptation */
    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));
    if (bounds.size.width > 0 && bounds.size.height > 0) {
        double w = bounds.size.width;
        double h = bounds.size.height;

        /* Adapt radar position for Landscape vs Portrait */
        double rx = w - RADAR_SIZE - 20.0;
        double ry = (w > h) ? 16.0 : 48.0;

        if (g_line_view) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(g_line_view, sel_registerName("setFrame:"), CGRectMake_f(0, 0, w, h));
            ((void (*)(id, SEL))objc_msgSend)(g_line_view, sel_registerName("setNeedsDisplay"));
        }

        if (g_radar_view) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(g_radar_view, sel_registerName("setFrame:"), CGRectMake_f(rx, ry, RADAR_SIZE, RADAR_SIZE));
            ((void (*)(id, SEL))objc_msgSend)(g_radar_view, sel_registerName("setNeedsDisplay"));
        }

        if (g_status_label) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(g_status_label, sel_registerName("setFrame:"),
                CGRectMake_f(rx, ry + RADAR_SIZE + 2.0, RADAR_SIZE, 20.0));
        }
    }

    /* Update Status Badge */
    if (g_frame_counter % 10 == 1 && g_status_label) {
        BOOL fresh = (monotonic_seconds() - g_changed_at < 2.0);
        char label[96];
        if (!fresh) {
            snprintf(label, sizeof(label), "Radar | Standby");
        } else if (g_snapshot.header.status == 2) {
            snprintf(label, sizeof(label), "Radar | Live | %u", g_snapshot.header.player_count);
        } else if (g_snapshot.header.status == 3) {
            snprintf(label, sizeof(label), "Radar | In Lobby");
        } else {
            snprintf(label, sizeof(label), "Radar | Connecting...");
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

    /* Window Properties: Level 10000001, Clear, Touch Pass-Through */
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

    double rx = bounds.size.width - RADAR_SIZE - 20.0;
    id radarView = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)RadarView, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(rx, 20.0, RADAR_SIZE, RADAR_SIZE));
    ((void (*)(id, SEL, id))objc_msgSend)(radarView, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(radarView, sel_registerName("setOpaque:"), NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(radarView, sel_registerName("setUserInteractionEnabled:"), NO);
    g_radar_view = radarView;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), radarView);

    /* Status Label */
    id statusLabel = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UILabel"), sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(rx, 20.0 + RADAR_SIZE + 2.0, RADAR_SIZE, 20.0));
    id whiteColor = ((id (*)(id, SEL))objc_msgSend)((id)UIColor_cls, sel_registerName("whiteColor"));
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, sel_registerName("setTextColor:"), whiteColor);
    id font = ((id (*)(id, SEL, double))objc_msgSend)((id)objc_getClass("UIFont"), sel_registerName("boldSystemFontOfSize:"), 12.0);
    ((void (*)(id, SEL, id))objc_msgSend)(statusLabel, sel_registerName("setFont:"), font);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(statusLabel, sel_registerName("setTextAlignment:"), 1); /* NSTextAlignmentCenter */
    ((void (*)(id, SEL, BOOL))objc_msgSend)(statusLabel, sel_registerName("setUserInteractionEnabled:"), NO);
    g_status_label = statusLabel;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), statusLabel);

    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setHidden:"), NO);
    ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("makeKeyAndVisible"));

    /* 6. Helper for Refresh Timer */
    Class HelperClass = objc_allocateClassPair(objc_getClass("NSObject"), "AntigravityRadarTimerHelper", 0);
    if (!HelperClass) {
        HelperClass = objc_getClass("AntigravityRadarTimerHelper");
    } else {
        class_addMethod(HelperClass, sel_registerName("tick:"), (IMP)timer_tick, "v@:@");
        objc_registerClassPair(HelperClass);
    }
    id helper = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)HelperClass, sel_registerName("alloc")), sel_registerName("init"));

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
    NSLog(nsstr("%@"), nsstr("[Radar] Overlay initialized with 100% touch pass-through"));
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
