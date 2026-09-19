#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct { double x, y; } CGPoint;

static void dump_methods(const char *cls_name) {
    Class cls = objc_getClass(cls_name);
    if (!cls) {
        printf("Class %s NOT FOUND\n", cls_name);
        return;
    }
    printf("=== Class %s ===\n", cls_name);
    unsigned int count = 0;
    Method *m = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(m[i]));
        if (strstr(name, "Event") || strstr(name, "event") || strstr(name, "Touch") || strstr(name, "touch") ||
            strstr(name, "post") || strstr(name, "server") || strstr(name, "Orientation") || strstr(name, "send")) {
            printf("  - %s\n", name);
        }
    }
    if (m) free(m);

    Class meta = object_getClass((id)cls);
    m = class_copyMethodList(meta, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(m[i]));
        printf("  + %s\n", name);
    }
    if (m) free(m);
}

static void dump_ivars(Class cls, id obj) {
    printf("=== Ivars for %s ===\n", class_getName(cls));
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        ptrdiff_t offset = ivar_getOffset(ivars[i]);
        void *val = NULL;
        if (obj) val = *(void **)((char *)obj + offset);
        printf("  ivar: %s (type: %s, offset: %ld) = %p\n", name, type, (long)offset, val);
    }
    if (ivars) free(ivars);
}

int main() {
    dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);

    dump_methods("AXServer");
    Class cls_AXBackBoard = objc_getClass("AXBackBoardServer");
    Class cls_AXEvent = objc_getClass("AXEventRepresentation");
    id srv = ((id (*)(id, SEL))objc_msgSend)((id)cls_AXBackBoard, sel_registerName("server"));
    id sident = ((id (*)(id, SEL))objc_msgSend)(srv, sel_registerName("serverIdentifier"));
    printf("srv: %p, serverIdentifier: %s\n", srv, sident ? ((const char* (*)(id, SEL))objc_msgSend)(sident, sel_registerName("UTF8String")) : "null");
    dump_ivars(cls_AXBackBoard, srv);
    Class supercls = class_getSuperclass(cls_AXBackBoard);
    if (supercls) dump_ivars(supercls, srv);


    if (srv) {
        ((void (*)(id, SEL, int))objc_msgSend)(srv, sel_registerName("registerAssistiveTouchPID:"), getpid());
        int registered_pid = ((int (*)(id, SEL))objc_msgSend)(srv, sel_registerName("accessibilityAssistiveTouchPID"));
        printf("accessibilityAssistiveTouchPID: %d (current pid: %d)\n", registered_pid, getpid());

        CGPoint pt = { 200.0, 400.0 };
        // Test down
        id rep_down = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
            (id)cls_AXEvent, sel_registerName("touchRepresentationWithHandType:location:"), 1, pt);
        printf("rep_down: %p\n", rep_down);

        if (rep_down) {
            printf("rep_down description: %s\n",
                ((const char* (*)(id, SEL))objc_msgSend)(
                    ((id (*)(id, SEL))objc_msgSend)(rep_down, sel_registerName("description")),
                    sel_registerName("UTF8String")));

            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(srv, sel_registerName("postEvent:systemEvent:"), rep_down, NO);
            printf("postEvent:systemEvent:NO dispatched successfully\n");

            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(srv, sel_registerName("postEvent:systemEvent:"), rep_down, YES);
            printf("postEvent:systemEvent:YES dispatched successfully\n");
        }

        // Test up
        id rep_up = ((id (*)(id, SEL, unsigned int, CGPoint))objc_msgSend)(
            (id)cls_AXEvent, sel_registerName("touchRepresentationWithHandType:location:"), 0, pt);
        if (rep_up) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(srv, sel_registerName("postEvent:systemEvent:"), rep_up, NO);
            printf("rep_up dispatched\n");
        }
    }
    return 0;
}