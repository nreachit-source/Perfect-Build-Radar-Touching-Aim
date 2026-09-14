import subprocess
from pathlib import Path
import sys

ROOT = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor\sileo_repo")
MONITOR = ROOT.parent
sys.path.insert(0, str(MONITOR))
sys.path.insert(0, str(ROOT))
from remote_sh import run_script
from tools.build_local import patch_ios

ZIG = Path(r"C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\zig\zig.exe")
PY3 = Path(r"C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\.venv\Scripts\python.exe")

out_bin = MONITOR / "build_codex/probe_live"
src = ROOT / "source/daemon"

cmd = [
    str(ZIG), "cc", "-target", "aarch64-macos", "-std=c11", "-O2",
    "-Wall", "-Wextra",
    str(ROOT / "tools/probe_live.c"),
    str(src / "remote_memory.c"),
    str(src / "aslr_slide.c"),
    str(src / "ue4_reflection.c"),
    "-o", str(out_bin)
]
print("Compiling probe_live...")
subprocess.run(cmd, check=True)
patch_ios(out_bin)

print("Pushing probe_live to device...")
subprocess.run([str(PY3), "-m", "pymobiledevice3", "afc", "push",
                str(out_bin), "/probe_live"], check=True)

script = """
cp /var/mobile/Media/probe_live /var/jb/tmp/probe_live
chmod 755 /var/jb/tmp/probe_live
ldid -S/var/mobile/Media/daemon_entitlements.plist /var/jb/tmp/probe_live
HASH=$(ldid -h /var/jb/tmp/probe_live | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH"
/var/jb/tmp/probe_live
"""
print(run_script(script, timeout=20))
