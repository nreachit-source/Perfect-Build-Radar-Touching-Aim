#include <stdio.h>
#include <stdbool.h>
#include <time.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef void (*IMP)(void);
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef bool BOOL;

#define YES 1
#define NO  0
#define nil ((id)0)

static Class (*fn_objc_getClass)(const char *name) = NULL;
static Class (*fn_objc_allocateClassPair)(Class superclass, const char *name, size_t extra) = NULL;
static void  (*fn_objc_registerClassPair)(Class cls) = NULL;
static BOOL  (*fn_class_addMethod)(Class cls, SEL sel, IMP imp, const char *types) = NULL;
static id    (*fn_objc_msgSend)(id self, SEL op, ...) = NULL;
static SEL   (*fn_sel_registerName)(const char *str) = NULL;
static const char *(*fn_class_getName)(Class cls) = NULL;
static Class (*fn_object_getClass)(id obj) = NULL;

#define objc_getClass fn_objc_getClass
#define objc_allocateClassPair fn_objc_allocateClassPair
#define objc_registerClassPair fn_objc_registerClassPair
#define class_addMethod fn_class_addMethod
#define objc_msgSend fn_objc_msgSend
#define sel_registerName fn_sel_registerName
#define class_getName fn_class_getName
#define object_getClass fn_object_getClass

static void resolve_symbols(void) {
    if (fn_objc_getClass) return;
    fn_objc_getClass         = (Class (*)(const char *))dlsym(RTLD_DEFAULT, "objc_getClass");
    fn_objc_allocateClassPair = (Class (*)(Class, const char *, size_t))dlsym(RTLD_DEFAULT, "objc_allocateClassPair");
    fn_objc_registerClassPair = (void (*)(Class))dlsym(RTLD_DEFAULT, "objc_registerClassPair");
    fn_class_addMethod        = (BOOL (*)(Class, SEL, IMP, const char *))dlsym(RTLD_DEFAULT, "class_addMethod");
    fn_objc_msgSend           = (id (*)(id, SEL, ...))dlsym(RTLD_DEFAULT, "objc_msgSend");
    fn_sel_registerName       = (SEL (*)(const char *))dlsym(RTLD_DEFAULT, "sel_registerName");
    fn_class_getName          = (const char *(*)(Class))dlsym(RTLD_DEFAULT, "class_getName");
    fn_object_getClass        = (Class (*)(id))dlsym(RTLD_DEFAULT, "object_getClass");
}

typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

static void inspect_buttons_in_view(id container, FILE *f, int *button_count) {
    if (!container) return;
    id views = ((id (*)(id, SEL))objc_msgSend)(container, sel_registerName("subviews"));
    if (!views) return;
    id it = ((id (*)(id, SEL))objc_msgSend)(views, sel_registerName("objectEnumerator"));
    id v;
    Class UIButton_cls = objc_getClass("UIButton");
    while ((v = ((id (*)(id, SEL))objc_msgSend)(it, sel_registerName("nextObject")))) {
        if (((BOOL (*)(id, SEL, Class))objc_msgSend)(v, sel_registerName("isKindOfClass:"), UIButton_cls)) {
            id title = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(v, sel_registerName("titleForState:"), 0);
            const char *before = ((const char *(*)(id, SEL))objc_msgSend)(title, sel_registerName("UTF8String"));
            char saved[96] = {0};
            snprintf(saved, sizeof(saved), "%s", before ? before : "");

            /* Simulate tap */
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(v, sel_registerName("sendActionsForControlEvents:"), 64);
            title = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(v, sel_registerName("titleForState:"), 0);
            const char *after = ((const char *(*)(id, SEL))objc_msgSend)(title, sel_registerName("UTF8String"));
            char changed_str[96] = {0};
            snprintf(changed_str, sizeof(changed_str), "%s", after ? after : "");

            fprintf(f, "BUTTON: '%s' -> '%s' (actionable=%d)\n", saved, changed_str, strcmp(saved, changed_str) != 0);

            /* Restore */
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(v, sel_registerName("sendActionsForControlEvents:"), 64);
            (*button_count)++;
        } else {
            /* Recurse into subview cards (e.g. menu card) */
            inspect_buttons_in_view(v, f, button_count);
        }
    }
}

static void test_window(id w, FILE *f, BOOL *found_window) {
    if (!w || *found_window) return;
    Class wcls = object_getClass(w);
    const char *cname = wcls ? class_getName(wcls) : "";
    if (!cname || strcmp(cname, "CodexRadarV4Window") != 0) {
        Class expected = objc_getClass("CodexRadarV4Window");
        if (!expected || !((BOOL (*)(id, SEL, Class))objc_msgSend)(w, sel_registerName("isKindOfClass:"), expected)) {
            return;
        }
    }

    *found_window = YES;
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(w, sel_registerName("bounds"));
    fprintf(f, "CodexRadarV4Window found! bounds: %.0f x %.0f (class=%s)\n", bounds.size.width, bounds.size.height, cname);

    /* 1. Touch pass-through tests while menu is closed */
    BOOL block_corner = ((BOOL (*)(id, SEL, CGPoint, id))objc_msgSend)(w, sel_registerName("pointInside:withEvent:"), (CGPoint){2, 2}, nil);
    BOOL block_center = ((BOOL (*)(id, SEL, CGPoint, id))objc_msgSend)(w, sel_registerName("pointInside:withEvent:"), (CGPoint){bounds.size.width / 2.0, bounds.size.height / 2.0}, nil);
    BOOL block_btn    = ((BOOL (*)(id, SEL, CGPoint, id))objc_msgSend)(w, sel_registerName("pointInside:withEvent:"), (CGPoint){20, 55}, nil);

    fprintf(f, "TOUCH_PASSTHROUGH_CLOSED: corner_passes=%d center_passes=%d button_intercepts=%d\n",
            !block_corner, !block_center, block_btn);

    /* 2. Open the menu */
    Class rwCls = objc_getClass("CodexRadarV4Window");
    if (rwCls && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)rwCls, sel_registerName("respondsToSelector:"), sel_registerName("toggleMenu"))) {
        ((void (*)(id, SEL))objc_msgSend)((id)rwCls, sel_registerName("toggleMenu"));
    } else {
        void (*toggle_fn)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "codex_overlay_toggle_menu");
        if (toggle_fn) toggle_fn();
    }

    /* 3. Touch pass-through tests while menu is open */
    BOOL menu_block_corner = ((BOOL (*)(id, SEL, CGPoint, id))objc_msgSend)(w, sel_registerName("pointInside:withEvent:"), (CGPoint){2, 2}, nil);
    BOOL menu_block_center = ((BOOL (*)(id, SEL, CGPoint, id))objc_msgSend)(w, sel_registerName("pointInside:withEvent:"), (CGPoint){bounds.size.width / 2.0, bounds.size.height / 2.0}, nil);
    fprintf(f, "TOUCH_INTERACTIVE_OPEN: corner_passes=%d menu_intercepts=%d\n",
            !menu_block_corner, menu_block_center);

    /* 4. Inspect all buttons and verify toggle actions */
    int buttons = 0;
    inspect_buttons_in_view(w, f, &buttons);
    fprintf(f, "total_buttons_discovered=%d\n", buttons);

    /* 5. Close the menu and restore 100% touch pass-through */
    if (rwCls && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)rwCls, sel_registerName("respondsToSelector:"), sel_registerName("toggleMenu"))) {
        ((void (*)(id, SEL))objc_msgSend)((id)rwCls, sel_registerName("toggleMenu"));
    } else {
        void (*toggle_fn)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "codex_overlay_toggle_menu");
        if (toggle_fn) toggle_fn();
    }
    BOOL final_center_passes = !((BOOL (*)(id, SEL, CGPoint, id))objc_msgSend)(w, sel_registerName("pointInside:withEvent:"), (CGPoint){bounds.size.width / 2.0, bounds.size.height / 2.0}, nil);
    fprintf(f, "TOUCH_PASSTHROUGH_RESTORED: center_passes=%d\n", final_center_passes);
}

static void inspect(id self, SEL cmd) {
    (void)self; (void)cmd;
    FILE *f = fopen("/var/mobile/Downloads/ue4_menu_test.log", "w");
    if (!f) return;
    resolve_symbols();

    BOOL found_window = NO;
    id w = nil;

    /* Strategy 1: [CodexRadarV4Window sharedWindow] */
    Class rwCls = objc_getClass("CodexRadarV4Window");
    if (rwCls && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)rwCls, sel_registerName("respondsToSelector:"), sel_registerName("sharedWindow"))) {
        w = ((id (*)(id, SEL))objc_msgSend)((id)rwCls, sel_registerName("sharedWindow"));
        if (w) fprintf(f, "Discovered window via [CodexRadarV4Window sharedWindow]: %p\n", w);
    }

    /* Strategy 2: [CodexActionHelper sharedWindow] */
    if (!w) {
        Class ahCls = objc_getClass("CodexActionHelper");
        if (ahCls && ((BOOL (*)(id, SEL, SEL))objc_msgSend)((id)ahCls, sel_registerName("respondsToSelector:"), sel_registerName("sharedWindow"))) {
            w = ((id (*)(id, SEL))objc_msgSend)((id)ahCls, sel_registerName("sharedWindow"));
            if (w) fprintf(f, "Discovered window via [CodexActionHelper sharedWindow]: %p\n", w);
        }
    }

    /* Strategy 3: Direct exported getter */
    if (!w) {
        id (*get_win_fn)(void) = (id (*)(void))dlsym(RTLD_DEFAULT, "get_codex_overlay_window");
        if (get_win_fn) {
            w = get_win_fn();
            if (w) fprintf(f, "Discovered window via get_codex_overlay_window(): %p\n", w);
        }
    }

    /* Strategy 4: [UIApplication sharedApplication].windows */
    if (!w) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
        id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
        if (windows) {
            id en = ((id (*)(id, SEL))objc_msgSend)(windows, sel_registerName("objectEnumerator"));
            id cand;
            while ((cand = ((id (*)(id, SEL))objc_msgSend)(en, sel_registerName("nextObject")))) {
                Class c = object_getClass(cand);
                const char *cn = c ? class_getName(c) : "";
                if (cn && strcmp(cn, "CodexRadarV4Window") == 0) {
                    w = cand;
                    fprintf(f, "Discovered window via UIApplication.windows: %p\n", w);
                    break;
                }
            }
        }
    }

    /* Strategy 5: UIWindowScene.windows */
    if (!w) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
        id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
        if (scenes) {
            id sen = ((id (*)(id, SEL))objc_msgSend)(scenes, sel_registerName("objectEnumerator"));
            id scene;
            while ((scene = ((id (*)(id, SEL))objc_msgSend)(sen, sel_registerName("nextObject")))) {
                id swindows = ((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("windows"));
                if (swindows) {
                    id wen = ((id (*)(id, SEL))objc_msgSend)(swindows, sel_registerName("objectEnumerator"));
                    id cand;
                    while ((cand = ((id (*)(id, SEL))objc_msgSend)(wen, sel_registerName("nextObject")))) {
                        Class c = object_getClass(cand);
                        const char *cn = c ? class_getName(c) : "";
                        if (cn && strcmp(cn, "CodexRadarV4Window") == 0) {
                            w = cand;
                            fprintf(f, "Discovered window via UIWindowScene.windows: %p\n", w);
                            break;
                        }
                    }
                }
                if (w) break;
            }
        }
    }

    if (w) {
        test_window(w, f, &found_window);
    } else {
        fprintf(f, "ERROR: CodexRadarV4Window not found!\n");
    }

    fflush(f);
    fclose(f);
}

__attribute__((constructor))
static void entry(void) {
    resolve_symbols();
    Class NSThread_cls = objc_getClass("NSThread");
    if (NSThread_cls && ((BOOL (*)(id, SEL))objc_msgSend)((id)NSThread_cls, sel_registerName("isMainThread"))) {
        inspect(nil, nil);
        return;
    }

    Class cls = objc_allocateClassPair(objc_getClass("NSObject"), "CodexMenuRuntimeTest", 0);
    if (!cls) {
        cls = objc_getClass("CodexMenuRuntimeTest");
    } else {
        class_addMethod(cls, sel_registerName("inspect"), (IMP)inspect, "v@:");
        objc_registerClassPair(cls);
    }
    id helper = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc")),
        sel_registerName("init"));

    id defaultMode = ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), "kCFRunLoopDefaultMode");
    id commonModes = ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), "kCFRunLoopCommonModes");
    id modes = ((id (*)(id, SEL, id, id, ...))objc_msgSend)(
        (id)objc_getClass("NSArray"), sel_registerName("arrayWithObjects:"), defaultMode, commonModes, nil);

    ((void (*)(id, SEL, SEL, id, BOOL, id))objc_msgSend)(
        helper, sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:modes:"),
        sel_registerName("inspect"), nil, NO, modes);
}
