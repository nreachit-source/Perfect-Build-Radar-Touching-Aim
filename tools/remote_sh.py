import subprocess
import socket
import time
import sys
import os
import uuid

PY3 = os.environ.get("RADAR_PYTHON", r"C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\.venv\Scripts\python.exe")

def run_script(script_text, timeout=25):
    # Ensure LF newlines
    script_text = script_text.replace("\r\n", "\n")
    if not script_text.startswith("#!"):
        script_text = "#!/var/jb/bin/sh\nexport PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin\n" + script_text
    
    name = "codex_exec_" + uuid.uuid4().hex + ".sh"
    tmp_sh = os.path.join(os.path.dirname(__file__), name)
    with open(tmp_sh, "w", newline="\n") as f:
        f.write(script_text)
        
    res = subprocess.run([PY3, "-m", "pymobiledevice3", "afc", "push", tmp_sh, "/" + name],
                         capture_output=True, text=True, timeout=45)
    if res.returncode != 0:
        return f"AFC push failed: {res.stderr}"
    
    # Run via iDownload
    s = socket.create_connection(('127.0.0.1', 1337), timeout=timeout)
    time.sleep(0.2)
    try:
        s.recv(4096)
    except Exception:
        pass
    
    cmd = "/var/jb/bin/sh /var/mobile/Media/" + name + "\n"
    s.sendall(cmd.encode('utf-8'))
    time.sleep(0.5)
    s.sendall(b"exit\n")
    s.settimeout(timeout)
    out = b""
    while True:
        try:
            b = s.recv(4096)
            if not b:
                break
            out += b
        except Exception:
            break
    s.close()
    return out.decode('utf-8', errors='replace')

if __name__ == '__main__':
    if len(sys.argv) > 1:
        cmd = " ".join(sys.argv[1:])
        print(run_script(cmd))
    else:
        # Default test
        print(run_script("cat /var/jb/etc/apt/sources.list.d/*; dpkg -l com.local.ue4loadmonitor"))
