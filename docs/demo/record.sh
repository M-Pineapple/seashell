#!/usr/bin/env bash
# Record assets/demo.gif from docs/demo.tape.
# Requires vhs (https://github.com/charmbracelet/vhs), ttyd, and ffmpeg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

export PATH="$ROOT/docs/demo/bin:$PATH"

if ! command -v vhs >/dev/null 2>&1; then
    printf 'record.sh: vhs not found on PATH. Install from https://github.com/charmbracelet/vhs\n' >&2
    exit 1
fi

chmod +x "$ROOT/docs/demo/bin/hey" "$ROOT/docs/demo/bin/seashell-sessions"

vhs docs/demo.tape

gif="$ROOT/assets/demo.gif"
if [ ! -f "$gif" ]; then
    printf 'record.sh: expected %s to exist after recording\n' "$gif" >&2
    exit 1
fi

size=$(wc -c < "$gif")
printf 'Wrote %s (%s bytes)\n' "$gif" "$size"
if [ "$size" -gt 2000000 ]; then
    printf 'record.sh: GIF is over 2 MB. Reduce width, height, or framerate in docs/demo.tape.\n' >&2
    exit 1
fi
