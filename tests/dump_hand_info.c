#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

static void dump_methods(const char *cls_name) {
    Class cls = objc_getClass(cls_name);
    if (!cls) return;
    unsigned int count = 0;
    Method *m = class_copyMethodList(cls, &count);
    printf("=== %s (%u methods) ===\n", cls_name, count);
    for (unsigned int i = 0; i < count; i++) {
        printf("  %s\n", sel_getName(method_getName(m[i])));
    }
    if (m) free(m);
}

int main(void) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);

    dump_methods("AXEventHandInfoRepresentation");
    dump_methods("AXEventPathInfoRepresentation");
    return 0;
}
