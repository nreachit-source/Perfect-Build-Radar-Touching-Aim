import json
import subprocess

res = subprocess.check_output(['python', 'tools/remote_sh.py', 'cat /var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-145802.ips'], encoding='utf-8', errors='ignore')
lines = res.split('\n')
body = '\n'.join(lines[1:])
start = body.find('{')
end = body.rfind('}')
data = json.loads(body[start:end+1])
print('Termination:', data.get('termination'))
print('Exception:', data.get('exception'))
print('Faulting thread:', data.get('faultingThread'))
for i, th in enumerate(data.get('threads', [])):
    if th.get('triggered', False) or i == data.get('faultingThread'):
        print(f"Triggered thread: {i} ({th.get('name', 'unnamed')})")
        for j, f in enumerate(th.get('frames', [])[:25]):
            print(f"  #{j}: {f.get('symbol', '?')} in {f.get('imageName', '?')} offset {hex(f.get('imageOffset', 0))}")
