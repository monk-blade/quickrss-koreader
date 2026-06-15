#!/usr/bin/env bash
# Fetch third-party deps and build the KOReader emulator.
# Run ./scripts/install-deps.sh first.
set -euo pipefail

KOREADER_DIR="${KOREADER_DIR:-$HOME/projects/koreader}"

if [[ ! -d "$KOREADER_DIR" ]]; then
    echo "Cloning KOReader…"
    git clone --depth 1 https://github.com/koreader/koreader.git "$KOREADER_DIR"
fi

cd "$KOREADER_DIR"
./kodev fetch-thirdparty
./kodev build

echo ""
echo "Build complete. Link the plugin and run:"
echo "  cd $(cd "$(dirname "$0")/.." && pwd) && ./scripts/dev-link.sh"
echo "  cd $KOREADER_DIR && ./kodev run -s=kobo-aura-one"
