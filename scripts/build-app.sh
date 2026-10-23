#!/bin/bash
# Build a self-contained app; signing credentials stay in Keychain/environment.
set -euo pipefail
cd "$(dirname "$0")/.."
architecture="$(uname -m)"
features=(--no-default-features)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal) architecture=universal ;;
        --arch) shift; architecture="${1:?Expected arm64, x86_64 or universal}" ;;
        --fuse) features+=(--features fuse) ;;
        --help) echo "Usage: $0 [--universal | --arch arm64|x86_64] [--fuse]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done
case "$architecture" in
    arm64|x86_64) architectures=("$architecture") ;;
    universal) architectures=(arm64 x86_64) ;;
    *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
esac
version=$(awk -F '"' '/^version = / { print $2; exit }' Cargo.toml)
identity="${SMARTDISK_SIGNING_IDENTITY:--}"
if [[ "$identity" != - && "$identity" != "Developer ID Application:"* ]]; then
    echo "Distribution signing requires a Developer ID Application identity." >&2; exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=26.0
mkdir -p dist
staging=$(mktemp -d "$PWD/dist/.app-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/SmartDisk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
app_binaries=(); helpers=(); cores=()
for arch in "${architectures[@]}"; do
    rust_arch="$arch"
    [[ "$arch" == arm64 ]] && rust_arch=aarch64
    target="$rust_arch-apple-darwin"
    if ! rustup target list --installed | /usr/bin/grep -qx "$target"; then
        echo "Install the compiler target first: rustup target add $target" >&2; exit 1
    fi
    cargo build --release --locked --target "$target" "${features[@]}"
    swift build --package-path macos -c release --triple "$arch-apple-macosx26.0"
    swift_bin=$(swift build --package-path macos -c release --triple "$arch-apple-macosx26.0" --show-bin-path)
    # Xcode's SwiftPM backend reuses one Products directory across triples.
    # Preserve each architecture before the next build replaces those files.
    cp "$swift_bin/SmartDisk" "$staging/SmartDisk-$arch"
    cp "$swift_bin/slim-helper" "$staging/slim-helper-$arch"
    app_binaries+=("$staging/SmartDisk-$arch")
    helpers+=("$staging/slim-helper-$arch")
    cores+=("target/$target/release/slim")
done
if [[ "$architecture" == universal ]]; then
    lipo -create "${app_binaries[@]}" -output "$app/Contents/MacOS/SmartDisk"
    lipo -create "${helpers[@]}" -output "$app/Contents/MacOS/slim-helper"
    lipo -create "${cores[@]}" -output "$app/Contents/MacOS/slim"
else
    cp "${app_binaries[0]}" "$app/Contents/MacOS/SmartDisk"
    cp "${helpers[0]}" "$app/Contents/MacOS/slim-helper"
    cp "${cores[0]}" "$app/Contents/MacOS/slim"
fi
cp macos/Resources/AppIcon.icns macos/Resources/SmartDiskLogo.png "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Smart Disk</string>
  <key>CFBundleDisplayName</key><string>Smart Disk</string>
  <key>CFBundleIdentifier</key><string>dev.smartdisk.app</string>
  <key>CFBundleExecutable</key><string>SmartDisk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>Smart Disk reads the folders you choose to organise files by their contents. Files stay on your Mac.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Smart Disk reads the folders you choose to organise files by their contents. Files stay on your Mac.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Smart Disk reads the folders you choose to organise files by their contents. Files stay on your Mac.</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
sign_options=(--force --sign "$identity")
[[ "$identity" != - ]] && sign_options+=(--options runtime --timestamp)
# Sign from the inside out. --deep is for verification, not signing.
codesign "${sign_options[@]}" "$app/Contents/MacOS/slim"
codesign "${sign_options[@]}" "$app/Contents/MacOS/slim-helper"
codesign "${sign_options[@]}" "$app"
codesign --verify --deep --strict "$app"
rm -rf dist/SmartDisk.app
mv "$app" dist/SmartDisk.app
echo "Built dist/SmartDisk.app ($architecture, version $version)"
