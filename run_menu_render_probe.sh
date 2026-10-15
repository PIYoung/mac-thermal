#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
build_dir="$project_dir/build"
mkdir -p "$build_dir" "$build_dir/menu-previews"
/usr/bin/python3 - "$project_dir" <<'PY'
from pathlib import Path
import sys
project = Path(sys.argv[1])
main = (project / 'main.swift').read_text().split('final class AppDelegate:', 1)[0]
resources = (project / 'Resources.swift').read_text().split('enum ResourceSampler', 1)[0]
(project / 'build' / 'ProbeModels.swift').write_text(main + '\n' + resources)
PY
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  "$project_dir/Localization.swift" "$project_dir/PanelTranslations.swift" "$project_dir/SystemTranslations.swift" \
  "$build_dir/ProbeModels.swift" "$project_dir/MenuBarPreferences.swift" \
  "$project_dir/MenuBarContent.swift" "$project_dir/menu_render_probe.swift" \
  -framework AppKit -framework QuartzCore -o "$build_dir/menu_render_probe"
"$build_dir/menu_render_probe" "$build_dir/menu-previews" 2> "$build_dir/menu-render-probe.log"
