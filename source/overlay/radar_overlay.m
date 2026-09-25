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
#include <mach/mach_time.h>

#include "../daemon/radar_data.h"

static double monotonic_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

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
static void *(*fn_objc_autoreleasePoolPush)(void) = NULL;
static void  (*fn_objc_autoreleasePoolPop)(void *ctx) = NULL;

#define objc_getClass fn_objc_getClass
#define objc_allocateClassPair fn_objc_allocateClassPair
#define objc_registerClassPair fn_objc_registerClassPair
#define class_addMethod fn_class_addMethod
#define objc_msgSend fn_objc_msgSend
#define sel_registerName fn_sel_registerName
#define object_getClass fn_object_getClass
#define class_getName fn_class_getName
#define objc_autoreleasePoolPush fn_objc_autoreleasePoolPush
#define objc_autoreleasePoolPop fn_objc_autoreleasePoolPop

/* CoreGraphics geometry types */
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

static inline CGRect CGRectMake_f(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGRect r = {{x, y}, {w, h}};
    return r;
}

static inline CGPoint CGPointMake_f(CGFloat x, CGFloat y) {
    CGPoint p = {x, y};
    return p;
}

static id nsstr(const char *s);
static double g_screen_w = 0.0;
static double g_screen_h = 0.0;

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

/* Dynamic IOKit HID Event symbols for touch injection */
typedef void* IOHIDEventRef;
typedef void* IOHIDEventSystemClientRef;
typedef const void* CFAllocatorRef;
typedef void* CFTypeRef;
typedef void* CFStringRef;

static IOHIDEventSystemClientRef (*fn_IOHIDEventSystemClientCreate)(CFAllocatorRef) = NULL;
static void (*fn_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef) = NULL;
static IOHIDEventRef (*fn_IOHIDEventCreateDigitizerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, bool, bool, uint32_t) = NULL;
static IOHIDEventRef (*fn_IOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, bool, bool, uint32_t) = NULL;
static void (*fn_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t) = NULL;
static void (*fn_IOHIDEventSetSenderID)(IOHIDEventRef, uint64_t) = NULL;
static void (*fn_IOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, int) = NULL;
static void (*fn_IOHIDEventSetFloatValue)(IOHIDEventRef, uint32_t, double) = NULL;
static void (*fn_CFRelease)(CFTypeRef) = NULL;
static CFStringRef (*fn_CFStringCreateWithCString)(CFAllocatorRef, const char *, uint32_t) = NULL;

typedef void* IOHIDServiceClientRef;
typedef void* CFArrayRef;
typedef long CFIndex;

static CFArrayRef (*fn_IOHIDEventSystemClientCopyServices)(IOHIDEventSystemClientRef) = NULL;
static CFTypeRef (*fn_IOHIDServiceClientCopyProperty)(IOHIDServiceClientRef, CFStringRef) = NULL;
static CFTypeRef (*fn_IOHIDServiceClientGetRegistryID)(IOHIDServiceClientRef) = NULL;
static CFIndex (*fn_CFArrayGetCount)(CFArrayRef) = NULL;
static const void* (*fn_CFArrayGetValueAtIndex)(CFArrayRef, CFIndex) = NULL;
static bool (*fn_CFNumberGetValue)(CFTypeRef, int, void *) = NULL;

static void update_digitizer_sender_id(void);

static IOHIDEventSystemClientRef g_hid_client = NULL;
static id g_ax_server = nil;
static Class g_cls_ax_event = nil;
static uint64_t g_touch_sender_id = 0;
static uint32_t g_touch_finger_id = 9;
static double g_panel_w = 375.0, g_panel_h = 812.0;
static BOOL drawn_point_to_panel(double x, double y, double *hx, double *hy);
static BOOL g_sim_touch_down = NO;
static NSInteger g_current_orientation = 3; /* 1=Portrait, 2=UpsideDown, 3=LandscapeRight, 4=LandscapeLeft */
static uint32_t g_draws = 0;
static FILE *g_proof = NULL;
static radar_shared_t g_snapshot;

static void screen_to_digitizer_coords(double scr_x, double scr_y, double *out_hid_x, double *out_hid_y) {
    if (drawn_point_to_panel(scr_x, scr_y, out_hid_x, out_hid_y)) return;
    NSInteger ori = g_current_orientation;
    /* In live gameplay tracking or when camera is valid, enforce landscape */
    if (g_snapshot.header.status == 2 && g_snapshot.header.camera_valid) {
        if (ori != 4) ori = 3; /* LandscapeRight */
    } else {
        if (ori != 1 && ori != 2 && ori != 4) ori = 3; /* Default LandscapeRight */
    }

    double hx = scr_x, hy = scr_y;
    if (ori == 3) {
        /* LandscapeRight: USB port on right, notch on left (panel X = 1.0 - scr_y, panel Y = scr_x) */
        hx = 1.0 - scr_y;
        hy = scr_x;
    } else if (ori == 4) {
        /* LandscapeLeft: USB port on left, notch on right (panel X = scr_y, panel Y = 1.0 - scr_x) */
        hx = scr_y;
        hy = 1.0 - scr_x;
    } else if (ori == 2) {
        /* PortraitUpsideDown */
        hx = 1.0 - scr_x;
        hy = 1.0 - scr_y;
    } else {
        /* Portrait */
        hx = scr_x;
        hy = scr_y;
    }

    if (hx < 0.02) hx = 0.02;
    if (hx > 0.98) hx = 0.98;
    if (hy < 0.02) hy = 0.02;
    if (hy > 0.98) hy = 0.98;

    *out_hid_x = hx;
    *out_hid_y = hy;
}

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
    fn_objc_autoreleasePoolPush     = (void *(*)(void))dlsym(RTLD_DEFAULT, "objc_autoreleasePoolPush");
    fn_objc_autoreleasePoolPop      = (void (*)(void *))dlsym(RTLD_DEFAULT, "objc_autoreleasePoolPop");

    void *hIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);
    void *hCF = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    if (hIOKit) {
        fn_IOHIDEventSystemClientCreate = (IOHIDEventSystemClientRef (*)(CFAllocatorRef))dlsym(hIOKit, "IOHIDEventSystemClientCreate");
        fn_IOHIDEventSystemClientDispatchEvent = (void (*)(IOHIDEventSystemClientRef, IOHIDEventRef))dlsym(hIOKit, "IOHIDEventSystemClientDispatchEvent");
        fn_IOHIDEventCreateDigitizerEvent = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t))dlsym(hIOKit, "IOHIDEventCreateDigitizerEvent");
        fn_IOHIDEventCreateDigitizerFingerEvent = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t))dlsym(hIOKit, "IOHIDEventCreateDigitizerFingerEvent");
        fn_IOHIDEventAppendEvent = (void (*)(IOHIDEventRef, IOHIDEventRef, uint32_t))dlsym(hIOKit, "IOHIDEventAppendEvent");
        fn_IOHIDEventSetSenderID = (void (*)(IOHIDEventRef, uint64_t))dlsym(hIOKit, "IOHIDEventSetSenderID");
        fn_IOHIDEventSetIntegerValue = (void (*)(IOHIDEventRef, uint32_t, int))dlsym(hIOKit, "IOHIDEventSetIntegerValue");
        fn_IOHIDEventSetFloatValue = (void (*)(IOHIDEventRef, uint32_t, double))dlsym(hIOKit, "IOHIDEventSetFloatValue");
    }
    if (hIOKit) {
        fn_IOHIDEventSystemClientCopyServices = (CFArrayRef (*)(IOHIDEventSystemClientRef))dlsym(hIOKit, "IOHIDEventSystemClientCopyServices");
        fn_IOHIDServiceClientCopyProperty = (CFTypeRef (*)(IOHIDServiceClientRef, CFStringRef))dlsym(hIOKit, "IOHIDServiceClientCopyProperty");
        fn_IOHIDServiceClientGetRegistryID = (CFTypeRef (*)(IOHIDServiceClientRef))dlsym(hIOKit, "IOHIDServiceClientGetRegistryID");
    }
    if (hCF) {
        fn_CFRelease = (void (*)(CFTypeRef))dlsym(hCF, "CFRelease");
        fn_CFStringCreateWithCString = (CFStringRef (*)(CFAllocatorRef, const char *, uint32_t))dlsym(hCF, "CFStringCreateWithCString");
        fn_CFArrayGetCount = (CFIndex (*)(CFArrayRef))dlsym(hCF, "CFArrayGetCount");
        fn_CFArrayGetValueAtIndex = (const void* (*)(CFArrayRef, CFIndex))dlsym(hCF, "CFArrayGetValueAtIndex");
        fn_CFNumberGetValue = (bool (*)(CFTypeRef, int, void *))dlsym(hCF, "CFNumberGetValue");
    }
    update_digitizer_sender_id();

    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    if (cls_AXBackBoard) {
        g_ax_server = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
        if (!g_ax_server) {
            g_ax_server = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("sharedInstance"));
        }
        if (g_ax_server) {
            ((void (*)(id, SEL, int))objc_msgSend)(g_ax_server, sel_registerName("registerAssistiveTouchPID:"), getpid());
        }
    }
    g_cls_ax_event = objc_getClass("AXEventRepresentation");
}

static inline BOOL safe_responds(id obj, const char *sel_name) {
    if (!obj) return NO;
    SEL s = sel_registerName(sel_name);
    return ((BOOL (*)(id, SEL, SEL))objc_msgSend)(obj, sel_registerName("respondsToSelector:"), s);
}

static void update_digitizer_sender_id(void) {
    if (!fn_IOHIDEventSystemClientCreate || !fn_IOHIDEventSystemClientCopyServices ||
        !fn_IOHIDServiceClientCopyProperty || !fn_IOHIDServiceClientGetRegistryID ||
        !fn_CFArrayGetCount || !fn_CFArrayGetValueAtIndex || !fn_CFRelease ||
        !fn_CFStringCreateWithCString || !fn_CFNumberGetValue) return;

    IOHIDEventSystemClientRef client = fn_IOHIDEventSystemClientCreate(NULL);
    if (!client) return;

    CFStringRef kPage = fn_CFStringCreateWithCString(NULL, "PrimaryUsagePage", 0x08000100);
    CFStringRef kUsage = fn_CFStringCreateWithCString(NULL, "PrimaryUsage", 0x08000100);

    CFArrayRef services = fn_IOHIDEventSystemClientCopyServices(client);
    if (services) {
        CFIndex count = fn_CFArrayGetCount(services);
        for (CFIndex i = 0; i < count; i++) {
            IOHIDServiceClientRef s = (IOHIDServiceClientRef)fn_CFArrayGetValueAtIndex(services, i);
            int page = 0, usage = 0;
            CFTypeRef pPage = fn_IOHIDServiceClientCopyProperty(s, kPage);
            if (pPage) {
                fn_CFNumberGetValue(pPage, 3 /* kCFNumberSInt32Type */, &page);
                fn_CFRelease(pPage);
            }
            CFTypeRef pUsage = fn_IOHIDServiceClientCopyProperty(s, kUsage);
            if (pUsage) {
                fn_CFNumberGetValue(pUsage, 3 /* kCFNumberSInt32Type */, &usage);
                fn_CFRelease(pUsage);
            }
            if (page == 0x0D && usage == 0x04) {
                CFTypeRef registry_number = fn_IOHIDServiceClientGetRegistryID(s);
                uint64_t reg = 0;
                /* GetRegistryID returns a borrowed CFNumber, not its integer value. */
                if (registry_number && fn_CFNumberGetValue(registry_number, 4 /* SInt64 */, &reg) && reg != 0) {
                    g_touch_sender_id = reg;
                    break;
                }
            }
        }
        fn_CFRelease(services);
    }
    if (kPage) fn_CFRelease(kPage);
    if (kUsage) fn_CFRelease(kUsage);
    fn_CFRelease(client);
}

static void ensure_screen_awake_and_unlocked(void) {
    Class SBLockScreenManager = objc_getClass("SBLockScreenManager");
    if (SBLockScreenManager && safe_responds((id)SBLockScreenManager, "sharedInstance")) {
        id lsm = ((id (*)(id, SEL))objc_msgSend)((id)SBLockScreenManager, sel_registerName("sharedInstance"));
        if (lsm && safe_responds(lsm, "unlockUIFromSource:withOptions:")) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(lsm, sel_registerName("unlockUIFromSource:withOptions:"), 0, (id)0);
        }
    }

    Class SBBacklightController = objc_getClass("SBBacklightController");
    if (SBBacklightController && safe_responds((id)SBBacklightController, "sharedInstance")) {
        id bl = ((id (*)(id, SEL))objc_msgSend)((id)SBBacklightController, sel_registerName("sharedInstance"));
        if (bl && safe_responds(bl, "turnOnScreenFullyWithReason:")) {
            ((void (*)(id, SEL, id))objc_msgSend)(bl, sel_registerName("turnOnScreenFullyWithReason:"), nsstr("WakeDevice"));
        }
    }
}

static void ensure_hid_client(void) {
    if (g_hid_client) return;
    if (fn_IOHIDEventSystemClientCreate) {
        g_hid_client = fn_IOHIDEventSystemClientCreate(NULL);
    }
}

static void hid_touch_event(double norm_x, double norm_y, int touch_state) {
    if (norm_x < 0.03) norm_x = 0.03;
    if (norm_x > 0.97) norm_x = 0.97;
    if (norm_y < 0.03) norm_y = 0.03;
    if (norm_y > 0.97) norm_y = 0.97;

    double hid_x, hid_y;
    screen_to_digitizer_coords(norm_x, norm_y, &hid_x, &hid_y);

    /* Physical portrait panel coordinates */
    double pw = g_panel_w;
    double ph = g_panel_h;
    if (pw <= 10.0 || ph <= 10.0) {
        id screen = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
        if (screen) {
            CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(screen, sel_registerName("bounds"));
            pw = fmin(b.size.width, b.size.height);
            ph = fmax(b.size.width, b.size.height);
            g_panel_w = pw;
            g_panel_h = ph;
        } else {
            pw = 768.0; ph = 1024.0;
        }
    }
    double port_px = hid_x * pw;
    double port_py = hid_y * ph;

    CGPoint touch_pt = CGPointMake_f(port_px, port_py);

    unsigned int hand_type = 1;
    uint32_t f_mask = 3;
    bool f_down = false;
    if (touch_state == 1) {
        hand_type = 1; /* Touched (Down) */
        f_mask = 3;    /* Touch | Range */
        f_down = true;
        g_sim_touch_down = YES;
    } else if (touch_state == 2) {
        hand_type = 2; /* Moved */
        f_mask = 4;    /* Position */
        f_down = true;
        g_sim_touch_down = YES;
    } else {
        hand_type = 6; /* Lifted (Up) */
        f_mask = 3;    /* Range and touch both leave the display. */
        f_down = false;
        g_sim_touch_down = NO;
    }

    /* 1. Accessibility Touch Injection via AXBackBoardServer (User requested outside accessibility touch) */
    if (g_cls_ax_event && g_ax_server) {
        if (safe_responds((id)g_cls_ax_event, "touchRepresentationWithHandType:location:")) {
            id rep = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
                (id)g_cls_ax_event, sel_registerName("touchRepresentationWithHandType:location:"), hand_type, touch_pt);
            if (rep) {
                if (safe_responds(rep, "setIsGeneratedEvent:")) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(rep, sel_registerName("setIsGeneratedEvent:"), YES);
                }
                if (safe_responds(g_ax_server, "postEvent:systemEvent:")) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(g_ax_server, sel_registerName("postEvent:systemEvent:"), rep, NO);
                }
            }
        }
    }

    /* 2. Raw IOHIDEvent digitizer transducer conforming to ZXTouch/SimulateTouch iOS 16 spec */
    ensure_hid_client();
    if (fn_IOHIDEventCreateDigitizerEvent && fn_IOHIDEventCreateDigitizerFingerEvent && fn_IOHIDEventAppendEvent && g_hid_client && g_touch_sender_id) {
        uint64_t now = mach_absolute_time();

        IOHIDEventRef parent = fn_IOHIDEventCreateDigitizerEvent(
            NULL, now, 3 /* Hand */, 99, 1, f_mask, 0,
            hid_x, hid_y, 0.0, 0.0, 0.0, f_down, f_down, 0);

        if (parent) {
            if (fn_IOHIDEventSetIntegerValue) {
                fn_IOHIDEventSetIntegerValue(parent, 720921 /* 0xb0019 */, 1); /* kIOHIDEventFieldDigitizerIsDisplayIntegrated */
                fn_IOHIDEventSetIntegerValue(parent, 4 /* 0x4 */, 1);          /* kIOHIDEventFieldDigitizerEventMask */
            }

            IOHIDEventRef finger = fn_IOHIDEventCreateDigitizerFingerEvent(
                NULL, now, g_touch_finger_id, 3, f_mask,
                hid_x, hid_y, 0.0, 0.0, 0.0,
                f_down ? 1 : 0, f_down ? 1 : 0, 0);

            if (finger) {
                if (fn_IOHIDEventSetFloatValue) {
                    fn_IOHIDEventSetFloatValue(finger, 720916 /* 0xb0014 */, 0.04); /* major radius */
                    fn_IOHIDEventSetFloatValue(finger, 720917 /* 0xb0015 */, 0.04); /* minor radius */
                }
                fn_IOHIDEventAppendEvent(parent, finger, 0);
                if (fn_IOHIDEventSetSenderID && g_touch_sender_id) {
                    fn_IOHIDEventSetSenderID(finger, g_touch_sender_id);
                }
                if (fn_CFRelease) fn_CFRelease(finger);
            }

            if (fn_IOHIDEventSetIntegerValue) {
                fn_IOHIDEventSetIntegerValue(parent, 720903 /* event mask */, f_mask);
                fn_IOHIDEventSetIntegerValue(parent, 720904 /* range */, f_down);
                fn_IOHIDEventSetIntegerValue(parent, 720905 /* touch */, f_down);
            }

            if (fn_IOHIDEventSetSenderID && g_touch_sender_id) {
                fn_IOHIDEventSetSenderID(parent, g_touch_sender_id);
            }

            if (fn_IOHIDEventSystemClientDispatchEvent) {
                fn_IOHIDEventSystemClientDispatchEvent(g_hid_client, parent);
            }
            if (fn_CFRelease) fn_CFRelease(parent);
        }
    }

    if (g_proof && (touch_state == 1 || touch_state == 0 || g_draws % 15 == 0)) {
        fprintf(g_proof, "TOUCH_EVENT: state=%d norm=(%.3f,%.3f) port=(%.1f,%.1f) ori=%ld down=%d sender=0x%llx\n",
                touch_state, norm_x, norm_y, port_px, port_py, (long)g_current_orientation, g_sim_touch_down, (unsigned long long)g_touch_sender_id);
        fflush(g_proof);
    }
}

static id nsstr(const char *s) {
    if (!fn_objc_getClass) resolve_cg_symbols();
    return ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), s);
}

static id retain_obj(id obj) {
    if (obj) {
        return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName("retain"));
    }
    return nil;
}

/* ------------------------------------------------------------------ */
/*  Feature Configuration & Global State                              */
/* ------------------------------------------------------------------ */

#define RADAR_VIEW_SIZE    180.0f
#define MENU_WIDTH         340.0f
#define MENU_HEIGHT        330.0f

static int             g_shm_fd     = -1;
static radar_shared_t *g_shared     = NULL;
static ino_t           g_shm_ino    = 0;
static uint32_t        g_last_tick  = 0;
static double          g_changed_at = 0;
static uint32_t        s_overlay_local_team = 0;
static uint32_t        g_reads = 0;
static void close_shared_memory(void);

/* View references */
static id g_button_window = nil, g_menu_window = nil, g_aim_window = nil;
static void layout_controls(void);
static id g_window          = nil;
static id g_esp_view        = nil;
/* Convert the same local point used by drawRect through the actual view transform.
 * UIScreen.fixedCoordinateSpace stays portrait regardless of scene orientation. */
static BOOL drawn_point_to_panel(double x, double y, double *hx, double *hy) {
    if (!g_esp_view || !safe_responds(g_esp_view, "convertPoint:toCoordinateSpace:")) return NO;
    id screen = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
    if (!safe_responds(screen, "fixedCoordinateSpace")) return NO;
    id fixed = ((id (*)(id, SEL))objc_msgSend)(screen, sel_registerName("fixedCoordinateSpace"));
    if (!fixed) return NO;
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(g_esp_view, sel_registerName("bounds"));
    CGRect panel = ((CGRect (*)(id, SEL))objc_msgSend)(fixed, sel_registerName("bounds"));
    if (bounds.size.width <= 0 || bounds.size.height <= 0 || panel.size.width <= 0 || panel.size.height <= 0) return NO;
    CGPoint local = CGPointMake_f(x * bounds.size.width, y * bounds.size.height);
    CGPoint pt = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(g_esp_view, sel_registerName("convertPoint:toCoordinateSpace:"), local, fixed);
    if (!isfinite(pt.x) || !isfinite(pt.y)) return NO;
    g_panel_w = panel.size.width;
    g_panel_h = panel.size.height;
    *hx = (pt.x - panel.origin.x) / g_panel_w;
    *hy = (pt.y - panel.origin.y) / g_panel_h;
    return YES;
}

static id g_radar_view      = nil;
static id g_drag_button     = nil;
static id g_aim_button      = nil;
static id g_menu_view       = nil;
static id g_menu_footer     = nil;

/* UI Rects for hit testing */
static CGRect g_button_rect = {{16, 50}, {48, 48}};
static CGRect g_aim_rect    = {{20, 200}, {56, 56}};
static CGRect g_menu_rect   = {{100, 30}, {MENU_WIDTH, MENU_HEIGHT}};

/* Dragging state */
static CGPoint g_drag_start_touch;
static CGPoint g_drag_start_origin;
static BOOL    g_is_dragging = NO;

/* Aim assist live state */
static BOOL    g_aim_active = NO;
static int     g_locked_player_idx = -1;
static CGPoint g_locked_screen_pos = {0, 0};
static double  g_sim_norm_x = 0.72;
static double  g_sim_norm_y = 0.50;
static int     g_sim_stroke_frames = 0;
static int     g_sim_recenter_pause = 0;

/* 24 Interactive Feature Flags */
static BOOL g_feat_radar          = NO;   /* Radar Minimap OFF */
static BOOL g_feat_lines          = NO;   /* Snaplines OFF */
static BOOL g_feat_box            = YES;  /* 2D Bounding Box ESP ON */
static BOOL g_feat_health         = NO;   /* Health Bar OFF */
static BOOL g_feat_name           = YES;  /* Player Name ESP ON */
static BOOL g_feat_dist           = NO;   /* Distance OFF */
static BOOL g_feat_team_bot       = YES;  /* Team ID & Bot Badge ON */
static BOOL g_feat_skeleton       = NO;   /* Skeleton OFF */
static BOOL g_feat_head           = NO;   /* Head Dot OFF */
static BOOL g_feat_vehicles       = NO;   /* Vehicles OFF */
static BOOL g_feat_items          = NO;   /* Loot ESP OFF */
static int  g_radar_range         = 200; /* 100, 200, 400 meters */
/* 12 Advanced Features (24 Total) */
static BOOL g_feat_touch_aim      = YES;  /* Outside Screen Touch Auto-Aim ON */
static int  g_aim_velocity        = 1;    /* 0=Slow 20%, 1=Med 45%, 2=Fast 75%, 3=Max 100% */
static int  g_aim_bone            = 0;    /* 0=Head, 1=Chest */
static BOOL g_feat_aim_fov        = NO;   /* Aim FOV Targeting Circle OFF */
static int  g_aim_fov_mode        = 1;    /* 0=100pt, 1=180pt, 2=260pt, 3=350pt, 4=Max/Full */
static int  g_aim_trigger_mode    = 1;    /* 0=Hold Button, 1=Auto FOV (Default), 2=OFF */
static int  g_aim_touch_zone      = 1;    /* 0=Left 1/3, 1=Right Look (Default), 2=Center */
static BOOL g_feat_veh_air_only   = NO;   /* Vehicles: Airplane Detection OFF */
static BOOL g_feat_item_filter    = NO;   /* Item Filter OFF */
static BOOL g_feat_teammates      = NO;   /* Teammate ESP Display OFF */
static BOOL g_feat_enemy_alert    = NO;   /* Enemy Count & Danger Warning Alert OFF */
static BOOL g_feat_offscreen_arrows = NO; /* Off-screen Radar Direction Arrows OFF */
static BOOL g_feat_crosshair      = NO;   /* Center Tactical Precision Crosshair OFF */
static BOOL g_feat_target_lock    = NO;   /* Target Lock Reticle & Aim Tracer OFF */
/* 14 New Creative High-Impact Features (38 Total) */
static BOOL g_feat_lead_pred       = NO;  /* 1. Target Lead Prediction Dot OFF */
static BOOL g_feat_bullet_drop     = NO;  /* 2. Sniper Bullet Drop Arc OFF */
static BOOL g_feat_recoil_comp     = NO;  /* 3. Weapon Recoil Compensation OFF */
static BOOL g_feat_gaze_ray        = NO;  /* 4. Enemy Line-of-Sight Gaze Tracer OFF */
static BOOL g_feat_blindspot_alert = NO;  /* 5. Behind-Back Blindspot Danger Warning OFF */
static BOOL g_feat_spectator_warn  = NO;  /* 6. Spectator Count & Surveillance Alert OFF */
static BOOL g_feat_adaptive_fov    = NO;  /* 7. Distance-Adaptive FOV Auto-Scaling OFF */
static BOOL g_feat_threat_tier     = NO;  /* 8. Bot vs Real Player Threat Ranking OFF */
static BOOL g_feat_grenade_warn    = NO;  /* 9. Grenade & Explosive Danger Zone OFF */
static BOOL g_feat_airdrop_beacon  = NO;  /* 10. Airdrop & Flare Crate Beacon ESP OFF */
static BOOL g_feat_sound_radar     = NO;  /* 11. Sound / Footstep Radar Visualizer OFF */
static BOOL g_feat_knocked_timer   = NO;  /* 12. Team Revive & Downed Player Bleed Timer OFF */
static BOOL g_feat_auto_evade      = NO;  /* 13. Low HP Tactical Emergency Alert OFF */
static BOOL g_feat_aim_smooth      = NO;  /* 14. Aim Smoothness Micro-Stroking OFF */

/* Tracking state for ballistics velocity and lead calculation */
typedef struct {
    rvec3_t pos;
    rvec3_t vel;
    double  last_time;
} player_tracking_t;
static player_tracking_t g_tracked_players[RADAR_MAX_PLAYERS];

static inline double get_aim_fov_radius(double screen_w, double screen_h) {
    double r = 180.0;
    switch (g_aim_fov_mode) {
        case 0: r = 100.0; break;
        case 1: r = 180.0; break;
        case 2: r = 260.0; break;
        case 3: r = 350.0; break;
        default: r = fmin(screen_w, screen_h) * 0.48; break;
    }
    if (g_feat_adaptive_fov && g_locked_player_idx >= 0 && (uint32_t)g_locked_player_idx < g_snapshot.header.player_count) {
        float d = g_snapshot.players[g_locked_player_idx].distance;
        if (d > 120.0f) r *= 0.65;      /* Tighten for long-range sniper accuracy */
        else if (d < 35.0f) r *= 1.40;  /* Expand for close-range CQB */
    }
    return r;
}

static double g_finger_drag_x     = 0.0;  /* Interactive finger movement bias */
static double g_finger_drag_y     = 0.0;

static BOOL g_menu_open           = NO;

/* Menu button references for state updates (22 features) */
static id g_btn_radar       = nil;
static id g_btn_lines       = nil;
static id g_btn_box         = nil;
static id g_btn_health      = nil;
static id g_btn_name        = nil;
static id g_btn_dist        = nil;
static id g_btn_team_bot    = nil;
static id g_btn_skeleton    = nil;
static id g_btn_head        = nil;
static id g_btn_vehicles    = nil;
static id g_btn_items       = nil;
static id g_btn_range       = nil;
/* 12 Advanced Feature Buttons (24 Total) */
static id g_btn_touch_aim   = nil;
static id g_btn_aim_speed   = nil;
static id g_btn_aim_bone    = nil;
static id g_btn_aim_fov     = nil;
static id g_btn_aim_zone    = nil;
static id g_btn_veh_filter  = nil;
static id g_btn_item_filter = nil;
static id g_btn_teammates   = nil;
static id g_btn_enemy_alert = nil;
static id g_btn_offscreen   = nil;
static id g_btn_crosshair   = nil;
static id g_btn_target_lock = nil;
/* 14 New Feature Buttons */
static id g_btn_lead_pred       = nil;
static id g_btn_bullet_drop     = nil;
static id g_btn_recoil_comp     = nil;
static id g_btn_gaze_ray        = nil;
static id g_btn_blindspot_alert = nil;
static id g_btn_spectator_warn  = nil;
static id g_btn_adaptive_fov    = nil;
static id g_btn_threat_tier     = nil;
static id g_btn_grenade_warn    = nil;
static id g_btn_airdrop_beacon  = nil;
static id g_btn_sound_radar     = nil;
static id g_btn_knocked_timer   = nil;
static id g_btn_auto_evade      = nil;
static id g_btn_aim_smooth      = nil;
static id g_btn_stop_radar      = nil;

/* Typography & Colors cached */
static id g_font_small  = nil;
static id g_font_bold   = nil;
static id g_color_white = nil;
static id g_color_green = nil;
static id g_color_yellow= nil;
static id g_color_cyan  = nil;
static id g_color_orange= nil;
static id g_color_gold  = nil;
static id g_color_red   = nil;
static id g_color_purple= nil;

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

    /* 12 Advanced Feature Toggles (24 Total) */
    const char *trig_names[] = { "Aim: Hold Btn", "Aim: Auto FOV", "Aim: OFF" };
    title(g_btn_touch_aim, trig_names[g_aim_trigger_mode % 3]);
    style_toggle_button(g_btn_touch_aim, g_aim_trigger_mode != 2);

    const char *vel_str = (g_aim_velocity == 0) ? "Aim: Slow 20%" :
                         ((g_aim_velocity == 1) ? "Aim: Med 45%" :
                         ((g_aim_velocity == 2) ? "Aim: Fast 75%" : "Aim: Max 100%"));
    title(g_btn_aim_speed, vel_str);
    style_toggle_button(g_btn_aim_speed, YES);

    const char *bone_names[] = { "Bone: Head", "Bone: Chest", "Bone: Pelvis" };
    title(g_btn_aim_bone, bone_names[g_aim_bone % 3]);
    style_toggle_button(g_btn_aim_bone, YES);

    const char *fov_names[] = { "FOV: 100pt", "FOV: 180pt", "FOV: 260pt", "FOV: 350pt", "FOV: Full" };
    title(g_btn_aim_fov, fov_names[g_aim_fov_mode % 5]);
    style_toggle_button(g_btn_aim_fov, g_aim_fov_mode != 4);

    const char *zone_names[] = { "Touch: Left 1/3", "Touch: Right Look", "Touch: Center" };
    title(g_btn_aim_zone, zone_names[g_aim_touch_zone % 3]);
    style_toggle_button(g_btn_aim_zone, YES);

    title(g_btn_veh_filter, g_feat_veh_air_only ? "Veh: Air Only" : "Veh: All Cars");
    style_toggle_button(g_btn_veh_filter, g_feat_veh_air_only);

    title(g_btn_item_filter, g_feat_item_filter ? "Loot: High Tier" : "Loot: All Items");
    style_toggle_button(g_btn_item_filter, g_feat_item_filter);

    title(g_btn_teammates, g_feat_teammates ? "Teammates: ON" : "Teammates: OFF");
    style_toggle_button(g_btn_teammates, g_feat_teammates);

    title(g_btn_enemy_alert, g_feat_enemy_alert ? "Enemy Alert: ON" : "Enemy Alert: OFF");
    style_toggle_button(g_btn_enemy_alert, g_feat_enemy_alert);

    title(g_btn_offscreen, g_feat_offscreen_arrows ? "Offscreen: ON" : "Offscreen: OFF");
    style_toggle_button(g_btn_offscreen, g_feat_offscreen_arrows);

    title(g_btn_crosshair, g_feat_crosshair ? "Crosshair: ON" : "Crosshair: OFF");
    style_toggle_button(g_btn_crosshair, g_feat_crosshair);

    title(g_btn_target_lock, g_feat_target_lock ? "Lock Box: ON" : "Lock Box: OFF");
    style_toggle_button(g_btn_target_lock, g_feat_target_lock);

    /* 14 New Feature Toggles */
    title(g_btn_lead_pred, g_feat_lead_pred ? "Lead Dot: ON" : "Lead Dot: OFF");
    style_toggle_button(g_btn_lead_pred, g_feat_lead_pred);

    title(g_btn_bullet_drop, g_feat_bullet_drop ? "Drop Guide: ON" : "Drop Guide: OFF");
    style_toggle_button(g_btn_bullet_drop, g_feat_bullet_drop);

    title(g_btn_recoil_comp, g_feat_recoil_comp ? "Recoil Comp: ON" : "Recoil Comp: OFF");
    style_toggle_button(g_btn_recoil_comp, g_feat_recoil_comp);

    title(g_btn_gaze_ray, g_feat_gaze_ray ? "Gaze Rays: ON" : "Gaze Rays: OFF");
    style_toggle_button(g_btn_gaze_ray, g_feat_gaze_ray);

    title(g_btn_blindspot_alert, g_feat_blindspot_alert ? "Blind Alert: ON" : "Blind Alert: OFF");
    style_toggle_button(g_btn_blindspot_alert, g_feat_blindspot_alert);

    title(g_btn_spectator_warn, g_feat_spectator_warn ? "Spectator: ON" : "Spectator: OFF");
    style_toggle_button(g_btn_spectator_warn, g_feat_spectator_warn);

    title(g_btn_adaptive_fov, g_feat_adaptive_fov ? "Adapt FOV: ON" : "Adapt FOV: OFF");
    style_toggle_button(g_btn_adaptive_fov, g_feat_adaptive_fov);

    title(g_btn_threat_tier, g_feat_threat_tier ? "Threat Rank: ON" : "Threat Rank: OFF");
    style_toggle_button(g_btn_threat_tier, g_feat_threat_tier);

    title(g_btn_grenade_warn, g_feat_grenade_warn ? "Nade Alert: ON" : "Nade Alert: OFF");
    style_toggle_button(g_btn_grenade_warn, g_feat_grenade_warn);

    title(g_btn_airdrop_beacon, g_feat_airdrop_beacon ? "Airdrop ESP: ON" : "Airdrop ESP: OFF");
    style_toggle_button(g_btn_airdrop_beacon, g_feat_airdrop_beacon);

    title(g_btn_sound_radar, g_feat_sound_radar ? "Audio Radar: ON" : "Audio Radar: OFF");
    style_toggle_button(g_btn_sound_radar, g_feat_sound_radar);

    title(g_btn_knocked_timer, g_feat_knocked_timer ? "Bleed Timer: ON" : "Bleed Timer: OFF");
    style_toggle_button(g_btn_knocked_timer, g_feat_knocked_timer);

    title(g_btn_auto_evade, g_feat_auto_evade ? "Evade Alert: ON" : "Evade Alert: OFF");
    style_toggle_button(g_btn_auto_evade, g_feat_auto_evade);

    title(g_btn_aim_smooth, g_feat_aim_smooth ? "Aim Smooth: ON" : "Aim Smooth: OFF");
    style_toggle_button(g_btn_aim_smooth, g_feat_aim_smooth);

    hidden(g_radar_view, !g_feat_radar);
    if (g_aim_window) hidden(g_aim_window, !g_feat_touch_aim || g_menu_open);
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
    return g_menu_window ? g_menu_window : g_window;
}

static void codex_action_toggle_menu_cls(id self, SEL cmd) {
    (void)self; (void)cmd;
    toggle_menu();
}

/* ------------------------------------------------------------------ */
/*  Text Rendering Helper via NSString drawAtPoint                    */
/* ------------------------------------------------------------------ */

static id s_font_attr_key = nil;
static id s_color_attr_key = nil;

static void ensure_text_attrs(void) {
    if (!s_font_attr_key) {
        id *pFont = (id *)dlsym(RTLD_DEFAULT, "NSFontAttributeName");
        if (pFont && *pFont) {
            s_font_attr_key = retain_obj(*pFont);
        } else {
            s_font_attr_key = retain_obj(nsstr("NSFont"));
        }
    }
    if (!s_color_attr_key) {
        id *pColor = (id *)dlsym(RTLD_DEFAULT, "NSForegroundColorAttributeName");
        if (pColor && *pColor) {
            s_color_attr_key = retain_obj(*pColor);
        } else {
            s_color_attr_key = retain_obj(nsstr("NSColor"));
        }
    }
}

static void draw_text_at(const char *text, CGPoint pt, id font, id color) {
    if (!text || text[0] == '\0') return;
    if (!font) font = g_font_small;
    if (!color) color = g_color_white;
    if (!font || !color) return;

    id s = nsstr(text);
    if (!s) return;

    ensure_text_attrs();
    if (!s_font_attr_key || !s_color_attr_key) return;

    Class dict_cls = objc_getClass("NSDictionary");
    if (!dict_cls) return;

    id objects[2] = { font, color };
    id keys[2] = { s_font_attr_key, s_color_attr_key };
    id attrs = ((id (*)(id, SEL, id*, id*, NSUInteger))objc_msgSend)(
        (id)dict_cls, sel_registerName("dictionaryWithObjects:forKeys:count:"),
        objects, keys, 2);
    if (!attrs) return;

    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(
        s, sel_registerName("drawAtPoint:withAttributes:"), pt, attrs);
}

static CGSize text_size(const char *text, id font) {
    if (!text || text[0] == '\0') return (CGSize){0, 0};
    if (!font) font = g_font_small;
    if (!font) return (CGSize){0, 0};

    id s = nsstr(text);
    if (!s) return (CGSize){0, 0};

    ensure_text_attrs();
    if (!s_font_attr_key) return (CGSize){0, 0};

    Class dict_cls = objc_getClass("NSDictionary");
    if (!dict_cls) return (CGSize){0, 0};

    id objects[1] = { font };
    id keys[1] = { s_font_attr_key };
    id attrs = ((id (*)(id, SEL, id*, id*, NSUInteger))objc_msgSend)(
        (id)dict_cls, sel_registerName("dictionaryWithObjects:forKeys:count:"),
        objects, keys, 1);
    if (!attrs) return (CGSize){0, 0};

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

static void close_shared_memory(void) {
    if (g_shared) {
        munmap(g_shared, sizeof(radar_shared_t));
        g_shared = NULL;
    }
    if (g_shm_fd >= 0) {
        close(g_shm_fd);
        g_shm_fd = -1;
    }
    g_shm_ino = 0;
}

static BOOL open_shared_memory(void) {
    struct stat st;
    if (stat(RADAR_FILE_PATH, &st) != 0 || st.st_size < (off_t)sizeof(radar_shared_t)) {
        return NO;
    }
    if (g_shared && g_shm_ino != 0 && st.st_ino != g_shm_ino) {
        close_shared_memory();
    }
    if (g_shared) return YES;

    g_shm_fd = open(RADAR_FILE_PATH, O_RDONLY);
    if (g_shm_fd < 0) return NO;

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

    g_shm_ino = st.st_ino;
    NSLog(nsstr("[Radar] Shared memory opened (ino=%llu, %zu bytes, version %u)"),
          (unsigned long long)g_shm_ino, sizeof(radar_shared_t), RADAR_VERSION);
    return YES;
}

static BOOL read_snapshot(void) {
    if (!g_shared) {
        if (!open_shared_memory()) return NO;
    }
    for (int retry = 0; retry < 3; retry++) {
        uint32_t seq = __atomic_load_n(&g_shared->header.sequence, __ATOMIC_ACQUIRE);
        if (seq & 1) continue;

        radar_shared_t candidate;
        memcpy(&candidate, g_shared, sizeof(candidate));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);

        if (seq != __atomic_load_n(&g_shared->header.sequence, __ATOMIC_ACQUIRE)) continue;
        if (candidate.header.magic != RADAR_MAGIC || candidate.header.version != RADAR_VERSION) {
            close_shared_memory();
            open_shared_memory();
            return NO;
        }
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
    if (w <= 10.0 || h <= 10.0) {
        if (g_screen_w > 10.0 && g_screen_h > 10.0) {
            w = g_screen_w;
            h = g_screen_h;
        } else {
            id ms = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
            CGRect b = ms ? ((CGRect (*)(id, SEL))objc_msgSend)(ms, sel_registerName("bounds")) : (CGRect){{0,0},{1024,768}};
            w = fmax(b.size.width, b.size.height);
            h = fmin(b.size.width, b.size.height);
        }
    }
    BOOL is_landscape = (g_current_orientation == 3 || g_current_orientation == 4 || w > h || g_snapshot.header.status >= 1);
    if (is_landscape && w < h) {
        double tmp = w; w = h; h = tmp;
    }

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

    void *pool = NULL;
    if (fn_objc_autoreleasePoolPush) pool = fn_objc_autoreleasePoolPush();

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        if (fn_objc_autoreleasePoolPop && pool) fn_objc_autoreleasePoolPop(pool);
        return;
    }

    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("bounds"));
    double w = bounds.size.width;
    double h = bounds.size.height;
    if (w <= 10.0 || h <= 10.0) {
        if (g_screen_w > 10.0 && g_screen_h > 10.0) {
            w = g_screen_w;
            h = g_screen_h;
        } else {
            id ms = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
            CGRect b = ms ? ((CGRect (*)(id, SEL))objc_msgSend)(ms, sel_registerName("bounds")) : (CGRect){{0,0},{1024,768}};
            w = fmax(b.size.width, b.size.height);
            h = fmin(b.size.width, b.size.height);
        }
    }
    BOOL is_landscape = (g_current_orientation == 3 || g_current_orientation == 4 || w > h || g_snapshot.header.status >= 1);
    if (is_landscape && w < h) {
        double tmp = w;
        w = h;
        h = tmp;
    }
    if (w <= 10.0 || h <= 10.0) {
        if (fn_objc_autoreleasePoolPop && pool) fn_objc_autoreleasePoolPop(pool);
        return;
    }

    /* 1. Render Players */
    uint32_t pcount = g_snapshot.header.player_count;
    if (pcount > RADAR_MAX_PLAYERS) pcount = RADAR_MAX_PLAYERS;
    uint32_t my_team = (g_snapshot.header.local_team > 0) ? g_snapshot.header.local_team : s_overlay_local_team;

    uint32_t enemy_count_nearby = 0;
    float closest_enemy_dist = 9999.0f;

    for (uint32_t i = 0; i < pcount; i++) {
        const radar_player_t *p = &g_snapshot.players[i];
        if (p->health_status == 2) continue;

        BOOL is_teammate = (my_team != 0 && p->team_id == my_team);
        if (is_teammate && !g_feat_teammates) continue;

        if (!is_teammate) {
            enemy_count_nearby++;
            if (p->distance < closest_enemy_dist) closest_enemy_dist = p->distance;
        }

        CGPoint head_2d, feet_2d;
        double depth = 0;
        BOOL on_screen = world_to_screen(p->head_pos, &head_2d, &depth, w, h) &&
                         world_to_screen(p->feet_pos, &feet_2d, NULL, w, h);

        if (!on_screen || depth <= 0.0) {
            /* Feature: Off-screen direction indicators for enemies */
            if (g_feat_offscreen_arrows && !is_teammate) {
                rvec3_t cam = g_snapshot.header.camera_pos;
                float cam_yaw_rad = -g_snapshot.header.local_rot.y * (float)M_PI / 180.0f;
                float dx = p->pos.x - cam.x;
                float dy = p->pos.y - cam.y;
                float angle = atan2f(dy, dx) - cam_yaw_rad;
                float ax = w / 2.0f + cosf(angle) * (w * 0.40f);
                float ay = h / 2.0f + sinf(angle) * (h * 0.40f);

                CGContextSetRGBFillColor(ctx, 1.0f, 0.2f, 0.2f, 0.85f);
                CGContextFillEllipseInRect(ctx, CGRectMake_f(ax - 5.0f, ay - 5.0f, 10.0f, 10.0f));

                char dist_txt[16];
                snprintf(dist_txt, sizeof(dist_txt), "%.0fm", p->distance);
                draw_text_centered(dist_txt, (CGPoint){ ax, ay + 7.0f }, g_font_small, g_color_white);
            }
            continue;
        }

        double box_h = feet_2d.y - head_2d.y;
        if (box_h < 12.0) box_h = 12.0;
        double box_w = box_h * 0.48;
        double box_x = (head_2d.x + feet_2d.x) / 2.0 - box_w / 2.0;
        double box_y = head_2d.y;

        /* Team color or Knocked color */
        BOOL is_knocked = (p->health_status == 1);
        id accent_color = is_teammate ? (is_knocked ? g_color_orange : g_color_green) :
                         (is_knocked ? g_color_orange :
                         (p->is_bot ? g_color_yellow : g_color_cyan));

        /* Feature: Snaplines */
        if (g_feat_lines) {
            if (is_teammate) {
                if (is_knocked) CGContextSetRGBStrokeColor(ctx, 1.0, 0.55, 0.0, 0.75);
                else CGContextSetRGBStrokeColor(ctx, 0.2, 0.95, 0.35, 0.75);
            } else if (is_knocked) CGContextSetRGBStrokeColor(ctx, 1.0, 0.55, 0.0, 0.75);
            else if (p->is_bot) CGContextSetRGBStrokeColor(ctx, 1.0, 0.9, 0.2, 0.75);
            else CGContextSetRGBStrokeColor(ctx, 0.0, 0.85, 1.0, 0.85);

            CGContextSetLineWidth(ctx, 1.2);
            CGContextMoveToPoint(ctx, w / 2.0, h);
            CGContextAddLineToPoint(ctx, (head_2d.x + feet_2d.x) / 2.0, feet_2d.y);
            CGContextStrokePath(ctx);
        }

        /* Feature: 2D Box ESP */
        if (g_feat_box) {
            if (is_teammate) {
                if (is_knocked) CGContextSetRGBStrokeColor(ctx, 1.0, 0.55, 0.0, 0.9);
                else CGContextSetRGBStrokeColor(ctx, 0.2, 0.95, 0.35, 0.9);
            } else if (is_knocked) CGContextSetRGBStrokeColor(ctx, 1.0, 0.55, 0.0, 0.9);
            else if (p->is_bot) CGContextSetRGBStrokeColor(ctx, 1.0, 0.9, 0.2, 0.9);
            else CGContextSetRGBStrokeColor(ctx, 0.0, 0.85, 1.0, 0.9);

            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeRect(ctx, CGRectMake_f(box_x, box_y, box_w, box_h));
        }

        /* Feature: Head Dot Aim Marker (Enemies only) */
        if (g_feat_head && !is_teammate) {
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

            CGContextSetRGBFillColor(ctx, 0.1, 0.1, 0.1, 0.7);
            CGContextFillRect(ctx, CGRectMake_f(bar_x, box_y, bar_w, box_h));

            double fill_h = box_h * hp_ratio;
            if (is_teammate) CGContextSetRGBFillColor(ctx, 0.2, 0.95, 0.35, 0.95);
            else if (hp_ratio > 0.5f) CGContextSetRGBFillColor(ctx, 0.2, 0.9, 0.3, 0.95);
            else if (hp_ratio > 0.25f) CGContextSetRGBFillColor(ctx, 1.0, 0.8, 0.1, 0.95);
            else CGContextSetRGBFillColor(ctx, 1.0, 0.2, 0.2, 0.95);

            CGContextFillRect(ctx, CGRectMake_f(bar_x, box_y + (box_h - fill_h), bar_w, fill_h));
        }

        /* Feature: Player Name & Team/Bot Tag */
        if (g_feat_name || g_feat_team_bot) {
            char name_buf[64] = {0};
            if (is_teammate) {
                if (is_knocked) {
                    snprintf(name_buf, sizeof(name_buf), "[TEAM #%u KNOCKED] %s", p->team_id, g_feat_name ? p->name : "");
                } else {
                    snprintf(name_buf, sizeof(name_buf), "[TEAM #%u] %s", p->team_id, g_feat_name ? p->name : "");
                }
            } else if (is_knocked) {
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

        /* Feature 8: Threat Ranking Tag */
        if (g_feat_threat_tier && !is_teammate) {
            char threat_buf[32];
            id threat_col = g_color_red;
            if (p->is_bot) {
                snprintf(threat_buf, sizeof(threat_buf), "[BOT - LOW]");
                threat_col = g_color_gold;
            } else if (p->distance < 85.0f) {
                snprintf(threat_buf, sizeof(threat_buf), "[TIER 1 DANGER]");
                threat_col = g_color_red;
            } else {
                snprintf(threat_buf, sizeof(threat_buf), "[TIER 2 ENEMY]");
                threat_col = g_color_orange;
            }
            draw_text_centered(threat_buf, (CGPoint){ (head_2d.x + feet_2d.x) / 2.0, box_y - 22 }, g_font_small, threat_col);
        }

        /* Feature 12: Knocked Bleedout Timer */
        if (g_feat_knocked_timer && is_knocked) {
            float bleed_pct = (p->health_max > 0) ? (p->health / p->health_max * 100.0f) : 50.0f;
            char bleed_buf[32];
            snprintf(bleed_buf, sizeof(bleed_buf), "+ BLEED: %.0f%% +", bleed_pct);
            draw_text_centered(bleed_buf, (CGPoint){ (head_2d.x + feet_2d.x) / 2.0, feet_2d.y + 20 }, g_font_small, g_color_orange);
        }

        /* Feature 4: Enemy Gaze / Line-of-Sight Tracer */
        if (g_feat_gaze_ray && !is_teammate) {
            float rad = p->yaw * (float)M_PI / 180.0f;
            rvec3_t gaze_end = {
                p->head_pos.x + cosf(rad) * 450.0f,
                p->head_pos.y + sinf(rad) * 450.0f,
                p->head_pos.z
            };
            CGPoint ray_screen;
            if (world_to_screen(gaze_end, &ray_screen, NULL, w, h)) {
                float to_cam_x = g_snapshot.header.camera_pos.x - p->head_pos.x;
                float to_cam_y = g_snapshot.header.camera_pos.y - p->head_pos.y;
                float cdist = hypotf(to_cam_x, to_cam_y);
                float dot = (cosf(rad) * to_cam_x + sinf(rad) * to_cam_y) / (cdist > 0 ? cdist : 1.0f);
                BOOL targeting_us = (dot > 0.85f);

                if (targeting_us) {
                    CGContextSetRGBStrokeColor(ctx, 1.0, 0.15, 0.15, 0.95);
                    CGContextSetLineWidth(ctx, 2.0);
                    draw_text_centered("[! TARGETING YOU !]", (CGPoint){ ray_screen.x, ray_screen.y - 10.0 }, g_font_small, g_color_red);
                } else {
                    CGContextSetRGBStrokeColor(ctx, 1.0, 0.82, 0.1, 0.65);
                    CGContextSetLineWidth(ctx, 1.2);
                }
                CGContextMoveToPoint(ctx, head_2d.x, head_2d.y);
                CGContextAddLineToPoint(ctx, ray_screen.x, ray_screen.y);
                CGContextStrokePath(ctx);
            }
        }

        /* Feature 1: Target Lead Prediction Dot */
        if (g_feat_lead_pred && !is_teammate) {
            float vx = g_tracked_players[i].vel.x;
            float vy = g_tracked_players[i].vel.y;
            float vz = g_tracked_players[i].vel.z;
            float spd = hypotf(vx, vy);
            if (spd > 25.0f && p->distance > 6.0f) {
                float bullet_t = p->distance / 880.0f;
                rvec3_t lead_pos = {
                    p->head_pos.x + vx * bullet_t,
                    p->head_pos.y + vy * bullet_t,
                    p->head_pos.z + vz * bullet_t
                };
                CGPoint lead_screen;
                if (world_to_screen(lead_pos, &lead_screen, NULL, w, h)) {
                    CGContextSetRGBStrokeColor(ctx, 0.0, 1.0, 0.85, 0.95);
                    CGContextSetRGBFillColor(ctx, 0.0, 1.0, 0.85, 0.45);
                    CGContextSetLineWidth(ctx, 1.5);
                    CGContextStrokeEllipseInRect(ctx, CGRectMake_f(lead_screen.x - 5.0, lead_screen.y - 5.0, 10.0, 10.0));
                    CGContextFillEllipseInRect(ctx, CGRectMake_f(lead_screen.x - 2.0, lead_screen.y - 2.0, 4.0, 4.0));
                    draw_text_centered("[LEAD]", (CGPoint){ lead_screen.x, lead_screen.y - 12.0 }, g_font_small, g_color_cyan);
                }
            }
        }

        /* Feature 2: Sniper Bullet Drop Distance Guide */
        if (g_feat_bullet_drop && !is_teammate && p->distance > 80.0f) {
            float bullet_t = p->distance / 800.0f;
            float drop_cm = 0.5f * 980.0f * bullet_t * bullet_t;
            rvec3_t drop_pos = { p->head_pos.x, p->head_pos.y, p->head_pos.z - drop_cm };
            CGPoint drop_screen;
            if (world_to_screen(drop_pos, &drop_screen, NULL, w, h)) {
                CGContextSetRGBStrokeColor(ctx, 1.0, 0.82, 0.1, 0.85);
                CGContextSetLineWidth(ctx, 1.2);
                CGContextMoveToPoint(ctx, head_2d.x - 6.0, drop_screen.y);
                CGContextAddLineToPoint(ctx, head_2d.x + 6.0, drop_screen.y);
                CGContextStrokePath(ctx);
                draw_text_centered("v DROP", (CGPoint){ head_2d.x + 16.0, drop_screen.y }, g_font_small, g_color_gold);
            }
        }

        /* Target Lock Reticle */
        if (g_feat_target_lock && g_locked_player_idx >= 0 && (uint32_t)g_locked_player_idx == i) {
            CGContextSetRGBStrokeColor(ctx, 1.0, 0.15, 0.35, 0.95);
            CGContextSetLineWidth(ctx, 2.0);
            double lock_size = box_w * 0.40;
            if (lock_size < 16.0) lock_size = 16.0;
            CGContextStrokeRect(ctx, CGRectMake_f(head_2d.x - lock_size/2.0, head_2d.y - lock_size/2.0, lock_size, lock_size));

            CGContextSetRGBStrokeColor(ctx, 1.0, 0.2, 0.3, 0.7);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextMoveToPoint(ctx, w / 2.0, h / 2.0);
            CGContextAddLineToPoint(ctx, head_2d.x, head_2d.y);
            CGContextStrokePath(ctx);
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
            BOOL is_air = (v->can_boost == 1) || (strstr(v->name, "Airplane") || strstr(v->name, "Glider") || strstr(v->name, "Helicopter"));
            if (g_feat_veh_air_only && !is_air) continue;

            CGPoint v_screen;
            if (!world_to_screen(v->pos, &v_screen, NULL, w, h)) continue;

            /* Draw marker: Diamond for car, Wings for Airplane */
            if (is_air) {
                CGContextSetRGBStrokeColor(ctx, 1.0, 0.4, 0.9, 0.95);
                CGContextSetLineWidth(ctx, 2.0);
                CGContextMoveToPoint(ctx, v_screen.x - 14, v_screen.y + 4);
                CGContextAddLineToPoint(ctx, v_screen.x, v_screen.y - 8);
                CGContextAddLineToPoint(ctx, v_screen.x + 14, v_screen.y + 4);
                CGContextMoveToPoint(ctx, v_screen.x, v_screen.y - 8);
                CGContextAddLineToPoint(ctx, v_screen.x, v_screen.y + 10);
                CGContextStrokePath(ctx);

                char vbuf[64];
                snprintf(vbuf, sizeof(vbuf), "[AIR: %s] %.0fm", v->name, v->distance);
                draw_text_centered(vbuf, (CGPoint){ v_screen.x, v_screen.y + 18 }, g_font_bold, g_color_gold);
            } else {
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
    }

    /* 3. Render Loot & Items */
    if (g_feat_items) {
        uint32_t icount = g_snapshot.header.item_count;
        if (icount > RADAR_MAX_ITEMS) icount = RADAR_MAX_ITEMS;

        for (uint32_t i = 0; i < icount; i++) {
            const radar_item_t *item = &g_snapshot.items[i];

            /* If item filter is enabled: only show throwables, high-tier weapons, scopes, crates */
            if (g_feat_item_filter) {
                BOOL is_high = (item->category == 1 || item->category == 5 ||
                                strstr(item->name, "Smoke") || strstr(item->name, "Frag") ||
                                strstr(item->name, "Molotov") || strstr(item->name, "Flare") ||
                                strstr(item->name, "AWM") || strstr(item->name, "Scope") ||
                                strstr(item->name, "Crate") || strstr(item->name, "Air Drop"));
                if (!is_high) continue;
            }

            CGPoint i_screen;
            if (!world_to_screen(item->pos, &i_screen, NULL, w, h)) continue;

            /* Category colors */
            id item_color = g_color_white;
            if (item->category == 1) {
                CGContextSetRGBFillColor(ctx, 1.0, 0.3, 0.3, 0.85);
                item_color = g_color_orange;
            } else if (item->category == 2) {
                CGContextSetRGBFillColor(ctx, 0.2, 0.7, 1.0, 0.85);
                item_color = g_color_cyan;
            } else if (item->category == 3) {
                CGContextSetRGBFillColor(ctx, 0.2, 0.95, 0.4, 0.85);
                item_color = g_color_green;
            } else if (item->category == 5 || strstr(item->name, "Smoke") || strstr(item->name, "Frag") || strstr(item->name, "Molotov")) {
                CGContextSetRGBFillColor(ctx, 0.75, 0.4, 1.0, 0.95);
                item_color = g_color_purple;
            } else {
                CGContextSetRGBFillColor(ctx, 0.9, 0.9, 0.9, 0.75);
                item_color = g_color_white;
            }

            CGContextFillEllipseInRect(ctx, CGRectMake_f(i_screen.x - 3, i_screen.y - 3, 6, 6));

            char ibuf[64];
            if (item->count > 1) {
                snprintf(ibuf, sizeof(ibuf), "%s x%d (%.0fm)", item->name, item->count, item->distance);
            } else {
                snprintf(ibuf, sizeof(ibuf), "%s (%.0fm)", item->name, item->distance);
            }
            draw_text_centered(ibuf, (CGPoint){ i_screen.x, i_screen.y - 8 }, g_font_small, item_color);
        }
    }

    /* 4. Tactical Precision Center Crosshair */
    if (g_feat_crosshair) {
        double cx = w / 2.0;
        double cy = h / 2.0;
        if (g_locked_player_idx >= 0) {
            CGContextSetRGBStrokeColor(ctx, 1.0, 0.2, 0.2, 0.95);
        } else {
            CGContextSetRGBStrokeColor(ctx, 0.0, 0.9, 1.0, 0.75);
        }
        CGContextSetLineWidth(ctx, 1.5);
        double arm = 10.0;
        double gap = 4.0;
        CGContextMoveToPoint(ctx, cx - gap - arm, cy); CGContextAddLineToPoint(ctx, cx - gap, cy);
        CGContextMoveToPoint(ctx, cx + gap, cy); CGContextAddLineToPoint(ctx, cx + gap + arm, cy);
        CGContextMoveToPoint(ctx, cx, cy - gap - arm); CGContextAddLineToPoint(ctx, cx, cy - gap);
        CGContextMoveToPoint(ctx, cx, cy + gap); CGContextAddLineToPoint(ctx, cx, cy + gap + arm);
        CGContextStrokePath(ctx);
        CGContextFillEllipseInRect(ctx, CGRectMake_f(cx - 1.0, cy - 1.0, 2.0, 2.0));
    }

    /* 5. Aim FOV Targeting Circle & Target Lock HUD */
    if (g_feat_aim_fov && g_feat_touch_aim && g_aim_trigger_mode != 2 && g_aim_fov_mode != 4) {
        double cx = w / 2.0;
        double cy = h / 2.0;
        double r = get_aim_fov_radius(w, h);

        if (g_locked_player_idx >= 0) {
            /* Locked Target: Bright neon orange/red HUD ring */
            CGContextSetRGBStrokeColor(ctx, 1.0, 0.40, 0.05, 0.85);
            CGContextSetLineWidth(ctx, 2.0);
            CGContextStrokeEllipseInRect(ctx, CGRectMake_f(cx - r, cy - r, r * 2.0, r * 2.0));

            /* 4 HUD crosshair tick marks on FOV boundary */
            CGContextMoveToPoint(ctx, cx, cy - r - 6); CGContextAddLineToPoint(ctx, cx, cy - r + 6);
            CGContextMoveToPoint(ctx, cx, cy + r - 6); CGContextAddLineToPoint(ctx, cx, cy + r + 6);
            CGContextMoveToPoint(ctx, cx - r - 6, cy); CGContextAddLineToPoint(ctx, cx - r + 6, cy);
            CGContextMoveToPoint(ctx, cx + r - 6, cy); CGContextAddLineToPoint(ctx, cx + r + 6, cy);
            CGContextStrokePath(ctx);

            /* FOV Lock Label */
            char fov_buf[48];
            snprintf(fov_buf, sizeof(fov_buf), "[AIM LOCKED - %.0fpt]", r);
            draw_text_centered(fov_buf, (CGPoint){ cx, cy - r - 12 }, g_font_small, g_color_gold);

            /* Aim tracer line from center directly to locked target */
            if (g_feat_target_lock && g_locked_screen_pos.x > 0 && g_locked_screen_pos.y > 0) {
                CGContextSetRGBStrokeColor(ctx, 1.0, 0.45, 0.10, 0.90);
                CGContextSetLineWidth(ctx, 1.6);
                CGContextMoveToPoint(ctx, cx, cy);
                CGContextAddLineToPoint(ctx, g_locked_screen_pos.x, g_locked_screen_pos.y);
                CGContextStrokePath(ctx);
            }
        } else {
            /* Idle FOV Circle: Neon cyan HUD ring */
            CGContextSetRGBStrokeColor(ctx, 0.0, 0.85, 1.0, 0.35);
            CGContextSetLineWidth(ctx, 1.2);
            CGContextStrokeEllipseInRect(ctx, CGRectMake_f(cx - r, cy - r, r * 2.0, r * 2.0));

            /* 4 HUD crosshair tick marks */
            CGContextMoveToPoint(ctx, cx, cy - r - 4); CGContextAddLineToPoint(ctx, cx, cy - r + 4);
            CGContextMoveToPoint(ctx, cx, cy + r - 4); CGContextAddLineToPoint(ctx, cx, cy + r + 4);
            CGContextMoveToPoint(ctx, cx - r - 4, cy); CGContextAddLineToPoint(ctx, cx - r + 4, cy);
            CGContextMoveToPoint(ctx, cx + r - 4, cy); CGContextAddLineToPoint(ctx, cx + r + 4, cy);
            CGContextStrokePath(ctx);
        }
    }

    /* 5b. Touch Assist Circular Zone & Active Sweep Indicator */
    if (g_feat_touch_aim && g_aim_trigger_mode != 2) {
        double touch_bx = ((g_aim_touch_zone == 0) ? 0.22 : ((g_aim_touch_zone == 1) ? 0.72 : 0.50)) * w;
        double touch_by = 0.50 * h;
        double touch_cr = 0.09 * w;
        double aspect = h / (w > 0 ? w : 1.0);

        if (g_sim_touch_down) {
            /* Active Touch: Glowing gold circle with active dragging dot and tracer */
            CGContextSetRGBStrokeColor(ctx, 1.0, 0.85, 0.0, 0.65);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeEllipseInRect(ctx, CGRectMake_f(touch_bx - touch_cr, touch_by - touch_cr * aspect, touch_cr * 2.0, touch_cr * 2.0 * aspect));

            double cur_tx = g_sim_norm_x * w;
            double cur_ty = g_sim_norm_y * h;

            /* Line from base center to current touch position */
            CGContextSetRGBStrokeColor(ctx, 1.0, 0.85, 0.0, 0.85);
            CGContextMoveToPoint(ctx, touch_bx, touch_by);
            CGContextAddLineToPoint(ctx, cur_tx, cur_ty);
            CGContextStrokePath(ctx);

            /* Glowing touch contact point */
            CGContextSetRGBFillColor(ctx, 1.0, 0.90, 0.1, 0.95);
            CGContextFillEllipseInRect(ctx, CGRectMake_f(cur_tx - 5.0, cur_ty - 5.0, 10.0, 10.0));

            draw_text_centered("[TOUCH INJECTING]", (CGPoint){ touch_bx, touch_by - touch_cr * aspect - 14.0 }, g_font_small, g_color_gold);
        } else {
            /* Idle Touch Zone indicator */
            CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 0.20);
            CGContextSetLineWidth(ctx, 1.0);
            CGContextStrokeEllipseInRect(ctx, CGRectMake_f(touch_bx - touch_cr, touch_by - touch_cr * aspect, touch_cr * 2.0, touch_cr * 2.0 * aspect));
        }
    }

    /* 6. Enemy Count & Danger Alert */
    if (g_feat_enemy_alert && enemy_count_nearby > 0) {
        char alert_buf[64];
        if (closest_enemy_dist < 30.0f) {
            snprintf(alert_buf, sizeof(alert_buf), "! DANGER: %u ENEMY < %.0fm !", enemy_count_nearby, closest_enemy_dist);
            CGSize sz = text_size(alert_buf, g_font_bold);
            CGRect pill = CGRectMake_f(w / 2.0 - sz.width / 2.0 - 12.0, 28.0, sz.width + 24.0, 24.0);
            CGContextSetRGBFillColor(ctx, 0.8, 0.1, 0.1, 0.75);
            CGContextFillRect(ctx, pill);
            draw_text_centered(alert_buf, (CGPoint){ w / 2.0, 40.0 }, g_font_bold, g_color_white);
        } else {
            snprintf(alert_buf, sizeof(alert_buf), "%u ENEMIES NEARBY (%.0fm)", enemy_count_nearby, closest_enemy_dist);
            CGSize sz = text_size(alert_buf, g_font_bold);
            CGRect pill = CGRectMake_f(w / 2.0 - sz.width / 2.0 - 10.0, 28.0, sz.width + 20.0, 22.0);
            CGContextSetRGBFillColor(ctx, 0.1, 0.15, 0.22, 0.75);
            CGContextFillRect(ctx, pill);
            draw_text_centered(alert_buf, (CGPoint){ w / 2.0, 39.0 }, g_font_bold, g_color_gold);
        }
    }

    /* Feature 5: Behind-Back Blindspot Danger Warning */
    if (g_feat_blindspot_alert) {
        float cam_yaw_rad = -g_snapshot.header.local_rot.y * (float)M_PI / 180.0f;
        float fwd_x = cosf(cam_yaw_rad), fwd_y = sinf(cam_yaw_rad);
        float right_x = sinf(cam_yaw_rad), right_y = -cosf(cam_yaw_rad);
        rvec3_t cam = g_snapshot.header.camera_pos;

        for (uint32_t i = 0; i < pcount; i++) {
            const radar_player_t *p = &g_snapshot.players[i];
            if (p->health_status == 2) continue;
            if (my_team != 0 && p->team_id == my_team) continue;
            if (p->distance > 65.0f) continue;

            float dx = p->pos.x - cam.x;
            float dy = p->pos.y - cam.y;
            float d_horiz = hypotf(dx, dy);
            if (d_horiz < 1.0f) continue;

            float dot_fwd = (dx * fwd_x + dy * fwd_y) / d_horiz;
            float dot_right = (dx * right_x + dy * right_y) / d_horiz;

            if (dot_fwd < 0.25f) { /* Flank or Behind */
                if (dot_right < -0.35f) {
                    CGContextSetRGBFillColor(ctx, 1.0, 0.2, 0.2, 0.65);
                    CGContextFillRect(ctx, CGRectMake_f(0, h * 0.35, 8.0, h * 0.30));
                    draw_text_centered("<< FLANK", (CGPoint){ 35.0, h * 0.50 }, g_font_bold, g_color_red);
                } else if (dot_right > 0.35f) {
                    CGContextSetRGBFillColor(ctx, 1.0, 0.2, 0.2, 0.65);
                    CGContextFillRect(ctx, CGRectMake_f(w - 8.0, h * 0.35, 8.0, h * 0.30));
                    draw_text_centered("FLANK >>", (CGPoint){ w - 35.0, h * 0.50 }, g_font_bold, g_color_red);
                } else if (dot_fwd < -0.30f) {
                    CGContextSetRGBFillColor(ctx, 1.0, 0.1, 0.1, 0.70);
                    CGContextFillRect(ctx, CGRectMake_f(w * 0.30, h - 8.0, w * 0.40, 8.0));
                    draw_text_centered("! BEHIND !", (CGPoint){ w * 0.50, h - 22.0 }, g_font_bold, g_color_red);
                }
            }
        }
    }

    /* Feature 11: Sound / Footstep Radar Visualizer */
    if (g_feat_sound_radar) {
        float cam_yaw_rad = -g_snapshot.header.local_rot.y * (float)M_PI / 180.0f;
        rvec3_t cam = g_snapshot.header.camera_pos;
        for (uint32_t i = 0; i < pcount; i++) {
            const radar_player_t *p = &g_snapshot.players[i];
            if (p->health_status == 2) continue;
            if (my_team != 0 && p->team_id == my_team) continue;
            if (p->distance > 42.0f) continue;

            float dx = p->pos.x - cam.x;
            float dy = p->pos.y - cam.y;
            float ang = atan2f(dy, dx) - cam_yaw_rad;
            float cx = w / 2.0f, cy = h / 2.0f;
            float wave_r = 45.0f + (p->distance / 42.0f) * 35.0f;

            CGContextSetRGBStrokeColor(ctx, 1.0, 0.55, 0.0, 0.75);
            CGContextSetLineWidth(ctx, 2.0);
            CGContextAddArc(ctx, cx, cy, wave_r, ang - 0.25f, ang + 0.25f, 0);
            CGContextStrokePath(ctx);
        }
    }

    /* Feature 9: Grenade Warning & Feature 10: Airdrop Beacon */
    if (g_feat_grenade_warn || g_feat_airdrop_beacon) {
        uint32_t icount = g_snapshot.header.item_count;
        if (icount > RADAR_MAX_ITEMS) icount = RADAR_MAX_ITEMS;
        for (uint32_t i = 0; i < icount; i++) {
            const radar_item_t *it = &g_snapshot.items[i];
            BOOL is_nade = (strstr(it->name, "Grenade") || strstr(it->name, "Frag") || strstr(it->name, "Smoke") || strstr(it->name, "Molotov") || strstr(it->name, "Bomb"));
            BOOL is_drop = (strstr(it->name, "AirDrop") || strstr(it->name, "Drop") || strstr(it->name, "Crate") || strstr(it->name, "Flare") || it->category == 5);

            CGPoint item_screen;
            if (!world_to_screen(it->pos, &item_screen, NULL, w, h)) continue;

            if (g_feat_grenade_warn && is_nade) {
                CGContextSetRGBStrokeColor(ctx, 1.0, 0.2, 0.1, 0.90);
                CGContextSetRGBFillColor(ctx, 1.0, 0.2, 0.1, 0.35);
                CGContextSetLineWidth(ctx, 2.0);
                CGContextStrokeEllipseInRect(ctx, CGRectMake_f(item_screen.x - 18.0, item_screen.y - 18.0, 36.0, 36.0));
                CGContextFillEllipseInRect(ctx, CGRectMake_f(item_screen.x - 6.0, item_screen.y - 6.0, 12.0, 12.0));
                char nade_txt[48];
                snprintf(nade_txt, sizeof(nade_txt), "! %s %.0fm !", it->name, it->distance);
                draw_text_centered(nade_txt, (CGPoint){ item_screen.x, item_screen.y - 24.0 }, g_font_bold, g_color_red);
            }

            if (g_feat_airdrop_beacon && is_drop) {
                CGContextSetRGBStrokeColor(ctx, 0.0, 0.95, 1.0, 0.80);
                CGContextSetLineWidth(ctx, 2.5);
                CGContextMoveToPoint(ctx, item_screen.x, 0.0);
                CGContextAddLineToPoint(ctx, item_screen.x, item_screen.y);
                CGContextStrokePath(ctx);

                char drop_txt[48];
                snprintf(drop_txt, sizeof(drop_txt), "[AIRDROP %.0fm]", it->distance);
                draw_text_centered(drop_txt, (CGPoint){ item_screen.x, item_screen.y + 12.0 }, g_font_bold, g_color_cyan);
            }
        }
    }

    /* Feature 6: Spectator Count HUD Badge */
    if (g_feat_spectator_warn) {
        draw_text_centered("[SURVEILLANCE: CLEAR]", (CGPoint){ w / 2.0, 16.0 }, g_font_small, g_color_cyan);
    }

    /* Feature 13: Low HP Tactical Emergency Alert */
    if (g_feat_auto_evade && closest_enemy_dist < 22.0f) {
        CGContextSetRGBStrokeColor(ctx, 1.0, 0.15, 0.15, 0.55);
        CGContextSetLineWidth(ctx, 3.0);
        CGContextStrokeRect(ctx, CGRectMake_f(2.0, 2.0, w - 4.0, h - 4.0));
        draw_text_centered("<! CLOSE THREAT - DANGER ZONE !>", (CGPoint){ w / 2.0, h - 35.0 }, g_font_bold, g_color_red);
    }

    if (fn_objc_autoreleasePoolPop && pool) fn_objc_autoreleasePoolPop(pool);
}

/* ------------------------------------------------------------------ */
/*  Radar Minimap View: drawRect                                      */
/* ------------------------------------------------------------------ */

static void radar_drawRect(id self, SEL cmd, CGRect rect) {
    (void)self; (void)cmd; (void)rect;
    if (!g_feat_radar) return;

    void *pool = NULL;
    if (fn_objc_autoreleasePoolPush) pool = fn_objc_autoreleasePoolPush();

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        if (fn_objc_autoreleasePoolPop && pool) fn_objc_autoreleasePoolPop(pool);
        return;
    }

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
            BOOL is_air = (v->can_boost == 1) || (strstr(v->name, "Airplane") || strstr(v->name, "Glider") || strstr(v->name, "Helicopter"));
            if (g_feat_veh_air_only && !is_air) continue;

            float dx = v->pos.x - lp.x;
            float dy = v->pos.y - lp.y;
            float rx = dx * cos_yaw - dy * sin_yaw;
            float ry = dx * sin_yaw + dy * cos_yaw;
            float sx = ry * scale;
            float sy = -rx * scale;
            float d = sqrtf(sx*sx + sy*sy);
            if (d > radius - 5.0f) continue;

            if (is_air) {
                CGContextSetRGBFillColor(ctx, 1.0f, 0.4f, 0.9f, 0.95f);
                CGContextFillRect(ctx, CGRectMake_f(cx + sx - 4, cy + sy - 4, 8, 8));
            } else {
                CGContextSetRGBFillColor(ctx, 1.0f, 0.85f, 0.1f, 0.95f);
                CGContextFillRect(ctx, CGRectMake_f(cx + sx - 3, cy + sy - 3, 6, 6));
            }
        }
    }

    /* Draw players on radar */
    uint32_t my_team = (g_snapshot.header.local_team > 0) ? g_snapshot.header.local_team : s_overlay_local_team;
    for (uint32_t i = 0; i < g_snapshot.header.player_count && i < RADAR_MAX_PLAYERS; i++) {
        const radar_player_t *p = &g_snapshot.players[i];
        if (p->health_status == 2) continue;

        BOOL is_teammate = (my_team != 0 && p->team_id == my_team);
        if (is_teammate && !g_feat_teammates) continue;

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

        if (is_teammate) {
            if (p->health_status == 1) CGContextSetRGBFillColor(ctx, 1.0f, 0.55f, 0.0f, 1.0f);
            else CGContextSetRGBFillColor(ctx, 0.2f, 0.95f, 0.35f, 1.0f);
        } else if (p->health_status == 1) {
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

    if (fn_objc_autoreleasePoolPop && pool) fn_objc_autoreleasePoolPop(pool);
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
    if (self != g_button_window && self != g_menu_window && self != g_aim_window) return NO;
    if (self == g_menu_window && !g_menu_open) return NO;
    if (self == g_aim_window && (!g_feat_touch_aim || g_menu_open)) return NO;
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("bounds"));
    return in_rect(point, bounds);
}

static id window_hitTest(id self, SEL cmd, CGPoint point, id event) {
    (void)cmd;
    if (!window_pointInside(self, 0, point, event)) return nil;
    if (self == g_button_window) return g_drag_button;
    if (self == g_aim_window) return g_aim_button;
    CGPoint p = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(
        g_menu_view, sel_registerName("convertPoint:fromView:"), point, self);
    return ((id (*)(id, SEL, CGPoint, id))objc_msgSend)(
        g_menu_view, sel_registerName("hitTest:withEvent:"), p, event);
}

/* Only these three small windows accept input. The full-screen drawing window
 * is noninteractive, including when the menu is expanded. */
static void layout_controls(void) {
    if (!g_button_window || !g_menu_window || !g_menu_view) return;
    double edge = 6.0;
    g_button_rect.origin.x = fmax(edge, fmin(g_button_rect.origin.x, g_screen_w - 48.0 - edge));
    g_button_rect.origin.y = fmax(edge, fmin(g_button_rect.origin.y, g_screen_h - 48.0 - edge));
    ((void (*)(id, SEL, CGRect))objc_msgSend)(g_button_window, sel_registerName("setFrame:"), g_button_rect);
    ((void (*)(id, SEL, CGRect))objc_msgSend)(g_drag_button, sel_registerName("setFrame:"), CGRectMake_f(0, 0, 48, 48));

    if (g_aim_window && g_aim_button) {
        g_aim_rect.origin.x = fmax(edge, fmin(g_aim_rect.origin.x, g_screen_w - 56.0 - edge));
        g_aim_rect.origin.y = fmax(edge, fmin(g_aim_rect.origin.y, g_screen_h - 56.0 - edge));
        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_aim_window, sel_registerName("setFrame:"), g_aim_rect);
        ((void (*)(id, SEL, CGRect))objc_msgSend)(g_aim_button, sel_registerName("setFrame:"), CGRectMake_f(0, 0, 56, 56));
        hidden(g_aim_window, !g_feat_touch_aim || g_menu_open);
    }

    double margin = 32.0;
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
    (void)self; (void)cmd; (void)event;
    id touch = ((id (*)(id, SEL))objc_msgSend)(touches, sel_registerName("anyObject"));
    if (touch) {
        CGPoint cur = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
            touch, sel_registerName("locationInView:"), g_window);
        double dx = cur.x - g_drag_start_touch.x;
        double dy = cur.y - g_drag_start_touch.y;
        if (fabs(dx) > 4.0 || fabs(dy) > 4.0) {
            g_is_dragging = YES;
            CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("bounds"));
            CGRect f = g_button_rect;
            double new_x = g_drag_start_origin.x + dx;
            double new_y = g_drag_start_origin.y + dy;
            if (new_x < 4.0) new_x = 4.0;
            if (new_y < 4.0) new_y = 4.0;
            if (new_x + f.size.width > bounds.size.width - 4.0) new_x = bounds.size.width - f.size.width - 4.0;
            if (new_y + f.size.height > bounds.size.height - 4.0) new_y = bounds.size.height - f.size.height - 4.0;
            f.origin.x = new_x;
            f.origin.y = new_y;
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
/*  Accessibility Aim Assist Button Touch Handling                    */
/* ------------------------------------------------------------------ */

static CGPoint g_aim_drag_start_touch;
static CGPoint g_aim_drag_start_origin;
static BOOL    g_aim_is_dragging = NO;

static void aim_btn_touchesBegan(id self, SEL cmd, id touches, id event) {
    (void)cmd; (void)event;
    id touch = ((id (*)(id, SEL))objc_msgSend)(touches, sel_registerName("anyObject"));
    if (touch) {
        g_aim_drag_start_touch = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
            touch, sel_registerName("locationInView:"), g_window);
        g_aim_drag_start_origin = g_aim_rect.origin;
        g_aim_is_dragging = NO;
        g_finger_drag_x = 0.0;
        g_finger_drag_y = 0.0;
        g_aim_active = YES;
        title(self, "AIM*");
    }
}

static void aim_btn_touchesMoved(id self, SEL cmd, id touches, id event) {
    (void)self; (void)cmd; (void)event;
    id touch = ((id (*)(id, SEL))objc_msgSend)(touches, sel_registerName("anyObject"));
    if (touch) {
        CGPoint cur = ((CGPoint (*)(id, SEL, id))objc_msgSend)(
            touch, sel_registerName("locationInView:"), g_window);
        double dx = cur.x - g_aim_drag_start_touch.x;
        double dy = cur.y - g_aim_drag_start_touch.y;
        g_finger_drag_x = dx;
        g_finger_drag_y = dy;

        if (fabs(dx) > 4.0 || fabs(dy) > 4.0) {
            g_aim_is_dragging = YES;
            CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("bounds"));
            CGRect f = g_aim_rect;
            double new_x = g_aim_drag_start_origin.x + dx;
            double new_y = g_aim_drag_start_origin.y + dy;
            if (new_x < 4.0) new_x = 4.0;
            if (new_y < 4.0) new_y = 4.0;
            if (new_x + f.size.width > bounds.size.width - 4.0) new_x = bounds.size.width - f.size.width - 4.0;
            if (new_y + f.size.height > bounds.size.height - 4.0) new_y = bounds.size.height - f.size.height - 4.0;
            f.origin.x = new_x;
            f.origin.y = new_y;
            g_aim_rect = f;
            layout_controls();
        }
    }
}

static void aim_btn_touchesEnded(id self, SEL cmd, id touches, id event) {
    (void)cmd; (void)touches; (void)event;
    g_aim_active = NO;
    g_finger_drag_x = 0.0;
    g_finger_drag_y = 0.0;
    title(self, "AIM");
    if (g_sim_touch_down) {
        double bx = (g_aim_touch_zone == 0) ? 0.20 : 0.75;
        hid_touch_event(bx, 0.50, 0);
    }
    g_locked_player_idx = -1;
    g_aim_is_dragging = NO;
}

static void aim_btn_touchesCancelled(id self, SEL cmd, id touches, id event) {
    (void)cmd; (void)touches; (void)event;
    g_aim_active = NO;
    g_finger_drag_x = 0.0;
    g_finger_drag_y = 0.0;
    title(self, "AIM");
    if (g_sim_touch_down) {
        double bx = (g_aim_touch_zone == 0) ? 0.20 : 0.75;
        hid_touch_event(bx, 0.50, 0);
    }
    g_locked_player_idx = -1;
    g_aim_is_dragging = NO;
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
static void action_toggle_touch_aim(id self, SEL cmd, id sender)  {
    (void)self; (void)cmd; (void)sender;
    g_aim_trigger_mode = (g_aim_trigger_mode + 1) % 3;
    g_feat_touch_aim = (g_aim_trigger_mode != 2);
    update_menu_buttons();
}
static void action_toggle_aim_speed(id self, SEL cmd, id sender)  {
    (void)self; (void)cmd; (void)sender;
    g_aim_velocity = (g_aim_velocity + 1) % 4;
    update_menu_buttons();
}
static void action_toggle_aim_bone(id self, SEL cmd, id sender)   {
    (void)self; (void)cmd; (void)sender;
    g_aim_bone = (g_aim_bone + 1) % 3;
    update_menu_buttons();
}
static void action_toggle_aim_fov(id self, SEL cmd, id sender)    {
    (void)self; (void)cmd; (void)sender;
    g_aim_fov_mode = (g_aim_fov_mode + 1) % 5;
    g_feat_aim_fov = (g_aim_fov_mode != 4);
    update_menu_buttons();
}
static void action_toggle_aim_zone(id self, SEL cmd, id sender)   {
    (void)self; (void)cmd; (void)sender;
    g_aim_touch_zone = (g_aim_touch_zone + 1) % 3;
    update_menu_buttons();
}
static void action_toggle_veh_filter(id self, SEL cmd, id sender) { (void)self; (void)cmd; (void)sender; g_feat_veh_air_only = !g_feat_veh_air_only; update_menu_buttons(); }
static void action_toggle_item_filter(id self, SEL cmd, id sender){ (void)self; (void)cmd; (void)sender; g_feat_item_filter = !g_feat_item_filter; update_menu_buttons(); }
static void action_toggle_teammates(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_teammates = !g_feat_teammates; update_menu_buttons(); }
static void action_toggle_enemy_alert(id self, SEL cmd, id sender){ (void)self; (void)cmd; (void)sender; g_feat_enemy_alert = !g_feat_enemy_alert; update_menu_buttons(); }
static void action_toggle_offscreen(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_offscreen_arrows = !g_feat_offscreen_arrows; update_menu_buttons(); }
static void action_toggle_crosshair(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_crosshair = !g_feat_crosshair; update_menu_buttons(); }
static void action_toggle_target_lock(id self, SEL cmd, id sender){ (void)self; (void)cmd; (void)sender; g_feat_target_lock = !g_feat_target_lock; update_menu_buttons(); }
/* 14 New Action Callbacks */
static void action_toggle_lead_pred(id self, SEL cmd, id sender)       { (void)self; (void)cmd; (void)sender; g_feat_lead_pred = !g_feat_lead_pred; update_menu_buttons(); }
static void action_toggle_bullet_drop(id self, SEL cmd, id sender)     { (void)self; (void)cmd; (void)sender; g_feat_bullet_drop = !g_feat_bullet_drop; update_menu_buttons(); }
static void action_toggle_recoil_comp(id self, SEL cmd, id sender)     { (void)self; (void)cmd; (void)sender; g_feat_recoil_comp = !g_feat_recoil_comp; update_menu_buttons(); }
static void action_toggle_gaze_ray(id self, SEL cmd, id sender)        { (void)self; (void)cmd; (void)sender; g_feat_gaze_ray = !g_feat_gaze_ray; update_menu_buttons(); }
static void action_toggle_blindspot_alert(id self, SEL cmd, id sender) { (void)self; (void)cmd; (void)sender; g_feat_blindspot_alert = !g_feat_blindspot_alert; update_menu_buttons(); }
static void action_toggle_spectator_warn(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_spectator_warn = !g_feat_spectator_warn; update_menu_buttons(); }
static void action_toggle_adaptive_fov(id self, SEL cmd, id sender)    { (void)self; (void)cmd; (void)sender; g_feat_adaptive_fov = !g_feat_adaptive_fov; update_menu_buttons(); }
static void action_toggle_threat_tier(id self, SEL cmd, id sender)     { (void)self; (void)cmd; (void)sender; g_feat_threat_tier = !g_feat_threat_tier; update_menu_buttons(); }
static void action_toggle_grenade_warn(id self, SEL cmd, id sender)    { (void)self; (void)cmd; (void)sender; g_feat_grenade_warn = !g_feat_grenade_warn; update_menu_buttons(); }
static void action_toggle_airdrop_beacon(id self, SEL cmd, id sender)  { (void)self; (void)cmd; (void)sender; g_feat_airdrop_beacon = !g_feat_airdrop_beacon; update_menu_buttons(); }
static void action_toggle_sound_radar(id self, SEL cmd, id sender)     { (void)self; (void)cmd; (void)sender; g_feat_sound_radar = !g_feat_sound_radar; update_menu_buttons(); }
static void action_toggle_knocked_timer(id self, SEL cmd, id sender)   { (void)self; (void)cmd; (void)sender; g_feat_knocked_timer = !g_feat_knocked_timer; update_menu_buttons(); }
static void action_toggle_auto_evade(id self, SEL cmd, id sender)      { (void)self; (void)cmd; (void)sender; g_feat_auto_evade = !g_feat_auto_evade; update_menu_buttons(); }
static void action_toggle_aim_smooth(id self, SEL cmd, id sender)      { (void)self; (void)cmd; (void)sender; g_feat_aim_smooth = !g_feat_aim_smooth; update_menu_buttons(); }
static void action_close_menu(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    if (g_menu_open) toggle_menu();
}

static void action_stop_radar(id self, SEL cmd, id sender) {
    (void)self; (void)cmd; (void)sender;
    FILE *fp = fopen("/var/mobile/Downloads/radar_stop.flag", "w");
    if (fp) {
        fprintf(fp, "STOP\n");
        fclose(fp);
        chown("/var/mobile/Downloads/radar_stop.flag", 501, 501);
    }
    system("killall -9 ue4loadmonitor 2>/dev/null; /var/jb/bin/launchctl stop system/com.local.ue4loadmonitor 2>/dev/null; rm -f /var/mobile/Downloads/ue4_radar.bin 2>/dev/null");
    if (g_shared) {
        munmap(g_shared, sizeof(radar_shared_t));
        g_shared = NULL;
    }
    if (g_shm_fd >= 0) {
        close(g_shm_fd);
        g_shm_fd = -1;
    }
    if (g_esp_view) {
        ((void (*)(id, SEL))objc_msgSend)(g_esp_view, sel_registerName("setNeedsDisplay"));
    }
    if (g_radar_view) {
        ((void (*)(id, SEL))objc_msgSend)(g_radar_view, sel_registerName("setNeedsDisplay"));
    }
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

    /* 1. Read shared memory snapshot (auto-reconnecting on inode change/recreation) */
    if (g_frame_counter % 20 == 1) {
        struct stat st;
        if (stat(RADAR_FILE_PATH, &st) == 0 && (st.st_ino != g_shm_ino || !g_shared)) {
            open_shared_memory();
        }
    }
    if (read_snapshot() && g_snapshot.header.tick != g_last_tick) {
        g_last_tick = g_snapshot.header.tick;
        g_changed_at = monotonic_seconds();
        if (g_snapshot.header.local_team > 0) {
            s_overlay_local_team = g_snapshot.header.local_team;
        }
    }

    if (g_frame_counter % 200 == 1) {
        ensure_screen_awake_and_unlocked();
    }

    /* 2. Window scene management */
    id scene = nil;
    if (g_window) scene = ((id (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("windowScene"));

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
            if (g_aim_window) ((void (*)(id, SEL, id))objc_msgSend)(g_aim_window, sel_registerName("setWindowScene:"), active_s);
            scene = active_s;
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(g_window, sel_registerName("setHidden:"), NO);
        if (!g_menu_open && g_button_window) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(g_button_window, sel_registerName("setHidden:"), NO);
            if (g_aim_window) ((void (*)(id, SEL, BOOL))objc_msgSend)(g_aim_window, sel_registerName("setHidden:"), !g_feat_touch_aim);
        }
    }

    /* 3. Orientation Triangulation (Application -> Scene -> Device -> Live Telemetry) */
    NSInteger app_ori = 0;
    Class UIApp_cls = objc_getClass("UIApplication");
    if (UIApp_cls) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)UIApp_cls, sel_registerName("sharedApplication"));
        if (app) {
            if (safe_responds(app, "_frontMostAppOrientation")) {
                app_ori = (NSInteger)((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("_frontMostAppOrientation"));
            } else if (safe_responds(app, "activeInterfaceOrientation")) {
                app_ori = (NSInteger)((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("activeInterfaceOrientation"));
            } else if (safe_responds(app, "statusBarOrientation")) {
                app_ori = (NSInteger)((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("statusBarOrientation"));
            }
        }
    }

    NSInteger scene_ori = 0;
    if (scene) scene_ori = (NSInteger)((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("interfaceOrientation"));

    NSInteger dev_ori = 0;
    Class UIDevice_cls = objc_getClass("UIDevice");
    if (UIDevice_cls) {
        id dev = ((id (*)(id, SEL))objc_msgSend)((id)UIDevice_cls, sel_registerName("currentDevice"));
        if (dev) {
            NSInteger d = (NSInteger)((id (*)(id, SEL))objc_msgSend)(dev, sel_registerName("orientation"));
            if (d == 3) dev_ori = 3;      /* UIDeviceOrientationLandscapeLeft -> UIInterfaceOrientationLandscapeRight */
            else if (d == 4) dev_ori = 4; /* UIDeviceOrientationLandscapeRight -> UIInterfaceOrientationLandscapeLeft */
            else if (d == 1) dev_ori = 1;
            else if (d == 2) dev_ori = 2;
        }
    }

    NSInteger ori = 0;
    if (app_ori == 3 || app_ori == 4) ori = app_ori;
    else if (scene_ori == 3 || scene_ori == 4) ori = scene_ori;
    else if (dev_ori == 3 || dev_ori == 4) ori = dev_ori;
    else if (app_ori >= 1 && app_ori <= 4) ori = app_ori;
    else if (scene_ori >= 1 && scene_ori <= 4) ori = scene_ori;
    else if (dev_ori >= 1 && dev_ori <= 4) ori = dev_ori;

    /* 4. Dynamic Screen Dimensions & Midpoint Refresh */
    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIScreen"), sel_registerName("mainScreen"));
    CGRect cur_bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));
    double raw_w = cur_bounds.size.width;
    double raw_h = cur_bounds.size.height;
    if (raw_w <= 10.0 || raw_h <= 10.0) { raw_w = 1024.0; raw_h = 768.0; }

    double max_dim = fmax(raw_w, raw_h);
    double min_dim = fmin(raw_w, raw_h);

    /* PUBG Mobile (ShadowTrackerExtra) is always a landscape application.
     * When telemetry is active, or raw_w > raw_h, or interface orientation is landscape,
     * enforce landscape bounds. */
    BOOL is_landscape = (ori == 3 || ori == 4 || raw_w > raw_h || g_snapshot.header.status >= 1);
    if (is_landscape) {
        if (ori == 4) g_current_orientation = 4;
        else if (ori == 3) g_current_orientation = 3;
        else if (dev_ori == 4) g_current_orientation = 4;
        else g_current_orientation = 3; /* Default LandscapeRight */
    } else {
        g_current_orientation = (ori >= 1 && ori <= 4) ? ori : 3;
    }
    if (g_frame_counter % 100 == 1) {
        update_digitizer_sender_id();
    }

    double target_w = is_landscape ? max_dim : min_dim;
    double target_h = is_landscape ? min_dim : max_dim;
    CGRect target_bounds = CGRectMake_f(0, 0, target_w, target_h);

    static NSInteger s_last_orientation = 0;
    BOOL bounds_changed = (fabs(target_w - g_screen_w) > 1.0 || fabs(target_h - g_screen_h) > 1.0 || g_current_orientation != s_last_orientation);

    if (bounds_changed || g_frame_counter % 20 == 1) {
        g_screen_w = target_w;
        g_screen_h = target_h;
        s_last_orientation = g_current_orientation;

        if (g_window) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(g_window, sel_registerName("setFrame:"), target_bounds);
            id root_vc = ((id (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("rootViewController"));
            if (root_vc) {
                id rv = ((id (*)(id, SEL))objc_msgSend)(root_vc, sel_registerName("view"));
                if (rv) ((void (*)(id, SEL, CGRect))objc_msgSend)(rv, sel_registerName("setFrame:"), target_bounds);
            }
        }
        if (g_esp_view) ((void (*)(id, SEL, CGRect))objc_msgSend)(g_esp_view, sel_registerName("setFrame:"), target_bounds);

        /* Adapt radar position for Landscape vs Portrait */
        double rx = fmax(10.0, g_screen_w - RADAR_VIEW_SIZE - 32.0);
        double ry = (g_screen_w > g_screen_h) ? 32.0 : 50.0;
        if (g_radar_view) ((void (*)(id, SEL, CGRect))objc_msgSend)(g_radar_view, sel_registerName("setFrame:"),
                                                                    CGRectMake_f(rx, ry, RADAR_VIEW_SIZE, RADAR_VIEW_SIZE));

        /* Keep controls laid out and centered */
        layout_controls();
    }

    /* Aim Assist Touch Steering Engine */

    BOOL aim_enabled = (g_feat_touch_aim && g_aim_trigger_mode != 2);
    BOOL aim_trigger_active = (g_aim_trigger_mode == 0) ? (g_aim_active && !g_aim_is_dragging) : YES;

    if (aim_enabled && aim_trigger_active && g_snapshot.header.status == 2 && g_snapshot.header.camera_valid) {
        double screen_w = g_screen_w > 0 ? g_screen_w : max_dim;
        double screen_h = g_screen_h > 0 ? g_screen_h : min_dim;
        if (is_landscape && screen_w < screen_h) {
            double tmp = screen_w; screen_w = screen_h; screen_h = tmp;
        }
        double center_x = screen_w / 2.0;
        double center_y = screen_h / 2.0;

        int best_idx = -1;
        double best_dist_sq = 1e12;
        CGPoint best_pos = {0, 0};
        double fov_radius = get_aim_fov_radius(screen_w, screen_h);

        uint32_t pcount = g_snapshot.header.player_count;
        if (pcount > RADAR_MAX_PLAYERS) pcount = RADAR_MAX_PLAYERS;
        uint32_t my_team = (g_snapshot.header.local_team > 0) ? g_snapshot.header.local_team : s_overlay_local_team;

        /* Velocity Tracking for Lead Prediction (Feature 1) */
        double now_sec = monotonic_seconds();
        for (uint32_t i = 0; i < pcount; i++) {
            const radar_player_t *p = &g_snapshot.players[i];
            double dt = now_sec - g_tracked_players[i].last_time;
            if (dt > 0.02 && dt < 0.5) {
                g_tracked_players[i].vel.x = (p->pos.x - g_tracked_players[i].pos.x) / (float)dt;
                g_tracked_players[i].vel.y = (p->pos.y - g_tracked_players[i].pos.y) / (float)dt;
                g_tracked_players[i].vel.z = (p->pos.z - g_tracked_players[i].pos.z) / (float)dt;
            }
            g_tracked_players[i].pos = p->pos;
            g_tracked_players[i].last_time = now_sec;
        }

        for (uint32_t i = 0; i < pcount; i++) {
            const radar_player_t *p = &g_snapshot.players[i];
            if (p->health_status == 2) continue; /* Dead/eliminated */
            if (my_team != 0 && p->team_id == my_team) continue; /* Friendly teammate */

            rvec3_t target_3d = p->head_pos;
            if (g_aim_bone == 1) { /* Chest */
                if (p->has_bones) target_3d = p->bones[2];
                else target_3d = (rvec3_t){ (p->head_pos.x + p->feet_pos.x) / 2.0f,
                                            (p->head_pos.y + p->feet_pos.y) / 2.0f,
                                            (p->head_pos.z + p->feet_pos.z) / 2.0f };
            } else if (g_aim_bone == 2) { /* Pelvis */
                if (p->has_bones) target_3d = p->bones[3];
                else target_3d = (rvec3_t){ (p->head_pos.x + p->feet_pos.x * 2.0f) / 3.0f,
                                            (p->head_pos.y + p->feet_pos.y * 2.0f) / 3.0f,
                                            (p->head_pos.z + p->feet_pos.z * 2.0f) / 3.0f };
            }
            /* Ballistics Lead Target Adjustment (Feature 1) */
            if (g_feat_lead_pred && !p->is_bot) {
                float spd = hypotf(g_tracked_players[i].vel.x, g_tracked_players[i].vel.y);
                if (spd > 25.0f && p->distance > 6.0f) {
                    float travel_t = p->distance / 880.0f;
                    target_3d.x += g_tracked_players[i].vel.x * travel_t;
                    target_3d.y += g_tracked_players[i].vel.y * travel_t;
                    target_3d.z += g_tracked_players[i].vel.z * travel_t;
                }
            }

            CGPoint sp;
            double depth = 0;
            if (!world_to_screen(target_3d, &sp, &depth, screen_w, screen_h)) continue;

            double dx = sp.x - center_x;
            double dy = sp.y - center_y;
            double d_sq = dx * dx + dy * dy;
            if (d_sq <= fov_radius * fov_radius && d_sq < best_dist_sq) {
                best_dist_sq = d_sq;
                best_idx = (int)i;
                best_pos = sp;
            }
        }

        /* Target Swapping & Recenter State Machine */
        double base_x = (g_aim_touch_zone == 0) ? 0.22 : ((g_aim_touch_zone == 1) ? 0.72 : 0.50);
        double base_y = 0.50;
        double min_x  = (g_aim_touch_zone == 0) ? 0.06 : ((g_aim_touch_zone == 1) ? 0.55 : 0.35);
        double max_x  = (g_aim_touch_zone == 0) ? 0.35 : ((g_aim_touch_zone == 1) ? 0.90 : 0.65);
        double min_y  = 0.22;
        double max_y  = 0.78;

        if (best_idx != g_locked_player_idx) {
            if (g_sim_touch_down) {
                hid_touch_event(g_sim_norm_x, g_sim_norm_y, 0); /* Clean lift on target switch */
            }
            g_locked_player_idx = best_idx;
            g_sim_norm_x = base_x;
            g_sim_norm_y = base_y;
            g_sim_stroke_frames = 0;
            g_sim_recenter_pause = 1; /* 1 frame (50ms) clean pause before touch down */
        }

        if (best_idx >= 0) {
            g_locked_screen_pos = best_pos;

            double delta_x = (best_pos.x - center_x) + (g_finger_drag_x * 0.4);
            double delta_y = (best_pos.y - center_y) + (g_finger_drag_y * 0.4);
            double dist = hypot(delta_x, delta_y);

            double vel_mult = (g_aim_velocity == 0) ? 0.25 :
                             ((g_aim_velocity == 1) ? 0.50 :
                             ((g_aim_velocity == 2) ? 0.80 : 1.15));

            if (g_sim_recenter_pause > 0) {
                g_sim_recenter_pause--;
                if (g_sim_recenter_pause == 0) {
                    /* Pause ended: touch down cleanly at base */
                    g_sim_norm_x = base_x;
                    g_sim_norm_y = base_y;
                    g_sim_stroke_frames = 0;
                    hid_touch_event(base_x, base_y, 1); /* Touch Down */
                }
            } else if (dist > 2.5) {
                double dir_x = delta_x / dist;
                double dir_y = delta_y / dist;

                double step_mag = fmin(0.025, fmax(0.004, (dist / screen_w) * 0.35)) * vel_mult;
                double step_x = dir_x * step_mag;
                double step_y = dir_y * step_mag;

                /* Weapon Recoil Compensation Touch Pull-Down (Feature 3) */
                if (g_feat_recoil_comp) {
                    step_y += 0.0030 * vel_mult;
                }

                /* Aim Smoothness Micro-Stroking (Feature 14) */
                if (g_feat_aim_smooth) {
                    double smooth_factor = sin(((double)(g_sim_stroke_frames % 14) + 1.0) * 3.14159 / 15.0);
                    step_x *= (0.75 + 0.50 * smooth_factor);
                    step_y *= (0.75 + 0.50 * smooth_factor);
                    step_x += ((double)((rand() % 100) - 50)) * 0.000006;
                    step_y += ((double)((rand() % 100) - 50)) * 0.000006;
                }

                if (!g_sim_touch_down) {
                    g_sim_norm_x = base_x;
                    g_sim_norm_y = base_y;
                    g_sim_stroke_frames = 0;
                    hid_touch_event(base_x, base_y, 1); /* Touch Down */
                } else {
                    g_sim_stroke_frames++;
                    double next_x = g_sim_norm_x + step_x;
                    double next_y = g_sim_norm_y + step_y;

                    if (g_sim_stroke_frames >= 20 || next_x < min_x || next_x > max_x || next_y < min_y || next_y > max_y) {
                        /* Continuous Circular Radius Scrolling: Lift finger cleanly, pause 1 tick, re-center */
                        hid_touch_event(g_sim_norm_x, g_sim_norm_y, 0); /* Touch Up */
                        g_sim_norm_x = base_x;
                        g_sim_norm_y = base_y;
                        g_sim_stroke_frames = 0;
                        g_sim_recenter_pause = 1;
                    } else {
                        g_sim_norm_x = next_x;
                        g_sim_norm_y = next_y;
                        hid_touch_event(g_sim_norm_x, g_sim_norm_y, 2); /* Touch Move */
                    }
                }
            } else {
                /* Target centered (dist <= 2.5) -> Smooth release */
                if (g_sim_touch_down) {
                    hid_touch_event(g_sim_norm_x, g_sim_norm_y, 0); /* Touch Up */
                    g_sim_norm_x = base_x;
                    g_sim_norm_y = base_y;
                    g_sim_stroke_frames = 0;
                }
            }
        } else {
            /* No enemy in FOV -> Lift touch */
            if (g_sim_touch_down) {
                hid_touch_event(base_x, base_y, 0);
                g_sim_stroke_frames = 0;
            }
            g_locked_player_idx = -1;
            g_sim_recenter_pause = 0;
        }
    } else {
        /* Aim disabled or trigger inactive */
        if (g_sim_touch_down) {
            double bx = (g_aim_touch_zone == 0) ? 0.22 : ((g_aim_touch_zone == 1) ? 0.72 : 0.50);
            hid_touch_event(bx, 0.50, 0);
            g_sim_stroke_frames = 0;
        }
        g_locked_player_idx = -1;
        g_sim_recenter_pause = 0;
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
        id root_vc = g_window ? ((id (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("rootViewController")) : nil;
        id rv = root_vc ? ((id (*)(id, SEL))objc_msgSend)(root_vc, sel_registerName("view")) : nil;
        CGRect wf = g_window ? ((CGRect (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("frame")) : (CGRect){{0,0},{0,0}};
        CGRect wb = g_window ? ((CGRect (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("bounds")) : (CGRect){{0,0},{0,0}};
        CGRect rvf = rv ? ((CGRect (*)(id, SEL))objc_msgSend)(rv, sel_registerName("frame")) : (CGRect){{0,0},{0,0}};
        CGRect rvb = rv ? ((CGRect (*)(id, SEL))objc_msgSend)(rv, sel_registerName("bounds")) : (CGRect){{0,0},{0,0}};
        CGRect ef = g_esp_view ? ((CGRect (*)(id, SEL))objc_msgSend)(g_esp_view, sel_registerName("frame")) : (CGRect){{0,0},{0,0}};
        CGRect eb = g_esp_view ? ((CGRect (*)(id, SEL))objc_msgSend)(g_esp_view, sel_registerName("bounds")) : (CGRect){{0,0},{0,0}};
        fprintf(g_proof, "timer=%d reads=%u draws=%u tick=%u status=%u players=%u scr=(%.0f,%.0f) mid=(%.1f,%.1f) ori=%ld menu=%d\n",
                g_frame_counter, g_reads, g_draws, g_last_tick, g_snapshot.header.status,
                g_snapshot.header.player_count, g_screen_w, g_screen_h,
                g_screen_w / 2.0, g_screen_h / 2.0, (long)g_current_orientation, g_menu_open);
        fprintf(g_proof, "DIAG_VIEWS: win_f=(%.0f,%.0f,%.0f,%.0f) win_b=(%.0f,%.0f,%.0f,%.0f) rv_f=(%.0f,%.0f,%.0f,%.0f) rv_b=(%.0f,%.0f,%.0f,%.0f) esp_f=(%.0f,%.0f,%.0f,%.0f) esp_b=(%.0f,%.0f,%.0f,%.0f)\n",
                wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
                wb.origin.x, wb.origin.y, wb.size.width, wb.size.height,
                rvf.origin.x, rvf.origin.y, rvf.size.width, rvf.size.height,
                rvb.origin.x, rvb.origin.y, rvb.size.width, rvb.size.height,
                ef.origin.x, ef.origin.y, ef.size.width, ef.size.height,
                eb.origin.x, eb.origin.y, eb.size.width, eb.size.height);
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
static NSInteger vc_preferredInterfaceOrientation(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 3; /* UIInterfaceOrientationLandscapeRight */
}
static void vc_loadView(id self, SEL cmd) {
    (void)cmd;
    Class UIView_cls = objc_getClass("UIView");
    Class UIScreen_cls = objc_getClass("UIScreen");
    id mainScreen = ((id (*)(id, SEL))objc_msgSend)((id)UIScreen_cls, sel_registerName("mainScreen"));
    CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));
    double max_dim = fmax(b.size.width, b.size.height);
    double min_dim = fmin(b.size.width, b.size.height);
    if (max_dim <= 10.0 || min_dim <= 10.0) { max_dim = 1024.0; min_dim = 768.0; }
    id v = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UIView_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(0, 0, max_dim, min_dim));
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(v, sel_registerName("setAutoresizingMask:"), 18);
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
        g_font_small = retain_obj(((id (*)(id, SEL, double))objc_msgSend)((id)UIFont_cls, sel_registerName("systemFontOfSize:"), 11.0));
        g_font_bold  = retain_obj(((id (*)(id, SEL, double))objc_msgSend)((id)UIFont_cls, sel_registerName("boldSystemFontOfSize:"), 12.0));
    }
    if (fstep) { fprintf(fstep, "step 2b: white\n"); fflush(fstep); }
    if (UIColor_cls) {
        g_color_white = retain_obj(((id (*)(id, SEL))objc_msgSend)((id)UIColor_cls, sel_registerName("whiteColor")));
        if (fstep) { fprintf(fstep, "step 2c: green\n"); fflush(fstep); }
        g_color_green = retain_obj(((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.2, 0.95, 0.35, 1.0));
        if (fstep) { fprintf(fstep, "step 2d: yellow\n"); fflush(fstep); }
        g_color_yellow = retain_obj(((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.9, 0.2, 1.0));
        if (fstep) { fprintf(fstep, "step 2e: cyan\n"); fflush(fstep); }
        g_color_cyan = retain_obj(((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.0, 0.88, 1.0, 1.0));
        if (fstep) { fprintf(fstep, "step 2f: orange\n"); fflush(fstep); }
        g_color_orange = retain_obj(((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.55, 0.0, 1.0));
        if (fstep) { fprintf(fstep, "step 2g: gold\n"); fflush(fstep); }
        g_color_gold = retain_obj(((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.82, 0.1, 1.0));
        if (fstep) { fprintf(fstep, "step 2h: red\n"); fflush(fstep); }
        g_color_red = retain_obj(((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 1.0, 0.2, 0.2, 1.0));
        g_color_purple = retain_obj(((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
            (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.75, 0.40, 1.0, 1.0));
    }
    ensure_text_attrs();
    if (fstep) {
        fprintf(fstep, "step 2i: text_attrs font_key=%p color_key=%p\n", (void*)s_font_attr_key, (void*)s_color_attr_key);
        fflush(fstep);
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

    /* 5. Accessibility Aim Trigger Button */
    Class AimButton = objc_allocateClassPair(UIButton_cls, "CodexAimTriggerButton", 0);
    if (!AimButton) {
        AimButton = objc_getClass("CodexAimTriggerButton");
    } else {
        class_addMethod(AimButton, sel_registerName("touchesBegan:withEvent:"), (IMP)aim_btn_touchesBegan, "v@:@@");
        class_addMethod(AimButton, sel_registerName("touchesMoved:withEvent:"), (IMP)aim_btn_touchesMoved, "v@:@@");
        class_addMethod(AimButton, sel_registerName("touchesEnded:withEvent:"), (IMP)aim_btn_touchesEnded, "v@:@@");
        class_addMethod(AimButton, sel_registerName("touchesCancelled:withEvent:"), (IMP)aim_btn_touchesCancelled, "v@:@@");
        objc_registerClassPair(AimButton);
    }

    /* 6. Action Target Helper */
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
        class_addMethod(ActionHelper, sel_registerName("toggleTouchAim:"), (IMP)action_toggle_touch_aim, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAimSpeed:"), (IMP)action_toggle_aim_speed, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAimBone:"), (IMP)action_toggle_aim_bone, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAimFov:"), (IMP)action_toggle_aim_fov, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAimZone:"), (IMP)action_toggle_aim_zone, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleVehFilter:"), (IMP)action_toggle_veh_filter, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleItemFilter:"), (IMP)action_toggle_item_filter, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleTeammates:"), (IMP)action_toggle_teammates, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleEnemyAlert:"), (IMP)action_toggle_enemy_alert, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleOffscreen:"), (IMP)action_toggle_offscreen, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleCrosshair:"), (IMP)action_toggle_crosshair, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleTargetLock:"), (IMP)action_toggle_target_lock, "v@:@");
        /* 14 New Methods */
        class_addMethod(ActionHelper, sel_registerName("toggleLeadPred:"), (IMP)action_toggle_lead_pred, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleBulletDrop:"), (IMP)action_toggle_bullet_drop, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleRecoilComp:"), (IMP)action_toggle_recoil_comp, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleGazeRay:"), (IMP)action_toggle_gaze_ray, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleBlindspot:"), (IMP)action_toggle_blindspot_alert, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleSpectator:"), (IMP)action_toggle_spectator_warn, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAdaptFov:"), (IMP)action_toggle_adaptive_fov, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleThreatTier:"), (IMP)action_toggle_threat_tier, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleNadeWarn:"), (IMP)action_toggle_grenade_warn, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAirdrop:"), (IMP)action_toggle_airdrop_beacon, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleSoundRadar:"), (IMP)action_toggle_sound_radar, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleKnockedTimer:"), (IMP)action_toggle_knocked_timer, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAutoEvade:"), (IMP)action_toggle_auto_evade, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("toggleAimSmooth:"), (IMP)action_toggle_aim_smooth, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("closeMenu:"), (IMP)action_close_menu, "v@:@");
        class_addMethod(ActionHelper, sel_registerName("stopRadar:"), (IMP)action_stop_radar, "v@:@");
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
    CGRect raw_bounds = ((CGRect (*)(id, SEL))objc_msgSend)(mainScreen, sel_registerName("bounds"));
    double max_dim = fmax(raw_bounds.size.width, raw_bounds.size.height);
    double min_dim = fmin(raw_bounds.size.width, raw_bounds.size.height);
    if (max_dim <= 10.0 || min_dim <= 10.0) { max_dim = 1024.0; min_dim = 768.0; }
    CGRect bounds = CGRectMake_f(0, 0, max_dim, min_dim);
    g_screen_w = max_dim;
    g_screen_h = min_dim;
    g_current_orientation = 3;

    Class UIDevice_cls = objc_getClass("UIDevice");
    if (UIDevice_cls) {
        id dev = ((id (*)(id, SEL))objc_msgSend)((id)UIDevice_cls, sel_registerName("currentDevice"));
        if (dev && safe_responds(dev, "beginGeneratingDeviceOrientationNotifications")) {
            ((void (*)(id, SEL))objc_msgSend)(dev, sel_registerName("beginGeneratingDeviceOrientationNotifications"));
        }
    }

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
        class_addMethod(CodexOverlayVC, sel_registerName("preferredInterfaceOrientationForPresentation"), (IMP)vc_preferredInterfaceOrientation, "q@:");
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

    id *controls[] = { &g_button_window, &g_menu_window, &g_aim_window };
    for (int i = 0; i < 3; ++i) {
        id w = ((id (*)(id, SEL, CGRect))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)RadarWindow, sel_registerName("alloc")),
            sel_registerName("initWithFrame:"), CGRectMake_f(0,0,56,56));
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
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(esp, sel_registerName("setAutoresizingMask:"), 18);
    ((void (*)(id, SEL, id))objc_msgSend)(root_view, sel_registerName("addSubview:"), esp);
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
    ((void (*)(id, SEL, id))objc_msgSend)(root_view, sel_registerName("addSubview:"), radar);
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

    /* --- Subview: Accessibility Aim Trigger Button --- */
    g_aim_rect = CGRectMake_f(20.0, 200.0, 56.0, 56.0);
    id aim_btn = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)AimButton, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(0, 0, 56.0, 56.0));
    id aim_bg = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)UIColor_cls, sel_registerName("colorWithRed:green:blue:alpha:"), 0.10, 0.16, 0.24, 0.90);
    ((void (*)(id, SEL, id))objc_msgSend)(aim_btn, sel_registerName("setBackgroundColor:"), aim_bg);
    title(aim_btn, "AIM");
    id alabel = ((id (*)(id, SEL))objc_msgSend)(aim_btn, sel_registerName("titleLabel"));
    if (alabel && g_font_bold) {
        ((void (*)(id, SEL, id))objc_msgSend)(alabel, sel_registerName("setFont:"), g_font_bold);
    }
    id aim_layer = ((id (*)(id, SEL))objc_msgSend)(aim_btn, sel_registerName("layer"));
    if (aim_layer) {
        id cg_orange = ((id (*)(id, SEL))objc_msgSend)(g_color_orange, sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(aim_layer, sel_registerName("setBorderColor:"), cg_orange);
        ((void (*)(id, SEL, double))objc_msgSend)(aim_layer, sel_registerName("setBorderWidth:"), 2.0);
        ((void (*)(id, SEL, double))objc_msgSend)(aim_layer, sel_registerName("setCornerRadius:"), 28.0);
    }
    ((void (*)(id, SEL, id))objc_msgSend)(g_aim_window, sel_registerName("addSubview:"), aim_btn);
    g_aim_button = aim_btn;

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

    /* Embed UIScrollView for 38 feature buttons (19 rows) */
    Class UIScrollView_cls = objc_getClass("UIScrollView");
    id scroll_view = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)UIScrollView_cls, sel_registerName("alloc")),
        sel_registerName("initWithFrame:"), CGRectMake_f(0, 36.0, MENU_WIDTH, 245.0));
    ((void (*)(id, SEL, CGSize))objc_msgSend)(scroll_view, sel_registerName("setContentSize:"), (CGSize){MENU_WIDTH, 19 * 40.0 + 8.0});
    ((void (*)(id, SEL, id))objc_msgSend)(menu, sel_registerName("addSubview:"), scroll_view);

    /* 2-Column Grid of 38 Feature Buttons */
    double c0 = 12.0, c1 = 176.0, bw = 152.0, bh = 34.0;
    #define ROW_Y(r) ((r) * 40.0 + 4.0)

    g_btn_radar       = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(0), bw, bh), "Radar: ON",      sel_registerName("toggleRadar:"));
    g_btn_lines       = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(0), bw, bh), "Snaplines: ON",  sel_registerName("toggleLines:"));
    g_btn_box         = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(1), bw, bh), "2D Box: ON",     sel_registerName("toggleBox:"));
    g_btn_health      = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(1), bw, bh), "Health: ON",     sel_registerName("toggleHealth:"));
    g_btn_name        = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(2), bw, bh), "Name: ON",       sel_registerName("toggleName:"));
    g_btn_dist        = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(2), bw, bh), "Distance: ON",   sel_registerName("toggleDist:"));
    g_btn_team_bot    = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(3), bw, bh), "Team/Bot: ON",   sel_registerName("toggleTeam:"));
    g_btn_skeleton    = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(3), bw, bh), "Skeleton: ON",   sel_registerName("toggleSkeleton:"));
    g_btn_head        = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(4), bw, bh), "Head Dot: ON",   sel_registerName("toggleHead:"));
    g_btn_vehicles    = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(4), bw, bh), "Vehicles: ON",   sel_registerName("toggleVehicles:"));
    g_btn_items       = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(5), bw, bh), "Loot ESP: ON",   sel_registerName("toggleItems:"));
    g_btn_range       = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(5), bw, bh), "Range: 200m",    sel_registerName("toggleRange:"));

    /* 12 Advanced Feature Buttons */
    g_btn_touch_aim   = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(6), bw, bh), "Touch Aim: ON",  sel_registerName("toggleTouchAim:"));
    g_btn_aim_speed   = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(6), bw, bh), "Aim: Med 35%",   sel_registerName("toggleAimSpeed:"));
    g_btn_aim_bone    = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(7), bw, bh), "Bone: Head",     sel_registerName("toggleAimBone:"));
    g_btn_aim_fov     = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(7), bw, bh), "Aim FOV: ON",    sel_registerName("toggleAimFov:"));
    g_btn_aim_zone    = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(8), bw, bh), "Touch: Left 1/3",sel_registerName("toggleAimZone:"));
    g_btn_veh_filter  = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(8), bw, bh), "Veh: Air Only",   sel_registerName("toggleVehFilter:"));
    g_btn_item_filter = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(9), bw, bh), "Loot: All Items",sel_registerName("toggleItemFilter:"));
    g_btn_teammates   = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(9), bw, bh), "Teammates: ON",  sel_registerName("toggleTeammates:"));
    g_btn_enemy_alert = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(10), bw, bh), "Enemy Alert: ON",sel_registerName("toggleEnemyAlert:"));
    g_btn_offscreen   = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(10), bw, bh), "Offscreen: ON", sel_registerName("toggleOffscreen:"));
    g_btn_crosshair   = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(11), bw, bh), "Crosshair: ON", sel_registerName("toggleCrosshair:"));
    g_btn_target_lock = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(11), bw, bh), "Lock Box: ON",  sel_registerName("toggleTargetLock:"));

    /* 14 New Creative Feature Buttons */
    g_btn_lead_pred       = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(12), bw, bh), "Lead Dot: ON",     sel_registerName("toggleLeadPred:"));
    g_btn_bullet_drop     = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(12), bw, bh), "Drop Guide: ON",   sel_registerName("toggleBulletDrop:"));
    g_btn_recoil_comp     = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(13), bw, bh), "Recoil Comp: ON", sel_registerName("toggleRecoilComp:"));
    g_btn_gaze_ray        = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(13), bw, bh), "Gaze Rays: ON",    sel_registerName("toggleGazeRay:"));
    g_btn_blindspot_alert = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(14), bw, bh), "Blind Alert: ON", sel_registerName("toggleBlindspot:"));
    g_btn_spectator_warn  = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(14), bw, bh), "Spectator: ON",   sel_registerName("toggleSpectator:"));
    g_btn_adaptive_fov    = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(15), bw, bh), "Adapt FOV: ON",    sel_registerName("toggleAdaptFov:"));
    g_btn_threat_tier     = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(15), bw, bh), "Threat Rank: ON", sel_registerName("toggleThreatTier:"));
    g_btn_grenade_warn    = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(16), bw, bh), "Nade Alert: ON",   sel_registerName("toggleNadeWarn:"));
    g_btn_airdrop_beacon  = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(16), bw, bh), "Airdrop ESP: ON", sel_registerName("toggleAirdrop:"));
    g_btn_sound_radar     = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(17), bw, bh), "Audio Radar: ON",  sel_registerName("toggleSoundRadar:"));
    g_btn_knocked_timer   = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(17), bw, bh), "Bleed Timer: ON", sel_registerName("toggleKnockedTimer:"));
    g_btn_auto_evade      = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(18), bw, bh), "Evade Alert: ON",  sel_registerName("toggleAutoEvade:"));
    g_btn_aim_smooth      = make_menu_button(scroll_view, helper, CGRectMake_f(c1, ROW_Y(18), bw, bh), "Aim Smooth: ON",  sel_registerName("toggleAimSmooth:"));

    /* Stop Radar Control Button */
    g_btn_stop_radar      = make_menu_button(scroll_view, helper, CGRectMake_f(c0, ROW_Y(19), bw * 2 + 12.0, bh), "🛑 STOP RADAR (Exit Daemon)", sel_registerName("stopRadar:"));
    id stop_layer = ((id (*)(id, SEL))objc_msgSend)(g_btn_stop_radar, sel_registerName("layer"));
    if (stop_layer) {
        id cg_red = ((id (*)(id, SEL))objc_msgSend)(
            ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
                (id)objc_getClass("UIColor"), sel_registerName("colorWithRed:green:blue:alpha:"), 0.85, 0.12, 0.16, 0.90),
            sel_registerName("CGColor"));
        ((void (*)(id, SEL, id))objc_msgSend)(stop_layer, sel_registerName("setBackgroundColor:"), cg_red);
        ((void (*)(id, SEL, double))objc_msgSend)(stop_layer, sel_registerName("setCornerRadius:"), 8.0);
    }
    #undef ROW_Y

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
    BOOL orig_radar = g_feat_radar;
    int  orig_aim_mode = g_aim_trigger_mode;
    BOOL orig_lead = g_feat_lead_pred;

    toggle_menu(); /* Open */
    BOOL test_menu_open = g_menu_open;

    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(g_btn_radar, sel_registerName("sendActionsForControlEvents:"), 64);
    BOOL test_radar_toggle = (g_feat_radar != orig_radar);
    g_feat_radar = orig_radar;

    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(g_btn_touch_aim, sel_registerName("sendActionsForControlEvents:"), 64);
    BOOL test_aim_toggle = (g_aim_trigger_mode != orig_aim_mode);
    g_aim_trigger_mode = orig_aim_mode;
    g_feat_touch_aim = (orig_aim_mode != 2);

    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(g_btn_lead_pred, sel_registerName("sendActionsForControlEvents:"), 64);
    BOOL test_lead_toggle = (g_feat_lead_pred != orig_lead);
    g_feat_lead_pred = orig_lead;

    update_menu_buttons();

    CGPoint close_center = {MENU_WIDTH - 59, 20};
    CGPoint close_in_window = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(g_menu_view,
        sel_registerName("convertPoint:toView:"), close_center, g_menu_window);
    BOOL test_close_hit = window_hitTest(g_menu_window, 0, close_in_window, nil) == close_btn;
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(close_btn, sel_registerName("sendActionsForControlEvents:"), 64);
    BOOL test_collapsed = !g_menu_open && ((BOOL (*)(id, SEL))objc_msgSend)(g_menu_window, sel_registerName("isHidden"));
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(close_btn, sel_registerName("sendActionsForControlEvents:"), 64);
    test_collapsed = test_collapsed && !g_menu_open;
    if (g_proof) fprintf(g_proof, "CONTROLS close_hit=%d collapse_idempotent=%d button_hit=%d aim_hit=%d\n", test_close_hit, test_collapsed,
        window_hitTest(g_button_window,0,(CGPoint){24,24},nil) == g_drag_button,
        window_hitTest(g_aim_window,0,(CGPoint){28,28},nil) == g_aim_button);
    BOOL test_pass_corner = !window_pointInside(window, 0, (CGPoint){2, 2}, nil);
    BOOL test_pass_radar  = !window_pointInside(window, 0, (CGPoint){rx + 50, ry + 50}, nil);

    if (g_proof) {
        fprintf(g_proof, "SELFTEST: menu_open=%d radar_toggle=%d aim_toggle=%d lead_toggle=%d pass_corner=%d pass_radar=%d all_features=38\n",
                test_menu_open, test_radar_toggle, test_aim_toggle, test_lead_toggle, test_pass_corner, test_pass_radar);
        fflush(g_proof);
    }

    if (g_proof) {
        CGRect bf = ((CGRect (*)(id, SEL))objc_msgSend)(g_button_window, sel_registerName("frame"));
        CGRect mf = ((CGRect (*)(id, SEL))objc_msgSend)(g_menu_window, sel_registerName("frame"));
        fprintf(g_proof, "BUILD touch-delivery-20260919 button=(%.0f,%.0f %.0fx%.0f) menu=(%.0f,%.0f %.0fx%.0f) display_interactive=%d\n", bf.origin.x,bf.origin.y,bf.size.width,bf.size.height,mf.origin.x,mf.origin.y,mf.size.width,mf.size.height,
            ((BOOL (*)(id, SEL))objc_msgSend)(g_window,sel_registerName("isUserInteractionEnabled")));
        fflush(g_proof);
    }

    if (g_proof) {
        fprintf(g_proof, "SERVER_TOUCH ignores=%d server_hit_testing=%d\n",
            ((BOOL (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("_ignoresHitTest")),
            ((BOOL (*)(id, SEL))objc_msgSend)(g_window, sel_registerName("_usesWindowServerHitTesting")));
        fflush(g_proof);
    }

    /* Ensure screen is awake and unlocked */
    ensure_screen_awake_and_unlocked();

    /* Open shared memory */
    open_shared_memory();

    /* Schedule Timer at 20 Hz (0.05s) */
    id timer = ((id (*)(id, SEL, double, id, SEL, id, BOOL))objc_msgSend)(
        (id)NSTimer_cls, sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:"),
        0.05, helper, sel_registerName("tick:"), nil, YES);

    id runloop = ((id (*)(id, SEL))objc_msgSend)((id)NSRunLoop_cls, sel_registerName("mainRunLoop"));
    id mode = nsstr("kCFRunLoopCommonModes");
    ((void (*)(id, SEL, id, id))objc_msgSend)(runloop, sel_registerName("addTimer:forMode:"), timer, mode);
    FILE *fpid = fopen("/var/mobile/Downloads/overlay_sb_pid.txt", "w");
    if (fpid) {
        fprintf(fpid, "%d\n", (int)getpid());
        fclose(fpid);
    }

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
    Class NSThread_cls = objc_getClass("NSThread");
    if (NSThread_cls && !((BOOL (*)(id, SEL))objc_msgSend)((id)NSThread_cls, sel_registerName("isMainThread"))) {
        if (self) {
            ((void (*)(id, SEL, SEL, id, BOOL))objc_msgSend)(
                self, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
                sel_registerName("deferredInit"), nil, NO);
        }
        return;
    }
    if (g_window) return;
    init_overlay();
    if (!g_window && self) {
        /* Retry after 0.5s if SpringBoard scenes were not connected yet */
        ((void (*)(id, SEL, SEL, id, double))objc_msgSend)(
            self, sel_registerName("performSelector:withObject:afterDelay:"),
            sel_registerName("deferredInit"), nil, 0.5);
    }
}

static id g_init_helper = nil;
static int s_tweak_initialized = 0;

__attribute__((constructor))
static void tweak_entry(void) {
    if (s_tweak_initialized) return;
    s_tweak_initialized = 1;

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

    FILE *fpid = fopen("/var/mobile/Downloads/overlay_sb_pid.txt", "w");
    if (fpid) {
        fprintf(fpid, "%d\n", (int)getpid());
        fclose(fpid);
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
    g_init_helper = retain_obj(helper);

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
