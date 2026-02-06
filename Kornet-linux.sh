#!/bin/bash
set -e

# --- URLs, IDs, paths ---
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
APP_NAME="Kornet Linux Player"
APP_COMMENT="https://kornet.lat/"
APP_ID="kornet-player"
APP_INSTALLER_EXE="KornetLauncher.exe"
APP_INSTALL_SEARCH_DIR="AppData/Local/Kornet"
MIN_WINE_VERSION_MAJOR=8

# --- .NET installation parameters ---
REQUIRED_DOTNET_VERSION="8.0"
DOTNET_INSTALLER_URL="https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
DOTNET_INSTALLER_NAME="windowsdesktop-runtime-win-x64.exe"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This installer must be run as root (sudo)."
  exit 1
fi

# --- check and select the download tool ---
DOWNLOAD_TOOL=""
DOWNLOAD_ARGS=""

if command -v curl &>/dev/null; then
  DOWNLOAD_TOOL="curl"
  DOWNLOAD_ARGS="-L -o"
  echo "Using 'curl' for downloads."
elif command -v wget &>/dev/null; then
  DOWNLOAD_TOOL="wget"
  DOWNLOAD_ARGS="-O"
  echo "Using 'wget' for downloads."
else
  echo "ERROR: Neither curl nor wget found. Please install one."
  exit 1
fi

# --- Detect non-root users ---
echo "Detecting users..."
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
  echo "ERROR: No users found."
  exit 1
elif [[ ${#USER_LIST[@]} -eq 1 ]]; then
  REAL_USER="${USER_LIST[0]}"
else
  echo "Select user to install $APP_NAME for:"
  mapfile -t sorted_users < <(printf "%s\n" "${USER_LIST[@]}" | sort)
  select chosen_user in "${sorted_users[@]}"; do
    if [[ -n "$chosen_user" ]]; then
      REAL_USER="$chosen_user"
      break
    fi
  done
fi

REAL_HOME=$(eval echo ~$REAL_USER)
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")
WINEPREFIX="$REAL_HOME/.wine"

# Graphical environment variables
SUDO_USER_ORIGINAL=$(logname 2>/dev/null || who am i | awk '{print $1}')
ENV_VARS="DISPLAY=\"$DISPLAY\" XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\""

execute_as_user() {
  su - "$REAL_USER" -c "export $ENV_VARS; WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 $1"
}

# --- Install Wine ---
if ! command -v wine &>/dev/null; then
  echo "Installing Wine..."
  if command -v apt &>/dev/null; then
    apt update && apt install -y wine winetricks
  elif command -v dnf &>/dev/null; then
    dnf install -y wine winetricks
  fi
fi

echo "Preparing Wine prefix..."
execute_as_user "wineboot -u"

# --- .NET 8.0 Check ---
DOTNET_DIR="$WINEPREFIX/drive_c/users/$REAL_USER/AppData/Local/Microsoft/dotnet/host/fxr/$REQUIRED_DOTNET_VERSION.0"
if [[ ! -d "$DOTNET_DIR" ]]; then
    echo "Installing .NET $REQUIRED_DOTNET_VERSION..."
    su - "$REAL_USER" -c "$DOWNLOAD_TOOL $DOWNLOAD_ARGS \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
    execute_as_user "wine \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" /quiet /norestart || true"
    su - "$REAL_USER" -c "rm -f \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\""
fi

# --- Kornet Installation ---
echo "Downloading Kornet Installer..."
su - "$REAL_USER" -c "$DOWNLOAD_TOOL $DOWNLOAD_ARGS \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\" \"$INSTALLER_URL\""

echo "Running Kornet Installer..."
execute_as_user "wine \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\" || true"

echo "Locating executable..."
sleep 5
INSTALL_PATH=$(find "$WINEPREFIX/drive_c/users/$REAL_USER/$APP_INSTALL_SEARCH_DIR" -type f -iname "*.exe" 2>/dev/null | head -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Executable not found in $APP_INSTALL_SEARCH_DIR."
  exit 1
fi

# --- Desktop file and Protocol ---
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"

echo "Creating Desktop Entry for kornet-player://..."
cat <<EOF > "$DESKTOP_DIR/$APP_ID.desktop"
[Desktop Entry]
Name=$APP_NAME
Exec=env WINEPREFIX=$WINEPREFIX wine "$INSTALL_PATH" %u
Type=Application
Comment=$APP_COMMENT
Categories=Game;
StartupWMClass=KornetClient
MimeType=x-scheme-handler/$APP_ID;
EOF
chown "$REAL_USER:$REAL_GID" "$DESKTOP_DIR/$APP_ID.desktop"

execute_as_user "update-desktop-database $DESKTOP_DIR || true"
execute_as_user "xdg-mime default $APP_ID.desktop x-scheme-handler/$APP_ID || true"

# Final Cleanup
rm -f "$REAL_HOME/Downloads/$APP_INSTALLER_EXE"

echo "------------------------------------------------"
echo "$APP_NAME installed successfully!"
echo "Protocol: $APP_ID://"
echo "------------------------------------------------"
