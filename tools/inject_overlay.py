import sys
from pathlib import Path
MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

script = """
LINE=$(ps -ef | grep SpringBoard | grep -v grep | head -n1)
set -- $LINE
SB=$2
RECORDED=$(cat /var/mobile/Downloads/overlay_sb_pid.txt 2>/dev/null)
if [ -n "$RECORDED" ] && [ "$SB" = "$RECORDED" ]; then
    echo "Overlay is ALREADY active in SpringBoard PID: $SB"
    exit 0
fi

echo "Overlay not active in SpringBoard (PID: $SB). Safely reloading SpringBoard..."
rm -f /var/jb/basebin/.safe_mode
rm -f /var/mobile/Downloads/overlay_sb_pid.txt
if [ -x /var/jb/usr/bin/sbreload ]; then
    /var/jb/usr/bin/sbreload || killall -9 SpringBoard
else
    killall -9 SpringBoard
fi
sleep 3
NEW_SB=$(ps -ef | grep SpringBoard | grep -v grep | head -n1 | awk '{print $2}')
NEW_REC=$(cat /var/mobile/Downloads/overlay_sb_pid.txt 2>/dev/null)
echo "SpringBoard reloaded: PID=$NEW_SB, overlay_pid=$NEW_REC"
"""
print(run_script(script, timeout=20))

