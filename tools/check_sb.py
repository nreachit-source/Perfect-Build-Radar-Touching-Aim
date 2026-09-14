import sys
from pathlib import Path
MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

script = """
LINE=$(ps -ef | grep SpringBoard | grep -v grep)
set -- $LINE
SB=$2
echo "SpringBoard PID: $SB"

# Check all /var/jb dylibs loaded in SpringBoard
vmmap $SB 2>/dev/null | grep -i '/var/jb' || echo "NO /var/jb DYLIBS FOUND IN VMMAP"
lsof -p $SB 2>/dev/null | grep -i '/var/jb' || echo "NO /var/jb DYLIBS IN LSOF"

# Check ElleKit
ls -la /var/jb/usr/lib/ellekit* 2>/dev/null || true
ls -la /var/jb/usr/lib/TweakInject/
"""
print(run_script(script, timeout=20))
