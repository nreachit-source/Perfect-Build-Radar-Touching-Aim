/*
 * radar_overlay.m — SpringBoard tweak: radar minimap overlay.
 *
 * Reads the shared mmap'd file written by the ue4loadmonitor daemon
 * and renders a circular radar minimap showing nearby players with
 * health indicators.
 *
 * Uses raw ObjC runtime calls (no Apple SDK headers required) so it
 * compiles with Zig's cross-compiler.
 *
 * Rules:
 *   - Never #include <syslog.h>
 *   - Never call dispatch_get_main_queue() in C
 *   - Attach windowScene from connectedScenes
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/*  ObjC runtime (no SDK headers needed)                              */
/* ------------------------------------------------------------------ */

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef void (*IMP)(void);
typedef struct objc_method *Method;
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef int BOOL;

#define YES 1
#define NO  0
#define nil ((id)0)

extern Class objc_getClass(const char *name);
extern Class objc_allocateClassPair(Class superclass, const char *name, size_t extra);
extern void  objc_registerClassPair(Class cls);
extern BOOL  class_addMethod(Class cls, SEL sel, IMP imp, const char *types);
extern BOOL  class_addIvar(Class cls, const char *name, size_t size, uint8_t alignment, const char *types);
extern id    objc_msgSend(id self, SEL op, ...);
extern SEL   sel_registerName(const char *str);

/* CGGeometry */
typedef struct { float x, y; } CGPoint;
typedef struct { float width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

static CGRect CGRectMake_f(float x, float y, float w, float h) {
    CGRect r = {{x, y}, {w, h}};
    return r;
}

/* CoreGraphics context functions (linked at runtime) */
typedef void *CGContextRef;

extern CGContextRef UIGraphicsGetCurrentContext(void);
extern void CGContextSetRGBFillColor(CGContextRef c, float r, float g, float b, float a);
extern void CGContextSetRGBStrokeColor(CGContextRef c, float r, float g, float b, float a);
extern void CGContextFillEllipseInRect(CGContextRef c, CGRect rect);
extern void CGContextStrokeEllipseInRect(CGContextRef c, CGRect rect);
extern void CGContextSetLineWidth(CGContextRef c, float w);
extern void CGContextMoveToPoint(CGContextRef c, float x, float y);
extern void CGContextAddLineToPoint(CGContextRef c, float x, float y);
extern void CGContextStrokePath(CGContextRef c);
extern void CGContextAddArc(CGContextRef c, float x, float y, float radius,
                             float startAngle, float endAngle, int clockwise);
extern void CGContextFillRect(CGContextRef c, CGRect rect);

/* NSLog */
extern void NSLog(id format, ...);

/* Helper: create NSString from C string */
static id nsstr(const char *s) {
    return objc_msgSend((id)objc_getClass("NSString"),
                        sel_registerName("stringWithUTF8String:"), s);
}

/* ------------------------------------------------------------------ */
/*  Shared data format (must match daemon's radar_data.h)             */
/* ------------------------------------------------------------------ */

#define RADAR_FILE_PATH   "/var/mobile/Downloads/ue4_radar.bin"
#define RADAR_MAGIC       0x52444152
#define RADAR_MAX_PLAYERS 100
#define RADAR_NUM_BONES   20

typedef struct { float x, y, z; } rvec3_t;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t tick;
    uint32_t player_count;
    rvec3_t  local_pos;
    rvec3_t  local_rot;
    float    camera_fov;
    float    _pad[3];
} radar_header_t;

typedef struct {
    rvec3_t  pos;
    float    health;
    float    health_max;
    float    yaw;
    uint8_t  team_id;
    uint8_t  is_bot;
    uint8_t  is_visible;
    uint8_t  health_status;
    uint8_t  has_bones;
    uint8_t  _pad[3];
    rvec3_t  bones[RADAR_NUM_BONES];
} radar_player_t;

typedef struct {
    radar_header_t header;
    radar_player_t players[RADAR_MAX_PLAYERS];
} radar_shared_t;

/* ------------------------------------------------------------------ */
/*  Radar configuration                                               */
/* ------------------------------------------------------------------ */

#define RADAR_SIZE       200.0f
#define RADAR_MARGIN     16.0f
#define RADAR_BG_ALPHA   0.55f
#define RADAR_RANGE      20000.0f  /* 200m in UE units */
#define DOT_SIZE         6.0f
#define RING_WIDTH       2.0f

/* ------------------------------------------------------------------ */
/*  Shared memory reader                                              */
/* ------------------------------------------------------------------ */

static int             g_shm_fd   = -1;
static radar_shared_t *g_shared   = NULL;
static uint32_t        g_last_tick = 0;

static BOOL open_shared_memory(void) {
    if (g_shared) return YES;

    g_shm_fd = open(RADAR_FILE_PATH, O_RDONLY);
    if (g_shm_fd < 0) return NO;

    struct stat st;
    if (fstat(g_shm_fd, &st) != 0 ||
        st.st_size < (off_t)sizeof(radar_shared_t)) {
        close(g_shm_fd);
        g_shm_fd = -1;
        return NO;
    }

    g_shared = (radar_shared_t *)mmap(NULL, sizeof(radar_shared_t),
                                       PROT_READ, MAP_SHARED,
                                       g_shm_fd, 0);
    if (g_shared == MAP_FAILED) {
        g_shared = NULL;
        close(g_shm_fd);
        g_shm_fd = -1;
        return NO;
    }

    NSLog(nsstr("[Radar] Shared memory opened (%zu bytes)"),
          sizeof(radar_shared_t));
    return YES;
}

/* ------------------------------------------------------------------ */
/*  RadarView: custom UIView subclass for drawing                     */
/* ------------------------------------------------------------------ */

static void radar_drawRect(id self, SEL _cmd, CGRect rect) {
    if (!g_shared || g_shared->header.magic != RADAR_MAGIC) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    float radius = RADAR_SIZE / 2.0f;
    float cx = radius, cy = radius;
    float scale = radius / RADAR_RANGE;

    /* Background circle */
    CGContextSetRGBFillColor(ctx, 0.05f, 0.05f, 0.1f, RADAR_BG_ALPHA);
    CGContextFillEllipseInRect(ctx, CGRectMake_f(0, 0, RADAR_SIZE, RADAR_SIZE));

    /* Grid rings */
    CGContextSetRGBStrokeColor(ctx, 0.3f, 0.3f, 0.4f, 0.4f);
    CGContextSetLineWidth(ctx, 0.5f);
    for (int i = 1; i <= 3; i++) {
        float r = radius * (float)i / 3.0f;
        CGContextStrokeEllipseInRect(ctx,
            CGRectMake_f(cx - r, cy - r, r * 2, r * 2));
    }

    /* Cross hair */
    CGContextMoveToPoint(ctx, cx, 0);
    CGContextAddLineToPoint(ctx, cx, RADAR_SIZE);
    CGContextMoveToPoint(ctx, 0, cy);
    CGContextAddLineToPoint(ctx, RADAR_SIZE, cy);
    CGContextStrokePath(ctx);

    /* Local player dot */
    CGContextSetRGBFillColor(ctx, 0.2f, 0.9f, 1.0f, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake_f(cx - 3, cy - 3, 6, 6));

    /* Camera yaw rotation */
    float cam_yaw_rad = -g_shared->header.local_rot.y * (float)M_PI / 180.0f;
    float cos_yaw = cosf(cam_yaw_rad);
    float sin_yaw = sinf(cam_yaw_rad);

    rvec3_t lp = g_shared->header.local_pos;
    uint32_t count = g_shared->header.player_count;
    if (count > RADAR_MAX_PLAYERS) count = RADAR_MAX_PLAYERS;

    for (uint32_t i = 0; i < count; i++) {
        const radar_player_t *p = &g_shared->players[i];

        /* Skip dead */
        if (p->health_status == 2) continue;
        if (p->health <= 0 && p->health_max > 0) continue;

        /* World delta */
        float dx = p->pos.x - lp.x;
        float dy = p->pos.y - lp.y;

        /* Rotate by camera yaw */
        float rx = dx * cos_yaw - dy * sin_yaw;
        float ry = dx * sin_yaw + dy * cos_yaw;

        /* Scale to radar */
        float sx = rx * scale;
        float sy = -ry * scale;

        /* Clamp to circle */
        float dist = sqrtf(sx * sx + sy * sy);
        if (dist > radius - DOT_SIZE) {
            float clamp = (radius - DOT_SIZE) / dist;
            sx *= clamp;
            sy *= clamp;
        }

        float dotx = cx + sx;
        float doty = cy + sy;

        /* Color: knocked=orange, alive=red */
        if (p->health_status == 1) {
            CGContextSetRGBFillColor(ctx, 1.0f, 0.6f, 0.0f, 1.0f);
        } else {
            CGContextSetRGBFillColor(ctx, 1.0f, 0.15f, 0.15f, 1.0f);
        }

        /* Player dot */
        CGContextFillEllipseInRect(ctx,
            CGRectMake_f(dotx - DOT_SIZE/2, doty - DOT_SIZE/2,
                          DOT_SIZE, DOT_SIZE));

        /* Health ring */
        if (p->health_max > 0) {
            float hp = p->health / p->health_max;
            if (hp > 1.0f) hp = 1.0f;
            if (hp < 0.0f) hp = 0.0f;

            CGContextSetRGBStrokeColor(ctx, 1.0f - hp, hp, 0.0f, 0.8f);
            CGContextSetLineWidth(ctx, RING_WIDTH);
            float ring_r = DOT_SIZE / 2 + 2;
            float start = -(float)M_PI / 2.0f;
            float end   = start + hp * 2.0f * (float)M_PI;
            CGContextAddArc(ctx, dotx, doty, ring_r, start, end, 0);
            CGContextStrokePath(ctx);
        }
    }

    /* View cone indicator */
    CGContextSetRGBStrokeColor(ctx, 0.2f, 0.9f, 1.0f, 0.3f);
    CGContextSetLineWidth(ctx, 1.0f);
    float cone_half = 30.0f * (float)M_PI / 180.0f;
    float cone_len = radius * 0.8f;
    float cl_x = cx + sinf(-cone_half) * cone_len;
    float cl_y = cy - cosf(-cone_half) * cone_len;
    float cr_x = cx + sinf(cone_half) * cone_len;
    float cr_y = cy - cosf(cone_half) * cone_len;
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cl_x, cl_y);
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, cr_x, cr_y);
    CGContextStrokePath(ctx);
}

/* ------------------------------------------------------------------ */
/*  RadarWindow: UIWindow subclass with touch pass-through            */
/* ------------------------------------------------------------------ */

static id g_radar_view = nil;

static BOOL window_pointInside(id self, SEL _cmd, CGPoint point, id event) {
    /* Pass all touches through — radar is display-only */
    (void)self; (void)_cmd; (void)point; (void)event;
    return NO;
}

/* ------------------------------------------------------------------ */
/*  Timer callback: refresh radar                                     */
/* ------------------------------------------------------------------ */

static int g_frame_counter = 0;

static void timer_tick(id self, SEL _cmd, id timer) {
    (void)self; (void)_cmd; (void)timer;
    g_frame_counter++;

    if (!g_shared) {
        if (g_frame_counter % 40 == 0) {
            open_shared_memory();
        }
        return;
    }

    uint32_t tick = g_shared->header.tick;
    if (tick != g_last_tick) {
        g_last_tick = tick;
        if (g_radar_view) {
            objc_msgSend(g_radar_view, sel_registerName("setNeedsDisplay"));
        }
    }
}

/* ------------------------------------------------------------------ */
/*  Setup                                                             */
/* ------------------------------------------------------------------ */

static void init_overlay(void) {
    Class UIWindow_cls   = objc_getClass("UIWindow");
    Class UIView_cls     = objc_getClass("UIView");
    Class UIScreen_cls   = objc_getClass("UIScreen");
    Class UIColor_cls    = objc_getClass("UIColor");
    Class UIApp_cls      = objc_getClass("UIApplication");
    Class UIWindowScene  = objc_getClass("UIWindowScene");
    Class NSTimer_cls    = objc_getClass("NSTimer");
    Class NSRunLoop_cls  = objc_getClass("NSRunLoop");

    /* --- Register RadarView subclass --- */
    Class RadarView = objc_allocateClassPair(UIView_cls, "RadarView", 0);
    if (!RadarView) {
        /* Already registered from previous injection */
        RadarView = objc_getClass("RadarView");
    } else {
        class_addMethod(RadarView, sel_registerName("drawRect:"),
                        (IMP)radar_drawRect, "v@:{CGRect=ffff}");
        objc_registerClassPair(RadarView);
    }

    /* --- Register RadarWindow subclass --- */
    Class RadarWindow = objc_allocateClassPair(UIWindow_cls, "RadarWindow", 0);
    if (!RadarWindow) {
        RadarWindow = objc_getClass("RadarWindow");
    } else {
        class_addMethod(RadarWindow, sel_registerName("pointInside:withEvent:"),
                        (IMP)window_pointInside, "B@:{CGPoint=ff}@");
        objc_registerClassPair(RadarWindow);
    }

    /* --- Get screen bounds --- */
    id mainScreen = objc_msgSend((id)UIScreen_cls,
                                 sel_registerName("mainScreen"));
    CGRect bounds;
    typedef CGRect (*bounds_fn)(id, SEL);
    bounds = ((bounds_fn)objc_msgSend)(mainScreen,
                                       sel_registerName("bounds"));

    /* --- Create window --- */
    typedef id (*initFrame_fn)(id, SEL, CGRect);
    id window = ((initFrame_fn)objc_msgSend)(
        objc_msgSend((id)RadarWindow, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), bounds);

    /* windowLevel = 10000001 */
    typedef void (*setLevel_fn)(id, SEL, double);
    ((setLevel_fn)objc_msgSend)(window,
        sel_registerName("setWindowLevel:"), 10000001.0);

    /* backgroundColor = clear */
    id clearColor = objc_msgSend((id)UIColor_cls,
                                  sel_registerName("clearColor"));
    objc_msgSend(window, sel_registerName("setBackgroundColor:"), clearColor);

    /* userInteractionEnabled = YES */
    typedef void (*setBool_fn)(id, SEL, BOOL);
    ((setBool_fn)objc_msgSend)(window,
        sel_registerName("setUserInteractionEnabled:"), YES);

    /* hidden = NO */
    ((setBool_fn)objc_msgSend)(window, sel_registerName("setHidden:"), NO);

    /* --- Attach windowScene --- */
    id app = objc_msgSend((id)UIApp_cls,
                           sel_registerName("sharedApplication"));
    id scenes = objc_msgSend(app, sel_registerName("connectedScenes"));
    id sceneEnum = objc_msgSend(scenes,
                                 sel_registerName("objectEnumerator"));
    id scene;
    while ((scene = objc_msgSend(sceneEnum,
                                  sel_registerName("nextObject")))) {
        BOOL isWindowScene = (BOOL)(NSInteger)objc_msgSend(scene,
            sel_registerName("isKindOfClass:"), UIWindowScene);
        if (isWindowScene) {
            objc_msgSend(window,
                sel_registerName("setWindowScene:"), scene);
            break;
        }
    }

    /* --- Create radar view — top-right corner --- */
    float vx = bounds.size.width - RADAR_SIZE - RADAR_MARGIN;
    float vy = 50.0f;
    CGRect radarFrame = CGRectMake_f(vx, vy, RADAR_SIZE, RADAR_SIZE);
    id radarView = ((initFrame_fn)objc_msgSend)(
        objc_msgSend((id)RadarView, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), radarFrame);

    objc_msgSend(radarView, sel_registerName("setBackgroundColor:"), clearColor);
    ((setBool_fn)objc_msgSend)(radarView,
        sel_registerName("setOpaque:"), NO);

    g_radar_view = radarView;
    objc_msgSend(window, sel_registerName("addSubview:"), radarView);
    objc_msgSend(window, sel_registerName("makeKeyAndVisible"));

    /* --- Register timer helper class --- */
    Class TimerHelper = objc_allocateClassPair(
        objc_getClass("NSObject"), "RadarTimerHelper", 0);
    if (!TimerHelper) {
        TimerHelper = objc_getClass("RadarTimerHelper");
    } else {
        class_addMethod(TimerHelper, sel_registerName("tick:"),
                        (IMP)timer_tick, "v@:@");
        objc_registerClassPair(TimerHelper);
    }

    id helper = objc_msgSend(
        objc_msgSend((id)TimerHelper, sel_registerName("alloc")),
        sel_registerName("init"));

    /* Schedule repeating timer at 20 Hz (0.05s) */
    typedef id (*timer_fn)(id, SEL, double, id, SEL, id, BOOL);
    id timer = ((timer_fn)objc_msgSend)(
        (id)NSTimer_cls,
        sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        0.05, helper, sel_registerName("tick:"), nil, YES);

    id runloop = objc_msgSend((id)NSRunLoop_cls,
                               sel_registerName("currentRunLoop"));
    /* NSDefaultRunLoopMode — use the string directly */
    id mode = nsstr("kCFRunLoopCommonModes");
    objc_msgSend(runloop, sel_registerName("addTimer:forMode:"), timer, mode);

    NSLog(nsstr("[Radar] Overlay initialized at (%.0f, %.0f)"), vx, vy);
}

/* ------------------------------------------------------------------ */
/*  Deferred init helper (must run on main thread)                    */
/* ------------------------------------------------------------------ */

static void deferred_init(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    init_overlay();
}

__attribute__((constructor))
static void tweak_entry(void) {
    /* Register a helper class for performSelectorOnMainThread */
    Class Helper = objc_allocateClassPair(
        objc_getClass("NSObject"), "RadarInitHelper", 0);
    if (!Helper) {
        Helper = objc_getClass("RadarInitHelper");
    } else {
        class_addMethod(Helper, sel_registerName("deferredInit"),
                        (IMP)deferred_init, "v@:");
        objc_registerClassPair(Helper);
    }

    id helper = objc_msgSend(
        objc_msgSend((id)Helper, sel_registerName("alloc")),
        sel_registerName("init"));

    objc_msgSend(helper,
        sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
        sel_registerName("deferredInit"), nil, NO);
}
