#!/usr/bin/env bash
#
# setup.sh — Install nxupl and its dependencies (Linux + Termux)
#
# By default this auto-installs any missing dependencies using your
# package manager (apt via sudo on Linux, pkg on Termux — Termux never
# needs sudo), and installs nxupl itself into ~/.local/bin.
#
# Pass --no-sudo (alias --skip-sudo) to skip all dependency installation
# and just check what's already on the system, using whatever is present
# without touching the package manager. nxupl is still installed to
# ~/.local/bin either way.
#
# Works two ways:
#   1. Locally, sitting next to nxupl/nxtgup.py/nxupl.conf.example —
#      those files are copied directly.
#   2. As a standalone curl one-liner:
#        curl -fsSL <RAW_URL>/setup.sh | bash
#      In this mode there are no local sibling files, so setup.sh uses
#      curl itself to fetch nxupl/nxtgup.py/nxupl.conf.example from
#      NXUPL_REPO_RAW (see below) before installing them.
#
# Usage:
#   ./setup.sh                                    # local install
#   ./setup.sh --no-sudo                          # local, check-only deps
#   curl -fsSL <RAW_URL>/setup.sh | bash          # remote install
#   curl -fsSL <RAW_URL>/setup.sh | bash -s -- --no-sudo   # remote, check-only deps
#
set -euo pipefail

# Base URL to fetch sibling files from when they aren't found locally
# (e.g. when this script is piped in via curl). Override by exporting
# NXUPL_REPO_RAW before running, or edit the default below to point at
# wherever you host these files (e.g. a GitHub raw URL).
NXUPL_REPO_RAW="${NXUPL_REPO_RAW:-https://raw.githubusercontent.com/imnathanzero/nath/refs/heads/main/nxupl}"

# When run locally this resolves to the real directory; when piped via
# `curl ... | bash` there's no real script file on disk, so this may
# resolve to something unusable (e.g. the current directory) — that's
# fine, we detect and fall back to curl-fetching each file below.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nxupl"
CONFIG_FILE="$CONFIG_DIR/nxupl.conf"
INSTALL_DIR="$HOME/.local/bin"

if [ -t 1 ]; then
    C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

log()  { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[-]${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

NO_SUDO=false
for arg in "$@"; do
    case "$arg" in
        --no-sudo|--skip-sudo)
            NO_SUDO=true
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--no-sudo]"
            echo "  --no-sudo   Don't install anything; just check what's already present."
            echo
            echo "Can also be run remotely:"
            echo "  curl -fsSL <RAW_URL>/setup.sh | bash"
            echo "  curl -fsSL <RAW_URL>/setup.sh | bash -s -- --no-sudo"
            exit 0
            ;;
        *)
            die "Unknown option: $arg"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Detect environment
# ---------------------------------------------------------------------------

IS_TERMUX=false
if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *"com.termux"* ]]; then
    IS_TERMUX=true
fi

if $IS_TERMUX; then
    ok "Detected Termux"
    PKG_INSTALL_CMD=(pkg install -y)
    # Termux's package manager runs as your own user and never needs sudo.
    SUDO_PREFIX=""
else
    ok "Detected Linux"
    if ! command -v apt-get >/dev/null 2>&1; then
        warn "This setup script only automates installation for apt-based distros."
        warn "Install the dependencies listed below manually, or re-run with --no-sudo"
        warn "once they're installed to verify."
    fi
    PKG_INSTALL_CMD=(apt-get install -y)
    SUDO_PREFIX=""
    if [ "$(id -u)" -ne 0 ]; then
        SUDO_PREFIX="sudo "
    fi
fi

# ---------------------------------------------------------------------------
# Dependency check / install
# ---------------------------------------------------------------------------

# name -> package name (Termux pkg / apt package, close enough for both)
declare -A DEPS=(
    [curl]="curl"
    [jq]="jq"
    [rclone]="rclone"
    [python3]="python3"
)

missing_cmds=()
for cmd in "${!DEPS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd already installed"
    else
        missing_cmds+=("$cmd")
    fi
done

if [ ${#missing_cmds[@]} -gt 0 ]; then
    if $NO_SUDO; then
        warn "Missing: ${missing_cmds[*]}"
        warn "--no-sudo passed, so not installing. Install these manually:"
        if $IS_TERMUX; then
            echo "    pkg install ${missing_cmds[*]}"
        else
            echo "    sudo apt-get install ${missing_cmds[*]}"
        fi
    else
        pkgs_to_install=()
        for cmd in "${missing_cmds[@]}"; do
            pkgs_to_install+=("${DEPS[$cmd]}")
        done
        log "Installing missing dependencies: ${pkgs_to_install[*]}"
        if $IS_TERMUX; then
            pkg update -y
            pkg install -y "${pkgs_to_install[@]}"
        else
            ${SUDO_PREFIX}apt-get update
            ${SUDO_PREFIX}apt-get install -y "${pkgs_to_install[@]}"
        fi
        ok "System packages installed"
    fi
else
    ok "All system packages already present"
fi

# ---------------------------------------------------------------------------
# Python deps (Telethon, Pillow for thumbnail dimension checks)
# ---------------------------------------------------------------------------

# Detect whether we're inside a Python virtual environment. If so, pip
# installs are already isolated and --break-system-packages should never
# be used (and usually isn't even accepted).
in_virtualenv() {
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys; sys.exit(0 if (hasattr(sys, 'real_prefix') or sys.base_prefix != sys.prefix) else 1)" 2>/dev/null && return 0
    fi
    return 1
}

# --break-system-packages is a pip flag introduced for PEP 668 "externally
# managed environment" distros. We only want to auto-pass it on Ubuntu
# 24.04+ specifically (per requirements) — not other distros, not older
# Ubuntu, not Termux, and never inside a venv.
needs_break_system_packages() {
    in_virtualenv && return 1
    [ -f /etc/os-release ] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || return 1
    local major minor
    major="${VERSION_ID%%.*}"
    minor="${VERSION_ID#*.}"
    minor="${minor%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    [[ "$minor" =~ ^[0-9]+$ ]] || return 1
    if [ "$major" -gt 24 ] || { [ "$major" -eq 24 ] && [ "$minor" -ge 4 ]; }; then
        return 0
    fi
    return 1
}

if command -v python3 >/dev/null 2>&1; then
    python_missing=()
    python3 -c "import telethon" >/dev/null 2>&1 || python_missing+=("telethon")
    python3 -c "import PIL" >/dev/null 2>&1 || python_missing+=("Pillow")

    if [ ${#python_missing[@]} -gt 0 ]; then
        if $NO_SUDO; then
            warn "Missing Python packages: ${python_missing[*]}"
            warn "--no-sudo passed, so not installing. Install manually:"
            echo "    pip install ${python_missing[*]}"
        else
            log "Installing Python packages: ${python_missing[*]}"
            pip_args=()
            if needs_break_system_packages; then
                log "Ubuntu 24.04+ detected (not in a venv) — using --break-system-packages"
                pip_args+=(--break-system-packages)
            fi
            python3 -m pip install "${pip_args[@]}" "${python_missing[@]}"
            ok "Python packages installed"
        fi
    else
        ok "Python packages (telethon, Pillow) already present"
    fi
else
    warn "python3 not available — skipping Python package checks (telegram upload needs it)"
fi

# ---------------------------------------------------------------------------
# File source: local siblings, or curl-fetched (for the pipe-install case)
# ---------------------------------------------------------------------------

if [ -f "$SCRIPT_DIR/nxupl" ]; then
    log "Running locally — using files next to this script ($SCRIPT_DIR)"
else
    log "No local nxupl found next to this script — will curl-fetch files from $NXUPL_REPO_RAW"
fi

# Fetch a sibling file (nxupl, nxtgup.py, nxupl.conf.example) to $dest,
# either by copying it from next to this script, or — if running via
# `curl ... | bash` and no local copy exists — by curl-fetching it from
# NXUPL_REPO_RAW. Returns 1 if the file couldn't be obtained either way.
fetch_file() {
    local name="$1" dest="$2"
    if [ -f "$SCRIPT_DIR/$name" ]; then
        cp "$SCRIPT_DIR/$name" "$dest"
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$NXUPL_REPO_RAW/$name" -o "$dest" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Config + permissions
# ---------------------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
    if fetch_file "nxupl.conf.example" "$CONFIG_FILE"; then
        chmod 600 "$CONFIG_FILE"
        ok "Created $CONFIG_FILE from the example — fill in your tokens/IDs."
    else
        warn "Couldn't find or fetch nxupl.conf.example; couldn't create $CONFIG_FILE"
    fi
else
    ok "Config already exists at $CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# Install nxupl into ~/.local/bin
# ---------------------------------------------------------------------------

mkdir -p "$INSTALL_DIR"

install_file() {
    local name="$1" mode="$2"
    local dest="$INSTALL_DIR/$name"
    if fetch_file "$name" "$dest"; then
        chmod "$mode" "$dest"
    else
        warn "Couldn't find or fetch $name; skipping install of that file"
    fi
}

install_file "nxupl" 755
install_file "nxtgup.py" 755

ok "Installed nxupl to $INSTALL_DIR"

case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        ;;
    *)
        warn "$INSTALL_DIR is not on your PATH."
        warn "Add this to your ~/.bashrc or ~/.zshrc:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac

echo
ok "Setup complete."
echo "  1. Edit $CONFIG_FILE with your API keys/tokens."
echo "  2. For Google Drive, run: rclone config   (name the remote 'gdrive')"
echo "  3. For Telegram, get api_id/api_hash from https://my.telegram.org"
echo "  4. Run: nxupl <service> <file>"
