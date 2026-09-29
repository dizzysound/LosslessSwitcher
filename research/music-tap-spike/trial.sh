#!/bin/bash
# trial.sh <name> <seconds> <track persistent ID> [renderer options...]
# Launches Renderer.app, starts the track from the beginning ~2 s later, pauses Music when done.
cd "$(dirname "$0")"; mkdir -p runs
name=$1 secs=$2 track=$3; shift 3
rm -f runs/$name.*
open -W -a "$PWD/Renderer.app" --args "$secs" "$PWD/runs/$name" "$PWD/runs/$name.log" "$@" &
sleep 2
osascript -e "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"$track\")" >/dev/null
wait
osascript -e 'tell application "Music" to pause'
cat runs/$name.log
