import subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_local import patch_ios
from remote_sh import run_script

ZIG = r"C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\zig\zig.exe"
PY3 = r"C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\.venv\Scripts\python.exe"

src = sys.argv[1] if len(sys.argv) > 1 else "tools/probe_symbols.c"
src_path = Path(src)
out_raw = Path("tools") / (src_path.stem + ".raw")

subprocess.run([ZIG, "cc", "-target", "aarch64-macos", "-O2", "-Wl,-undefined,dynamic_lookup", str(src_path), "-o", str(out_raw)], check=True)
patch_ios(out_raw)
remote_name = src_path.stem
subprocess.run([PY3, "-m", "pymobiledevice3", "afc", "push", str(out_raw), "/" + remote_name], check=True)
cmd = f"cp /var/mobile/Media/{remote_name} /var/jb/tmp/{remote_name}; chmod 755 /var/jb/tmp/{remote_name}; ldid -S /var/jb/tmp/{remote_name}; DHASH=$(ldid -h /var/jb/tmp/{remote_name} | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2); /var/jb/basebin/jbctl trustcache add $DHASH; /var/jb/tmp/{remote_name}"
print(run_script(cmd))

