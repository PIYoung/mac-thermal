#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
check_dir="$project_dir/build/codex-reset-check"
mkdir -p "$check_dir/module-cache"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$check_dir/module-cache" \
 "$project_dir/Sources/Localization.swift" "$project_dir/Sources/PanelTranslations.swift" \
 "$project_dir/Sources/SystemTranslations.swift" "$project_dir/Sources/CleanupTranslations.swift" "$project_dir/Sources/CodexTranslations.swift" \
 "$project_dir/Sources/CodexModels.swift" "$project_dir/Sources/CodexResetNotifications.swift" \
 "$project_dir/tests/probes/codex_reset_notifications_probe.swift" \
 -framework AppKit -framework UserNotifications -o "$check_dir/codex-reset-probe"
"$check_dir/codex-reset-probe"
