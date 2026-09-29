#!/bin/bash
# gapless_seek.sh <track name> <seconds before end>: plays the temp playlist, steps to <track name>,
# seeks to <seconds before end> of it, so Music rolls into the playlist's next track.
osascript <<OSA >/dev/null
tell application "Music"
	play user playlist "tap-test (temporary)"
	delay 3
	repeat 6 times
		if name of current track is "$1" then exit repeat
		next track
		delay 1.5
	end repeat
	delay 1.5
	set player position to (duration of current track) - $2
end tell
OSA
