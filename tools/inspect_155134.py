import json
import subprocess

full_res = subprocess.check_output(['python', 'tools/remote_sh.py', 'cat /var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-155134.ips'], encoding='utf-8', errors='ignore')
lines = full_res.split('\n')
body = '\n'.join(lines[1:])
start = body.find('{')
end = body.rfind('}')
data = json.loads(body[start:end+1])
images = data.get('usedImages', [])
print('Faulting thread:', data.get('faultingThread'))
print('Exception:', data.get('exception'))
print('Termination:', data.get('termination'))
print('asi:', data.get('asi'))
print('lastExceptionBacktrace:', data.get('lastExceptionBacktrace'))

print(f"\n--- Thread 12 Raw Frames ---")
for j, f in enumerate(data['threads'][12]['frames']):
    print(f"  #{j:02d}: {f}")



