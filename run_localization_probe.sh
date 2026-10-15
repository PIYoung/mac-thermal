#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
build_dir="$project_dir/build/localization-check"
mkdir -p "$build_dir"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  "$project_dir/Localization.swift" "$project_dir/PanelTranslations.swift" "$project_dir/SystemTranslations.swift" "$project_dir/Uptime.swift" "$project_dir/localization_probe.swift" \
  -framework AppKit -o "$build_dir/localization_probe"
"$build_dir/localization_probe" "$project_dir"
