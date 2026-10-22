#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/fan-service-check"
mkdir -p "$check_dir/module-cache"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Sources/FanBoost.swift" "$project_dir/Sources/FanControlProtocol.swift" \
  "$project_dir/Helper/FanServiceCore.swift" "$project_dir/tests/probes/fan_service_probe.swift" \
  -o "$check_dir/fan-service-probe"
"$check_dir/fan-service-probe"
