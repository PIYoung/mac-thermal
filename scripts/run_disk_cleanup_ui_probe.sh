#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
check_dir="$project_dir/build/disk-cleanup-ui-check"
mkdir -p "$check_dir/module-cache"
/usr/bin/python3 - "$project_dir" "$check_dir" <<'PY'
from pathlib import Path
import sys
project, check = map(Path, sys.argv[1:])
models, marker, _ = (project/'Sources/main.swift').read_text().partition('final class AppDelegate:')
assert marker
resources, marker, _ = (project/'Sources/Resources.swift').read_text().partition('enum ResourceSampler')
assert marker
models = models.replace('ThermalStatus(ProcessInfo.processInfo.thermalState)', 'ThermalStatus(.nominal)')
(check/'ProbeModels.swift').write_text(models+'\n'+resources)
PY
xcrun swiftc -O -D PANEL_UPDATES_PROBE -target arm64-apple-macosx14.0 \
  -module-cache-path "$check_dir/module-cache" \
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" \
  "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/CodexTranslations.swift" \
  "$check_dir/ProbeModels.swift" "$source_dir/MenuBarPreferences.swift" \
  "$source_dir/Uptime.swift" "$source_dir/CPUUsageHistory.swift" "$source_dir/LiquidTabs.swift" \
  "$source_dir/DiskCleanup.swift" "$source_dir/DiskCleanupView.swift" \
  "$source_dir/HealthAdvice.swift" "$source_dir/OnDeviceAdvice.swift" "$source_dir/HealthAdviceView.swift" "$source_dir/FanBoost.swift" "$source_dir/FanControlProtocol.swift" "$source_dir/FanControlClient.swift" "$source_dir/FanControlView.swift" "$source_dir/Panel.swift" "$source_dir/DashboardLayout.swift" "$source_dir/DashboardWindow.swift" "$source_dir/PanelPresentationRequest.swift" \
  "$project_dir/tests/probes/disk_cleanup_ui_probe.swift" \
  -Xlinker -weak_framework -Xlinker FoundationModels -framework AppKit -framework QuartzCore -o "$check_dir/disk-cleanup-ui-probe"
"$check_dir/disk-cleanup-ui-probe"
