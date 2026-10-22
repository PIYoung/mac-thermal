#!/usr/bin/python3
"""Reviewed local-only installation. Never invoked automatically by the app."""
import sys
if not sys.flags.isolated:
    raise SystemExit("Use /usr/bin/python3 -I with this reviewed installer script")

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import uuid

MANIFEST_SHA256 = "@MANIFEST_SHA256@"
LABEL = "local.mac-thermal.fan-helper"
HELPER = Path("/Library/PrivilegedHelperTools") / LABEL
PLIST = Path("/Library/LaunchDaemons") / (LABEL + ".plist")
FOLDER = Path("/Library/Application Support/Mac Thermal/FanControl")

def secure_parents(path):
    current = Path("/")
    for part in path.parent.parts[1:]:
        current /= part
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError("Unsafe installation parent")

def codehash(path):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)
    result = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)], capture_output=True, text=True, check=True)
    match = re.search(r"^CDHash=([a-f0-9]{40,64})$", result.stderr, re.M)
    if not match: raise RuntimeError("Missing code hash")
    flags = re.search(r"flags=0x([a-fA-F0-9]+)", result.stderr)
    if not flags or not int(flags.group(1), 16) & 0x10000: raise RuntimeError("Hardened runtime is required")
    ent = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)], capture_output=True, check=True).stdout
    values = plistlib.loads(ent) if ent.strip() else {}
    if any(values.get(key) for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables"]):
        raise RuntimeError("Unsafe injection/debug entitlements")
    return match.group(1)

def read_regular(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= limit:
            raise RuntimeError("Invalid input file")
        data = bytearray()
        while len(data) <= limit:
            block = os.read(fd, min(65536, limit + 1 - len(data)))
            if not block: break
            data.extend(block)
        if len(data) != info.st_size: raise RuntimeError("Input changed while reading")
        return bytes(data)
    finally: os.close(fd)

def atomic_root_file(path, data, mode):
    secure_parents(path)
    temporary = path.parent / (".fan-install-" + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode)
    try:
        os.fchown(fd, 0, 0)
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(data); output.flush(); os.fsync(fd)
        if path.exists() or path.is_symlink(): raise RuntimeError("Existing installation; refusing replacement")
        os.rename(temporary, path)
        folder = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(folder)
        finally: os.close(folder)
    finally:
        os.close(fd)
        if temporary.exists(): temporary.unlink()

def install():
    if os.getuid() != 0 or os.geteuid() != 0: raise RuntimeError("Run this reviewed installer with administrator privileges")
    if len(sys.argv) != 1: raise RuntimeError("This installer accepts no commands, paths or options")
    package = Path(__file__).resolve().parent
    raw = read_regular(package / "MANIFEST.json", 16384)
    if hashlib.sha256(raw).hexdigest() != MANIFEST_SHA256: raise RuntimeError("Package manifest changed")
    manifest = json.loads(raw)
    app = Path(manifest["appPath"])
    executable = app / "Contents/MacOS/MacThermal"
    if manifest["uid"] < 501 or executable.lstat().st_uid != manifest["uid"]: raise RuntimeError("Unexpected app owner")
    if codehash(app) != manifest["clientCDHash"]: raise RuntimeError("Reviewed app changed")
    if hashlib.sha256(read_regular(executable, 50000000)).hexdigest() != manifest["appSHA256"]: raise RuntimeError("App executable changed")
    payload = read_regular(package / LABEL, 50000000)
    if hashlib.sha256(payload).hexdigest() != manifest["helperSHA256"]: raise RuntimeError("Helper payload changed")
    if any(path.exists() or path.is_symlink() for path in [HELPER, PLIST, FOLDER / "config.json", FOLDER / "lease.json", FOLDER / "maintenance"]):
        raise RuntimeError("Existing helper/recovery data found; use its reviewed uninstaller first")
    for parent in [HELPER.parent, PLIST.parent, FOLDER.parent, FOLDER]:
        if not parent.exists():
            secure_parents(parent)
            parent.mkdir(mode=0o700 if parent == FOLDER else 0o755)
            os.chown(parent, 0, 0)
        secure_parents(parent / "check")
    config = json.dumps({"version":1, "clientCDHash":manifest["clientCDHash"], "allowedUID":manifest["uid"]}).encode()
    launch = {"Label":LABEL, "ProgramArguments":[str(HELPER)], "MachServices":{LABEL:True},
              "RunAtLoad":True, "KeepAlive":True, "ThrottleInterval":10, "ExitTimeOut":20, "ProcessType":"Background"}
    atomic_root_file(HELPER, payload, 0o555)
    if codehash(HELPER) != manifest["helperCDHash"]: raise RuntimeError("Installed helper code hash mismatch")
    atomic_root_file(FOLDER / "config.json", config, 0o600)
    atomic_root_file(PLIST, plistlib.dumps(launch), 0o644)
    subprocess.run(["/bin/launchctl", "bootstrap", "system", str(PLIST)], check=True)
    print("Installed a local, code-hash-pinned fan helper. No cooling boost was started.")

if __name__ == "__main__":
    try: install()
    except Exception as error:
        print("Installation stopped: " + str(error), file=sys.stderr)
        print("Do not remove recovery data or bypass code-signing checks.", file=sys.stderr)
        sys.exit(1)
