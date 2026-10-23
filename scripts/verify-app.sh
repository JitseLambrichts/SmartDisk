#!/bin/bash
set -euo pipefail
app="${1:-dist/SmartDisk.app}"
[[ "$app" == /* ]] || app="$PWD/$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
for binary in SmartDisk slim slim-helper; do
    executable="$app/Contents/MacOS/$binary"
    test -x "$executable"
    file "$executable"
    if otool -L "$executable" | awk '/^[[:space:]]/ { print $1 }' | /usr/bin/grep -Ev '^(/usr/lib/|/System/Library/)'; then
        echo "Unexpected external library in $binary" >&2; exit 1
    fi
done
test -s "$app/Contents/Resources/AppIcon.icns"
test -s "$app/Contents/Resources/SmartDiskLogo.png"
test "$(defaults read "$app/Contents/Info" CFBundleDevelopmentRegion)" = en
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT
SLIM_HOME="$test_home" "$app/Contents/MacOS/slim" status --json > "$test_home/status.json"
python3 - "$test_home/status.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state['config']['folders'] == [], 'First launch must ask users to choose source folders'
assert state['files_indexed'] == 0, 'A release must not contain an index'
PY
"$app/Contents/MacOS/slim-helper" capabilities > /dev/null
echo "App verification passed."
