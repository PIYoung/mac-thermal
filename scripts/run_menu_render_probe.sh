#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source_dir="$project_dir/Sources"
build_dir="$project_dir/build"
output_dir="$build_dir/menu-previews"
case "${1:-}" in
  ""|--benchmark) ;;
  *) print -u2 -- "Usage: zsh scripts/run_menu_render_probe.sh [--benchmark]"; exit 2 ;;
esac
(( $# <= 1 )) || { print -u2 -- "Too many arguments."; exit 2; }
mkdir -p "$build_dir" "$output_dir"
/usr/bin/python3 - "$project_dir" <<'PY'
from pathlib import Path
import sys
project = Path(sys.argv[1])
main = (project / 'Sources/main.swift').read_text().split('final class AppDelegate:', 1)[0]
resources = (project / 'Sources/Resources.swift').read_text().split('enum ResourceSampler', 1)[0]
(project / 'build' / 'ProbeModels.swift').write_text(main + '\n' + resources)
PY
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  "$source_dir/Localization.swift" "$source_dir/PanelTranslations.swift" "$source_dir/SystemTranslations.swift" \
  "$build_dir/ProbeModels.swift" "$source_dir/MenuBarPreferences.swift" \
  "$source_dir/MenuBarContent.swift" "$project_dir/tests/probes/menu_render_probe.swift" \
  -framework AppKit -framework QuartzCore -o "$build_dir/menu_render_probe"
"$build_dir/menu_render_probe" "$output_dir" "$@" 2> "$build_dir/menu-render-probe.log"
