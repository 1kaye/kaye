mod config;
mod menu;
mod system;
mod theme;

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::process::Command;

#[derive(Parser)]
#[command(
    name = "kaye",
    version,
    about = "Kaye OS CLI, theme engine, and Quickshell backend"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Display Kaye OS ASCII branding and system summary
    About,

    /// Manage themes and wallpapers
    Theme {
        #[command(subcommand)]
        action: ThemeAction,
    },

    /// Query menu tree, desktop apps, providers, or keybindings (for Quickshell)
    Menu {
        #[command(subcommand)]
        action: MenuAction,
    },

    /// Configure the Quickshell bar layout
    Bar {
        #[command(subcommand)]
        action: BarAction,
    },

    /// Toggle desktop flags (stay-awake, nightlight, dnd, bar-off)
    Toggle {
        /// Toggle name: stay-awake | nightlight | dnd | bar-off
        name: String,
        /// Mode: on | off | toggle | status
        #[arg(default_value = "toggle")]
        mode: String,
    },

    /// Manage Btrfs Snapper snapshots
    Snapshot {
        #[command(subcommand)]
        action: SnapshotAction,
    },

    /// Full safe system update (snapshot -> cache prune -> pacman/AUR)
    Update,

    /// Control the Quickshell systemd user service
    Shell {
        /// Action: reload | restart | status | logs
        #[arg(default_value = "restart")]
        action: String,
    },
}

#[derive(Subcommand)]
enum ThemeAction {
    List {
        #[arg(long)]
        json: bool,
    },
    Current,
    Set {
        name: String,
    },
    Bg {
        path: PathBuf,
    },
}

#[derive(Subcommand)]
enum MenuAction {
    Query {
        #[arg(default_value = "root")]
        route: String,
        #[arg(long)]
        search: Option<String>,
        #[arg(long)]
        json: bool,
    },
    Apps {
        #[arg(long)]
        search: Option<String>,
        #[arg(long)]
        json: bool,
    },
    Provider {
        name: String,
        #[arg(long)]
        search: Option<String>,
        #[arg(long)]
        json: bool,
    },
    Keybindings {
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum BarAction {
    Position {
        /// top | bottom | left | right
        edge: String,
    },
    Background {
        /// opaque | glassy | none
        style: String,
    },
    Toggle,
}

#[derive(Subcommand)]
enum SnapshotAction {
    Create {
        #[arg(default_value = "manual")]
        description: String,
    },
    List,
    Delete {
        number: String,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::About => system::print_about()?,
        Commands::Theme { action } => match action {
            ThemeAction::List { json } => {
                let themes = theme::list_themes()?;
                if json {
                    println!("{}", serde_json::to_string(&themes)?);
                } else {
                    for t in themes {
                        let mark = if t.active { "*" } else { " " };
                        println!("{mark} {:<18} ({}, {})", t.name, t.mode, t.accent);
                    }
                }
            }
            ThemeAction::Current => {
                println!(
                    "{}",
                    theme::current_theme()?.unwrap_or_else(|| "none".to_string())
                );
            }
            ThemeAction::Set { name } => {
                let dest = theme::set_theme(&name)?;
                println!("Applied theme '{name}' -> {}", dest.display());
            }
            ThemeAction::Bg { path } => {
                theme::set_background(&path)?;
                println!("Applied background -> {}", path.display());
            }
        },
        Commands::Menu { action } => match action {
            MenuAction::Query {
                route,
                search,
                json,
            } => {
                let rows = menu::query_menu(&route, search.as_deref())?;
                if json {
                    println!("{}", serde_json::to_string(&rows)?);
                } else {
                    for r in rows {
                        println!("{} {} [{}]", r.icon, r.label, r.id);
                    }
                }
            }
            MenuAction::Apps { search, json } => {
                let rows = menu::scan_desktop_apps(search.as_deref())?;
                if json {
                    println!("{}", serde_json::to_string(&rows)?);
                } else {
                    for r in rows {
                        println!("{} -> {}", r.label, r.action.unwrap_or_default());
                    }
                }
            }
            MenuAction::Provider { name, search, json } => {
                let rows = menu::provider_items(&name, search.as_deref())?;
                if json {
                    println!("{}", serde_json::to_string(&rows)?);
                } else {
                    for r in rows {
                        println!("{} {}", r.icon, r.label);
                    }
                }
            }
            MenuAction::Keybindings { json } => {
                let rows = menu::list_keybindings()?;
                if json {
                    println!("{}", serde_json::to_string(&rows)?);
                } else {
                    for r in rows {
                        println!("{:<24} {}", r.keys, r.description);
                    }
                }
            }
        },
        Commands::Bar { action } => {
            let mut cfg = config::load_shell_config()?;
            match action {
                BarAction::Position { edge } => {
                    if !matches!(edge.as_str(), "top" | "bottom" | "left" | "right") {
                        anyhow::bail!("Invalid position '{edge}' (expected top|bottom|left|right)");
                    }
                    cfg.bar.position = edge;
                }
                BarAction::Background { style } => {
                    if !matches!(style.as_str(), "opaque" | "glassy" | "none") {
                        anyhow::bail!("Invalid background '{style}' (expected opaque|glassy|none)");
                    }
                    cfg.bar.background = style;
                }
                BarAction::Toggle => {
                    cfg.bar.hidden = !cfg.bar.hidden;
                }
            }
            config::save_shell_config(&cfg)?;
        }
        Commands::Toggle { name, mode } => {
            let active = config::set_toggle(&name, &mode)?;
            if mode != "status" && name == "nightlight" {
                if active {
                    let _ = Command::new("hyprctl")
                        .args(["hyprsunset", "temperature", "4000"])
                        .output();
                } else {
                    let _ = Command::new("hyprctl")
                        .args(["hyprsunset", "identity"])
                        .output();
                }
            }
            println!("{}", if active { "on" } else { "off" });
        }
        Commands::Snapshot { action } => match action {
            SnapshotAction::Create { description } => system::snapshot_create(&description)?,
            SnapshotAction::List => system::snapshot_list()?,
            SnapshotAction::Delete { number } => system::snapshot_delete(&number)?,
        },
        Commands::Update => system::system_update()?,
        Commands::Shell { action } => system::shell_control(&action)?,
    }

    Ok(())
}
