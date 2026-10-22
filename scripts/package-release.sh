#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
case "${1:-}" in
  "") zsh "$project_dir/build.sh" ;;
  --skip-build) ;;
  --help|-h)
    print -- "Usage: zsh scripts/package-release.sh [--skip-build]"
    print -- "Create an Apple Silicon DMG, app ZIP, optional fan-tools ZIP, and SHA256SUMS in dist/."
    exit 0 ;;
  *) print -u2 -- "Unknown option: $1"; exit 2 ;;
esac
(( $# <= 1 )) || { print -u2 -- "Too many arguments."; exit 2; }

app_dir="$project_dir/build/Mac Thermal.app"
dist_dir="$project_dir/dist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 -- "Invalid release version: $version"; exit 1; }
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
[[ "$app_version" == "$version" ]] || { print -u2 -- "The built app version does not match Info.plist."; exit 1; }
[[ "$(xcrun lipo -archs "$app_dir/Contents/MacOS/MacThermal")" == arm64 ]] || { print -u2 -- "Expected an arm64-only application."; exit 1; }
codesign --verify --strict "$app_dir"
for notice in LICENSE THIRD_PARTY_NOTICES.txt ASSET_PROVENANCE.md; do
  cmp "$project_dir/$notice" "$app_dir/Contents/Resources/$notice"
done

mkdir -p "$dist_dir"
artifact_name="Mac-Thermal-v${version}-arm64"
stage_dir="$(mktemp -d "$project_dir/build/dmg-stage.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT
/usr/bin/ditto "$app_dir" "$stage_dir/Mac Thermal.app"
ln -s /Applications "$stage_dir/Applications"
cp "$project_dir/LICENSE" "$project_dir/THIRD_PARTY_NOTICES.txt" "$stage_dir/"
# Copy only reviewed source templates/notices: no generated personal manifest,
# app-path/UID pin, recovery journal, credential or auto-install entry point.
/usr/bin/python3 - "$project_dir" "$stage_dir" "$dist_dir" "$version" <<'PYTOOLS'
from pathlib import Path
import re, shutil, sys, zipfile
project, stage, dist = map(Path, sys.argv[1:4])
version = sys.argv[4]
folder = stage / f'Mac Thermal Fan Tools v{version}'
files = ['scripts/prepare_fan_installation.py', 'Helper/install-template.py',
         'Helper/uninstall-template.py', 'docs/FAN_CONTROL_SETUP.md',
         'docs/FAN_CONTROL.md', 'docs/FAN_CONTROL_TESTS.md',
         'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'SECURITY.md', 'AGENTS.md']
for name in files:
    destination = folder / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(project / name, destination)
    if destination.suffix == '.md':
        def resolve_link(match):
            target = match.group(1)
            if ':' in target or target.startswith('#'): return match.group(0)
            relative = target.split('#', 1)[0]
            resolved = ((project / name).parent / relative).resolve()
            try: key = str(resolved.relative_to(project))
            except ValueError: return match.group(0)
            if key in files or not resolved.is_file(): return match.group(0)
            anchor = '#' + target.split('#', 1)[1] if '#' in target else ''
            return '](https://github.com/PIYoung/mac-thermal/blob/v' + version + '/' + key + anchor + ')'
        destination.write_text(re.sub(r'\]\(([^)]+)\)', resolve_link, destination.read_text()))
(folder / 'Read Me.txt').write_text(
    'OPTIONAL FAN CONTROL / 선택형 팬 제어 / 任意のファン制御 / 可选风扇控制\n'
    'Copy this whole versioned folder to a writable location before preparation.\n'
    'Review docs/FAN_CONTROL_SETUP.md (한국어 / English / 日本語 / 简体中文).\n'
    'No installation runs automatically. Basic monitoring needs no root helper.\n'
    'Keep this folder and its generated package for matching removal before updates.\n')
archive = dist / f'Mac-Thermal-v{version}-fan-tools.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as output:
    for file in sorted(folder.rglob('*')):
        if file.is_file(): output.write(file, file.relative_to(stage))
with zipfile.ZipFile(archive) as output:
    if output.testzip() is not None: raise SystemExit('Fan tools ZIP integrity failed')
    actual = {str(Path(x).relative_to(folder.name)) for x in output.namelist()}
    if actual != set(files) | {'Read Me.txt'}: raise SystemExit('Unexpected fan tools payload')
PYTOOLS
cat > "$stage_dir/Read Me First.txt" <<'TEXT'
Mac Thermal — Apple Silicon, macOS 14 or later

Drag Mac Thermal.app to Applications, then open it from Applications.

This community build is ad-hoc signed. It does not have an Apple Developer ID
signature and has not been notarized by Apple. A downloaded build may be blocked
by macOS. The project does not disable or bypass macOS security checks.
If macOS blocks it, you can review the source and build locally with Xcode 26+.

The application defaults to Korean. Open the gear button to choose English,
Japanese, or Simplified Chinese. It runs in the menu bar.

Optional experimental fan control requires a separate, personally reviewed
administrator installation. Copy the versioned Fan Tools folder to a writable
location and read its docs/FAN_CONTROL_SETUP.md. Nothing installs automatically.
Keep its matching generated package: remove the old helper before app updates.
Basic monitoring needs no helper. No fanless/unsupported device control is implied.

MIT license. Third-party notices are included beside this file and inside the app.
TEXT

# Standard Finder installation: application plus an Applications-folder shortcut.
hdiutil create -ov -format UDZO -volname "Mac Thermal $version" \
  -srcfolder "$stage_dir" "$dist_dir/$artifact_name.dmg"
hdiutil verify "$dist_dir/$artifact_name.dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$dist_dir/$artifact_name.zip"
/usr/bin/python3 - "$dist_dir" "$artifact_name" <<'PY'
from pathlib import Path
import hashlib
import sys
import zipfile

dist = Path(sys.argv[1])
name = sys.argv[2]
with zipfile.ZipFile(dist / f'{name}.zip') as archive:
    if archive.testzip() is not None:
        raise SystemExit('ZIP integrity check failed.')
    required = {'Mac Thermal.app/Contents/Info.plist',
                'Mac Thermal.app/Contents/MacOS/MacThermal',
                'Mac Thermal.app/Contents/Resources/LICENSE',
                'Mac Thermal.app/Contents/Resources/THIRD_PARTY_NOTICES.txt',
                'Mac Thermal.app/Contents/Resources/ASSET_PROVENANCE.md',
                'Mac Thermal.app/Contents/Resources/local.mac-thermal.fan-helper',
                'Mac Thermal.app/Contents/Resources/FanHelper.cdhash'}
    if not required.issubset(archive.namelist()):
        raise SystemExit('ZIP is missing required application files.')
lines = []
for path in [dist / f'{name}.dmg', dist / f'{name}.zip', dist / f'{name[:-len("-arm64")]}-fan-tools.zip']:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    lines.append(f'{digest.hexdigest()}  {path.name}\n')
(dist / 'SHA256SUMS').write_text(''.join(lines), encoding='utf-8')
print(''.join(lines), end='')
PY
print -- "Release artifacts: $dist_dir/$artifact_name.dmg, $artifact_name.zip, Mac-Thermal-v${version}-fan-tools.zip, SHA256SUMS"
