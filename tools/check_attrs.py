import sys
from remote_sh import run_script

script = """
python3 - << 'EOF'
import ctypes
uikit = ctypes.CDLL(None)
try:
    p_font = ctypes.c_void_p.in_dll(uikit, 'NSFontAttributeName')
    p_color = ctypes.c_void_p.in_dll(uikit, 'NSForegroundColorAttributeName')
    print('NSFontAttributeName:', hex(p_font.value))
    print('NSForegroundColorAttributeName:', hex(p_color.value))
    # print string contents
    cfstring_get_cstring = uikit.CFStringGetCString
    cfstring_get_cstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    buf1 = ctypes.create_string_buffer(64)
    cfstring_get_cstring(p_font.value, buf1, 64, 0x08000100)
    buf2 = ctypes.create_string_buffer(64)
    cfstring_get_cstring(p_color.value, buf2, 64, 0x08000100)
    print('font key string:', buf1.value.decode())
    print('color key string:', buf2.value.decode())
except Exception as e:
    print('Error:', e)
EOF
"""
print(run_script(script))
