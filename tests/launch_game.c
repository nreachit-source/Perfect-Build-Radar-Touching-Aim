#include <stdio.h>
#include <dlfcn.h>
#include <stdbool.h>

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef const void *CFStringRef;

static Class (*fn_objc_getClass)(const char *name) = NULL;
static id    (*fn_objc_msgSend)(id self, SEL op, ...) = NULL;
static SEL   (*fn_sel_registerName)(const char *str) = NULL;
static CFStringRef (*fn_CFStringCreateWithCString)(void *alloc, const char *cStr, unsigned int encoding) = NULL;

int main(int argc, char **argv) {
    const char *bid = argc > 1 ? argv[1] : "com.tencent.ig";

    fn_objc_getClass = (Class (*)(const char *))dlsym(RTLD_DEFAULT, "objc_getClass");
    fn_objc_msgSend = (id (*)(id, SEL, ...))dlsym(RTLD_DEFAULT, "objc_msgSend");
    fn_sel_registerName = (SEL (*)(const char *))dlsym(RTLD_DEFAULT, "sel_registerName");
    fn_CFStringCreateWithCString = (CFStringRef (*)(void *, const char *, unsigned int))dlsym(RTLD_DEFAULT, "CFStringCreateWithCString");

    /* Try LSApplicationWorkspace first */
    if (fn_objc_getClass && fn_objc_msgSend && fn_sel_registerName && fn_CFStringCreateWithCString) {
        Class LS_cls = fn_objc_getClass("LSApplicationWorkspace");
        if (LS_cls) {
            id ws = fn_objc_msgSend((id)LS_cls, fn_sel_registerName("defaultWorkspace"));
            if (ws) {
                CFStringRef cf_bid = fn_CFStringCreateWithCString(NULL, bid, 0x08000100 /* kCFStringEncodingUTF8 */);
                bool ok = (bool)(long)fn_objc_msgSend(ws, fn_sel_registerName("openApplicationWithBundleID:"), cf_bid);
                printf("LSApplicationWorkspace openApplicationWithBundleID: %s -> %d\n", bid, ok);
                if (ok) return 0;
            }
        }
    }

    /* Fallback to SBSLaunchApplicationWithIdentifier */
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (sbs && fn_CFStringCreateWithCString) {
        typedef int (*SBSLaunchAppFn)(CFStringRef, int);
        SBSLaunchAppFn launch = (SBSLaunchAppFn)dlsym(sbs, "SBSLaunchApplicationWithIdentifier");
        if (launch) {
            CFStringRef cf_bid = fn_CFStringCreateWithCString(NULL, bid, 0x08000100);
            printf("SBSLaunchApplicationWithIdentifier: %s...\n", bid);
            int ret = launch(cf_bid, 0);
            printf("SBS Result: %d\n", ret);
            return ret;
        }
    }

    printf("Failed to launch %s\n", bid);
    return 1;
}
