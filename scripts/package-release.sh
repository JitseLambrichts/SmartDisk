#!/bin/bash
# A clean archive contains only the finished app, license and instructions.
set -euo pipefail
cd "$(dirname "$0")/.."
notarize=false
build_args=(--arch "$(uname -m)")
for arg in "$@"; do
    case "$arg" in
        --notarize) notarize=true ;;
        --universal) build_args+=(--universal) ;;
        --help) echo "Usage: $0 [--universal] [--notarize]"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
if $notarize; then
    : "${SMARTDISK_SIGNING_IDENTITY:?Set your Developer ID Application identity}"
    : "${SMARTDISK_NOTARY_PROFILE:?Set your notarytool Keychain profile name}"
fi
scripts/build-app.sh "${build_args[@]}"
scripts/verify-app.sh dist/SmartDisk.app
version=$(defaults read "$PWD/dist/SmartDisk.app/Contents/Info" CFBundleShortVersionString)
arch=$(lipo -archs dist/SmartDisk.app/Contents/MacOS/SmartDisk)
case "$arch" in
    *arm64*x86_64*|*x86_64*arm64*) platform=universal ;;
    *arm64*) platform=apple-silicon ;;
    *) platform=intel ;;
esac
staging=$(mktemp -d "$PWD/dist/.package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto dist/SmartDisk.app "$staging/SmartDisk.app"
cp docs/INSTALL.txt "$staging/READ ME FIRST.txt"
cp LICENSE "$staging/LICENSE.txt"
python3 scripts/third-party-notices.py "$staging/THIRD-PARTY NOTICES.txt"
if $notarize; then
    ditto -c -k --keepParent "$staging/SmartDisk.app" "$staging/submission.zip"
    xcrun notarytool submit "$staging/submission.zip" --keychain-profile "$SMARTDISK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$staging/SmartDisk.app"
    xcrun stapler validate "$staging/SmartDisk.app"
    spctl --assess --type execute --verbose=2 "$staging/SmartDisk.app"
    rm "$staging/submission.zip"
    cp docs/INSTALL-NOTARIZED.txt "$staging/READ ME FIRST.txt"
fi
filename="SmartDisk-$version-macOS-$platform.zip"
ditto -c -k --norsrc "$staging" "dist/$filename"
(cd dist && shasum -a 256 "$filename" > "$filename.sha256")
echo "Ready to share: dist/$filename"
if ! $notarize; then
    echo "This build is not notarized. First-open instructions are included."
fi
