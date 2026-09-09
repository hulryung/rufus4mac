#!/usr/bin/env bash
# Copy wimlib-imagex + its libwim dylib into <app>/Contents/Resources/wimlib and
# rewrite the link path so the bundled binary needs no Homebrew.
set -euo pipefail
DEST="${1:?usage: bundle-wimlib.sh <RufusApp.app/Contents/Resources/wimlib>}"
SRC="$(command -v wimlib-imagex || echo /opt/homebrew/bin/wimlib-imagex)"
[ -x "$SRC" ] || { echo "wimlib-imagex not found; brew install wimlib"; exit 1; }
lipo "$SRC" -verify_arch arm64
mkdir -p "$DEST"
# Carry the upstream notices with the redistributed binary and library.
PREFIX="$(cd "$(dirname "$(realpath "$SRC")")/.." && pwd)"
for NOTICE in COPYING COPYING.GPLv3 COPYING.LGPL; do
  cp "$PREFIX/$NOTICE" "$DEST/$NOTICE"
done
cp "$SRC" "$DEST/wimlib-imagex"
# find the libwim dylib it links to
LIB=$(otool -L "$DEST/wimlib-imagex" | awk '/libwim/{print $1; exit}')
if [ -n "${LIB:-}" ] && [ -f "$LIB" ]; then
  cp "$LIB" "$DEST/"
  BASE=$(basename "$LIB")
  install_name_tool -change "$LIB" "@executable_path/$BASE" "$DEST/wimlib-imagex"
fi
echo "bundled wimlib into $DEST"
