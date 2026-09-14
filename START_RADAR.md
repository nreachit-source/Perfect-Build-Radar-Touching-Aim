# UE4 radar — release 1.3.3

This release packages the signed daemon and overlay whose compiled sections match the tested Windows build. The full-screen drawing window opts out of window-server hit testing; separate floating-button and menu windows remain interactive.

## Use directly on the iPhone

1. Activate Dopamine after any full reboot. The rootless `/var/jb` environment must be present.
2. Install **UE4 Load Monitor 1.3.3** in Sileo from `https://raw.githubusercontent.com/nreachit-source/ios-working-radar/main/` and use Sileo's restart-SpringBoard action after an overlay update.
3. Open PUBG. The daemon starts automatically through launchd, and ElleKit loads the floating ESP menu in SpringBoard. Tap **ESP**, activate the features you want, and tap **Collapse**. USB and a laptop are not needed for normal use.

If the floating button is absent, check that Dopamine is active and tweaks are enabled. A full reboot requires reactivating the jailbreak on the phone; this package does not bypass that requirement. A normal launch does not dump game memory or regenerate a schema.

## Windows launcher

`Start Radar.bat` runs `tools/start_radar.py`. On the development PC, a copy is on the desktop. It creates the USB forward when needed, checks local and installed SHA-256 hashes against `artifacts/build.json`, verifies an advancing overlay heartbeat, starts the service, and opens PUBG. It refuses a build mismatch instead of silently downgrading the phone. Set `RADAR_PYTHON` when using a different Python toolchain path.

## Build and package

- Source: `source/daemon/` and `source/overlay/`.
- `python tools/build_local.py --zig <zig.exe> --out <output-directory>` cross-compiles and checks the iOS ARM64 platform.
- `artifacts/` holds the exact signed release binaries and their manifest. Signing changes whole-file hashes; compare signed artifacts to the installation.
- `python tools/package_release.py` packages these signed artifacts and regenerates `Packages`, `Packages.gz`, and `Release`. It does not rebuild or resign them.
- Package: `debs/com.local.ue4loadmonitor_1.3.3_iphoneos-arm64.deb`.

The installer registers signed code hashes, starts the launchd service, and lets Sileo request a respring. It does not clear trustcache, repeatedly inject a loaded dylib, or rely on temporary signing entitlements from the user's Media folder.

## Verification limits

Observed on the phone before packaging: `SERVER_TOUCH ignores=1 server_hit_testing=0`; menu close, collapse, and button checks passed; live radar ticks advanced. The signed artifacts' Mach-O sections matched the local builds. Internal checks do not establish physical gameplay touch success. Final 1.3.3 package installation is pending restoration of Dopamine because `/var/jb` disappeared during the installation attempt.

Gemini/Antigravity implementation guidance is in `.agents/skills/focused-radar-implementation/SKILL.md`.
