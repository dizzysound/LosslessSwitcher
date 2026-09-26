#!/bin/bash
# Skip forward N times with the dev app running; log what Music plays after each skip.
set -u
BIN="../typecheck/.build/LosslessSwitcher Dev.app/Contents/MacOS/LosslessSwitcher"; AC=../local-file-resampling/audioctl
script -q -F app_skip.log "$BIN" >/dev/null 2>&1 & APP=$!
./listen 70 > notifications_skip.log & LIS=$!
sleep 12
state() { osascript -e 'tell application "Music" to get (player state as string) & " | " & name of current track & " | " & (sample rate of current track)' 2>&1; }
echo "$(date +%T) before: $(state) | device $($AC rate 'MT 48')"
for i in 1 2 3 4 5 6; do
  osascript -e 'tell application "Music" to next track'
  sleep 0.5; echo "$(date +%T) skip $i +0.5s: $(state) | device $($AC rate 'MT 48')"
  sleep 5;   echo "$(date +%T) skip $i +5.5s: $(state) | device $($AC rate 'MT 48')"
done
kill $APP $LIS; wait 2>/dev/null
