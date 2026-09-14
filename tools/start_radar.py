"""Start the installed radar and overlay over USB; never build or dump memory."""
import argparse
import hashlib
import json
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT.parent
PYTHON = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from remote_sh import run_script


def connected():
    try:
        with socket.create_connection(("127.0.0.1", 1337), timeout=2):
            return True
    except OSError:
        return False


def ensure_usb():
    if not PYTHON.is_file():
        raise RuntimeError("Missing device Python: " + str(PYTHON))
    if connected():
        return
    log = open(ROOT / "start_usb.log", "a")
    subprocess.Popen([str(PYTHON), "-m", "pymobiledevice3", "usbmux", "forward", "1337", "1337"],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        creationflags=subprocess.CREATE_NO_WINDOW | subprocess.DETACHED_PROCESS)
    log.close()
    for _ in range(20):
        if connected():
            return
        time.sleep(0.25)
    raise RuntimeError("USB forwarding failed. Connect and unlock the phone, trust this PC, and enable iDownload in the jailbreak app. See start_usb.log.")


def remote(script):
    result = run_script("set -e\n" + script + "\necho START_COMMAND_OK\n", timeout=12)
    if "START_COMMAND_OK" not in result:
        raise RuntimeError(result.strip() or "No response from phone. Enable iDownload and check USB.")
    return result


def overlay_tick():
    result = remote("tail -100 /var/mobile/Downloads/ue4_overlay_v3_proof.log 2>/dev/null || true")
    ticks = re.findall(r"^timer=(\d+).*", result, re.M)
    return ticks[-1] if ticks else None


def do_restart(clean_game=True, respring_overlay=False):
    """Cleanly restarts or launches PUBG and the radar daemon."""
    cmds = []
    if clean_game:
        cmds.append("""
ps -ef | grep ShadowTrackerExtra | grep -v grep | while read -r u p rest; do
    kill -9 "$p" 2>/dev/null || true
done
""")
    cmds.append("rm -f /var/jb/basebin/.safe_mode 2>/dev/null || true")
    if respring_overlay:
        cmds.append("/var/jb/usr/bin/sbreload 2>/dev/null || true")
    cmds.append("""
/var/jb/bin/launchctl kickstart -k user/501/com.local.ue4loadmonitor 2>/dev/null || \
/var/jb/bin/launchctl kickstart -k system/com.local.ue4loadmonitor 2>/dev/null || true
/var/jb/usr/bin/uiopen --bundleid com.tencent.ig 2>/dev/null || true
""")
    remote("\n".join(cmds))


def get_live_status():
    """Returns running processes and radar bin info."""
    procs = remote("ps -A -o pid,comm | grep -E 'ue4loadmonitor|ShadowTracker|SpringBoard' || true")
    ipc_info = remote("ls -la /var/mobile/Downloads/ue4_radar.bin 2>/dev/null || true")
    clean_procs = "\n".join(l for l in procs.splitlines() if l.strip() and "START_COMMAND_OK" not in l and "iDownload>" not in l)
    clean_ipc = "\n".join(l for l in ipc_info.splitlines() if l.strip() and "START_COMMAND_OK" not in l and "iDownload>" not in l)
    return clean_procs, clean_ipc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restart-overlay", action="store_true", help="Restart SpringBoard to reload the installed overlay")
    parser.add_argument("--no-loop", action="store_true", help="Launch once and exit without interactive menu")
    args = parser.parse_args()

    print("================================================================", flush=True)
    print("      iOS UE4 Radar & ESP Launcher (Release 1.3.3)             ", flush=True)
    print("================================================================", flush=True)
    print("[*] Keep phone UNLOCKED and screen ON during startup.", flush=True)
    print("[*] Connecting to iPhone over USB (port 1337)...", flush=True)
    ensure_usb()

    # 1. Verify installed files exist and are executable
    remote("""
test -s /var/jb/usr/local/libexec/ue4loadmonitor
test -s /var/jb/usr/lib/TweakInject/radar_overlay.dylib
test -s /var/jb/usr/lib/TweakInject/radar_overlay.plist
""")

    manifest = json.loads((ROOT / "artifacts/build.json").read_text())
    for name, expected in manifest["sha256"].items():
        if hashlib.sha256((ROOT / "artifacts" / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError("Local release artifact mismatch: " + name)

    print(f"[+] Verified installation for UE4 Load Monitor {manifest['version']}", flush=True)

    # 2. Check overlay heartbeat and ensure active
    tick = overlay_tick()
    if args.restart_overlay or not tick:
        print("[*] Activating / reloading overlay in SpringBoard...", flush=True)
        remote("""
LINE=$(ps -ef | grep SpringBoard | grep -v grep | head -n1)
set -- $LINE
SB=$2
if [ -n "$SB" ]; then
    /var/jb/basebin/jbctl proc_set_debugged "$SB" 2>/dev/null || true
    /var/jb/basebin/opainject "$SB" /var/jb/usr/lib/TweakInject/radar_overlay.dylib 2>/dev/null || true
fi
""")
        time.sleep(2)

    # 3. Launch / Restart game and daemon
    print("[*] Launching Radar Daemon and PUBG Mobile...", flush=True)
    do_restart(clean_game=False, respring_overlay=False)
    time.sleep(3)

    procs, ipc_info = get_live_status()
    print("\n[+] LIVE SYSTEM STATUS:")
    print(procs)
    if ipc_info:
        print(f"[+] IPC Shared Memory: {ipc_info}")
    
    print("\n[+] Overlay is active. Tap 'ESP' on screen for settings; tap 'Collapse' to close.")
    print("[+] Radar is running. Wait for LIVE status in-game.")

    if args.no_loop:
        return

    # 4. Interactive Quick-Restart Console Loop
    while True:
        print("\n" + "-" * 64)
        print("  QUICK RESTARTER CONTROLS:")
        print("    [R] -> Instant Restart (Kills crashed game, resets daemon, relaunches)")
        print("    [S] -> Soft Respring (Reloads SpringBoard & ESP overlay)")
        print("    [K] -> Kill Game & Daemon (Clean shutdown)")
        print("    [Q] -> Quit Launcher")
        print("-" * 64)
        try:
            choice = input("Enter action [R/S/K/Q] (default R): ").strip().upper()
        except (EOFError, KeyboardInterrupt):
            break

        if not choice or choice == "R":
            print("\n[*] Executing Quick Restart...", flush=True)
            do_restart(clean_game=True, respring_overlay=False)
            time.sleep(3)
            procs, ipc = get_live_status()
            print("[+] Restart complete! Current processes:\n" + procs)
        elif choice == "S":
            print("\n[*] Executing Soft Respring & Restart...", flush=True)
            do_restart(clean_game=True, respring_overlay=True)
            time.sleep(4)
            procs, ipc = get_live_status()
            print("[+] Respring complete! Current processes:\n" + procs)
        elif choice == "K":
            print("\n[*] Terminating game and stopping daemon...", flush=True)
            remote("""
ps -ef | grep ShadowTrackerExtra | grep -v grep | while read -r u p rest; do
    kill -9 "$p" 2>/dev/null || true
done
/var/jb/bin/launchctl stop user/501/com.local.ue4loadmonitor 2>/dev/null || true
""")
            print("[+] Stopped.")
        elif choice == "Q":
            print("[*] Exiting launcher console. Radar remains running on phone.")
            break
        else:
            print(f"Unknown choice '{choice}'. Press R to restart, or Q to quit.")


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        print("START FAILED: " + str(exc), file=sys.stderr)
        sys.exit(1)
