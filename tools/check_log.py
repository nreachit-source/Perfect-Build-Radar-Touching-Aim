import sys
from pathlib import Path
MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

script = """
log show --last 1m --style compact | grep -E "SpringBoard|dyld|radar" | tail -n 30
"""
print(run_script(script, timeout=15))
