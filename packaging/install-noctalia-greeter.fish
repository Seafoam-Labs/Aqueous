#!/usr/bin/env fish
# Install and configure greetd with Noctalia Greeter for Aqueous, then replace
# SDDM. Run this script as the desktop user; it requests sudo only when needed.

function fail --argument-names message
    echo "error: $message" >&2
    exit 1
end

if test (id -u) -eq 0
    fail "run this script as the signed-in user, without sudo"
end

if not command -q shelly
    fail "Shelly is required but was not found on PATH"
end

if not command -q systemctl
    fail "this installer requires a systemd-based Arch Linux system"
end

if not command -q pacman
    fail "this installer supports Arch Linux and Arch-based distributions"
end

set -l login_user (id -un)
set -l backup_stamp (date +%Y%m%d-%H%M%S)
set -l greetd_config /etc/greetd/config.toml
set -l temporary_config (mktemp --tmpdir greetd-config.XXXXXX)
or fail "could not create a temporary configuration file"

function cleanup --on-event fish_exit --inherit-variable temporary_config
    if set -q temporary_config; and test -f "$temporary_config"
        command rm -f -- "$temporary_config"
    end
end

echo "Installing greetd and Noctalia Greeter from the configured repositories..."
shelly install standard greetd noctalia-greeter
or fail "Shelly could not install greetd and noctalia-greeter"

set -l greeter_session (command -s noctalia-greeter-session)
if test -z "$greeter_session"
    fail "noctalia-greeter-session was not found after installation"
end

if not id -u greeter >/dev/null 2>&1
    fail "the greetd greeter account does not exist after installation"
end

# Noctalia Greeter keeps optional appearance settings beneath this directory.
# The packaged tmpfiles entry normally creates it; install -d is an idempotent
# fallback and deliberately leaves any existing greeter settings untouched.
if test -f /usr/lib/tmpfiles.d/noctalia-greeter.conf
    sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/noctalia-greeter.conf
    or fail "could not create Noctalia Greeter's state directory"
else
    sudo install -d -m 0750 -o greeter -g greeter /var/lib/noctalia-greeter
    or fail "could not create Noctalia Greeter's state directory"
end

# --user opens the password prompt for the account running this installer.
# --session selects the Name= value from aqueous.desktop, not its filename.
printf '%s\n' \
    '# Managed by install-noctalia-greeter.fish' \
    '' \
    '[terminal]' \
    'vt = 1' \
    '' \
    '[default_session]' \
    "command = \"$greeter_session -- --user $login_user --session Aqueous\"" \
    'user = "greeter"' >"$temporary_config"
or fail "could not prepare greetd's configuration"

if test -e "$greetd_config"
    set -l backup_path "$greetd_config.backup.$backup_stamp"
    echo "Backing up the existing greetd config to $backup_path"
    sudo cp --preserve=mode,ownership,timestamps -- "$greetd_config" "$backup_path"
    or fail "could not back up the existing greetd configuration"
end

sudo install -Dm644 "$temporary_config" "$greetd_config"
or fail "could not install greetd's configuration"

# Do not use --now here: stopping SDDM would terminate the graphical session
# from which this installer is normally run. The replacement takes effect at
# the next reboot.
if systemctl list-unit-files sddm.service --no-legend 2>/dev/null | string match -q 'sddm.service*'
    echo "Disabling SDDM for the next boot..."
    sudo systemctl disable sddm.service
    or fail "could not disable SDDM"
end

echo "Enabling greetd for the next boot..."
sudo systemctl enable greetd.service
or fail "could not enable greetd"

if not systemctl is-enabled --quiet greetd.service
    fail "greetd did not remain enabled; SDDM has not been removed"
end

# Resolve the package that owns the SDDM unit so sddm-git and similar package
# names are removed through the correct Shelly backend as well.
set -l sddm_unit /usr/lib/systemd/system/sddm.service
if test -e "$sddm_unit"
    set -l sddm_package (pacman -Qqo "$sddm_unit" 2>/dev/null)
    if test -n "$sddm_package"
        echo "Removing $sddm_package through Shelly..."
        if pacman -Qm "$sddm_package" >/dev/null 2>&1
            shelly remove aur "$sddm_package"
        else
            shelly remove standard "$sddm_package"
        end
        or fail "greetd is enabled, but Shelly could not remove $sddm_package"
    end
else
    echo "SDDM is not installed; nothing needs to be removed."
end

echo
echo "greetd and Noctalia Greeter are configured for $login_user."
echo "Aqueous will be preselected, and greetd will replace SDDM after reboot."
echo "Reboot when you are ready; this script intentionally did not end the current session."
