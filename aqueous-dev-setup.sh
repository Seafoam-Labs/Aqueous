#!/bin/bash
# aqueous-dev-setup.sh
# Sets up the dev environment for Aqueous:
#   1. Symlinks all service scripts to ~/.local/bin/
#   2. Runs aqueous-wayfire-setup.sh to configure keybindings
# Safe to run multiple times (idempotent).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FEATURES_DIR="$SCRIPT_DIR/Aqueous/Features"
LOCAL_BIN="$HOME/.local/bin"

# --- 1. Ensure ~/.local/bin exists and is in PATH ---
mkdir -p "$LOCAL_BIN"

if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    echo "[dev-setup] WARNING: $LOCAL_BIN is not in your PATH."
    echo "[dev-setup] Add this to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# --- 2. Discover and symlink all aqueous-* scripts ---
echo "[dev-setup] Scanning for service scripts in $FEATURES_DIR..."

link_count=0
for script in "$FEATURES_DIR"/*/aqueous-*; do
    [ -f "$script" ] || continue
    name="$(basename "$script")"

    # Ensure script is executable
    chmod +x "$script"

    # Create or update symlink
    if [ -L "$LOCAL_BIN/$name" ]; then
        current_target="$(readlink -f "$LOCAL_BIN/$name")"
        if [ "$current_target" = "$(readlink -f "$script")" ]; then
            echo "[dev-setup] $name — already linked, skipping."
        else
            ln -sf "$script" "$LOCAL_BIN/$name"
            echo "[dev-setup] $name — updated symlink (was pointing elsewhere)."
        fi
    else
        ln -sf "$script" "$LOCAL_BIN/$name"
        echo "[dev-setup] $name — symlinked."
    fi
    link_count=$((link_count + 1))
done

echo "[dev-setup] Linked $link_count script(s) to $LOCAL_BIN/"

# --- 3. Run Wayfire keybinding setup if available ---
WAYFIRE_SETUP="$SCRIPT_DIR/aqueous-wayfire-setup.sh"
if [ -x "$WAYFIRE_SETUP" ]; then
    echo ""
    echo "[dev-setup] Running Wayfire keybinding setup..."
    "$WAYFIRE_SETUP"
else
    echo "[dev-setup] No aqueous-wayfire-setup.sh found, skipping Wayfire config."
fi

# --- 4. Summary ---
echo ""
echo "[dev-setup] === Dev Setup Complete ==="
echo "[dev-setup] Symlinked scripts:"
for script in "$LOCAL_BIN"/aqueous-*; do
    [ -L "$script" ] && echo "  $(basename "$script") -> $(readlink "$script")"
done
echo ""
echo "[dev-setup] To undo: rm ~/.local/bin/aqueous-*"
echo "[dev-setup] Restart Wayfire for keybinding changes to take effect."
