#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

int main(void) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    Class cls = objc_getClass("AXBackBoardServer");
    if (!cls) {
        printf("AXBackBoardServer not found\n");
        return 1;
    }

    id srv = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("server"));
    if (!srv) srv = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedInstance"));
    printf("srv: %p\n", srv);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    printf("Methods count: %u\n", count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        const char *types = method_getTypeEncoding(methods[i]);
        if (strstr(name, "post") || strstr(name, "Event") || strstr(name, "event") || strstr(name, "Touch") || strstr(name, "touch")) {
            printf("  %s -> %s\n", name, types);
        }
    }
    if (methods) free(methods);
    return 0;
}
