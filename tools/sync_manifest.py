import subprocess
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from remote_sh import run_script

py = ROOT.parents[1] / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(ROOT / "artifacts/build.json"), "/build.json"], check=True)

script = """
mkdir -p /var/jb/usr/local/share/ue4loadmonitor
cp /var/mobile/Media/build.json /var/jb/usr/local/share/ue4loadmonitor/build.json
chmod 644 /var/jb/usr/local/share/ue4loadmonitor/build.json
cat /var/jb/usr/local/share/ue4loadmonitor/build.json
"""
print(run_script(script))
