#!/bin/bash
# repro192.sh <name> <rounds>: reproduces a switch into 192k WITHOUT the renderer, the way
# LosslessSwitcher's pause-while-switching does it. Temp playlist: Backwoods 44.1k, Ventura 192k,
# Bobby 48k, Ventura, Skyfall 96k, Ventura. Each round: set the device to the from-track's rate,
# play it 3 s, start Ventura (Music starts it at the old rate), pause 0.2 s later, set 192k, wait
# 3.5 s, rewind to 0:00, play; 1.5 s later capture 5 s with TapCapture (unmuted device tap, the
# spike's granted build). Analyse with repro192.py.
cd "$(dirname "$0")"; name=$1; rounds=${2:-12}; mode=${3:-plain}
# mode vol: the renderer's volume sequence without taps: volume 0 before the rate set, play silently
# 0.9 s, restore volume 100, 0.15 s, pause, rewind, play.
A=~/Developer/LosslessSwitcher/research/local-file-resampling/audioctl
TC=/Users/chrisgillespie/Developer/music-tap-spike/TapCapture.app
PL='user playlist "tap-test (temporary)"'
for i in $(seq 1 $rounds); do
  k=$(( (i - 1) % 3 )); from=$((k * 2 + 1)); rate=(44100 48000 96000); r=${rate[$k]}
  $A set-rate "MT 48" $r >/dev/null; sleep 2.5
  osascript -e "tell application \"Music\" to play track $from of $PL"; sleep 3
  osascript -e "tell application \"Music\" to play track $((from + 1)) of $PL"; sleep 0.2
  osascript -e 'tell application "Music" to pause'
  if [ "$mode" = vol ]; then
    osascript -e 'tell application "Music" to set sound volume to 0'
    $A set-rate "MT 48" 192000 >/dev/null; sleep 3.5
    osascript -e 'tell application "Music" to play'; sleep 0.9
    osascript -e 'tell application "Music" to set sound volume to 100'; sleep 0.15
    # separate calls, as the renderer does (one script with pause + set position + play leaves Music paused)
    osascript -e 'tell application "Music" to pause'; sleep 0.1
    osascript -e 'tell application "Music" to set player position to 0'; sleep 0.1
    osascript -e 'tell application "Music" to play'; sleep 1.5
  else
    $A set-rate "MT 48" 192000 >/dev/null; sleep 3.5
    osascript -e 'tell application "Music"' -e 'set player position to 0' -e 'play' -e 'end tell'; sleep 1.5
  fi
  open -W -a $TC --args device 5 "$PWD/runs/$name.$i.f32" "$PWD/runs/$name.$i.log"
  echo "round $i: from $r -> 192000: $(grep -E 'tap format|callbacks' runs/$name.$i.log | tr '\n' ' ' | cut -c1-160)"
done
osascript -e 'tell application "Music" to pause'
