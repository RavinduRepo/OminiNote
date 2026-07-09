#!/usr/bin/env bash
# OminiNote Linux installer — copies this bundle into the user's local app
# directory and registers a desktop launcher entry (icon + app-search entry).
#
# Usage: extract the release tarball, then run  ./install.sh
# Uninstall:  ./install.sh --uninstall
set -euo pipefail

APP_NAME="omininote"
DISPLAY_NAME="OminiNote"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_NAME.desktop"

# Directory this script lives in (the extracted bundle root).
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uninstall() {
  echo "Removing $DISPLAY_NAME…"
  rm -rf "$INSTALL_DIR"
  rm -f "$DESKTOP_FILE"
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  echo "Uninstalled."
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

echo "Installing $DISPLAY_NAME to $INSTALL_DIR …"
mkdir -p "$INSTALL_DIR" "$DESKTOP_DIR"

# Copy the whole bundle (excluding the installer itself) into place.
for entry in "$SRC_DIR"/*; do
  base="$(basename "$entry")"
  [ "$base" = "install.sh" ] && continue
  cp -r "$entry" "$INSTALL_DIR/"
done
chmod +x "$INSTALL_DIR/$APP_NAME"

ICON_LINE=""
if [ -f "$INSTALL_DIR/$APP_NAME.png" ]; then
  ICON_LINE="Icon=$INSTALL_DIR/$APP_NAME.png"
fi

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
Comment=Stylus note-taking app
Exec=$INSTALL_DIR/$APP_NAME
$ICON_LINE
Terminal=false
Categories=Office;Graphics;
StartupWMClass=$APP_NAME
Keywords=notes;stylus;drawing;pdf;
EOF

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

echo "Done. Search for \"$DISPLAY_NAME\" in your app launcher."
echo "To uninstall later: run this script again with --uninstall"
