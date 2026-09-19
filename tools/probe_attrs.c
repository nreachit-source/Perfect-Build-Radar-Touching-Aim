#include <stdio.h>
#include <dlfcn.h>
#include <objc/message.h>

int main(void) {
    void *pFont = dlsym(RTLD_DEFAULT, "NSFontAttributeName");
    void *pColor = dlsym(RTLD_DEFAULT, "NSForegroundColorAttributeName");
    printf("pFont=%p, pColor=%p\n", pFont, pColor);
    if (pFont) {
        id fstr = *(id*)pFont;
        const char *s = ((const char* (*)(id, SEL))objc_msgSend)(fstr, sel_registerName("UTF8String"));
        printf("fstr=%p (%s)\n", fstr, s ? s : "null");
    }
    if (pColor) {
        id cstr = *(id*)pColor;
        const char *s = ((const char* (*)(id, SEL))objc_msgSend)(cstr, sel_registerName("UTF8String"));
        printf("cstr=%p (%s)\n", cstr, s ? s : "null");
    }
    return 0;
}
