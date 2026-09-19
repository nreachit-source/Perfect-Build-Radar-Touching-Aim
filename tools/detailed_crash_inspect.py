import json
import subprocess

files = [
    '/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-155134.ips',
    '/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-154839.ips',
    '/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-145802.ips',
    '/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-031605.ips',
    '/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-003843.ips'
]

for filepath in files:
    print(f"\n=======================================================")
    print(f"FILE: {filepath}")
    print(f"=======================================================")
    full_res = subprocess.check_output(['python', 'tools/remote_sh.py', f'cat {filepath}'], encoding='utf-8', errors='ignore')
    lines = full_res.split('\n')
    body = '\n'.join(lines[1:])
    start = body.find('{')
    end = body.rfind('}')
    if start == -1 or end == -1:
        print("No JSON found")
        continue
    data = json.loads(body[start:end+1])
    images = data.get('usedImages', [])
    print("Termination:", data.get("termination"))
    print("Exception:", data.get("exception"))
    print("Faulting thread:", data.get("faultingThread"))
    print("asi:", data.get("asi"))
    
    leb = data.get("lastExceptionBacktrace")
    if leb:
        print("\n--- Last Exception Backtrace ---")
        for item in leb:
            if isinstance(item, dict):
                idx = item.get('imageIndex')
                img_name = images[idx].get('name', '?') if (idx is not None and idx < len(images)) else '?'
                sym = item.get('symbol', '')
                off = hex(item.get('imageOffset', 0))
                print(f"  {img_name} {sym} (+{off})")
            else:
                print(f"  {item}")
                
    for i, th in enumerate(data.get('threads', [])):
        triggered = th.get('triggered', False) or (i == data.get('faultingThread'))
        frames = th.get('frames', [])
        has_overlay = any('radar' in (images[f.get('imageIndex', 0)].get('name', '') if f.get('imageIndex') is not None and f.get('imageIndex') < len(images) else '').lower() for f in frames)
        if triggered or has_overlay:
            print(f"\nThread {i} (triggered={triggered}, name={th.get('name')}):")
            for j, f in enumerate(frames[:20]):
                idx = f.get('imageIndex')
                img_name = images[idx].get('name', '?') if (idx is not None and idx < len(images)) else '?'
                sym = f.get('symbol', '')
                off = hex(f.get('imageOffset', 0))
                print(f"  #{j:02d}: {img_name} {sym} (+{off})")
