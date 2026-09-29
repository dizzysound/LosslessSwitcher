#!/bin/bash
# trial_192.sh <name> <seconds> [renderer options]: renderer --auto --taponly over the temp playlist
# (Backwoods 44.1k, Ventura 192k, Bobby 48k, Ventura, Skyfall 96k, Ventura, x4: 12 switches into
# 192k). Each track after the first: seek to 4 s before the end, wait for the next track, play 6 s.
# Analyse with sr192.py.
cd "$(dirname "$0")"; name=$1 secs=$2; shift 2; rm -f runs/$name.*
open -W -a "$PWD/Renderer.app" --args $secs "$PWD/runs/$name" "$PWD/runs/$name.log" --auto --taponly "$@" &
sleep 2
osascript <<'OSA'
tell application "Music"
	play user playlist "tap-test (temporary)"
	delay 8
	set n to count of tracks of user playlist "tap-test (temporary)"
	repeat (n - 1) times
		set i to index of current track
		set player position to (duration of current track) - 4
		set t to 0
		repeat while (index of current track) = i and t < 60
			delay 0.5
			set t to t + 1
		end repeat
		delay 6
	end repeat
	pause
end tell
OSA
wait
grep -cE "switch [0-9]+ done" runs/$name.log
