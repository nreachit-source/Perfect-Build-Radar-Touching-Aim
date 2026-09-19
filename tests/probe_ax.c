
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

int main(void) {
    dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_GLOBAL | RTLD_NOW);
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);

    const char *target_classes[] = {
        "AXBackBoardServer",
        "AXEventRepresentation",
        "BKSHIDEventRouter",
        NULL
    };

    for (int c = 0; target_classes[c]; c++) {
        Class cls = objc_getClass(target_classes[c]);
        printf("=== Class: %s (%p) ===\n", target_classes[c], cls);
        if (!cls) continue;

        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        printf("Instance methods (%u):\n", count);
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            printf("  - %s\n", sel_getName(sel));
        }
        free(methods);

        Class meta = object_getClass((id)cls);
        methods = class_copyMethodList(meta, &count);
        printf("Class methods (%u):\n", count);
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            printf("  + %s\n", sel_getName(sel));
        }
        free(methods);
    }
    return 0;
}
