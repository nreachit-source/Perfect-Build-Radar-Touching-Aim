"""Capture current device logs and radar counters, without screenshots/dumps."""
import json
from pathlib import Path
import subprocess
import sys
import struct
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT.parent
sys.path.insert(0, str(MONITOR))
from remote_sh import run_script

out = MONITOR / "build_codex/proof"
out.mkdir(parents=True, exist_ok=True)
logs = run_script("""ps -ef | grep -e SpringBoard -e ue4load -e ShadowTracker | grep -v grep
tail -n 12 /var/mobile/Downloads/ue4_radar.log
tail -n 12 /var/mobile/Downloads/ue4_overlay_v3_proof.log
cp /var/mobile/Downloads/ue4_radar.bin /var/mobile/Media/codex_radar_proof.bin
""", timeout=10)
(out / "device.log").write_text(logs, encoding="utf-8")
py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "pull",
                "/codex_radar_proof.bin", str(out / "radar.bin")], check=True)
b = (out / "radar.bin").read_bytes()
magic, version, tick, count = struct.unpack_from("<4I", b)
if magic != 0x52444152 or version != 3 or len(b) != 72+272*100 or count > 100:
    raise RuntimeError("Invalid snapshot format")
seq, status = struct.unpack_from("<2I", b, 44)
if seq & 1:
    raise RuntimeError("Writer was publishing; recapture the snapshot")
report = dict(captured_utc=datetime.now(timezone.utc).isoformat(),
    tick=tick, status=status, player_count=count,
    local_position=struct.unpack_from("<3f", b, 16),
    camera_position=struct.unpack_from("<3f", b, 52),
    camera_valid=struct.unpack_from("<I", b, 64)[0],
    players=[dict(position=struct.unpack_from("<3f", b, 72+i*272),
                  health=struct.unpack_from("<f", b, 84+i*272)[0]) for i in range(count)],
    limitation="A copied snapshot is diagnostic evidence, not a gameplay accuracy test.")
(out / "snapshot.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
print(logs)
print(json.dumps(report, indent=2))
