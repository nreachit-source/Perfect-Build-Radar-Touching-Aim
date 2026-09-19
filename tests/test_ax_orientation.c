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

    // Check device orientation methods on ax_srv
    if (ax_srv) {
        long ori = 0;
        if (((BOOL (*)(id, SEL, SEL))objc_msgSend)(ax_srv, sel_registerName("respondsToSelector:"), sel_registerName("deviceOrientation"))) {
            ori = ((long (*)(id, SEL))objc_msgSend)(ax_srv, sel_registerName("deviceOrientation"));
            printf("Current ax_srv deviceOrientation: %ld\n", ori);
        } else {
            printf("ax_srv does not respond to deviceOrientation\n");
        }
    }

    CGPoint pt = (CGPoint){ 100.0, 200.0 };
    int test_types[] = { 0, 1, 2, 6 };
    for (int i = 0; i < 4; i++) {
        int ht = test_types[i];
        id rep_t = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
            (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), ht, pt);
        if (rep_t) {
            id desc = ((id (*)(id, SEL))objc_msgSend)(rep_t, sel_registerName("description"));
            const char *s = ((const char* (*)(id, SEL))objc_msgSend)(desc, sel_registerName("UTF8String"));
            printf("handType %d description:\n%s\n\n", ht, s ? s : "(null)");
        }
    }
    return 0;
}
