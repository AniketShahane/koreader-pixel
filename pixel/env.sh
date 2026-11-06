# Shared paths for the Pixel scripts (sourced, not run).
# REPO = this fork. WORK = where downloads, the simulator and test books live
# (default: the folder that contains the repo; override with PIXEL_WORK).
PIXEL_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIXEL_WORK="${PIXEL_WORK:-$(dirname "$PIXEL_REPO")}"
# The official KOReader build this fork is based on (frontend must match exactly)
PIXEL_BASE_BUILD="v2026.07.2-311-g4102790_2026-11-05"
PIXEL_BASE_RELEASE="https://github.com/AniketShahane/koreader-pixel/releases/download/base-v2026.07.2-311"
