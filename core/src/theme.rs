use crate::config;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct ThemeInfo {
    pub name: String,
    pub mode: String,
    pub accent: String,
    pub background: String,
    pub path: String,
    pub active: bool,
}

fn theme_search_dirs() -> Result<Vec<PathBuf>> {
    Ok(vec![
        config::config_dir()?.join("themes"),
        config::kaye_root()?.join("themes"),
    ])
}

fn template_search_dirs() -> Result<Vec<PathBuf>> {
    Ok(vec![
        config::kaye_root()?.join("default/themed"),
        config::config_dir()?.join("themed"),
    ])
}

pub fn parse_colors_toml(content: &str) -> Result<BTreeMap<String, String>> {
    let table: toml::Table = toml::from_str(content).context("Invalid colors.toml")?;
    let mut map = BTreeMap::new();
    for (k, v) in table {
        if let Some(s) = v.as_str() {
            map.insert(k, s.to_string());
        }
    }
    Ok(map)
}

pub fn hex_to_rgb(hex: &str) -> Option<String> {
    let clean = hex.trim().trim_start_matches('#');
    if clean.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&clean[0..2], 16).ok()?;
    let g = u8::from_str_radix(&clean[2..4], 16).ok()?;
    let b = u8::from_str_radix(&clean[4..6], 16).ok()?;
    Some(format!("{r},{g},{b}"))
}

pub fn render_template(template: &str, colors: &BTreeMap<String, String>) -> String {
    let mut out = String::with_capacity(template.len());
    let bytes = template.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        if i + 1 < bytes.len() && bytes[i] == b'{' && bytes[i + 1] == b'{' {
            if let Some(rel_end) = template[i + 2..].find("}}") {
                let token = template[i + 2..i + 2 + rel_end].trim();
                if let Some(resolved) = resolve_token(token, colors) {
                    out.push_str(&resolved);
                } else {
                    out.push_str(&template[i..i + 4 + rel_end]);
                }
                i += 4 + rel_end;
                continue;
            }
        }
        let ch = template[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }

    out
}

fn resolve_token(token: &str, colors: &BTreeMap<String, String>) -> Option<String> {
    if let Some(key) = token.strip_suffix("_strip") {
        let val = colors.get(key)?;
        return Some(val.trim_start_matches('#').to_string());
    }
    if let Some(key) = token.strip_suffix("_rgb") {
        let val = colors.get(key)?;
        return hex_to_rgb(val);
    }
    colors.get(token).cloned()
}

pub fn current_theme() -> Result<Option<String>> {
    let path = config::state_dir()?.join("current/theme.name");
    if !path.exists() {
        return Ok(None);
    }
    let name = fs::read_to_string(path)?.trim().to_string();
    if name.is_empty() {
        Ok(None)
    } else {
        Ok(Some(name))
    }
}

pub fn list_themes() -> Result<Vec<ThemeInfo>> {
    let active = current_theme()?.unwrap_or_default();
    let mut seen: BTreeMap<String, PathBuf> = BTreeMap::new();

    // User themes override repo themes with the same slug.
    for dir in theme_search_dirs()?.into_iter().rev() {
        if !dir.is_dir() {
            continue;
        }
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() && path.join("colors.toml").is_file() {
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    seen.insert(name.to_string(), path);
                }
            }
        }
    }

    let mut themes = Vec::new();
    for (name, path) in seen {
        let raw = fs::read_to_string(path.join("colors.toml"))?;
        let colors = parse_colors_toml(&raw)?;
        themes.push(ThemeInfo {
            active: name == active,
            mode: colors
                .get("mode")
                .cloned()
                .unwrap_or_else(|| "dark".to_string()),
            accent: colors
                .get("accent")
                .cloned()
                .unwrap_or_else(|| "#89b4fa".to_string()),
            background: colors
                .get("background")
                .cloned()
                .unwrap_or_else(|| "#1e1e2e".to_string()),
            path: path.display().to_string(),
            name,
        });
    }

    Ok(themes)
}

pub fn find_theme_dir(name: &str) -> Result<PathBuf> {
    for dir in theme_search_dirs()? {
        let candidate = dir.join(name);
        if candidate.join("colors.toml").is_file() {
            return Ok(candidate);
        }
    }
    bail!("Theme '{name}' not found")
}

pub fn list_backgrounds(theme_name: Option<&str>) -> Result<Vec<PathBuf>> {
    let target = match theme_name {
        Some(n) => n.to_string(),
        None => current_theme()?.unwrap_or_else(|| "catppuccin".to_string()),
    };
    let dir = find_theme_dir(&target)?.join("backgrounds");
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_file() {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "webp") {
                files.push(path);
            }
        }
    }
    files.sort();
    Ok(files)
}

fn replace_symlink(target: &Path, link_path: &Path) -> Result<()> {
    let tmp_link = link_path.with_extension("link.tmp");
    if tmp_link.exists() || tmp_link.symlink_metadata().is_ok() {
        let _ = fs::remove_file(&tmp_link);
    }
    symlink(target, &tmp_link)?;
    fs::rename(&tmp_link, link_path)?;
    Ok(())
}

pub fn set_background(image_path: &Path) -> Result<()> {
    if !image_path.is_file() {
        bail!("Background image does not exist: {}", image_path.display());
    }
    let current_dir = config::state_dir()?.join("current");
    fs::create_dir_all(&current_dir)?;
    replace_symlink(image_path, &current_dir.join("background"))?;
    Ok(())
}

pub fn set_theme(name: &str) -> Result<PathBuf> {
    let theme_dir = find_theme_dir(name)?;
    let colors_raw = fs::read_to_string(theme_dir.join("colors.toml"))?;
    let colors = parse_colors_toml(&colors_raw)?;

    let current_dir = config::state_dir()?.join("current");
    fs::create_dir_all(&current_dir)?;

    // Render into a clean staging directory before swapping the active directory.
    let stage_dir = current_dir.join("next-theme");
    if stage_dir.exists() {
        fs::remove_dir_all(&stage_dir)?;
    }
    fs::create_dir_all(&stage_dir)?;
    fs::copy(theme_dir.join("colors.toml"), stage_dir.join("colors.toml"))?;

    for tpl_dir in template_search_dirs()? {
        if !tpl_dir.is_dir() {
            continue;
        }
        for entry in fs::read_dir(&tpl_dir)? {
            let path = entry?.path();
            if !path.is_file() {
                continue;
            }
            let Some(fname) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let Some(out_name) = fname.strip_suffix(".tpl") else {
                continue;
            };
            let tpl = fs::read_to_string(&path)?;
            let rendered = render_template(&tpl, &colors);
            fs::write(stage_dir.join(out_name), rendered)?;
        }
    }

    let live_dir = current_dir.join("theme");
    let prev_dir = current_dir.join("prev-theme");
    if prev_dir.exists() {
        let _ = fs::remove_dir_all(&prev_dir);
    }
    if live_dir.exists() {
        fs::rename(&live_dir, &prev_dir)?;
    }
    fs::rename(&stage_dir, &live_dir)?;
    if prev_dir.exists() {
        let _ = fs::remove_dir_all(&prev_dir);
    }

    fs::write(current_dir.join("theme.name"), format!("{name}\n"))?;

    // Set default wallpaper from theme if present.
    if let Ok(bgs) = list_backgrounds(Some(name)) {
        if let Some(first) = bgs.first() {
            let _ = set_background(first);
        }
    }

    // Best-effort live reload for Hyprland (Quickshell watches shell.toml directly).
    let _ = Command::new("hyprctl").arg("reload").output();

    Ok(live_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_hex_to_rgb() {
        assert_eq!(hex_to_rgb("#1e1e2e").as_deref(), Some("30,30,46"));
        assert_eq!(hex_to_rgb("89b4fa").as_deref(), Some("137,180,250"));
        assert_eq!(hex_to_rgb("invalid"), None);
    }

    #[test]
    fn renders_all_placeholder_variants() {
        let colors = parse_colors_toml(
            r##"
mode = "dark"
accent = "#89b4fa"
background = "#1e1e2e"
"##,
        )
        .unwrap();

        let tpl = "mode={{ mode }} hex={{ accent }} strip={{ accent_strip }} rgb={{ background_rgb }} unknown={{ nope }}";
        let rendered = render_template(tpl, &colors);
        assert_eq!(
            rendered,
            "mode=dark hex=#89b4fa strip=89b4fa rgb=30,30,46 unknown={{ nope }}"
        );
    }
}
