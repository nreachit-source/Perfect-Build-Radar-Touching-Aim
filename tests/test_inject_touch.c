#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct CGPoint { double x; double y; } CGPoint;

int main(int argc, char **argv) {
    printf("=== Verified Physical Touch Injection Test (AXBackBoardServer) ===\n");
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);

    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");

    if (!cls_AXBackBoard || !cls_AXEventRep) {
        printf("[-] Failed: AXBackBoardServer or AXEventRepresentation not found!\n");
        return 1;
    }

    id ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
    if (!ax_srv) {
        ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("sharedInstance"));
    }
    if (!ax_srv) {
        printf("[-] Failed: AXBackBoardServer instance is NULL!\n");
        return 1;
    }

    printf("[+] AXBackBoardServer: %p, AXEventRepresentation: %p\n", ax_srv, cls_AXEventRep);

    ((void (*)(id, SEL, int))objc_msgSend)(ax_srv, sel_registerName("registerAssistiveTouchPID:"), getpid());
    int cur_pid = ((int (*)(id, SEL))objc_msgSend)(ax_srv, sel_registerName("accessibilityAssistiveTouchPID"));
    printf("[+] Registered AssistiveTouch PID: %d (verified: %d)\n", getpid(), cur_pid);

    /* LandscapeRight look-zone swipe simulation:
     * Landscape norm (0.70, 0.50) -> (0.80, 0.50)
     * Physical portrait panel: port_px = (1.0 - 0.50)*375 = 187.5, port_py = norm_x * 812
     */
    double start_x = 187.5, start_y = 0.70 * 812.0; /* 568.4 */
    double end_x = 187.5, end_y = 0.80 * 812.0;     /* 649.6 */
    int steps = 20;

    printf("[*] Simulating physical camera aim swipe: (%.1f, %.1f) -> (%.1f, %.1f) in %d steps...\n",
           start_x, start_y, end_x, end_y, steps);

    /* 1. Touch Down (hand_type = 1 -> eventType Touched) */
    id rep_down = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 1, (CGPoint){start_x, start_y});
    if (!rep_down) {
        printf("[-] Failed to create touch down representation!\n");
        return 1;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_down, sel_registerName("setIsGeneratedEvent:"), YES);
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_down, NO);
    printf("[+] Touch Down dispatched (hand_type=1)\n");

    /* 2. Touch Move steps (hand_type = 2 -> eventType Moved) */
    for (int s = 1; s <= steps; s++) {
        double cur_y = start_y + (end_y - start_y) * ((double)s / (double)steps);
        usleep(12000); /* 12ms per step */
        id rep_move = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
            (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 2, (CGPoint){start_x, cur_y});
        if (rep_move) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_move, sel_registerName("setIsGeneratedEvent:"), YES);
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_move, NO);
        }
    }
    printf("[+] Dispatched %d move steps (hand_type=2)\n", steps);

    /* 3. Touch Up (hand_type = 6 -> eventType Lifted) */
    usleep(12000);
    id rep_up = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 6, (CGPoint){end_x, end_y});
    if (rep_up) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_up, sel_registerName("setIsGeneratedEvent:"), YES);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_up, NO);
    }
    printf("[+] Touch Up dispatched (hand_type=6)\n");
    printf("[+] Dispatched swipe completed successfully!\n");
    return 0;
}
