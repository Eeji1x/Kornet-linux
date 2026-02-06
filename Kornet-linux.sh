#!/bin/bash
set -e

# --- CONFIGURATION ---
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
APP_NAME="Kornet Linux Player"
APP_ID="kornet-player"
APP_INSTALLER_NAME="KornetLauncher.exe"

# 1. ROOT CHECK
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with sudo: sudo bash Kornet-linux.sh"
  exit 1
fi

# 2. USER DETECTION
REAL_USER=$(logname || echo $SUDO_USER)
REAL_HOME=$(eval echo ~$REAL_USER)
REAL_GID=$(id -g "$REAL_USER")
WINEPREFIX="$REAL_HOME/.wine"

# 3. ENSURE WINE DRIVE EXISTS
if [[ ! -d "$WINEPREFIX/drive_c" ]]; then
    echo "Initializing Wine prefix..."
    su - "$REAL_USER" -c "WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 wineboot -u"
fi

# 4. DOWNLOAD DIRECTLY INTO WINE'S C: DRIVE
# This prevents the "Tiedostoa ei löydy" error
WINE_TEMP="$WINEPREFIX/drive_c/temp"
su - "$REAL_USER" -c "mkdir -p \"$WINE_TEMP\""

echo "Downloading installer to Wine C: drive..."
su - "$REAL_USER" -c "curl -L -o \"$WINE_TEMP/$APP_INSTALLER_NAME\" \"$INSTALLER_URL\""

# 5. EXECUTE USING WINDOWS PATH
echo "Launching Kornet Installer..."
# We tell Wine to run it from C:\temp\ which it always understands
su - "$REAL_USER" -c "WINEPREFIX=\"$WINEPREFIX\" wine \"C:\\temp\\$APP_INSTALLER_NAME\""

# 6. SCAN FOR INSTALLED EXE
echo "Searching for Kornet..."
sleep 5
INSTALL_PATH=$(find "$WINEPREFIX/drive_c/users/$REAL_USER/" -type f -name "*Kornet*.exe" 2>/dev/null | head -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Could not find Kornet.exe. Did you finish the install window?"
  exit 1
fi

# 7. PROTOCOL REGISTRATION
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
su - "$REAL_USER" -c "mkdir -p \"$DESKTOP_DIR\""

cat <<EOF > "$DESKTOP_DIR/$APP_ID.desktop"
[Desktop Entry]
Name=$APP_NAME
Exec=env WINEPREFIX=$WINEPREFIX wine "$INSTALL_PATH" %u
Type=Application
Terminal=false
MimeType=x-scheme-handler/$APP_ID;
EOF
chown "$REAL_USER:$REAL_GID" "$DESKTOP_DIR/$APP_ID.desktop"

su - "$REAL_USER" -c "update-desktop-database \"$DESKTOP_DIR\""
su - "$REAL_USER" -c "xdg-mime default \"$APP_ID.desktop\" x-scheme-handler/$APP_ID"

# 8. CLEANUP
rm -rf "$WINE_TEMP"

echo "------------------------------------------------"
echo "DONE! Kornet is installed."
echo "------------------------------------------------"
