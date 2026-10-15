#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror \
  -mmacosx-version-min=14.0 "$project_dir/tests/probes/thermal_fallback_probe.c" \
  -framework IOKit -framework CoreFoundation -o "$check_dir/thermal-fallback-probe"
"$check_dir/thermal-fallback-probe"
