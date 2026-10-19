#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
build_dir="$project_dir/build/panel-updates-check"
benchmark=false
baseline_panel=""
while (( $# )); do
  case "$1" in
    --benchmark) benchmark=true; shift ;;
    --baseline-panel)
      (( $# >= 2 )) || { print -u2 -- "--baseline-panel requires a local Panel.swift path"; exit 2; }
      baseline_panel="$2"; shift 2 ;;
    *) print -u2 -- "Usage: $0 [--benchmark [--baseline-panel /path/to/Panel.swift]]"; exit 2 ;;
  esac
done
if [[ -n "$baseline_panel" && "$benchmark" != true ]]; then
  print -u2 -- "--baseline-panel requires --benchmark"; exit 2
fi
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
common_sources=(
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/CodexTranslations.swift"
  "$build_dir/ProbeModels.swift" "$source_dir/MenuBarPreferences.swift" "$source_dir/Uptime.swift"
  "$source_dir/CPUUsageHistory.swift" "$source_dir/LiquidTabs.swift"
  "$project_dir/tests/probes/panel_updates_probe.swift"
)
xcrun swiftc -O -D PANEL_UPDATES_PROBE -target arm64-apple-macosx14.0 \
  -module-cache-path "$build_dir/module-cache" "${common_sources[@]}" \
  "$source_dir/DiskCleanup.swift" "$source_dir/DiskCleanupView.swift" "$source_dir/Panel.swift" "$source_dir/DashboardLayout.swift" "$source_dir/DashboardWindow.swift" \
  -framework AppKit -framework QuartzCore -o "$build_dir/panel-updates-probe"
if [[ "$benchmark" == true ]]; then
  if [[ -n "$baseline_panel" ]]; then
    # The baseline is supplied as a reviewed local source file; never fetched.
    xcrun swiftc -O -D PANEL_UPDATES_BASELINE -target arm64-apple-macosx14.0 \
      -module-cache-path "$build_dir/module-cache" "${common_sources[@]}" "$baseline_panel" \
      -framework AppKit -framework QuartzCore -o "$build_dir/panel-updates-baseline"
    "$build_dir/panel-updates-baseline" --benchmark
  fi
  "$build_dir/panel-updates-probe" --benchmark
else
  "$build_dir/panel-updates-probe"
fi
