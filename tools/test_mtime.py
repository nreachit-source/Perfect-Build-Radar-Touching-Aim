import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from remote_sh import run_script

script = """
LOG=/var/mobile/Downloads/ue4_overlay_v3_proof.log
MOD=$(stat -c %Y "$LOG" 2>/dev/null || stat -f %m "$LOG" 2>/dev/null || echo 0)
NOW=$(date +%s)
DIFF=$(( NOW - MOD ))
echo "MOD=$MOD NOW=$NOW DIFF=$DIFF"
"""
print(run_script(script, timeout=10))
