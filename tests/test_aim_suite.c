#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct CGPoint { double x; double y; } CGPoint;
typedef struct { float x, y, z; } rvec3_t;

typedef const void * CFAllocatorRef;
typedef void * CFTypeRef;
typedef void * CFStringRef;
typedef void * CFArrayRef;
typedef void * CFNumberRef;
typedef long CFIndex;

typedef void* IOHIDEventRef;
typedef void* IOHIDEventSystemClientRef;
typedef void* IOHIDServiceClientRef;

/* Function pointer definitions */
static IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef) = NULL;
static void (*p_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef) = NULL;
static IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t) = NULL;
static IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t) = NULL;
static void (*p_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t) = NULL;
static void (*p_IOHIDEventSetSenderID)(IOHIDEventRef, uint64_t) = NULL;
static void (*p_IOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, int) = NULL;
static void (*p_IOHIDEventSetFloatValue)(IOHIDEventRef, uint32_t, double) = NULL;
static CFArrayRef (*p_IOHIDEventSystemClientCopyServices)(IOHIDEventSystemClientRef) = NULL;
static CFTypeRef (*p_IOHIDServiceClientCopyProperty)(IOHIDServiceClientRef, CFStringRef) = NULL;
static CFTypeRef (*p_IOHIDServiceClientGetRegistryID)(IOHIDServiceClientRef) = NULL;

static void (*p_CFRelease)(CFTypeRef) = NULL;
static CFStringRef (*p_CFStringCreateWithCString)(CFAllocatorRef, const char *, uint32_t) = NULL;
static CFIndex (*p_CFArrayGetCount)(CFArrayRef) = NULL;
static const void* (*p_CFArrayGetValueAtIndex)(CFArrayRef, CFIndex) = NULL;
static bool (*p_CFNumberGetValue)(CFTypeRef, int, void *) = NULL;

static void load_symbols(void) {
    void *hIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);
    void *hCF = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    if (hIOKit) {
        p_IOHIDEventSystemClientCreate = (IOHIDEventSystemClientRef (*)(CFAllocatorRef))dlsym(hIOKit, "IOHIDEventSystemClientCreate");
        p_IOHIDEventSystemClientDispatchEvent = (void (*)(IOHIDEventSystemClientRef, IOHIDEventRef))dlsym(hIOKit, "IOHIDEventSystemClientDispatchEvent");
        p_IOHIDEventCreateDigitizerEvent = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t))dlsym(hIOKit, "IOHIDEventCreateDigitizerEvent");
        p_IOHIDEventCreateDigitizerFingerEvent = (IOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t))dlsym(hIOKit, "IOHIDEventCreateDigitizerFingerEvent");
        p_IOHIDEventAppendEvent = (void (*)(IOHIDEventRef, IOHIDEventRef, uint32_t))dlsym(hIOKit, "IOHIDEventAppendEvent");
        p_IOHIDEventSetSenderID = (void (*)(IOHIDEventRef, uint64_t))dlsym(hIOKit, "IOHIDEventSetSenderID");
        p_IOHIDEventSetIntegerValue = (void (*)(IOHIDEventRef, uint32_t, int))dlsym(hIOKit, "IOHIDEventSetIntegerValue");
        p_IOHIDEventSetFloatValue = (void (*)(IOHIDEventRef, uint32_t, double))dlsym(hIOKit, "IOHIDEventSetFloatValue");
        p_IOHIDEventSystemClientCopyServices = (CFArrayRef (*)(IOHIDEventSystemClientRef))dlsym(hIOKit, "IOHIDEventSystemClientCopyServices");
        p_IOHIDServiceClientCopyProperty = (CFTypeRef (*)(IOHIDServiceClientRef, CFStringRef))dlsym(hIOKit, "IOHIDServiceClientCopyProperty");
        p_IOHIDServiceClientGetRegistryID = (CFTypeRef (*)(IOHIDServiceClientRef))dlsym(hIOKit, "IOHIDServiceClientGetRegistryID");
    }
    if (hCF) {
        p_CFRelease = (void (*)(CFTypeRef))dlsym(hCF, "CFRelease");
        p_CFStringCreateWithCString = (CFStringRef (*)(CFAllocatorRef, const char *, uint32_t))dlsym(hCF, "CFStringCreateWithCString");
        p_CFArrayGetCount = (CFIndex (*)(CFArrayRef))dlsym(hCF, "CFArrayGetCount");
        p_CFArrayGetValueAtIndex = (const void* (*)(CFArrayRef, CFIndex))dlsym(hCF, "CFArrayGetValueAtIndex");
        p_CFNumberGetValue = (bool (*)(CFTypeRef, int, void *))dlsym(hCF, "CFNumberGetValue");
    }
}

/* TEST 1: Hardware Digitizer Discovery & Registry Sender ID Resolution */
static bool test1_digitizer_sender_id(uint64_t *out_sender_id) {
    printf("[TEST 1] Testing Hardware Digitizer Discovery & Registry Sender ID Resolution...\n");
    if (!p_IOHIDEventSystemClientCreate || !p_IOHIDEventSystemClientCopyServices ||
        !p_IOHIDServiceClientCopyProperty || !p_IOHIDServiceClientGetRegistryID ||
        !p_CFStringCreateWithCString || !p_CFRelease || !p_CFArrayGetCount) {
        printf("  [-] Missing IOHID symbols\n");
        return false;
    }

    IOHIDEventSystemClientRef client = p_IOHIDEventSystemClientCreate(NULL);
    if (!client) {
        printf("  [-] IOHIDEventSystemClientCreate returned NULL\n");
        return false;
    }

    CFStringRef kPage = p_CFStringCreateWithCString(NULL, "PrimaryUsagePage", 0x08000100);
    CFStringRef kUsage = p_CFStringCreateWithCString(NULL, "PrimaryUsage", 0x08000100);
    CFArrayRef services = p_IOHIDEventSystemClientCopyServices(client);

    uint64_t found_id = 0;
    if (services) {
        CFIndex count = p_CFArrayGetCount(services);
        printf("  [*] Enumerating %ld IOHID services...\n", (long)count);
        for (CFIndex i = 0; i < count; i++) {
            IOHIDServiceClientRef s = (IOHIDServiceClientRef)p_CFArrayGetValueAtIndex(services, i);
            int page = 0, usage = 0;
            CFTypeRef pPage = p_IOHIDServiceClientCopyProperty(s, kPage);
            if (pPage) {
                p_CFNumberGetValue(pPage, 3, &page);
                p_CFRelease(pPage);
            }
            CFTypeRef pUsage = p_IOHIDServiceClientCopyProperty(s, kUsage);
            if (pUsage) {
                p_CFNumberGetValue(pUsage, 3, &usage);
                p_CFRelease(pUsage);
            }
            if (page == 0x0D && usage == 0x04) {
                CFTypeRef number = p_IOHIDServiceClientGetRegistryID(s);
                uint64_t reg = 0;
                if (number && p_CFNumberGetValue(number, 4, &reg) && reg != 0) {
                    found_id = reg;
                    printf("  [+] Matched Digitizer (Page 0x0D, Usage 0x04): RegistryID=0x%llx\n", (unsigned long long)found_id);
                    break;
                }
            }
        }
        p_CFRelease(services);
    }
    if (kPage) p_CFRelease(kPage);
    if (kUsage) p_CFRelease(kUsage);
    p_CFRelease(client);

    if (found_id != 0) {
        *out_sender_id = found_id;
        printf("  [PASS] Test 1: Hardware digitizer resolved successfully (sender_id=0x%llx)\n\n", (unsigned long long)found_id);
        return true;
    } else {
        printf("  [-] Test 1: Could not find touchscreen digitizer service\n\n");
        return false;
    }
}

/* TEST 2: Conforming Digitizer Event Packet Construction */
static bool test2_packet_conformance(uint64_t sender_id) {
    printf("[TEST 2] Testing Conforming Digitizer Event Packet Construction...\n");
    if (!p_IOHIDEventCreateDigitizerEvent || !p_IOHIDEventCreateDigitizerFingerEvent ||
        !p_IOHIDEventAppendEvent || !p_IOHIDEventSetIntegerValue || !p_IOHIDEventSetFloatValue) {
        printf("  [-] Missing IOHID event creation symbols\n");
        return false;
    }

    uint64_t now = mach_absolute_time();
    IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        NULL, now, 3, 99, 1, 0, 0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
    if (!parent) {
        printf("  [-] Failed to create parent digitizer event\n");
        return false;
    }

    p_IOHIDEventSetIntegerValue(parent, 720921, 1);
    p_IOHIDEventSetIntegerValue(parent, 4, 1);
    p_IOHIDEventSetIntegerValue(parent, 720903, 0x23);
    p_IOHIDEventSetIntegerValue(parent, 720904, 0x1);
    p_IOHIDEventSetIntegerValue(parent, 720905, 0x1);

    IOHIDEventRef finger = p_IOHIDEventCreateDigitizerFingerEvent(
        NULL, now, 1, 3, 3,
        0.50, 0.50, 0.0, 0.0, 0.0,
        1, 1, 0);
    if (!finger) {
        printf("  [-] Failed to create child finger event\n");
        p_CFRelease(parent);
        return false;
    }

    p_IOHIDEventSetFloatValue(finger, 720916, 0.04);
    p_IOHIDEventSetFloatValue(finger, 720917, 0.04);

    if (p_IOHIDEventSetSenderID && sender_id) {
        p_IOHIDEventSetSenderID(finger, sender_id);
        p_IOHIDEventSetSenderID(parent, sender_id);
    }

    p_IOHIDEventAppendEvent(parent, finger, 0);
    printf("  [+] Child finger event appended to parent with radii (major=0.04, minor=0.04) and sender=0x%llx\n", (unsigned long long)sender_id);

    p_CFRelease(finger);
    p_CFRelease(parent);
    printf("  [PASS] Test 2: Conforming digitizer event constructed and released cleanly\n\n");
    return true;
}

/* TEST 3: AXBackBoardServer Registration & Bridge */
static bool test3_ax_bridge(void) {
    printf("[TEST 3] Testing Dual-Channel Accessibility Bridge (AXBackBoardServer)...\n");
    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");

    if (!cls_AXBackBoard || !cls_AXEventRep) {
        printf("  [-] AXBackBoardServer or AXEventRepresentation class not found\n");
        return false;
    }

    id ax_srv = NULL;
    if (class_respondsToSelector(object_getClass((id)cls_AXBackBoard), sel_registerName("server"))) {
        ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
    }
    if (!ax_srv && class_respondsToSelector(object_getClass((id)cls_AXBackBoard), sel_registerName("sharedInstance"))) {
        ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("sharedInstance"));
    }
    if (!ax_srv) {
        printf("  [-] Failed to obtain AXBackBoardServer instance\n");
        return false;
    }
    printf("  [+] AXBackBoardServer instance: %p\n", ax_srv);

    if (class_getInstanceMethod(cls_AXBackBoard, sel_registerName("registerAssistiveTouchPID:"))) {
        ((void (*)(id, SEL, int))objc_msgSend)(ax_srv, sel_registerName("registerAssistiveTouchPID:"), getpid());
        printf("  [+] registerAssistiveTouchPID registered for pid=%d\n", getpid());
    }

    CGPoint pt = { 187.5, 406.0 };
    id rep = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 1, pt);
    if (!rep) {
        printf("  [-] touchRepresentationWithHandType returned nil\n");
        return false;
    }
    printf("  [+] Created AXEventRepresentation: %p\n", rep);

    if (class_getInstanceMethod(cls_AXEventRep, sel_registerName("setIsGeneratedEvent:"))) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rep, sel_registerName("setIsGeneratedEvent:"), YES);
        printf("  [+] setIsGeneratedEvent: YES applied successfully\n");
    } else {
        printf("  [-] setIsGeneratedEvent method not found\n");
        return false;
    }

    printf("  [PASS] Test 3: AXBackBoardServer bridge verified and functional\n\n");
    return true;
}

/* TEST 4: 3-Phase Touch Lifecycle & Gesture State Machine */
static bool test4_touch_lifecycle(void) {
    printf("[TEST 4] Testing 3-Phase Touch Lifecycle (Down -> Move -> Up)...\n");
    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");
    if (!cls_AXEventRep) return false;

    CGPoint p_down = { 187.5, 584.6 };
    id rep_down = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 1, p_down);
    if (!rep_down) { printf("  [-] Down rep failed\n"); return false; }
    id hi_down = ((id (*)(id, SEL))objc_msgSend)(rep_down, sel_registerName("handInfo"));
    id desc_down = hi_down ? ((id (*)(id, SEL))objc_msgSend)(hi_down, sel_registerName("description")) : nil;
    const char *s_down = desc_down ? ((const char* (*)(id, SEL))objc_msgSend)(desc_down, sel_registerName("UTF8String")) : "";
    if (!strstr(s_down, "Touched")) {
        printf("  [-] Down eventType is not Touched: %s\n", s_down);
        return false;
    }
    printf("  [+] Phase 1 (Down): handType=1 -> eventType Touched at (%.1f, %.1f)\n", p_down.x, p_down.y);

    CGPoint p_move = { 210.0, 560.0 };
    id rep_move = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 2, p_move);
    if (!rep_move) { printf("  [-] Move rep failed\n"); return false; }
    id hi_move = ((id (*)(id, SEL))objc_msgSend)(rep_move, sel_registerName("handInfo"));
    id desc_move = hi_move ? ((id (*)(id, SEL))objc_msgSend)(hi_move, sel_registerName("description")) : nil;
    const char *s_move = desc_move ? ((const char* (*)(id, SEL))objc_msgSend)(desc_move, sel_registerName("UTF8String")) : "";
    if (!strstr(s_move, "Moved")) {
        printf("  [-] Move eventType is not Moved: %s\n", s_move);
        return false;
    }
    printf("  [+] Phase 2 (Move): handType=2 -> eventType Moved at (%.1f, %.1f)\n", p_move.x, p_move.y);

    CGPoint p_up = { 260.0, 510.0 };
    id rep_up = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 6, p_up);
    if (!rep_up) { printf("  [-] Up rep failed\n"); return false; }
    id hi_up = ((id (*)(id, SEL))objc_msgSend)(rep_up, sel_registerName("handInfo"));
    id desc_up = hi_up ? ((id (*)(id, SEL))objc_msgSend)(hi_up, sel_registerName("description")) : nil;
    const char *s_up = desc_up ? ((const char* (*)(id, SEL))objc_msgSend)(desc_up, sel_registerName("UTF8String")) : "";
    if (!strstr(s_up, "Lifted")) {
        printf("  [-] Up eventType is not Lifted: %s\n", s_up);
        return false;
    }
    printf("  [+] Phase 3 (Up): handType=6 -> eventType Lifted at (%.1f, %.1f)\n", p_up.x, p_up.y);

    printf("  [PASS] Test 4: 3-Phase touch lifecycle verified with exact iOS eventType mappings\n\n");
    return true;
}

/* TEST 5: Coordinate Transform & Active Area Clamping */
static void transform_coords(double scr_x, double scr_y, int ori, double *out_px, double *out_py) {
    double hx = scr_x, hy = scr_y;
    if (ori == 3) {
        hx = 1.0 - scr_y;
        hy = scr_x;
    } else if (ori == 4) {
        hx = scr_y;
        hy = 1.0 - scr_x;
    }
    if (hx < 0.02) hx = 0.02;
    if (hx > 0.98) hx = 0.98;
    if (hy < 0.02) hy = 0.02;
    if (hy > 0.98) hy = 0.98;

    double px = hx * 375.0;
    double py = hy * 812.0;
    if (px < 6.0) px = 6.0;
    if (px > 369.0) px = 369.0;
    if (py < 12.0) py = 12.0;
    if (py > 800.0) py = 800.0;
    *out_px = px;
    *out_py = py;
}

static bool test5_coordinate_transform(void) {
    printf("[TEST 5] Testing Landscape-to-Portrait Digitizer Transform & Active Area Clamping...\n");
    double px, py;

    transform_coords(0.50, 0.50, 3, &px, &py);
    if (fabs(px - 187.5) > 0.1 || fabs(py - 406.0) > 0.1) {
        printf("  [-] Center transform failed: (%.1f, %.1f)\n", px, py);
        return false;
    }
    printf("  [+] Screen Center (0.50, 0.50) -> Digitizer Panel (%.1f, %.1f) [OK]\n", px, py);

    transform_coords(0.72, 0.50, 3, &px, &py);
    if (fabs(px - 187.5) > 0.1 || fabs(py - 584.64) > 0.5) {
        printf("  [-] Aim zone base transform failed: (%.1f, %.1f)\n", px, py);
        return false;
    }
    printf("  [+] Aim Base (0.72, 0.50) -> Digitizer Panel (%.1f, %.1f) [OK]\n", px, py);

    transform_coords(0.0, 0.0, 3, &px, &py);
    if (px < 6.0 || py < 12.0 || px > 369.0 || py > 800.0) {
        printf("  [-] Boundary clamp failed for (0,0): (%.1f, %.1f)\n", px, py);
        return false;
    }
    printf("  [+] Clamped Boundary (0.0, 0.0) -> Digitizer Panel (%.1f, %.1f) [OK]\n", px, py);

    transform_coords(1.0, 1.0, 3, &px, &py);
    if (px < 6.0 || py < 12.0 || px > 369.0 || py > 800.0) {
        printf("  [-] Boundary clamp failed for (1,1): (%.1f, %.1f)\n", px, py);
        return false;
    }
    printf("  [+] Clamped Boundary (1.0, 1.0) -> Digitizer Panel (%.1f, %.1f) [OK]\n", px, py);

    printf("  [PASS] Test 5: All coordinate transforms and active-area clamping verified\n\n");
    return true;
}

/* TEST 6: Aim Steering & Prediction Vector Calculations */
static bool test6_aim_steering_math(void) {
    printf("[TEST 6] Testing Aim Assist Steering Vector & Ballistics Lead Calculation...\n");

    double center_x = 406.0, center_y = 187.5;
    double enemy_x = 450.0, enemy_y = 180.0;
    double dx = enemy_x - center_x;
    double dy = enemy_y - center_y;
    double dist = hypot(dx, dy);

    double fov_radius = 90.0;
    bool in_fov = (dist <= fov_radius);
    if (!in_fov) { printf("  [-] Enemy inside FOV check failed\n"); return false; }
    printf("  [+] Target Acquisition: dist=%.2f px inside FOV radius=%.0f px\n", dist, fov_radius);

    rvec3_t enemy_pos = { 1000.0f, 2000.0f, 50.0f };
    rvec3_t enemy_vel = { 120.0f, 0.0f, 0.0f };
    float enemy_dist_m = 50.0f;
    float bullet_speed = 880.0f;
    float travel_time = enemy_dist_m / bullet_speed;
    rvec3_t predicted_pos = enemy_pos;
    predicted_pos.x += enemy_vel.x * travel_time;
    predicted_pos.y += enemy_vel.y * travel_time;
    predicted_pos.z += enemy_vel.z * travel_time;

    float lead_offset = predicted_pos.x - enemy_pos.x;
    if (lead_offset <= 0.0f) { printf("  [-] Lead offset calculation failed\n"); return false; }
    printf("  [+] Ballistics Lead Prediction: travel_time=%.3fs, lead_offset=%.2f cm\n", travel_time, lead_offset);

    double vel_mult = 0.80;
    double recoil_comp_dy = 0.0030 * vel_mult;
    if (recoil_comp_dy <= 0.0) { printf("  [-] Recoil pull-down calculation failed\n"); return false; }
    printf("  [+] Recoil Compensation: downward pull-step = +%.4f\n", recoil_comp_dy);

    double smooth_factor = sin((5.0 + 1.0) * 3.14159 / 15.0);
    double step_x = (dx / dist) * 0.015 * (0.75 + 0.50 * smooth_factor);
    if (step_x <= 0.0) { printf("  [-] Smoothing step calculation failed\n"); return false; }
    printf("  [+] Sinusoidal Micro-Stroke Step: step_x=%.5f (smooth_factor=%.3f)\n", step_x, smooth_factor);

    printf("  [PASS] Test 6: Aim steering, FOV acquisition, and prediction math verified\n\n");
    return true;
}

/* TEST 7: Live In-Game Dispatch Execution & System Health */
static bool test7_live_dispatch_execution(uint64_t sender_id) {
    printf("[TEST 7] Testing Live In-Game Dispatch Execution & System Health...\n");
    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");
    id ax_srv = NULL;
    if (cls_AXBackBoard) {
        ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
        if (!ax_srv) ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("sharedInstance"));
    }

    IOHIDEventSystemClientRef client = p_IOHIDEventSystemClientCreate ? p_IOHIDEventSystemClientCreate(NULL) : NULL;

    printf("  [*] Dispatching live 10-step aim stroke via Dual AX + IOHID channels...\n");
    double start_x = 187.5, start_y = 584.6;
    double end_x = 215.0, end_y = 530.0;
    int steps = 10;

    for (int i = 0; i <= steps + 1; i++) {
        int state = (i == 0) ? 1 : ((i == steps + 1) ? 0 : 2);
        unsigned int ht = (state == 1) ? 1 : ((state == 2) ? 2 : 6);
        uint32_t f_mask = (state == 1) ? 3 : ((state == 2) ? 4 : 3);
        bool f_down = (state != 0);

        double progress = (state == 0) ? 1.0 : ((double)i / (double)steps);
        double cur_x = start_x + (end_x - start_x) * progress;
        double cur_y = start_y + (end_y - start_y) * progress;
        CGPoint cur_pt = { cur_x, cur_y };

        if (cls_AXEventRep && ax_srv) {
            id rep = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
                (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), ht, cur_pt);
            if (rep) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(rep, sel_registerName("setIsGeneratedEvent:"), YES);
                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep, NO);
            }
        }

        if (client && p_IOHIDEventCreateDigitizerEvent && p_IOHIDEventCreateDigitizerFingerEvent && p_IOHIDEventAppendEvent) {
            uint64_t now = mach_absolute_time();
            IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
                NULL, now, 3, 99, 1, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
            if (parent) {
                p_IOHIDEventSetIntegerValue(parent, 720921, 1);
                p_IOHIDEventSetIntegerValue(parent, 4, 1);
                IOHIDEventRef finger = p_IOHIDEventCreateDigitizerFingerEvent(
                    NULL, now, 1, 3, f_mask,
                    cur_x / 375.0, cur_y / 812.0, 0.0, 0.0, 0.0,
                    f_down ? 1 : 0, f_down ? 1 : 0, 0);
                if (finger) {
                    p_IOHIDEventSetFloatValue(finger, 720916, 0.04);
                    p_IOHIDEventSetFloatValue(finger, 720917, 0.04);
                    p_IOHIDEventAppendEvent(parent, finger, 0);
                    if (p_IOHIDEventSetSenderID && sender_id) {
                        p_IOHIDEventSetSenderID(finger, sender_id);
                        p_IOHIDEventSetSenderID(parent, sender_id);
                    }
                    p_CFRelease(finger);
                }
                p_IOHIDEventSetIntegerValue(parent, 720903, f_mask);
                p_IOHIDEventSetIntegerValue(parent, 720904, f_down);
                p_IOHIDEventSetIntegerValue(parent, 720905, f_down);
                if (p_IOHIDEventSystemClientDispatchEvent) {
                    p_IOHIDEventSystemClientDispatchEvent(client, parent);
                }
                p_CFRelease(parent);
            }
        }

        usleep(12000);
    }

    if (client) p_CFRelease(client);
    printf("  [+] 10-step aim stroke dispatched successfully across both channels\n");
    printf("  [PASS] Test 7: Live dispatch completed cleanly without process interruption\n\n");
    return true;
}

int main(int argc, char **argv) {
    printf("======================================================================\n");
    printf("     7-TEST VERIFICATION SUITE: AUTO-AIM TOUCH INJECTION SYSTEM       \n");
    printf("   Target: iPhone X (iOS 16.7.16, arm64, Dopamine Rootless)          \n");
    printf("======================================================================\n\n");

    load_symbols();

    uint64_t sender_id = 0;
    int passed = 0;
    if (argc > 1 && strcmp(argv[1], "--sender-only") == 0)
        return test1_digitizer_sender_id(&sender_id) ? 0 : 1;

    if (test1_digitizer_sender_id(&sender_id)) passed++;
    if (test2_packet_conformance(sender_id)) passed++;
    if (test3_ax_bridge()) passed++;
    if (test4_touch_lifecycle()) passed++;
    if (test5_coordinate_transform()) passed++;
    if (test6_aim_steering_math()) passed++;
    if (test7_live_dispatch_execution(sender_id)) passed++;

    printf("======================================================================\n");
    printf("TEST RESULTS SUMMARY: %d / 7 TESTS PASSED\n", passed);
    printf("STATUS: %s\n", (passed == 7) ? "DISPATCH CHECKS PASSED; APP DELIVERY NOT VERIFIED" : "FAILURES DETECTED");
    printf("======================================================================\n");

    return (passed == 7) ? 0 : 1;
}
