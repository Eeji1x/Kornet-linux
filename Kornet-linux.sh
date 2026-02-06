#!/bin/bash
set -e

# --- CONFIGURATION ---
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
APP_NAME="Kornet Linux Player"
APP_COMMENT="https://kornet.lat/"
APP_ID="kornet-player"  # This is the protocol: kornet-player://
APP_INSTALLER_EXE="KornetLauncher.exe"
APP_INSTALL_SEARCH_DIR="AppData/Local/Kornet"
REQUIRED_DOTNET_VERSION="8.0"
DOTNET_INSTALLER_URL="https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
DOTNET_INSTALLER_NAME="windowsdesktop-runtime-win-x64.exe"

# 1. ROOT CHECK
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: You must run this with sudo: sudo bash Kornet-linux.sh"
  exit 1
fi

# 2. USER DETECTION (Since sudo is root, we need to find your actual user)
echo "Finding the correct user to install for..."
USER_DIRS=(/home/*)
declare -A found_users
for dir in "${USER_DIRS[@]}"; do
  if [[ -d "$dir" ]] && [[ ! -L "$dir" ]]; then
    user=$(basename "$dir")
    if [[ "$user" != "root" ]] && id "$user" >/dev/null 2>&1; then
      uid=$(id -u "$user")
      if [[ "$uid" -ge 1000 ]]; then
        found_users["$user"]=1
      fi
    fi
  fi
done
USER_LIST=("${!found_users[@]}")

if [[ ${#USER_LIST[@]} -eq 0 ]]; then
  echo "ERROR: No user found."
  exit 1
elif [[ ${#USER_LIST[@]} -eq 1 ]]; then
  REAL_USER="${USER_LIST[0]}"
else
  echo "Multiple users found. Please type the name of the user to install for:"
  read -r REAL_USER
fi

REAL_HOME=$(eval echo ~$REAL_USER)
REAL_GID=$(id -g "$REAL_USER")
WINEPREFIX="$REAL_HOME/.wine"

# 3. ENVIRONMENT SETUP
ENV_VARS="DISPLAY=\"$DISPLAY\" XDG_RUNTIME_DIR=\"/run/user/$(id -u "$REAL_USER")\""
execute_as_user() {
  su - "$REAL_USER" -c "export $ENV_VARS; WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 $1"
}

# 4. INSTALL DEPENDENCIES (Wine)
echo "Checking for Wine..."
if ! command -v wine &>/dev/null; then
  apt update && apt install -y wine winetricks
fi

# 5. PREPARE WINE
echo "Setting up Wine environment for $REAL_USER..."
execute_as_user "wineboot -u"

# 6. DOWNLOAD TOOLS
DOWNLOAD_TOOL="curl -L -o"
if ! command -v curl &>/dev/null; then
  apt install -y curl
fi

# 7. .NET INSTALLATION
DOTNET_DIR="$WINEPREFIX/drive_c/users/$REAL_USER/AppData/Local/Microsoft/dotnet/host/fxr/$REQUIRED_DOTNET_VERSION.0"
if [[ ! -d "$DOTNET_DIR" ]]; then
    echo "Downloading .NET 8.0..."
    su - "$REAL_USER" -c "$DOWNLOAD_TOOL \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
    echo "Installing .NET... (Follow the installer window)"
    execute_as_user "wine \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\""
    su - "$REAL_USER" -c "rm -f \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\""
fi

# 8. KORNET INSTALLATION
echo "Downloading Kornet Installer..."
su - "$REAL_USER" -c "$DOWNLOAD_TOOL \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\" \"$INSTALLER_URL\""

echo "Running Kornet Installer... (Please complete the installation in the window)"
execute_as_user "wine \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\""

echo "Searching for the installed app..."
sleep 5
# Search for any Kornet exe in the Local AppData
INSTALL_PATH=$(find "$WINEPREFIX/drive_c/users/$REAL_USER/" -type f -name "*Kornet*.exe" 2>/dev/null | head -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Could not find the installed Kornet exe."
  exit 1
fi

# 9. DESKTOP & PROTOCOL REGISTRATION
echo "Finalizing system integration..."
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"

cat <<EOF > "$DESKTOP_DIR/$APP_ID.desktop"
[Desktop Entry]
Name=$APP_NAME
Exec=env WINEPREFIX=$WINEPREFIX wine "$INSTALL_PATH" %u
Type=Application
Comment=$APP_COMMENT
Categories=Game;
MimeType=x-scheme-handler/$APP_ID;
EOF
chown "$REAL_USER:$REAL_GID" "$DESKTOP_DIR/$APP_ID.desktop"

execute_as_user "update-desktop-database $DESKTOP_DIR"
execute_as_user "xdg-mime default $APP_ID.desktop x-scheme-handler/$APP_ID"

# 10. CLEANUP
rm -f "$REAL_HOME/Downloads/$APP_INSTALLER_EXE"

echo "------------------------------------------------"
echo "INSTALLATION COMPLETE!"
echo "You can now go to kornet.lat and click Play."
echo "The browser will launch $APP_NAME."
echo "------------------------------------------------"
