#!/usr/bin/python3
"""Restore and verify before unloading. Root-only, no force bypass."""
import sys
if not sys.flags.isolated:
    raise SystemExit("Use /usr/bin/python3 -I with this reviewed installer script")

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time

MANIFEST_SHA256 = "@MANIFEST_SHA256@"
LABEL = "local.mac-thermal.fan-helper"
HELPER = Path("/Library/PrivilegedHelperTools") / LABEL
PLIST = Path("/Library/LaunchDaemons") / (LABEL + ".plist")
FOLDER = Path("/Library/Application Support/Mac Thermal/FanControl")

def regular(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o022:
        raise RuntimeError("Untrusted installed file")

def uninstall():
    if os.getuid() != 0 or os.geteuid() != 0 or len(sys.argv) != 1: raise RuntimeError("Administrator privileges and no arguments required")
    descriptor = os.open(Path(__file__).resolve().parent / "MANIFEST.json", os.O_RDONLY | os.O_NOFOLLOW)
    try: raw = os.read(descriptor, 16385)
    finally: os.close(descriptor)
    if len(raw) > 16384 or hashlib.sha256(raw).hexdigest() != MANIFEST_SHA256: raise RuntimeError("Manifest changed")
    manifest = json.loads(raw)
    # Verify root-only parents without following links before signaling/running.
    for target in [HELPER, PLIST, FOLDER / "config.json"]:
        current = Path("/")
        for part in target.parent.parts[1:]:
            current /= part
            info = current.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022: raise RuntimeError("Unsafe installation parent")
        regular(target)
    if hashlib.sha256(HELPER.read_bytes()).hexdigest() != manifest["helperSHA256"]: raise RuntimeError("Different helper installed; use its matching uninstaller")
    marker = FOLDER / "maintenance"
    if marker.exists() or marker.is_symlink():
        regular(marker)
        if marker.read_bytes() != b"1": raise RuntimeError("Invalid maintenance marker")
    else:
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try: os.write(fd, b"1"); os.fsync(fd)
        finally: os.close(fd)
    # New starts are inhibited before requesting service shutdown/restoration.
    subprocess.run(["/bin/launchctl", "kill", "SIGTERM", "system/" + LABEL], check=False, capture_output=True)
    end = time.monotonic() + 10
    verified = False
    while time.monotonic() < end:
        if not (FOLDER / "lease.json").exists():
            result = subprocess.run([str(HELPER), "--verify-auto"], timeout=3, check=False, capture_output=True)
            if result.returncode == 0: verified = True; break
        time.sleep(0.25)
    if not verified: raise RuntimeError("Automatic control unconfirmed; helper and recovery data retained")
    loaded = subprocess.run(["/bin/launchctl", "print", "system/" + LABEL], capture_output=True).returncode == 0
    if loaded:
        subprocess.run(["/bin/launchctl", "bootout", "system/" + LABEL], check=True)
    if (FOLDER / "lease.json").exists(): raise RuntimeError("Recovery appeared; retaining installation")
    for target in [PLIST, HELPER, FOLDER / "config.json", FOLDER / "maintenance"]:
        regular(target); target.unlink()
    # Empty fixed folder only; never recursively remove unrelated files.
    try: FOLDER.rmdir()
    except OSError: pass
    print("Verified Apple automatic mode and removed the fan helper.")

if __name__ == "__main__":
    try: uninstall()
    except Exception as error:
        print("Uninstall stopped: " + str(error) + ". Recovery files remain in place.", file=sys.stderr)
        sys.exit(1)
