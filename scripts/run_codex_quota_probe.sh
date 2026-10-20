#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/codex-quota-check"
mkdir -p "$check_dir/module-cache"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Sources/CodexModels.swift" "$project_dir/Sources/CodexAccount.swift" \
 "$project_dir/tests/probes/codex_quota_probe.swift" -framework Security -o "$check_dir/codex-quota-probe"
"$check_dir/codex-quota-probe" "$@"
