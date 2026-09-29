#!/bin/bash
# trial_rate.sh <name> <hz> <first track> <second track> [renderer options]: plays the first track,
# then pauses Music, has the renderer switch the device to <hz>, waits, and plays the second track.
cd "$(dirname "$0")"; name=$1 hz=$2 t1=$3 t2=$4; shift 4; rm -f runs/$name.*
play() { osascript -e "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"$1\")" >/dev/null; }
open -W -a "$PWD/Renderer.app" --args 32 "$PWD/runs/$name" "$PWD/runs/$name.log" "$@" &
sleep 2; play $t1; sleep 10
osascript -e 'tell application "Music" to pause'; echo "rate $hz" > runs/$name.cmd
sleep ${WAIT:-3}; play $t2
# REBUILD_AFTER=<s>: send the same rate again (forces a fresh tap + aggregate) after the 2nd track starts
if [ -n "$REBUILD_AFTER" ]; then sleep 1; ./procdevs > runs/$name.procdevs; sleep $REBUILD_AFTER; echo "rate $hz" >> runs/$name.cmd; fi
wait; osascript -e 'tell application "Music" to pause'
grep -v "IO stalled\|IO resumed" runs/$name.log
