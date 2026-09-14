---
name: focused-radar-implementation
description: Implement and verify focused fixes in this iOS radar project, preserve working behavior, and keep source, phone installation, Sileo package, and Windows launcher on one verified build.
---

# Focused implementation

Start with the user's latest concrete failure and observable success condition. Inspect the current source and git diff before relying on old notes. Preserve existing uncommitted work. Fix the smallest relevant component; cross component boundaries only when the evidence requires it. Do not restart working radar/SDK investigations while fixing menu touches.

Use the available local scripts and USB connection. Batch independent reads; keep device mutations sequential. Build once after a coherent edit, run the check that can falsify the hypothesis, then install and verify the exact artifact when authorized. Do not stop after a plan when implementation was requested. If the same attempt fails, collect new evidence before retrying.

## Project facts to verify before changing them

- Active development: `C:/Users/GAME/Desktop/BUILD/iphone_ue4_monitor/sileo_repo`.
- Requested public repository: `https://github.com/nreachit-source/deamon-ue4-dumper`. The development checkout's `origin` may instead point to `stuck`; inspect it before publishing.
- `source/daemon/radar_data.h` is the IPC contract: currently version 4, 33768 bytes, sequence-protected mmap at `/var/mobile/Downloads/ue4_radar.bin`. Do not replace it with an old sample protocol.
- Radar reads existing offsets; normal startup does not dump schemas. Respect the user's no-dumps and no-screenshots instructions.
- Display window is separate from button/menu windows. Cross-process pass-through needs the display subclass `_ignoresHitTest=YES`, `_usesWindowServerHitTesting=NO` BEFORE window creation; UIKit `hitTest:nil` alone was insufficient. Do not apply those hooks to interactive control windows.
- Build: `python tools/build_local.py`; it verifies iOS ARM64 load commands. The source uses C runtime calls despite the `.m` extension.
- USB shell uses `tools/remote_sh.py` (or the older parent copy); iDownload is forwarded on localhost:1337. Do not print credentials or inspect unrelated account files.
- Stage and sign before atomic replacement. Register only the new code hashes; never clear the entire trustcache. Do not inject a second copy into SpringBoard: it previously crashed. Use one necessary soft reload after an overlay update; daemon-only updates do not need it.
- `artifacts/build.json` and `artifacts/SHA256SUMS` identify the release. Signing changes file hashes: compare signed artifacts with installed signed files, and verify Mach-O sections when comparing signed with unsigned builds.

## Completion evidence

Separate compilation, installation, heartbeat/IPC, and real touch/gameplay verification. Logs showing a hit-test method returned nil do not prove physical touches reached the game. Zero players in a lobby is not a failure or proof of detection. Use current time/build and advancing ticks, not old log lines. Never claim 100% from a single heartbeat.

For publishing, include matching source, signed artifacts, reproducible package tooling, updated package index, and a build manifest. Check the phone and desktop launcher against that manifest. Preserve automatic launchd/ElleKit startup: after jailbreaking, the phone can open the ESP menu without USB. Windows startup should start the installed build and flag mismatches, not silently install an older binary.

End with what changed, what passed, and any remaining user-dependent check. Give brief meaningful progress updates during longer work. Ask only for missing information that actually blocks the next authorized step.
