#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/mp4_silence_removal.sh"
DEST_DIR="$HOME/bin"
DEST="$DEST_DIR/mp4_silence_removal"

if [[ ! -f "$SOURCE" ]]; then
  echo "error: $SOURCE not found" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
install -m 0755 "$SOURCE" "$DEST"
echo "installed: $DEST"
