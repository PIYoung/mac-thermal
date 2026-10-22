#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/fan-auth-check"
mkdir -p "$check_dir/module-cache"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$check_dir/module-cache" \
  "$project_dir/tests/probes/fan_xpc_auth_probe.swift" -framework Foundation -framework Security -o "$check_dir/fan-xpc-auth-probe"
codesign --force --sign - --options runtime "$check_dir/fan-xpc-auth-probe"
"$check_dir/fan-xpc-auth-probe"
