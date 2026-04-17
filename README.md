# Aqueous

![Screenshot](Screenshot_20260417_101145.png)

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

### Customizing CSS (Dotfile Overrides)

Aqueous supports per-user CSS overrides via `~/.config/aqueous/`. On first run, default CSS files are copied there automatically.

#### Override directory structure

```
~/.config/aqueous/
├── Features/
│   ├── AppLauncher/applauncher.css
│   ├── AudioSwitcher/audioswitcher.css
│   ├── Bar/bar.css
│   ├── Bluetooth/bluetooth.css
│   ├── Dock/dock.css
│   ├── Settings/settings.css
│   ├── SnapTo/snapto.css
│   └── Wallpaper/wallpaper.css
└── Widgets/
    ├── AudioTray/audiotray.css
    ├── BluetoothTray/bluetoothtray.css
    ├── StartMenu/startmenu.css
    ├── SystemTray/systemtray.css
    ├── WindowList/windowlist.css
    └── WorkspaceSwitcher/workspaceswitcher.css
```

#### How it works

- If a CSS file exists in `~/.config/aqueous/`, it is used instead of the bundled default.
- To reset a component's style, simply delete its file from `~/.config/aqueous/` — the built-in default will be used on next launch.
- To reset all styles: `rm -rf ~/.config/aqueous/` and restart Aqueous.

#### Example: changing the bar background

Edit `~/.config/aqueous/Features/Bar/bar.css`:

```css
.bar {
    background-color: rgba(30, 30, 46, 0.9);
}
```

Restart Aqueous to apply changes.

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
│   │   ├── Bar/              # Status bar
│   │   ├── Bluetooth/        # Bluetooth manager
│   │   ├── Dock/             # Application dock (+ helpers/)
│   │   ├── Settings/         # Settings panel (+ SettingsPages/)
│   │   ├── SnapTo/           # Window snapping + aqueous-snapto script
│   │   ├── SystemTray/       # System tray service
│   │   ├── Wallpaper/        # Wallpaper manager (+ DefaultWallpapers/)
│   │   └── WindowManager/    # Window manager service
│   └── Widgets/
│       ├── AudioTray/        # Audio tray bar widget
│       ├── BluetoothTray/    # Bluetooth tray bar widget
│       ├── Clock/            # Clock bar widget
│       ├── Dock/             # Dock widget components
│       ├── StartMenu/        # Start menu bar widget
│       ├── SystemTray/       # System tray bar widget
│       ├── WindowList/       # Window list bar widget
│       └── WorkspaceSwitcher/ # Workspace switcher bar widget
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
