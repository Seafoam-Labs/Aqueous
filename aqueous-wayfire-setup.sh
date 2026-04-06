#!/bin/bash
# aqueous-wayfire-setup.sh
# Configures Wayfire keybindings and plugins for Aqueous.
# Safe to run multiple times (idempotent).

WAYFIRE_INI="${XDG_CONFIG_HOME:-$HOME/.config}/wayfire.ini"

if [ ! -f "$WAYFIRE_INI" ]; then
    echo "[aqueous-setup] No wayfire.ini found at $WAYFIRE_INI, skipping."
    exit 0
fi

echo "[aqueous-setup] Configuring Wayfire for Aqueous..."

# --- 1. Ensure required plugins are loaded ---
if grep -q '^\[core\]' "$WAYFIRE_INI"; then
    if grep -q 'plugins\s*=' "$WAYFIRE_INI"; then
        if ! grep -q 'shortcuts-inhibit' "$WAYFIRE_INI"; then
            sed -i '/^\(plugins\s*=.*\)/s/$/ shortcuts-inhibit/' "$WAYFIRE_INI"
            echo "[aqueous-setup] Added shortcuts-inhibit to [core] plugins."
        else
            echo "[aqueous-setup] shortcuts-inhibit already in plugins."
        fi

        # Ensure ipc plugin is loaded (required for Wayfire IPC event subscription)
        if ! grep -q '\bipc\b' "$WAYFIRE_INI"; then
            sed -i '/^\(plugins\s*=\)/s/=\s*/= ipc /' "$WAYFIRE_INI"
            echo "[aqueous-setup] Added ipc to [core] plugins."
        else
            echo "[aqueous-setup] ipc already in plugins."
        fi

        # Ensure ipc-rules plugin is loaded (required for event watching)
        if ! grep -q '\bipc-rules\b' "$WAYFIRE_INI"; then
            sed -i '/^\(plugins\s*=\)/s/=\s*/= ipc-rules /' "$WAYFIRE_INI"
            echo "[aqueous-setup] Added ipc-rules to [core] plugins."
        else
            echo "[aqueous-setup] ipc-rules already in plugins."
        fi
    fi
fi

# --- 2. Clear conflicting [showtouch] toggle binding ---
if grep -q '^\[showtouch\]' "$WAYFIRE_INI"; then
    sed -i '/^\[showtouch\]/,/^\[/{s/^toggle\s*=.*/toggle = none/}' "$WAYFIRE_INI"
    echo "[aqueous-setup] Cleared [showtouch] toggle to avoid conflict."
fi

# --- 3. Add Aqueous keybindings to [command] section ---
add_binding() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}\s*=" "$WAYFIRE_INI"; then
        echo "[aqueous-setup] $key already set, skipping."
    else
        # Append after [command] header
        sed -i "/^\[command\]/a ${key} = ${value}" "$WAYFIRE_INI"
        echo "[aqueous-setup] Added $key = $value"
    fi
}

if grep -q '^\[command\]' "$WAYFIRE_INI"; then
    add_binding "binding_aqueous_launcher" "<alt> KEY_SPACE"
    add_binding "command_aqueous_launcher" "aqueous-applauncher"
    add_binding "binding_aqueous_snapto" "<ctrl> <super> KEY_S"
    add_binding "command_aqueous_snapto" "aqueous-snapto toggle"
else
    # No [command] section exists, append one
    cat >> "$WAYFIRE_INI" <<'EOF'

[command]
binding_aqueous_launcher = <alt> KEY_SPACE
command_aqueous_launcher = aqueous-applauncher
binding_aqueous_snapto = <ctrl> <super> KEY_S
command_aqueous_snapto = aqueous-snapto toggle
EOF
    echo "[aqueous-setup] Created [command] section with Aqueous bindings."
fi

echo "[aqueous-setup] Done. Restart Wayfire for changes to take effect."
