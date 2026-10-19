#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror \
  -mmacosx-version-min=14.0 "$project_dir/tests/probes/gpu_metrics_probe.c" \
  -framework IOKit -framework CoreFoundation -o "$check_dir/gpu-metrics-probe"
"$check_dir/gpu-metrics-probe"

# Live reads are opt-in; CI only executes deterministic synthetic fixtures.
if [[ "${1:-}" == --live ]]; then
  xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror \
    -mmacosx-version-min=14.0 -I"$project_dir/Sources" \
    "$project_dir/tests/probes/gpu_metrics_live_probe.c" \
    "$project_dir/Sources/GPUMetrics.c" -framework IOKit -framework CoreFoundation \
    -o "$check_dir/gpu-metrics-live-probe"
  "$check_dir/gpu-metrics-live-probe"
fi
