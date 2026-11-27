use crate::{config, system, theme};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

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

const LUA_KEYBIND_SCANNER: &str = r##"
local kaye_root = os.getenv("_KAYE_SCAN_ROOT") or ""
local user_bindings = os.getenv("_KAYE_SCAN_USER") or ""

local rows = {}

local function clean(value)
  return tostring(value or ""):gsub("[\t\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function norm_keys(value)
  return clean(value):gsub("%s+", " "):upper()
end

local function format_value(value)
  local t = type(value)
  if t == "string" or t == "number" or t == "boolean" then
    return tostring(value)
  elseif t == "table" then
    local keys = {}
    for k in pairs(value) do
      table.insert(keys, k)
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      if type(k) == "number" then
        table.insert(parts, format_value(value[k]))
      else
        table.insert(parts, tostring(k) .. "=" .. format_value(value[k]))
      end
    end
    return table.concat(parts, ", ")
  end
  return ""
end

local function dsp_proxy(path)
  return setmetatable({ _path = path }, {
    __index = function(self, key)
      return dsp_proxy(self._path .. "." .. tostring(key))
    end,
    __call = function(self, ...)
      if self._path == "hl.dsp.exec_cmd" or self._path == "hl.dsp.exec_raw" then
        local first = ...
        return { __kaye_dsp = clean(first) }
      end
      local args = {}
      for i = 1, select("#", ...) do
        local formatted = format_value(select(i, ...))
        if formatted ~= "" then
          table.insert(args, formatted)
        end
      end
      local short = self._path:gsub("^hl%.dsp%.", "")
      return { __kaye_dsp = short .. "(" .. table.concat(args, ", ") .. ")" }
    end,
  })
end

local noop
noop = setmetatable({}, {
  __index = function() return noop end,
  __call = function() return noop end,
  __tostring = function() return "" end,
})

hl = setmetatable({
  dsp = dsp_proxy("hl.dsp"),
  unbind = function(keys)
    local target = norm_keys(keys)
    for i = #rows, 1, -1 do
      if norm_keys(rows[i].keys) == target then
        table.remove(rows, i)
      end
    end
  end,
  bind = function(keys, dispatcher, opts)
    opts = opts or {}
    local cmd = ""
    if type(dispatcher) == "table" and dispatcher.__kaye_dsp then
      cmd = clean(dispatcher.__kaye_dsp)
    elseif type(dispatcher) == "string" then
      cmd = clean(dispatcher)
    elseif type(dispatcher) == "function" then
      cmd = "lua()"
    end
    local desc = clean(opts.description or opts.desc or "")
    if desc == "" then
      desc = cmd
    end
    table.insert(rows, {
      keys = clean(keys),
      description = desc,
      command = cmd,
    })
    return noop
  end,
  get_config = function() return nil end,
}, {
  __index = function() return noop end,
})

debug.sethook(function()
  error("instruction limit exceeded")
end, "", 2000000)

local bootstrap_file = kaye_root .. "/default/hypr/bootstrap.lua"
local bf = io.open(bootstrap_file, "r")
if bf then
  bf:close()
  local ok, init = pcall(dofile, bootstrap_file)
  if ok and type(init) == "function" then
    pcall(init, kaye_root)
  end
end

pcall(require, "default.hypr.helpers")

local default_file = kaye_root .. "/default/hypr/bindings.lua"
local df = io.open(default_file, "r")
if df then
  df:close()
  pcall(dofile, default_file)
end

if user_bindings and user_bindings ~= "" then
  local uf = io.open(user_bindings, "r")
  if uf then
    uf:close()
    pcall(dofile, user_bindings)
  end
end

debug.sethook()

for _, row in ipairs(rows) do
  print(row.keys .. "\t" .. row.description .. "\t" .. row.command)
end
"##;

fn hypr_config_dir() -> Result<PathBuf> {
    if let Ok(xdg) = env::var("XDG_CONFIG_HOME") {
        if !xdg.trim().is_empty() {
            return Ok(PathBuf::from(xdg).join("hypr"));
        }
    }
    Ok(config::home_dir()?.join(".config/hypr"))
}

fn normalize_key_chord(keys: &str) -> String {
    keys.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_uppercase()
}

fn eval_lua_keybindings(
    kaye_root: &Path,
    user_bindings: Option<&Path>,
) -> Option<Vec<KeybindingRow>> {
    let mut cmd = Command::new("lua");
    cmd.args(["-E", "-e", LUA_KEYBIND_SCANNER])
        .env("_KAYE_SCAN_ROOT", kaye_root)
        .env(
            "_KAYE_SCAN_USER",
            user_bindings.unwrap_or_else(|| Path::new("")),
        );

    let output = cmd.output().ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut rows = Vec::new();
    for line in stdout.lines() {
        let mut parts = line.splitn(3, '\t');
        let Some(keys) = parts.next() else {
            continue;
        };
        let Some(description) = parts.next() else {
            continue;
        };
        let command = parts.next().unwrap_or("");
        if !keys.trim().is_empty() {
            rows.push(KeybindingRow {
                keys: keys.trim().to_string(),
                description: description.trim().to_string(),
                command: command.trim().to_string(),
            });
        }
    }
    Some(rows)
}

fn strip_lua_comments(raw: &str) -> String {
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::with_capacity(raw.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '"' || c == '\'' {
            let quote = c;
            out.push(c);
            i += 1;
            while i < chars.len() {
                let ch = chars[i];
                out.push(ch);
                i += 1;
                if ch == '\\' && i < chars.len() {
                    out.push(chars[i]);
                    i += 1;
                } else if ch == quote {
                    break;
                }
            }
            continue;
        }
        if c == '[' && i + 1 < chars.len() && chars[i + 1] == '[' {
            out.push('[');
            out.push('[');
            i += 2;
            while i < chars.len() {
                if chars[i] == ']' && i + 1 < chars.len() && chars[i + 1] == ']' {
                    out.push(']');
                    out.push(']');
                    i += 2;
                    break;
                }
                out.push(chars[i]);
                i += 1;
            }
            continue;
        }
        if c == '-' && i + 1 < chars.len() && chars[i + 1] == '-' {
            i += 2;
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

fn unquote_lua_string(expr: &str) -> Option<String> {
    let s = expr.trim();
    if s.starts_with("[[") && s.ends_with("]]") && s.len() >= 4 {
        return Some(s[2..s.len() - 2].to_string());
    }
    let quote = s.chars().next()?;
    if (quote == '"' || quote == '\'') && s.len() >= 2 && s.ends_with(quote) {
        let inner = &s[1..s.len() - 1];
        let mut out = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                if let Some(next) = chars.next() {
                    out.push(next);
                }
            } else {
                out.push(c);
            }
        }
        return Some(out);
    }
    None
}

fn split_lua_args(arg_str: &str) -> Vec<String> {
    let chars: Vec<char> = arg_str.chars().collect();
    let mut args = Vec::new();
    let mut current = String::new();
    let mut paren = 0usize;
    let mut brace = 0usize;
    let mut bracket = 0usize;
    let mut i = 0;

    while i < chars.len() {
        let c = chars[i];
        if c == '"' || c == '\'' {
            let quote = c;
            current.push(c);
            i += 1;
            while i < chars.len() {
                let ch = chars[i];
                current.push(ch);
                i += 1;
                if ch == '\\' && i < chars.len() {
                    current.push(chars[i]);
                    i += 1;
                } else if ch == quote {
                    break;
                }
            }
            continue;
        }
        if c == '[' && i + 1 < chars.len() && chars[i + 1] == '[' {
            current.push('[');
            current.push('[');
            i += 2;
            while i < chars.len() {
                if chars[i] == ']' && i + 1 < chars.len() && chars[i + 1] == ']' {
                    current.push(']');
                    current.push(']');
                    i += 2;
                    break;
                }
                current.push(chars[i]);
                i += 1;
            }
            continue;
        }

        match c {
            '(' => {
                paren += 1;
                current.push(c);
            }
            ')' => {
                paren = paren.saturating_sub(1);
                current.push(c);
            }
            '{' => {
                brace += 1;
                current.push(c);
            }
            '}' => {
                brace = brace.saturating_sub(1);
                current.push(c);
            }
            '[' => {
                bracket += 1;
                current.push(c);
            }
            ']' => {
                bracket = bracket.saturating_sub(1);
                current.push(c);
            }
            ',' if paren == 0 && brace == 0 && bracket == 0 => {
                args.push(current.trim().to_string());
                current.clear();
            }
            _ => current.push(c),
        }
        i += 1;
    }

    let tail = current.trim();
    if !tail.is_empty() {
        args.push(tail.to_string());
    }
    args
}

fn extract_lua_opt_description(opts: &str) -> Option<String> {
    for key in ["description", "desc"] {
        if let Some(pos) = opts.find(key) {
            let rest = &opts[pos + key.len()..];
            let rest = rest.trim_start();
            if let Some(after_eq) = rest.strip_prefix('=') {
                let val_part = after_eq.trim_start();
                let first_arg = split_lua_args(val_part.trim_end_matches('}'))
                    .into_iter()
                    .next()?;
                if let Some(s) = unquote_lua_string(&first_arg) {
                    return Some(s);
                }
            }
        }
    }
    None
}

/// Pure-Rust fallback parser for Lua Hyprland bindings (`kaye.bind`, `kaye.rebind`,
/// `hl.bind`, `hl.unbind`) when the `lua` interpreter is unavailable.
pub fn parse_lua_bindings_text(raw: &str, rows: &mut Vec<KeybindingRow>) {
    let cleaned = strip_lua_comments(raw);
    let bytes = cleaned.as_bytes();
    let calls = ["kaye.rebind(", "kaye.bind(", "hl.unbind(", "hl.bind("];
    let mut i = 0;

    while i < bytes.len() {
        let matched = calls
            .iter()
            .find(|prefix| cleaned[i..].starts_with(*prefix))
            .copied();

        let Some(call_name) = matched else {
            let ch = cleaned[i..].chars().next().unwrap();
            i += ch.len_utf8();
            continue;
        };

        // Ensure we didn't match inside a longer identifier (e.g. `mykaye.bind(`).
        if i > 0 {
            let prev = cleaned[..i].chars().next_back().unwrap_or(' ');
            if prev.is_alphanumeric() || prev == '_' {
                i += 1;
                continue;
            }
        }

        let args_start = i + call_name.len();
        let rest = &cleaned[args_start..];
        let chars: Vec<(usize, char)> = rest.char_indices().collect();
        let mut depth = 1usize;
        let mut idx = 0usize;
        let mut args_end = None;

        while idx < chars.len() {
            let (byte_pos, c) = chars[idx];
            if c == '"' || c == '\'' {
                let quote = c;
                idx += 1;
                while idx < chars.len() {
                    let (_, ch) = chars[idx];
                    idx += 1;
                    if ch == '\\' && idx < chars.len() {
                        idx += 1;
                    } else if ch == quote {
                        break;
                    }
                }
                continue;
            }
            if c == '[' && idx + 1 < chars.len() && chars[idx + 1].1 == '[' {
                idx += 2;
                while idx < chars.len() {
                    if chars[idx].1 == ']' && idx + 1 < chars.len() && chars[idx + 1].1 == ']' {
                        idx += 2;
                        break;
                    }
                    idx += 1;
                }
                continue;
            }
            if c == '(' {
                depth += 1;
            } else if c == ')' {
                depth -= 1;
                if depth == 0 {
                    args_end = Some(byte_pos);
                    break;
                }
            }
            idx += 1;
        }

        let Some(rel_end) = args_end else {
            break;
        };
        let arg_slice = &rest[..rel_end];
        let args = split_lua_args(arg_slice);

        match call_name {
            "hl.unbind(" => {
                if let Some(keys) = args.first().and_then(|a| unquote_lua_string(a)) {
                    let target = normalize_key_chord(&keys);
                    rows.retain(|r| normalize_key_chord(&r.keys) != target);
                }
            }
            "kaye.bind(" | "kaye.rebind(" => {
                if args.len() >= 3 {
                    if let Some(keys) = unquote_lua_string(&args[0]) {
                        if call_name == "kaye.rebind(" {
                            let target = normalize_key_chord(&keys);
                            rows.retain(|r| normalize_key_chord(&r.keys) != target);
                        }
                        let description =
                            unquote_lua_string(&args[1]).unwrap_or_else(|| args[1].clone());
                        let command =
                            unquote_lua_string(&args[2]).unwrap_or_else(|| args[2].clone());
                        rows.push(KeybindingRow {
                            keys,
                            description: if description.is_empty() {
                                command.clone()
                            } else {
                                description
                            },
                            command,
                        });
                    }
                }
            }
            "hl.bind(" if args.len() >= 2 => {
                if let Some(keys) = unquote_lua_string(&args[0]) {
                    let command = unquote_lua_string(&args[1]).unwrap_or_else(|| args[1].clone());
                    let description = args
                        .get(2)
                        .and_then(|o| extract_lua_opt_description(o))
                        .unwrap_or_else(|| command.clone());
                    rows.push(KeybindingRow {
                        keys,
                        description,
                        command,
                    });
                }
            }
            _ => {}
        }

        i = args_start + rel_end + 1;
    }
}

/// Legacy Hyprlang `.conf` binding parser (`bindd` / `bind`) kept as fallback.
pub fn parse_conf_bindings_text(raw: &str, rows: &mut Vec<KeybindingRow>) {
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

pub fn list_keybindings() -> Result<Vec<KeybindingRow>> {
    let kaye_root = config::kaye_root()?;
    let hypr_dir = hypr_config_dir()?;

    let default_lua = kaye_root.join("default/hypr/bindings.lua");
    let user_lua = hypr_dir.join("bindings.lua");

    if default_lua.is_file() || user_lua.is_file() {
        if let Some(rows) =
            eval_lua_keybindings(&kaye_root, user_lua.is_file().then_some(user_lua.as_path()))
        {
            if !rows.is_empty() {
                return Ok(rows);
            }
        }

        let mut rows = Vec::new();
        if default_lua.is_file() {
            let raw = fs::read_to_string(&default_lua)?;
            parse_lua_bindings_text(&raw, &mut rows);
        }
        if user_lua.is_file() {
            let raw = fs::read_to_string(&user_lua)?;
            parse_lua_bindings_text(&raw, &mut rows);
        }
        return Ok(rows);
    }

    // Legacy `.conf` fallback
    let mut rows = Vec::new();
    for file in [
        kaye_root.join("default/hypr/bindings.conf"),
        hypr_dir.join("bindings.conf"),
    ] {
        if file.is_file() {
            let raw = fs::read_to_string(&file)?;
            parse_conf_bindings_text(&raw, &mut rows);
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

    #[test]
    fn parses_lua_bindings_rebind_and_unbind() {
        let raw = r#"
-- Commented bind should be ignored:
-- kaye.bind("SUPER + Z", "Ignored", "true")
kaye.bind("SUPER + SPACE", "Kaye Menu", kaye.ipc("menu", "toggle", "root"))
kaye.bind("SUPER + RETURN", "Open Terminal", kaye.launch("foot"))
kaye.bind("SUPER + B", "Open Browser", kaye.launch("xdg-open https://"))
hl.bind("SUPER + M", hl.dsp.window.close(), { description = "Close Window" })
kaye.rebind("SUPER + RETURN", "Open Custom Terminal", "alacritty")
hl.unbind("SUPER + B")
"#;
        let mut rows = Vec::new();
        parse_lua_bindings_text(raw, &mut rows);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].keys, "SUPER + SPACE");
        assert_eq!(rows[0].description, "Kaye Menu");
        assert_eq!(rows[1].keys, "SUPER + M");
        assert_eq!(rows[1].description, "Close Window");
        assert_eq!(rows[2].keys, "SUPER + RETURN");
        assert_eq!(rows[2].description, "Open Custom Terminal");
        assert_eq!(rows[2].command, "alacritty");
    }

    #[test]
    fn parses_legacy_conf_bindings_fallback() {
        let raw = "bindd = SUPER, Q, Close Active Window, killactive,\n";
        let mut rows = Vec::new();
        parse_conf_bindings_text(raw, &mut rows);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].keys, "SUPER + Q");
        assert_eq!(rows[0].description, "Close Active Window");
    }

    #[test]
    fn evaluates_repo_lua_bindings_end_to_end() {
        let kaye_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
        let rows = eval_lua_keybindings(&kaye_root, None)
            .expect("lua interpreter should evaluate default/hypr/bindings.lua");
        assert!(
            rows.iter()
                .any(|r| r.keys == "SUPER + SPACE" && r.description == "Kaye Menu"),
            "missing SUPER + SPACE binding"
        );
        assert!(
            rows.iter()
                .any(|r| r.keys == "SUPER + RETURN" && r.description == "Open Terminal"),
            "missing SUPER + RETURN binding"
        );
        assert!(
            rows.iter()
                .any(|r| r.keys == "SUPER + Q" && r.description == "Close Active Window"),
            "missing SUPER + Q binding"
        );
        assert!(
            rows.iter()
                .any(|r| r.keys == "SUPER + 9" && r.description == "Workspace 9"),
            "missing expanded workspace loop binding"
        );
        assert!(
            rows.iter()
                .any(|r| r.keys == "SUPER + SHIFT + 9" && r.description == "Move to Workspace 9"),
            "missing expanded move-to-workspace loop binding"
        );

        let tmp_override =
            env::temp_dir().join(format!("kaye-bindings-test-{}.lua", std::process::id()));
        fs::write(
            &tmp_override,
            r#"
kaye.rebind("SUPER + E", "Open Yazi", kaye.launch("foot -e yazi"))
hl.unbind("SUPER + B")
"#,
        )
        .unwrap();
        let overridden = eval_lua_keybindings(&kaye_root, Some(&tmp_override))
            .expect("lua interpreter should evaluate user override");
        let _ = fs::remove_file(&tmp_override);

        assert!(
            overridden
                .iter()
                .any(|r| r.keys == "SUPER + E" && r.description == "Open Yazi"),
            "expected kaye.rebind override for SUPER + E"
        );
        assert!(
            !overridden.iter().any(|r| r.keys == "SUPER + B"),
            "expected hl.unbind to remove SUPER + B"
        );
    }
}
