#!/bin/bash
# Build a release Nativerate with SwiftPM (no Xcode) and install it to /Applications.
# - Build path is outside the repo: SwiftPM's resource accessor for MediaRemoteAdapter looks for its
#   bundle at <app>/MediaRemoteAdapter_MediaRemoteAdapter.bundle (which codesign rejects) or at the
#   compiled-in build path. Deleting $BP breaks track-change detection.
# - Info.plist, icon and asset catalog come from the existing install (or the backup), since actool
#   and Xcode's Info.plist generation aren't available here.
# - The existing app is zipped to $BACKUP_DIR first.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
BP="$HOME/Library/Application Support/Nativerate-build"
DEST=/Applications/Nativerate.app
BACKUP_DIR="$HOME/Developer/LosslessSwitcher-backups" # holds the pre-rename app zips the template comes from
SHA=$(git -C "$REPO" rev-parse --short HEAD)

rm -f Sources/Nativerate/*.swift
for f in "$REPO"/Nativerate/*.swift; do ln -s "$f" "Sources/Nativerate/$(basename "$f")"; done
swift build -c release --build-path "$BP" 2>&1 | grep -E "error:|Build complete" || true
BIN="$BP/release"
[ -x "$BIN/Nativerate" ] || { echo "build failed"; exit 1; }

# template for Info.plist and icons: current install, else the newest backup
TEMPLATE="$DEST"
if ! [ -d "$TEMPLATE" ]; then
  Z=$(ls -t "$BACKUP_DIR"/*.zip | head -1); TMPT=$(mktemp -d); ditto -x -k "$Z" "$TMPT"; TEMPLATE="$TMPT/LosslessSwitcher.app"
fi

STAGE=$(mktemp -d)/Nativerate.app
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN/Nativerate" "$BIN"/*.dylib "$STAGE/Contents/MacOS/"
cp -R "$BIN/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$STAGE/Contents/Resources/"
cp "$REPO/Nativerate/Nativerate.sdef" "$STAGE/Contents/Resources/"
"$REPO/HALPlugin/build.sh" >/dev/null && cp -R "$REPO/HALPlugin/LSOutput.driver" "$STAGE/Contents/Resources/"
for f in AppIcon.icns Assets.car; do [ -f "$TEMPLATE/Contents/Resources/$f" ] && cp "$TEMPLATE/Contents/Resources/$f" "$STAGE/Contents/Resources/"; done
cp "$TEMPLATE/Contents/Info.plist" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print NSAudioCaptureUsageDescription" "$STAGE/Contents/Info.plist" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add NSAudioCaptureUsageDescription string Exclusive Mode takes Music's audio from the output device and plays it back unchanged, so it can switch the sample rate without cutting tracks." "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print NSMicrophoneUsageDescription" "$STAGE/Contents/Info.plist" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add NSMicrophoneUsageDescription string Exclusive Mode reads Music's audio back from the Nativerate virtual device (its loopback input) to play it to your DAC unchanged." "$STAGE/Contents/Info.plist"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$STAGE/Contents/Info.plist" | sed 's/-local.*//')
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VER-local-$SHA" "$STAGE/Contents/Info.plist"
codesign -s - --force --deep "$STAGE" 2>&1 | { grep -v "replacing existing" || true; }
codesign --verify --deep --strict "$STAGE"

osascript -e 'tell application id "com.dizzysound.Nativerate" to quit' 2>/dev/null || true
osascript -e 'tell application id "com.dizzysound.Nativerate.dev" to quit' 2>/dev/null || true
# the pre-rename app (before Nativerate): quit it too
osascript -e 'tell application id "com.vincent-neo.LosslessSwitcher" to quit' 2>/dev/null || true
osascript -e 'tell application id "com.dizzysound.LosslessSwitcher.dev" to quit' 2>/dev/null || true
sleep 1
if [ -d "$DEST" ] && ! /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist" | grep -q -- "-local-"; then
  mkdir -p "$BACKUP_DIR"
  OLD=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist")
  ditto -c -k --keepParent "$DEST" "$BACKUP_DIR/Nativerate-$OLD-upstream.zip"
  echo "backed up upstream $OLD to $BACKUP_DIR"
fi
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
echo "installed $DEST ($VER-local-$SHA)"
