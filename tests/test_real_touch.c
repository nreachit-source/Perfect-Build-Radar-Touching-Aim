#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <objc/runtime.h>
#include <objc/message.h>
typedef struct CGPoint { double x; double y; } CGPoint;

typedef const void * CFAllocatorRef;
typedef void * CFTypeRef;
typedef void * CFStringRef;
typedef void * CFArrayRef;
typedef long CFIndex;
typedef void* IOHIDEventRef;
typedef void* IOHIDEventSystemClientRef;
typedef void* IOHIDServiceClientRef;

typedef IOHIDEventSystemClientRef (*fn_IOHIDEventSystemClientCreate_t)(CFAllocatorRef);
typedef void (*fn_IOHIDEventSystemClientDispatchEvent_t)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*fn_IOHIDEventCreateDigitizerEvent_t)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t);
typedef IOHIDEventRef (*fn_IOHIDEventCreateDigitizerFingerEvent_t)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t);
typedef void (*fn_IOHIDEventAppendEvent_t)(IOHIDEventRef, IOHIDEventRef);
typedef void (*fn_IOHIDEventSetSenderID_t)(IOHIDEventRef, uint64_t);
typedef void (*fn_IOHIDEventSetIntegerValue_t)(IOHIDEventRef, uint32_t, int);
typedef CFArrayRef (*fn_IOHIDEventSystemClientCopyServices_t)(IOHIDEventSystemClientRef);
typedef CFTypeRef (*fn_IOHIDServiceClientCopyProperty_t)(IOHIDServiceClientRef, CFStringRef);
typedef uint64_t (*fn_IOHIDServiceClientGetRegistryID_t)(IOHIDServiceClientRef);
typedef void (*fn_CFRelease_t)(CFTypeRef);
typedef CFStringRef (*fn_CFStringCreateWithCString_t)(CFAllocatorRef, const char *, uint32_t);
typedef CFIndex (*fn_CFArrayGetCount_t)(CFArrayRef);
typedef const void* (*fn_CFArrayGetValueAtIndex_t)(CFArrayRef, CFIndex);
typedef long (*fn_CFNumberGetValue_t)(CFTypeRef, int, void *);

int main(int argc, char **argv) {
    printf("=== Test Real Touch Simulation on iPhone X ===\n");
    void *hIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);
    void *hCF = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");

    printf("AXBackBoardServer: %p, AXEventRepresentation: %p\n", cls_AXBackBoard, cls_AXEventRep);

    id ax_srv = NULL;
    if (cls_AXBackBoard) {
        ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
        if (!ax_srv) {
            ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("sharedInstance"));
        }
    }
    printf("ax_srv: %p\n", ax_srv);

    if (ax_srv) {
        ((void (*)(id, SEL, int))objc_msgSend)(ax_srv, sel_registerName("registerAssistiveTouchPID:"), getpid());
        int cur_pid = ((int (*)(id, SEL))objc_msgSend)(ax_srv, sel_registerName("accessibilityAssistiveTouchPID"));
        printf("accessibilityAssistiveTouchPID: %d (my pid: %d)\n", cur_pid, getpid());
    }

    // Determine digitizer sender ID
    uint64_t sender_id = 0;
    fn_IOHIDEventSystemClientCreate_t fn_create = (fn_IOHIDEventSystemClientCreate_t)dlsym(hIOKit, "IOHIDEventSystemClientCreate");
    fn_IOHIDEventSystemClientCopyServices_t fn_copy_srv = (fn_IOHIDEventSystemClientCopyServices_t)dlsym(hIOKit, "IOHIDEventSystemClientCopyServices");
    fn_IOHIDServiceClientCopyProperty_t fn_copy_prop = (fn_IOHIDServiceClientCopyProperty_t)dlsym(hIOKit, "IOHIDServiceClientCopyProperty");
    fn_IOHIDServiceClientGetRegistryID_t fn_get_reg = (fn_IOHIDServiceClientGetRegistryID_t)dlsym(hIOKit, "IOHIDServiceClientGetRegistryID");
    fn_CFRelease_t fn_release = (fn_CFRelease_t)dlsym(hCF, "CFRelease");
    fn_CFStringCreateWithCString_t fn_str_create = (fn_CFStringCreateWithCString_t)dlsym(hCF, "CFStringCreateWithCString");
    fn_CFArrayGetCount_t fn_arr_count = (fn_CFArrayGetCount_t)dlsym(hCF, "CFArrayGetCount");
    fn_CFArrayGetValueAtIndex_t fn_arr_val = (fn_CFArrayGetValueAtIndex_t)dlsym(hCF, "CFArrayGetValueAtIndex");
    fn_CFNumberGetValue_t fn_num_val = (fn_CFNumberGetValue_t)dlsym(hCF, "CFNumberGetValue");

    IOHIDEventSystemClientRef client = fn_create ? fn_create(NULL) : NULL;
    if (client && fn_copy_srv && fn_str_create) {
        CFStringRef kPage = fn_str_create(NULL, "PrimaryUsagePage", 0x08000100);
        CFStringRef kUsage = fn_str_create(NULL, "PrimaryUsage", 0x08000100);
        CFArrayRef srvs = fn_copy_srv(client);
        if (srvs) {
            CFIndex n = fn_arr_count(srvs);
            for (CFIndex i = 0; i < n; i++) {
                IOHIDServiceClientRef s = (IOHIDServiceClientRef)fn_arr_val(srvs, i);
                int page = 0, usage = 0;
                CFTypeRef pPage = fn_copy_prop(s, kPage);
                if (pPage) { fn_num_val(pPage, 3, &page); fn_release(pPage); }
                CFTypeRef pUsage = fn_copy_prop(s, kUsage);
                if (pUsage) { fn_num_val(pUsage, 3, &usage); fn_release(pUsage); }
                if (page == 0x0D && usage == 0x04) {
                    sender_id = fn_get_reg(s);
                    printf("Found digitizer service: 0x%llx\n", (unsigned long long)sender_id);
                    break;
                }
            }
            fn_release(srvs);
        }
        if (kPage) fn_release(kPage);
        if (kUsage) fn_release(kUsage);
    }

    printf("Executing swipe up from bottom (unlock test)...\n");
    // iPhone X portrait resolution: 375 x 812 points
    double start_x = 187.5, start_y = 750.0;
    double end_x = 187.5, end_y = 200.0;
    int steps = 25;

    // Send touch down
    id rep_down = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 1, (CGPoint){start_x, start_y});
    if (rep_down) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_down, sel_registerName("setIsGeneratedEvent:"), YES);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_down, NO);
    }

    // Send move steps
    for (int s = 1; s <= steps; s++) {
        double cur_y = start_y + (end_y - start_y) * ((double)s / (double)steps);
        usleep(12000);
        id rep_move = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
            (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 2, (CGPoint){start_x, cur_y});
        if (rep_move) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_move, sel_registerName("setIsGeneratedEvent:"), YES);
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_move, NO);
        }
    }

    // Send touch up
    usleep(12000);
    id rep_up = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 0, (CGPoint){end_x, end_y});
    if (rep_up) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_up, sel_registerName("setIsGeneratedEvent:"), YES);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_up, NO);
    }

    printf("Swipe dispatch finished!\n");
    return 0;
}
