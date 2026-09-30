#!/bin/bash
# Run the installed app with logging and record track, position and device rate over a station's
# next-item prefetch, to check that no rate change happens mid-track.
set -u
AC=../local-file-resampling/audioctl; DEV="${DEV:-MT 48}"; SECS=${SECS:-200}
osascript -e 'tell application id "com.dizzysound.Nativerate" to quit' 2>/dev/null; sleep 1
script -q -F app_prefetch.log /Applications/Nativerate.app/Contents/MacOS/Nativerate >/dev/null 2>&1 & APP=$!
end=$(( $(date +%s) + SECS )); last=""
while [ $(date +%s) -lt $end ]; do
  s="$(osascript -e 'tell application "Music" to get name of current track' 2>/dev/null) | $($AC rate "$DEV")"
  [ "$s" != "$last" ] && echo "$(date +%T) pos $(osascript -e 'tell application "Music" to get round (player position)' 2>/dev/null) | $s" && last="$s"
  sleep 0.5
done > prefetch_monitor.log
kill $APP; wait $APP 2>/dev/null
open /Applications/Nativerate.app
