use crate::{config, system, theme};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize)]
pub struct RawMenuEntry {
    #[serde(default)]
    pub icon: String,
    pub label: String,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub action: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MenuRow {
    pub id: String,
    pub icon: String,
    pub label: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtext: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_name: Option<String>,
    #[serde(default)]
    pub checked: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct KeybindingRow {
    pub keys: String,
    pub description: String,
    pub command: String,
}

/// Strips `//` and `/* ... */` comments plus trailing commas outside quoted strings.
pub fn strip_jsonc(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut no_comments = String::with_capacity(input.len());
    let mut i = 0;
    let mut in_string = false;
    let mut escaped = false;

    while i < chars.len() {
        let c = chars[i];
        if in_string {
            no_comments.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
            i += 1;
            continue;
        }

        if c == '"' {
            in_string = true;
            no_comments.push(c);
            i += 1;
            continue;
        }

        if c == '/' && i + 1 < chars.len() && chars[i + 1] == '/' {
            i += 2;
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }

        if c == '/' && i + 1 < chars.len() && chars[i + 1] == '*' {
            i += 2;
            while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                i += 1;
            }
            i = (i + 2).min(chars.len());
            continue;
        }

        no_comments.push(c);
        i += 1;
    }

    // Remove trailing commas before `}` or `]`.
    let nc: Vec<char> = no_comments.chars().collect();
    let mut cleaned = String::with_capacity(no_comments.len());
    let mut j = 0;
    in_string = false;
    escaped = false;
    while j < nc.len() {
        let c = nc[j];
        if in_string {
            cleaned.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
            j += 1;
            continue;
        }
        if c == '"' {
            in_string = true;
            cleaned.push(c);
            j += 1;
            continue;
        }
        if c == ',' {
            let mut k = j + 1;
            while k < nc.len() && nc[k].is_whitespace() {
                k += 1;
            }
            if k < nc.len() && (nc[k] == '}' || nc[k] == ']') {
                j += 1;
                continue;
            }
        }
        cleaned.push(c);
        j += 1;
    }

    cleaned
}

pub fn parse_menu_jsonc(raw: &str) -> Result<BTreeMap<String, RawMenuEntry>> {
    let cleaned = strip_jsonc(raw);
    let map: BTreeMap<String, RawMenuEntry> =
        serde_json::from_str(&cleaned).context("Failed to parse menu.jsonc")?;
    Ok(map)
}

pub fn load_merged_menu() -> Result<BTreeMap<String, RawMenuEntry>> {
    let mut merged = BTreeMap::new();
    let default_path = config::kaye_root()?.join("default/kaye/menu.jsonc");
    if default_path.is_file() {
        let raw = fs::read_to_string(&default_path)?;
        merged.extend(parse_menu_jsonc(&raw)?);
    }
    let user_path = config::config_dir()?.join("menu.jsonc");
    if user_path.is_file() {
        let raw = fs::read_to_string(&user_path)?;
        merged.extend(parse_menu_jsonc(&raw)?);
    }
    Ok(merged)
}

pub fn fuzzy_score(query: &str, haystack: &str) -> Option<i32> {
    let q = query.trim().to_ascii_lowercase();
    if q.is_empty() {
        return Some(0);
    }
    let h = haystack.to_ascii_lowercase();
    if h == q {
        return Some(1000);
    }
    if h.starts_with(&q) {
        return Some(800 - (h.len() as i32));
    }
    if let Some(pos) = h.find(&q) {
        return Some(600 - (pos as i32) * 4);
    }

    // Subsequence match with word-boundary bonuses.
    let mut score = 200i32;
    let mut qi = q.chars().peekable();
    let mut prev_matched = false;
    let mut prev_sep = true;
    for ch in h.chars() {
        if let Some(&qc) = qi.peek() {
            if ch == qc {
                qi.next();
                score += if prev_sep { 25 } else { 10 };
                if prev_matched {
                    score += 12;
                }
                prev_matched = true;
            } else {
                prev_matched = false;
            }
        }
        prev_sep = !ch.is_alphanumeric();
    }
    if qi.peek().is_none() {
        Some(score - (h.len() as i32))
    } else {
        None
    }
}

fn direct_children(route: &str, entries: &BTreeMap<String, RawMenuEntry>) -> Vec<MenuRow> {
    let prefix = if route.is_empty() || route == "root" {
        String::new()
    } else {
        format!("{route}.")
    };

    let mut rows = Vec::new();
    for (id, entry) in entries {
        let rest = if prefix.is_empty() {
            if id.contains('.') {
                continue;
            }
            id.as_str()
        } else {
            let Some(after) = id.strip_prefix(&prefix) else {
                continue;
            };
            if after.contains('.') {
                continue;
            }
            after
        };
        let _ = rest;
        let kind = if entry.provider.is_some() {
            "provider"
        } else if entry.action.is_some() {
            "action"
        } else {
            "submenu"
        };
        rows.push(MenuRow {
            id: id.clone(),
            icon: entry.icon.clone(),
            label: entry.label.clone(),
            kind: kind.to_string(),
            action: entry.action.clone(),
            provider: entry.provider.clone(),
            subtext: entry.description.clone(),
            icon_name: None,
            checked: false,
        });
    }
    rows
}

pub fn query_menu(route: &str, search: Option<&str>) -> Result<Vec<MenuRow>> {
    if route == "apps" {
        return scan_desktop_apps(search);
    }
    let entries = load_merged_menu()?;

    if let Some(q) = search.filter(|s| !s.trim().is_empty()) {
        let mut scored: Vec<(i32, MenuRow)> = Vec::new();
        for (id, entry) in &entries {
            if entry.action.is_none() && entry.provider.is_none() {
                continue;
            }
            let combined = format!("{} {} {}", entry.label, id, entry.aliases.join(" "));
            if let Some(score) = fuzzy_score(q, &combined) {
                let kind = if entry.provider.is_some() {
                    "provider"
                } else {
                    "action"
                };
                scored.push((
                    score,
                    MenuRow {
                        id: id.clone(),
                        icon: entry.icon.clone(),
                        label: entry.label.clone(),
                        kind: kind.to_string(),
                        action: entry.action.clone(),
                        provider: entry.provider.clone(),
                        subtext: entry.description.clone().or_else(|| Some(id.clone())),
                        icon_name: None,
                        checked: false,
                    },
                ));
            }
        }
        for app in scan_desktop_apps(Some(q))? {
            let s = fuzzy_score(q, &app.label).unwrap_or(100);
            scored.push((s, app));
        }
        scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.label.cmp(&b.1.label)));
        return Ok(scored.into_iter().map(|(_, r)| r).collect());
    }

    if let Some(entry) = entries.get(route) {
        if let Some(provider) = &entry.provider {
            return provider_items(provider, None);
        }
    }

    Ok(direct_children(route, &entries))
}

pub fn provider_items(provider: &str, search: Option<&str>) -> Result<Vec<MenuRow>> {
    match provider {
        "apps" => scan_desktop_apps(search),
        "themes" => {
            let themes = theme::list_themes()?;
            Ok(themes
                .into_iter()
                .map(|t| MenuRow {
                    id: format!("theme.{}", t.name),
                    icon: "󰸌".to_string(),
                    label: t.name.clone(),
                    kind: "action".to_string(),
                    action: Some(format!("kaye theme set {}", t.name)),
                    provider: None,
                    subtext: Some(format!("{} · {}", t.mode, t.accent)),
                    icon_name: None,
                    checked: t.active,
                })
                .collect())
        }
        "backgrounds" => {
            let bgs = theme::list_backgrounds(None)?;
            Ok(bgs
                .into_iter()
                .map(|p| {
                    let fname = p
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("wallpaper")
                        .to_string();
                    MenuRow {
                        id: format!("bg.{fname}"),
                        icon: "".to_string(),
                        label: fname,
                        kind: "action".to_string(),
                        action: Some(format!("kaye theme bg '{}'", p.display())),
                        provider: None,
                        subtext: Some(p.display().to_string()),
                        icon_name: None,
                        checked: false,
                    }
                })
                .collect())
        }
        "snapshots" => {
            let snaps = system::list_snapshots_raw()?;
            Ok(snaps
                .into_iter()
                .map(|line| MenuRow {
                    id: format!("snap.{line}"),
                    icon: "󰁯".to_string(),
                    label: line,
                    kind: "info".to_string(),
                    action: None,
                    provider: None,
                    subtext: None,
                    icon_name: None,
                    checked: false,
                })
                .collect())
        }
        other => anyhow::bail!("Unknown menu provider '{other}'"),
    }
}

fn clean_exec(raw: &str) -> String {
    raw.split_whitespace()
        .filter(|part| !matches!(*part, "%u" | "%U" | "%f" | "%F" | "%i" | "%c" | "%k"))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn parse_desktop_file(path: &Path) -> Option<MenuRow> {
    let raw = fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    let mut name = String::new();
    let mut comment = String::new();
    let mut exec = String::new();
    let mut icon = String::new();
    let mut keywords = String::new();
    let mut no_display = false;
    let mut hidden = false;
    let mut app_type = String::new();

    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_entry = trimmed == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((k, v)) = trimmed.split_once('=') else {
            continue;
        };
        match k.trim() {
            "Type" => app_type = v.trim().to_string(),
            "Name" if name.is_empty() => name = v.trim().to_string(),
            "Comment" if comment.is_empty() => comment = v.trim().to_string(),
            "Exec" if exec.is_empty() => exec = clean_exec(v.trim()),
            "Icon" if icon.is_empty() => icon = v.trim().to_string(),
            "Keywords" if keywords.is_empty() => keywords = v.trim().to_string(),
            "NoDisplay" => no_display = v.trim().eq_ignore_ascii_case("true"),
            "Hidden" => hidden = v.trim().eq_ignore_ascii_case("true"),
            _ => {}
        }
    }

    if app_type != "Application" || no_display || hidden || name.is_empty() || exec.is_empty() {
        return None;
    }

    let id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(&name)
        .to_string();
    let subtext = if !comment.is_empty() {
        Some(comment)
    } else if !keywords.is_empty() {
        Some(keywords)
    } else {
        None
    };

    Some(MenuRow {
        id: format!("app.{id}"),
        icon: "󰀻".to_string(),
        label: name,
        kind: "app".to_string(),
        action: Some(exec),
        provider: None,
        subtext,
        icon_name: if icon.is_empty() { None } else { Some(icon) },
        checked: false,
    })
}

pub fn scan_desktop_apps(search: Option<&str>) -> Result<Vec<MenuRow>> {
    let home = config::home_dir()?;
    let dirs = vec![
        PathBuf::from("/usr/share/applications"),
        PathBuf::from("/usr/local/share/applications"),
        home.join(".local/share/applications"),
    ];

    // Later directories override earlier ones by filename (XDG desktop spec).
    let mut by_file: BTreeMap<String, PathBuf> = BTreeMap::new();
    for dir in dirs {
        if !dir.is_dir() {
            continue;
        }
        if let Ok(read) = fs::read_dir(&dir) {
            for entry in read.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) == Some("desktop") {
                    if let Some(fname) = path.file_name().and_then(|n| n.to_str()) {
                        by_file.insert(fname.to_string(), path);
                    }
                }
            }
        }
    }

    let q = search.unwrap_or("").trim();
    let mut scored: Vec<(i32, MenuRow)> = Vec::new();
    for path in by_file.values() {
        if let Some(row) = parse_desktop_file(path) {
            if q.is_empty() {
                scored.push((0, row));
            } else {
                let hay = format!(
                    "{} {} {}",
                    row.label,
                    row.id,
                    row.subtext.as_deref().unwrap_or("")
                );
                if let Some(score) = fuzzy_score(q, &hay) {
                    scored.push((score, row));
                }
            }
        }
    }

    scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.label.cmp(&b.1.label)));
    Ok(scored.into_iter().map(|(_, r)| r).collect())
}

pub fn list_keybindings() -> Result<Vec<KeybindingRow>> {
    let mut files = Vec::new();
    let default_bindings = config::kaye_root()?.join("default/hypr/bindings.conf");
    if default_bindings.is_file() {
        files.push(default_bindings);
    }
    let user_bindings = config::home_dir()?.join(".config/hypr/bindings.conf");
    if user_bindings.is_file() {
        files.push(user_bindings);
    }

    let mut rows = Vec::new();
    for file in files {
        let raw = fs::read_to_string(&file)?;
        for line in raw.lines() {
            let trimmed = line.trim();
            if !(trimmed.starts_with("bindd") || trimmed.starts_with("bind "))
                && !trimmed.starts_with("bind=")
                && !trimmed.starts_with("bindd=")
            {
                continue;
            }
            let Some((_, rhs)) = trimmed.split_once('=') else {
                continue;
            };
            let parts: Vec<&str> = rhs.split(',').map(|p| p.trim()).collect();
            if trimmed.starts_with("bindd") && parts.len() >= 4 {
                rows.push(KeybindingRow {
                    keys: format!("{} + {}", parts[0], parts[1]),
                    description: parts[2].to_string(),
                    command: parts[3..].join(", "),
                });
            } else if parts.len() >= 3 {
                rows.push(KeybindingRow {
                    keys: format!("{} + {}", parts[0], parts[1]),
                    description: parts[2..].join(", "),
                    command: parts[2..].join(", "),
                });
            }
        }
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_jsonc_comments_and_trailing_commas() {
        let raw = r#"{
            // Root entry
            "apps": { "icon": "a", "label": "Apps", "action": "https://example.com" },
            /* Multi-line
               comment */
            "system": { "icon": "s", "label": "System", },
        }"#;
        let parsed = parse_menu_jsonc(raw).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(
            parsed["apps"].action.as_deref(),
            Some("https://example.com")
        );
    }

    #[test]
    fn dotted_hierarchy_lists_direct_children_only() {
        let raw = r#"{
            "appearance": { "icon": "a", "label": "Appearance" },
            "appearance.theme": { "icon": "t", "label": "Theme", "provider": "themes" },
            "appearance.bar": { "icon": "b", "label": "Bar" },
            "appearance.bar.top": { "icon": "u", "label": "Top", "action": "kaye bar position top" }
        }"#;
        let map = parse_menu_jsonc(raw).unwrap();
        let root_items = direct_children("root", &map);
        assert_eq!(root_items.len(), 1);
        assert_eq!(root_items[0].id, "appearance");

        let sub = direct_children("appearance", &map);
        assert_eq!(sub.len(), 2);
    }

    #[test]
    fn fuzzy_matcher_ranks_prefix_above_subsequence() {
        let exact = fuzzy_score("fire", "Firefox").unwrap();
        let subseq = fuzzy_score("fire", "File Reader").unwrap();
        assert!(exact > subseq);
        assert!(fuzzy_score("zzz", "Firefox").is_none());
    }
}
