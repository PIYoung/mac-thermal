#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir"

# Compile the application and all native collectors with strict C warnings.
zsh "$project_dir/build.sh"
zsh "$project_dir/run_localization_probe.sh"
zsh "$project_dir/run_menu_render_probe.sh"

# These probes use isolated preference suites and synthetic history samples.
# They do not enumerate other processes, read sensors, or change app settings.
xcrun swiftc -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Localization.swift" "$project_dir/PanelTranslations.swift" \
  "$project_dir/SystemTranslations.swift" "$project_dir/Uptime.swift" \
  "$project_dir/CPUUsageHistory.swift" "$project_dir/ui_metrics_probe.swift" \
  -framework AppKit -o "$check_dir/ui-metrics-probe"
"$check_dir/ui-metrics-probe"

print -- "Build, localization, menu rendering, uptime, and CPU history checks passed."
