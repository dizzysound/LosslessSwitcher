#!/bin/bash
# trial.sh <launch_rate> <play_rate> <out.wav>
# Quit Music, set Loopback to launch_rate, launch Music, switch to play_rate, record test track.
set -u
D="Loopback Audio"; LR=$1; PR=$2; OUT=$3; PID=$(cat test_track_pid.txt)
osascript -e 'tell application "Music" to quit' >/dev/null; while pgrep -x Music >/dev/null; do sleep 0.5; done
./audioctl set-rate "$D" "$LR"
open -g -a Music; until osascript -e 'tell application "Music" to get player state' >/dev/null 2>&1; do sleep 0.5; done; sleep 3
./audioctl set-rate "$D" "$PR"; sleep 1
sox -q -t coreaudio "$D" -r "$PR" -b 24 "$OUT" trim 0 6 &
REC=$!; sleep 0.5
osascript -e "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"$PID\")"
wait $REC
osascript -e 'tell application "Music" to stop'
echo "device rate during recording end: $(./audioctl rate "$D")"
log show --last 20s --style compact --predicate 'process == "Music" AND subsystem == "com.apple.coreaudio"' 2>/dev/null \
  | grep -E "ACAppleLosslessDecoder.*Input format" | tail -2 > "${OUT%.wav}.decoderlog.txt"
echo "decoder log lines: $(wc -l < "${OUT%.wav}.decoderlog.txt")"
