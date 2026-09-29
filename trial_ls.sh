#!/bin/bash
# trial_ls.sh <name> [seconds cap] [scenario]: scenario "rates" (default) or "mixed" (trial_switch2's:
# first play, 10 s pause, 44.1k -> 96k, same-rate skip, gapless pair, skip to the stream, 96k -> 44.1k;
# needs trial_switch2's playlist). Drives LosslessSwitcher Dev (branch renderer-engine) with its
# Renderer Engine on and debug recording to runs/<name>.*, over the temp playlist the way
# trial_rates.sh does (seek to 8 s before each end, wait for the next track, play 12 s), then quits
# the app so it writes the recording. Engine log: ~/Library/Logs/LosslessSwitcher-Renderer.log,
# copied to runs/<name>.log.
cd "$(dirname "$0")"; name=$1; secs=${2:-330}; scenario=${3:-rates}; rm -f runs/$name.*
APP="$HOME/Developer/LosslessSwitcher-renderer/research/typecheck/.build/LosslessSwitcher Dev.app"
D=com.dizzysound.LosslessSwitcher.dev
defaults write $D PreferRendererEngine -bool true
defaults write $D RendererDebugRecord "$PWD/runs/$name"
defaults write $D RendererDebugRecordSeconds -float $secs
open "$APP"; sleep 4
if [ "$scenario" = mixed ]; then
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
else
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
fi
osascript -e "tell application id \"$D\" to quit"; sleep 8
cp ~/Library/Logs/LosslessSwitcher-Renderer.log runs/$name.log
grep -cE "switch [0-9]+ done" runs/$name.log
