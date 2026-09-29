#!/bin/bash
# Builds renderer.swift into Renderer.app (needed for the System Audio Recording permission; see make_app.sh).
set -e; cd "$(dirname "$0")"
swiftc -O renderer.swift -o renderer
A=Renderer.app; rm -rf $A; mkdir -p $A/Contents/MacOS; cp renderer $A/Contents/MacOS/
cat > $A/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dizzysound.Renderer</string>
<key>CFBundleName</key><string>Renderer</string>
<key>CFBundleExecutable</key><string>renderer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Pauses and resumes Music while the DAC changes sample rate.</string>
<key>NSAudioCaptureUsageDescription</key><string>Taps Music's audio and plays it to the DAC (renderer prototype).</string>
</dict></plist>
PLIST
codesign -s - --force $A 2>&1 | { grep -v "replacing existing" || true; }
echo "$PWD/$A"
