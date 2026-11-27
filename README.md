# Kaye OS

```text
███   ███   ▄█████▄   ███   ███  █████████
███  ███   ███   ███  ███   ███  ███
███ ███    ███   ███  ███   ███  ███
██████     █████████   ▀█████▀   ███████
███ ███    ███   ███     ███     ███
███  ███   ███   ███     ███     ███
███   ███  ███   ███     ███     █████████
```

A minimal, modular **Arch Linux** desktop environment built on **Hyprland**, **Quickshell**, and a single **Rust** core binary (`kaye`). Designed for speed, clean customization, and zero bloat.

## Highlights

- **Single-Process Desktop UI (`Quickshell`)** — One lightweight Wayland shell process handles the bar (with hover tooltips on every widget), `Super + Space` hierarchical menu, app launcher, keybindings viewer, notifications, volume/brightness OSD, wallpaper, login intro, and lock screen.
- **Single Rust Core Binary (`kaye`)** — Unified CLI, atomic `colors.toml` theme engine, JSONC menu tree + `.desktop` scanner + fuzzy search backend, shell config & toggle manager, and Snapper/update wrappers.
- **Unified `KAYE` Branding** — Custom Plymouth boot splash (with LUKS passphrase dialog and eased progress bar), Quickshell login intro cover, lock screen, and `kaye about` / `fastfetch` art.
- **3-Layer Configuration** — Repository defaults (`default/`), user overrides (`~/.config/`), and runtime state (`~/.local/state/kaye/`) stay cleanly separated.

## Installation

On an existing **Arch Linux** installation (`git` and `base-devel` recommended):

```bash
git clone https://github.com/1kaye/kaye.git ~/kaye
cd ~/kaye
bash install/all.sh
```

`install/all.sh` runs six idempotent steps:

1. `01-packages.sh` — Installs base packages ([install/packages.base](./install/packages.base)), `yay-bin`, AUR packages ([install/packages.aur](./install/packages.aur)), and configures `rustup default stable`.
2. `02-services.sh` — Enables `NetworkManager`, `bluetooth`, `power-profiles-daemon`, `ufw`, `zram-generator`, and Snapper (retention limit: 3).
3. `03-hardware.sh` — Auto-detects CPU microcode and GPU drivers (`amd`/`intel`/`nvidia`).
4. `04-plymouth.sh` — Installs the `kaye` Plymouth theme, adds the `plymouth` mkinitcpio hook, and rebuilds initramfs.
5. `05-core-and-dotfiles.sh` — Builds and installs `kaye` into `~/.local/bin/kaye`, copies starter configs into `~/.config/` (without overwriting existing files), and enables `kaye-shell.service`.
6. `06-theme.sh` — Applies the default `catppuccin` theme and wallpaper.

### Post-Install Notes

- **Plymouth boot splash:** Ensure `quiet splash` is present in your bootloader kernel parameters.
- **Auto-start Hyprland with UWSM** (optional, no display manager required) — add to `~/.bash_profile`:
  ```bash
  if uwsm check may-start; then
    exec uwsm start hyprland-uwsm.desktop
  fi
  ```

## Repository Structure

```text
kaye/
├── branding/        # KAYE ASCII logo and SVG assets
├── config/          # Starter configs copied to ~/.config/ on first install
├── core/            # Rust CLI, theme engine, menu/search backend (`kaye`)
├── default/         # Repo-managed Hyprland, menu, and `.tpl` color templates
├── install/         # Idempotent Arch bootstrap scripts and package lists
├── plymouth/kaye/   # Plymouth boot splash theme & LUKS prompt assets
├── shell/           # Quickshell thin QML desktop modules
└── themes/          # Bundled themes (`catppuccin`, `tokyo-night`, `gruvbox`)
```

## Default Keybindings

| Shortcut | Action |
|---|---|
| `Super + Space` | Kaye Menu Manager (hierarchical menu + global search) |
| `Super + Alt + Space` | App Launcher (`.desktop` fuzzy search) |
| `Super + K` | Keybindings Viewer |
| `Super + Return` | Terminal (`foot`) |
| `Super + E` | File Manager (`thunar`) |
| `Super + B` | Default Browser |
| `Super + Q` / `F` / `V` / `J` | Close / Fullscreen / Float / Toggle split |
| `Super + 1..9` | Switch workspace (`+ Shift` to move window) |
| `Super + Shift + B` | Show / hide bar |
| `Super + Ctrl + I` | Toggle Stay Awake |
| `Super + Ctrl + N` | Toggle Night Light (`hyprsunset`) |
| `Super + Shift + S` / `Print` | Region / fullscreen screenshot to clipboard |
| `Super + L` | Lock Screen |

## CLI Reference (`kaye`)

| Command | Description |
|---|---|
| `kaye about` | Show Kaye OS branding and system summary |
| `kaye theme list [--json]` | List available themes |
| `kaye theme current` | Print active theme name |
| `kaye theme set <name>` | Render templates and switch theme live |
| `kaye theme bg <path>` | Switch active wallpaper |
| `kaye menu query [route] [--search Q] [--json]` | Query `menu.jsonc` hierarchy |
| `kaye menu apps [--search Q] [--json]` | Scan and fuzzy-search desktop applications |
| `kaye menu provider <name> [--search Q] [--json]` | Query dynamic providers (`themes`, `backgrounds`, `snapshots`) |
| `kaye menu keybindings [--json]` | Parse active Hyprland `bindd` shortcuts |
| `kaye bar position <top\|bottom\|left\|right>` | Move Quickshell bar edge |
| `kaye bar background <opaque\|glassy\|none>` | Change bar background style |
| `kaye bar toggle` | Show / hide bar |
| `kaye toggle <stay-awake\|nightlight\|dnd\|bar-off> [on\|off\|toggle\|status]` | Read or toggle runtime flags |
| `kaye snapshot <create\|list\|delete>` | Manage Snapper Btrfs snapshots |
| `kaye update` | Safe system update (snapshot → cache prune → pacman → AUR) |
| `kaye shell <reload\|restart\|status\|logs>` | Control `kaye-shell.service` |

## Themes & Customization

- **Bundled themes:** `catppuccin`, `tokyo-night`, `gruvbox`.
- **Custom themes:** Create `~/.config/kaye/themes/<name>/colors.toml` (with optional `backgrounds/` directory) and apply it with `kaye theme set <name>`.
- **Menu & Shell overrides:** Edit `~/.config/kaye/menu.jsonc` (merged on top of `default/kaye/menu.jsonc`) and `~/.config/kaye/shell.json` (hot-reloaded by Quickshell).
- **Hyprland overrides:** Edit files in `~/.config/hypr/` (`monitors.conf`, `input.conf`, `bindings.conf`, `looknfeel.conf`, `autostart.conf`), which are sourced after `default/hypr/`.

## Development

```bash
cd core
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

See [AGENTS.md](./AGENTS.md) for architecture conventions, QML rules, and verification steps.
