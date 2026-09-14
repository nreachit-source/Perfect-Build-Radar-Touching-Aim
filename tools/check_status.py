import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))
from remote_sh import run_script

print("=== Running Processes ===")
print(run_script("ps -ef | grep -E 'Shadow|ue4|SpringBoard'"))

print("=== Daemon Log (Last 10 lines) ===")
print(run_script("tail -n 10 /var/mobile/Downloads/ue4_radar.log"))

print("=== Overlay Proof (Last 10 lines) ===")
print(run_script("tail -n 10 /var/mobile/Downloads/ue4_overlay_v3_proof.log"))
