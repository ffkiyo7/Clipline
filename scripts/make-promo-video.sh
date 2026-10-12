#!/bin/bash
# Renders the promo film into build/promo. It draws with the same functions as
# the README art, so this glues make-readme-art.swift (minus its last loop,
# which renders the README images) to make-promo-video.swift and builds that.
# Usage: scripts/make-promo-video.sh [zh-Hans|en]
#        THEME=dark, STILLS=1.5,6.2 and STILLS_ONLY=1 are passed through.
set -euo pipefail
cd "$(dirname "$0")/.."

LANGUAGE="${1:-zh-Hans}"
OUT="build/promo"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sed '/^for t in \[light, dark\] {$/,$d' scripts/make-readme-art.swift > "$WORK/main.swift"
cat scripts/make-promo-video.swift >> "$WORK/main.swift"
swiftc -O "$WORK/main.swift" -o "$WORK/promo"
"$WORK/promo" "$LANGUAGE" "$OUT"
