#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct CGPoint { double x; double y; } CGPoint;

int main(void) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");

    id ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
    if (!ax_srv) ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("sharedInstance"));

    // ESP floating drag button center: x = 56.0, y = 74.0
    double tap_x = 56.0, tap_y = 74.0;

    printf("Simulating physical tap at (%f, %f)...\n", tap_x, tap_y);

    id rep_down = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 1, (CGPoint){tap_x, tap_y});
    if (rep_down) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_down, sel_registerName("setIsGeneratedEvent:"), YES);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_down, NO);
    }

    usleep(50000); // 50ms hold

    id rep_up = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 0, (CGPoint){tap_x, tap_y});
    if (rep_up) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_up, sel_registerName("setIsGeneratedEvent:"), YES);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_up, NO);
    }

    printf("Tap sent successfully!\n");
    return 0;
}
