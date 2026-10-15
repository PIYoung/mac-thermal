#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
preview_dir="$project_dir/build/doc-preview"
helper_dir="$preview_dir/DocPreview.app"
mkdir -p "$preview_dir/module-cache" "$helper_dir/Contents/MacOS" "$helper_dir/Contents/Resources" "$project_dir/docs/images"
/usr/bin/python3 - "$project_dir" "$preview_dir" <<'PY'
from pathlib import Path
import plistlib
import sys
project, preview = map(Path, sys.argv[1:])
main, marker, _ = (project / 'main.swift').read_text().partition('final class AppDelegate:')
if not marker:
    raise SystemExit('Cannot isolate documentation models from app entry point')
resources, marker, _ = (project / 'Resources.swift').read_text().partition('enum ResourceSampler')
if not marker:
    raise SystemExit('Cannot isolate documentation models from metric samplers')
# Even the pending placeholder uses a fixture instead of querying thermal state.
main = main.replace('ThermalStatus(ProcessInfo.processInfo.thermalState)', 'ThermalStatus(.nominal)')
(preview / 'DocModels.swift').write_text(main + '\n' + resources)
info = {'CFBundleExecutable': 'DocPreview', 'CFBundleIdentifier': 'local.mac-thermal.docs-preview', 'CFBundlePackageType': 'APPL', 'LSUIElement': True}
(preview / 'DocPreview.app' / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swift -module-cache-path "$preview_dir/module-cache" "$project_dir/DrawIcon.swift" "$preview_dir/AppIcon.iconset"
iconutil -c icns "$preview_dir/AppIcon.iconset" -o "$helper_dir/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$preview_dir/module-cache" \
  "$project_dir/Localization.swift" "$project_dir/PanelTranslations.swift" "$project_dir/SystemTranslations.swift" \
  "$preview_dir/DocModels.swift" "$project_dir/MenuBarPreferences.swift" \
  "$project_dir/Uptime.swift" "$project_dir/CPUUsageHistory.swift" "$project_dir/LiquidTabs.swift" \
  "$project_dir/Panel.swift" "$project_dir/scripts/render-doc-preview.swift" \
  -framework AppKit -framework QuartzCore -o "$helper_dir/Contents/MacOS/DocPreview"
"$helper_dir/Contents/MacOS/DocPreview" "$project_dir/docs/images/mac-thermal-summary.png"
