#!/bin/sh
# Run against a preserved before/after libghostty-internal.a and explicit config.
set -eu
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 LIBRARY CONFIG OUTPUT_DIRECTORY [--switch]" >&2
    exit 1
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$3"
clang -O2 -fobjc-arc -fblocks -I"$root/include" \
    "$root/test/renderer-power/renderer-bench.m" "$1" -o "$3/renderer-bench" \
    -framework AppKit -framework Metal -framework QuartzCore -framework IOSurface \
    -framework Carbon -framework CoreText -framework CoreVideo \
    -framework CoreGraphics -framework IOKit -lc++
"$3/renderer-bench" "$2" "$root/test/renderer-power/workload.py" "${4:-}" > "$3/result.json"
cat "$3/result.json"
