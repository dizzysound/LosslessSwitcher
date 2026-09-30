#!/bin/bash
# trial_midswitch.sh <track_pid> <out.wav>
# Nativerate's real sequence: Music launched at 44.1k, track starts at 44.1k, device -> 96k mid-track.
set -u
D="Loopback Audio"; PID=$1; OUT=$2
osascript -e 'tell application "Music" to quit' >/dev/null; while pgrep -x Music >/dev/null; do sleep 0.5; done
./audioctl set-rate "$D" 44100
open -g -a Music; until osascript -e 'tell application "Music" to get player state' >/dev/null 2>&1; do sleep 0.5; done; sleep 3
osascript -e "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"$PID\")"
sleep 1.5; ./audioctl set-rate "$D" 96000; sleep 1
sox -q -t coreaudio "$D" -r 96000 -b 24 "$OUT" trim 0 4
osascript -e 'tell application "Music" to stop'
