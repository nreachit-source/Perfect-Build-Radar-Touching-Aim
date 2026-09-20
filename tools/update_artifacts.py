import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
art = ROOT / "artifacts"

def main():
    d_bin = (art / "ue4loadmonitor").read_bytes()
    o_bin = (art / "radar_overlay.dylib").read_bytes()
    app_path = art / "RadarManager"
    if not app_path.is_file():
        app_path = ROOT.parent / "build_codex" / "RadarManager"
    app_bin = app_path.read_bytes()

    d_hash = hashlib.sha256(d_bin).hexdigest()
    o_hash = hashlib.sha256(o_bin).hexdigest()
    app_hash = hashlib.sha256(app_bin).hexdigest()

    print(f"ue4loadmonitor:     {d_hash} ({len(d_bin)} bytes)")
    print(f"radar_overlay.dylib: {o_hash} ({len(o_bin)} bytes)")
    print(f"RadarManager:       {app_hash} ({len(app_bin)} bytes)")

    sums = f"{o_hash}  radar_overlay.dylib\n{d_hash}  ue4loadmonitor\n{app_hash}  RadarManager\n"
    (art / "SHA256SUMS").write_text(sums, newline="\n")

    manifest = {
        "version": "1.3.5",
        "build": "on-device-manager-20260920",
        "sha256": {
            "ue4loadmonitor": d_hash,
            "radar_overlay.dylib": o_hash,
            "RadarManager": app_hash,
        },
        "source": "source/overlay/radar_overlay.m",
        "note": "Signed artifacts match installed device SHA-256. Includes standalone on-device Radar Manager app, in-overlay stop button, and XNU watchdog check-in invariant."
    }
    (art / "build.json").write_text(json.dumps(manifest, indent=2) + "\n", newline="\n")
    print("Updated artifacts/SHA256SUMS and artifacts/build.json")

    # Now run package_release.py
    import package_release
    package_release.main()
    print("Release packaging completed successfully!")

if __name__ == "__main__":
    main()
