#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
artwork_dir="$project_dir/build/readme-assets"
helper_dir="$artwork_dir/ReadmeAssets.app"
image_dir="$project_dir/docs/images"
mkdir -p "$artwork_dir/module-cache" "$helper_dir/Contents/MacOS" "$image_dir"
# Reuse the panel renderer's deterministic, isolated fixtures for every locale.
zsh "$project_dir/scripts/render-doc-preview.sh"
/usr/bin/python3 - "$project_dir" "$artwork_dir" <<'PY'
from pathlib import Path
import plistlib
import sys
project, artwork = map(Path, sys.argv[1:])
main, marker, _ = (project / 'Sources/main.swift').read_text().partition('final class AppDelegate:')
if not marker:
    raise SystemExit('Cannot isolate documentation models from app entry point')
resources, marker, _ = (project / 'Sources/Resources.swift').read_text().partition('enum ResourceSampler')
if not marker:
    raise SystemExit('Cannot isolate documentation models from metric samplers')
main = main.replace('ThermalStatus(ProcessInfo.processInfo.thermalState)', 'ThermalStatus(.nominal)')
(artwork / 'ReadmeModels.swift').write_text(main + '\n' + resources)
info = {'CFBundleExecutable': 'ReadmeAssets', 'CFBundleIdentifier': 'local.mac-thermal.readme-assets', 'CFBundlePackageType': 'APPL', 'LSUIElement': True}
(artwork / 'ReadmeAssets.app' / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$artwork_dir/module-cache" \
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/CodexTranslations.swift" \
  "$artwork_dir/ReadmeModels.swift" "$source_dir/MenuBarPreferences.swift" \
  "$source_dir/CodexModels.swift" "$source_dir/CodexMenuState.swift" "$source_dir/MenuBarContent.swift" "$project_dir/scripts/render-readme-assets.swift" \
  -framework AppKit -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers \
  -o "$helper_dir/Contents/MacOS/ReadmeAssets"
"$helper_dir/Contents/MacOS/ReadmeAssets" "$image_dir"
cp "$project_dir/build/doc-preview/AppIcon.iconset/icon_128x128@2x.png" "$image_dir/app-icon.png"
for language in ko en ja zh-CN; do
  source_language="$language"
  [[ "$language" != zh-CN ]] || source_language=zh-Hans
  for tab in cpu gpu memory ssd network; do
    cp "$project_dir/build/panel-previews/$source_language-light-$tab.png" "$image_dir/panel-$language-$tab.png"
  done
done
zsh "$project_dir/scripts/run_codex_panel_probe.sh" --render "$project_dir/build/codex-docs"
for language in ko en ja zh-CN; do
  source_language="$language"
  [[ "$language" != zh-CN ]] || source_language=zh-Hans
  cp "$project_dir/build/codex-docs/codex-$source_language-light.png" "$image_dir/codex-$language-light.png"
done
print -- "README artwork ready: original app icon, synthetic menu GIF/PNG, and 20 native resource PNGs (680×840) and four Codex PNGs (600×840)."
