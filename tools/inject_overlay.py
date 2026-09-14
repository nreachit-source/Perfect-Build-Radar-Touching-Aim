import sys
from pathlib import Path
MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

script = """
SB=$(pidof SpringBoard 2>/dev/null)
if [ -z "$SB" ]; then
    LINE=$(ps -ef | grep SpringBoard | grep -v grep)
    set -- $LINE
    SB=$2
fi
echo "Target SpringBoard PID: $SB"
/var/jb/basebin/opainject "$SB" /var/jb/usr/lib/TweakInject/radar_overlay.dylib
"""
print(run_script(script, timeout=20))
