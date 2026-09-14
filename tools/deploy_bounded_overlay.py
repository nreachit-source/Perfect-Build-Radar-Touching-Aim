"""Stage/sign this overlay atomically, retaining the previous binary for rollback."""
import re
import subprocess
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))
from remote_sh import run_script

def checked(script):
    result = run_script("set -e\n" + script + "\necho BOUNDED_DEPLOY_OK\n", timeout=15)
    print(result)
    if "BOUNDED_DEPLOY_OK" not in result:
        raise RuntimeError("Deployment did not complete")
    return result

py = ROOT.parents[1] / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
    str(ROOT.parent / "build_codex/radar_overlay.dylib"), "/radar_bounded_next.dylib"], check=True)
signed = checked("""cp /var/mobile/Media/radar_bounded_next.dylib /var/jb/tmp/radar_bounded_next.dylib
chmod 755 /var/jb/tmp/radar_bounded_next.dylib
ldid -S /var/jb/tmp/radar_bounded_next.dylib
ldid -h /var/jb/tmp/radar_bounded_next.dylib""")
m = re.search(r"^CDHash=([a-fA-F0-9]{40})$", signed, re.M)
if not m: raise RuntimeError("Missing signed hash")
checked("/var/jb/basebin/jbctl trustcache add " + m[1] + "\n" + """
if [ ! -f /var/jb/tmp/radar_before_bounded.dylib ]; then
 cp /var/jb/usr/lib/TweakInject/radar_overlay.dylib /var/jb/tmp/radar_before_bounded.dylib
fi
mv /var/jb/tmp/radar_bounded_next.dylib /var/jb/usr/lib/TweakInject/radar_overlay.dylib
if [ -f /var/jb/basebin/.safe_mode ]; then
 mv /var/jb/basebin/.safe_mode /var/jb/tmp/safe_mode_before_bounded
fi
""")
print(run_script("/var/jb/usr/bin/sbreload", timeout=8))
