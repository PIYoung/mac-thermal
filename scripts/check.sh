#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir"

# Compile the application and all native collectors with strict C warnings.
zsh "$project_dir/build.sh"
zsh "$project_dir/scripts/run_localization_probe.sh"
zsh "$project_dir/scripts/run_menu_render_probe.sh"
zsh "$project_dir/scripts/run_process_ranking_probe.sh"
zsh "$project_dir/scripts/run_thermal_fallback_probe.sh"
zsh "$project_dir/scripts/run_fan_metrics_probe.sh"
zsh "$project_dir/scripts/run_gpu_metrics_probe.sh"
zsh "$project_dir/scripts/run_panel_updates_probe.sh"
zsh "$project_dir/scripts/run_panel_presentation_probe.sh"
zsh "$project_dir/scripts/run_dashboard_layout_probe.sh"
zsh "$project_dir/scripts/run_codex_monitor_probe.sh"
zsh "$project_dir/scripts/run_codex_quota_probe.sh"
zsh "$project_dir/scripts/run_codex_reset_notifications_probe.sh"
zsh "$project_dir/scripts/run_codex_panel_probe.sh"
zsh "$project_dir/scripts/run_disk_cleanup_probe.sh"
zsh "$project_dir/scripts/run_disk_cleanup_ui_probe.sh"

# These probes use isolated preference suites and synthetic history samples.
# They do not enumerate other processes, read sensors, or change app settings.
xcrun swiftc -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$check_dir/module-cache" \
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" \
  "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/CodexTranslations.swift" "$source_dir/Uptime.swift" \
  "$source_dir/CPUUsageHistory.swift" "$project_dir/tests/probes/ui_metrics_probe.swift" \
  -framework AppKit -o "$check_dir/ui-metrics-probe"
"$check_dir/ui-metrics-probe"

print -- "Build, localization, CPU/GPU menu rendering, process ranking, thermal fallback, GPU parsing, paired panel layout/updates, bounded panel opening, Codex local-record parser/UI, uptime, usage history, and isolated disk cleanup checks passed."
