#!/bin/zsh
# Builds vrender.swift into VRender.app: reading the virtual device's loopback input needs the
# Microphone permission, which tccd only grants (with a prompt) to an app, not to a CLI run from
# Claude Code. Run: open -W -a "$PWD/VRender.app" --args <vrender args> (stdout is lost: see <prefix>.log).
set -e; cd "${0:A:h}"
swiftc -O -import-objc-header vring.h vrender.swift -o vrender
A=VRender.app; rm -rf $A; mkdir -p $A/Contents/MacOS; cp vrender $A/Contents/MacOS/
cat > $A/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dizzysound.VRender</string>
<key>CFBundleName</key><string>VRender</string>
<key>CFBundleExecutable</key><string>vrender</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSAppleEventsUsageDescription</key><string>Pauses, rewinds and resumes Music around a DAC sample-rate switch.</string>
<key>NSMicrophoneUsageDescription</key><string>Reads Music's audio back from the LosslessSwitcher Output virtual device and plays it to the DAC (renderer prototype).</string>
</dict></plist>
PLIST
codesign -s - --force $A 2>&1 | { grep -v "replacing existing" || true; }
echo "$PWD/$A"
