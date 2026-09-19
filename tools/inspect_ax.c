#include <stdio.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>

static void dump_class(const char *name) {
    Class cls = objc_getClass(name);
    if (!cls) {
        printf(Class %s NOT FOUND\n, name);
        return;
    }
    printf(=== Class %s ===\n, name);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    printf(Instance methods (%u):\n, count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        printf( - %s\n, sel_getName(sel));
    }
    if (methods) free(methods);

    Class meta = object_getClass((id)cls);
    methods = class_copyMethodList(meta, &count);
    printf(Class methods (%u):\n, count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        printf( + %s\n, sel_getName(sel));
    }
    if (methods) free(methods);
}

int main(void) {
    dlopen(/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities, RTLD_GLOBAL | RTLD_NOW);
    dlopen(/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime, RTLD_GLOBAL | RTLD_NOW);
    dlopen(/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices, RTLD_GLOBAL | RTLD_NOW);
    dlopen(/System/Library/Frameworks/IOKit.framework/IOKit, RTLD_GLOBAL | RTLD_NOW);

    dump_class(AXBackBoardServer);
    dump_class(AXEventRepresentation);
    return 0;
}
