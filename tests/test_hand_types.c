#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct CGPoint { double x; double y; } CGPoint;

int main(void) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    Class cls_AXEventRep = objc_getClass("AXEventRepresentation");

    for (unsigned int ht = 0; ht <= 6; ht++) {
        CGPoint pt = { 100.0, 200.0 };
        id rep = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
            (id)cls_AXEventRep, sel_registerName("touchRepresentationWithHandType:location:"), ht, pt);
        if (rep) {
            id handInfo = ((id (*)(id, SEL))objc_msgSend)(rep, sel_registerName("handInfo"));
            id desc = handInfo ? ((id (*)(id, SEL))objc_msgSend)(handInfo, sel_registerName("description")) : nil;
            const char *s = desc ? ((const char* (*)(id, SEL))objc_msgSend)(desc, sel_registerName("UTF8String")) : "(null)";
            printf("handType=%u -> %s\n", ht, s);
        }
    }
    return 0;
}
