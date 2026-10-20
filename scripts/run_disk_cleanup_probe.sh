#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir/module-cache"
xcrun swiftc -O -D DISK_CLEANUP_PROBE -target arm64-apple-macosx14.0 \
  -module-cache-path "$check_dir/module-cache" \
  "$project_dir/Sources/DiskCleanup.swift" \
  "$project_dir/tests/probes/disk_cleanup_probe.swift" \
  -framework UniformTypeIdentifiers -o "$check_dir/disk-cleanup-probe"
"$check_dir/disk-cleanup-probe"
