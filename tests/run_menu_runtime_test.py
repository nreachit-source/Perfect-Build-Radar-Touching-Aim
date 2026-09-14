import subprocess
from pathlib import Path
import sys
import time

MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
print("Pushing menu_runtime_test.dylib...")
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(MONITOR / "build_codex/menu_runtime_test.dylib"), "/menu_runtime_test.dylib"], check=True)

ps_out = run_script("ps -ef")
sb_pid = None
for line in ps_out.splitlines():
    if "SpringBoard.app/SpringBoard" in line:
        parts = line.split()
        if len(parts) >= 2:
            sb_pid = parts[1]
            break

if not sb_pid:
    raise RuntimeError(f"Could not find SpringBoard PID in ps -ef:\n{ps_out}")

print(f"Found SpringBoard PID: {sb_pid}")

script = f"""
cp /var/mobile/Media/menu_runtime_test.dylib /var/jb/tmp/menu_runtime_test.dylib
chmod 755 /var/jb/tmp/menu_runtime_test.dylib
ldid -S /var/jb/tmp/menu_runtime_test.dylib
HASH=$(ldid -h /var/jb/tmp/menu_runtime_test.dylib | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH"

echo "Injecting into SpringBoard PID {sb_pid}..."
/var/jb/basebin/jbctl proc_set_debugged "{sb_pid}" || true
/var/jb/basebin/opainject "{sb_pid}" /var/jb/tmp/menu_runtime_test.dylib
sleep 1
cat /var/mobile/Downloads/ue4_menu_test.log
"""
print(run_script(script, timeout=20))
