# Touch delivery correction — 2026-09-19

The previous 7/7 report did not prove foreground touch reception. Test 7 sends events and observes no receiver. Test 5 tests a duplicate transform, not the overlay view transform.

Changes:
- Decode IOHIDServiceClientGetRegistryID as a borrowed CFNumber with CFNumberGetValue(SInt64); never use its pointer/tagged-object bits as the sender ID. Device now resolves 0x10000053f.
- IOHIDEventAppendEvent receives its third options argument (0).
- Parent event mask, range, and touch follow down/move/up; release no longer leaves the parent touching.
- Convert the drawn point from g_esp_view into UIScreen.fixedCoordinateSpace and use its bounds for both injection paths. The previous rotation formula remains a fallback if coordinate-space conversion is unavailable.
- Remove immediate, untimed startup swipe.
- Rebuild test suite from source on each invocation and check device exit status. Remove the claim of 100% operational delivery.

Verification:
- tools/build_local.py: all five targets compiled with warnings as errors and iOS ARM64 load commands verified.
- Corrected suite: 7/7 dispatch checks, device exit 0. This is NOT proof of app reception.
- Installed overlay SHA-256: f35069869b5e195d36047f3c95c09bdd6a045f8e4b46ffc8dd2f877ab38b66c2.
- SpringBoard PID 1470; constructor PID marker matches. BUILD touch-delivery-20260919 and advancing timers confirmed.
- Game was closed by the necessary SpringBoard reload. uiopen was attempted; subsequent process checks did not show the game running. User must enter gameplay for reception/location verification.

API references:
- https://developer.apple.com/documentation/iokit/2269426-iohidserviceclientgetregistryid
- https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/ios/IOKitSPIIOS.h

Remaining: confirm camera response at the drawn touch point. Do not repeat the earlier false success claim based solely on dispatch logs.
