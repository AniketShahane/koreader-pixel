#!/bin/bash
# Start Pixel KOReader on this Mac, in a window shaped like a Kindle Paperwhite.
#   pixel/run-mac.sh            open the library
#   pixel/run-mac.sh book.epub  open a book
# Controls: click = tap, hold = long-press, drag = swipe, F2 = power button.
# For Explain, export ANTHROPIC_API_KEY first (or add a key in Settings > Pixel theme).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
APP="$PIXEL_WORK/sim/KOReader.app/Contents/koreader"
[ -d "$APP" ] || { echo "run pixel/setup.sh first" >&2; exit 1; }
"$PIXEL_REPO/pixel/sync.sh" "$APP"
mkdir -p "$PIXEL_WORK/sim/home/plugins"
rsync -a "$PIXEL_REPO/pixel/dev/simdriver.koplugin" "$PIXEL_WORK/sim/home/plugins/"
# Only one simulator at a time (they share settings and the dev remote)
if pgrep -f "^\./luajit reader\.lua" >/dev/null; then
  pkill -f "^\./luajit reader\.lua"; sleep 2
  pkill -9 -f "^\./luajit reader\.lua" 2>/dev/null || true
fi
cd "$APP"
export KO_HOME="$PIXEL_WORK/sim/home"
export EMULATE_READER_W=618 EMULATE_READER_H=824   # x2 on a Retina Mac = 1236x1648 = Paperwhite
export EMULATE_BW_SCREEN=1 EMULATE_BB_TYPE=BB8     # greyscale, like e-ink
exec ./luajit reader.lua "$@"
