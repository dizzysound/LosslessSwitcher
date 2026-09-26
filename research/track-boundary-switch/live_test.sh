#!/bin/bash
# Live test of Pause While Switching: run the dev build, play local tracks at different rates,
# record app log, Music notifications and the device's nominal rate over time.
set -u
BIN="../typecheck/.build/LosslessSwitcher Dev.app/Contents/MacOS/LosslessSwitcher"; AC=../local-file-resampling/audioctl; DEV="${DEV:-MT 48}"
defaults write com.dizzysound.LosslessSwitcher.dev PreferPauseWhileSwitching -bool true
script -q -F app.log "$BIN" >/dev/null 2>&1 & APP=$!
./listen 75 > notifications.log & LIS=$!
( t0=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())'); end=$(( $(date +%s) + 73 ))
  last=""; while [ $(date +%s) -lt $end ]; do r=$($AC rate "$DEV"); [ "$r" != "$last" ] && echo "$(python3 -c 'import time;print("%.3f"%time.time())') rate $r" && last=$r; sleep 0.02; done ) > rates.log & RAT=$!
sleep 4
for id in A485A3F165BE6CC2 C79A30CC28CE5BF7 AE57AD96DC95CAB1 58283B44B419F777; do
  echo "$(python3 -c 'import time;print("%.3f"%time.time())') play $id" >> actions.log
  osascript -e "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"$id\")"
  sleep 16
done
wait $LIS $RAT; kill $APP 2>/dev/null; wait $APP 2>/dev/null
