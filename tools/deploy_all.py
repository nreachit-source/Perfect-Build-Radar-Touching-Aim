"""Deploy locally built ue4loadmonitor daemon and radar_overlay.dylib to iOS device."""
import re
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT.parent
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

def checked(script, timeout=25):
    result = run_script("set -e\n" + script + "\necho CODEX_DEPLOY_OK\n", timeout=timeout)
    if "CODEX_DEPLOY_OK" not in result:
        raise RuntimeError(result)
    return result

def main():
    python = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"

    print("==> 1. Pushing binary artifacts via USB AFC...")
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                    str(MONITOR / "build_codex/ue4loadmonitor"), "/ue4loadmonitor_next"], check=True)
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                    str(ROOT / "source/daemon/entitlements.plist"), "/daemon_entitlements.plist"], check=True)
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                    str(ROOT / "source/daemon/com.local.ue4loadmonitor.plist"), "/com.local.ue4loadmonitor.plist"], check=True)
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                    str(MONITOR / "build_codex/radar_overlay.dylib"), "/radar_overlay_next.dylib"], check=True)
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                    str(ROOT / "source/overlay/radar_overlay.plist"), "/radar_overlay.plist"], check=True)

    print("==> 2. Signing and registering trustcache...")
    sign_script = """
# Clean up trustcache if large (table limit 256)
TC_COUNT=$(/var/jb/basebin/jbctl trustcache info 2>/dev/null | grep -c '^[|]')
if [ "$TC_COUNT" -gt 100 ]; then
    /var/jb/basebin/jbctl trustcache clear
fi

# Stage daemon
cp /var/mobile/Media/ue4loadmonitor_next /var/jb/tmp/ue4loadmonitor_staged
chmod 755 /var/jb/tmp/ue4loadmonitor_staged
ldid -S/var/mobile/Media/daemon_entitlements.plist /var/jb/tmp/ue4loadmonitor_staged
DHASH=$(ldid -h /var/jb/tmp/ue4loadmonitor_staged | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$DHASH"

# Install daemon binary and launchd configuration
mv /var/jb/tmp/ue4loadmonitor_staged /var/jb/usr/local/libexec/ue4loadmonitor
cp /var/mobile/Media/com.local.ue4loadmonitor.plist /var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist
chmod 644 /var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist

# Install overlay tweak into TweakInject
cp /var/mobile/Media/radar_overlay.plist /var/jb/usr/lib/TweakInject/radar_overlay.plist
cp /var/mobile/Media/radar_overlay_next.dylib /var/jb/usr/lib/TweakInject/radar_overlay.dylib
chmod 755 /var/jb/usr/lib/TweakInject/radar_overlay.dylib
ldid -S /var/jb/usr/lib/TweakInject/radar_overlay.dylib
OHASH=$(ldid -h /var/jb/usr/lib/TweakInject/radar_overlay.dylib | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$OHASH"

# Bootstrap daemon via launchctl
launchctl unload /var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist 2>/dev/null || true
launchctl load -w /var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist 2>/dev/null || true
launchctl kickstart -k system/com.local.ue4loadmonitor 2>/dev/null || true
"""
    res = checked(sign_script)
    print("Daemon and tweak staged successfully.")

    print("==> 3. Ensuring game and SpringBoard are running cleanly...")
    ensure_script = """
# Check if game is running; if not, launch it
if ! ps -ef | grep -v grep | grep -q ShadowTrackerExtra; then
    uiopen --bundleid com.tencent.ig || true
    sleep 3
fi

# Clear any safe mode flag from Dopamine
rm -f /var/jb/basebin/.safe_mode

# Cleanly restart SpringBoard via sbreload
if [ -x /var/jb/usr/bin/sbreload ]; then
    /var/jb/usr/bin/sbreload || killall -9 SpringBoard
else
    killall -9 SpringBoard
fi
sleep 4
"""
    try:
        run_script(ensure_script, timeout=12)
    except Exception:
        pass

    time.sleep(4)
    status = run_script("ps -ef | grep -E 'SpringBoard|ue4load|ShadowTracker' | grep -v grep")
    print(status)
    print("Deployment complete.")

if __name__ == "__main__":
    main()
