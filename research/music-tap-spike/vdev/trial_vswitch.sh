#!/bin/zsh
# trial_vswitch.sh <prefix> <boundaries> [vrender args...]
# NOSET=1: the watcher only logs tracks (vrender --auto does the switching). R0: start rate.
# Music (playlist Hi-Res, shuffle on) -> LosslessSwitcher Output -> VRender -> MT 48.
# A watcher polls Music every 0.15 s and sets the virtual device to each new track's rate
# (after-the-fact detection, like LosslessSwitcher); vrender follows by switching the DAC.
# Each round seeks to 5 s before the current track's end and waits 12 s.
set -u
cd "${0:A:h}"
P=$1; N=$2; shift 2
AC=~/Developer/LosslessSwitcher/research/local-file-resampling/audioctl
LS="LosslessSwitcher Output"
PL="Hi-Res"
r0=${R0:-96000}   # the watcher switches to the first track's rate if it differs
secs=$(( N * 13 + 25 ))
open -W -a "$PWD/VRender.app" --args $secs "$PWD/$P" --rate $r0 --hog --nonmix --setdefault "$@" &
until grep -q "locking" $P.log 2>/dev/null; do sleep 0.5; done
# Play the playlist itself (a single track reference queues nothing after it).
# Music doesn't start if told to play within a few seconds of the default output changing: retry
for try in 1 2 3 4; do
  osascript -e "tell application \"Music\" to play (first user playlist whose name is \"$PL\")"
  sleep 2
  [[ $(osascript -e 'tell application "Music" to get player state') == playing ]] && break
  echo "play attempt $try: not playing"
done
# watcher
( last=""
  while true; do
    line=$(osascript -e 'tell application "Music"' -e 'set t to current track' -e 'set p to ""' -e 'try' -e 'set p to POSIX path of ((location of t) as alias)' -e 'end try' -e 'return (persistent ID of t) & tab & (sample rate of t) & tab & (player position) & tab & p' -e 'end tell' 2>/dev/null)
    id=${line%%$'\t'*}
    if [[ -n "$id" && "$id" != "$last" ]]; then
      last=$id; rate=$(echo "$line" | cut -f2)
      cur=$($AC rate "$LS")
      echo "$(python3 -c 'import time;print(f"{time.time():.3f}")') track $line (LS $cur)"
      if [[ -z "${NOSET:-}" && "${cur%.0}" != "$rate" && "$cur" != "$rate" ]]; then $AC set-rate "$LS" $rate; echo "$(python3 -c 'import time;print(f"{time.time():.3f}")') set LS $rate"; fi
    fi
    sleep 0.15
  done ) > $P.watch.txt 2>&1 &
W=$!
sleep 8
for i in $(seq 1 $N); do
  osascript -e 'tell application "Music"' -e 'set d to duration of current track' -e 'set player position to (d - 5)' -e 'end tell'
  sleep 12
done
osascript -e 'tell application "Music" to pause'
kill $W
wait
echo "done"; tail -3 $P.log
