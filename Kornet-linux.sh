#!/bin/bash
set -e

# --- URLs, IDs, paths ---
INSTALLER_URL="https://kornet.lat/korcdns/KornetLauncher.exe"
APP_NAME="Kornet linux Player"
APP_COMMENT="https://kornet.lat//"
APP_ID="KornetLauncher"
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
  echo "Using 'wget' for downloads (Warning: Cannot follow redirects, .NET download may fail)."
else
  echo "ERROR: Neither curl nor wget found. Please install one to proceed."
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

echo "Capturing user's graphical environment variables..."

# --- get the original user who ran sudo ---
SUDO_USER_ORIGINAL=$(logname 2>/dev/null || who am i | awk '{print $1}')
if [[ -z "$SUDO_USER_ORIGINAL" ]]; then
    echo "WARNING: Could not determine original user. Falling back to simple environment pass."
    SUDO_USER_ORIGINAL="$REAL_USER" # fallback
fi

# --- determine the actual display env variables to pass ---
ENV_VARS="DISPLAY=\"$DISPLAY\" XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\" WAYLAND_DISPLAY=\"$WAYLAND_DISPLAY\""

# --- get xauthority path for x11 connections ---
if [[ -n "$DISPLAY" ]] && [[ "$SUDO_USER_ORIGINAL" == "$REAL_USER" ]]; then
    # try to find the xauthority file
    XAUTH_FILE=""
    if [[ -n "$XAUTHORITY" ]] && [[ -f "$XAUTHORITY" ]]; then
        XAUTH_FILE="$XAUTHORITY"
    elif [[ -f "$REAL_HOME/.Xauthority" ]]; then
        XAUTH_FILE="$REAL_HOME/.Xauthority"
    else
        # find in /run/user for modern setups
        XAUTH_DIR="/run/user/$(id -u "$REAL_USER")"
        XAUTH_CANDIDATE=$(find "$XAUTH_DIR" -type f -iname "*authority*" -print -quit 2>/dev/null)
        if [[ -n "$XAUTH_CANDIDATE" ]]; then
            XAUTH_FILE="$XAUTH_CANDIDATE"
        fi
    fi

    if [[ -n "$XAUTH_FILE" ]]; then
        # ensure the file exists and is readable before passing
        if [[ -f "$XAUTH_FILE" ]]; then
            ENV_VARS+=" XAUTHORITY=\"$XAUTH_FILE\""
            echo "Using XAUTHORITY: $XAUTH_FILE"
        fi
    fi
fi

# --- define a function to execute commands as the user with the necessary environment ---
execute_as_user() {
  # pass wineprefix and winearch directly to su -c
  su - "$REAL_USER" -c "export $ENV_VARS; WINEPREFIX=\"$WINEPREFIX\" WINEARCH=win64 $1"
}

WINE_EXE=$(command -v wine || true)
if [[ -z "$WINE_EXE" ]]; then
  echo "Installing Wine..."
  if command -v dnf &>/dev/null; then
    dnf install -y wine winetricks
  elif command -v apt &>/dev/null; then
    apt update && apt install -y wine winetricks
  elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm wine winetricks
  else
    echo "ERROR: Cannot find package manager."
    exit 1
  fi
fi

# --- run wineboot here to ensure prefix is fully prepared ---
echo "Preparing Wine prefix (initialization/update)..."
execute_as_user "wineboot -u"

# --- check for a modern .NET runtime ---
DOTNET_DIR="$WINEPREFIX/drive_c/users/$REAL_USER/AppData/Local/Microsoft/dotnet/host/fxr/$REQUIRED_DOTNET_VERSION.0.0" 

echo "Checking for existing .NET $REQUIRED_DOTNET_VERSION runtime installation..."
if [[ -d "$DOTNET_DIR" ]]; then
  echo ".NET $REQUIRED_DOTNET_VERSION seems to be already installed."
  HAS_DOTNET=true
else
  HAS_DOTNET=false
fi

# --- .NET installation prompt ---

if [[ "$HAS_DOTNET" == false ]]; then
  echo
  echo "Required .NET $REQUIRED_DOTNET_VERSION runtime is missing."
  echo "You have two options:"
  echo "  1) Automatic install (opens a Wine GUI window using the official installer)."
  echo "  2) Manual install (recommended if GUI fails)."
  echo

  read -r -p "" CHOICE
  CHOICE=${CHOICE:-Y}

  # --- installing .NET ---
  if [[ "$CHOICE" =~ ^[1Yy]$ ]]; then
    echo "Starting GUI installation of .NET $REQUIRED_DOTNET_VERSION..."
    
    echo "Downloading .NET $REQUIRED_DOTNET_VERSION runtime installer..."
    
    DOTNET_DOWNLOAD_CMD="$DOWNLOAD_TOOL $DOWNLOAD_ARGS \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
    
    if ! su - "$REAL_USER" -c "$DOTNET_DOWNLOAD_CMD"; then
        echo "ERROR: Failed to download the .NET installer using $DOWNLOAD_TOOL."
        echo "Please try the manual install instructions below."
        exit 1
    else
        echo "Running .NET installer..."
        # running without /install /quiet to force the GUI open
        execute_as_user "wine \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" || true"

        echo "Cleaning up .NET installer..."
        su - "$REAL_USER" -c "rm -f \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\""
    fi

  # --- manual installation prompt ---
  else
    echo
    echo "Manual installation instructions:"
    echo "---------------------------------"
    echo "1. Open a terminal as user '$REAL_USER'"
    echo "2. Run the following commands:"
    echo
    echo "   # Download the installer (Use 'curl -L' for reliability)"
    echo "   curl -L -o \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
    echo "   # If curl is not available, try:"
    echo "   # wget -O \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\" \"$DOTNET_INSTALLER_URL\""
    echo
    echo "   # Install the runtime"
    echo "   export WINEPREFIX=\"$WINEPREFIX\""
    echo "   export WINEARCH=win64"
    echo "   wine \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\""
    echo "   # Delete the installer after use"
    echo "   rm -f \"$REAL_HOME/Downloads/$DOTNET_INSTALLER_NAME\""
    echo
    echo "Then re-run this installer when finished."
    echo ""
    echo "imma be honest i don't know if this method works, haven't tested it yet. use automatic installation for now, it should work"
    exit 0
  fi
else
  echo ".NET $REQUIRED_DOTNET_VERSION runtime already installed - skipping."
fi

# --- bootstrapper / installer download ---
echo "Downloading installer..."
MAIN_DOWNLOAD_CMD="$DOWNLOAD_TOOL $DOWNLOAD_ARGS \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\" \"$INSTALLER_URL\""
su - "$REAL_USER" -c "$MAIN_DOWNLOAD_CMD"

echo "Running BubbaBlox installer..."
execute_as_user "wine \"$REAL_HOME/Downloads/$APP_INSTALLER_EXE\" || true"

# fix: add a short delay for the installation to complete fully
echo "Waiting 5 seconds for installation cleanup to complete..."
sleep 5

echo "Searching for installed executable..."
INSTALL_PATH=$(find "$WINEPREFIX/drive_c/users/$REAL_USER/$APP_INSTALL_SEARCH_DIR" -type f -iname "*.exe" 2>/dev/null | sort | tail -n 1)

if [[ -z "$INSTALL_PATH" ]]; then
  echo "ERROR: Could not find installed executable in $APP_INSTALL_SEARCH_DIR."
  echo "The client may have installed to a different path or failed to finish cleanly."
  echo "You will need to manually locate the executable file."
  exit 1
fi

# --- .desktop file creation ---
DESKTOP_DIR="$REAL_HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"

echo "Creating desktop entry for URL protocol handler (bbclient://)..."
cat <<EOF > "$DESKTOP_DIR/$APP_ID.desktop"
[Desktop Entry]
Name=$APP_NAME
Exec=env WINEPREFIX=$WINEPREFIX wine "$INSTALL_PATH" %u
Type=Application
Comment=$APP_COMMENT
Categories=Game;
StartupWMClass=BubbaBloxClient
MimeType=x-scheme-handler/bbclient;
EOF
chown "$REAL_USER:$REAL_GID" "$DESKTOP_DIR/$APP_ID.desktop"

# register the handler with the system
echo "Registering 'bbclient://' protocol handler..."
execute_as_user "update-desktop-database $DESKTOP_DIR || true"
execute_as_user "xdg-mime default $APP_ID.desktop x-scheme-handler/bbclient || true"

# cleaning up
echo "Cleaning up installer..."
rm -f "$REAL_HOME/Downloads/$APP_INSTALLER_EXE"

echo "$APP_NAME installation completed successfully."
