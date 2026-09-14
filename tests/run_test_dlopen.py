import subprocess
from pathlib import Path
import sys

MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(MONITOR / "build_codex/test_dlopen"), "/test_dlopen"], check=True)

script = """
cp /var/mobile/Media/test_dlopen /var/jb/tmp/test_dlopen
chmod 755 /var/jb/tmp/test_dlopen
ldid -S /var/jb/tmp/test_dlopen
HASH=$(ldid -h /var/jb/tmp/test_dlopen | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH"
/var/jb/tmp/test_dlopen /var/jb/usr/lib/TweakInject/radar_overlay.dylib
"""
print(run_script(script, timeout=20))
