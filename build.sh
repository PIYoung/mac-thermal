#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
source_dir="$project_dir/Sources"
build_dir="$project_dir/build"
app_dir="$build_dir/Mac Thermal.app"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  print -u2 -- "Mac Thermal currently builds on Apple Silicon Macs only."
  exit 1
fi
if ! sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
  print -u2 -- "Install Xcode 26 or newer and select it with xcode-select before building."
  exit 1
fi
if (( ${sdk_version%%.*} < 26 )); then
  print -u2 -- "macOS SDK 26 or newer is required (selected SDK: $sdk_version)."
  exit 1
fi
for notice in LICENSE THIRD_PARTY_NOTICES.txt ASSET_PROVENANCE.md; do
  [[ -f "$project_dir/$notice" ]] || { print -u2 -- "Missing required notice: $notice"; exit 1; }
done

# The build directory contains generated files only. Start a fresh application
# bundle so removed resources cannot leak into a release.
rm -rf -- "$app_dir"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -c "$source_dir/ThermalSensors.c" -o "$build_dir/ThermalSensors.o"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -c "$source_dir/SystemMetrics.c" -o "$build_dir/SystemMetrics.o"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -c "$source_dir/ResourceMetrics.c" -o "$build_dir/ResourceMetrics.o"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -c "$source_dir/DiskMetrics.c" -o "$build_dir/DiskMetrics.o"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -c "$source_dir/GPUMetrics.c" -o "$build_dir/GPUMetrics.o"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" -import-objc-header "$source_dir/BridgingHeader.h" "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" "$source_dir/SystemTranslations.swift" "$source_dir/CleanupTranslations.swift" "$source_dir/LoginItem.swift" "$source_dir/Uptime.swift" "$source_dir/CPUUsageHistory.swift" "$source_dir/MenuBarPreferences.swift" "$source_dir/Resources.swift" "$source_dir/LiquidTabs.swift" "$source_dir/DiskCleanup.swift" "$source_dir/DiskCleanupView.swift" "$source_dir/Panel.swift" "$source_dir/MenuBarContent.swift" "$source_dir/DashboardWindow.swift" "$source_dir/PanelPresentationRequest.swift" "$source_dir/main.swift" "$build_dir/ThermalSensors.o" "$build_dir/SystemMetrics.o" "$build_dir/ResourceMetrics.o" "$build_dir/DiskMetrics.o" "$build_dir/GPUMetrics.o" -framework AppKit -framework QuartzCore -framework IOKit -framework CoreFoundation -framework ServiceManagement -o "$app_dir/Contents/MacOS/MacThermal"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/LICENSE" "$project_dir/THIRD_PARTY_NOTICES.txt" "$project_dir/ASSET_PROVENANCE.md" "$app_dir/Contents/Resources/"
xcrun swift -module-cache-path "$build_dir/module-cache" "$project_dir/scripts/DrawIcon.swift" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
print -r -- "$app_dir"
