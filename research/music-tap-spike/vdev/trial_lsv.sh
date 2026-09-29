#!/bin/zsh
# trial_lsv.sh <name> <scenario> [rounds]: LosslessSwitcher Dev (dizzysound/LosslessSwitcher branch
# renderer-vdevice) with the Renderer Engine on the virtual device and its debug recording to
# data/<name>.* (vrender's format: vcheck.py; outcheck.py on .out.f32, or on .in.f32 via a symlink).
# Scenarios (shuffle stays on; the temp playlists make the boundaries):
#   rates  - playlist "vdev-rates (temporary)" (44.1-192k): <rounds> times seek to 6 s before the end,
#            wait for the next track, play 10 s
#   mixed  - first play from paused, pause/resume, seek, user skip, an auto boundary, the Apple Music
#            stream "Age of Anxiety I" from paused (lossy -> lossless), the gapless pair Have a Cigar ->
#            Wish You Were Here ("vdev-gapless (temporary)")
# A watcher logs each new track (time, persistent ID, rate, position, name, file) to data/<name>.watch.txt.
# The app is quit at the end (it restores the default output); the script checks that it did.
set -u
cd "${0:A:h}"
name=$1; scen=$2; rounds=${3:-8}
mkdir -p data; rm -f data/$name.*
APP="$HOME/Developer/LosslessSwitcher-renderer/research/typecheck/.build/LosslessSwitcher Dev.app"
B=com.dizzysound.LosslessSwitcher.dev
LOG=~/Library/Logs/LosslessSwitcher-Renderer.log
AC=~/Developer/LosslessSwitcher/research/local-file-resampling/audioctl
osascript -e 'tell application id "com.vincent-neo.LosslessSwitcher" to quit' 2>/dev/null
osascript -e 'tell application "Music" to pause'
defaults write $B PreferRendererEngine -bool true
defaults write $B RendererDebugRecord "$PWD/data/$name"
defaults write $B RendererDebugRecordSeconds -float ${SECS:-900}
rm -f $LOG
echo "$(date +%T) default before: $($AC default) @ $($AC rate "MT 48")" | tee data/$name.trial.txt
open "$APP"
for i in {1..60}; do grep -q "start B" $LOG 2>/dev/null && break; sleep 0.5; done
sleep 3
echo "$(date +%T) default while running: $($AC default)" | tee -a data/$name.trial.txt
( last=""
  while true; do
    line=$(osascript -e 'tell application "Music"' -e 'set t to current track' -e 'set p to ""' -e 'try' -e 'set p to POSIX path of ((location of t) as alias)' -e 'end try' -e 'return (persistent ID of t) & tab & (sample rate of t) & tab & (player position) & tab & (name of t) & tab & p' -e 'end tell' 2>/dev/null)
    id=${line%%$'\t'*}
    if [[ -n "$id" && "$id" != "$last" ]]; then last=$id; echo "$(python3 -c 'import time;print(f"{time.time():.3f}")') $line"; fi
    sleep 0.15
  done ) > data/$name.watch.txt 2>&1 &
W=$!
case $scen in
rates)
osascript - $rounds <<'OSA'
on run argv
	set n to (item 1 of argv) as integer
	tell application "Music"
		play user playlist "vdev-rates (temporary)"
		delay 10
		repeat n times
			set i to persistent ID of current track
			set d to duration of current track
			set player position to (d - 6)
			set t to 0
			repeat while (persistent ID of current track) = i and t < 60
				delay 0.25
				set t to t + 1
			end repeat
			delay 10
		end repeat
		pause
	end tell
end run
OSA
;;
mixed)
osascript <<'OSA'
tell application "Music"
	-- first play from paused (gate; a switch if the rate differs)
	play user playlist "vdev-rates (temporary)"
	delay 10
	-- pause / resume the same track: no switch
	pause
	delay 5
	play
	delay 6
	-- seek within the track: no switch
	set player position to 60
	delay 6
	-- user skip
	next track
	delay 12
	-- auto boundary
	set i to persistent ID of current track
	set d to duration of current track
	set player position to (d - 6)
	repeat while (persistent ID of current track) = i
		delay 0.25
	end repeat
	delay 10
	-- the Apple Music stream, started from paused
	pause
	delay 3
	play (first track of library playlist 1 whose persistent ID is "77AC8F0632ECBA3F")
	delay 25
	-- gapless pair, from paused
	pause
	delay 3
	-- play the playlist itself (a single track reference queues nothing); shuffle is on, so retry
	-- until Have a Cigar comes first and Wish You Were Here follows it
	repeat 8 times
		play user playlist "vdev-gapless (temporary)"
		delay 2
		if name of current track is "Have a Cigar" then exit repeat
		pause
		delay 1
	end repeat
	delay 6
	set d to duration of current track
	set player position to (d - 15)
	delay 35
	pause
end tell
OSA
;;
esac
kill $W
osascript -e "tell application id \"$B\" to quit"
for i in {1..60}; do grep -q "engine stopped" $LOG 2>/dev/null && break; sleep 0.5; done
sleep 1
cp $LOG data/$name.log
echo "$(date +%T) default after quit: $($AC default) @ $($AC rate "MT 48")" | tee -a data/$name.trial.txt
grep -cE "switch [0-9]+ done" data/$name.log
