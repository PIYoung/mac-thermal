#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
build_dir="$project_dir/build/localization-check"
mkdir -p "$build_dir"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/CodexTranslations.swift" "$source_dir/Uptime.swift" "$project_dir/tests/probes/localization_probe.swift" \
  -framework AppKit -o "$build_dir/localization_probe"
"$build_dir/localization_probe" "$project_dir"
