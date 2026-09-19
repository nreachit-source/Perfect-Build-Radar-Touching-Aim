import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from remote_sh import run_script

script = """
python3 - << 'EOF'
import ctypes

objc = ctypes.cdll.LoadLibrary('/usr/lib/libobjc.A.dylib')
objc.objc_getClass.restype = ctypes.c_void_p
objc.objc_getClass.argtypes = [ctypes.c_char_p]
objc.sel_registerName.restype = ctypes.c_void_p
objc.sel_registerName.argtypes = [ctypes.c_char_p]
objc.objc_msgSend.restype = ctypes.c_void_p
objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities')
ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime')

cls = objc.objc_getClass(b"AXBackBoardServer")
print("AXBackBoardServer class:", hex(cls or 0))
if cls:
    srv = objc.objc_msgSend(cls, objc.sel_registerName(b"server"))
    print("server:", hex(srv or 0))
    if not srv:
        srv = objc.objc_msgSend(cls, objc.sel_registerName(b"sharedInstance"))
        print("sharedInstance:", hex(srv or 0))

cls_axrep = objc.objc_getClass(b"AXEventRepresentation")
print("AXEventRepresentation:", hex(cls_axrep or 0))

class_copyMethodList = objc.class_copyMethodList
class_copyMethodList.restype = ctypes.POINTER(ctypes.c_void_p)
class_copyMethodList.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
method_getName = objc.method_getName
method_getName.restype = ctypes.c_void_p
method_getName.argtypes = [ctypes.c_void_p]
sel_getName = objc.sel_getName
sel_getName.restype = ctypes.c_char_p
sel_getName.argtypes = [ctypes.c_void_p]

cnt = ctypes.c_uint(0)
methods = class_copyMethodList(cls, ctypes.byref(cnt))
print(f"AXBackBoardServer methods count: {cnt.value}")
touch_methods = []
for i in range(cnt.value):
    m = methods[i]
    sel = method_getName(m)
    name = sel_getName(sel).decode()
    if any(k in name.lower() for k in ["event", "touch", "post", "send", "hid", "assist"]):
        touch_methods.append(name)
print("Relevant AXBackBoardServer methods:", touch_methods)

# Check class (meta) methods
cnt_meta = ctypes.c_uint(0)
object_getClass = objc.object_getClass
object_getClass.restype = ctypes.c_void_p
object_getClass.argtypes = [ctypes.c_void_p]
meta_axrep = object_getClass(cls_axrep)
methods2 = class_copyMethodList(meta_axrep, ctypes.byref(cnt_meta))
rep_methods = []
for i in range(cnt_meta.value):
    m = methods2[i]
    sel = method_getName(m)
    name = sel_getName(sel).decode()
    if any(k in name.lower() for k in ["touch", "hand", "point", "rep", "event"]):
        rep_methods.append(name)
print("AXEventRepresentation class methods:", rep_methods)
EOF
"""
print(run_script(script))
