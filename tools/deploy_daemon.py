"""Deploy the locally built radar daemon over USB (no schema dump)."""
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT.parent
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script


def checked(script):
    result = run_script("set -e\n" + script + "\necho CODEX_DEPLOY_OK\n", timeout=15)
    if "CODEX_DEPLOY_OK" not in result:
        raise RuntimeError(result)
    return result


def main():
    python = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                    str(MONITOR / "build_codex/ue4loadmonitor"), "/ue4loadmonitor_codex"], check=True)
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                    str(ROOT / "source/daemon/entitlements.plist"), "/codex_daemon_entitlements.plist"], check=True)
    signed = checked("""cp /var/mobile/Media/ue4loadmonitor_codex /var/jb/tmp/ue4loadmonitor_codex_next
chmod 755 /var/jb/tmp/ue4loadmonitor_codex_next
ldid -S/var/mobile/Media/codex_daemon_entitlements.plist /var/jb/tmp/ue4loadmonitor_codex_next
ldid -h /var/jb/tmp/ue4loadmonitor_codex_next""")
    match = re.search(r"^CDHash=([0-9a-fA-F]{40})$", signed, re.M)
    if not match:
        raise RuntimeError(signed)
    result = checked("/var/jb/basebin/jbctl trustcache add " + match[1] + "\n" + """
if [ ! -f /var/jb/tmp/ue4loadmonitor_before_codex ]; then
    cp /var/jb/usr/local/libexec/ue4loadmonitor /var/jb/tmp/ue4loadmonitor_before_codex
fi
mv /var/jb/tmp/ue4loadmonitor_codex_next /var/jb/usr/local/libexec/ue4loadmonitor
launchctl kickstart -k system/com.local.ue4loadmonitor""")
    print(result)


if __name__ == "__main__":
    main()
