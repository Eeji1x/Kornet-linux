#!/bin/bash
set -e

# --- CONFIGURATION ---
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
APP_NAME="Kornet Linux Player"
APP_COMMENT="https://kornet.lat/"
APP_ID="kornet-player"
APP_INSTALLER_EXE="KornetLauncher.exe"
REQUIRED_DOTNET_VERSION="8.0"
DOTNET_INSTALLER_URL="https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
DOTNET_INSTALLER_NAME="windowsdesktop-runtime-win-x64.exe"

# 1. ROOT CHECK
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run this with sudo: sudo bash Kornet-linux.sh"
  exit 1
fi

# 2. USER DETECTION
echo "Detecting user..."
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

if [[ ${#USER_LIST[@]} -eq 1 ]]; then
  REAL_USER="${USER_LIST[0]}"
else
  echo "Select user:"
  select chosen_user in "${USER_LIST[@]}"; do
    if [[ -n "$chosen_user" ]]; then
      REAL_USER="$chosen_user"
      break
    fi
  done
fi

REAL_HOME=$(eval echo ~$REAL_USER)
REAL_GID=$(id -g "$REAL_USER")
WINEPREFIX="$REAL_HOME/.wine"

# 3. SMART FOLDER DETECTION (Finnish/English/etc.)
# This finds the download folder regardless of its name (Downloads, Lataukset, etc.)
DOWNLOAD_DIR=$(su - "$REAL_USER" -c "xdg-user-dir DOWNLOAD")
if [ ! -d "$DOWNLOAD_DIR" ]; then
    DOWNLOAD_DIR="$REAL_HOME/Downloads"
    su - "$REAL_USER" -c "mkdir -p \"$DOWNLOAD_DIR\""
fi

echo "Using download directory: $DOWNLOAD_DIR"

ENV_VARS="DISPLAY=\"$DISPLAY\" XDG_RUNTIME_DIR=\"/run/user/$(id -u "$REAL_USER")\""
execute_as_user() {
  su - "$REAL_USER" -c "export $ENV_VARS; WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 $1"
}

# 4. INSTALL WINE
if ! command -v wine &>/dev/null; then
  echo "Installing Wine..."
  apt update && apt install -y wine winetricks
fi

# 5. DOWNLOAD TOOLS
if ! command -v curl &>/dev/null; then
  apt install -y curl
fi
DOWNLOAD_TOOL="curl -L -o"

# 6. .NET INSTALLATION
DOTNET_DIR="$WINEPREFIX/drive_c/users/$REAL_USER/AppData/Local/Microsoft/dotnet/host/fxr/$REQUIRED_DOTNET_VERSION.0"
if [[ ! -d "$DOTNET_DIR" ]]; then
    echo "Required .NET missing. Downloading..."
    su - "$REAL_USER" -c "$DOWNLOAD_TOOL \"$DOWNLOAD_DIR/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
    
    echo "Running .NET installer..."
    execute_as_user "wine \"$DOWNLOAD_DIR/$DOTNET_INSTALLER_NAME\""
    su - "$REAL_USER" -c "rm -f \"$DOWNLOAD_DIR/$DOTNET_INSTALLER_NAME\""
else
    echo ".NET already installed."
fi

# 7. KORNET INSTALLATION
echo "Downloading Kornet..."
su - "$REAL_USER" -c "$DOWNLOAD_TOOL \"$DOWNLOAD_DIR/$APP_INSTALLER_EXE\" \"$INSTALLER_URL\""

echo "Running Kornet Installer..."
execute_as_user "wine \"$DOWNLOAD_DIR/$APP_INSTALLER_EXE\""

echo "Locating Kornet in Wine drive..."
sleep 5
# Search all of Wine's drive C for the exe
INSTALL_PATH=$(find "$WINEPREFIX/drive_c/users/$REAL_USER/" -type f -name "*Kornet*.exe" 2>/dev/null | head -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Could not find Kornet.exe. Is the install finished?"
  exit 1
fi

# 8. SYSTEM INTEGRATION
echo "Setting up kornet-player:// protocol..."
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
su - "$REAL_USER" -c "mkdir -p \"$DESKTOP_DIR\""

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

execute_as_user "update-desktop-database \"$DESKTOP_DIR\""
execute_as_user "xdg-mime default \"$APP_ID.desktop\" x-scheme-handler/$APP_ID"

# 9. CLEANUP
rm -f "$DOWNLOAD_DIR/$APP_INSTALLER_EXE"

echo "------------------------------------------------"
echo "DONE! Kornet is installed."
echo "You can play now on kornet.lat"
echo "------------------------------------------------"
