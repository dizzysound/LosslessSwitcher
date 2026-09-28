#!/bin/bash
# Build "LosslessSwitcher Dev" for another Mac into <dest> (default ~/Desktop/LosslessSwitcher Dev):
# the app plus "Set Up (run once).command", which puts MediaRemoteAdapter's resource bundle where the
# binary looks for it (/Users/Shared/LosslessSwitcher-dev-build/..., see make_dev_app.sh) and clears
# the quarantine flag (the app is ad-hoc signed). arm64 only.
set -e
cd "$(dirname "$0")"
DEST=${1:-"$HOME/Desktop/LosslessSwitcher Dev"}
BP=/Users/Shared/LosslessSwitcher-dev-build
CONFIG=release BUILD_PATH=$BP ./make_dev_app.sh >/dev/null
cat ".build/LosslessSwitcher Dev.app/Contents/MacOS/"* | strings | grep -q "$BP/arm64-apple-macosx/release/MediaRemoteAdapter_MediaRemoteAdapter.bundle" \
  || { echo "the binary doesn't point at $BP"; exit 1; }
rm -rf "$DEST"; mkdir -p "$DEST"
ditto ".build/LosslessSwitcher Dev.app" "$DEST/LosslessSwitcher Dev.app"
cat > "$DEST/Set Up (run once).command" <<SH
#!/bin/bash
# Run once on the Mac that will use LosslessSwitcher Dev (double-click; Terminal opens).
cd "\$(dirname "\$0")"
APP="\$PWD/LosslessSwitcher Dev.app"
xattr -dr com.apple.quarantine "\$APP" 2>/dev/null
mkdir -p "$BP/arm64-apple-macosx/release"
rm -rf "$BP/arm64-apple-macosx/release/MediaRemoteAdapter_MediaRemoteAdapter.bundle"
cp -R "\$APP/Contents/Resources/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$BP/arm64-apple-macosx/release/"
echo "Set up. Open LosslessSwitcher Dev, then in its menu: Virtual Output Device > Install..., and"
echo "Renderer Engine (Experimental). Quit the regular LosslessSwitcher first if it is running."
SH
chmod +x "$DEST/Set Up (run once).command"
cat > "$DEST/README.txt" <<TXT
LosslessSwitcher Dev (branch renderer-vdevice of dizzysound/LosslessSwitcher, $(git -C ../.. rev-parse --short HEAD), built $(date '+%Y-%m-%d %H:%M')).
Apple Silicon only. Ad-hoc signed: each copy asks again for Microphone and Automation (Music).

1. Copy this folder anywhere on the test Mac (the app must stay next to nothing in particular).
2. Double-click "Set Up (run once).command" (right-click > Open if macOS refuses).
3. Quit the regular LosslessSwitcher if it runs, then open "LosslessSwitcher Dev.app".
4. Its menu-bar item (a music note; on a notched MacBook it can hide under the notch):
   Virtual Output Device > Install... (administrator password; audio restarts for a moment),
   then Renderer Engine (Experimental) to turn the engine on. Allow Microphone and Automation.
Engine log: ~/Library/Logs/LosslessSwitcher-Renderer.log
Remove: menu Virtual Output Device > Remove..., then delete the app and /Users/Shared/LosslessSwitcher-dev-build.
TXT
echo "$DEST"
