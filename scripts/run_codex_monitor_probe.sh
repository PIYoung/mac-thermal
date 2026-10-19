#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir/module-cache"
xcrun swiftc -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Sources/CodexModels.swift" "$project_dir/Sources/CodexMonitor.swift" \
  "$project_dir/tests/probes/codex_monitor_probe.swift" \
  -framework AppKit -o "$check_dir/codex-monitor-probe"
"$check_dir/codex-monitor-probe"
