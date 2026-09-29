#!/bin/bash
# trial_switch2.sh <name> [renderer options]: renderer --auto for 150 s over the temp playlist
# (Backwoods 44.1k, Skyfall 96k, Have a Cigar 96k, Wish You Were Here 96k, Age of Anxiety stream,
# Backwoods 44.1k): first play after launch, a 10 s user pause, 44.1k -> 96k at a track end, a
# same-rate user skip (Skyfall -> Have a Cigar), a same-rate gapless change (Have a Cigar -> Wish
# You Were Here), a skip to the stream, and 96k -> 44.1k at the stream's end.
cd "$(dirname "$0")"; name=$1; shift; rm -f runs/$name.*
open -W -a "$PWD/Renderer.app" --args 150 "$PWD/runs/$name" "$PWD/runs/$name.log" --auto "$@" &
sleep 2
osascript <<'OSA'
tell application "Music"
	play user playlist "tap-test (temporary)"
	delay 9
	pause
	delay 10
	play
	delay 5
	set player position to (duration of current track) - 12
	delay 26
	next track
	delay 8
	set player position to (duration of current track) - 12
	delay 20
	next track
	delay 25
	set player position to (duration of current track) - 12
	delay 22
	pause
end tell
OSA
wait
grep -vE "IO stalled|IO resumed" runs/$name.log
