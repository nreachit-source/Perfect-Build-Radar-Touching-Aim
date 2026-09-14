import sys
from pathlib import Path
MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

script = """
python3 - << 'EOF'
import json, glob, os

files = sorted(glob.glob('/var/mobile/Library/Logs/CrashReporter/*.ips'), key=os.path.getmtime)
if not files:
    print("No ips files found")
    exit(0)

latest = files[-1]
print("Latest crash log:", latest)
try:
    with open(latest, 'r', errors='ignore') as f:
        data = json.load(f)
    print("Termination:", data.get("termination"))
    print("Faulting thread:", data.get("faultingThread"))
    ft = data.get("faultingThread", 0)
    threads = data.get("threads", [])
    if ft < len(threads):
        print("Frames:")
        for frame in threads[ft].get("frames", [])[:15]:
            print(frame)
except Exception as e:
    print("Error parsing:", e)
EOF
"""
print(run_script(script, timeout=15))
