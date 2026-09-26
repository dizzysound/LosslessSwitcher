#!/bin/bash
# Alternate two tracks N times (default 44.1k Backwoods <-> 96k Skyfall) to catch intermittent readiness timeouts.
set -u
BIN="../typecheck/.build/LosslessSwitcher Dev.app/Contents/MacOS/LosslessSwitcher"
A=${A:-A485A3F165BE6CC2}; B=${B:-C79A30CC28CE5BF7}; N=${N:-4}
script -q -F app_repeat.log "$BIN" >/dev/null 2>&1 & APP=$!
sleep 12
for i in $(seq 1 $N); do
  for id in $A $B; do osascript -e "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"$id\")"; sleep 11; done
done
kill $APP; wait $APP 2>/dev/null
