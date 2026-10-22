#!/usr/bin/python3
"""Nonprivileged boundary tests. Never invokes sudo, launchctl or the helper."""
import sys
sys.dont_write_bytecode = True
if not sys.flags.isolated: raise SystemExit("Run with /usr/bin/python3 -I")
import importlib.util
import os
from pathlib import Path
import tempfile

project = Path(__file__).resolve().parent.parent
if os.geteuid() == 0: raise SystemExit("This test must not run as root")

def load(name):
    path = project / "Helper" / (name + "-template.py")
    compile(path.read_text(), str(path), "exec")
    spec = importlib.util.spec_from_file_location("fan_" + name + "_fixture", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def rejected(action):
    try: action()
    except (RuntimeError, OSError): return
    raise AssertionError("Unsafe input was accepted")

install = load("install")
uninstall = load("uninstall")
rejected(install.install)
rejected(uninstall.uninstall)
with tempfile.TemporaryDirectory(prefix="fan-installer-fixture-") as temporary:
    folder = Path(temporary)
    plain = folder / "plain"; plain.write_bytes(b"ok")
    assert install.read_regular(plain, 2) == b"ok"
    rejected(lambda: install.read_regular(plain, 1))
    symlink = folder / "symlink"; symlink.symlink_to(plain)
    rejected(lambda: install.read_regular(symlink, 10))
    hardlink = folder / "hardlink"; os.link(plain, hardlink)
    rejected(lambda: install.read_regular(plain, 10))
    hardlink.unlink()
    rejected(lambda: install.atomic_root_file(folder / "blocked", b"no", 0o600))
    assert not (folder / "blocked").exists()
if len(sys.argv) == 2:
    app = Path(sys.argv[1])
    assert install.codehash(app)
    assert install.codehash(app / "Contents/Resources/local.mac-thermal.fan-helper")
print("PASS installer boundaries: root guard, isolated mode, bounded regular inputs, symlink/hardlink refusal, unsafe parent refusal; no administrator operations or hardware")
