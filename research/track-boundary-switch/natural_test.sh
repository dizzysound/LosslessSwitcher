#!/bin/bash
# Natural boundary: seek to the last seconds of a track and let Music advance by itself.
set -u
BIN="../typecheck/.build/LosslessSwitcher Dev.app/Contents/MacOS/LosslessSwitcher"; AC=../local-file-resampling/audioctl
script -q -F app_natural.log "$BIN" >/dev/null 2>&1 & APP=$!
sleep 12  # outlast the regular path's post-launch timer
osascript <<'AS'
tell application "Music"
    set p to make new user playlist with properties {name:"LosslessSwitcher boundary test (temp)"}
    duplicate (first track of library playlist 1 whose persistent ID is "C79A30CC28CE5BF7") to p
    duplicate (first track of library playlist 1 whose persistent ID is "A485A3F165BE6CC2") to p
    set shuffle enabled to false
    play p
end tell
AS
sleep 4
for i in 1 2 3 4 5; do  # seeking right after a switch sometimes doesn't take
  osascript -e 'tell application "Music" to set player position to ((duration of current track) - 3)' 2>/dev/null
  sleep 0.3
  osascript -e 'tell application "Music" to get (player position > (duration of current track) - 5)' | grep -q true && break
done
for i in $(seq 1 20); do echo "$(python3 -c 'import time;print("%.2f"%time.time())') $($AC rate 'MT 48') $(osascript -e 'tell application "Music" to get (player state as string) & " " & name of current track & " " & sample rate of current track' 2>&1)"; sleep 0.5; done | awk '!seen[substr($0, index($0," ")+1)]++'
kill $APP; wait $APP 2>/dev/null
osascript -e 'tell application "Music" to delete (every user playlist whose name is "LosslessSwitcher boundary test (temp)")'
osascript -e 'tell application "Music" to get count of (every user playlist whose name is "LosslessSwitcher boundary test (temp)")' 
