#!/usr/bin/python3
"""Prepare exact local payloads; does not run the helper, sudo or launchctl."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

project = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2: raise SystemExit("Usage: prepare_fan_installation.py /absolute/path/to/reviewed/Mac Thermal.app")
app = Path(sys.argv[1]).absolute()
helper = app / "Contents/Resources/local.mac-thermal.fan-helper"
executable = app / "Contents/MacOS/MacThermal"

def codehash(path):
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)
    result = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)], capture_output=True, text=True, check=True)
    match = re.search(r"^CDHash=([a-f0-9]{40,64})$", result.stderr, re.M)
    if not match: raise RuntimeError("Code hash unavailable")
    return match.group(1)

manifest = {"version":1, "appPath":str(app), "uid":os.getuid(), "clientCDHash":codehash(app),
            "appSHA256":hashlib.sha256(executable.read_bytes()).hexdigest(), "helperCDHash":codehash(helper),
            "helperSHA256":hashlib.sha256(helper.read_bytes()).hexdigest()}
folder = project / "build/fan-control-installation"
folder.mkdir(parents=True, exist_ok=True)
raw = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
digest = hashlib.sha256(raw).hexdigest()
(folder / "MANIFEST.json").write_bytes(raw)
shutil.copy2(helper, folder / "local.mac-thermal.fan-helper")
for name in ["install", "uninstall"]:
    source = (project / "Helper" / (name + "-template.py")).read_text()
    assert source.count("@MANIFEST_SHA256@") == 1
    (folder / (name + ".py")).write_text(source.replace("@MANIFEST_SHA256@", digest))
for name in ["LICENSE", "THIRD_PARTY_NOTICES.txt"]: shutil.copy2(project / name, folder / name)
(folder / "REVIEW.txt").write_text(
    "LOCAL REVIEW PACKAGE. Nothing has been installed or executed.\n"
    "Root helper: /Library/PrivilegedHelperTools/local.mac-thermal.fan-helper\n"
    "Launch service: /Library/LaunchDaemons/local.mac-thermal.fan-helper.plist\n"
    "Root-only pin/recovery data: /Library/Application Support/Mac Thermal/FanControl/\n"
    "Only the exact reviewed app code hash and user ID can connect.\n"
    "RPM: 100-RPM steps, not below current speed or hardware minimum; not above any fan maximum.\n"
    "Fixed 600 seconds, no extension. Heat/pressure/missing temperature, sleep/disconnect restore automatic mode.\n"
    "No global Ftst/test unlock writes. Unsupported hardware fails closed.\n"
    "Custom RPM can reduce cooling relative to later automatic demand. Safety checks are not hardware guarantees.\n"
    "Keep this matching package for uninstall; the uninstaller verifies auto before removal.\n"
    "Administrator installation and actual fan writes require separate user approval.\n"
    "Manifest SHA256: " + digest + "\n")
print("Prepared (not installed): " + str(folder))
print("Manifest SHA256: " + digest)
