#!/usr/bin/env bash
# Symlink quickrss.koplugin into a KOReader source tree for ./kodev run testing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KOREADER_DIR="${KOREADER_DIR:-$HOME/projects/koreader}"
PLUGIN_SRC="$ROOT/quickrss.koplugin"
PLUGIN_DST="$KOREADER_DIR/plugins/quickrss.koplugin"

if [[ ! -d "$PLUGIN_SRC" ]]; then
    echo "error: $PLUGIN_SRC not found" >&2
    exit 1
fi

if [[ ! -d "$KOREADER_DIR" ]]; then
    echo "error: KOReader not found at $KOREADER_DIR" >&2
    echo "Clone it first: git clone https://github.com/koreader/koreader.git $KOREADER_DIR" >&2
    exit 1
fi

mkdir -p "$KOREADER_DIR/plugins"
ln -sfn "$PLUGIN_SRC" "$PLUGIN_DST"
echo "Linked → $PLUGIN_DST"
echo "Run emulator: cd $KOREADER_DIR && ./kodev run -s=kobo-aura-one"
