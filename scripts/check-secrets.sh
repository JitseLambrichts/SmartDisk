#!/bin/bash
# Pin and verify the scanner; never print detected secret values.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
version=8.30.1
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        platform=darwin_arm64
        checksum=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
    Darwin-x86_64)
        platform=darwin_x64
        checksum=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
    Linux-x86_64)
        platform=linux_x64
        checksum=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    *) echo "Install Gitleaks $version and scan this platform manually." >&2; exit 1 ;;
esac
archive="gitleaks_${version}_${platform}.tar.gz"
curl --fail --silent --show-error --location "https://github.com/gitleaks/gitleaks/releases/download/v$version/$archive" -o "$work/$archive"
actual=$(shasum -a 256 "$work/$archive" | awk '{print $1}')
test "$actual" = "$checksum"
tar -xzf "$work/$archive" -C "$work" gitleaks
"$work/gitleaks" git --redact --no-banner --log-opts=--all .
# Scan the actual tracked/unignored worktree too, including uncommitted changes.
python3 - "$work/source" <<'PY'
import pathlib, shutil, subprocess, sys
dest = pathlib.Path(sys.argv[1])
dest.mkdir()
paths = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'])
for raw in set(paths.split(b'\0')):
    if not raw:
        continue
    path = pathlib.Path(raw.decode())
    if path.is_file() and not path.is_symlink():
        target = dest / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
PY
"$work/gitleaks" dir --redact --no-banner "$work/source"
echo "Secret scans passed for history and the current source tree."
