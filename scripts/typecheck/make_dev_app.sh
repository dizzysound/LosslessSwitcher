#!/bin/bash
# Wrap the SwiftPM build in a minimal ad-hoc-signed .app so Bundle.main has an Info.plist.
# Uses its own bundle id (and so its own defaults domain) to stay clear of the installed app.
# CONFIG=release builds optimized (RendererEngine's IO loop wants it at high sample rates).
set -e
CONFIG=${CONFIG:-debug}
cd "$(dirname "$0")"; swift build -c "$CONFIG" >/dev/null
APP=".build/LosslessSwitcher Dev.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/$CONFIG/LosslessSwitcher .build/$CONFIG/*.dylib "$APP/Contents/MacOS/"
cp -R .build/$CONFIG/MediaRemoteAdapter_MediaRemoteAdapter.bundle "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dizzysound.LosslessSwitcher.dev</string>
<key>CFBundleName</key><string>LosslessSwitcher Dev</string>
<key>CFBundleExecutable</key><string>LosslessSwitcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>dev</string>
<key>CFBundleVersion</key><string>0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>This permission is required for local file sample rate detection.</string>
<key>NSAudioCaptureUsageDescription</key><string>The Renderer Engine takes Music's audio from the output device and plays it back unchanged, so it can switch the sample rate without cutting tracks.</string>
</dict></plist>
PLIST
codesign -s - --force --deep "$APP" 2>&1 | { grep -v "replacing existing" || true; }
echo "$PWD/$APP"
