#!/bin/zsh
set -euo pipefail
[[ "${1:-}" == --live && $# == 1 ]] || { print -u2 -- "Usage: $0 --live (reads numeric fan keys only; never changes fan settings)"; exit 2; }
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/checks"
mkdir -p "$check_dir"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  "$project_dir/scripts/fan-readonly-preflight.c" -framework IOKit -framework CoreFoundation \
  -o "$check_dir/fan-readonly-preflight"
"$check_dir/fan-readonly-preflight"
