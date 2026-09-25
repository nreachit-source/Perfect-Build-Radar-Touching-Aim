#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef bool BOOL;

static Class (*fn_objc_getClass)(const char *name) = NULL;
static id    (*fn_objc_msgSend)(id self, SEL op, ...) = NULL;
static SEL   (*fn_sel_registerName)(const char *str) = NULL;
static const char *(*fn_class_getName)(Class cls) = NULL;
static Class (*fn_object_getClass)(id obj) = NULL;

#define objc_getClass fn_objc_getClass
#define objc_msgSend fn_objc_msgSend
#define sel_registerName fn_sel_registerName
#define class_getName fn_class_getName
#define object_getClass fn_object_getClass

__attribute__((constructor))
static void inspect_entry(void) {
    fn_objc_getClass    = (Class (*)(const char *))dlsym(RTLD_DEFAULT, "objc_getClass");
    fn_objc_msgSend      = (id (*)(id, SEL, ...))dlsym(RTLD_DEFAULT, "objc_msgSend");
    fn_sel_registerName  = (SEL (*)(const char *))dlsym(RTLD_DEFAULT, "sel_registerName");
    fn_class_getName     = (const char *(*)(Class))dlsym(RTLD_DEFAULT, "class_getName");
    fn_object_getClass   = (Class (*)(id))dlsym(RTLD_DEFAULT, "object_getClass");

    FILE *f = fopen("/var/mobile/Downloads/springboard_view_inspection.log", "w");
    if (!f) return;

    fprintf(f, "=== SpringBoard View Inspection ===\n");

    Class UIScreen_cls = objc_getClass("UIScreen");
    if (UIScreen_cls) {
        id screen = ((id (*)(id, SEL))objc_msgSend)((id)UIScreen_cls, sel_registerName("mainScreen"));
        if (screen) {
            CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(screen, sel_registerName("bounds"));
            CGRect nb = ((CGRect (*)(id, SEL))objc_msgSend)(screen, sel_registerName("nativeBounds"));
            CGFloat s = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, sel_registerName("scale"));
            fprintf(f, "mainScreen: bounds=(%.1f, %.1f, %.1f, %.1f) nativeBounds=(%.1f, %.1f, %.1f, %.1f) scale=%.1f\n",
                    b.origin.x, b.origin.y, b.size.width, b.size.height,
                    nb.origin.x, nb.origin.y, nb.size.width, nb.size.height, s);
        }
    }

    Class UIApp_cls = objc_getClass("UIApplication");
    if (UIApp_cls) {
        id app = ((id (*)(id, SEL))objc_msgSend)((id)UIApp_cls, sel_registerName("sharedApplication"));
        if (app) {
            id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
            if (scenes) {
                id sEnum = ((id (*)(id, SEL))objc_msgSend)(scenes, sel_registerName("objectEnumerator"));
                id scene = NULL;
                int s_idx = 0;
                while ((scene = ((id (*)(id, SEL))objc_msgSend)(sEnum, sel_registerName("nextObject")))) {
                    const char *cls_name = class_getName(object_getClass(scene));
                    long ori = (long)((NSInteger (*)(id, SEL))objc_msgSend)(scene, sel_registerName("interfaceOrientation"));
                    long state = (long)((NSInteger (*)(id, SEL))objc_msgSend)(scene, sel_registerName("activationState"));
                    CGRect sbounds = {0};
                    id cs = ((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("coordinateSpace"));
                    if (cs) {
                        sbounds = ((CGRect (*)(id, SEL))objc_msgSend)(cs, sel_registerName("bounds"));
                    }
                    fprintf(f, "Scene[%d]: cls=%s state=%ld ori=%ld bounds=(%.1f, %.1f, %.1f, %.1f)\n",
                            s_idx++, cls_name, state, ori, sbounds.origin.x, sbounds.origin.y, sbounds.size.width, sbounds.size.height);
                }
            }

            id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
            if (windows) {
                id wEnum = ((id (*)(id, SEL))objc_msgSend)(windows, sel_registerName("objectEnumerator"));
                id win = NULL;
                int w_idx = 0;
                while ((win = ((id (*)(id, SEL))objc_msgSend)(wEnum, sel_registerName("nextObject")))) {
                    const char *w_cls = class_getName(object_getClass(win));
                    if (strstr(w_cls, "Codex") || strstr(w_cls, "Radar")) {
                        CGRect wf = ((CGRect (*)(id, SEL))objc_msgSend)(win, sel_registerName("frame"));
                        CGRect wb = ((CGRect (*)(id, SEL))objc_msgSend)(win, sel_registerName("bounds"));
                        BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(win, sel_registerName("isHidden"));
                        id vc = ((id (*)(id, SEL))objc_msgSend)(win, sel_registerName("rootViewController"));
                        const char *vc_cls = vc ? class_getName(object_getClass(vc)) : "nil";
                        fprintf(f, "Window[%d]: cls=%s hidden=%d frame=(%.1f, %.1f, %.1f, %.1f) bounds=(%.1f, %.1f, %.1f, %.1f) vc=%s\n",
                                w_idx++, w_cls, hidden, wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
                                wb.origin.x, wb.origin.y, wb.size.width, wb.size.height, vc_cls);
                        if (vc) {
                            id rv = ((id (*)(id, SEL))objc_msgSend)(vc, sel_registerName("view"));
                            if (rv) {
                                CGRect rvf = ((CGRect (*)(id, SEL))objc_msgSend)(rv, sel_registerName("frame"));
                                CGRect rvb = ((CGRect (*)(id, SEL))objc_msgSend)(rv, sel_registerName("bounds"));
                                unsigned long mask = (unsigned long)((NSUInteger (*)(id, SEL))objc_msgSend)(rv, sel_registerName("autoresizingMask"));
                                fprintf(f, "  rootView: frame=(%.1f, %.1f, %.1f, %.1f) bounds=(%.1f, %.1f, %.1f, %.1f) autoresize=%lu\n",
                                        rvf.origin.x, rvf.origin.y, rvf.size.width, rvf.size.height,
                                        rvb.origin.x, rvb.origin.y, rvb.size.width, rvb.size.height, mask);
                                id subviews = ((id (*)(id, SEL))objc_msgSend)(rv, sel_registerName("subviews"));
                                if (subviews) {
                                    id svEnum = ((id (*)(id, SEL))objc_msgSend)(subviews, sel_registerName("objectEnumerator"));
                                    id sv = NULL;
                                    int sv_idx = 0;
                                    while ((sv = ((id (*)(id, SEL))objc_msgSend)(svEnum, sel_registerName("nextObject")))) {
                                        const char *sv_cls = class_getName(object_getClass(sv));
                                        CGRect svf = ((CGRect (*)(id, SEL))objc_msgSend)(sv, sel_registerName("frame"));
                                        CGRect svb = ((CGRect (*)(id, SEL))objc_msgSend)(sv, sel_registerName("bounds"));
                                        unsigned long svmask = (unsigned long)((NSUInteger (*)(id, SEL))objc_msgSend)(sv, sel_registerName("autoresizingMask"));
                                        fprintf(f, "    subview[%d]: cls=%s frame=(%.1f, %.1f, %.1f, %.1f) bounds=(%.1f, %.1f, %.1f, %.1f) autoresize=%lu\n",
                                                sv_idx++, sv_cls, svf.origin.x, svf.origin.y, svf.size.width, svf.size.height,
                                                svb.origin.x, svb.origin.y, svb.size.width, svb.size.height, svmask);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fprintf(f, "=== End Inspection ===\n");
    fclose(f);
}
