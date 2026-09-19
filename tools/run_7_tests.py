import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT.parent
sys.path.insert(0, str(ROOT / "tools"))
from remote_sh import run_script, PY3

def main():
    bin_path = MONITOR / "build_codex" / "test_aim_suite"
    from build_local import DEFAULT_ZIG, patch_ios
    subprocess.run([str(DEFAULT_ZIG), "cc", "-target", "aarch64-macos", "-O2", "-Wl,-undefined,dynamic_lookup", str(ROOT / "tests/test_aim_suite.c"), "-o", str(bin_path)], check=True)
    patch_ios(bin_path)
    if not bin_path.is_file():
        print(f"Error: {bin_path} not found")
        sys.exit(1)

    print("==> 1. Pushing test_aim_suite to device via AFC...")
    subprocess.run([PY3, "-m", "pymobiledevice3", "afc", "push",
                    str(bin_path), "/test_aim_suite_next"], check=True)

    print("==> 2. Signing test_aim_suite and registering trustcache...")
    sign_script = """export PATH=/var/jb/usr/bin:/var/jb/bin:$PATH
cp /var/mobile/Media/test_aim_suite_next /var/jb/tmp/test_aim_suite
chmod 755 /var/jb/tmp/test_aim_suite
ldid -S /var/jb/tmp/test_aim_suite
HASH=$(ldid -h /var/jb/tmp/test_aim_suite | grep -o 'CDHash=[0-9a-fA-F]*' | head -n1 | cut -d= -f2)
/var/jb/basebin/jbctl trustcache add "$HASH" 2>/dev/null || true
echo "SIGN_OK HASH=$HASH"
"""
    res = run_script(sign_script)
    print(res)

    print("==> 3. Running 7-Test Verification Suite on device...")
    exec_script = """export PATH=/var/jb/usr/bin:/var/jb/bin:$PATH
/var/jb/tmp/test_aim_suite 2>&1
rc=$?
echo TEST_EXIT=$rc
"""
    test_out = run_script(exec_script, timeout=45)
    print("\n" + "=" * 70)
    print("DEVICE TEST EXECUTION OUTPUT:")
    print("=" * 70)
    print(test_out)
    if "TEST_EXIT=0" not in test_out:
        raise RuntimeError("Device dispatch checks failed or did not complete")
    print("=" * 70)

if __name__ == "__main__":
    main()
