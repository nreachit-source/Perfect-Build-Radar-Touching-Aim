"""Clear Dopamine safe mode flag and cleanly respring SpringBoard."""
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from remote_sh import run_script

script = """
rm -f /var/jb/basebin/.safe_mode
rm -f /var/mobile/Downloads/overlay_sb_pid.txt
echo "Safe mode flag removed: $(ls -la /var/jb/basebin/.safe_mode 2>&1 || true)"
if [ -x /var/jb/usr/bin/sbreload ]; then
    /var/jb/usr/bin/sbreload || killall -9 SpringBoard
else
    killall -9 SpringBoard
fi
sleep 3
ps -ef | grep SpringBoard | grep -v grep
"""
print(run_script(script, timeout=15))
