#!/bin/zsh
# Music-only bench run (on the bench Mac): musiconly_bench.sh <prefix> <silence|alone|with> <track database ID> [seconds]
#  silence: Music paused, afplay (another app, to the default output = the virtual device) plays
#  alone:   the track from 0, nothing else
#  with:    the track from 0 while afplay plays
# Restarts the dev app with RendererDebugRecord=<prefix> so the recording starts fresh; quits it at
# the end (the recording is finalized on stop) and reopens it without recording.
set -u
P=$1 MODE=$2 ID=$3 SECS=${4:-35}
APP="/Applications/LosslessSwitcher Dev.app" BID=com.dizzysound.LosslessSwitcher.dev L=~/Library/Logs/LosslessSwitcher-ExclusiveMode.log
M() { perl -e 'alarm 10; exec @ARGV' osascript -e "tell application \"Music\" to $1" }
quitapp() { osascript -e "tell application id \"$BID\" to quit"; for i in {1..80}; do pgrep -f "$APP/Contents/MacOS" >/dev/null || return 0; sleep 0.5; done; echo "app did not quit"; exit 1 }
M pause >/dev/null
quitapp
defaults write $BID RendererDebugRecord -string "$P"; defaults write $BID RendererDebugRecordSeconds -float $((SECS + 20))
open "$APP"
for i in {1..60}; do grep -q "clock lock" $L 2>/dev/null && break; sleep 0.5; done
grep -q "clock lock" $L || { echo "no clock lock"; }
sleep 2
AF=""
if [[ $MODE != alone ]]; then ( while true; do afplay /System/Library/Sounds/Submarine.aiff; done ) & AF=$!; fi
if [[ $MODE != silence ]]; then M "play (first track of library playlist 1 whose database ID is $ID)" >/dev/null; sleep 0.3; M "set player position to 0" >/dev/null; fi
sleep $SECS
M pause >/dev/null
[[ -n $AF ]] && { kill $AF; pkill -x afplay; }
sleep 1
grep -E "music only|other apps|alert sounds| Hz fill|MUTED|dry" $L | tail -8
quitapp
defaults delete $BID RendererDebugRecord; defaults delete $BID RendererDebugRecordSeconds
open "$APP"
ls -la "$P".in.f32 "$P".out.f32
