/*
 * radar_overlay.m — SpringBoard tweak: radar minimap overlay.
 *
 * Reads the shared mmap'd file written by the ue4loadmonitor daemon
 * and renders a circular radar minimap showing nearby players with
 * health indicators.
 *
 * Uses raw ObjC runtime calls (no Apple SDK headers required) so it
 * compiles with Zig's cross-compiler.
 *
 * Rules:
 *   - Never #include <syslog.h>
 *   - Never call dispatch_get_main_queue() in C
 *   - Attach windowScene from connectedScenes
 */

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

/* ------------------------------------------------------------------ */
/*  ObjC runtime (no SDK headers needed)                              */
/* ------------------------------------------------------------------ */

typedef void *id;
typedef void *SEL;
typedef void *Class;
typedef void (*IMP)(void);
typedef struct objc_method *Method;
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef bool BOOL;

#define YES 1
#define NO  0
#define nil ((id)0)

extern Class objc_getClass(const char *name);
extern Class objc_allocateClassPair(Class superclass, const char *name, size_t extra);
extern void  objc_registerClassPair(Class cls);
extern BOOL  class_addMethod(Class cls, SEL sel, IMP imp, const char *types);
extern BOOL  class_addIvar(Class cls, const char *name, size_t size, uint8_t alignment, const char *types);
extern id objc_msgSend(id self, SEL op, ...);
extern SEL   sel_registerName(const char *str);

/* CGGeometry */
typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

static CGRect CGRectMake_f(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGRect r = {{x, y}, {w, h}};
    return r;
}

/* CoreGraphics context functions (linked at runtime) */
typedef void *CGContextRef;

extern CGContextRef UIGraphicsGetCurrentContext(void);
extern void CGContextSetRGBFillColor(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a);
extern void CGContextSetRGBStrokeColor(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a);
extern void CGContextFillEllipseInRect(CGContextRef c, CGRect rect);
extern void CGContextStrokeEllipseInRect(CGContextRef c, CGRect rect);
extern void CGContextSetLineWidth(CGContextRef c, CGFloat w);
extern void CGContextMoveToPoint(CGContextRef c, CGFloat x, CGFloat y);
extern void CGContextAddLineToPoint(CGContextRef c, CGFloat x, CGFloat y);
extern void CGContextStrokePath(CGContextRef c);
extern void CGContextAddArc(CGContextRef c, CGFloat x, CGFloat y, CGFloat radius,
                             CGFloat startAngle, CGFloat endAngle, int clockwise);
extern void CGContextFillRect(CGContextRef c, CGRect rect);

/* NSLog */
extern void NSLog(id format, ...);

/* Helper: create NSString from C string */
static id nsstr(const char *s) {
    return ((id (*)(id, SEL, const char *))objc_msgSend)((id)objc_getClass("NSString"),
                        sel_registerName("stringWithUTF8String:"), s);
}


static void inspect(id self,SEL cmd) {
 (void)self;(void)cmd;
 FILE *f=fopen("/var/mobile/Downloads/ue4_menu_test.log","w");if(!f)return;
 id app=((id (*)(id,SEL))objc_msgSend)((id)objc_getClass("UIApplication"),sel_registerName("sharedApplication"));
 id windows=((id (*)(id,SEL))objc_msgSend)(app,sel_registerName("windows"));
 id en=((id (*)(id,SEL))objc_msgSend)(windows,sel_registerName("objectEnumerator"));id w;
 while((w=((id (*)(id,SEL))objc_msgSend)(en,sel_registerName("nextObject")))) {
  Class cls=objc_getClass("CodexRadarV3Window");
  if(!cls||!((BOOL (*)(id,SEL,Class))objc_msgSend)(w,sel_registerName("isKindOfClass:"),cls))continue;
  id views=((id (*)(id,SEL))objc_msgSend)(w,sel_registerName("subviews"));
  id it=((id (*)(id,SEL))objc_msgSend)(views,sel_registerName("objectEnumerator"));id v;int buttons=0;
  while((v=((id (*)(id,SEL))objc_msgSend)(it,sel_registerName("nextObject")))) {
   if(!((BOOL (*)(id,SEL,Class))objc_msgSend)(v,sel_registerName("isKindOfClass:"),objc_getClass("UIButton")))continue;
   id title=((id (*)(id,SEL,NSUInteger))objc_msgSend)(v,sel_registerName("titleForState:"),0);
   const char *before=((const char *(*)(id,SEL))objc_msgSend)(title,sel_registerName("UTF8String"));
   char saved[96];snprintf(saved,sizeof(saved),"%s",before?before:"");
   ((void (*)(id,SEL,NSUInteger))objc_msgSend)(v,sel_registerName("sendActionsForControlEvents:"),64);
   title=((id (*)(id,SEL,NSUInteger))objc_msgSend)(v,sel_registerName("titleForState:"),0);
   const char *after=((const char *(*)(id,SEL))objc_msgSend)(title,sel_registerName("UTF8String"));
   fprintf(f,"button %s -> %s changed=%d\n",saved,after,strcmp(saved,after)!=0);
   ((void (*)(id,SEL,NSUInteger))objc_msgSend)(v,sel_registerName("sendActionsForControlEvents:"),64);
   title=((id (*)(id,SEL,NSUInteger))objc_msgSend)(v,sel_registerName("titleForState:"),0);
   after=((const char *(*)(id,SEL))objc_msgSend)(title,sel_registerName("UTF8String"));
   fprintf(f,"restored=%d\n",strcmp(saved,after)==0);buttons++;
  }
  BOOL blocked=((BOOL (*)(id,SEL,CGPoint,id))objc_msgSend)(w,sel_registerName("pointInside:withEvent:"),(CGPoint){2,2},nil);
  fprintf(f,"buttons=%d game_corner_pass_through=%d\n",buttons,!blocked);
 }
 fclose(f);
}
__attribute__((constructor)) static void entry(void) {
 Class cls=objc_allocateClassPair(objc_getClass("NSObject"),"CodexMenuTest",0);
 if(!cls)return;
 class_addMethod(cls,sel_registerName("inspect"),(IMP)inspect,"v@:");objc_registerClassPair(cls);
 id helper=((id (*)(id,SEL))objc_msgSend)(((id (*)(id,SEL))objc_msgSend)((id)cls,sel_registerName("alloc")),sel_registerName("init"));
 ((void (*)(id,SEL,SEL,id,BOOL))objc_msgSend)(helper,sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),sel_registerName("inspect"),nil,NO);
}
