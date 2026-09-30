#!/bin/bash
# Bench build for another Mac, with Xcode: "Nativerate Dev.app" (bundle id
# com.dizzysound.Nativerate.dev, beside the regular app) zipped with a README into <dest>
# (default ~/Desktop/Nativerate-Dev-<commit>.zip). Universal (arm64 + x86_64).
# Unlike make_portable_dev_app.sh no setup script is needed: Xcode embeds MediaRemoteAdapter's
# resource bundle in the app. Ad-hoc signed with the hardened runtime OFF: with it on, library
# validation refuses the embedded ad-hoc MediaRemoteAdapter.framework ("different Team IDs",
# dyld "Library missing" at launch). A Developer ID build (hardened runtime, notarized) needs a
# paid Apple Developer account.
set -e
cd "$(dirname "$0")/../.."
REV=$(git rev-parse --short HEAD)
DEST=${1:-"$HOME/Desktop/Nativerate-Dev-$REV.zip"}
DD=$(mktemp -d /tmp/ls-xcode.XXXX)
xcodebuild -project Nativerate.xcodeproj -scheme Nativerate -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.dizzysound.Nativerate.dev LS_GIT_COMMIT="$REV$(git diff --quiet HEAD -- Nativerate HALPlugin || echo -dirty)" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
OUT="$DD/out"; mkdir -p "$OUT"
ditto "$DD/Build/Products/Release/Nativerate.app" "$OUT/Nativerate Dev.app"
codesign --verify --deep --strict "$OUT/Nativerate Dev.app"
P="$OUT/Nativerate Dev.app/Contents/Resources/LSOutput.driver/Contents/Info.plist"
[ "$(stat -f %Lp "$P")" = 644 ] || { echo "LSOutput.driver Info.plist is not world-readable"; exit 1; }
cat > "$OUT/README.txt" <<TXT
Nativerate Dev (branch $(git rev-parse --abbrev-ref HEAD) of dizzysound/Nativerate, $REV, Xcode build $(date '+%Y-%m-%d %H:%M')).
Universal (Apple Silicon and Intel). Ad-hoc signed: each copy asks again for Microphone and Automation (Music).

1. Unzip anywhere local (~/Applications is good; not an iCloud-synced Desktop or Documents).
2. Right-click the app > Open the first time (or: xattr -dr com.apple.quarantine "Nativerate Dev.app").
3. Quit the regular Nativerate if it runs, then open Nativerate Dev. No setup script is needed.
4. Menu-bar item (a music note; on a notched MacBook it can hide under the notch):
   Install Exclusive Mode Driver... (administrator password; audio restarts for a moment; it turns
   Exclusive Mode on). Allow Microphone and Automation.
Engine log: ~/Library/Logs/Nativerate-ExclusiveMode.log
Remove: menu Advanced > Virtual Output Device > Remove..., then delete the app.
What to test, the rules and what's already known: BENCH-BRIEF.md.
TXT
cp research/renderer-engine/BENCH-BRIEF.md "$OUT/BENCH-BRIEF.md"
rm -f "$DEST"
(cd "$OUT" && ditto -c -k --sequesterRsrc . "$DEST")
rm -rf "$DD"
echo "$DEST"
