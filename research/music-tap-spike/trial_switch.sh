#!/bin/bash
# trial_switch.sh <name> [renderer options]: renderer --auto for 100 s. Music starts the temp playlist
# (Backwoods 44.1k, Skyfall 96k, Age of Anxiety 96k stream, Backwoods 44.1k) after the renderer is up
# (first-play-after-launch case), pauses 4 s at ~8 s (user pause/resume), then seeks to 12 s before
# the end of each track so every transition happens within the run.
cd "$(dirname "$0")"; name=$1; shift; rm -f runs/$name.*
open -W -a "$PWD/Renderer.app" --args 100 "$PWD/runs/$name" "$PWD/runs/$name.log" --auto "$@" &
sleep 2
osascript <<'OSA'
tell application "Music"
	play user playlist "tap-test (temporary)"
	delay 8
	pause
	delay 4
	play
	delay 5
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
