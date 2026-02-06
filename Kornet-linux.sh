#!/bin/bash
set -e

############################################
# Kornet Linux Installer
# Inspired by vyteshark/bbblox-linux
############################################

# -------- CONFIG --------
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
INSTALLER_NAME="KornetLauncher.exe"

APP_NAME="Kornet Linux Player"
APP_ID="kornet-player"

############################################
# 1. ROOT CHECK
############################################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run with:"
  echo "  sudo bash Kornet-linux.sh"
  exit 1
fi

############################################
# 2. USER DETECTION
############################################
REAL_USER=${SUDO_USER:-$(logname)}
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

echo "Detecting user..."
echo "Using user: $REAL_USER"
echo "Home directory: $REAL_HOME"

############################################
# 3. WINE SETUP
############################################
WINEPREFIX="$REAL_HOME/.wine"
WINE_TEMP="$WINEPREFIX/drive_c/temp"

echo "Using Wine prefix: $WINEPREFIX"

if [[ ! -d "$WINEPREFIX/drive_c" ]]; then
  echo "Initializing Wine prefix..."
  su - "$REAL_USER" -c \
    "WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 wineboot -u"
fi

############################################
# 4. DOWNLOAD INSTALLER
############################################
echo "Preparing Wine temp directory..."
su - "$REAL_USER" -c "mkdir -p \"$WINE_TEMP\""

INSTALLER_PATH="$WINE_TEMP/$INSTALLER_NAME"

echo "Downloading Kornet launcher..."
su - "$REAL_USER" -c \
  "curl -L -H \"User-Agent: Mozilla/5.0\" \
   -o \"$INSTALLER_PATH\" \"$INSTALLER_URL\""

############################################
# 5. VALIDATE DOWNLOAD (PE CHECK)
############################################
if [[ ! -f "$INSTALLER_PATH" ]]; then
  echo "ERROR: Installer file missing."
  exit 1
fi

FILE_TYPE=$(file "$INSTALLER_PATH")

if ! echo "$FILE_TYPE" | grep -qi "PE32 executable"; then
  echo "ERROR: Downloaded file is not a Windows executable."
  echo "$FILE_TYPE"
  exit 1
fi

echo "Installer verified:"
echo "$FILE_TYPE"

############################################
# 6. RUN INSTALLER
############################################
echo "Launching Kornet launcher..."
su - "$REAL_USER" -c \
  "WINEPREFIX=\"$WINEPREFIX\" wine \"C:\\\\temp\\\\$INSTALLER_NAME\""

############################################
# 7. FIND INSTALLED KORNET EXE
############################################
echo "Searching for Kornet executable..."
sleep 5

INSTALL_PATH=$(find \
  "$WINEPREFIX/drive_c/users/$REAL_USER" \
  -type f -iname "*kornet*.exe" 2>/dev/null | head -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Kornet executable not found."
  echo "Make sure the launcher finished installing."
  exit 1
fi

echo "Found Kornet executable:"
echo "$INSTALL_PATH"

############################################
# 8. DESKTOP ENTRY
############################################
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"

echo "Creating desktop entry..."
su - "$REAL_USER" -c "mkdir -p \"$DESKTOP_DIR\""

cat <<EOF > "$DESKTOP_FILE"
[Desktop Entry]
Name=$APP_NAME
Exec=env WINEPREFIX=$WINEPREFIX wine "$INSTALL_PATH" %u
Type=Application
Terminal=false
Categories=Game;
EOF

chown "$REAL_USER:$REAL_GID" "$DESKTOP_FILE"

su - "$REAL_USER" -c "update-desktop-database \"$DESKTOP_DIR\""

############################################
# 9. CLEANUP
############################################
echo "Cleaning up temporary files..."
rm -rf "$WINE_TEMP"

echo "--------------------------------------------"
echo "DONE! Kornet is installed."
echo "Launch it from your app menu."
echo "--------------------------------------------"

