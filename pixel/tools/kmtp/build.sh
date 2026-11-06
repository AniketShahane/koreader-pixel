#!/bin/bash
# Build kmtp, the Kindle MTP copier (macOS: brew install libmtp pkg-config).
set -euo pipefail
cd "$(dirname "$0")"
clang -O2 -o kmtp kmtp.c $(pkg-config --cflags --libs libmtp)
echo "built $(pwd)/kmtp"
