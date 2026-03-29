### Audio Switcher — CLI Trigger Setup

The Audio Switcher popup is controlled via a Unix domain socket. To toggle it from a keybinding or script, you need `socat` installed and a small trigger script.

---

### Prerequisites

- **socat** must be installed on your system:
  ```bash
  # Arch / Manjaro
  sudo pacman -S socat

  # Debian / Ubuntu
  sudo apt install socat

  # Fedora
  sudo dnf install socat
  ```

- **PulseAudio CLI tools** (`pactl`) must be available. These are included with PipeWire's PulseAudio compatibility layer or standalone PulseAudio:
  ```bash
  # Arch / Manjaro
  sudo pacman -S libpulse

  # Debian / Ubuntu
  sudo apt install pulseaudio-utils

  # Fedora
  sudo dnf install pulseaudio-utils
  ```

---

### Trigger Script

A ready-made script is provided at `Features/AudioSwitcher/aqueous-audioswitcher`. To use it system-wide:

```bash
# Copy to a directory on your PATH
sudo cp Aqueous/Features/AudioSwitcher/aqueous-audioswitcher /usr/local/bin/
sudo chmod +x /usr/local/bin/aqueous-audioswitcher
```

The script sends `toggle` to the Audio Switcher socket:

```bash
#!/bin/bash
echo "toggle" | socat - UNIX-CONNECT:${XDG_RUNTIME_DIR}/aqueous-audio.sock
```

---

### Available Commands

You can send any of these commands to the socket:

| Command  | Action                          |
|----------|---------------------------------|
| `toggle` | Show the popup if hidden, hide if visible |
| `show`   | Show the popup                  |
| `hide`   | Hide the popup                  |

Example — show only:
```bash
echo "show" | socat - UNIX-CONNECT:${XDG_RUNTIME_DIR}/aqueous-audio.sock
```

---

### Binding to a Keyboard Shortcut

#### Wayfire (`~/.config/wayfire.ini`)

```ini
[command]
binding_audio_switcher = <super> KEY_A
command_audio_switcher = aqueous-audioswitcher
```

#### Hyprland (`~/.config/hypr/hyprland.conf`)

```
bind = SUPER, A, exec, aqueous-audioswitcher
```

#### Sway (`~/.config/sway/config`)

```
bindsym $mod+a exec aqueous-audioswitcher
```

Replace the key combination with whatever you prefer.
