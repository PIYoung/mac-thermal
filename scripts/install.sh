#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
open_after_install=0
case "${1:-}" in
  "") ;;
  --open) open_after_install=1 ;;
  --help|-h)
    print -- "Usage: zsh scripts/install.sh [--open]"
    print -- "Build locally and install into ~/Applications; --open launches the result."
    exit 0 ;;
  *) print -u2 -- "Unknown option: $1"; exit 2 ;;
esac
(( $# <= 1 )) || { print -u2 -- "Too many arguments."; exit 2; }

if pgrep -x MacThermal >/dev/null; then
  print -u2 -- "Quit Mac Thermal from its panel before installing. The installer will not stop it."
  exit 1
fi
zsh "$project_dir/build.sh"

/usr/bin/python3 - "$project_dir/build/Mac Thermal.app" <<'PY'
from datetime import datetime
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
applications = Path.home() / 'Applications'
destination = applications / 'Mac Thermal.app'
bundle_id = 'local.woori.mac-thermal'

def identifier(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream).get('CFBundleIdentifier')

if identifier(source) != bundle_id:
    raise SystemExit('The built application has an unexpected bundle identifier.')
if destination.exists() and (destination.is_symlink() or identifier(destination) != bundle_id):
    raise SystemExit('Refusing to replace an unrelated application or symbolic link.')
applications.mkdir(parents=True, exist_ok=True)
temporary = Path(tempfile.mkdtemp(prefix='.mac-thermal-install-', dir=applications))
staged = temporary / 'Mac Thermal.app'
backup = None
try:
    subprocess.run(['/usr/bin/ditto', str(source), str(staged)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(staged)], check=True)
    if subprocess.run(['/usr/bin/pgrep', '-x', 'MacThermal'], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('Mac Thermal started during the build. Quit it and rerun this installer.')
    if destination.exists():
        backup_parent = Path.home() / 'Library/Application Support/Mac Thermal/Backups'
        backup_parent.mkdir(parents=True, exist_ok=True)
        backup_dir = Path(tempfile.mkdtemp(prefix=datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=backup_parent))
        backup = backup_dir / 'Mac Thermal.app'
        os.replace(destination, backup)
    try:
        os.replace(staged, destination)
    except BaseException:
        if backup is not None:
            os.replace(backup, destination)
        raise
    print(f'Installed: {destination}')
    if backup is not None:
        print(f'Previous version: {backup}')
finally:
    shutil.rmtree(temporary)
PY

if (( open_after_install )); then
  /usr/bin/open "$HOME/Applications/Mac Thermal.app"
fi
