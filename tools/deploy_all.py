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

    test_hid = MONITOR / "build_codex/test_hid_inject"
    if test_hid.is_file():
        subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "push",
                        str(test_hid), "/test_hid_inject_next"], check=True)

    print("==> 2. Signing and registering trustcache...")
    sign_script = """
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

# Install test_hid_inject tool
if [ -f /var/mobile/Media/test_hid_inject_next ]; then
    cp /var/mobile/Media/test_hid_inject_next /var/jb/tmp/test_hid_inject
    chmod 755 /var/jb/tmp/test_hid_inject
    ldid -S /var/jb/tmp/test_hid_inject
fi

# Copy signed binaries back to Media for AFC retrieval
cp /var/jb/usr/local/libexec/ue4loadmonitor /var/mobile/Media/ue4loadmonitor_signed
cp /var/jb/usr/lib/TweakInject/radar_overlay.dylib /var/mobile/Media/radar_overlay_signed.dylib

# Bootstrap daemon via launchctl
launchctl unload /var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist 2>/dev/null || true
launchctl load -w /var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist 2>/dev/null || true
launchctl kickstart -k system/com.local.ue4loadmonitor 2>/dev/null || true
"""
    res = checked(sign_script)
    print("Daemon and tweak staged successfully.")

    print("==> 3. Pulling signed artifacts back to host repository...")
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "pull",
                    "/ue4loadmonitor_signed", str(ROOT / "artifacts/ue4loadmonitor")], check=True)
    subprocess.run([str(python), "-m", "pymobiledevice3", "afc", "pull",
                    "/radar_overlay_signed.dylib", str(ROOT / "artifacts/radar_overlay.dylib")], check=True)

    print("==> 4. Updating build manifest and packaging signed release...")
    import update_artifacts
    update_artifacts.main()

    print("==> 5. Ensuring game and SpringBoard are running cleanly...")
    ensure_script = """
# Check if game is running; if not, launch it
if ! ps -ef | grep -v grep | grep -q ShadowTrackerExtra; then
    uiopen --bundleid com.tencent.ig || true
    sleep 3
fi

# Clear any safe mode flag from Dopamine
rm -f /var/jb/basebin/.safe_mode

# Cleanly restart SpringBoard via sbreload
rm -f /var/mobile/Downloads/overlay_sb_pid.txt
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
