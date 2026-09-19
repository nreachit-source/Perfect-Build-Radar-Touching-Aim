import json
import subprocess
import glob

cmd = "ls -1t /var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-09-14-*.ips"
out = subprocess.check_output(['python', 'tools/remote_sh.py', cmd], encoding='utf-8', errors='ignore')
files = [line.strip() for line in out.splitlines() if line.strip().endswith('.ips')]
print(f"Found {len(files)} crash files from today:")

for f in files:
    full_res = subprocess.check_output(['python', 'tools/remote_sh.py', f'cat {f}'], encoding='utf-8', errors='ignore')
    lines = full_res.split('\n')
    body = '\n'.join(lines[1:])
    start = body.find('{')
    end = body.rfind('}')
    if start == -1 or end == -1:
        print(f"{f}: NO JSON")
        continue
    try:
        d = json.loads(body[start:end+1])
        term = d.get('termination', {})
        exc = d.get('exception', {})
        ft = d.get('faultingThread')
        leb = d.get('lastExceptionBacktrace')
        asi = d.get('asi')
        images = d.get('usedImages', [])
        
        print(f"\n=======================================================")
        print(f"--- {f} ---")
        print(f"  Termination: {term}")
        print(f"  Exception: {exc}")
        print(f"  Faulting thread: {ft}")
        print(f"  ASI: {asi}")
        if leb:
            print(f"  LastExceptionBacktrace len: {len(leb)}")
            for item in leb[:10]:
                if isinstance(item, dict):
                    idx = item.get('imageIndex')
                    name = images[idx].get('name', '?') if (idx is not None and idx < len(images)) else '?'
                    print(f"    {name} {item.get('symbol')} (+{hex(item.get('imageOffset', 0))})")
        
        threads = d.get('threads', [])
        if ft is not None and ft < len(threads):
            th = threads[ft]
            print(f"  Faulting Thread {ft} ({th.get('name')}) frames:")
            for j, fr in enumerate(th.get('frames', [])[:10]):
                idx = fr.get('imageIndex')
                name = images[idx].get('name', '?') if (idx is not None and idx < len(images)) else '?'
                print(f"    #{j}: {name} {fr.get('symbol')} (+{hex(fr.get('imageOffset', 0))})")
        
        # Also check if any thread mentions radar or overlay
        for i, th in enumerate(threads):
            if i == ft: continue
            for fr in th.get('frames', []):
                idx = fr.get('imageIndex')
                name = images[idx].get('name', '') if (idx is not None and idx < len(images)) else ''
                sym = fr.get('symbol', '')
                if 'radar' in name.lower() or 'radar' in sym.lower() or 'init_overlay' in sym.lower():
                    print(f"  Thread {i} mentions {name} / {sym}")
                    for k, f_th in enumerate(th.get('frames', [])[:8]):
                        idx_k = f_th.get('imageIndex')
                        name_k = images[idx_k].get('name', '?') if (idx_k is not None and idx_k < len(images)) else '?'
                        print(f"    [T{i} #{k}] {name_k} {f_th.get('symbol')} (+{hex(f_th.get('imageOffset', 0))})")
                    break
    except Exception as e:
        print(f"{f}: Error {e}")
