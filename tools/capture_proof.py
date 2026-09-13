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
tail -n 15 /var/mobile/Downloads/ue4_radar.log
tail -n 15 /var/mobile/Downloads/ue4_overlay_v3_proof.log
cp /var/mobile/Downloads/ue4_radar.bin /var/mobile/Media/codex_radar_proof.bin 2>/dev/null || true
""", timeout=15)
(out / "device.log").write_text(logs, encoding="utf-8")

py = MONITOR.parent / "iPhone_RE_Toolchain/.venv/Scripts/python.exe"
try:
    subprocess.run([str(py), "-m", "pymobiledevice3", "afc", "pull",
                    "/codex_radar_proof.bin", str(out / "radar.bin")], check=True, timeout=20)
    b = (out / "radar.bin").read_bytes()
    if len(b) >= 33768:
        magic, version, tick, pcount, vcount, icount = struct.unpack_from("<6I", b, 0)
        if magic == 0x52444152 and version == 4:
            seq, status = struct.unpack_from("<2I", b, 52)
            cam_valid = struct.unpack_from("<I", b, 72)[0]
            local_pos = struct.unpack_from("<3f", b, 24)
            cam_pos = struct.unpack_from("<3f", b, 60)

            players = []
            for i in range(min(pcount, 100)):
                off = 88 + i * 284
                pos = struct.unpack_from("<3f", b, off)
                hp, hp_max = struct.unpack_from("<2f", b, off + 12)
                team_id = struct.unpack_from("<I", b, off + 24)[0]
                is_bot = struct.unpack_from("<B", b, off + 28)[0]
                raw_name = b[off + 32 : off + 64].split(b"\x00")[0].decode("ascii", errors="replace")
                dist = struct.unpack_from("<f", b, off + 64)[0]
                players.append(dict(name=raw_name, is_bot=bool(is_bot), team_id=team_id,
                                    position=pos, health=hp, health_max=hp_max, distance_m=dist))

            vehicles = []
            for i in range(min(vcount, 30)):
                off = 28488 + i * 56
                pos = struct.unpack_from("<3f", b, off)
                dist, spd = struct.unpack_from("<2f", b, off + 12)
                raw_name = b[off + 24 : off + 56].split(b"\x00")[0].decode("ascii", errors="replace")
                vehicles.append(dict(name=raw_name, position=pos, distance_m=dist, speed_kmh=spd))

            items = []
            for i in range(min(icount, 60)):
                off = 30168 + i * 60
                pos = struct.unpack_from("<3f", b, off)
                dist = struct.unpack_from("<f", b, off + 12)[0]
                item_id, count, cat = struct.unpack_from("<2iB", b, off + 16)
                raw_name = b[off + 28 : off + 60].split(b"\x00")[0].decode("ascii", errors="replace")
                items.append(dict(name=raw_name, item_id=item_id, count=count, category=cat, distance_m=dist))

            report = dict(
                captured_utc=datetime.now(timezone.utc).isoformat(),
                protocol_version=version,
                tick=tick,
                status=status,
                camera_valid=cam_valid,
                player_count=pcount,
                vehicle_count=vcount,
                item_count=icount,
                local_position=local_pos,
                camera_position=cam_pos,
                players=players,
                vehicles=vehicles,
                items=items,
                limitation="Diagnostic proof captured from live shared memory."
            )
            (out / "snapshot.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
            print(json.dumps(report, indent=2))
except Exception as e:
    print(f"Snapshot parse note: {e}")

print(logs)
