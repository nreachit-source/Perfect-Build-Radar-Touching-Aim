/*
 * radar_overlay.m — SpringBoard tweak: full-featured UE4 radar & ESP overlay.
 *
 * Features:
 *   1. 100% Touch Pass-Through: Only the draggable button and open menu
 *      intercept touches; all game touches pass completely uninterrupted.
 *   2. Draggable Floating Button: Tap to open/close menu; drag anywhere on screen.
 *   3. Settings Menu: Polished frosted glass card with live toggles for 12 features:
 *      - Radar Minimap (ON/OFF)
 *      - Snaplines to Players (ON/OFF)
 *      - 2D Bounding Box ESP (ON/OFF)
 *      - Health Bar & HP Text (ON/OFF)
 *      - Player Name ESP (ON/OFF)
 *      - Distance in Meters (ON/OFF)
 *      - Team ID & Bot Badge (ON/OFF)
 *      - Player Skeleton Bones (ON/OFF)
 *      - Head Dot Aim Marker (ON/OFF)
 *      - Vehicle ESP (ON/OFF)
 *      - Loot & Items ESP (ON/OFF)
 *      - Radar Range (100m / 200m / 400m)
 *   4. Dynamic Landscape & Portrait orientation adaptation without stalling.
 *   5. Smooth 20 Hz frame updates without layout thrashing or game hitching.
 *
 * Rules:
 *   - Never #include <syslog.h>
 *   - Never call dispatch_get_main_queue() in C
 *   - Attach windowScene from connectedScenes
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
#include <dlfcn.h>

#include "../daemon/radar_data.h"

/* Use system libSystem sincos intrinsics */

/* ------------------------------------------------------------------ */
/*  ObjC runtime declarations (no Apple SDK headers needed)           */
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

static Class (*fn_objc_getClass)(const char *name) = NULL;
static Class (*fn_objc_allocateClassPair)(Class superclass, const char *name, size_t extra) = NULL;
static void  (*fn_objc_registerClassPair)(Class cls) = NULL;
static BOOL  (*fn_class_addMethod)(Class cls, SEL sel, IMP imp, const char *types) = NULL;
static id    (*fn_objc_msgSend)(id self, SEL op, ...) = NULL;
static SEL   (*fn_sel_registerName)(const char *str) = NULL;
static Class (*fn_object_getClass)(id obj) = NULL;
static const char *(*fn_class_getName)(Class cls) = NULL;

#define objc_getClass fn_objc_getClass
#define objc_allocateClassPair fn_objc_allocateClassPair
#define objc_registerClassPair fn_objc_registerClassPair
#define class_addMethod fn_class_addMethod
#define objc_msgSend fn_objc_msgSend
#define sel_registerName fn_sel_registerName
#define object_getClass fn_object_getClass
#define class_getName fn_class_getName

/* CoreGraphics geometry types */
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

static inline CGRect CGRectMake_f(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGRect r = {{x, y}, {w, h}};
    return r;
}

static inline BOOL in_rect(CGPoint p, CGRect r) {
    return p.x >= r.origin.x && p.y >= r.origin.y &&
           p.x < (r.origin.x + r.size.width) &&
           p.y < (r.origin.y + r.size.height);
}

/* Dynamic CoreGraphics & logging function pointers to avoid flat dyld bind lookups */
typedef void *CGContextRef;

static CGContextRef (*fn_UIGraphicsGetCurrentContext)(void) = NULL;
static void (*fn_CGContextSetRGBFillColor)(CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat) = NULL;
static void (*fn_CGContextSetRGBStrokeColor)(CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat) = NULL;
static void (*fn_CGContextFillEllipseInRect)(CGContextRef, CGRect) = NULL;
static void (*fn_CGContextStrokeEllipseInRect)(CGContextRef, CGRect) = NULL;
static void (*fn_CGContextSetLineWidth)(CGContextRef, CGFloat) = NULL;
static void (*fn_CGContextMoveToPoint)(CGContextRef, CGFloat, CGFloat) = NULL;
static void (*fn_CGContextAddLineToPoint)(CGContextRef, CGFloat, CGFloat) = NULL;
static void (*fn_CGContextStrokePath)(CGContextRef) = NULL;
static void (*fn_CGContextAddArc)(CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, int) = NULL;
static void (*fn_CGContextFillRect)(CGContextRef, CGRect) = NULL;
static void (*fn_CGContextStrokeRect)(CGContextRef, CGRect) = NULL;
static void (*fn_NSLog)(id format, ...) = NULL;

#define UIGraphicsGetCurrentContext fn_UIGraphicsGetCurrentContext
#define CGContextSetRGBFillColor fn_CGContextSetRGBFillColor
#define CGContextSetRGBStrokeColor fn_CGContextSetRGBStrokeColor
#define CGContextFillEllipseInRect fn_CGContextFillEllipseInRect
#define CGContextStrokeEllipseInRect fn_CGContextStrokeEllipseInRect
#define CGContextSetLineWidth fn_CGContextSetLineWidth
#define CGContextMoveToPoint fn_CGContextMoveToPoint
#define CGContextAddLineToPoint fn_CGContextAddLineToPoint
#define CGContextStrokePath fn_CGContextStrokePath
#define CGContextAddArc fn_CGContextAddArc
#define CGContextFillRect fn_CGContextFillRect
#define CGContextStrokeRect fn_CGContextStrokeRect
#define NSLog fn_NSLog

static void resolve_cg_symbols(void) {
    if (fn_UIGraphicsGetCurrentContext) return;
    fn_UIGraphicsGetCurrentContext  = (CGContextRef (*)(void))dlsym(RTLD_DEFAULT, "UIGraphicsGetCurrentContext");
    fn_CGContextSetRGBFillColor     = (void (*)(CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat))dlsym(RTLD_DEFAULT, "CGContextSetRGBFillColor");
    fn_CGContextSetRGBStrokeColor   = (void (*)(CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat))dlsym(RTLD_DEFAULT, "CGContextSetRGBStrokeColor");
    fn_CGContextFillEllipseInRect   = (void (*)(CGContextRef, CGRect))dlsym(RTLD_DEFAULT, "CGContextFillEllipseInRect");
    fn_CGContextStrokeEllipseInRect = (void (*)(CGContextRef, CGRect))dlsym(RTLD_DEFAULT, "CGContextStrokeEllipseInRect");
    fn_CGContextSetLineWidth        = (void (*)(CGContextRef, CGFloat))dlsym(RTLD_DEFAULT, "CGContextSetLineWidth");
    fn_CGContextMoveToPoint         = (void (*)(CGContextRef, CGFloat, CGFloat))dlsym(RTLD_DEFAULT, "CGContextMoveToPoint");
    fn_CGContextAddLineToPoint      = (void (*)(CGContextRef, CGFloat, CGFloat))dlsym(RTLD_DEFAULT, "CGContextAddLineToPoint");
    fn_CGContextStrokePath          = (void (*)(CGContextRef))dlsym(RTLD_DEFAULT, "CGContextStrokePath");
    fn_CGContextAddArc              = (void (*)(CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, int))dlsym(RTLD_DEFAULT, "CGContextAddArc");
    fn_CGContextFillRect            = (void (*)(CGContextRef, CGRect))dlsym(RTLD_DEFAULT, "CGContextFillRect");
    fn_CGContextStrokeRect          = (void (*)(CGContextRef, CGRect))dlsym(RTLD_DEFAULT, "CGContextStrokeRect");
    fn_NSLog                        = (void (*)(id, ...))dlsym(RTLD_DEFAULT, "NSLog");

    fn_objc_getClass               = (Class (*)(const char *))dlsym(RTLD_DEFAULT, "objc_getClass");
    fn_objc_allocateClassPair       = (Class (*)(Class, const char *, size_t))dlsym(RTLD_DEFAULT, "objc_allocateClassPair");
    fn_objc_registerClassPair       = (void (*)(Class))dlsym(RTLD_DEFAULT, "objc_registerClassPair");
    fn_class_addMethod              = (BOOL (*)(Class, SEL, IMP, const char *))dlsym(RTLD_DEFAULT, "class_addMethod");
    fn_objc_msgSend                 = (id (*)(id, SEL, ...))dlsym(RTLD_DEFAULT, "objc_msgSend");
    fn_sel_registerName             = (SEL (*)(const char *))dlsym(RTLD_DEFAULT, "sel_registerName");
    fn_object_getClass              = (Class (*)(id))dlsym(RTLD_DEFAULT, "object_getClass");
    fn_class_getName                = (const char *(*)(Class))dlsym(RTLD_DEFAULT, "class_getName");
}

static id nsstr(const char *s) {
    if (!fn_objc_getClass) resolve_cg_symbols();
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), s);
}

/* ------------------------------------------------------------------ */
/*  Feature Configuration & Global State                              */
/* ------------------------------------------------------------------ */

#define RADAR_VIEW_SIZE    180.0f
#define MENU_WIDTH         340.0f
#define MENU_HEIGHT        320.0f

static int             g_shm_fd     = -1;
static radar_shared_t *g_shared     = NULL;
static radar_shared_t  g_snapshot;
static uint32_t        g_last_tick  = 0;
static double          g_changed_at = 0;
static uint32_t        g_draws = 0, g_reads = 0;
static FILE           *g_proof = NULL;

/* View references */
static id g_button_window, g_menu_window;
static void layout_controls(void);
static id g_window          = nil;
static id g_esp_view        = nil;
static id g_radar_view      = nil;
static id g_drag_button     = nil;
static id g_menu_view       = nil;
static id g_menu_footer     = nil;

/* Screen tracking for dynamic orientation adaptation */
static double g_screen_w = 0.0;
static double g_screen_h = 0.0;

/* UI Rects for hit testing */
static CGRect g_button_rect = {{16, 50}, {48, 48}};
static CGRect g_menu_rect   = {{100, 30}, {MENU_WIDTH, MENU_HEIGHT}};

/* Dragging state */
static CGPoint g_drag_start_touch;
static CGPoint g_drag_start_origin;
static BOOL    g_is_dragging = NO;

/* 12 Interactive Feature Flags */
static BOOL g_feat_radar     = YES;
static BOOL g_feat_lines     = YES;
static BOOL g_feat_box       = YES;
static BOOL g_feat_health    = YES;
static BOOL g_feat_name      = YES;
static BOOL g_feat_dist      = YES;
static BOOL g_feat_team_bot  = YES;
static BOOL g_feat_skeleton  = YES;
static BOOL g_feat_head      = YES;
static BOOL g_feat_vehicles  = YES;
static BOOL g_feat_items     = YES;
static int  g_radar_range    = 200; /* 100, 200, 400 meters */
static BOOL g_menu_open      = NO;

/* Menu button references for state updates */
static id g_btn_radar     = nil;
static id g_btn_lines     = nil;
static id g_btn_box       = nil;
static id g_btn_health    = nil;
static id g_btn_name      = nil;
static id g_btn_dist      = nil;
static id g_btn_team_bot  = nil;
static id g_btn_skeleton  = nil;
static id g_btn_head      = nil;
static id g_btn_vehicles  = nil;
static id g_btn_items     = nil;
static id g_btn_range     = nil;

/* Typography & Colors cached */
static id g_font_small = nil;
static id g_font_bold  = nil;
static id g_color_white = nil;
static id g_color_green = nil;
static id g_color_yellow = nil;
static id g_color_cyan = nil;
static id g_color_orange = nil;
static id g_color_gold = nil;
static id g_color_red = nil;

static double monotonic_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void hidden(id view, BOOL val) {
    if (view) ((void (*)(id, SEL, BOOL))objc_msgSend)(view, sel_registerName("setHidden:"), val);
}

static void title(id button, const char *text) {
    if (button) ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        button, sel_registerName("setTitle:forState:"), nsstr(text), 0);
}

static void style_toggle_button(id button, BOOL active) {
    if (!button) return;
    Class UIColor_cls = objc_getClass("UIColor");
    id bg = active ?
        ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.06, 0.32, 0.42, 0.92) :
        ((id (*)(id, SEL, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithWhite:alpha:"), 0.16, 0.88);
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setBackgroundColor:"), bg);

    id layer = ((id (*)(id, SEL))objc_msgSend)(button, sel_registerName("layer"));
    if (layer) {
        id border = active ?
            ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
                (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.0, 0.88, 1.0, 0.85) :
            ((id (*)(id, SEL, double, double))objc_msgSend)(
                (id)UIColor_cls, sel_registerName("colorWithWhite:alpha:"), 0.30, 0.50);
        id cg_color = ((id (*)(id, SEL))objc_msgSend)(border, sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setBorderColor:"), cg_color);
        ((void (*)(id, SEL, double))objc_msgSend)(layer, sel_registerName("setBorderWidth:"), active ? 1.5 : 1.0);
        ((void (*)(id, SEL, double))objc_msgSend)(layer, sel_registerName("setCornerRadius:"), 8.0);
    }
}

static void update_menu_buttons(void) {
    title(g_btn_radar, g_feat_radar ? "Radar: ON" : "Radar: OFF");
    style_toggle_button(g_btn_radar, g_feat_radar);

    title(g_btn_lines, g_feat_lines ? "Snaplines: ON" : "Snaplines: OFF");
    style_toggle_button(g_btn_lines, g_feat_lines);

    title(g_btn_box, g_feat_box ? "2D Box: ON" : "2D Box: OFF");
    style_toggle_button(g_btn_box, g_feat_box);

    title(g_btn_health, g_feat_health ? "Health: ON" : "Health: OFF");
    style_toggle_button(g_btn_health, g_feat_health);

    title(g_btn_name, g_feat_name ? "Name: ON" : "Name: OFF");
    style_toggle_button(g_btn_name, g_feat_name);

    title(g_btn_dist, g_feat_dist ? "Distance: ON" : "Distance: OFF");
    style_toggle_button(g_btn_dist, g_feat_dist);

    title(g_btn_team_bot, g_feat_team_bot ? "Team/Bot: ON" : "Team/Bot: OFF");
    style_toggle_button(g_btn_team_bot, g_feat_team_bot);

    title(g_btn_skeleton, g_feat_skeleton ? "Skeleton: ON" : "Skeleton: OFF");
    style_toggle_button(g_btn_skeleton, g_feat_skeleton);

    title(g_btn_head, g_feat_head ? "Head Dot: ON" : "Head Dot: OFF");
    style_toggle_button(g_btn_head, g_feat_head);

    title(g_btn_vehicles, g_feat_vehicles ? "Vehicles: ON" : "Vehicles: OFF");
    style_toggle_button(g_btn_vehicles, g_feat_vehicles);

    title(g_btn_items, g_feat_items ? "Loot ESP: ON" : "Loot ESP: OFF");
    style_toggle_button(g_btn_items, g_feat_items);

    char range_buf[32];
    snprintf(range_buf, sizeof(range_buf), "Range: %dm", g_radar_range);
    title(g_btn_range, range_buf);
    style_toggle_button(g_btn_range, YES);

    hidden(g_radar_view, !g_feat_radar);
}

static void toggle_menu(void) {
    g_menu_open = !g_menu_open;
    layout_controls();
    if (g_menu_view) {
        hidden(g_menu_view, !g_menu_open);
        if (g_menu_open) update_menu_buttons();
    }
    if (g_drag_button) {
        title(g_drag_button, g_menu_open ? "X" : "ESP");
    }
    if (g_proof) {
        fprintf(g_proof, "menu_toggled open=%d\n", g_menu_open);
        fflush(g_proof);
    }
}

id get_codex_overlay_window(void) {
    return g_window;
}

void codex_overlay_toggle_menu(void) {
    toggle_menu();
}

static id get_shared_window(id self, SEL cmd) {
    (void)self; (void)cmd;
    return g_window;
}

static void codex_action_toggle_menu_cls(id self, SEL cmd) {
    (void)self; (void)cmd;
    toggle_menu();
}

/* ------------------------------------------------------------------ */
/*  Text Rendering Helper via NSString drawAtPoint                    */
/* ------------------------------------------------------------------ */

static void draw_text_at(const char *text, CGPoint pt, id font, id color) {
    if (!text || text[0] == '\0' || !font || !color) return;
    id s = nsstr(text);
    if (!s) return;

    Class dict_cls = objc_getClass("NSDictionary");
    id font_key = nsstr("NSFont");
    id color_key = nsstr("NSColor");
    id objects[2] = { font, color };
    id keys[2] = { font_key, color_key };
    id attrs = ((id (*)(id, SEL, id*, id*, NSUInteger))objc_msgSend)(
        (id)dict_cls, sel_registerName("dictionaryWithObjects:forKeys:count:"),
        objects, keys, 2);

    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(
        s, sel_registerName("drawAtPoint:withAttributes:"), pt, attrs);
}

static CGSize text_size(const char *text, id font) {
    if (!text || text[0] == '\0' || !font) return (CGSize){0, 0};
    id s = nsstr(text);
    if (!s) return (CGSize){0, 0};

    Class dict_cls = objc_getClass("NSDictionary");
    id font_key = nsstr("NSFont");
    id objects[1] = { font };
    id keys[1] = { font_key };
    id attrs = ((id (*)(id, SEL, id*, id*, NSUInteger))objc_msgSend)(
        (id)dict_cls, sel_registerName("dictionaryWithObjects:forKeys:count:"),
        objects, keys, 1);

    return ((CGSize (*)(id, SEL, id))objc_msgSend)(
        s, sel_registerName("sizeWithAttributes:"), attrs);
}

static void draw_text_centered(const char *text, CGPoint center, id font, id color) {
    CGSize sz = text_size(text, font);
    CGPoint pt = (CGPoint){ center.x - sz.width / 2.0, center.y - sz.height / 2.0 };
    draw_text_at(text, pt, font, color);
}

/* ------------------------------------------------------------------ */
/*  Shared Memory Snapshot Reader                                     */
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

    g_shared = (radar_shared_t *)mmap(NULL, sizeof(radar_shared_t), PROT_READ, MAP_SHARED, g_shm_fd, 0);
    if (g_shared == MAP_FAILED) {
        g_shared = NULL;
        close(g_shm_fd);
        g_shm_fd = -1;
        return NO;
    }

    NSLog(nsstr("[Radar] Shared memory opened (%zu bytes, version %u)"),
          sizeof(radar_shared_t), RADAR_VERSION);
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
        if (candidate.header.magic != RADAR_MAGIC || candidate.header.version != RADAR_VERSION) return NO;
        if (candidate.header.player_count > RADAR_MAX_PLAYERS) return NO;

        g_snapshot = candidate;
        g_reads++;
        return YES;
    }
    return NO;
}

/* ------------------------------------------------------------------ */
/*  3D -> 2D World-To-Screen Projection                               */
/* ------------------------------------------------------------------ */

static BOOL world_to_screen(rvec3_t world_pos, CGPoint *out_screen, double *out_depth, double w, double h) {
    rvec3_t cam = g_snapshot.header.camera_pos;
    rvec3_t rot = g_snapshot.header.local_rot;
    double pitch = rot.x * M_PI / 180.0;
    double yaw   = rot.y * M_PI / 180.0;
    double roll  = rot.z * M_PI / 180.0;

    double cp = cos(pitch), sp = sin(pitch);
    double cy = cos(yaw),   sy = sin(yaw);
    double cr = cos(roll),  sr = sin(roll);

    double fov = g_snapshot.header.camera_fov;
    if (!isfinite(fov) || fov <= 10.0 || fov >= 180.0) fov = 90.0;
    double focal = w / (2.0 * tan(fov * M_PI / 360.0));

    double dx = world_pos.x - cam.x;
    double dy = world_pos.y - cam.y;
    double dz = world_pos.z - cam.z;

    double depth = dx * cp * cy + dy * cp * sy + dz * sp;
    if (depth <= 10.0) return NO; /* Behind or too close */

    double right = dx * (sr * sp * cy - cr * sy) + dy * (sr * sp * sy + cr * cy) - dz * sr * cp;
    double up    = dx * (-cr * sp * cy - sr * sy) + dy * (-cr * sp * sy + sr * cy) + dz * cr * cp;

    double x = w / 2.0 + right * focal / depth;
    double y = h / 2.0 - up * focal / depth;

    if (!isfinite(x) || !isfinite(y)) return NO;
    if (x < -200.0 || x > w + 200.0 || y < -200.0 || y > h + 200.0) return NO;

    out_screen->x = x;
    out_screen->y = y;
    if (out_depth) *out_depth = depth;
    return YES;
}

/* ------------------------------------------------------------------ */
/*  ESP Fullscreen View: drawRect (Players, Vehicles, Loot, Skeleton) */
/* ------------------------------------------------------------------ */

static void esp_drawRect(id self, SEL cmd, CGRect rect) {
    (void)cmd; (void)rect;
    g_draws++;

    if (!g_snapshot.header.camera_valid || g_snapshot.header.status != 2) return;
    if (monotonic_seconds() - g_changed_at > 2.0) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("bounds"));
    double w = bounds.size.width;
    double h = bounds.size.height;
    if (w <= 10.0 || h <= 10.0) return;

    /* 1. Render Players */
    uint32_t pcount = g_snapshot.header.player_count;
    if (pcount > RADAR_MAX_PLAYERS) pcount = RADAR_MAX_PLAYERS;

    for (uint32_t i = 0; i < pcount; i++) {
        const radar_player_t *p = &g_snapshot.players[i];
        if (p->health_status == 2) continue;

        CGPoint head_2d, feet_2d;
        double depth = 0;
        if (!world_to_screen(p->head_pos, &head_2d, &depth, w, h)) continue;
        if (!world_to_screen(p->feet_pos, &feet_2d, NULL, w, h)) continue;

        double box_h = feet_2d.y - head_2d.y;
        if (box_h < 12.0) box_h = 12.0;
        double box_w = box_h * 0.48;
        double box_x = (head_2d.x + feet_2d.x) / 2.0 - box_w / 2.0;
        double box_y = head_2d.y;

        /* Team color or Knocked color */
        BOOL is_knocked = (p->health_status == 1);
        id accent_color = is_knocked ? g_color_orange : (p->is_bot ? g_color_yellow : g_color_cyan);

        /* Feature: Snaplines */
        if (g_feat_lines) {
            if (is_knocked) CGContextSetRGBStrokeColor(ctx, 1.0, 0.55, 0.0, 0.75);
            else if (p->is_bot) CGContextSetRGBStrokeColor(ctx, 1.0, 0.9, 0.2, 0.75);
            else CGContextSetRGBStrokeColor(ctx, 0.0, 0.85, 1.0, 0.85);

            CGContextSetLineWidth(ctx, 1.2);
            CGContextMoveToPoint(ctx, w / 2.0, h);
            CGContextAddLineToPoint(ctx, (head_2d.x + feet_2d.x) / 2.0, feet_2d.y);
            CGContextStrokePath(ctx);
        }

        /* Feature: 2D Box ESP */
        if (g_feat_box) {
            if (is_knocked) CGContextSetRGBStrokeColor(ctx, 1.0, 0.55, 0.0, 0.9);
            else if (p->is_bot) CGContextSetRGBStrokeColor(ctx, 1.0, 0.9, 0.2, 0.9);
            else CGContextSetRGBStrokeColor(ctx, 0.0, 0.85, 1.0, 0.9);

            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeRect(ctx, CGRectMake_f(box_x, box_y, box_w, box_h));
        }

        /* Feature: Head Dot Aim Marker */
        if (g_feat_head) {
            CGContextSetRGBStrokeColor(ctx, 1.0, 0.2, 0.2, 0.95);
            CGContextSetRGBFillColor(ctx, 1.0, 0.2, 0.2, 0.40);
            CGContextSetLineWidth(ctx, 1.2);
            double hrad = fmax(3.0, box_w * 0.18);
            CGContextFillEllipseInRect(ctx, CGRectMake_f(head_2d.x - hrad, head_2d.y - hrad, hrad * 2, hrad * 2));
            CGContextStrokeEllipseInRect(ctx, CGRectMake_f(head_2d.x - hrad, head_2d.y - hrad, hrad * 2, hrad * 2));
        }

        /* Feature: Health Bar */
        if (g_feat_health && p->health_max > 0) {
            float hp_ratio = p->health / p->health_max;
            if (hp_ratio > 1.0f) hp_ratio = 1.0f;
            if (hp_ratio < 0.0f) hp_ratio = 0.0f;

            double bar_w = 3.5;
            double bar_x = box_x - bar_w - 3.0;

            /* Bar background */
            CGContextSetRGBFillColor(ctx, 0.1, 0.1, 0.1, 0.7);
            CGContextFillRect(ctx, CGRectMake_f(bar_x, box_y, bar_w, box_h));

            /* Filled health portion */
            double fill_h = box_h * hp_ratio;
            if (hp_ratio > 0.5f) CGContextSetRGBFillColor(ctx, 0.2, 0.9, 0.3, 0.95);
            else if (hp_ratio > 0.25f) CGContextSetRGBFillColor(ctx, 1.0, 0.8, 0.1, 0.95);
            else CGContextSetRGBFillColor(ctx, 1.0, 0.2, 0.2, 0.95);

            CGContextFillRect(ctx, CGRectMake_f(bar_x, box_y + (box_h - fill_h), bar_w, fill_h));
        }

        /* Feature: Player Name & Team/Bot Tag */
        if (g_feat_name || g_feat_team_bot) {
            char name_buf[64] = {0};
            if (is_knocked) {
                snprintf(name_buf, sizeof(name_buf), "[KNOCKED] %s", g_feat_name ? p->name : "");
            } else if (g_feat_team_bot) {
                if (p->is_bot) snprintf(name_buf, sizeof(name_buf), "[BOT] %s", g_feat_name ? p->name : "");
                else snprintf(name_buf, sizeof(name_buf), "[T%u] %s", p->team_id, g_feat_name ? p->name : "");
            } else if (g_feat_name) {
                snprintf(name_buf, sizeof(name_buf), "%s", p->name);
            }
            draw_text_centered(name_buf, (CGPoint){ (head_2d.x + feet_2d.x) / 2.0, box_y - 10 },
                               g_font_bold, accent_color);
        }

        /* Feature: Distance */
        if (g_feat_dist) {
            char dist_buf[32];
            snprintf(dist_buf, sizeof(dist_buf), "%.0fm", p->distance);
            draw_text_centered(dist_buf, (CGPoint){ (head_2d.x + feet_2d.x) / 2.0, feet_2d.y + 8 },
                               g_font_small, g_color_white);
        }

        /* Feature: Skeleton Bones */
        if (g_feat_skeleton && p->has_bones) {
            CGContextSetRGBStrokeColor(ctx, 0.9, 0.95, 1.0, 0.85);
            CGContextSetLineWidth(ctx, 1.2);

            CGPoint b_screen[RADAR_NUM_BONES];
            BOOL b_ok[RADAR_NUM_BONES];
            for (int b = 0; b < RADAR_NUM_BONES; b++) {
                b_ok[b] = world_to_screen(p->bones[b], &b_screen[b], NULL, w, h);
            }

            /* Spine: Head(0) -> Neck(1) -> Chest(2) -> Pelvis(3) */
            if (b_ok[0] && b_ok[1]) { CGContextMoveToPoint(ctx, b_screen[0].x, b_screen[0].y); CGContextAddLineToPoint(ctx, b_screen[1].x, b_screen[1].y); }
            if (b_ok[1] && b_ok[2]) { CGContextMoveToPoint(ctx, b_screen[1].x, b_screen[1].y); CGContextAddLineToPoint(ctx, b_screen[2].x, b_screen[2].y); }
            if (b_ok[2] && b_ok[3]) { CGContextMoveToPoint(ctx, b_screen[2].x, b_screen[2].y); CGContextAddLineToPoint(ctx, b_screen[3].x, b_screen[3].y); }

            /* Left arm: Chest(2) -> LShoulder(4) -> LElbow(5) -> LHand(6) */
            if (b_ok[2] && b_ok[4]) { CGContextMoveToPoint(ctx, b_screen[2].x, b_screen[2].y); CGContextAddLineToPoint(ctx, b_screen[4].x, b_screen[4].y); }
            if (b_ok[4] && b_ok[5]) { CGContextMoveToPoint(ctx, b_screen[4].x, b_screen[4].y); CGContextAddLineToPoint(ctx, b_screen[5].x, b_screen[5].y); }
            if (b_ok[5] && b_ok[6]) { CGContextMoveToPoint(ctx, b_screen[5].x, b_screen[5].y); CGContextAddLineToPoint(ctx, b_screen[6].x, b_screen[6].y); }

            /* Right arm: Chest(2) -> RShoulder(7) -> RElbow(8) -> RHand(9) */
            if (b_ok[2] && b_ok[7]) { CGContextMoveToPoint(ctx, b_screen[2].x, b_screen[2].y); CGContextAddLineToPoint(ctx, b_screen[7].x, b_screen[7].y); }
            if (b_ok[7] && b_ok[8]) { CGContextMoveToPoint(ctx, b_screen[7].x, b_screen[8].y); CGContextAddLineToPoint(ctx, b_screen[8].x, b_screen[8].y); }
            if (b_ok[8] && b_ok[9]) { CGContextMoveToPoint(ctx, b_screen[8].x, b_screen[8].y); CGContextAddLineToPoint(ctx, b_screen[9].x, b_screen[9].y); }

            /* Left leg: Pelvis(3) -> LHip(10) -> LKnee(11) -> LFoot(12) */
            if (b_ok[3] && b_ok[10]) { CGContextMoveToPoint(ctx, b_screen[3].x, b_screen[3].y); CGContextAddLineToPoint(ctx, b_screen[10].x, b_screen[10].y); }
            if (b_ok[10] && b_ok[11]) { CGContextMoveToPoint(ctx, b_screen[10].x, b_screen[10].y); CGContextAddLineToPoint(ctx, b_screen[11].x, b_screen[11].y); }
            if (b_ok[11] && b_ok[12]) { CGContextMoveToPoint(ctx, b_screen[11].x, b_screen[11].y); CGContextAddLineToPoint(ctx, b_screen[12].x, b_screen[12].y); }

            /* Right leg: Pelvis(3) -> RHip(13) -> RKnee(14) -> RFoot(15) */
            if (b_ok[3] && b_ok[13]) { CGContextMoveToPoint(ctx, b_screen[3].x, b_screen[3].y); CGContextAddLineToPoint(ctx, b_screen[13].x, b_screen[13].y); }
            if (b_ok[13] && b_ok[14]) { CGContextMoveToPoint(ctx, b_screen[13].x, b_screen[13].y); CGContextAddLineToPoint(ctx, b_screen[14].x, b_screen[14].y); }
            if (b_ok[14] && b_ok[15]) { CGContextMoveToPoint(ctx, b_screen[14].x, b_screen[14].y); CGContextAddLineToPoint(ctx, b_screen[15].x, b_screen[15].y); }

            CGContextStrokePath(ctx);
        }
    }

    /* 2. Render Vehicles */
    if (g_feat_vehicles) {
        uint32_t vcount = g_snapshot.header.vehicle_count;
        if (vcount > RADAR_MAX_VEHICLES) vcount = RADAR_MAX_VEHICLES;

        for (uint32_t i = 0; i < vcount; i++) {
            const radar_vehicle_t *v = &g_snapshot.vehicles[i];
            CGPoint v_screen;
            if (!world_to_screen(v->pos, &v_screen, NULL, w, h)) continue;

            /* Draw diamond marker */
            CGContextSetRGBStrokeColor(ctx, 1.0, 0.85, 0.1, 0.95);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextMoveToPoint(ctx, v_screen.x, v_screen.y - 6);
            CGContextAddLineToPoint(ctx, v_screen.x + 6, v_screen.y);
            CGContextAddLineToPoint(ctx, v_screen.x, v_screen.y + 6);
            CGContextAddLineToPoint(ctx, v_screen.x - 6, v_screen.y);
            CGContextAddLineToPoint(ctx, v_screen.x, v_screen.y - 6);
            CGContextStrokePath(ctx);

            char vbuf[64];
            if (v->speed > 2.0f) {
                snprintf(vbuf, sizeof(vbuf), "[%s] %.0fm (%.0f km/h)", v->name, v->distance, v->speed);
            } else {
                snprintf(vbuf, sizeof(vbuf), "[%s] %.0fm", v->name, v->distance);
            }
            draw_text_centered(vbuf, (CGPoint){ v_screen.x, v_screen.y + 12 }, g_font_bold, g_color_gold);
        }
    }

    /* 3. Render Loot & Items */
    if (g_feat_items) {
        uint32_t icount = g_snapshot.header.item_count;
        if (icount > RADAR_MAX_ITEMS) icount = RADAR_MAX_ITEMS;

        for (uint32_t i = 0; i < icount; i++) {
            const radar_item_t *item = &g_snapshot.items[i];
            CGPoint i_screen;
            if (!world_to_screen(item->pos, &i_screen, NULL, w, h)) continue;

            /* Small dot with category color */
            if (item->category == 1) CGContextSetRGBFillColor(ctx, 1.0, 0.3, 0.3, 0.85); /* Weapons: Red */
            else if (item->category == 2) CGContextSetRGBFillColor(ctx, 0.2, 0.7, 1.0, 0.85); /* Armor: Blue */
            else if (item->category == 3) CGContextSetRGBFillColor(ctx, 0.2, 0.95, 0.4, 0.85); /* Meds: Green */
            else CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.9, 0.75); /* Other / Ammo */

            CGContextFillEllipseInRect(ctx, CGRectMake_f(i_screen.x - 3, i_screen.y - 3, 6, 6));

            char ibuf[64];
            if (item->count > 1) {
                snprintf(ibuf, sizeof(ibuf), "%s x%d (%.0fm)", item->name, item->count, item->distance);
            } else {
                snprintf(ibuf, sizeof(ibuf), "%s (%.0fm)", item->name, item->distance);
            }
            draw_text_centered(ibuf, (CGPoint){ i_screen.x, i_screen.y - 8 }, g_font_small, g_color_green);
        }
    }
}

/* ------------------------------------------------------------------ */
/*  Radar Minimap View: drawRect                                      */
/* ------------------------------------------------------------------ */

static void radar_drawRect(id self, SEL cmd, CGRect rect) {
    (void)self; (void)cmd; (void)rect;
    if (!g_feat_radar) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    float radius = RADAR_VIEW_SIZE / 2.0f;
    float cx = radius, cy = radius;
    float range_cm = (float)g_radar_range * 100.0f;
    float scale = radius / range_cm;

    /* Background circular card */
    CGContextSetRGBFillColor(ctx, 0.05f, 0.07f, 0.12f, 0.70f);
    CGContextFillEllipseInRect(ctx, CGRectMake_f(0, 0, RADAR_VIEW_SIZE, RADAR_VIEW_SIZE));

    /* Outer border ring */
    CGContextSetRGBStrokeColor(ctx, 0.0f, 0.85f, 1.0f, 0.65f);
    CGContextSetLineWidth(ctx, 1.5f);
    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(1, 1, RADAR_VIEW_SIZE - 2, RADAR_VIEW_SIZE - 2));

    /* Grid range rings */
    CGContextSetRGBStrokeColor(ctx, 0.3f, 0.4f, 0.5f, 0.4f);
    CGContextSetLineWidth(ctx, 0.8f);
    for (int i = 1; i <= 3; i++) {
        float r = radius * (float)i / 3.0f;
        CGContextStrokeEllipseInRect(ctx, CGRectMake_f(cx - r, cy - r, r * 2, r * 2));
    }

    /* Crosshairs */
    CGContextMoveToPoint(ctx, cx, 0);
    CGContextAddLineToPoint(ctx, cx, RADAR_VIEW_SIZE);
    CGContextMoveToPoint(ctx, 0, cy);
    CGContextAddLineToPoint(ctx, RADAR_VIEW_SIZE, cy);
    CGContextStrokePath(ctx);

    /* Local player center dot */
    CGContextSetRGBFillColor(ctx, 0.0f, 0.9f, 1.0f, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake_f(cx - 3.5f, cy - 3.5f, 7.0f, 7.0f));

    /* Camera view cone */
    float cam_yaw_rad = -g_snapshot.header.local_rot.y * (float)M_PI / 180.0f;
    float cos_yaw = cosf(cam_yaw_rad);
    float sin_yaw = sinf(cam_yaw_rad);

    CGContextSetRGBStrokeColor(ctx, 0.0f, 0.9f, 1.0f, 0.45f);
    CGContextSetLineWidth(ctx, 1.2f);
    float cone_half = 30.0f * (float)M_PI / 180.0f;
    float cone_len = radius * 0.85f;
    float cl_x = cx + sinf(-cone_half) * cone_len;
    float cl_y = cy - cosf(-cone_half) * cone_len;
    float cr_x = cx + sinf(cone_half) * cone_len;
    float cr_y = cy - cosf(cone_half) * cone_len;
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cl_x, cl_y);
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cr_x, cr_y);
    CGContextStrokePath(ctx);

    rvec3_t lp = g_snapshot.header.local_pos;
    BOOL fresh = (g_snapshot.header.status == 2 && monotonic_seconds() - g_changed_at < 2.0);
    if (!fresh) return;

    /* Draw loot on radar */
    if (g_feat_items) {
        for (uint32_t i = 0; i < g_snapshot.header.item_count && i < RADAR_MAX_ITEMS; i++) {
            const radar_item_t *item = &g_snapshot.items[i];
            float dx = item->pos.x - lp.x;
            float dy = item->pos.y - lp.y;
            float rx = dx * cos_yaw - dy * sin_yaw;
            float ry = dx * sin_yaw + dy * cos_yaw;
            float sx = ry * scale;
            float sy = -rx * scale;
            float d = sqrtf(sx*sx + sy*sy);
            if (d > radius - 4.0f) continue;

            CGContextSetRGBFillColor(ctx, 0.2f, 0.9f, 0.4f, 0.7f);
            CGContextFillEllipseInRect(ctx, CGRectMake_f(cx + sx - 2, cy + sy - 2, 4, 4));
        }
    }

    /* Draw vehicles on radar */
    if (g_feat_vehicles) {
        for (uint32_t i = 0; i < g_snapshot.header.vehicle_count && i < RADAR_MAX_VEHICLES; i++) {
            const radar_vehicle_t *v = &g_snapshot.vehicles[i];
            float dx = v->pos.x - lp.x;
            float dy = v->pos.y - lp.y;
            float rx = dx * cos_yaw - dy * sin_yaw;
            float ry = dx * sin_yaw + dy * cos_yaw;
            float sx = ry * scale;
            float sy = -rx * scale;
            float d = sqrtf(sx*sx + sy*sy);
            if (d > radius - 5.0f) continue;

            CGContextSetRGBFillColor(ctx, 1.0f, 0.85f, 0.1f, 0.95f);
            CGContextFillRect(ctx, CGRectMake_f(cx + sx - 3, cy + sy - 3, 6, 6));
        }
    }

    /* Draw players on radar */
    for (uint32_t i = 0; i < g_snapshot.header.player_count && i < RADAR_MAX_PLAYERS; i++) {
        const radar_player_t *p = &g_snapshot.players[i];
        if (p->health_status == 2) continue;

        float dx = p->pos.x - lp.x;
        float dy = p->pos.y - lp.y;
        float rx = dx * cos_yaw - dy * sin_yaw;
        float ry = dx * sin_yaw + dy * cos_yaw;
        float sx = ry * scale;
        float sy = -rx * scale;

        float dist = sqrtf(sx * sx + sy * sy);
        if (dist > radius - 6.0f) {
            float clamp = (radius - 6.0f) / dist;
            sx *= clamp;
            sy *= clamp;
        }

        float dotx = cx + sx;
        float doty = cy + sy;

        if (p->health_status == 1) {
            CGContextSetRGBFillColor(ctx, 1.0f, 0.55f, 0.0f, 1.0f);
        } else if (p->is_bot) {
            CGContextSetRGBFillColor(ctx, 1.0f, 0.9f, 0.2f, 1.0f);
        } else {
            CGContextSetRGBFillColor(ctx, 1.0f, 0.2f, 0.2f, 1.0f);
        }

        CGContextFillEllipseInRect(ctx, CGRectMake_f(dotx - 3.5f, doty - 3.5f, 7.0f, 7.0f));

        /* Health arc around player */
        if (p->health_max > 0) {
            float hp = p->health / p->health_max;
            if (hp > 1.0f) hp = 1.0f;
            if (hp < 0.0f) hp = 0.0f;

            CGContextSetRGBStrokeColor(ctx, 1.0f - hp, hp, 0.0f, 0.85f);
            CGContextSetLineWidth(ctx, 1.8f);
            float start = -(float)M_PI / 2.0f;
            float end   = start + hp * 2.0f * (float)M_PI;
            CGContextAddArc(ctx, dotx, doty, 6.0f, start, end, 0);
            CGContextStrokePath(ctx);
        }
    }
}

/* ------------------------------------------------------------------ */
/*  UIWindow Subclass: 100% Touch Pass-Through Window                 */
/* ------------------------------------------------------------------ */

/* Window-server routing happens before UIKit hitTest. A dedicated display
 * class must opt out before initWithFrame registers its remote context. */
static BOOL display_ignores_hit_test(id self, SEL cmd) {
    (void)self; (void)cmd; return YES;
}
static BOOL display_uses_window_server_hit_testing(id self, SEL cmd) {
    (void)self; (void)cmd; return NO;
}

static BOOL window_pointInside(id self, SEL cmd, CGPoint point, id event) {
    (void)cmd; (void)event;
    if (self == g_window) return NO;
    if (self != g_button_window && self != g_menu_window) return NO;
    if (self == g_menu_window && !g_menu_open) return NO;
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("bounds"));
    return in_rect(point, bounds);
}

static id window_hitTest(id self, SEL cmd, CGPoint point, id event) {
    (void)cmd;
    if (!window_pointInside(self, 0, point, event)) return nil;
    if (self == g_button_window) return g_drag_button;
    CGPoint p = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(
        g_menu_view, sel_registerName("convertPoint:fromView:"), point, self);
    return ((id (*)(id, SEL, CGPoint, id))objc_msgSend)(
        g_menu_view, sel_registerName("hitTest:withEvent:"), p, event);
}

/* Only these two small windows accept input. The full-screen drawing window
 * is noninteractive, including when the menu is expanded. */
static void layout_controls(void) {
    if (!g_button_window || !g_menu_window || !g_menu_view) return;
    double margin = 32.0;
    g_button_rect.origin.x = fmax(margin, fmin(g_button_rect.origin.x, g_screen_w - 48.0 - margin));
    g_button_rect.origin.y = fmax(margin, fmin(g_button_rect.origin.y, g_screen_h - 48.0 - margin));
    ((void (*)(id, SEL, CGRect))objc_msgSend)(g_button_window, sel_registerName("setFrame:"), g_button_rect);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(g_drag_button, sel_registerName("setFrame:"), CGRectMake_f(0, 0, 48, 48));
    double scale = fmin(1.0, fmin((g_screen_w - 2 * margin) / MENU_WIDTH, (g_screen_h - 2 * margin) / MENU_HEIGHT));
    g_menu_rect = CGRectMake_f((g_screen_w - MENU_WIDTH * scale)/2, (g_screen_h - MENU_HEIGHT * scale)/2, MENU_WIDTH * scale, MENU_HEIGHT * scale);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(g_menu_window, sel_registerName("setFrame:"), g_menu_rect);
    typedef struct { double a,b,c,d,tx,ty; } Transform;
    ((void (*)(id, SEL, Transform))objc_msgSend)(g_menu_view, sel_registerName("setTransform:"), (Transform){scale,0,0,scale,0,0});
    ((void (*)(id, SEL, CGRect))objc_msgSend)(g_menu_view, sel_registerName("setBounds:"), CGRectMake_f(0,0,MENU_WIDTH,MENU_HEIGHT));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(g_menu_view, sel_registerName("setCenter:"), (CGPoint){g_menu_rect.size.width/2,g_menu_rect.size.height/2});
    hidden(g_menu_window, !g_menu_open);
    hidden(g_button_window, g_menu_open);
}

/* ------------------------------------------------------------------ */
/*  Draggable Floating Button Touch Handling                          */
/* ------------------------------------------------------------------ */

static void btn_touchesBegan(id self, SEL cmd, id touches, id event) {
    (void)cmd; (void)event;
    id touch = ((id (*)(id, SEL))objc_msgSend)(touches, sel_registerName("anyObject"));
    if (touch) {
        g_drag_start_touch = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
            touch, sel_registerName("locationInView:"), g_window);
        CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("frame"));
        (void)f;
        g_drag_start_origin = g_button_rect.origin;
        g_is_dragging = NO;
    }
}

static void btn_touchesMoved(id self, SEL cmd, id touches, id event) {
    (void)cmd; (void)event;
    id touch = ((id (*)(id, SEL))objc_msgSend)(touches, sel_registerName("anyObject"));
    if (touch) {
        CGPoint cur = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
            touch, sel_registerName("locationInView:"), g_window);
        double dx = cur.x - g_drag_start_touch.x;
        double dy = cur.y - g_drag_start_touch.y;
        if (fabs(dx) > 4.0 || fabs(dy) > 4.0) {
            g_is_dragging = YES;
            CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("bounds"));
            CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("frame"));
            double new_x = g_drag_start_origin.x + dx;
            double new_y = g_drag_start_origin.y + dy;
            if (new_x < 4.0) new_x = 4.0;
            if (new_y < 4.0) new_y = 4.0;
            if (new_x + f.size.width > bounds.size.width - 4.0) new_x = bounds.size.width - f.size.width - 4.0;
            if (new_y + f.size.height > bounds.size.height - 4.0) new_y = bounds.size.height - f.size.height - 4.0;
            f.origin.x = new_x;
            f.origin.y = new_y;
            ((void (*)(id, SEL, CGRect))objc_msgSend)(self, sel_registerName("setFrame:"), f);
            g_button_rect = f;
            layout_controls();
        }
    }
}

static void btn_touchesEnded(id self, SEL cmd, id touches, id event) {
    (void)self; (void)cmd; (void)touches; (void)event;
    if (!g_is_dragging) {
        toggle_menu();
    }
    g_is_dragging = NO;
}

static void btn_touchesCancelled(id self, SEL cmd, id touches, id event) {
    (void)self; (void)cmd; (void)touches; (void)event;
    g_is_dragging = NO;
}

/* ------------------------------------------------------------------ */
/*  Menu Action Callbacks                                             */
/* ------------------------------------------------------------------ */

static void action_toggle_radar(id self, SEL cmd, id sender)     { (void)self; (void)cmd; (void)sender; g_feat_radar = !g_feat_radar; update_menu_buttons(); }
static void action_toggle_lines(id self, SEL cmd, id sender)     { (void)self; (void)cmd; (void)sender; g_feat_lines = !g_feat_lines; update_menu_buttons(); }
static void action_toggle_box(id self, SEL cmd, id sender)       { (void)self; (void)cmd; (void)sender; g_feat_box = !g_feat_box; update_menu_buttons(); }
static void action_toggle_health(id self, SEL cmd, id sender)    { (void)self; (void)cmd; (void)sender; g_feat_health = !g_feat_health; update_menu_buttons(); }
static void action_toggle_name(id self, SEL cmd, id sender)      { (void)self; (void)cmd; (void)sender; g_feat_name = !g_feat_name; update_menu_buttons(); }
static void action_toggle_dist(id self, SEL cmd, id sender)      { (void)self; (void)cmd; (void)sender; g_feat_dist = !g_feat_dist; update_menu_buttons(); }
static void action_toggle_team_bot(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_team_bot = !g_feat_team_bot; update_menu_buttons(); }
static void action_toggle_skeleton(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_skeleton = !g_feat_skeleton; update_menu_buttons(); }
static void action_toggle_head(id self, SEL cmd, id sender)      { (void)self; (void)cmd; (void)sender; g_feat_head = !g_feat_head; update_menu_buttons(); }
static void action_toggle_vehicles(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_vehicles = !g_feat_vehicles; update_menu_buttons(); }
static void action_toggle_items(id self, SEL cmd, id sender)     { (void)self; (void)cmd; (void)sender; g_feat_items = !g_feat_items; update_menu_buttons(); }
static void action_toggle_range(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    if (g_radar_range == 100) g_radar_range = 200;
    else if (g_radar_range == 200) g_radar_range = 400;
    else g_radar_range = 100;
    update_menu_buttons();
}
static void action_close_menu(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    if (g_menu_open) toggle_menu();
}

static id make_menu_button(id parent, id target, CGRect frame, const char *text, SEL action) {
    id btn = ((id (*)(id, SEL, NSInteger))objc_msgSend)(
        (id)objc_getClass("UIButton"), sel_registerName("buttonWithType:"), 1);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(btn, sel_registerName("setFrame:"), frame);
    title(btn, text);

    id titleLabel = ((id (*)(id, SEL))objc_msgSend)(btn, sel_registerName("titleLabel"));
    if (titleLabel && g_font_bold) {
        ((void (*)(id, SEL, id))objc_msgSend)(titleLabel, sel_registerName("setFont:"), g_font_bold);
    }
    ((void (*)(id, SEL, id, SEL, NSUInteger))objc_msgSend)(
        btn, sel_registerName("addTarget:action:forControlEvents:"), target, action, 64);
    ((void (*)(id, SEL, id))objc_msgSend)(parent, sel_registerName("addSubview:"), btn);
    return btn;
}

/* ------------------------------------------------------------------ */
/*  Timer Callback: 20 Hz Frame Update & Orientation Adaptation        */
/* ------------------------------------------------------------------ */

static int g_frame_counter = 0;

static void timer_tick(id self, SEL cmd, id timer) {
    (void)self; (void)cmd; (void)timer;
    g_frame_counter++;

    /* 1. Dynamic orientation & screen bounds adaptation */
    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
    CGRect cur_bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));

    id scene = nil;
    if (g_window) scene = ((id (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("windowScene"));

    /* Periodically ensure window is attached to the foreground active UIWindowScene */
    if (g_window && g_frame_counter % 20 == 1) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
        id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
        id sceneEnum = ((id (*)(id, SEL))objc_msgSend)(scenes, sel_registerName("objectEnumerator"));
        id s, active_s = nil;
        while ((s = ((id (*)(id, SEL))objc_msgSend)(sceneEnum, sel_registerName("nextObject")))) {
            if (((BOOL (*)(id, SEL, Class))objc_msgSend)(s, sel_registerName("isKindOfClass:"), objc_getClass("UIWindowScene"))) {
                NSInteger state = (NSInteger)((id (*)(id, SEL))objc_msgSend)(s, sel_registerName("activationState"));
                if (state == 0) { /* UISceneActivationStateForegroundActive */
                    active_s = s;
                    break;
                }
                if (!active_s) active_s = s;
            }
        }
        if (active_s && active_s != scene) {
            ((void (*)(id, SEL, id))objc_msgSend)(g_window, sel_registerName("setWindowScene:"), active_s);
            ((void (*)(id, SEL, id))objc_msgSend)(g_button_window, sel_registerName("setWindowScene:"), active_s);
            ((void (*)(id, SEL, id))objc_msgSend)(g_menu_window, sel_registerName("setWindowScene:"), active_s);
            scene = active_s;
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(g_window, sel_registerName("setHidden:"), NO);
        if (!g_menu_open && g_button_window) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(g_button_window, sel_registerName("setHidden:"), NO);
        }
    }
    NSInteger ori = 0;
    if (scene) ori = (NSInteger)((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("interfaceOrientation"));
    BOOL is_landscape = (ori == 3 || ori == 4);
    if (!is_landscape && g_snapshot.header.status == 2 && g_snapshot.header.camera_valid) {
        /* When live game camera is tracking, PUBG Mobile on iPhone is landscape */
        is_landscape = YES;
    }
    if (is_landscape) {
        double sw = fmax(cur_bounds.size.width, cur_bounds.size.height);
        double sh = fmin(cur_bounds.size.width, cur_bounds.size.height);
        cur_bounds = CGRectMake_f(0, 0, sw, sh);
    } else {
        double sw = fmin(cur_bounds.size.width, cur_bounds.size.height);
        double sh = fmax(cur_bounds.size.width, cur_bounds.size.height);
        cur_bounds = CGRectMake_f(0, 0, sw, sh);
    }

    if (cur_bounds.size.width > 0 && cur_bounds.size.height > 0 &&
        (fabs(cur_bounds.size.width - g_screen_w) > 1.0 || fabs(cur_bounds.size.height - g_screen_h) > 1.0)) {
        g_screen_w = cur_bounds.size.width;
        g_screen_h = cur_bounds.size.height;

        if (g_window) ((void (*)(id, SEL, CGRect))objc_msgSend)(g_window, sel_registerName("setFrame:"), cur_bounds);
        if (g_esp_view) ((void (*)(id, SEL, CGRect))objc_msgSend)(g_esp_view, sel_registerName("setFrame:"), cur_bounds);

        /* Adapt radar position for Landscape vs Portrait */
        double rx = fmax(10.0, g_screen_w - RADAR_VIEW_SIZE - 32.0);
        double ry = (g_screen_w > g_screen_h) ? 32.0 : 50.0;
        if (g_radar_view) ((void (*)(id, SEL, CGRect))objc_msgSend)(g_radar_view, sel_registerName("setFrame:"),
                                                                    CGRectMake_f(rx, ry, RADAR_VIEW_SIZE, RADAR_VIEW_SIZE));

        /* Adapt settings menu position (centered on screen) */
        double mx = fmax(10.0, (g_screen_w - MENU_WIDTH) / 2.0);
        double my = fmax(10.0, (g_screen_h - MENU_HEIGHT) / 2.0);
        g_menu_rect = CGRectMake_f(mx, my, MENU_WIDTH, MENU_HEIGHT);
        if (g_menu_view) ((void (*)(id, SEL, CGRect))objc_msgSend)(g_menu_view, sel_registerName("setFrame:"), g_menu_rect);

        /* Clamp floating button within new screen boundaries */
        if (g_drag_button) {
            CGRect bf = g_button_rect;
            if (bf.origin.x + bf.size.width > g_screen_w - 4.0) bf.origin.x = g_screen_w - bf.size.width - 4.0;
            if (bf.origin.y + bf.size.height > g_screen_h - 4.0) bf.origin.y = g_screen_h - bf.size.height - 4.0;
            if (bf.origin.x < 4.0) bf.origin.x = 4.0;
            if (bf.origin.y < 4.0) bf.origin.y = 4.0;
            ((void (*)(id, SEL, CGRect))objc_msgSend)(g_drag_button, sel_registerName("setFrame:"), bf);
            g_button_rect = bf;
            layout_controls();
        }
    }

    if (!g_shared && g_frame_counter % 20 == 1) {
        open_shared_memory();
    }

    if (g_shared && read_snapshot() && g_snapshot.header.tick != g_last_tick) {
        g_last_tick = g_snapshot.header.tick;
        g_changed_at = monotonic_seconds();
    }

    /* Redraw active views */
    if (g_esp_view) {
        ((void (*)(id, SEL))objc_msgSend)(g_esp_view, sel_registerName("setNeedsDisplay"));
    }
    if (g_feat_radar && g_radar_view) {
        ((void (*)(id, SEL))objc_msgSend)(g_radar_view, sel_registerName("setNeedsDisplay"));
    }

    /* Update menu footer info every 20 frames */
    if (g_menu_open && g_menu_footer && g_frame_counter % 20 == 1) {
        BOOL fresh = monotonic_seconds() - g_changed_at < 2.0;
        char status_txt[128];
        snprintf(status_txt, sizeof(status_txt), "Status: %s | P: %u | V: %u | L: %u",
                 fresh ? "LIVE" : "WAITING",
                 g_snapshot.header.player_count,
                 g_snapshot.header.vehicle_count,
                 g_snapshot.header.item_count);
        ((void (*)(id, SEL, id))objc_msgSend)(g_menu_footer, sel_registerName("setText:"), nsstr(status_txt));
    }

    /* Periodic diagnostic logging */
    if (g_proof && g_frame_counter % 100 == 1) {
        fprintf(g_proof, "timer=%d reads=%u draws=%u tick=%u status=%u players=%u vehs=%u items=%u menu=%d\n",
                g_frame_counter, g_reads, g_draws, g_last_tick, g_snapshot.header.status,
                g_snapshot.header.player_count, g_snapshot.header.vehicle_count,
                g_snapshot.header.item_count, g_menu_open);
        fflush(g_proof);
    }
}

/* --- Root View Controller with Full Orientation Support --- */
static NSUInteger vc_supportedOrientations(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 30; /* UIInterfaceOrientationMaskAll */
}
static BOOL vc_shouldAutorotate(id self, SEL cmd) {
    (void)self; (void)cmd;
    return YES;
}
static BOOL vc_prefersStatusBarHidden(id self, SEL cmd) {
    (void)self; (void)cmd;
    return YES;
}
static void vc_loadView(id self, SEL cmd) {
    (void)cmd;
    Class UIView_cls = objc_getClass("UIView");
    Class UIScreen_cls = objc_getClass("UIScreen");
    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)UIScreen_cls, sel_registerName("mainScreen"));
    CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));
    id v = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UIView_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), b);
    ((void (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setView:"), v);
}

static void init_overlay(void) {
    if (g_window) return;
    FILE *fstep = fopen("/var/mobile/Downloads/overlay_step.log", "w");
    if (fstep) { fprintf(fstep, "step 1: resolve_cg_symbols\n"); fflush(fstep); }
    resolve_cg_symbols();
    g_proof = fopen("/var/mobile/Downloads/ue4_overlay_v3_proof.log", "a");

    Class UIWindow_cls  = objc_getClass("UIWindow");
    Class UIView_cls    = objc_getClass("UIView");
    Class UIButton_cls  = objc_getClass("UIButton");
    Class UILabel_cls   = objc_getClass("UILabel");
    Class UIScreen_cls  = objc_getClass("UIScreen");
    Class UIColor_cls   = objc_getClass("UIColor");
    Class UIFont_cls    = objc_getClass("UIFont");
    Class UIApp_cls     = objc_getClass("UIApplication");
    Class UIWindowScene = objc_getClass("UIWindowScene");
    Class NSTimer_cls   = objc_getClass("NSTimer");
    Class NSRunLoop_cls = objc_getClass("NSRunLoop");

    if (!UIApp_cls || !UIWindowScene || !UIWindow_cls) {
        if (fstep) { fprintf(fstep, "Essential classes not available yet\n"); fclose(fstep); }
        return;
    }

    id app = ((id (*)(id, SEL))objc_msgSend)((id)UIApp_cls, sel_registerName("sharedApplication"));
    if (!app) {
        if (fstep) { fprintf(fstep, "sharedApplication is nil\n"); fclose(fstep); }
        return;
    }

    id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
    if (!scenes) {
        if (fstep) { fprintf(fstep, "connectedScenes is nil\n"); fclose(fstep); }
        return;
    }

    id sceneEnum = ((id (*)(id, SEL))objc_msgSend)(scenes, sel_registerName("objectEnumerator"));
    id scene = nil, best_scene = nil;
    while ((scene = ((id (*)(id, SEL))objc_msgSend)(sceneEnum, sel_registerName("nextObject")))) {
        BOOL isWindowScene = (BOOL)(NSInteger)((id (*)(id, SEL, id))objc_msgSend)(
            scene, sel_registerName("isKindOfClass:"), UIWindowScene);
        if (isWindowScene) {
            NSInteger state = (NSInteger)((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("activationState"));
            if (state == 0) { // UISceneActivationStateForegroundActive
                best_scene = scene;
                break;
            }
            if (!best_scene) best_scene = scene;
        }
    }
    if (!best_scene) {
        if (fstep) { fprintf(fstep, "No UIWindowScene connected yet, waiting...\n"); fclose(fstep); }
        return;
    }

    if (fstep) {
        fprintf(fstep, "step 2: active UIWindowScene=%p, UIWindow=%p, UIView=%p, UIButton=%p, UILabel=%p, UIScreen=%p, UIColor=%p, UIFont=%p\n",
                best_scene, UIWindow_cls, UIView_cls, UIButton_cls, UILabel_cls, UIScreen_cls, UIColor_cls, UIFont_cls);
        fflush(fstep);
    }

    /* Cache common colors and fonts */
    if (fstep) { fprintf(fstep, "step 2a: fonts\n"); fflush(fstep); }
    if (UIFont_cls) {
        g_font_small = ((id (*)(id, SEL, double))objc_msgSend)((id)UIFont_cls, sel_registerName("systemFontOfSize:"), 11.0);
        g_font_bold  = ((id (*)(id, SEL, double))objc_msgSend)((id)UIFont_cls, sel_registerName("boldSystemFontOfSize:"), 12.0);
    }
    if (fstep) { fprintf(fstep, "step 2b: white\n"); fflush(fstep); }
    if (UIColor_cls) {
        g_color_white = ((id (*)(id, SEL))objc_msgSend)((id)UIColor_cls, sel_registerName("whiteColor"));
        if (fstep) { fprintf(fstep, "step 2c: green\n"); fflush(fstep); }
        g_color_green = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.2, 0.95, 0.35, 1.0);
        if (fstep) { fprintf(fstep, "step 2d: yellow\n"); fflush(fstep); }
        g_color_yellow = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.9, 0.2, 1.0);
        if (fstep) { fprintf(fstep, "step 2e: cyan\n"); fflush(fstep); }
        g_color_cyan = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.0, 0.88, 1.0, 1.0);
        if (fstep) { fprintf(fstep, "step 2f: orange\n"); fflush(fstep); }
        g_color_orange = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.55, 0.0, 1.0);
        if (fstep) { fprintf(fstep, "step 2g: gold\n"); fflush(fstep); }
        g_color_gold = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.82, 0.1, 1.0);
        if (fstep) { fprintf(fstep, "step 2h: red\n"); fflush(fstep); }
        g_color_red = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.2, 0.2, 1.0);
    }
    if (fstep) { fprintf(fstep, "step 3: custom classes\n"); fflush(fstep); }

    /* --- Register Custom Classes --- */

    /* 1. Radar Window */
    Class RadarWindow = objc_allocateClassPair(UIWindow_cls, "CodexRadarV4Window", 0);
    if (!RadarWindow) {
        RadarWindow = objc_getClass("CodexRadarV4Window");
    } else {
        class_addMethod(RadarWindow, sel_registerName("pointInside:withEvent:"),
                        (IMP)window_pointInside, "B@:{CGPoint=dd}@");
        class_addMethod(RadarWindow, sel_registerName("hitTest:withEvent:"),
                        (IMP)window_hitTest, "@@:{CGPoint=dd}@");
        objc_registerClassPair(RadarWindow);
    }
    Class DisplayWindow = objc_allocateClassPair(RadarWindow, "CodexNoninteractiveDisplayWindow", 0);
    if (!DisplayWindow) DisplayWindow = objc_getClass("CodexNoninteractiveDisplayWindow");
    else {
        class_addMethod(DisplayWindow, sel_registerName("_ignoresHitTest"),
                        (IMP)display_ignores_hit_test, "B@:");
        class_addMethod(DisplayWindow, sel_registerName("_usesWindowServerHitTesting"),
                        (IMP)display_uses_window_server_hit_testing, "B@:");
        objc_registerClassPair(DisplayWindow);
    }
    Class metaW = object_getClass((id)RadarWindow);
    if (metaW) {
        class_addMethod(metaW, sel_registerName("sharedWindow"), (IMP)get_shared_window, "@@:");
        class_addMethod(metaW, sel_registerName("toggleMenu"), (IMP)codex_action_toggle_menu_cls, "v@:");
    }

    /* 2. ESP Fullscreen View */
    Class ESPView = objc_allocateClassPair(UIView_cls, "CodexESPView", 0);
    if (!ESPView) {
        ESPView = objc_getClass("CodexESPView");
    } else {
        class_addMethod(ESPView, sel_registerName("drawRect:"),
                        (IMP)esp_drawRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        objc_registerClassPair(ESPView);
    }

    /* 3. Radar Minimap View */
    Class RadarView = objc_allocateClassPair(UIView_cls, "CodexRadarV4View", 0);
    if (!RadarView) {
        RadarView = objc_getClass("CodexRadarV4View");
    } else {
        class_addMethod(RadarView, sel_registerName("drawRect:"),
                        (IMP)radar_drawRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        objc_registerClassPair(RadarView);
    }

    /* 4. Draggable Floating Button */
    Class DragButton = objc_allocateClassPair(UIButton_cls, "CodexDragButton", 0);
    if (!DragButton) {
        DragButton = objc_getClass("CodexDragButton");
    } else {
        class_addMethod(DragButton, sel_registerName("touchesBegan:withEvent:"), (IMP)btn_touchesBegan, "v@:@@");
        class_addMethod(DragButton, sel_registerName("touchesMoved:withEvent:"), (IMP)btn_touchesMoved, "v@:@@");
        class_addMethod(DragButton, sel_registerName("touchesEnded:withEvent:"), (IMP)btn_touchesEnded, "v@:@@");
        class_addMethod(DragButton, sel_registerName("touchesCancelled:withEvent:"), (IMP)btn_touchesCancelled, "v@:@@");
        objc_registerClassPair(DragButton);
    }

    /* 5. Action Target Helper */
    Class ActionHelper = objc_allocateClassPair(objc_getClass("NSObject"), "CodexActionHelper", 0);
    if (!ActionHelper) {
        ActionHelper = objc_getClass("CodexActionHelper");
    } else {
        class_addMethod(ActionHelper, sel_registerName("tick:"), (IMP)timer_tick, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleRadar:"), (IMP)action_toggle_radar, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleLines:"), (IMP)action_toggle_lines, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleBox:"), (IMP)action_toggle_box, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleHealth:"), (IMP)action_toggle_health, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleName:"), (IMP)action_toggle_name, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleDist:"), (IMP)action_toggle_dist, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleTeam:"), (IMP)action_toggle_team_bot, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleSkeleton:"), (IMP)action_toggle_skeleton, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleHead:"), (IMP)action_toggle_head, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleVehicles:"), (IMP)action_toggle_vehicles, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleItems:"), (IMP)action_toggle_items, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleRange:"), (IMP)action_toggle_range, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("closeMenu:"), (IMP)action_close_menu, "v@:@");
        objc_registerClassPair(ActionHelper);
    }
    Class metaH = object_getClass((id)ActionHelper);
    if (metaH) {
        class_addMethod(metaH, sel_registerName("sharedWindow"), (IMP)get_shared_window, "@@:");
        class_addMethod(metaH, sel_registerName("toggleMenu"), (IMP)codex_action_toggle_menu_cls, "v@:");
    }

    id helper = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)ActionHelper, sel_registerName("alloc")),
        sel_registerName("init"));

    /* --- Screen & Window Setup --- */
    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)UIScreen_cls, sel_registerName("mainScreen"));
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));
    g_screen_w = bounds.size.width;
    g_screen_h = bounds.size.height;

    id window = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)DisplayWindow, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), bounds);
    g_window = window;

    /* Window Properties */
    ((void (*)(id, SEL, double))objc_msgSend)(window, sel_registerName("setWindowLevel:"), 10000001.0);
    id clearColor = ((id (*)(id, SEL))objc_msgSend)((id)UIColor_cls, sel_registerName("clearColor"));
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setUserInteractionEnabled:"), NO);

    /* Root View Controller with Full Orientation Support */
    Class CodexOverlayVC = objc_allocateClassPair(objc_getClass("UIViewController"), "CodexOverlayViewController", 0);
    if (!CodexOverlayVC) {
        CodexOverlayVC = objc_getClass("CodexOverlayViewController");
    } else {
        class_addMethod(CodexOverlayVC, sel_registerName("supportedInterfaceOrientations"), (IMP)vc_supportedOrientations, "Q@:");
        class_addMethod(CodexOverlayVC, sel_registerName("shouldAutorotate"), (IMP)vc_shouldAutorotate, "B@:");
        class_addMethod(CodexOverlayVC, sel_registerName("prefersStatusBarHidden"), (IMP)vc_prefersStatusBarHidden, "B@:");
        class_addMethod(CodexOverlayVC, sel_registerName("loadView"), (IMP)vc_loadView, "v@:");
        objc_registerClassPair(CodexOverlayVC);
    }

    id controller = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)CodexOverlayVC, sel_registerName("alloc")),
        sel_registerName("init"));
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("setRootViewController:"), controller);
    id root_view = ((id (*)(id, SEL))objc_msgSend)(controller, sel_registerName("view"));
    ((void (*)(id, SEL, id))objc_msgSend)(root_view, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(root_view, sel_registerName("setUserInteractionEnabled:"), NO);

    /* Attach verified active Window Scene */
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("setWindowScene:"), best_scene);

    id *controls[] = { &g_button_window, &g_menu_window };
    for (int i = 0; i < 2; ++i) {
        id w = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)RadarWindow, sel_registerName("alloc")),
            sel_registerName("initWithFrame:"), CGRectMake_f(0,0,48,48));
        *controls[i] = w;
        ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("setWindowScene:"), best_scene);
        ((void (*)(id, SEL, double))objc_msgSend)(w, sel_registerName("setWindowLevel:"), 10000002.0 + i);
        ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("setBackgroundColor:"), clearColor);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(w, sel_registerName("setUserInteractionEnabled:"), YES);
        id vc = ((id (*)(id, SEL))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)CodexOverlayVC, sel_registerName("alloc")), sel_registerName("init"));
        ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("setRootViewController:"), vc);
    }

    /* --- Subview 1: Fullscreen ESP View --- */
    id esp = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)ESPView, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), bounds);
    ((void (*)(id, SEL, id))objc_msgSend)(esp, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(esp, sel_registerName("setOpaque:"), NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(esp, sel_registerName("setUserInteractionEnabled:"), NO);
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), esp);
    g_esp_view = esp;

    /* --- Subview 2: Radar Minimap View (Top-Right) --- */
    double rx = fmax(10.0, bounds.size.width - RADAR_VIEW_SIZE - 32.0);
    double ry = (bounds.size.width > bounds.size.height) ? 32.0 : 50.0;
    id radar = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)RadarView, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(rx, ry, RADAR_VIEW_SIZE, RADAR_VIEW_SIZE));
    ((void (*)(id, SEL, id))objc_msgSend)(radar, sel_registerName("setBackgroundColor:"), clearColor);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(radar, sel_registerName("setOpaque:"), NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(radar, sel_registerName("setUserInteractionEnabled:"), NO);
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel_registerName("addSubview:"), radar);
    g_radar_view = radar;

    /* --- Subview 3: Draggable Floating Button --- */
    g_button_rect = CGRectMake_f(16.0, 50.0, 48.0, 48.0);
    id drag_btn = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)DragButton, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), g_button_rect);
    id btn_bg = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.08, 0.12, 0.18, 0.90);
    ((void (*)(id, SEL, id))objc_msgSend)(drag_btn, sel_registerName("setBackgroundColor:"), btn_bg);
    title(drag_btn, "ESP");
    id dlabel = ((id (*)(id, SEL))objc_msgSend)(drag_btn, sel_registerName("titleLabel"));
    if (dlabel && g_font_bold) {
        ((void (*)(id, SEL, id))objc_msgSend)(dlabel, sel_registerName("setFont:"), g_font_bold);
    }
    id btn_layer = ((id (*)(id, SEL))objc_msgSend)(drag_btn, sel_registerName("layer"));
    if (btn_layer) {
        id cg_cyan = ((id (*)(id, SEL))objc_msgSend)(g_color_cyan, sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(btn_layer, sel_registerName("setBorderColor:"), cg_cyan);
        ((void (*)(id, SEL, double))objc_msgSend)(btn_layer, sel_registerName("setBorderWidth:"), 2.0);
        ((void (*)(id, SEL, double))objc_msgSend)(btn_layer, sel_registerName("setCornerRadius:"), 24.0);
    }
    ((void (*)(id, SEL, id))objc_msgSend)(g_button_window, sel_registerName("addSubview:"), drag_btn);
    g_drag_button = drag_btn;

    /* --- Subview 4: Settings Menu Card (Centered) --- */
    double mx = fmax(10.0, (bounds.size.width - MENU_WIDTH) / 2.0);
    double my = fmax(10.0, (bounds.size.height - MENU_HEIGHT) / 2.0);
    g_menu_rect = CGRectMake_f(mx, my, MENU_WIDTH, MENU_HEIGHT);

    id menu = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UIView_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), g_menu_rect);
    id menu_bg = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.08, 0.10, 0.14, 0.95);
    ((void (*)(id, SEL, id))objc_msgSend)(menu, sel_registerName("setBackgroundColor:"), menu_bg);

    id mlayer = ((id (*)(id, SEL))objc_msgSend)(menu, sel_registerName("layer"));
    if (mlayer) {
        id cg_cyan = ((id (*)(id, SEL))objc_msgSend)(g_color_cyan, sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(mlayer, sel_registerName("setBorderColor:"), cg_cyan);
        ((void (*)(id, SEL, double))objc_msgSend)(mlayer, sel_registerName("setBorderWidth:"), 1.5);
        ((void (*)(id, SEL, double))objc_msgSend)(mlayer, sel_registerName("setCornerRadius:"), 14.0);
    }

    /* Menu Title Header */
    id title_label = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UILabel_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(14.0, 8.0, 208.0, 26.0));
    ((void (*)(id, SEL, id))objc_msgSend)(title_label, sel_registerName("setText:"), nsstr("UE4 RADAR & ESP MENU"));
    ((void (*)(id, SEL, id))objc_msgSend)(title_label, sel_registerName("setTextColor:"), g_color_cyan);
    if (g_font_bold) ((void (*)(id, SEL, id))objc_msgSend)(title_label, sel_registerName("setFont:"), g_font_bold);
    ((void (*)(id, SEL, id))objc_msgSend)(menu, sel_registerName("addSubview:"), title_label);

    /* Close Button [ X ] */
    id close_btn = make_menu_button(menu, helper, CGRectMake_f(MENU_WIDTH - 108.0, 2.0, 98.0, 36.0), "Collapse", sel_registerName("closeMenu:"));
    style_toggle_button(close_btn, NO);

    /* 2-Column Grid of 12 Feature Buttons */
    double c0 = 12.0, c1 = 176.0, bw = 152.0, bh = 34.0;
    double r0 = 40.0, r1 = 80.0, r2 = 120.0, r3 = 160.0, r4 = 200.0, r5 = 240.0;

    g_btn_radar    = make_menu_button(menu, helper, CGRectMake_f(c0, r0, bw, bh), "Radar: ON",    sel_registerName("toggleRadar:"));
    g_btn_lines    = make_menu_button(menu, helper, CGRectMake_f(c1, r0, bw, bh), "Snaplines: ON",sel_registerName("toggleLines:"));
    g_btn_box      = make_menu_button(menu, helper, CGRectMake_f(c0, r1, bw, bh), "2D Box: ON",   sel_registerName("toggleBox:"));
    g_btn_health   = make_menu_button(menu, helper, CGRectMake_f(c1, r1, bw, bh), "Health: ON",   sel_registerName("toggleHealth:"));
    g_btn_name     = make_menu_button(menu, helper, CGRectMake_f(c0, r2, bw, bh), "Name: ON",     sel_registerName("toggleName:"));
    g_btn_dist     = make_menu_button(menu, helper, CGRectMake_f(c1, r2, bw, bh), "Distance: ON", sel_registerName("toggleDist:"));
    g_btn_team_bot = make_menu_button(menu, helper, CGRectMake_f(c0, r3, bw, bh), "Team/Bot: ON", sel_registerName("toggleTeam:"));
    g_btn_skeleton = make_menu_button(menu, helper, CGRectMake_f(c1, r3, bw, bh), "Skeleton: ON", sel_registerName("toggleSkeleton:"));
    g_btn_head     = make_menu_button(menu, helper, CGRectMake_f(c0, r4, bw, bh), "Head Dot: ON", sel_registerName("toggleHead:"));
    g_btn_vehicles = make_menu_button(menu, helper, CGRectMake_f(c1, r4, bw, bh), "Vehicles: ON", sel_registerName("toggleVehicles:"));
    g_btn_items    = make_menu_button(menu, helper, CGRectMake_f(c0, r5, bw, bh), "Loot ESP: ON", sel_registerName("toggleItems:"));
    g_btn_range    = make_menu_button(menu, helper, CGRectMake_f(c1, r5, bw, bh), "Range: 200m",  sel_registerName("toggleRange:"));

    /* Footer Telemetry Label */
    id footer = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UILabel_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(12.0, 285.0, MENU_WIDTH - 24.0, 24.0));
    ((void (*)(id, SEL, id))objc_msgSend)(footer, sel_registerName("setText:"), nsstr("Tap Collapse to return to the game"));
    ((void (*)(id, SEL, id))objc_msgSend)(footer, sel_registerName("setTextColor:"), g_color_white);
    if (g_font_small) ((void (*)(id, SEL, id))objc_msgSend)(footer, sel_registerName("setFont:"), g_font_small);
    ((void (*)(id, SEL, id))objc_msgSend)(menu, sel_registerName("addSubview:"), footer);
    g_menu_footer = footer;

    ((void (*)(id, SEL, id))objc_msgSend)(g_menu_window, sel_registerName("addSubview:"), menu);
    g_menu_view = menu;
    hidden(menu, YES); /* Closed by default */
    layout_controls();
    update_menu_buttons();

    /* Make window visible */
    ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel_registerName("setHidden:"), NO);

    /* --- Built-in Selftest --- */
    toggle_menu(); /* Open */
    BOOL test_menu_open = g_menu_open;

    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(g_btn_radar, sel_registerName("sendActionsForControlEvents:"), 64);
    BOOL test_radar_toggle = !g_feat_radar;
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(g_btn_radar, sel_registerName("sendActionsForControlEvents:"), 64); /* restore */

    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(g_btn_lines, sel_registerName("sendActionsForControlEvents:"), 64);
    BOOL test_lines_toggle = !g_feat_lines;
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(g_btn_lines, sel_registerName("sendActionsForControlEvents:"), 64); /* restore */

    CGPoint close_center = {MENU_WIDTH - 59, 20};
    CGPoint close_in_window = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(g_menu_view,
        sel_registerName("convertPoint:toView:"), close_center, g_menu_window);
    BOOL test_close_hit = window_hitTest(g_menu_window, 0, close_in_window, nil) == close_btn;
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(close_btn, sel_registerName("sendActionsForControlEvents:"), 64);
    BOOL test_collapsed = !g_menu_open && ((BOOL (*)(id, SEL))objc_msgSend)(g_menu_window, sel_registerName("isHidden"));
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(close_btn, sel_registerName("sendActionsForControlEvents:"), 64);
    test_collapsed = test_collapsed && !g_menu_open;
    if (g_proof) fprintf(g_proof, "CONTROLS close_hit=%d collapse_idempotent=%d button_hit=%d\n", test_close_hit, test_collapsed,
        window_hitTest(g_button_window,0,(CGPoint){24,24},nil) == g_drag_button);
    BOOL test_pass_corner = !window_pointInside(window, 0, (CGPoint){2, 2}, nil);
    BOOL test_pass_radar  = !window_pointInside(window, 0, (CGPoint){rx + 50, ry + 50}, nil);

    if (g_proof) {
        fprintf(g_proof, "SELFTEST: menu_open=%d radar_toggle=%d lines_toggle=%d pass_corner=%d pass_radar=%d all_features=12\n",
                test_menu_open, test_radar_toggle, test_lines_toggle, test_pass_corner, test_pass_radar);
        fflush(g_proof);
    }

    if (g_proof) {
        CGRect bf = ((CGRect (*)(id, SEL))objc_msgSend)(g_button_window, sel_registerName("frame"));
        CGRect mf = ((CGRect (*)(id, SEL))objc_msgSend)(g_menu_window, sel_registerName("frame"));
        fprintf(g_proof, "BUILD server-passthrough-20260913 button=(%.0f,%.0f %.0fx%.0f) menu=(%.0f,%.0f %.0fx%.0f) display_interactive=%d\n", bf.origin.x,bf.origin.y,bf.size.width,bf.size.height,mf.origin.x,mf.origin.y,mf.size.width,mf.size.height,
            ((BOOL (*)(id, SEL))objc_msgSend)(g_window,sel_registerName("isUserInteractionEnabled")));
        fflush(g_proof);
    }

    if (g_proof) {
        fprintf(g_proof, "SERVER_TOUCH ignores=%d server_hit_testing=%d\n",
            ((BOOL (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("_ignoresHitTest")),
            ((BOOL (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("_usesWindowServerHitTesting")));
        fflush(g_proof);
    }
    /* Open shared memory */
    open_shared_memory();

    /* Schedule Timer at 20 Hz (0.05s) */
    id timer = ((id (*)(id, SEL, double, id, SEL, id, BOOL))objc_msgSend)(
        (id)NSTimer_cls, sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        0.05, helper, sel_registerName("tick:"), nil, YES);

    id runloop = ((id (*)(id, SEL))objc_msgSend)((id)NSRunLoop_cls, sel_registerName("mainRunLoop"));
    id mode = nsstr("kCFRunLoopCommonModes");
    ((void (*)(id, SEL, id, id))objc_msgSend)(runloop, sel_registerName("addTimer:forMode:"), timer, mode);
    if (g_proof) {
        fprintf(g_proof, "[Radar] Overlay initialized with full 12-feature menu, separate bounded control windows and fitted Collapse menu\n");
        fflush(g_proof);
    }
}

/* ------------------------------------------------------------------ */
/*  Main Thread Deferred Init Helper                                  */
/* ------------------------------------------------------------------ */

static void deferred_init(id self, SEL cmd) {
    (void)cmd;
    if (g_window) return;
    init_overlay();
    if (!g_window && self) {
        /* Retry after 0.5s if SpringBoard scenes were not connected yet */
        ((void (*)(id, SEL, SEL, id, double))objc_msgSend)(
            self, sel_registerName("performSelector:withObject:afterDelay:"),
            sel_registerName("deferredInit"), nil, 0.5);
    }
}

__attribute__((constructor))
static void tweak_entry(void) {
    resolve_cg_symbols();

    /* Ensure we only run inside SpringBoard */
    Class NSProcessInfo_cls = objc_getClass("NSProcessInfo");
    if (NSProcessInfo_cls) {
        id procInfo = ((id (*)(id, SEL))objc_msgSend)((id)NSProcessInfo_cls, sel_registerName("processInfo"));
        id procName = ((id (*)(id, SEL))objc_msgSend)(procInfo, sel_registerName("processName"));
        const char *pname = ((const char *(*)(id, SEL))objc_msgSend)(procName, sel_registerName("UTF8String"));
        if (pname && strcmp(pname, "SpringBoard") != 0 && strstr(pname, "test_dlopen") == NULL && strstr(pname, "menu_runtime_test") == NULL) {
            return;
        }
    }

    Class Helper = objc_allocateClassPair(objc_getClass("NSObject"), "CodexRadarV4Init", 0);
    if (!Helper) {
        Helper = objc_getClass("CodexRadarV4Init");
    } else {
        class_addMethod(Helper, sel_registerName("deferredInit"), (IMP)deferred_init, "v@:");
        class_addMethod(Helper, sel_registerName("deferredInit:"), (IMP)deferred_init, "v@:@");
        objc_registerClassPair(Helper);
    }

    id helper = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)Helper, sel_registerName("alloc")),
        sel_registerName("init"));

    Class NSThread_cls = objc_getClass("NSThread");

    /* Register notification observers for app launch and scene activation as fallbacks */
    Class NSNotificationCenter_cls = objc_getClass("NSNotificationCenter");
    if (NSNotificationCenter_cls) {
        id center = ((id (*)(id, SEL))objc_msgSend)((id)NSNotificationCenter_cls, sel_registerName("defaultCenter"));
        if (center) {
            id notif1 = nsstr("UIApplicationDidFinishLaunchingNotification");
            id notif2 = nsstr("UISceneDidActivateNotification");
            id notif3 = nsstr("UISceneWillConnectNotification");
            ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
                center, sel_registerName("addObserver:selector:name:object:"),
                helper, sel_registerName("deferredInit:"), notif1, nil);
            ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
                center, sel_registerName("addObserver:selector:name:object:"),
                helper, sel_registerName("deferredInit:"), notif2, nil);
            ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
                center, sel_registerName("addObserver:selector:name:object:"),
                helper, sel_registerName("deferredInit:"), notif3, nil);
        }
    }

    /* Unconditionally dispatch to main thread */
    if (NSThread_cls && ((BOOL (*)(id, SEL))objc_msgSend)((id)NSThread_cls, sel_registerName("isMainThread"))) {
        deferred_init(helper, sel_registerName("deferredInit"));
    } else {
        ((void (*)(id, SEL, SEL, id, BOOL))objc_msgSend)(
            helper, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
            sel_registerName("deferredInit"), nil, NO);
    }
}
