#!/bin/bash
# Copy this fork's Lua code and the Pixel fonts on top of an official KOReader
# install of the SAME build (v2026.07.2-311-g4102790). Used for the Mac
# simulator and for the Kindle package. Only copies; never deletes.
#   usage: pixel/sync.sh /path/to/koreader
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="${1:?usage: sync.sh /path/to/koreader}"
[ -f "$DST/reader.lua" ] || { echo "not a KOReader folder: $DST" >&2; exit 1; }
rsync -a "$SRC/frontend/" "$DST/frontend/"
rsync -a --exclude SSH.koplugin --exclude hello.koplugin --exclude timesync.koplugin \
      "$SRC/plugins/" "$DST/plugins/"
cp "$SRC/reader.lua" "$DST/reader.lua"
rsync -a "$SRC/resources/" "$DST/resources/"
mkdir -p "$DST/fonts/pixel"
rsync -a --include '*.ttf' --include '*.txt' --exclude '*' "$SRC/pixel/fonts/" "$DST/fonts/pixel/"
