#include <stdio.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>
#include <mach/mach_time.h>
#include <unistd.h>

typedef const void * CFAllocatorRef;
typedef void * CFTypeRef;
typedef void * CFStringRef;
typedef void* IOHIDEventRef;
typedef void* IOHIDEventSystemClientRef;

typedef IOHIDEventSystemClientRef (*fn_create_client_t)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*fn_create_client_type_t)(CFAllocatorRef, uint32_t);
typedef void (*fn_dispatch_event_t)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*fn_create_digitizer_t)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t);
typedef IOHIDEventRef (*fn_create_finger_t)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, bool, bool, uint32_t);
typedef void (*fn_append_event_t)(IOHIDEventRef, IOHIDEventRef);
typedef void (*fn_set_sender_id_t)(IOHIDEventRef, uint64_t);
typedef void (*fn_cfrelease_t)(CFTypeRef);
typedef CFStringRef (*fn_cfstr_create_t)(CFAllocatorRef, const char *, uint32_t);
typedef void (*fn_bks_send_t)(IOHIDEventRef, CFStringRef);

static void send_touch(fn_create_digitizer_t pDigitizer,
                       fn_create_finger_t pFinger,
                       fn_append_event_t pAppend,
                       fn_set_sender_id_t pSetSender,
                       fn_dispatch_event_t pDispatch,
                       fn_cfrelease_t pRelease,
                       IOHIDEventSystemClientRef client,
                       double x, double y, int state) {
    uint64_t now = mach_absolute_time();
    uint32_t mask = 0;
    bool is_down = false;
    if (state == 1) { /* Down */
        mask = 0x03;
        is_down = true;
    } else if (state == 2) { /* Move */
        mask = 0x07;
        is_down = true;
    } else { /* Up */
        mask = 0x01;
        is_down = false;
    }

    IOHIDEventRef parent = pDigitizer(
        NULL, now, 0x23, 0, 0, mask, 0,
        x, y, 0.0, is_down ? 1.0 : 0.0, 0.0,
        is_down, is_down, 0);

    IOHIDEventRef finger = pFinger(
        NULL, now, 1, 2, mask,
        x, y, 0.0, is_down ? 1.0 : 0.0, 0.0,
        is_down, is_down, 0);

    if (parent && finger) {
        pAppend(parent, finger);
        pSetSender(parent, 0x8000000817319372ULL);
        pDispatch(client, parent);
    }
    if (finger) pRelease(finger);
    if (parent) pRelease(parent);
}

int main(void) {
    printf("=== Probing HID & BKS Injection Symbols ===\n");
    void *hIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);
    void *hCF = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_GLOBAL | RTLD_NOW);
    void *hBKS = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_GLOBAL | RTLD_NOW);

    if (!hIOKit || !hCF) {
        printf("Failed to open IOKit/CF\n");
        return 1;
    }

    fn_create_client_t pCreateClient = (fn_create_client_t)dlsym(hIOKit, "IOHIDEventSystemClientCreate");
    fn_create_client_type_t pCreateClientType = (fn_create_client_type_t)dlsym(hIOKit, "IOHIDEventSystemClientCreateWithType");
    fn_dispatch_event_t pDispatch = (fn_dispatch_event_t)dlsym(hIOKit, "IOHIDEventSystemClientDispatchEvent");
    fn_create_digitizer_t pDigitizer = (fn_create_digitizer_t)dlsym(hIOKit, "IOHIDEventCreateDigitizerEvent");
    fn_create_finger_t pFinger = (fn_create_finger_t)dlsym(hIOKit, "IOHIDEventCreateDigitizerFingerEvent");
    fn_append_event_t pAppend = (fn_append_event_t)dlsym(hIOKit, "IOHIDEventAppendEvent");
    fn_set_sender_id_t pSetSender = (fn_set_sender_id_t)dlsym(hIOKit, "IOHIDEventSetSenderID");
    fn_cfrelease_t pRelease = (fn_cfrelease_t)dlsym(hCF, "CFRelease");

    printf("IOHIDEventSystemClientCreate: %p\n", pCreateClient); fflush(stdout);
    printf("IOHIDEventSystemClientCreateWithType: %p\n", pCreateClientType); fflush(stdout);
    printf("IOHIDEventSystemClientDispatchEvent: %p\n", pDispatch); fflush(stdout);
    printf("IOHIDEventCreateDigitizerEvent: %p\n", pDigitizer); fflush(stdout);
    printf("IOHIDEventCreateDigitizerFingerEvent: %p\n", pFinger); fflush(stdout);
    printf("IOHIDEventAppendEvent: %p\n", pAppend); fflush(stdout);
    printf("IOHIDEventSetSenderID: %p\n", pSetSender); fflush(stdout);

    if (hBKS) {
        void *pBksSend = dlsym(hBKS, "BKSHIDEventSendToApplicationWithBundleID");
        printf("BKSHIDEventSendToApplicationWithBundleID: %p\n", pBksSend); fflush(stdout);
        void *pBksSendApp = dlsym(hBKS, "BKSHIDEventSendToApplication");
        printf("BKSHIDEventSendToApplication: %p\n", pBksSendApp); fflush(stdout);
    }

    IOHIDEventSystemClientRef client = NULL;
    if (pCreateClient) {
        client = pCreateClient(NULL);
        printf("Client (default): %p\n", client); fflush(stdout);
    }

    if (client && pDigitizer && pFinger && pAppend && pSetSender && pDispatch) {
        printf("Testing swipe stroke via dispatch...\n");
        send_touch(pDigitizer, pFinger, pAppend, pSetSender, pDispatch, pRelease, client, 0.50, 0.50, 1);
        for (int i = 1; i <= 5; i++) {
            usleep(16000);
            send_touch(pDigitizer, pFinger, pAppend, pSetSender, pDispatch, pRelease, client, 0.50, 0.50 - i * 0.04, 2);
        }
        usleep(16000);
        send_touch(pDigitizer, pFinger, pAppend, pSetSender, pDispatch, pRelease, client, 0.50, 0.30, 0);
        printf("Dispatched swipe completed successfully!\n");
        pRelease(client);
    }

    return 0;
}
