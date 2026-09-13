# UE4 Load Monitor

This repository contains a small iOS development monitor and its Sileo package. The monitor checks the process list for the executable name `ShadowTrackerExtra`. When detected, it writes a marker file. It does not read process memory, game files, credentials, or live object values.

## Sileo source

Add this source:

`https://raw.githubusercontent.com/nreachit-source/stuck/main/`

Install the package named `UE4 Load Monitor`.

## Source layout

- `source/daemon/main.c`: process-name monitor source.
- `source/daemon/entitlements.plist`: daemon signing entitlement.
- `source/daemon/com.local.ue4loadmonitor.plist`: rootless launchd configuration.
- `source/plugin/UE4SchemaExporter`: optional source-only UE4 plugin for projects built by their owner.

The optional UE4 plugin uses Unreal's public reflection API inside an authorized source build. It exports class/function/property schema to `Saved/SchemaExport/ue4_schema.json`. It deliberately does not read another process or export live object values.

## Building

The daemon is an ARM64 iOS command-line Mach-O. Compile `main.c` against an iOS SDK, reserve code-signature header padding, then ad-hoc sign it with the included entitlement. Package it at `/var/jb/usr/local/libexec/ue4loadmonitor` with mode `0755` and install the launchd plist at `/var/jb/Library/LaunchDaemons/` with mode `0644`.

For the schema exporter, copy `UE4SchemaExporter` into the owning UE project's `Plugins` directory, enable it, and rebuild the iOS target. The current implementation targets UE 4.25–4.27.
