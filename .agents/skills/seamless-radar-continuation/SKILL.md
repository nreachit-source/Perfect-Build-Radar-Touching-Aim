---
name: seamless-radar-continuation
description: >-
  Comprehensive continuation guide, live architecture handbook, and progress runbook for the iOS UE4 working radar and touch-transparent SpringBoard overlay project.
  Use this skill whenever continuing development, debugging overlay injection, modifying launcher scripts, building releases, or keeping GitHub and Desktop launcher in sync.
---

# Seamless Radar Continuation & Live Operations Guide

This skill is the single source of truth for continuing work on the iOS UE4 Radar & SpringBoard ESP Overlay. Any agent taking over this task must read this document to understand the exact current architecture, avoided traps, and live verification commands.

> **CRITICAL INSTRUCTION FOR AGENTS**:
> Whenever you make new progress, modify files, or fix bugs, **you MUST update this SKILL.md file** (and its repository copy) with your latest findings and progress so future sessions continue seamlessly without repeating past mistakes.

---

## 1. Project Overview & Environment Ground Truth

### Repositories & Paths
- **Active Codebase & Sileo Repo**: `C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor\sileo_repo`
- **GitHub Remote**: `https://github.com/nreachit-source/ios-working-radar.git` (branch `main`)
- **Published GitHub Release**: `v1.3.3` (with deb, daemon, dylib, SHA256SUMS, build.json)
- **Sileo Source URL**: `https://raw.githubusercontent.com/nreachit-source/ios-working-radar/main/`
- **Desktop Launcher**: `C:\Users\GAME\Desktop\Start Radar.bat` (delegates to `sileo_repo\Start Radar.bat`)
- **Zig Cross-Compiler**: `C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\zig\zig.exe`
- **Python Runtime**: `C:\Users\GAME\Desktop\BUILD\iPhone_RE_Toolchain\.venv\Scripts\python.exe`
- **Device Connection**: iDownload forwarded to TCP `127.0.0.1:1337` via `pymobiledevice3 usbmux forward 1337 1337`

### Target Device
- **Device**: iPhone X (A11 Bionic, ARM64)
- **OS**: iOS 16.7.16 (Build 20H392)
- **Jailbreak**: Dopamine rootless (`/var/jb` prefix)
- **Target App**: `ShadowTrackerExtra` (PUBG Mobile 4.6.0, Bundle ID `com.tencent.ig`)

---

## 2. Decoupled Architecture & IPC Contract

```
┌────────────────────────────────────────────────────────────────────────┐
│                        iPhone X (iOS 16.7.16)                          │
│                                                                        │
│   ┌───────────────────────────┐      ┌─────────────────────────────┐   │
│   │ ShadowTrackerExtra (Game) │      │  ue4loadmonitor (Daemon)    │   │
│   │ PID: ~2990                │◄─────┤  PID: ~3010 (launchd root)  │   │
│   └───────────────────────────┘ Mach └──────────────┬──────────────┘   │
│                                Task                 │                  │
│                                Port                 ▼ Writes at 10 Hz  │
│                                      ┌─────────────────────────────┐   │
│                                      │ Shared Memory IPC Mmap      │   │
│                                      │ /var/mobile/Downloads/      │   │
│                                      │   ue4_radar.bin (33,768 B)  │   │
│                                      └──────────────┬──────────────┘   │
│                                                     │                  │
│   ┌──────────────────────────────────────────────┐  │ Reads at 20 Hz   │
│   │ SpringBoard.app (PID: ~2769)                 │  │                  │
│   │   radar_overlay.dylib (Injected via opainject)◄─┘                  │
│   │   ├── CodexNoninteractiveDisplayWindow (ESP & Radar: 100% touches pass through)
│   │   ├── RadarWindow (Interactive 48x48 floating 'ESP' button)        │
│   │   └── RadarWindow (Interactive 272x256 12-feature settings card)   │
│   └──────────────────────────────────────────────┘                     │
└────────────────────────────────────────────────────────────────────────┘
```

### IPC Protocol Contract (v4)
- File: `/var/mobile/Downloads/ue4_radar.bin` (33,768 bytes, sequence-locked atomic mmap).
- Defined in: `source/daemon/radar_data.h`.
- **Never modify** this binary struct layout or change the sequence lock mechanism without updating both daemon and overlay simultaneously.

---

## 3. Critical Solved Problems & Rules to Obey

### Problem 1: Touchless ESP Pass-Through
- **Solution**: Subclass `UIWindow` as `CodexNoninteractiveDisplayWindow` with:
  - `_ignoresHitTest = YES`
  - `_usesWindowServerHitTesting = NO`
  - `userInteractionEnabled = NO`
- **Important**: This opt-out must be applied to the display window only. Interactive control elements (the 48x48 draggable `ESP` button and the 272x256 settings menu card) reside in separate dedicated bounded `UIWindow` instances.

### Problem 2: iOS 16 `opainject` Failure (`Bus error: 10`)
- **Rule**: On iOS 16 (Dopamine), `opainject` fails or crashes target processes unless `jbctl proc_set_debugged` is called first.
- **Exact Working Injection Command**:
  ```sh
  LINE=$(ps -ef | grep SpringBoard | grep -v grep | head -n1)
  set -- $LINE
  SB=$2
  /var/jb/basebin/jbctl proc_set_debugged "$SB"
  /var/jb/basebin/opainject "$SB" /var/jb/usr/lib/TweakInject/radar_overlay.dylib
  ```

### Problem 3: SpringBoard PID Reset & Stale Heartbeat Trap
- **Trap**: Do NOT check `/var/mobile/Downloads/ue4_overlay_v3_proof.log` to determine if the overlay is running. Historical logs remain on disk across resprings, causing false-positive "already running" detections.
- **Solution**: Track the actual live SpringBoard PID against `/var/mobile/Downloads/overlay_sb_pid.txt`.
  - If `SB_PID != RECORDED_PID`, SpringBoard has restarted/respringed: automatically run `jbctl proc_set_debugged` + `opainject` and update the recorded PID.
  - If `SB_PID == RECORDED_PID`, skip injection to avoid the duplicate-injection crash.

### Problem 4: Post-Respring Auto-Injection
- Whenever `sbreload` is executed, SpringBoard gets a new PID.
- In `tools/start_radar.py`, `do_restart(..., respring_overlay=True)` automatically sleeps 4 seconds for SpringBoard to reload and triggers `ensure_overlay(force=True)`.

### Problem 5: Remote Shell Socket Resilience (`tools/remote_sh.py`)
- iDownload is an execution prompt (`iDownload> `), not a full POSIX shell.
- Place completion markers (`echo __CODEX_DONE__`) inside the pushed script file, not as trailing command arguments.
- Wrap socket connections in auto-retry loops to handle transient connection resets.

---

## 4. Runbook: Verification & Daily Operations

### 1. Verify Live System State (Read-Only)
```python
import sys
sys.path.insert(0, r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor\sileo_repo\tools")
from remote_sh import run_script

script = """
ps -ef | grep -E 'SpringBoard|ShadowTrackerExtra|ue4loadmonitor' | grep -v grep
ls -l /var/mobile/Downloads/ue4_radar.bin
tail -5 /var/mobile/Downloads/ue4_overlay_v3_proof.log
"""
print(run_script(script, timeout=10))
```

### 2. Run Desktop Launcher
From Windows Command Prompt / PowerShell:
```cmd
"C:\Users\GAME\Desktop\Start Radar.bat"
```
Or non-interactive check:
```cmd
"C:\Users\GAME\Desktop\Start Radar.bat" --no-loop
```
**Restarter Console Hotkeys**:
- `[R]` -> Instant Restart (terminates crashed game, restarts daemon, relaunches game)
- `[S]` -> Soft Respring (reloads SpringBoard, waits 4s, auto-injects overlay, restarts game)
- `[O]` -> Re-Inject Overlay (forces instant injection into current SpringBoard PID)
- `[K]` -> Clean Shutdown (stops daemon and kills game)
- `[Q]` -> Quit Launcher Console (leaves tweak running on phone)

### 3. Build & Package Release
```cmd
cd C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor\sileo_repo
python tools\build_local.py
python tools\package_release.py
```
This updates `artifacts/build.json`, `artifacts/SHA256SUMS`, and `debs/com.local.ue4loadmonitor_1.3.3_iphoneos-arm64.deb`.

### 4. Git Push & Parity Maintenance
Always keep the working directory clean and synced:
```cmd
git add -A
git commit -m "Your descriptive commit message"
git push origin main
```

---

## 5. Protocol for Updating this Skill

Whenever you work on this project:
1. Verify the current build matches across:
   - Source code (`source/daemon/`, `source/overlay/`)
   - Release binaries (`artifacts/`)
   - Installed tweak (`/var/jb/usr/lib/TweakInject/radar_overlay.dylib`)
   - Desktop launcher (`tools/start_radar.py`)
   - Git repository (`main` branch)
2. If any new behavior, offset, or script is introduced, update this file immediately.
3. Keep instructions concise, factual, and strictly focused on verified steps.
