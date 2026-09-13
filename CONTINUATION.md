# Current device status — 2026-09-13 (v4 Upgrade)

This supersedes all earlier continuation notes.

## Implemented and Deployed (Protocol v4)

1. **Complete Touch Pass-Through Window Architecture**:
   - `CodexRadarV4Window` implements both `- (BOOL)pointInside:withEvent:` and `- (UIView *)hitTest:withEvent:`.
   - Returns `NO`/`nil` across 100% of the screen area except for the draggable floating button and the open menu card.
   - Touches to all game controls (joystick, firing, aiming, camera rotation, inventory, prone, jump) pass directly through with zero interception or latency.

2. **Draggable Floating Control Button**:
   - Compact circular floating button (`CodexDragButton`) with glowing cyan border and dark translucent fill.
   - Smooth gesture-based dragging anywhere on screen with automatic screen edge clamping.
   - Tap detection (< 5pt movement) instantly toggles the settings menu.

3. **Polished 12-Feature Settings Menu Card**:
   - Centered 340x310 pt frosted dark glass card (`[UIColor colorWithWhite:0.1 alpha:0.95]`) with rounded corners and neon cyan border.
   - Header with title and close [X] button; footer with live telemetry status.
   - 2-Column grid of 12 interactive feature toggles with active/inactive visual styling:
     1. **Radar Minimap** (ON/OFF): Top-right circular radar with range rings, view cone, player dots, vehicle dots, and loot dots.
     2. **Player Snaplines** (ON/OFF): Lines originating from screen bottom-center to player feet.
     3. **2D Bounding Box ESP** (ON/OFF): Full 2D bounding boxes anchored to player head and feet coordinates.
     4. **Health Bar & HP** (ON/OFF): Vertical color-coded health bar (Green/Yellow/Red) and numeric HP text.
     5. **Player Name** (ON/OFF): Display player name read from reflection FString (`PlayerState->PlayerName` / `RealPlayerName`).
     6. **Distance in Meters** (ON/OFF): Real-time distance in meters `[XXm]` calculated from camera pos.
     7. **Team ID & Bot Badge** (ON/OFF): Team indicator `[T%u]` and `[BOT]` tag based on `UAEPlayerState->TeamID` and `APlayerState->bIsABot`.
     8. **Player Skeleton ESP** (ON/OFF): 16-point anatomical skeleton (head circle, spine, shoulders, arms, pelvis, legs) anchored to player 3D orientation.
     9. **Vehicle ESP** (ON/OFF): World-projected markers for vehicles (`STExtraVehicleBase`) with model name (Buggy, Dacia, UAZ, Motorcycle, Boat), distance, and speed in km/h.
     10. **Loot & Items ESP** (ON/OFF): World-projected ground loot (`PickUpWrapperActor`) with weapon names (M416, AKM, AWM, etc.), armor, meds, and distances.
     11. **Radar Range Scale** (100m / 200m / 400m): Dynamic zoom scaling for minimap radar.
     12. **Touch-Pass Status**: Active indicator confirming 100% click-through outside controls.

4. **Engine & Reader Optimization**:
   - Dual Actor Discovery: searches `PersistentLevel->Actors` array first for immediate discovery, falling back to non-blocking `ue4r_find_instance` scans.
   - Eliminated layout thrashing in `timer_tick` (no per-frame `setFrame:` calls).
   - Removed 2-second sleep stalling on temporary player state hiccups.
   - Shared protocol v4 with verified ABI static assertions (`sizeof(radar_shared_t) == 33768`).

5. **Diagnostic Verification & Proof**:
   - Automated selftest ran on device: `SELFTEST: menu_open=1 radar_toggle=1 lines_toggle=1 pass_corner=1 pass_radar=1 all_features=12`.
   - Real-time timer and shared reader verified running at 20 Hz (`timer=601 reads=601 draws=601 tick=261 status=1`).
   - Clean compilation under `-Wall -Wextra -Werror` with Zig toolchain.
   - Built Debian package `com.local.ue4loadmonitor_1.3.0_iphoneos-arm64.deb` and updated APT repository (`Packages`, `Packages.gz`, `Release`).
