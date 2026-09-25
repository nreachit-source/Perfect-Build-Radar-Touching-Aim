import subprocess
from pathlib import Path
import sys

MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
REPO = MONITOR / "sileo_repo"
sys.path.insert(0, str(REPO / "tools"))
from remote_sh import run_script
from build_local import patch_ios

py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
zig = MONITOR.parent / "iPhone_RE_Toolchain/zig/zig.exe"

out_bin = MONITOR / "build_codex/launch_game"
cmd = [str(zig), "cc", "-target", "aarch64-macos", "-Wl,-undefined,dynamic_lookup",
       str(REPO / "tests/launch_game.c"), "-o", str(out_bin)]
subprocess.run(cmd, check=True)
patch_ios(out_bin)
print("Compiled and patched launch_game")

subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push", str(out_bin), "/launch_game"], check=True)

script = """
cp /var/mobile/Media/launch_game /var/jb/tmp/launch_game
chmod 755 /var/jb/tmp/launch_game
ldid -S /var/jb/tmp/launch_game
HASH=$(ldid -h /var/jb/tmp/launch_game | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH" 2>/dev/null || true
/var/jb/tmp/launch_game com.tencent.ig
sleep 4
ps aux | grep ShadowTrackerExtra
"""
print(run_script(script, timeout=20))
