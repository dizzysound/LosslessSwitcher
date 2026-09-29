#!/bin/bash
# Kill the MediaRemoteAdapter helper and time how long until a new one appears.
PAT='MediaRemoteAdapter_MediaRemoteAdapter.bundle.*run.pl.*loop'
old=$(pgrep -f "$PAT" | head -1)
[ -z "$old" ] && { echo "no helper running"; exit 1; }
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
pkill -f "$PAT"
while :; do
  new=$(pgrep -f "$PAT" | head -1)
  now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    printf "%s killed %s, new helper %s after %.2f s\n" "$(date +%T)" "$old" "$new" "$(echo "$now - $t0" | bc)"; break
  fi
  if [ "$(echo "$now - $t0 > 15" | bc)" = 1 ]; then echo "$(date +%T) killed $old, no new helper within 15 s"; break; fi
  sleep 0.05
done
