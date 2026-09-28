#!/bin/bash
# Wrap the SwiftPM build in a minimal ad-hoc-signed .app so Bundle.main has an Info.plist.
# Uses its own bundle id (and so its own defaults domain) to stay clear of the installed app.
# CONFIG=release builds optimized (RendererEngine's IO loop wants it at high sample rates).
# SANITIZE=address: ASan build. BUILD_PATH=<dir>: SwiftPM build path. MediaRemoteAdapter's resource
# accessor finds its bundle only in the .app root (codesign rejects that) or at the build path
# compiled into the binary, else it calls fatalError at launch; for another Mac build with
# BUILD_PATH=/Users/Shared/LosslessSwitcher-dev-build and run the setup script shipped beside the app
# there (see make_portable_dev_app.sh).
set -e
CONFIG=${CONFIG:-debug}
cd "$(dirname "$0")"
BP=${BUILD_PATH:-.build}
swift build -c "$CONFIG" --build-path "$BP" ${SANITIZE:+--sanitize=$SANITIZE} >/dev/null
APP=".build/LosslessSwitcher Dev.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BP/$CONFIG"/LosslessSwitcher "$BP/$CONFIG"/*.dylib "$APP/Contents/MacOS/"
cp -R "$BP/$CONFIG/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$APP/Contents/Resources/"
../../HALPlugin/build.sh >/dev/null && cp -R ../../HALPlugin/LSOutput.driver "$APP/Contents/Resources/"
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
<key>NSAudioCaptureUsageDescription</key><string>Exclusive Mode takes Music's audio from the output device and plays it back unchanged, so it can switch the sample rate without cutting tracks.</string>
<key>NSMicrophoneUsageDescription</key><string>Exclusive Mode reads Music's audio back from the LosslessSwitcher Output virtual device (its loopback input) to play it to your DAC unchanged.</string>
</dict></plist>
PLIST
codesign -s - --force --deep "$APP" 2>&1 | { grep -v "replacing existing" || true; }
echo "$PWD/$APP"
