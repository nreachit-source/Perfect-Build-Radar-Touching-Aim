import subprocess
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))
from remote_sh import run_script

tools = ROOT / "tools"
from build_local import patch_ios

zig = ROOT.parents[1] / "iPhone_RE_Toolchain/zig/zig.exe"
out_bin = ROOT.parent / "build_codex/test_hid_inject"

cmd = [str(zig), "cc", "-target", "aarch64-macos", "-std=c11", "-O2",
       str(ROOT / "tests/test_hid_inject.c"), "-o", str(out_bin)]
subprocess.run(cmd, check=True)
patch_ios(out_bin)
print("Compiled test_hid_inject")

py = ROOT.parents[1] / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(out_bin), "/test_hid_inject"], check=True)

script = """
cp /var/mobile/Media/test_hid_inject /var/jb/tmp/test_hid_inject
chmod 755 /var/jb/tmp/test_hid_inject
ldid -S /var/jb/tmp/test_hid_inject
/var/jb/tmp/test_hid_inject
"""
print(run_script(script, timeout=10))
