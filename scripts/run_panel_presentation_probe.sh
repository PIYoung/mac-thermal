#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir/module-cache"
xcrun swiftc -O -target arm64-apple-macosx14.0 \
  -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Sources/PanelPresentationRequest.swift" \
  "$project_dir/tests/probes/panel_presentation_probe.swift" \
  -o "$check_dir/panel-presentation-probe"
"$check_dir/panel-presentation-probe"
