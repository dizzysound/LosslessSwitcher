#!/bin/bash
# trial_gapless.sh <name> <track> <seconds before end> [renderer options]: starts the renderer, then
# the temp playlist (startup), steps to <track>, seeks near its end so Music rolls gaplessly into
# the next track, and records 45 s in all.
cd "$(dirname "$0")"; name=$1 track=$2 before=$3; shift 3; rm -f runs/$name.*
open -W -a "$PWD/Renderer.app" --args 45 "$PWD/runs/$name" "$PWD/runs/$name.log" "$@" &
sleep 2; ./gapless_seek.sh "$track" "$before"
wait; osascript -e 'tell application "Music" to pause'
grep -vE "IO stalled|IO resumed" runs/$name.log
