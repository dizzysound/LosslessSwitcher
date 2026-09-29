#!/bin/bash
# trial_auto.sh <name> [renderer options]: renderer --auto for 95 s while the temp playlist
# (Backwoods 44.1k, Skyfall 96k, Age of Anxiety 96k stream, Backwoods 44.1k) plays, seeking to
# 12 s before the end of each track so every transition happens within the run.
cd "$(dirname "$0")"; name=$1; shift; rm -f runs/$name.*
open -W -a "$PWD/Renderer.app" --args 95 "$PWD/runs/$name" "$PWD/runs/$name.log" --auto "$@" &
sleep 2
osascript <<'OSA'
tell application "Music"
	play user playlist "tap-test (temporary)"
	delay 10
	repeat 3 times
		set player position to (duration of current track) - 12
		delay 22
	end repeat
	delay 8
	pause
end tell
OSA
wait
grep -vE "IO stalled|IO resumed" runs/$name.log
