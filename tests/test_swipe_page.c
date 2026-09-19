#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct CGPoint { double x; double y; } CGPoint;

int main(int argc, char **argv) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");

    id ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
    if (!ax_srv) ax_srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("sharedInstance"));

    // Swipe horizontally from left to right: (45, 400) -> (330, 400)
    double sx = 45.0, ex = 330.0, y = 400.0;
    int steps = 25;

    id rep_down = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 1, (CGPoint){sx, y});
    ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_down, sel_registerName("setIsGeneratedEvent:"), YES);
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_down, NO);

    for (int s = 1; s <= steps; s++) {
        double cur_x = sx + (ex - sx) * ((double)s / (double)steps);
        usleep(12000);
        id rep_move = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
            (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 2, (CGPoint){cur_x, y});
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_move, sel_registerName("setIsGeneratedEvent:"), YES);
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_move, NO);
    }

    usleep(12000);
    id rep_up = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
        (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), 0, (CGPoint){ex, y});
    ((void (*)(id, SEL, BOOL))objc_msgSend)(rep_up, sel_registerName("setIsGeneratedEvent:"), YES);
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ax_srv, sel_registerName("postEvent:systemEvent:"), rep_up, NO);

    printf("Horizontal swipe completed!\n");
    return 0;
}
