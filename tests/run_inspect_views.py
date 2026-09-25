import subprocess
from pathlib import Path
import sys
import time

MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
REPO = MONITOR / "sileo_repo"
sys.path.insert(0, str(REPO / "tools"))
from remote_sh import run_script
from build_local import patch_ios

py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
zig = MONITOR.parent / "iPhone_RE_Toolchain/zig/zig.exe"

out_dylib = MONITOR / "build_codex/inspect_views.dylib"
cmd = [str(zig), "cc", "-target", "aarch64-macos", "-dynamiclib", "-Wl,-undefined,dynamic_lookup",
       str(REPO / "tests/inspect_views.c"), "-o", str(out_dylib)]
subprocess.run(cmd, check=True)
patch_ios(out_dylib)
print(f"Compiled and patched: {out_dylib}")

print("Pushing inspect_views.dylib via AFC...")
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(out_dylib), "/inspect_views.dylib"], check=True)

ps_out = run_script("ps -ef")
sb_pid = None
for line in ps_out.splitlines():
    if "SpringBoard.app/SpringBoard" in line:
        parts = line.split()
        if len(parts) >= 2:
            sb_pid = parts[1]
            break

if not sb_pid:
    raise RuntimeError(f"Could not find SpringBoard PID")

print(f"Found SpringBoard PID: {sb_pid}")

script = f"""
cp /var/mobile/Media/inspect_views.dylib /var/jb/tmp/inspect_views.dylib
chmod 755 /var/jb/tmp/inspect_views.dylib
ldid -S /var/jb/tmp/inspect_views.dylib
HASH=$(ldid -h /var/jb/tmp/inspect_views.dylib | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH"

echo "Injecting into SpringBoard PID {sb_pid}..."
/var/jb/basebin/jbctl proc_set_debugged "{sb_pid}" || true
/var/jb/basebin/opainject "{sb_pid}" /var/jb/tmp/inspect_views.dylib
sleep 1
cat /var/mobile/Downloads/springboard_view_inspection.log
"""
print(run_script(script, timeout=20))
