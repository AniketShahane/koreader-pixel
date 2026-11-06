#!/bin/bash
# Build Pixel KOReader for a jailbroken Kindle, and optionally copy it over USB.
#
#   pixel/deploy-kindle.sh                    build for Kindles on firmware 5.16.3 or newer
#   pixel/deploy-kindle.sh pw2                build for older firmware (below 5.16.3)
#   pixel/deploy-kindle.sh hf /Volumes/Kindle build, then copy onto a plugged-in Kindle
#
# It takes the official KOReader download of the SAME version this fork is
# based on (v2026.07.2-311, saved in vendor/), lays the Pixel code and fonts
# on top, and zips it. Your KOReader settings on the Kindle are kept.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"; ROOT="$PIXEL_WORK"
case "${1:-hf}" in
  hf)  PKG=kindlehf ;;
  pw2) PKG=kindlepw2 ;;
  *)   echo "usage: $0 [hf|pw2] [/Volumes/Kindle]" >&2; exit 1 ;;
esac
TAR=$(ls "$ROOT"/vendor/koreader-$PKG-v*.tar.xz 2>/dev/null | head -1)
[ -n "$TAR" ] || { echo "missing vendor/koreader-$PKG-*.tar.xz" >&2; exit 1; }

BUILD="$ROOT/build/$PKG"
rm -rf "$BUILD" && mkdir -p "$BUILD"
tar -xJf "$TAR" -C "$BUILD"
"$PIXEL_REPO/pixel/sync.sh" "$BUILD/koreader"

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/koreader-pixel-$PKG.zip"
rm -f "$ZIP"
(cd "$BUILD" && zip -qr "$ZIP" koreader extensions)
echo "Built $ZIP"

if [ -n "${2:-}" ]; then
  KINDLE="$2"
  [ -d "$KINDLE/documents" ] || { echo "$KINDLE doesn't look like a Kindle (no documents folder)" >&2; exit 1; }
  rsync -a "$BUILD/koreader" "$BUILD/extensions" "$KINDLE/"
  echo "Copied to $KINDLE. Eject it, then open KUAL > KOReader on the Kindle."
fi
