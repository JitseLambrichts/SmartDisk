#!/bin/zsh
# Builds dist/SmartDisk.app: the SwiftUI app with `slim` and `slim-helper` inside.
#   scripts/build-app.sh            # mirror-folder drive (no install needed)
#   scripts/build-app.sh --fuse     # also a real drive via FUSE-T / macFUSE
set -euo pipefail
cd "${0:A:h}/.."

features=()
[[ "${1:-}" == "--fuse" ]] && features=(--features fuse)

cargo build --release "${features[@]}"
(cd macos && swift build -c release)

app=dist/SmartDisk.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/.build/release/SmartDisk "$app/Contents/MacOS/SmartDisk"
cp macos/.build/release/slim-helper "$app/Contents/MacOS/slim-helper"
cp target/release/slim "$app/Contents/MacOS/slim"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Smart Disk</string>
  <key>CFBundleDisplayName</key><string>Smart Disk</string>
  <key>CFBundleIdentifier</key><string>dev.smartdisk.app</string>
  <key>CFBundleExecutable</key><string>SmartDisk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDocumentsFolderUsageDescription</key><string>Smart Disk reads the folders you choose to sort files by what is in them. Files never leave your Mac.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Smart Disk reads the folders you choose to sort files by what is in them. Files never leave your Mac.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Smart Disk reads the folders you choose to sort files by what is in them. Files never leave your Mac.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs the bundle locally (use a Developer ID for distribution).
codesign --force --deep --sign - "$app"
echo "Built $app"
