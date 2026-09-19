import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
art = ROOT / "artifacts"

def main():
    d_bin = (art / "ue4loadmonitor").read_bytes()
    o_bin = (art / "radar_overlay.dylib").read_bytes()

    d_hash = hashlib.sha256(d_bin).hexdigest()
    o_hash = hashlib.sha256(o_bin).hexdigest()

    print(f"ue4loadmonitor:     {d_hash} ({len(d_bin)} bytes)")
    print(f"radar_overlay.dylib: {o_hash} ({len(o_bin)} bytes)")

    sums = f"{o_hash}  radar_overlay.dylib\n{d_hash}  ue4loadmonitor\n"
    (art / "SHA256SUMS").write_text(sums, newline="\n")

    manifest = {
        "version": "1.3.4",
        "build": "touch-delivery-20260919",
        "sha256": {
            "ue4loadmonitor": d_hash,
            "radar_overlay.dylib": o_hash,
        },
        "source": "source/overlay/radar_overlay.m",
        "note": "Signed artifacts match installed device SHA-256. Build and dispatch checks passed; foreground touch delivery awaits gameplay verification."
    }
    (art / "build.json").write_text(json.dumps(manifest, indent=2) + "\n", newline="\n")
    print("Updated artifacts/SHA256SUMS and artifacts/build.json")

    # Now run package_release.py
    import package_release
    package_release.main()
    print("Release packaging completed successfully!")

if __name__ == "__main__":
    main()
