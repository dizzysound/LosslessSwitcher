#!/bin/bash
# User actions during the switcher's wait: press play 0.8 s after a rate-changing track starts,
# then skip to another rate-changing track 0.8 s after the next one starts.
set -u
BIN="../typecheck/.build/Nativerate Dev.app/Contents/MacOS/Nativerate"
script -q -F app_intervene.log "$BIN" >/dev/null 2>&1 & APP=$!
sleep 12; pgrep -f "Nativerate Dev.app/Contents/MacOS" >/dev/null && echo "app up" || echo "APP NOT RUNNING"
play() { osascript -e "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"$1\")"; }
echo "== play pressed during wait"; play C79A30CC28CE5BF7; sleep 0.8; osascript -e 'tell application "Music" to play'; sleep 5
osascript -e 'tell application "Music" to get (player state as string) & " " & name of current track'
echo "== skip during wait"; play AE57AD96DC95CAB1; sleep 0.8; play A485A3F165BE6CC2; sleep 6
osascript -e 'tell application "Music" to get (player state as string) & " " & name of current track'
kill $APP; wait $APP 2>/dev/null
