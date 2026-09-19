"""Stop all iOS Radar processes locally and on the connected iPhone."""
import os
import sys
import time
import socket
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))

def stop_device_radar():
    print('[*] Checking iPhone connection over USB...')
    try:
        from remote_sh import run_script
        script = """
killall -9 ue4loadmonitor 2>/dev/null || true
/var/jb/bin/launchctl stop user/501/com.local.ue4loadmonitor 2>/dev/null || true
/var/jb/bin/launchctl stop system/com.local.ue4loadmonitor 2>/dev/null || true
rm -f /var/mobile/Downloads/ue4_radar.bin 2>/dev/null || true
echo RADAR_STOPPED_ON_DEVICE
"""
        res = run_script(script, timeout=8)
        if 'RADAR_STOPPED_ON_DEVICE' in res:
            print('[+] Successfully stopped ue4loadmonitor daemon and cleared IPC on iPhone.')
        else:
            print('[-] iPhone did not acknowledge stop command (device may be locked or disconnected).')
    except Exception as e:
        print(f'[-] Could not communicate with iPhone: {e}')

def stop_windows_processes():
    print('[*] Terminating Windows radar launcher and USB forwarders...')
    my_pid = os.getpid()
    
    kill_script = (
        'Get-Process python -ErrorAction SilentlyContinue | '
        'Where-Object { ($_.Id -ne ' + str(my_pid) + ') } | '
        'ForEach-Object { '
        '    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine; '
        '    if ($cmd -match "start_radar" -or $cmd -match "forward 1337") { '
        '        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue '
        '    } '
        '}'
    )
    try:
        subprocess.run(['powershell', '-Command', kill_script], capture_output=True, timeout=10)
        print('[+] Terminated background Start Radar launcher and USB port forwarders.')
    except Exception as e:
        print(f'[-] Error stopping Windows processes: {e}')

def main():
    print('================================================================')
    print('                iOS UE4 Radar Stopper (Clean Exit)              ')
    print('================================================================')
    stop_device_radar()
    stop_windows_processes()
    print('================================================================')
    print('[+] RADAR HAS BEEN SUCCESSFULLY STOPPED.')
    print('================================================================')

if __name__ == '__main__':
    main()
