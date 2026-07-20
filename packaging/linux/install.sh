#!/usr/bin/env bash
# OminiNote Linux installer — copies this bundle into the user's local app
# directory, registers a desktop launcher entry (icon + app-search entry), and
# associates .omninote notebook files + omninote:// share links with the app so
# double-clicking a file / tapping a link opens and imports it.
#
# Usage: extract the release tarball, then run  ./install.sh
# Uninstall:  ./install.sh --uninstall
set -euo pipefail

APP_NAME="omininote"                        # binary name inside the bundle
APP_ID="io.github.ravinduRepo.omininote"    # Wayland app_id / desktop-file basename
DISPLAY_NAME="OminiNote"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
# The .desktop file's basename MUST equal the window's app_id, or Wayland
# taskbars (waybar's wlr/taskbar, etc.) can't bind the running window to its
# launcher entry — the app would show a blank/generic icon. The Linux runner
# sets app_id = APPLICATION_ID (io.github.ravinduRepo.omininote) via
# g_set_prgname, so the file is named to match.
DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"
# Legacy name from earlier installs — removed so the launcher shows no duplicate.
LEGACY_DESKTOP_FILE="$DESKTOP_DIR/$APP_NAME.desktop"
ICON_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
ICON_SIZES=(256 512)
MIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
MIME_FILE="$MIME_DIR/packages/$APP_NAME.xml"

# Directory this script lives in (the extracted bundle root).
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

refresh_databases() {
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  command -v update-mime-database >/dev/null 2>&1 && \
    update-mime-database "$MIME_DIR" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -f -t "$ICON_BASE" 2>/dev/null || true
}

uninstall() {
  echo "Removing $DISPLAY_NAME…"
  rm -rf "$INSTALL_DIR"
  rm -f "$DESKTOP_FILE" "$LEGACY_DESKTOP_FILE" "$MIME_FILE"
  for size in "${ICON_SIZES[@]}"; do
    rm -f "$ICON_BASE/${size}x${size}/apps/$APP_ID.png"
  done
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

# Install the icon into the hicolor theme under the app_id name, so both the
# app launcher (Icon= lookup) and the Wayland taskbar (app_id → theme lookup)
# resolve it. Taskbars resolve icons by theme name, not absolute paths.
ICON_LINE=""
if [ -f "$INSTALL_DIR/$APP_NAME.png" ]; then
  for size in "${ICON_SIZES[@]}"; do
    dir="$ICON_BASE/${size}x${size}/apps"
    mkdir -p "$dir"
    cp "$INSTALL_DIR/$APP_NAME.png" "$dir/$APP_ID.png"
  done
  ICON_LINE="Icon=$APP_ID"
fi

# Remove any stale launcher entry from a previous (differently named) install.
rm -f "$LEGACY_DESKTOP_FILE"

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
# scheme handler so the OS routes both to us. StartupWMClass matches the X11/
# XWayland window class (app_id) for taskbar grouping.
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
Comment=Stylus note-taking app
Exec=$INSTALL_DIR/$APP_NAME %U
$ICON_LINE
Terminal=false
Categories=Graphics;2DGraphics;
StartupWMClass=$APP_ID
Keywords=notes;stylus;drawing;pdf;
MimeType=application/x-omninote;x-scheme-handler/omninote;application/pdf;
EOF

refresh_databases

echo "Done. Search for \"$DISPLAY_NAME\" in your app launcher."
echo "Double-click a .omninote file (or tap an omninote:// link) to import."
echo "To uninstall later: run this script again with --uninstall"
