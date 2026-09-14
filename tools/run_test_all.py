import subprocess
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from remote_sh import run_script

tools = ROOT / "tools"
from build_local import patch_ios

zig = ROOT.parents[1] / "iPhone_RE_Toolchain/zig/zig.exe"
out_bin = ROOT.parent / "build_codex/test_all_features"

cmd = [str(zig), "cc", "-target", "aarch64-macos", "-std=c11", "-O2",
       "-Wall", "-Wextra",
       str(ROOT / "tests/test_all_features.c"), "-o", str(out_bin)]
subprocess.run(cmd, check=True)
patch_ios(out_bin)
print("Compiled and patched test_all_features")

py = ROOT.parents[1] / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(out_bin), "/test_all_features"], check=True)
print("Pushed test_all_features via AFC")

script = """
cp /var/mobile/Media/test_all_features /var/jb/tmp/test_all_features
chmod 755 /var/jb/tmp/test_all_features
ldid -S /var/jb/tmp/test_all_features
/var/jb/tmp/test_all_features
"""
print(run_script(script, timeout=15))
