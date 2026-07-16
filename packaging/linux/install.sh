#!/usr/bin/env bash
# OminiNote Linux installer — copies this bundle into the user's local app
# directory, registers a desktop launcher entry (icon + app-search entry), and
# associates .omninote notebook files + omninote:// share links with the app so
# double-clicking a file / tapping a link opens and imports it.
#
# Usage: extract the release tarball, then run  ./install.sh
# Uninstall:  ./install.sh --uninstall
set -euo pipefail

APP_NAME="omininote"
DISPLAY_NAME="OminiNote"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_NAME.desktop"
MIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
MIME_FILE="$MIME_DIR/packages/$APP_NAME.xml"

# Directory this script lives in (the extracted bundle root).
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

refresh_databases() {
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  command -v update-mime-database >/dev/null 2>&1 && \
    update-mime-database "$MIME_DIR" 2>/dev/null || true
}

uninstall() {
  echo "Removing $DISPLAY_NAME…"
  rm -rf "$INSTALL_DIR"
  rm -f "$DESKTOP_FILE" "$MIME_FILE"
  refresh_databases
  echo "Uninstalled."
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

echo "Installing $DISPLAY_NAME to $INSTALL_DIR …"
mkdir -p "$INSTALL_DIR" "$DESKTOP_DIR" "$MIME_DIR/packages"

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

# Custom MIME type for .omninote notebook bundles (a ZIP under the hood).
cat > "$MIME_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-omninote">
    <comment>$DISPLAY_NAME notebook</comment>
    <glob pattern="*.omninote"/>
  </mime-type>
</mime-info>
EOF

# %U passes the opened file path(s) / omninote:// URL(s) as launch arguments,
# which the app reads on startup. MimeType registers the file type + the URL
# scheme handler so the OS routes both to us.
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
Comment=Stylus note-taking app
Exec=$INSTALL_DIR/$APP_NAME %U
$ICON_LINE
Terminal=false
Categories=Office;Graphics;
StartupWMClass=$APP_NAME
Keywords=notes;stylus;drawing;pdf;
MimeType=application/x-omninote;x-scheme-handler/omninote;application/pdf;
EOF

refresh_databases

echo "Done. Search for \"$DISPLAY_NAME\" in your app launcher."
echo "Double-click a .omninote file (or tap an omninote:// link) to import."
echo "To uninstall later: run this script again with --uninstall"
