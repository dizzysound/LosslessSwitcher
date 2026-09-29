#!/bin/bash
# Wraps tapcapture in an app bundle so macOS attributes the System Audio Recording permission to it
# (a CLI run from another app inherits that app's TCC identity and can't prompt).
set -e; cd "$(dirname "$0")"
swiftc -O tapcapture.swift -o tapcapture
A=TapCapture.app; rm -rf $A; mkdir -p $A/Contents/MacOS; cp tapcapture $A/Contents/MacOS/
cat > $A/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dizzysound.TapCapture</string>
<key>CFBundleName</key><string>TapCapture</string>
<key>CFBundleExecutable</key><string>tapcapture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Records Music's audio to test whether a process tap is bit-exact.</string>
</dict></plist>
PLIST
codesign -s - --force $A 2>&1 | { grep -v "replacing existing" || true; }
echo "$PWD/$A"
