# Aqueous

A .NET 10 GTK4-based desktop environment component suite using [Astal](https://github.com/Aylur/astal), designed for Wayfire.

### Features

- **App Launcher** — fuzzy application launcher (`Alt + Space`)
- **SnapTo** — window snapping/tiling helper (`Ctrl + Super + S`)
- **Audio Switcher** — quick audio device switching
- **Bar, Dock, Wallpaper, Bluetooth, Settings** — additional desktop widgets

---

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/)
- [GTK4](https://gtk.org/)
- [Wayfire](https://wayfire.org/) compositor
- Astal libraries (`libastal-io`, `libastal-apps`, `libastal-auth`, `libastal-battery`, `libastal-bluetooth`, `libastal-cava`, `libastal-greet`, `libastal-mpris`, `libastal-network`, `libastal-notifd`, `libastal-powerprofiles`, `libastal-tray`, `libastal-wireplumber`)
- `socat` (used by service scripts for socket communication)
- `clang`, `zlib`, `krb5` (build dependencies for AOT compilation)

---

### Getting Started (Development)

#### 1. Clone the repository

```bash
git clone <repo-url>
cd Aqueous
```

#### 2. Build the project

```bash
dotnet build Aqueous/Aqueous.csproj
```

Or for a release AOT build:

```bash
dotnet publish Aqueous/Aqueous.csproj -c Release -r linux-x64 --self-contained true /p:PublishAot=true
```

#### 3. Run the dev setup script

This symlinks all service scripts (`aqueous-applauncher`, `aqueous-snapto`, `aqueous-audioswitcher`) into `~/.local/bin/` and configures Wayfire keybindings:

```bash
chmod +x aqueous-dev-setup.sh
./aqueous-dev-setup.sh
```

The script will:
- Auto-discover all `aqueous-*` scripts under `Aqueous/Features/`
- Symlink them to `~/.local/bin/` (must be in your `PATH`)
- Add the `shortcuts-inhibit` plugin to Wayfire (needed for nested sessions)
- Register keybindings in `wayfire.ini`:
  - `Alt + Space` → App Launcher
  - `Ctrl + Super + S` → SnapTo

> **Note:** If `~/.local/bin` is not in your PATH, add this to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):
> ```bash
> export PATH="$HOME/.local/bin:$PATH"
> ```

#### 4. Restart Wayfire

Keybinding changes require a Wayfire restart (or config reload) to take effect.

#### 5. Run Aqueous

```bash
dotnet run --project Aqueous/Aqueous.csproj
```

Or if you built a release binary:

```bash
./Aqueous/bin/Release/net10.0/linux-x64/publish/Aqueous
```

Aqueous is also configured to autostart with Wayfire via the `[autostart]` section in `wayfire.ini`.

---

### Teardown (Dev)

Remove all symlinks created by the dev setup:

```bash
rm ~/.local/bin/aqueous-*
```

---

### Project Structure

```
Aqueous/
├── Aqueous/                  # Main application
│   ├── Features/
│   │   ├── AppLauncher/      # App launcher + aqueous-applauncher script
│   │   ├── AudioSwitcher/    # Audio switcher + aqueous-audioswitcher script
│   │   ├── SnapTo/           # Window snapping + aqueous-snapto script
│   │   ├── Bar/              # Status bar
│   │   ├── Dock/             # Application dock
│   │   ├── Bluetooth/        # Bluetooth manager
│   │   ├── Settings/         # Settings panel
│   │   └── Wallpaper/        # Wallpaper manager
│   └── Widgets/              # Shared widget components
├── AqueousBindings/          # C# bindings for Astal libraries
├── aqueous-dev-setup.sh      # Dev environment setup script
├── aqueous-wayfire-setup.sh  # Wayfire keybinding configuration
├── aqueous.install           # Pacman post-install hook
├── aqueous.desktop           # Desktop entry file
└── PKGBUILD                  # Arch Linux package build
```

---

### Installing (Arch Linux)

Build and install the package:

```bash
makepkg -si
```

The post-install hook will automatically configure Wayfire keybindings for all users with a `wayfire.ini`.

---

### Keybindings

| Shortcut | Action |
|---|---|
| `Alt + Space` | Toggle App Launcher |
| `Ctrl + Super + S` | Toggle SnapTo |

These are registered in the `[command]` section of `wayfire.ini`. To customize, edit `~/.config/wayfire.ini` directly.

---

### Nested Wayfire Sessions

If running Wayfire nested inside another compositor (e.g., KDE Plasma/KWin), the host compositor may intercept keybindings before they reach Wayfire. The `shortcuts-inhibit` plugin (configured by the setup scripts) tells the host to stop intercepting keys when Wayfire has focus.

If keybindings still don't work:
1. Ensure the host compositor supports the `shortcuts-inhibit-v1` Wayland protocol
2. Disable conflicting host shortcuts (e.g., KDE's `Alt+Space` for KRunner)
3. Use KWin Window Rules to force "Ignore global shortcuts" for the Wayfire window
