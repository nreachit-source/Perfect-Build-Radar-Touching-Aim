import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))
from remote_sh import run_script

print("=== Checking backboardd and HID event logs ===")
script = """
/var/jb/tmp/test_hid_inject
sleep 1
log show --predicate 'process == "backboardd" or sender == "IOKit"' --last 10s --style compact 2>&1 | tail -n 25
"""
print(run_script(script, timeout=20))
