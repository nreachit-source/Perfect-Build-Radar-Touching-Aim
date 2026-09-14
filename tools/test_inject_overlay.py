import subprocess
from pathlib import Path
import sys

MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
ROOT = MONITOR / "sileo_repo"
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
print("Pushing radar_overlay.dylib...")
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(MONITOR / "build_codex/radar_overlay.dylib"), "/radar_overlay_test.dylib"], check=True)

script = """
rm -f /var/mobile/Downloads/entry_debug.log
cp /var/mobile/Media/radar_overlay_test.dylib /var/jb/tmp/radar_overlay_test.dylib
chmod 755 /var/jb/tmp/radar_overlay_test.dylib
ldid -S /var/jb/tmp/radar_overlay_test.dylib
HASH=$(ldid -h /var/jb/tmp/radar_overlay_test.dylib | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH"

LINE=$(ps -ef | grep SpringBoard | grep -v grep)
set -- $LINE
SB=$2
echo "Injecting radar_overlay_test.dylib into SpringBoard PID $SB..."
/var/jb/basebin/opainject "$SB" /var/jb/tmp/radar_overlay_test.dylib
sleep 1
cat /var/mobile/Downloads/entry_debug.log || true
"""
print(run_script(script, timeout=20))
