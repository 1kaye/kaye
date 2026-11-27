use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdleConfig {
    #[serde(default = "default_screensaver")]
    pub screensaver: u64,
    #[serde(default = "default_lock")]
    pub lock: u64,
}

fn default_screensaver() -> u64 {
    180
}

fn default_lock() -> u64 {
    300
}

impl Default for IdleConfig {
    fn default() -> Self {
        Self {
            screensaver: default_screensaver(),
            lock: default_lock(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BarConfig {
    #[serde(default = "default_bar_position")]
    pub position: String,
    #[serde(default = "default_bar_background")]
    pub background: String,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default = "default_bar_height")]
    pub height: u32,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

fn default_bar_position() -> String {
    "top".to_string()
}

fn default_bar_background() -> String {
    "opaque".to_string()
}

fn default_bar_height() -> u32 {
    30
}

impl Default for BarConfig {
    fn default() -> Self {
        Self {
            position: default_bar_position(),
            background: default_bar_background(),
            hidden: false,
            height: default_bar_height(),
            extra: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShellConfig {
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(default)]
    pub idle: IdleConfig,
    #[serde(default)]
    pub bar: BarConfig,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

fn default_version() -> u32 {
    1
}

impl Default for ShellConfig {
    fn default() -> Self {
        Self {
            version: default_version(),
            idle: IdleConfig::default(),
            bar: BarConfig::default(),
            extra: BTreeMap::new(),
        }
    }
}

pub fn home_dir() -> Result<PathBuf> {
    env::var("HOME")
        .map(PathBuf::from)
        .context("HOME environment variable is not set")
}

pub fn kaye_root() -> Result<PathBuf> {
    if let Ok(path) = env::var("KAYE_PATH") {
        if !path.trim().is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    Ok(home_dir()?.join("kaye"))
}

pub fn config_dir() -> Result<PathBuf> {
    if let Ok(xdg) = env::var("XDG_CONFIG_HOME") {
        if !xdg.trim().is_empty() {
            return Ok(PathBuf::from(xdg).join("kaye"));
        }
    }
    Ok(home_dir()?.join(".config/kaye"))
}

pub fn state_dir() -> Result<PathBuf> {
    if let Ok(xdg) = env::var("XDG_STATE_HOME") {
        if !xdg.trim().is_empty() {
            return Ok(PathBuf::from(xdg).join("kaye"));
        }
    }
    Ok(home_dir()?.join(".local/state/kaye"))
}

pub fn shell_config_path() -> Result<PathBuf> {
    Ok(config_dir()?.join("shell.json"))
}

pub fn load_shell_config() -> Result<ShellConfig> {
    let path = shell_config_path()?;
    if !path.exists() {
        return Ok(ShellConfig::default());
    }
    let raw =
        fs::read_to_string(&path).with_context(|| format!("Failed to read {}", path.display()))?;
    let cfg: ShellConfig = serde_json::from_str(&raw)
        .with_context(|| format!("Failed to parse {}", path.display()))?;
    Ok(cfg)
}

pub fn save_shell_config(cfg: &ShellConfig) -> Result<()> {
    let path = shell_config_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(cfg)?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, format!("{json}\n"))?;
    fs::rename(&tmp, &path)?;
    Ok(())
}

pub fn toggle_flag_path(name: &str) -> Result<PathBuf> {
    Ok(state_dir()?.join("toggles").join(name))
}

pub fn set_toggle(name: &str, mode: &str) -> Result<bool> {
    let path = toggle_flag_path(name)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let currently_on = path.exists();
    let next_on = match mode {
        "on" => true,
        "off" => false,
        "toggle" => !currently_on,
        "status" => return Ok(currently_on),
        other => anyhow::bail!("Unknown toggle mode '{other}' (expected on|off|toggle|status)"),
    };

    if next_on {
        fs::write(&path, "1\n")?;
    } else if path.exists() {
        fs::remove_file(&path)?;
    }
    Ok(next_on)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_shell_config_roundtrip() {
        let cfg = ShellConfig::default();
        let json = serde_json::to_string_pretty(&cfg).unwrap();
        let parsed: ShellConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.bar.position, "top");
        assert_eq!(parsed.bar.background, "opaque");
        assert_eq!(parsed.idle.lock, 300);
    }

    #[test]
    fn preserves_extra_fields() {
        let raw =
            r#"{"version":1,"bar":{"position":"bottom","customWidget":true},"userNote":"hi"}"#;
        let parsed: ShellConfig = serde_json::from_str(raw).unwrap();
        assert_eq!(parsed.bar.position, "bottom");
        assert_eq!(
            parsed.bar.extra.get("customWidget"),
            Some(&Value::Bool(true))
        );
        assert_eq!(
            parsed.extra.get("userNote"),
            Some(&Value::String("hi".to_string()))
        );
    }
}
