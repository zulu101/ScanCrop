#!/bin/bash
# Builds ScanCrop.app (release, universal: Apple silicon + Intel) into ./build/
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP="build/ScanCrop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ScanCrop" "$APP/Contents/MacOS/ScanCrop"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Localizations (English is the development language; German translation in de.lproj)
cp -R Resources/en.lproj Resources/de.lproj "$APP/Contents/Resources/"

VERSION="${VERSION:-0.1.0}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ScanCrop</string>
    <key>CFBundleDisplayName</key><string>ScanCrop</string>
    <key>CFBundleIdentifier</key><string>app.scancrop.ScanCrop</string>
    <key>CFBundleExecutable</key><string>ScanCrop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 zulu101 · MIT License</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (sufficient for local use)
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
