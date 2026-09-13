# Current device status — 2026-09-13

This supersedes the earlier continuation notes.

## User requirements

- No further schema dumps and no screenshots.
- Radar remains touch-through, except for the button above it and its menu.
- Independent Radar and Player lines toggles; lines originate at screen center.
- Do not claim complete enemy detection from a running daemon or local position.
- Nearby items/vehicles were requested earlier and remain unimplemented.

## Implemented and deployed

- Normal daemon startup no longer calls the schema dumper.
- Fixed initialization timing and object lookup. Original configured addresses
  are usable after the engine initializes; earlier empty reads did not prove
  that those offsets were wrong.
- Locate LocalPlayer through reflection, then ViewportClient +0x58 and World
  +0x78, validating PlayerController's backlink. The GameInstance LocalPlayers
  array was empty in the observed run.
- PlayerState array had four entries with unusable PawnPrivate pointers.
  Character discovery now enumerates STExtraBaseCharacter and derived objects,
  caches candidates, and reads validated positions/health directly.
- Fixed camera rotation to +0x548 and FOV to +0x554. Live samples showed plausible
  changing pitch/yaw and FOV 80 at those offsets, rather than the earlier layout.
- Shared protocol version 3 includes camera position/validity, status and a
  publication sequence. Overlay rejects invalid/inconsistent snapshots.
- Menu button above radar, separate radar and center-to-player line toggles,
  and hit-test gating to pass game touches through outside the controls.
- Live projection uses camera position, rotation, FOV, and view bounds; rejects
  behind-camera/off-screen coordinates and stale data. Lines default OFF.
- Built-in menu selftest uses the actual UIControl action handlers, restores
  defaults before rendering, and reports hit-test checks.

## Captured evidence

Latest capture: ../build_codex/proof/snapshot.json and device.log.
- Shared tick: 1332
- Status: 2 (camera/position ready), camera_valid: 1.
- Three readable character records, health values 100, 75, 100.
- Overlay draws and snapshots increased from 301 to 601; scene=1, hidden=0,
  player count=3, data age 0.00–0.05 seconds in those samples.
- SELFTEST: menu=1 radar_toggle=1 lines_toggle=1 pass_through=1 restored=1.
- Build passes -Wall -Wextra -Werror for daemon, overlay and SDK regression.
- Existing SDK regression previously passed on device; no new dump was run.

## Important remaining limitations

- These records are not proof of every enemy, or of teammate/enemy distinction.
  Team IDs and visibility classification are not implemented.
- Live line alignment still requires gameplay verification. Latest proof was
  captured with the line toggle OFF. Projection code is deployed, not visually
  verified; no screenshots were taken.
- Initial object discovery currently takes tens of seconds and recurring scans
  reduce reader cadence (roughly 12–15 Hz in the captured interval). This needs
  optimization before describing the radar as production-ready.
- Skeleton, nearby items and vehicles are not implemented.
- Persisted tweak loading after a future SpringBoard restart is not verified.
- Loading an additional diagnostic dylib into a SpringBoard already running
  the overlay twice caused SIGILL/restart during opainject. Do not repeat that
  auxiliary-injection test. Fresh-process overlay injection succeeded; cause of
  the reinjection failure is unresolved. SpringBoard PID 15676 was stable in the
  final capture, daemon PID 15702. PIDs are transient.
- Standalone menu diagnostic tests/menu_runtime_test.c did NOT execute because
  its injection failed. Only the built-in overlay selftest is a passed test.

## Files and commands

- tools/build_local.py: compile and validate iOS Mach-O artifacts.
- tools/deploy_daemon.py: signed USB deployment, no automatic dump.
- tools/capture_proof.py: bounded diagnostic snapshot/log capture.
- ../remote_sh.py: now uses unique temporary script names; overlapping calls
  previously shared exec.sh and could execute the wrong script. AFC has a
  45-second timeout. Keep device operations sequential.
- Installed daemon: /var/jb/usr/local/libexec/ue4loadmonitor.
- Installed overlay: /var/jb/usr/lib/TweakInject/radar_overlay.dylib.
- Runtime overlay: /var/jb/tmp/radar_overlay_v3_final.dylib.
- Prior binaries backed up as /var/jb/tmp/ue4loadmonitor_before_codex and
  /var/jb/tmp/radar_overlay_before_codex.dylib.
