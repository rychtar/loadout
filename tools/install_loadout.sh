#!/bin/sh
# Installs Loadout into a Godot 4 project (macOS / Linux).
# Usage: tools/install_loadout.sh <project folder> [--force]
# Godot is taken from $GODOT, then `godot` in PATH, then /Applications/Godot.app.
set -e

LOADOUT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "$1" ]; then
	echo "Usage: $0 <project folder> [--force]" >&2
	exit 2
fi
if [ ! -d "$1" ]; then
	echo "Folder $1 does not exist." >&2
	exit 2
fi
PROJECT="$(cd "$1" && pwd)"
shift

if [ -z "$GODOT" ]; then
	GODOT="$(command -v godot || true)"
fi
if [ -z "$GODOT" ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
	GODOT=/Applications/Godot.app/Contents/MacOS/Godot
fi
if [ -z "$GODOT" ]; then
	echo "Godot not found. Set GODOT to the path of the Godot executable." >&2
	exit 2
fi

exec "$GODOT" --headless --path "$LOADOUT_ROOT" --script res://tools/install_loadout.gd -- "$PROJECT" "$@"
