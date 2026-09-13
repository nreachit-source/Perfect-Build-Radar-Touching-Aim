#ifndef UIKIT_LITE_H
#define UIKIT_LITE_H

#import <objc/runtime.h>
#import <objc/message.h>

typedef double CGFloat;
typedef struct CGPoint { CGFloat x, y; } CGPoint;
typedef struct CGSize { CGFloat width, height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;

typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef NSInteger UIModalPresentationStyle;
typedef NSInteger UIBlurEffectStyle;
typedef NSInteger UIControlState;
typedef NSInteger UIControlEvents;

#define UIControlStateNormal 0
#define UIControlEventTouchUpInside (1 << 6)
#define UIBlurEffectStyleDark 2
#define NSTextAlignmentCenter 1

@class UIEvent, CALayer, UILabel, UIView, UIWindowScene;

@interface NSObject
+ (id)alloc;
- (id)init;
- (id)copy;
- (BOOL)isKindOfClass:(Class)aClass;
- (void)performSelectorOnMainThread:(SEL)aSelector withObject:(id)arg waitUntilDone:(BOOL)wait;
@end

@interface NSString : NSObject
+ (instancetype)stringWithUTF8String:(const char *)nullTerminatedCString;
+ (instancetype)stringWithFormat:(NSString *)format, ...;
- (const char *)UTF8String;
@end

@interface NSSet : NSObject
- (NSUInteger)count;
- (id)anyObject;
- (NSUInteger)countByEnumeratingWithState:(void *)state objects:(id *)stackbuf count:(NSUInteger)len;
@end

@interface UIColor : NSObject
+ (UIColor *)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
+ (UIColor *)whiteColor;
+ (UIColor *)blackColor;
+ (UIColor *)clearColor;
+ (UIColor *)systemGreenColor;
+ (UIColor *)systemBlueColor;
+ (UIColor *)systemGrayColor;
+ (UIColor *)colorWithWhite:(CGFloat)white alpha:(CGFloat)alpha;
- (void *)CGColor;
@end

@interface UIFont : NSObject
+ (UIFont *)systemFontOfSize:(CGFloat)fontSize;
+ (UIFont *)boldSystemFontOfSize:(CGFloat)fontSize;
+ (UIFont *)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight;
@end

@interface UIScreen : NSObject
+ (UIScreen *)mainScreen;
- (CGRect)bounds;
- (CGFloat)scale;
@end

@interface CALayer : NSObject
@property CGFloat cornerRadius;
@property CGFloat borderWidth;
@property (assign) void *borderColor;
@property BOOL masksToBounds;
@property float shadowOpacity;
@property CGFloat shadowRadius;
@property CGSize shadowOffset;
@property (assign) void *shadowColor;
@end

@interface UIView : NSObject
- (instancetype)initWithFrame:(CGRect)frame;
@property CGRect frame;
@property CGRect bounds;
@property CGPoint center;
@property (retain) UIColor *backgroundColor;
@property (readonly) CALayer *layer;
@property (getter=isHidden) BOOL hidden;
@property (getter=isUserInteractionEnabled) BOOL userInteractionEnabled;
@property CGFloat alpha;
@property BOOL clipsToBounds;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event;
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event;
- (CGPoint)convertPoint:(CGPoint)point toView:(UIView *)view;
- (void)addGestureRecognizer:(id)gestureRecognizer;
+ (void)animateWithDuration:(double)duration animations:(void (^)(void))animations;
+ (void)animateWithDuration:(double)duration animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion;
@end

@interface UILabel : UIView
@property (copy) NSString *text;
@property (retain) UIFont *font;
@property (retain) UIColor *textColor;
@property NSInteger textAlignment;
@property NSInteger numberOfLines;
@end

@interface UIControl : UIView
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents;
@end

@interface UIButton : UIControl
+ (instancetype)buttonWithType:(NSInteger)buttonType;
- (void)setTitle:(NSString *)title forState:(UIControlState)state;
- (void)setTitleColor:(UIColor *)color forState:(UIControlState)state;
@property (readonly) UILabel *titleLabel;
@end

@interface UIWindowScene : NSObject
@end

@interface UIWindow : UIView
@property (assign) UIWindowScene *windowScene;
@property CGFloat windowLevel;
@property (retain) id rootViewController;
- (void)makeKeyAndVisible;
@end

@interface UIViewController : NSObject
- (instancetype)init;
@property (retain) UIView *view;
- (void)viewDidLoad;
@end

@interface UIApplication : NSObject
+ (UIApplication *)sharedApplication;
- (NSSet *)connectedScenes;
- (UIWindow *)keyWindow;
@end

@interface UIVisualEffect : NSObject
@end

@interface UIBlurEffect : UIVisualEffect
+ (UIBlurEffect *)effectWithStyle:(UIBlurEffectStyle)style;
@end

@interface UIVisualEffectView : UIView
- (instancetype)initWithEffect:(UIVisualEffect *)effect;
@property (readonly) UIView *contentView;
@end

typedef NSInteger UIGestureRecognizerState;
#define UIGestureRecognizerStateBegan 1
#define UIGestureRecognizerStateChanged 2
#define UIGestureRecognizerStateEnded 3

@interface UIGestureRecognizer : NSObject
- (instancetype)initWithTarget:(id)target action:(SEL)action;
@property (readonly) UIGestureRecognizerState state;
@end

@interface UIPanGestureRecognizer : UIGestureRecognizer
- (CGPoint)translationInView:(UIView *)view;
- (void)setTranslation:(CGPoint)translation inView:(UIView *)view;
- (CGPoint)locationInView:(UIView *)view;
@end

@interface NSNotification : NSObject
@property (copy, readonly) NSString *name;
@end

@interface NSNotificationCenter : NSObject
+ (NSNotificationCenter *)defaultCenter;
- (void)addObserver:(id)observer selector:(SEL)aSelector name:(NSString *)aName object:(id)anObject;
@end

#endif
