#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    /* Pre-load CoreGraphics and UIKit into global namespace, like SpringBoard does */
    dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_GLOBAL | RTLD_LAZY);
    dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_GLOBAL | RTLD_LAZY);
    dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_GLOBAL | RTLD_LAZY);

    const char *p = argc > 1 ? argv[1] : "/var/jb/usr/lib/TweakInject/radar_overlay.dylib";
    printf("dlopen %s...\n", p);
    void *h = dlopen(p, RTLD_NOW);
    if (!h) {
        printf("DLERROR: %s\n", dlerror());
        return 1;
    }
    printf("SUCCESS: %p\n", h);
    return 0;
}
