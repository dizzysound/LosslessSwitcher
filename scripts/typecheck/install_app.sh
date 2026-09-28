#!/bin/bash
# Build a release LosslessSwitcher with SwiftPM (no Xcode) and install it to /Applications.
# - Build path is outside the repo: SwiftPM's resource accessor for MediaRemoteAdapter looks for its
#   bundle at <app>/MediaRemoteAdapter_MediaRemoteAdapter.bundle (which codesign rejects) or at the
#   compiled-in build path. Deleting $BP breaks track-change detection.
# - Info.plist, icon and asset catalog come from the existing install (or the backup), since actool
#   and Xcode's Info.plist generation aren't available here.
# - The existing app is zipped to $BACKUP_DIR first.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
BP="$HOME/Library/Application Support/LosslessSwitcher-build"
DEST=/Applications/LosslessSwitcher.app
BACKUP_DIR="$HOME/Developer/LosslessSwitcher-backups"
SHA=$(git -C "$REPO" rev-parse --short HEAD)

rm -f Sources/LosslessSwitcher/*.swift
for f in "$REPO"/Quality/*.swift; do ln -s "$f" "Sources/LosslessSwitcher/$(basename "$f")"; done
swift build -c release --build-path "$BP" 2>&1 | grep -E "error:|Build complete" || true
BIN="$BP/release"
[ -x "$BIN/LosslessSwitcher" ] || { echo "build failed"; exit 1; }

# template for Info.plist and icons: current install, else the newest backup
TEMPLATE="$DEST"
if ! [ -d "$TEMPLATE" ]; then
  Z=$(ls -t "$BACKUP_DIR"/*.zip | head -1); TMPT=$(mktemp -d); ditto -x -k "$Z" "$TMPT"; TEMPLATE="$TMPT/LosslessSwitcher.app"
fi

STAGE=$(mktemp -d)/LosslessSwitcher.app
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN/LosslessSwitcher" "$BIN"/*.dylib "$STAGE/Contents/MacOS/"
cp -R "$BIN/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$STAGE/Contents/Resources/"
cp "$REPO/Quality/LosslessSwitcher.sdef" "$STAGE/Contents/Resources/"
for f in AppIcon.icns Assets.car; do [ -f "$TEMPLATE/Contents/Resources/$f" ] && cp "$TEMPLATE/Contents/Resources/$f" "$STAGE/Contents/Resources/"; done
cp "$TEMPLATE/Contents/Info.plist" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print NSAudioCaptureUsageDescription" "$STAGE/Contents/Info.plist" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add NSAudioCaptureUsageDescription string The Renderer Engine takes Music's audio from the output device and plays it back unchanged, so it can switch the sample rate without cutting tracks." "$STAGE/Contents/Info.plist"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$STAGE/Contents/Info.plist" | sed 's/-local.*//')
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VER-local-$SHA" "$STAGE/Contents/Info.plist"
codesign -s - --force --deep "$STAGE" 2>&1 | { grep -v "replacing existing" || true; }
codesign --verify --deep --strict "$STAGE"

osascript -e 'tell application id "com.vincent-neo.LosslessSwitcher" to quit' 2>/dev/null || true
osascript -e 'tell application id "com.dizzysound.LosslessSwitcher.dev" to quit' 2>/dev/null || true
sleep 1
if [ -d "$DEST" ] && ! /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist" | grep -q -- "-local-"; then
  mkdir -p "$BACKUP_DIR"
  OLD=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist")
  ditto -c -k --keepParent "$DEST" "$BACKUP_DIR/LosslessSwitcher-$OLD-upstream.zip"
  echo "backed up upstream $OLD to $BACKUP_DIR"
fi
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
echo "installed $DEST ($VER-local-$SHA)"
