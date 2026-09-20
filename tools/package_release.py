"""Package the exact signed artifacts, then regenerate this flat Sileo index."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]

def tar_bytes(files):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w", format=tarfile.GNU_FORMAT) as tf:
        directories = set()
        for name in files:
            parent = Path(name).parent
            while str(parent) != ".":
                directories.add(parent.as_posix())
                parent = parent.parent
        for name in sorted(directories):
            ti = tarfile.TarInfo("./" + name)
            ti.type, ti.mode, ti.uid, ti.gid, ti.mtime = tarfile.DIRTYPE, 0o755, 0, 0, 0
            ti.uname, ti.gname = "root", "wheel"
            tf.addfile(ti)
        for name, (data, mode) in sorted(files.items()):
            ti = tarfile.TarInfo("./" + name)
            ti.size, ti.mode, ti.uid, ti.gid, ti.mtime = len(data), mode, 0, 0, 0
            ti.uname, ti.gname = "root", "wheel"
            tf.addfile(ti, io.BytesIO(data))
    return gzip.compress(out.getvalue(), mtime=0)

def main():
    manifest = json.loads((ROOT / "artifacts/build.json").read_text())
    version = manifest["version"]
    data = {}
    for name, target in {
        "ue4loadmonitor": "var/jb/usr/local/libexec/ue4loadmonitor",
        "radar_overlay.dylib": "var/jb/usr/lib/TweakInject/radar_overlay.dylib",
        "RadarManager": "var/jb/Applications/RadarManager.app/RadarManager",
    }.items():
        app_source = ROOT / "artifacts" / name
        if not app_source.is_file():
            app_source = ROOT.parent / "build_codex" / name
        blob = app_source.read_bytes()
        assert hashlib.sha256(blob).hexdigest() == manifest["sha256"][name]
        data[target] = (blob, 0o755)
    for source, target in {
        "source/daemon/com.local.ue4loadmonitor.plist": "var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist",
        "source/overlay/radar_overlay.plist": "var/jb/usr/lib/TweakInject/radar_overlay.plist",
        "source/app/Info.plist": "var/jb/Applications/RadarManager.app/Info.plist",
        "source/app/entitlements.plist": "var/jb/Applications/RadarManager.app/entitlements.plist",
        "artifacts/build.json": "var/jb/usr/local/share/ue4loadmonitor/build.json",
    }.items():
        data[target] = ((ROOT / source).read_bytes(), 0o644)
    control = f"""Package: com.local.ue4loadmonitor
Name: UE4 Load Monitor
Version: {version}
Architecture: iphoneos-arm64
Description: Live radar with display touch passthrough, on-phone ESP controls, and on-device Radar Manager app.
Maintainer: Local Development
Section: Development
Depends: firmware (>= 13.0)
"""
    postinst = b"""#!/var/jb/bin/sh
set -e
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/basebin:/usr/bin:/bin:/usr/sbin:/sbin
# Release artifacts are already signed. Preserve their exact hashes.
for file in /var/jb/usr/local/libexec/ue4loadmonitor /var/jb/usr/lib/TweakInject/radar_overlay.dylib /var/jb/Applications/RadarManager.app/RadarManager; do
 if [ -f "$file" ]; then
  hash=$(ldid -h "$file" | sed -n 's/^CDHash=//p')
  if [ -n "$hash" ]; then
   /var/jb/basebin/jbctl trustcache add "$hash" 2>/dev/null || true
  fi
 fi
done
if [ -x /var/jb/usr/bin/uicache ]; then
 /var/jb/usr/bin/uicache -p /var/jb/Applications/RadarManager.app 2>/dev/null || true
fi
plist=/var/jb/Library/LaunchDaemons/com.local.ue4loadmonitor.plist
if ! launchctl print system/com.local.ue4loadmonitor >/dev/null 2>&1; then
 launchctl bootstrap system "$plist"
fi
launchctl kickstart -k system/com.local.ue4loadmonitor
# ElleKit loads the overlay automatically at SpringBoard launch.
# Let Sileo request one respring; never inject another copy into the live process.
if [ -n "${CYDIA:-}" ]; then
 cydo_fd=${CYDIA%% *}
 case "$cydo_fd" in ''|*[!0-9]*) ;; *) printf 'finish:restart-springboard\n' >"/dev/fd/$cydo_fd" || true ;; esac
fi
exit 0
"""
    prerm = b"""#!/var/jb/bin/sh
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
case "$1" in remove|deconfigure)
 launchctl bootout system/com.local.ue4loadmonitor 2>/dev/null || true
 if [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -u /var/jb/Applications/RadarManager.app 2>/dev/null || true
 fi
;; esac
exit 0
"""
    members = {"debian-binary": b"2.0\n", "control.tar.gz": tar_bytes({"control": (control.encode(), 0o644), "postinst": (postinst, 0o755), "prerm": (prerm, 0o755)}), "data.tar.gz": tar_bytes(data)}
    out = bytearray(b"!<arch>\n")
    for name, blob in members.items():
        out += ((name + "/").ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6) + "100644".ljust(8) + str(len(blob)).ljust(10) + "`\n").encode()
        out += blob
        if len(blob) % 2: out += b"\n"
    deb = ROOT / "debs" / f"com.local.ue4loadmonitor_{version}_iphoneos-arm64.deb"
    deb.parent.mkdir(exist_ok=True)
    deb.write_bytes(out)
    package = control + f"Filename: debs/{deb.name}\nSize: {len(out)}\n" + "".join(f"{field}: {hashlib.new(alg,out).hexdigest()}\n" for field, alg in [("MD5sum","md5"),("SHA1","sha1"),("SHA256","sha256")]) + "\n"
    (ROOT / "Packages").write_text(package, newline="\n")
    (ROOT / "Packages.gz").write_bytes(gzip.compress(package.encode(),mtime=0))
    release = "Origin: UE4 Load Monitor\nLabel: UE4 Load Monitor\nSuite: stable\nCodename: ios\nArchitectures: iphoneos-arm64\nComponents: main\nDescription: UE4 radar release repository\n"
    for field, alg in [("MD5Sum","md5"),("SHA1","sha1"),("SHA256","sha256")]:
        release += field + ":\n"
        for name in ["Packages","Packages.gz"]:
            blob = (ROOT/name).read_bytes()
            release += f" {hashlib.new(alg,blob).hexdigest()} {len(blob):16d} {name}\n"
    (ROOT / "Release").write_text(release, newline="\n")
    print(deb)
    print("PASS: signed payload hashes and package index generated")

if __name__ == "__main__": main()
