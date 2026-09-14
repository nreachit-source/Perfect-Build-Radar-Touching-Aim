import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))
from remote_sh import run_script

script = """
cat << 'EOF' > /var/jb/tmp/test_hid.py
import ctypes
import ctypes.util

iokit = ctypes.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
print('IOKit loaded:', bool(iokit))

def check_sym(dll, name):
    try:
        fn = getattr(dll, name)
        print(f'{name}: {hex(ctypes.cast(fn, ctypes.c_void_p).value or 0)}')
    except Exception as e:
        print(f'{name}: NOT FOUND ({e})')

check_sym(iokit, 'IOHIDEventSystemClientCreate')
check_sym(iokit, 'IOHIDEventSystemClientDispatchEvent')
check_sym(iokit, 'IOHIDEventCreateDigitizerFingerEvent')
check_sym(iokit, 'IOHIDEventCreateDigitizerEvent')

try:
    bks = ctypes.CDLL('/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices')
    print('BackBoardServices loaded:', bool(bks))
    check_sym(bks, 'BKSHIDEventSendToApplicationWithBundleID')
except Exception as e:
    print('BackBoardServices failed:', e)

EOF
python3 /var/jb/tmp/test_hid.py
"""
print(run_script(script, timeout=10))
