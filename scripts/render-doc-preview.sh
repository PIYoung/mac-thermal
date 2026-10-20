#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
preview_dir="$project_dir/build/doc-preview"
helper_dir="$preview_dir/DocPreview.app"
mkdir -p "$preview_dir/module-cache" "$helper_dir/Contents/MacOS" "$helper_dir/Contents/Resources" "$project_dir/docs/images"
/usr/bin/python3 - "$project_dir" "$preview_dir" <<'PY'
from pathlib import Path
import plistlib
import sys
project, preview = map(Path, sys.argv[1:])
main, marker, _ = (project / 'Sources/main.swift').read_text().partition('final class AppDelegate:')
if not marker:
    raise SystemExit('Cannot isolate documentation models from app entry point')
resources, marker, _ = (project / 'Sources/Resources.swift').read_text().partition('enum ResourceSampler')
if not marker:
    raise SystemExit('Cannot isolate documentation models from metric samplers')
# Even the pending placeholder uses a fixture instead of querying thermal state.
main = main.replace('ThermalStatus(ProcessInfo.processInfo.thermalState)', 'ThermalStatus(.nominal)')
(preview / 'DocModels.swift').write_text(main + '\n' + resources)
info = {'CFBundleExecutable': 'DocPreview', 'CFBundleIdentifier': 'local.mac-thermal.docs-preview', 'CFBundlePackageType': 'APPL', 'LSUIElement': True}
(preview / 'DocPreview.app' / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swift -module-cache-path "$preview_dir/module-cache" "$project_dir/scripts/DrawIcon.swift" "$preview_dir/AppIcon.iconset"
iconutil -c icns "$preview_dir/AppIcon.iconset" -o "$helper_dir/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$preview_dir/module-cache" \
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/CodexTranslations.swift" \
  "$preview_dir/DocModels.swift" "$source_dir/MenuBarPreferences.swift" \
  "$source_dir/Uptime.swift" "$source_dir/CPUUsageHistory.swift" "$source_dir/LiquidTabs.swift" \
  "$source_dir/DiskCleanup.swift" "$source_dir/DiskCleanupView.swift" "$source_dir/HealthAdvice.swift" "$source_dir/OnDeviceAdvice.swift" "$source_dir/HealthAdviceView.swift" "$source_dir/Panel.swift" "$project_dir/scripts/render-doc-preview.swift" \
  -Xlinker -weak_framework -Xlinker FoundationModels -framework AppKit -framework QuartzCore -o "$helper_dir/Contents/MacOS/DocPreview"
"$helper_dir/Contents/MacOS/DocPreview" "$project_dir/docs/images/mac-thermal-cpu.png" "$project_dir/build/panel-previews"
