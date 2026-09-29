#!/bin/bash
# trial_rates.sh <name> <seconds> [renderer options]: renderer --auto while the temp playlist plays from
# its start (first play after launch); for each following track, seeks to 8 s before the current
# track's end, waits until Music is on the next track, then lets it play 12 s.
cd "$(dirname "$0")"; name=$1 secs=$2; shift 2; rm -f runs/$name.*
open -W -a "$PWD/Renderer.app" --args $secs "$PWD/runs/$name" "$PWD/runs/$name.log" --auto "$@" &
sleep 2
osascript <<'OSA'
tell application "Music"
	play user playlist "tap-test (temporary)"
	delay 10
	set n to count of tracks of user playlist "tap-test (temporary)"
	repeat (n - 1) times
		set i to index of current track
		set player position to (duration of current track) - 8
		set t to 0
		repeat while (index of current track) = i and t < 60
			delay 0.5
			set t to t + 1
		end repeat
		delay 12
	end repeat
	pause
end tell
OSA
wait
grep -vE "IO stalled|IO resumed|tap signal" runs/$name.log
