#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
helper_dir="$project_dir/build/fan-helper"
mkdir -p "$helper_dir/module-cache"
xcrun clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -c "$project_dir/Helper/FanHardware.c" -o "$helper_dir/FanHardware.o"
xcrun swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$helper_dir/module-cache" \
  -import-objc-header "$project_dir/Helper/FanHardware.h" \
  "$project_dir/Sources/FanBoost.swift" "$project_dir/Sources/FanControlProtocol.swift" \
  "$project_dir/Helper/FanServiceCore.swift" "$project_dir/Helper/FanRootStore.swift" "$project_dir/Helper/main.swift" \
  "$helper_dir/FanHardware.o" -framework Foundation -framework IOKit -framework CoreFoundation \
  -o "$helper_dir/local.mac-thermal.fan-helper"
codesign --force --sign - --options runtime --identifier local.mac-thermal.fan-helper "$helper_dir/local.mac-thermal.fan-helper"
codesign --verify --strict "$helper_dir/local.mac-thermal.fan-helper"
/usr/bin/python3 - "$helper_dir" <<'PY'
from pathlib import Path
import re, subprocess, sys
folder=Path(sys.argv[1])
info=subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(folder/'local.mac-thermal.fan-helper')],capture_output=True,text=True,check=True)
match=re.search(r'^CDHash=([a-f0-9]{40,64})$',info.stderr,re.M)
if not match: raise SystemExit('No helper code hash; refusing to prepare an unauthenticated helper')
(folder/'FanHelper.cdhash').write_text(match.group(1)+'\n')
PY
print -- "Built and signed fan helper; not installed or executed."
