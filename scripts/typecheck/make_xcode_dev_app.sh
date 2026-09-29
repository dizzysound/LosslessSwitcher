#!/bin/bash
# Bench build for another Mac, with Xcode: "LosslessSwitcher Dev.app" (bundle id
# com.dizzysound.LosslessSwitcher.dev, beside the regular app) zipped with a README into <dest>
# (default ~/Desktop/LosslessSwitcher-Dev-<commit>.zip). Universal (arm64 + x86_64).
# Unlike make_portable_dev_app.sh no setup script is needed: Xcode embeds MediaRemoteAdapter's
# resource bundle in the app. Ad-hoc signed with the hardened runtime OFF: with it on, library
# validation refuses the embedded ad-hoc MediaRemoteAdapter.framework ("different Team IDs",
# dyld "Library missing" at launch). A Developer ID build (hardened runtime, notarized) needs a
# paid Apple Developer account.
set -e
cd "$(dirname "$0")/../.."
REV=$(git rev-parse --short HEAD)
DEST=${1:-"$HOME/Desktop/LosslessSwitcher-Dev-$REV.zip"}
DD=$(mktemp -d /tmp/ls-xcode.XXXX)
xcodebuild -project Quality.xcodeproj -scheme LosslessSwitcher -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.dizzysound.LosslessSwitcher.dev LS_GIT_COMMIT="$REV$(git diff --quiet HEAD -- Quality HALPlugin || echo -dirty)" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
OUT="$DD/out"; mkdir -p "$OUT"
ditto "$DD/Build/Products/Release/LosslessSwitcher.app" "$OUT/LosslessSwitcher Dev.app"
codesign --verify --deep --strict "$OUT/LosslessSwitcher Dev.app"
P="$OUT/LosslessSwitcher Dev.app/Contents/Resources/LSOutput.driver/Contents/Info.plist"
[ "$(stat -f %Lp "$P")" = 644 ] || { echo "LSOutput.driver Info.plist is not world-readable"; exit 1; }
cat > "$OUT/README.txt" <<TXT
LosslessSwitcher Dev (branch $(git rev-parse --abbrev-ref HEAD) of dizzysound/LosslessSwitcher, $REV, Xcode build $(date '+%Y-%m-%d %H:%M')).
Universal (Apple Silicon and Intel). Ad-hoc signed: each copy asks again for Microphone and Automation (Music).

1. Unzip anywhere local (~/Applications is good; not an iCloud-synced Desktop or Documents).
2. Right-click the app > Open the first time (or: xattr -dr com.apple.quarantine "LosslessSwitcher Dev.app").
3. Quit the regular LosslessSwitcher if it runs, then open LosslessSwitcher Dev. No setup script is needed.
4. Menu-bar item (a music note; on a notched MacBook it can hide under the notch):
   Install Exclusive Mode Driver... (administrator password; audio restarts for a moment; it turns
   Exclusive Mode on). Allow Microphone and Automation.
Engine log: ~/Library/Logs/LosslessSwitcher-ExclusiveMode.log
Remove: menu Advanced > Virtual Output Device > Remove..., then delete the app.
What to test, the rules and what's already known: BENCH-BRIEF.md.
TXT
cp research/renderer-engine/BENCH-BRIEF.md "$OUT/BENCH-BRIEF.md"
rm -f "$DEST"
(cd "$OUT" && ditto -c -k --sequesterRsrc . "$DEST")
rm -rf "$DD"
echo "$DEST"
