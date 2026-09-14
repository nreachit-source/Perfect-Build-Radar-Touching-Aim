import subprocess
from pathlib import Path
import sys

MONITOR = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor")
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
print("Pushing sdk_regression...")
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "push",
                str(MONITOR / "build_codex/sdk_regression"), "/sdk_regression_test"], check=True)

script = """
cp /var/mobile/Media/sdk_regression_test /var/jb/tmp/sdk_regression_test
chmod 755 /var/jb/tmp/sdk_regression_test
ldid -S /var/jb/tmp/sdk_regression_test
HASH=$(ldid -h /var/jb/tmp/sdk_regression_test | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH"
/var/jb/tmp/sdk_regression_test
echo REGRESSION_DONE
"""
print(run_script(script, timeout=20))
