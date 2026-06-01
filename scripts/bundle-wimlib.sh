#!/usr/bin/env bash
# Copy wimlib-imagex + its libwim dylib into <app>/Contents/Resources/wimlib and
# rewrite the link path so the bundled binary needs no Homebrew.
set -euo pipefail
DEST="${1:?usage: bundle-wimlib.sh <RufusApp.app/Contents/Resources/wimlib>}"
SRC="$(command -v wimlib-imagex || echo /opt/homebrew/bin/wimlib-imagex)"
[ -x "$SRC" ] || { echo "wimlib-imagex not found; brew install wimlib"; exit 1; }
mkdir -p "$DEST"
cp "$SRC" "$DEST/wimlib-imagex"
# find the libwim dylib it links to
LIB=$(otool -L "$DEST/wimlib-imagex" | awk '/libwim/{print $1; exit}')
if [ -n "${LIB:-}" ] && [ -f "$LIB" ]; then
  cp "$LIB" "$DEST/"
  BASE=$(basename "$LIB")
  install_name_tool -change "$LIB" "@executable_path/$BASE" "$DEST/wimlib-imagex"
fi
echo "bundled wimlib into $DEST"
