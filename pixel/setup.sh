#!/bin/bash
# One-time setup: download the official KOReader builds this fork sits on,
# unpack the Mac simulator, and fetch some free books to test with.
#   pixel/setup.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
V="$PIXEL_WORK/vendor"; mkdir -p "$V" "$PIXEL_WORK/sim/home" "$PIXEL_WORK/books"
for f in "koreader-macos-11.0-arm64-$PIXEL_BASE_BUILD.7z" \
         "koreader-kindlehf-$PIXEL_BASE_BUILD.tar.xz" \
         "koreader-kindlepw2-$PIXEL_BASE_BUILD.tar.xz"; do
  [ -s "$V/$f" ] || { echo "downloading $f"; curl -fSL -o "$V/$f" "$PIXEL_BASE_RELEASE/$f"; }
done
if [ ! -d "$PIXEL_WORK/sim/KOReader.app" ]; then
  echo "unpacking the Mac simulator"
  tar -xf "$V/koreader-macos-11.0-arm64-$PIXEL_BASE_BUILD.7z" -C "$PIXEL_WORK/sim"
fi
S="$PIXEL_WORK/sim/home/settings.reader.lua"
[ -f "$S" ] || cat > "$S" <<EOS
return {
    ["home_dir"] = "$PIXEL_WORK/books",
    ["lastdir"] = "$PIXEL_WORK/books",
    ["quickstart_shown_version"] = 999999999999999,
    ["start_with"] = "filemanager",
}
EOS
get() { [ -s "$PIXEL_WORK/books/$2" ] || curl -fsSL -A "Mozilla/5.0" -o "$PIXEL_WORK/books/$2" "https://www.gutenberg.org/ebooks/$1.epub3.images" || true; }
get 2701 "Herman Melville - Moby-Dick.epub"
get 84   "Mary Shelley - Frankenstein.epub"
get 2680 "Marcus Aurelius - Meditations.epub"
get 64317 "F. Scott Fitzgerald - The Great Gatsby.epub"
get 2500 "Hermann Hesse - Siddhartha.epub"
get 205  "Henry David Thoreau - Walden.epub"
echo "Ready. Run: pixel/run-mac.sh"
