#!/bin/bash
set -e

# --- CONFIGURATION ---
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
APP_NAME="Kornet Linux Player"
APP_ID="kornet-player"
APP_INSTALLER_NAME="KornetLauncher.exe"
REQUIRED_DOTNET_VERSION="8.0"
DOTNET_INSTALLER_URL="https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
DOTNET_INSTALLER_NAME="windowsdesktop-runtime-win-x64.exe"

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

echo "Installing for user: $REAL_USER"
echo "Home directory: $REAL_HOME"

# 3. CREATE TEMP WORKING DIRECTORY
# This avoids "File not found" errors by using a simple path
TMP_DIR="/tmp/kornet_install"
mkdir -p "$TMP_DIR"
chown "$REAL_USER:$REAL_GID" "$TMP_DIR"

# 4. ENVIRONMENT SETUP
ENV_VARS="DISPLAY=\"$DISPLAY\" XDG_RUNTIME_DIR=\"/run/user/$(id -u "$REAL_USER")\""
execute_as_user() {
  su - "$REAL_USER" -c "export $ENV_VARS; WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 $1"
}

# 5. INSTALL WINE & CURL
if ! command -v wine &>/dev/null || ! command -v curl &>/dev/null; then
  echo "Installing system dependencies..."
  apt update && apt install -y wine wine64 curl
fi

# 6. .NET INSTALLATION
DOTNET_DIR="$WINEPREFIX/drive_c/users/$REAL_USER/AppData/Local/Microsoft/dotnet/host/fxr/$REQUIRED_DOTNET_VERSION.0"
if [[ ! -d "$DOTNET_DIR" ]]; then
    echo "Downloading .NET..."
    su - "$REAL_USER" -c "curl -L -o \"$TMP_DIR/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
    echo "Launching .NET Installer..."
    execute_as_user "wine \"$TMP_DIR/$DOTNET_INSTALLER_NAME\""
fi

# 7. KORNET INSTALLATION
echo "Downloading Kornet..."
su - "$REAL_USER" -c "curl -L -o \"$TMP_DIR/$APP_INSTALLER_NAME\" \"$INSTALLER_URL\""

echo "Launching Kornet Installer..."
# We use the full absolute path to the TMP folder so Wine can't miss it
execute_as_user "wine \"$TMP_DIR/$APP_INSTALLER_NAME\""

echo "Scanning for installed Kornet..."
sleep 5
INSTALL_PATH=$(find "$WINEPREFIX/drive_c/users/$REAL_USER/" -type f -name "*Kornet*.exe" 2>/dev/null | head -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Installer finished but Kornet.exe was not found in Wine drive."
  exit 1
fi

# 8. PROTOCOL REGISTRATION
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

execute_as_user "update-desktop-database \"$DESKTOP_DIR\""
execute_as_user "xdg-mime default \"$APP_ID.desktop\" x-scheme-handler/$APP_ID"

# 9. CLEANUP
rm -rf "$TMP_DIR"

echo "------------------------------------------------"
echo "SUCCESS! Kornet is ready."
echo "You can now join games from kornet.lat"
echo "------------------------------------------------"
