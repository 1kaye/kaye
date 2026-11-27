# AGENTS.md

Technical guide and architecture rules for agents and contributors working in the **Kaye OS** repository.

## 1. Architecture Overview

Kaye OS splits responsibilities cleanly across three layers:

1. **Quickshell (`shell/` — thin QML UI)**
   - Single process (`kaye-shell.service`) rendering Background, Startup Intro, Bar, Menu Manager (`Super + Space`), App Launcher, Keybindings Viewer, Notifications, OSD, and Lock Screen.
   - Keep UI modules thin and declarative. Do not write heavy parsing, indexing, or fuzzy-search logic in `.js` files — delegate to the `kaye` Rust binary (`--json`).
2. **Rust Core (`core/` → `~/.local/bin/kaye`)**
   - `core/src/main.rs`: `clap` CLI router.
   - `core/src/theme.rs`: `colors.toml` parser, `.tpl` renderer (`{{ key }}`, `{{ key_strip }}`, `{{ key_rgb }}`), and atomic swap to `~/.local/state/kaye/current/theme/`.
   - `core/src/menu.rs`: JSONC parser (comments + trailing commas), `default/kaye/menu.jsonc` + `~/.config/kaye/menu.jsonc` merger, dotted-ID hierarchy resolver, `.desktop` scanner, fuzzy search, and Hyprland `bindd` parser.
   - `core/src/config.rs`: Type-safe read/write of `~/.config/kaye/shell.json` (preserving unknown user fields) and `~/.local/state/kaye/toggles/*`.
   - `core/src/system.rs`: Safe subprocess wrappers (`Command::new`) for Snapper, `paccache`, `pacman`/`yay`, `systemctl --user`, and `kaye about`.
3. **Bootstrap Installers (`install/` — Bash)**
   - Strictly limited to idempotent first-time setup and package provisioning.

### 3-Layer Configuration Separation

- **Repository defaults (`$KAYE_PATH/`):** `branding/`, `plymouth/kaye/`, `core/`, `default/`, `config/` (starter templates), `install/`, `shell/`, `themes/`.
- **User overrides (`~/.config/`):** `hypr/*.conf`, `kaye/shell.json`, `kaye/menu.jsonc`, `kaye/themes/`, `uwsm/env.d/`, `foot/foot.ini`, `fastfetch/config.jsonc`.
- **Runtime state (`~/.local/state/kaye/`):** `current/theme/`, `current/theme.name`, `current/background`, `toggles/*`. Never commit runtime state or build artifacts (`core/target/`).

### Branding Surfaces

- Boot splash: `plymouth/kaye/` (`kaye.plymouth`, `kaye.script`, PNG assets).
- Login cover: `shell/modules/intro/StartupIntro.qml` (runs once per Hyprland session via `/tmp/kaye-intro-<sig>.done`).
- Lock screen: `shell/modules/lock/LockScreen.qml` (`WlSessionLock` + `PamContext`).
- CLI / terminal: `branding/logo.txt` used by `kaye about`, `install/all.sh`, and `fastfetch`.

## 2. Quickshell & QML Rules

1. **Avoid QtQuick `Color` shadowing:** Always import `import qs.Commons as Commons` and reference `Commons.Color.*`. Never hardcode theme hex colors in UI modules; use `Commons.Color.*` and `Style.*`.
2. **Never stack `HoverHandler` over `MouseArea`:** In Qt 6, an overlaid `HoverHandler` interferes with `MouseArea.onEntered` and breaks bar tooltips.
3. **Tooltip window resolution & fractional scaling:**
   - Match tooltip targets by traversing `item.parent` up to `barWindow.contentItem` (`targetBelongsToWindow()`) rather than relying solely on `target.QsWindow.window`.
   - Keep a short fallback `Timer` (`~120ms`) on tooltip `PopupWindow` so tooltips never stall at zero opacity under fractional scaling.
   - Every bar widget must define `tooltipText`. Calling `showTooltip(target, "")` must not dismiss an active tooltip owned by a different target.
4. **Prevent rich-text injection:** Set `textFormat: Text.PlainText` on all `Text` items rendering dynamic strings (app names, notifications, window titles, CLI output).
5. **Verification:**
   ```bash
   /usr/lib/qt6/bin/qmllint shell/shell.qml shell/Commons/*.qml shell/Ui/*.qml shell/modules/*/*.qml
   journalctl --user -u kaye-shell.service --since "1 minute ago" --no-pager
   ```
   Changes must pass with zero syntax errors, zero `TypeError`, and zero `ReferenceError`.

## 3. Rust (`core/`) Rules

1. Keep dependencies lean (`clap`, `serde`, `serde_json`, `toml`, `anyhow`) to maintain fast builds and sub-15 ms startup latency.
2. Any `--json` subcommand must emit pure JSON to `stdout` (no ANSI escape sequences or extra logs); report errors to `stderr` with a non-zero exit code.
3. Build external process invocations with `Command::new(...).arg(...)` — never interpolate untrusted strings into a shell command.
4. Preserve backward compatibility with user-defined keys in `~/.config/kaye/shell.json`.
5. **Verification:**
   ```bash
   cd core
   cargo fmt --check
   cargo clippy --all-targets -- -D warnings
   cargo test
   cargo build --release
   ```

## 4. Hyprland, Themes & Installer Rules

1. **Hyprland:** Declare keybindings with `bindd` so `kaye menu keybindings` can display descriptions. Verify live edits with `hyprctl reload && hyprctl configerrors` (output must be empty).
2. **Theme templates (`default/themed/*.tpl`):** Every placeholder must correspond to a key in `colors.toml` (`{{ key }}`, `{{ key_strip }}`, `{{ key_rgb }}`). Verify rendered output contains zero unresolved `{{` tokens.
3. **Install scripts (`install/*.sh`):** Must start with `#!/usr/bin/env bash` and `set -euo pipefail`, be safe to re-run (idempotent), keep executable permissions (`chmod +x`), and pass `bash -n`.
4. **Minimal footprint:** Do not add packages to `install/packages.base` or `install/packages.aur` without an explicit requirement.
5. **No machine-specific leakage:** Never hardcode personal usernames, hostnames, mount paths, monitor IDs, or secrets anywhere in repository files.
