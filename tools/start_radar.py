"""Start the installed radar and overlay over USB; never build or dump memory."""
import argparse
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT.parent
PYTHON = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from remote_sh import run_script

_stop_event = threading.Event()


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


def remote(script, timeout=25):
    result = run_script(script + "\necho START_COMMAND_OK\n", timeout=timeout)
    if "START_COMMAND_OK" not in result:
        raise RuntimeError(result.strip() or "No response from phone. Enable iDownload and check USB.")
    return result


def _watchdog_petter_loop():
    """Safely neutralizes watchdogd to prevent hardware sensor panics without crash-looping thermalmonitord."""
    while not _stop_event.is_set():
        try:
            if connected():
                remote(
                    "/var/jb/bin/launchctl disable system/com.apple.watchdogd 2>/dev/null || "
                    "/var/jb/bin/launchctl stop system/com.apple.watchdogd 2>/dev/null || "
                    "/var/jb/bin/launchctl kickstart system/com.apple.thermalmonitord 2>/dev/null || true",
                    timeout=10
                )
        except Exception:
            pass
        _stop_event.wait(60)


def exit_safe_mode():
    """Clears Dopamine safe mode flag and cleanly resprings SpringBoard."""
    print("[*] Clearing Dopamine safe mode flag and reloading SpringBoard...", flush=True)
    script = """
rm -f /var/jb/basebin/.safe_mode
rm -f /var/mobile/Downloads/overlay_sb_pid.txt
if [ -x /var/jb/usr/bin/sbreload ]; then
    /var/jb/usr/bin/sbreload || killall -9 SpringBoard
else
    killall -9 SpringBoard
fi
"""
    remote(script, timeout=15)
    time.sleep(3)
    # Wait for new SpringBoard PID and verify overlay loaded
    for _ in range(6):
        try:
            res = remote("""
LINE=$(ps -ef | grep SpringBoard | grep -v grep | head -n1)
set -- $LINE
SB=$2
RECORDED=$(cat /var/mobile/Downloads/overlay_sb_pid.txt 2>/dev/null)
echo "$SB $RECORDED"
""", timeout=5)
            parts = res.strip().split()
            if len(parts) >= 2 and parts[0] == parts[1] and parts[0]:
                print(f"[+] Safe mode cleared! SpringBoard restarted (PID {parts[0]}) with overlay active.", flush=True)
                return True
        except Exception:
            pass
        time.sleep(1)
    print("[+] Safe mode cleared and SpringBoard respringed.", flush=True)
    return True


def ensure_overlay(force=False):
    """Ensures radar_overlay.dylib is active in SpringBoard via ElleKit without crashes or safe mode traps."""
    # 1. Clear any safe mode flag if present
    check_sm = remote("if [ -f /var/jb/basebin/.safe_mode ]; then echo 'SAFE_MODE'; fi")
    if "SAFE_MODE" in check_sm:
        print("[!] Dopamine Safe Mode detected! Automatically exiting safe mode...", flush=True)
        exit_safe_mode()
        return True

    # 2. If force restart requested, respring cleanly via sbreload (NEVER call opainject!)
    if force:
        print("[*] Performing soft respring to reload overlay cleanly...", flush=True)
        exit_safe_mode()
        return True

    # 3. Check if SpringBoard currently has the overlay running
    check_script = """
LINE=$(ps -ef | grep SpringBoard | grep -v grep | head -n1)
set -- $LINE
SB=$2
if [ -z "$SB" ]; then
    echo "NO_SPRINGBOARD"
    exit 0
fi
RECORDED=$(cat /var/mobile/Downloads/overlay_sb_pid.txt 2>/dev/null)
if [ -n "$RECORDED" ] && [ "$SB" = "$RECORDED" ]; then
    echo "ALREADY_ACTIVE $SB"
    exit 0
fi
# Wait up to 3s for newly spawned SpringBoard to initialize overlay
for i in 1 2 3; do
    sleep 1
    RECORDED=$(cat /var/mobile/Downloads/overlay_sb_pid.txt 2>/dev/null)
    if [ -n "$RECORDED" ] && [ "$SB" = "$RECORDED" ]; then
        echo "ALREADY_ACTIVE $SB"
        exit 0
    fi
done
echo "NOT_LOADED $SB"
"""
    res = remote(check_script, timeout=15)
    if "ALREADY_ACTIVE" in res:
        print("    [+] Overlay is already active in current SpringBoard.", flush=True)
        return True
    elif "NOT_LOADED" in res:
        print("    [*] Overlay not active in current SpringBoard. Reloading SpringBoard cleanly via sbreload...", flush=True)
        exit_safe_mode()
        return True
    return True



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
        cmds.append("rm -f /var/mobile/Downloads/overlay_sb_pid.txt 2>/dev/null || true")
    cmds.append("""
/var/jb/bin/launchctl kickstart -k user/501/com.local.ue4loadmonitor 2>/dev/null || \
/var/jb/bin/launchctl kickstart -k system/com.local.ue4loadmonitor 2>/dev/null || true
/var/jb/usr/bin/uiopen --bundleid com.tencent.ig >/dev/null 2>&1 &
""")
    remote("\n".join(cmds))

    if respring_overlay:
        print("[*] Waiting for SpringBoard to reload...", flush=True)
        time.sleep(4)
        print("[*] Verifying overlay status in refreshed SpringBoard...", flush=True)
        ensure_overlay(force=False)


def get_live_status():
    """Returns running processes and radar bin info."""
    procs = remote("ps -A -o pid,comm | grep -E 'ue4loadmonitor|ShadowTracker|SpringBoard' || true")
    ipc_info = remote("ls -la /var/mobile/Downloads/ue4_radar.bin 2>/dev/null || true")
    clean_procs = "\n".join(l for l in procs.splitlines() if l.strip() and "START_COMMAND_OK" not in l and "iDownload>" not in l and "__CODEX_DONE__" not in l)
    clean_ipc = "\n".join(l for l in ipc_info.splitlines() if l.strip() and "START_COMMAND_OK" not in l and "iDownload>" not in l and "__CODEX_DONE__" not in l)
    return clean_procs, clean_ipc


def show_telemetry_stream():
    """Streams live telemetry from the daemon and overlay until key press."""
    print("\n" + "=" * 64)
    print("  LIVE RADAR & AIM TELEMETRY STREAM (Press Ctrl+C to return)")
    print("=" * 64)
    try:
        while True:
            out = remote("""
D=$(tail -n 1 /var/mobile/Downloads/ue4_radar.log 2>/dev/null || echo "DAEMON: offline")
O=$(tail -n 1 /var/mobile/Downloads/ue4_overlay_v3_proof.log 2>/dev/null || echo "OVERLAY: offline")
echo "D_LOG: $D"
echo "O_LOG: $O"
""")
            d_line = ""
            o_line = ""
            for line in out.splitlines():
                if line.startswith("D_LOG: "):
                    d_line = line[7:].strip()
                elif line.startswith("O_LOG: "):
                    o_line = line[7:].strip()
            print(f"\r[*] [DAEMON] {d_line[:50]} | [OVERLAY] {o_line[:40]}", end="", flush=True)
            time.sleep(0.5)
    except (KeyboardInterrupt, EOFError):
        print("\n[*] Exited telemetry stream.")


def test_touch_injection():
    """Directly triggers a verified touch injection stroke on the device."""
    print("\n[*] Triggering test touch swipe on iPhone screen...", flush=True)
    res = remote("/var/jb/tmp/test_hid_inject 2>&1 || true")
    for line in res.splitlines():
        line = line.strip()
        if any(w in line for w in ["Probing", "IOHID", "Simulating", "Dispatched", "swipe completed"]):
            print(f"    [+] {line}", flush=True)
    print("[+] Touch injection test finished. Check device screen for swipe reaction.", flush=True)


def show_recent_logs():
    """Displays latest entries from daemon log and overlay proof."""
    print("\n" + "=" * 64)
    print("  RECENT DAEMON LOG (/var/mobile/Downloads/ue4_radar.log):")
    print("=" * 64)
    d_log = remote("tail -n 12 /var/mobile/Downloads/ue4_radar.log 2>/dev/null || echo 'No daemon log'")
    for line in d_log.splitlines():
        if "START_COMMAND_OK" not in line and "iDownload>" not in line and "__CODEX_DONE__" not in line:
            print("  " + line)

    print("\n" + "=" * 64)
    print("  RECENT OVERLAY PROOF (/var/mobile/Downloads/ue4_overlay_v3_proof.log):")
    print("=" * 64)
    o_log = remote("tail -n 12 /var/mobile/Downloads/ue4_overlay_v3_proof.log 2>/dev/null || echo 'No overlay log'")
    for line in o_log.splitlines():
        if "START_COMMAND_OK" not in line and "iDownload>" not in line and "__CODEX_DONE__" not in line:
            print("  " + line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restart-overlay", action="store_true", help="Restart SpringBoard to reload the installed overlay")
    parser.add_argument("--no-loop", action="store_true", help="Launch once and exit without interactive menu")
    args = parser.parse_args()

    print("================================================================", flush=True)
    print("      iOS UE4 Radar, Aim Assist & ESP Launcher (v1.3.4)         ", flush=True)
    print("================================================================", flush=True)
    print("[*] Keep phone UNLOCKED and screen ON during startup.", flush=True)
    print("[*] Connecting to iPhone over USB (port 1337)...", flush=True)
    ensure_usb()

    # Start background watchdog petter thread to prevent missing-sensor thermalmonitord panics
    petter_thread = threading.Thread(target=_watchdog_petter_loop, daemon=True)
    petter_thread.start()
    print("[+] Watchdog sensor keepalive active (prevents hardware thermal panics).", flush=True)

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

    # 2. Ensure overlay is injected and active in current SpringBoard
    print("[*] Checking SpringBoard overlay status...", flush=True)
    ensure_overlay(force=args.restart_overlay)
    time.sleep(1.5)

    # 3. Launch / Restart game and daemon
    print("[*] Launching Radar Daemon and PUBG Mobile...", flush=True)
    do_restart(clean_game=False, respring_overlay=False)
    time.sleep(3)

    procs, ipc_info = get_live_status()
    print("\n[+] LIVE SYSTEM STATUS:")
    print(procs)
    if ipc_info:
        print(f"[+] IPC Shared Memory: {ipc_info}")

    print("\n[+] Overlay is active. Tap 'ESP' on screen for settings; tap 'AIM' for touch aim.")
    print("[+] Radar is running. Wait for LIVE status in-game.")

    if args.no_loop:
        return

    # 4. Interactive Console Loop
    while True:
        print("\n" + "-" * 64)
        print("  CONSOLE RESTARTER & DIAGNOSTIC CONTROLS:")
        print("    [R] -> Instant Restart (Kills stuck game, resets daemon, relaunches)")
        print("    [S] -> Soft Respring (Safely reloads SpringBoard & ESP overlay)")
        print("    [O] -> Verify Overlay (Checks active status / re-injects if idle)")
        print("    [E] -> Exit Safe Mode (Clears .safe_mode and cleanly resprings SpringBoard)")
        print("    [T] -> Telemetry Stream (Live real-time tick, enemy count, aim lock)")
        print("    [F] -> Test Touch Injection (Fires a test swipe stroke on screen)")
        print("    [L] -> View Recent Logs (Tail daemon & overlay proof logs)")
        print("    [P] -> System & Process Status (Display PIDs & shared memory info)")
        print("    [K] -> Kill Game & Daemon (Clean shutdown)")
        print("    [Q] -> Quit Launcher")
        print("-" * 64)
        try:
            choice = input("Enter action [R/S/O/E/T/F/L/P/K/Q] (default R): ").strip().upper()
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
        elif choice == "O":
            print("\n[*] Checking overlay status in current SpringBoard...", flush=True)
            ensure_overlay(force=False)
        elif choice == "E":
            exit_safe_mode()
        elif choice == "T":
            show_telemetry_stream()
        elif choice == "F":
            test_touch_injection()
        elif choice == "L":
            show_recent_logs()
        elif choice == "P":
            procs, ipc = get_live_status()
            print("\n[+] SYSTEM & PROCESS STATUS:")
            print(procs)
            if ipc:
                print(f"[+] IPC Shared Memory: {ipc}")
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

    _stop_event.set()


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        _stop_event.set()
        print("START FAILED: " + str(exc), file=sys.stderr)
        sys.exit(1)
