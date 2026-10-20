#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
build_dir="$project_dir/build/health-advice-check"
mkdir -p "$build_dir/module-cache"
/usr/bin/python3 - "$project_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
project, build = map(Path, sys.argv[1:])
models, marker, _ = (project / 'Sources/main.swift').read_text().partition('final class AppDelegate:')
if not marker:
    raise SystemExit('Cannot isolate app models from entry point')
resources, marker, _ = (project / 'Sources/Resources.swift').read_text().partition('enum ResourceSampler')
if not marker:
    raise SystemExit('Cannot isolate resource models from collectors')
# Synthetic tests must not query thermal state, sensors, processes, or login items.
models = models.replace('ThermalStatus(ProcessInfo.processInfo.thermalState)', 'ThermalStatus(.nominal)')
(build / 'ProbeModels.swift').write_text(models + '\n' + resources)
PY
xcrun swiftc -O -D PANEL_UPDATES_PROBE -D HEALTH_ADVICE_PROBE -target arm64-apple-macosx14.0 \
  -module-cache-path "$build_dir/module-cache" \
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/CodexTranslations.swift" \
  "$build_dir/ProbeModels.swift" "$source_dir/MenuBarPreferences.swift" "$source_dir/Uptime.swift" "$source_dir/CPUUsageHistory.swift" "$source_dir/LiquidTabs.swift" \
  "$source_dir/DiskCleanup.swift" "$source_dir/DiskCleanupView.swift" "$source_dir/HealthAdvice.swift" "$source_dir/OnDeviceAdvice.swift" "$source_dir/HealthAdviceView.swift" \
  "$source_dir/Panel.swift" "$source_dir/DashboardLayout.swift" "$source_dir/DashboardWindow.swift" "$source_dir/PanelPresentationRequest.swift" "$project_dir/tests/probes/health_advice_probe.swift" \
  -Xlinker -weak_framework -Xlinker FoundationModels -framework AppKit -framework QuartzCore -o "$build_dir/health-advice-probe"
"$build_dir/health-advice-probe"
