#!/bin/bash
# Item 7: kill -9 the Dev app, time the default output leaving the virtual device, check helpers.
B=$(dirname "$0")
APP=$(pgrep -f "LosslessSwitcher Dev.app/Contents/MacOS" | head -1)
[ -z "$APP" ] && { echo "app not running"; exit 1; }
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
kill -9 "$APP"
while :; do
  d=$("$B/audioprobe" | grep DEFAULT | cut -d'|' -f1)
  now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  el=$(echo "$now - $t0" | bc)
  if ! echo "$d" | grep -q LosslessSwitcher; then echo "default left the virtual device after ${el} s: now $d"; break; fi
  if [ "$(echo "$el > 15" | bc)" = 1 ]; then echo "default still the virtual device after 15 s"; break; fi
  sleep 0.1
done
sleep 2
echo "helpers after kill: $(pgrep -f 'run.pl.*loop' | wc -l | tr -d ' ')"
"$B/audioprobe" | head -3
