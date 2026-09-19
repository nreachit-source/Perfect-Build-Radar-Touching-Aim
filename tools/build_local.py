"""Build daemon, overlay and isolated regression test on Windows; no deployment."""
import argparse
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ZIG = ROOT.parents[1] / "iPhone_RE_Toolchain" / "zig" / "zig.exe"


def patch_ios(path):
    data = bytearray(path.read_bytes())
    if len(data) < 32 or struct.unpack_from("<II", data) != (0xFEEDFACF, 0x100000C):
        raise ValueError("Expected a 64-bit ARM Mach-O")
    end = 32 + struct.unpack_from("<I", data, 20)[0]
    off, found = 32, 0
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        if off + 8 > min(end, len(data)):
            raise ValueError("Truncated load command")
        cmd, size = struct.unpack_from("<II", data, off)
        if size < 8 or off + size > min(end, len(data)):
            raise ValueError("Invalid load command size")
        if cmd == 0x32:
            if size < 24:
                raise ValueError("Truncated build version")
            struct.pack_into("<III", data, off + 8, 2, 0xD0000, 0xD0000)
            found += 1
        off += size
    if found != 1 or off != end:
        raise ValueError("Expected exactly one LC_BUILD_VERSION")
    path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", type=Path, default=DEFAULT_ZIG)
    parser.add_argument("--out", type=Path, default=ROOT.parent / "build_codex")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    src = ROOT / "source" / "daemon"
    common = [str(args.zig), "cc", "-target", "aarch64-macos", "-std=c11",
              "-O2", "-Wall", "-Wextra", "-Werror",
              "-fno-builtin-sinf", "-fno-builtin-cosf", "-fno-builtin-sin", "-fno-builtin-cos"]
    daemon = ["main", "ue4_sdk", "remote_memory", "aslr_slide", "pattern_scan",
              "ue4_reflection", "ue4_json", "radar_reader"]
    targets = {
        "ue4loadmonitor": [str(src / (name + ".c")) for name in daemon],
        "radar_overlay.dylib": ["-x", "c", "-dynamiclib", "-Wl,-undefined,dynamic_lookup",
                                str(ROOT / "source/overlay/radar_overlay.m")],
        "sdk_regression": ["-I", str(src),
            '-DUE4_SDK_OUTPUT_PATH="/var/jb/tmp/codex_sdk_regression.json"',
            '-DUE4_SDK_LOG_PATH="/var/jb/tmp/codex_sdk_regression.log"',
            '-DUE4_SDK_CONFIG_PATH="/var/jb/tmp/codex_sdk_regression.config"',
            str(ROOT / "tests/sdk_regression.c"), str(src / "ue4_sdk.c"), str(src / "ue4_json.c")],
        "test_dlopen": [str(ROOT / "tests/test_dlopen.c")],
        "menu_runtime_test.dylib": ["-x", "c", "-dynamiclib", "-Wl,-undefined,dynamic_lookup",
                                     str(ROOT / "tests/menu_runtime_test.c")],
    }
    for name, flags in targets.items():
        output = args.out / name
        subprocess.run(common + flags + ["-o", str(output)], check=True)
        patch_ios(output)
        print(f"Built and verified iOS ARM64: {output}", flush=True)


if __name__ == "__main__":
    main()
