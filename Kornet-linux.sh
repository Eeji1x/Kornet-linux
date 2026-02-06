#!/bin/bash
set -e

# --- URLs, IDs, paths ---
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
APP_NAME="Kornet Player"
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

echo "Detecting non-root users..."
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
  echo "ERROR: No suitable user directories found."
  exit 1
elif [[ ${#USER_LIST[@]} -eq 1 ]]; then
  REAL_USER="${USER_LIST[0]}"
  echo "Found single user: $REAL_USER"
else
  echo "Multiple users found. Please choose the user to install $APP_NAME for:"
  mapfile -t sorted_users < <(printf "%s\n" "${USER_LIST[@]}" | sort)
  select chosen_user in "${sorted_users[@]}"; do
    if [[ -n "$chosen_user" ]]; then
      REAL_USER="$chosen_user"
      echo "Selected user: $REAL_USER"
      break
    fi
  done
fi

REAL_HOME=$(eval echo ~$REAL_USER)
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")
WINEPREFIX="$REAL_HOME/.wine"

echo "Capturing graphical environment..."
SUDO_USER_ORIGINAL=$(logname 2>/dev/null || who am i | awk '{print $1}')
if [[ -z "$SUDO_USER_ORIGINAL" ]]; then
    SUDO_USER_ORIGINAL="$REAL_USER"
fi

ENV_VARS="DISPLAY=\"$DISPLAY\" XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\" WAYLAND_DISPLAY=\"$WAYLAND_DISPLAY\""

if [[ -n "$DISPLAY" ]] && [[ "$SUDO_USER_ORIGINAL" == "$REAL_USER" ]]; then
    XAUTH_FILE=""
    if [[ -n "$XAUTHORITY" ]] && [[ -f "$XAUTHORITY" ]]; then
        XAUTH_FILE="$XAUTHORITY"
    elif [[ -f "$REAL_HOME/.Xauthority" ]]; then
        XAUTH_FILE="$REAL_HOME/.Xauthority"
    fi

    if [[ -n "$XAUTH_FILE" ]]; then
        ENV_VARS+=" XAUTHORITY=\"$XAUTH_FILE\""
    fi
fi

execute_as_user() {
  su - "$REAL_USER" -c "export $ENV_VARS; WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 $1"
}

# --- Wine Check ---
WINE_EXE=$(command -v wine || true)
if [[ -z "$WINE_EXE" ]]; then
  echo "Installing Wine..."
  if command -v apt &>/dev/null; then
    apt update && apt install -y wine winetricks
  elif command -v dnf &>/dev/null; then
    dnf install -y wine winetricks
  elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm wine winetricks
  fi
fi

echo "Preparing Wine prefix..."
execute_as_user "wineboot -u"

# --- .NET Runtime Check ---
DOTNET_DIR="$WINEPREFIX/drive_c/users/$REAL_USER/AppData/Local/Microsoft/dotnet/host/fxr/$REQUIRED_DOTNET_VERSION.0" 

if [[ ! -d "$DOTNET_DIR" ]]; then
  echo "Required .NET $REQUIRED_DOTNET_VERSION runtime is missing."
  echo "Downloading .NET installer..."
  su - "$REAL_USER" -c "$DOWNLOAD_TOOL $DOWNLOAD_ARGS \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
  echo "Running .NET installer (GUI)..."
  execute_as_user "wine \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" || true"
  su - "$REAL_USER" -c "rm -f \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\""
else
  echo ".NET $REQUIRED_DOTNET_VERSION already installed."
fi

# --- Kornet Installation ---
echo "Downloading $APP_NAME installer..."
su - "$REAL_USER" -c "$DOWNLOAD_TOOL $DOWNLOAD_ARGS \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\" \"$INSTALLER_URL\""

echo "Running $APP_NAME installer..."
execute_as_user "wine \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\" || true"

echo "Waiting for installation to finish..."
sleep 8

echo "Searching for Kornet executable..."
# Aggressive search for the exe
INSTALL_PATH=$(find "$WINEPREFIX/drive_c/users/$REAL_USER/" -type f -name "Kornet*.exe" 2>/dev/null | head -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Could not find Kornet executable in Wine drive."
  exit 1
fi

# --- Desktop Entry and Protocol Handling ---
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"

echo "Creating desktop entry for $APP_ID://..."
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

echo "Registering protocol handler..."
execute_as_user "update-desktop-database $DESKTOP_DIR || true"
execute_as_user "xdg-mime default $APP_ID.desktop x-scheme-handler/$APP_ID || true"

# Final Cleanup
rm -f "$REAL_HOME/Downloads/$APP_INSTALLER_EXE"

echo "------------------------------------------------"
echo "$APP_NAME installation completed successfully."
echo "Website Protocol: $APP_ID://"
echo "------------------------------------------------"
