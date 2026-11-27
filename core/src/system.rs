use crate::config;
use anyhow::{bail, Context, Result};
use std::fs;
use std::process::Command;

fn run_interactive(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(args)
        .status()
        .with_context(|| format!("Failed to execute {program}"))?;
    if !status.success() {
        bail!("{program} exited with status {status}");
    }
    Ok(())
}

pub fn print_about() -> Result<()> {
    let logo_path = config::kaye_root()?.join("branding/logo.txt");
    if logo_path.is_file() {
        let art = fs::read_to_string(&logo_path)?;
        println!("\x1b[34m{art}\x1b[0m");
    } else {
        println!("KAYE OS");
    }
    println!("  OS      : Kaye OS (Arch Linux + Hyprland + Quickshell + Rust)");
    println!("  Version : {}", env!("CARGO_PKG_VERSION"));
    println!("  Repo    : {}", config::kaye_root()?.display());
    if let Ok(Some(t)) = crate::theme::current_theme() {
        println!("  Theme   : {t}");
    }
    Ok(())
}

pub fn snapshot_create(description: &str) -> Result<()> {
    run_interactive(
        "sudo",
        &[
            "snapper",
            "-c",
            "root",
            "create",
            "-c",
            "number",
            "-d",
            description,
        ],
    )?;
    let _ = Command::new("sudo")
        .args(["snapper", "-c", "root", "cleanup", "number"])
        .status();
    Ok(())
}

pub fn list_snapshots_raw() -> Result<Vec<String>> {
    let output = Command::new("snapper")
        .args(["-c", "root", "list", "--columns", "number,date,description"])
        .output();
    match output {
        Ok(out) if out.status.success() => {
            let text = String::from_utf8_lossy(&out.stdout);
            Ok(text
                .lines()
                .skip(2)
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect())
        }
        _ => Ok(Vec::new()),
    }
}

pub fn snapshot_list() -> Result<()> {
    run_interactive("sudo", &["snapper", "-c", "root", "list"])
}

pub fn snapshot_delete(number: &str) -> Result<()> {
    run_interactive("sudo", &["snapper", "-c", "root", "delete", number])
}

pub fn system_update() -> Result<()> {
    println!("==> [1/4] Creating pre-update Btrfs snapshot...");
    let _ = snapshot_create("kaye-pre-update");

    println!("==> [2/4] Pruning old Pacman cache (keeping 2 versions)...");
    let _ = Command::new("sudo").args(["paccache", "-rk2"]).status();

    println!("==> [3/4] Updating Arch packages...");
    run_interactive("sudo", &["pacman", "-Syu"])?;

    if Command::new("which")
        .arg("yay")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        println!("==> [4/4] Updating AUR packages...");
        run_interactive("yay", &["-Sua"])?;
    }

    println!("==> Kaye OS update complete.");
    Ok(())
}

pub fn shell_control(action: &str) -> Result<()> {
    match action {
        "restart" | "reload" => {
            run_interactive("systemctl", &["--user", "restart", "kaye-shell.service"])
        }
        "logs" => run_interactive(
            "journalctl",
            &[
                "--user",
                "-u",
                "kaye-shell.service",
                "-n",
                "60",
                "--no-pager",
            ],
        ),
        "status" => run_interactive(
            "systemctl",
            &["--user", "status", "kaye-shell.service", "--no-pager"],
        ),
        other => bail!("Unknown shell action '{other}' (expected reload|restart|status|logs)"),
    }
}
