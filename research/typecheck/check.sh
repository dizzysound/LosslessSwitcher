#!/bin/bash
# Symlink the app's sources into the package and compile them.
set -e
cd "$(dirname "$0")"
rm -f Sources/Nativerate/*.swift
for f in ../../Nativerate/*.swift; do ln -s "../../$f" "Sources/Nativerate/$(basename "$f")"; done
swift build 2>&1 | grep -E "error:|warning:.*(LocalTrack|TrackBoundary|OutputDevices|Defaults|MenuView)|Compiling|Build complete|Build failed|error" | grep -v "^\[" | sort -u
