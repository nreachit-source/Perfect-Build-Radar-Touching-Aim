import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))
from remote_sh import run_script

script = """
cat << 'EOF' > /var/jb/tmp/check_syms.c
#include <stdio.h>
#include <dlfcn.h>
int main() {
    void *hBKS = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_GLOBAL | RTLD_NOW);
    printf("BKS handle: %p\\n", hBKS);
    if (hBKS) {
        printf("BKSHIDEventSendToApplicationWithBundleID: %p\\n", dlsym(hBKS, "BKSHIDEventSendToApplicationWithBundleID"));
        printf("BKSHIDEventSendToApplication: %p\\n", dlsym(hBKS, "BKSHIDEventSendToApplication"));
        printf("BKSHIDEventRouter: %p\\n", dlsym(hBKS, "BKSHIDEventRouter"));
        printf("BKSHIDEventRegisterEventCallback: %p\\n", dlsym(hBKS, "BKSHIDEventRegisterEventCallback"));
    }
    void *hIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_GLOBAL | RTLD_NOW);
    if (hIOKit) {
        printf("IOHIDEventSystemClientCreateWithType: %p\\n", dlsym(hIOKit, "IOHIDEventSystemClientCreateWithType"));
        printf("IOHIDEventSystemClientDispatchEvent: %p\\n", dlsym(hIOKit, "IOHIDEventSystemClientDispatchEvent"));
    }
    return 0;
}
EOF
clang -O2 /var/jb/tmp/check_syms.c -o /var/jb/tmp/check_syms 2>&1 || true
if [ -f /var/jb/tmp/check_syms ]; then
    chmod 755 /var/jb/tmp/check_syms
    ldid -S /var/jb/tmp/check_syms
    /var/jb/tmp/check_syms
fi
"""
print(run_script(script, timeout=15))
