import json
import subprocess
import glob
import re

out = subprocess.check_output(['python', 'tools/remote_sh.py', 'ls -1t /var/mobile/Library/Logs/CrashReporter/SpringBoard-*.ips | head -n 6'], encoding='utf-8', errors='ignore')
files = [line.strip() for line in out.splitlines() if line.strip().endswith('.ips')]
print(f"Found {len(files)} recent SpringBoard crash files: {files}")

for filepath in files[:4]:
    print(f"\n=======================================================")
    print(f"ANALYZING: {filepath}")
    print(f"=======================================================")
    full_res = subprocess.check_output(['python', 'tools/remote_sh.py', f'cat {filepath}'], encoding='utf-8', errors='ignore')
    lines = full_res.split('\n')
    body = '\n'.join(lines[1:])
    start = body.find('{')
    end = body.rfind('}')
    if start != -1 and end != -1:
        try:
            data = json.loads(body[start:end+1])
            print('Termination:', json.dumps(data.get('termination'), indent=2))
            print('Exception:', json.dumps(data.get('exception'), indent=2))
            print('Faulting thread:', data.get('faultingThread'))
            images = data.get('usedImages', [])
            
            ft = data.get('faultingThread')
            threads = data.get('threads', [])
            if ft is not None and ft < len(threads):
                th = threads[ft]
                print(f"\nTriggered Thread {ft} ({th.get('name', 'unnamed')}):")
                for j, f in enumerate(th.get('frames', [])[:30]):
                    sym = f.get('symbol', '')
                    img_idx = f.get('imageIndex')
                    img_name = images[img_idx].get('name', '?') if (img_idx is not None and img_idx < len(images)) else '?'
                    offset = hex(f.get('imageOffset', 0))
                    print(f"  #{j:02d}: {img_name} {sym} (+{offset})")
            
            for i, th in enumerate(threads):
                if i == ft: continue
                frames = th.get('frames', [])
                for f in frames:
                    img_idx = f.get('imageIndex')
                    img_name = images[img_idx].get('name', '') if (img_idx is not None and img_idx < len(images)) else ''
                    sym = f.get('symbol', '')
                    if 'radar' in img_name.lower() or 'radar' in sym.lower() or 'overlay' in img_name.lower():
                        print(f"Thread {i} mentions {img_name} / {sym}")
                        break
        except Exception as e:
            print('JSON parse error:', e)
    else:
        print("Could not find JSON payload")
