#!/usr/bin/env bash
# Install the desktop UI and landing page into the location nginx serves from.
# Override DST_DIR=... to write somewhere else.
set -e
DIR="$(dirname "$(readlink -f "$0")")"
DST_DIR="${DST_DIR:-$HOME/claude-web-www}"
mkdir -p "$DST_DIR"
install -m 644 "$DIR/desktop.html" "$DST_DIR/index.html"
install -m 644 "$DIR/index.html" "$DST_DIR/landing.html"
install -m 644 "$DIR/filebrowser-patches.js" "$DST_DIR/filebrowser-patches.js"
install -m 644 "$DIR/monitor.html" "$DST_DIR/monitor.html"
install -m 644 "$DIR/upload.html" "$DST_DIR/upload.html"
install -m 644 "$DIR/services.example.json" "$DST_DIR/services.example.json"
# Seed services.json from the example only if the host doesn't already have one
# (it's host-local and gitignored — never overwrite the real list on re-install).
if [ ! -f "$DST_DIR/services.json" ]; then
  install -m 644 "$DIR/services.example.json" "$DST_DIR/services.json"
  echo "Created $DST_DIR/services.json (edit to list your host's services)"
fi
echo "Installed desktop -> $DST_DIR/index.html"
echo "Installed landing -> $DST_DIR/landing.html"
echo "Installed filebrowser-patches.js -> $DST_DIR/filebrowser-patches.js"
echo "Installed monitor -> $DST_DIR/monitor.html"
