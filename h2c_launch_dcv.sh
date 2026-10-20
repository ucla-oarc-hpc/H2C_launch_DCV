#!/bin/bash

# --- CONFIGURATION DEFAULT VALUES ---
DCV_HOST="dcv1.hoffman2.oarc.ucla.edu"             # Plain hostname or IP only
DCV_PORT="8443"
DCV_USER="$USER"                                   # Default to the current client-side username
VIEWER_GRACE_SECONDS=15                            # Time the viewer has to read the .dcv file before it is wiped
DCV_DOWNLOAD_URL="https://www.amazondcv.com/"
# ------------------------------------

usage() {
    cat << EOF
Usage: $(basename "$0") [-u username] [-h]

Connect to a DCV virtual session on ${DCV_HOST}, creating the session first
if it does not exist yet. The session is named '<username>-dcv'.

Options:
  -u username   Username on ${DCV_HOST} (default: '${USER}')
  -h            Show this help and exit

Requirements:
  - SSH access to ${DCV_HOST} (you will be prompted for your password/2FA)
  - The DCV Viewer (client) installed on this computer

Supported clients: Linux, macOS, and Windows (Git Bash, Cygwin, or WSL).
EOF
}

viewer_install_help() {
    echo
    echo "ERROR: The DCV Viewer was not found on this computer."
    echo
    echo "Download it from: ${DCV_DOWNLOAD_URL}  (Clients section)"
    echo
    case "$1" in
        linux)
            echo "Linux:"
            echo "  RHEL/Rocky/Alma/Fedora: download the .rpm for your distribution, then"
            echo "      sudo dnf install ./nice-dcv-viewer-*.rpm"
            echo "  Ubuntu/Debian: download the .deb for your release, then"
            echo "      sudo apt install ./nice-dcv-viewer_*.deb"
            echo "  Afterwards, make sure 'dcvviewer' is on your PATH."
            ;;
        macos)
            echo "macOS:"
            echo "  Download the .dmg, open it and drag 'DCV Viewer' into Applications."
            echo "  The first time, you may need to right-click the app and choose Open."
            ;;
        windows)
            echo "Windows:"
            echo "  Download the Windows client (.msi installer, or the portable .zip),"
            echo "  install it, then re-run this script."
            echo "  If you used the portable version or a non-default folder, add the folder"
            echo "  that contains dcvviewer.exe to your PATH."
            ;;
    esac
    echo
}

# Sets CLIENT_OS and VIEWER (path to the viewer executable or macOS .app bundle).
# Returns non-zero if no viewer could be found.
find_viewer() {
    VIEWER=""
    local candidate

    case "$OSTYPE" in
        darwin*)
            CLIENT_OS=macos
            for candidate in \
                "/Applications/DCV Viewer.app" \
                "/Applications/NICE DCV Viewer.app" \
                "$HOME/Applications/DCV Viewer.app" \
                "$HOME/Applications/NICE DCV Viewer.app"; do
                if [ -d "$candidate" ]; then
                    VIEWER="$candidate"
                    return 0
                fi
            done
            VIEWER=$(command -v dcvviewer 2>/dev/null)
            ;;
        msys*|cygwin*)
            CLIENT_OS=windows
            VIEWER=$(command -v dcvviewer.exe 2>/dev/null || command -v dcvviewer 2>/dev/null)
            if [ -z "$VIEWER" ]; then
                local pf pf86
                pf=$(cygpath -u "${PROGRAMFILES:-C:\\Program Files}" 2>/dev/null)
                pf86=$(cygpath -u "${PROGRAMFILES_X86:-C:\\Program Files (x86)}" 2>/dev/null)
                for candidate in \
                    "$pf/NICE/DCV/Client/bin/dcvviewer.exe" \
                    "$pf/Amazon/DCV/Client/bin/dcvviewer.exe" \
                    "$pf86/NICE/DCV/Client/bin/dcvviewer.exe" \
                    "$pf86/Amazon/DCV/Client/bin/dcvviewer.exe"; do
                    if [ -x "$candidate" ]; then
                        VIEWER="$candidate"
                        break
                    fi
                done
            fi
            ;;
        linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                # WSL: use the Windows viewer
                CLIENT_OS=windows
                VIEWER=$(command -v dcvviewer.exe 2>/dev/null)
                if [ -z "$VIEWER" ]; then
                    for candidate in \
                        "/mnt/c/Program Files/NICE/DCV/Client/bin/dcvviewer.exe" \
                        "/mnt/c/Program Files/Amazon/DCV/Client/bin/dcvviewer.exe" \
                        "/mnt/c/Program Files (x86)/NICE/DCV/Client/bin/dcvviewer.exe" \
                        "/mnt/c/Program Files (x86)/Amazon/DCV/Client/bin/dcvviewer.exe"; do
                        if [ -x "$candidate" ]; then
                            VIEWER="$candidate"
                            break
                        fi
                    done
                fi
            else
                CLIENT_OS=linux
                VIEWER=$(command -v dcvviewer 2>/dev/null)
            fi
            ;;
        *)
            echo "ERROR: Unsupported client platform '$OSTYPE'."
            exit 1
            ;;
    esac

    [ -n "$VIEWER" ]
}

# Converts a local path to the form the viewer expects (Windows paths for Windows viewers)
viewer_path() {
    if [ "$CLIENT_OS" = "windows" ]; then
        if command -v cygpath >/dev/null 2>&1; then
            cygpath -w "$1"
        else
            wslpath -w "$1"
        fi
    else
        echo "$1"
    fi
}

# Process command-line options
while getopts ":u:h" opt; do
  case ${opt} in
    u )
      DCV_USER=$OPTARG
      ;;
    h )
      usage
      exit 0
      ;;
    : )
      echo "ERROR: Option -$OPTARG requires an argument."
      usage
      exit 1
      ;;
    \? )
      echo "ERROR: Unknown option -$OPTARG."
      usage
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -gt 0 ]; then
    echo "ERROR: Unexpected argument(s): $*"
    usage
    exit 1
fi

# Reject anything that is not a plain POSIX username (also blocks values that ssh would parse as options)
if [[ ! "$DCV_USER" =~ ^[a-z_][a-z0-9._-]*$ ]]; then
    echo "ERROR: Invalid username '$DCV_USER'."
    exit 1
fi

# Check for the viewer before touching the server
if ! find_viewer; then
    viewer_install_help "$CLIENT_OS"
    exit 1
fi
echo "Using DCV Viewer: $VIEWER"

# Session IDs are unique server-wide, so derive one per user
SESSION_ID="${DCV_USER}-dcv"

echo "Using target username: '$DCV_USER'"

umask 077
TEMP_DIR=$(mktemp -d)
TEMP_DCV_FILE="$TEMP_DIR/connect.dcv"
CONTROL_DIR=$(mktemp -d)
SOCKET_FILE="$CONTROL_DIR/ssh.sock"

cleanup() {
    ssh -S "$SOCKET_FILE" -O exit "${DCV_USER}@${DCV_HOST}" 2>/dev/null || true
    rm -rf "$CONTROL_DIR"
}
trap cleanup EXIT

echo "=========================================================="
echo " Establishing secure connection control channel..."
echo "=========================================================="

# 1. Initialize the master connection.
ssh -M -S "$SOCKET_FILE" -fN -o ControlPersist=5m "${DCV_USER}@${DCV_HOST}"

if [ ! -S "$SOCKET_FILE" ]; then
    echo "ERROR: Failed to establish an authentication channel. Exiting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

run_remote() {
    ssh -S "$SOCKET_FILE" "${DCV_USER}@${DCV_HOST}" "$1" 2>/dev/null
}

# 2. Query host status (describe-session exits non-zero when the session does not exist)
if run_remote "dcv describe-session '$SESSION_ID'" >/dev/null; then
    echo "Existing DCV session '$SESSION_ID' found."
else
    echo "No active session found. Instantiating a new virtual session..."
    run_remote "dcv create-session --type virtual '$SESSION_ID'" >/dev/null
    sleep 2

    if ! run_remote "dcv describe-session '$SESSION_ID'" >/dev/null; then
        echo "ERROR: Failed to spin up the DCV session."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
fi

# 3. Generate the temporary .dcv connection file (no password: the viewer prompts for it)
echo "Generating temporary connection file..."
cat << EOF > "$TEMP_DCV_FILE"
[version]
format=1.0

[connect]
host=$DCV_HOST
port=$DCV_PORT
sessionid=$SESSION_ID
user=$DCV_USER
proxytype=NONE
transport=auto

[options]
fullscreen=false
useallmonitors=false
EOF

# 4. Launch the local client application targeting the file
echo "Launching DCV Viewer..."

if [ "$CLIENT_OS" = "macos" ] && [ -d "$VIEWER" ]; then
    open -a "$VIEWER" "$TEMP_DCV_FILE"
else
    "$VIEWER" "$(viewer_path "$TEMP_DCV_FILE")" >/dev/null 2>&1 &
fi

# 5. Wipe the connection file once the viewer has had time to read it.
#    Detached so the terminal is released immediately.
( sleep "$VIEWER_GRACE_SECONDS" && rm -rf "$TEMP_DIR" ) >/dev/null 2>&1 &
disown 2>/dev/null || true

exit 0
