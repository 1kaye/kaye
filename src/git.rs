use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::filter::filter_kaye_output;

pub const KAYE_DIR: &str = ".kaye";

/// Traverses upwards from `start_dir` to find the project root containing `.kaye`
pub fn find_kaye_root(start_dir: &Path) -> Option<PathBuf> {
    let mut current = start_dir.to_path_buf();
    loop {
        if current.join(KAYE_DIR).is_dir() {
            return Some(current);
        }
        if !current.pop() {
            return None;
        }
    }
}

/// Appends a line to a file only if an equivalent line does not already exist
pub fn append_unique_line(file_path: &Path, entry: &str) -> io::Result<bool> {
    if let Some(parent) = file_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let existing = fs::read_to_string(file_path).unwrap_or_default();
    let trimmed_entry = entry.trim_end_matches('/');
    let already_exists = existing.lines().any(|line| {
        let l = line.trim().trim_end_matches('/');
        l == trimmed_entry
    });
    if !already_exists {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(file_path)?;
        let prefix = if existing.is_empty() || existing.ends_with('\n') {
            ""
        } else {
            "\n"
        };
        writeln!(file, "{}{}", prefix, entry)?;
        return Ok(true);
    }
    Ok(false)
}

/// Builds a `git` Command pre-configured for the `.kaye` database and project working tree
pub fn kaye_command(root_dir: &Path) -> Command {
    let kaye_dir = root_dir.join(KAYE_DIR);
    let mut cmd = Command::new("git");
    cmd.arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()));
    cmd
}

/// Checks whether `.kaye` already has at least one commit (`HEAD` resolves)
pub fn has_head(root_dir: &Path) -> bool {
    kaye_command(root_dir)
        .args(["rev-parse", "--verify", "HEAD"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Executes a git command isolated inside the `.kaye` database with output rewriting
pub fn run_kaye_git(root_dir: &Path, args: &[&str], inherit_io: bool) -> i32 {
    let kaye_dir = root_dir.join(KAYE_DIR);
    let mut cmd = Command::new("git");
    if io::stdout().is_terminal() {
        cmd.arg("-c").arg("color.ui=always");
    }
    cmd.arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .args(args);

    if !inherit_io {
        cmd.stdout(Stdio::null()).stderr(Stdio::null());
        return match cmd.status() {
            Ok(status) => status.code().unwrap_or(0),
            Err(e) => {
                eprintln!("[kaye error] Failed to execute git: {}", e);
                1
            }
        };
    }

    match cmd.output() {
        Ok(out) => {
            let stdout_str = String::from_utf8_lossy(&out.stdout);
            let stderr_str = String::from_utf8_lossy(&out.stderr);
            let filtered_stdout = filter_kaye_output(&stdout_str);
            let filtered_stderr = filter_kaye_output(&stderr_str);
            if !filtered_stdout.is_empty() {
                print!("{}", filtered_stdout);
                let _ = io::stdout().flush();
            }
            if !filtered_stderr.is_empty() {
                eprint!("{}", filtered_stderr);
                let _ = io::stderr().flush();
            }
            out.status.code().unwrap_or(0)
        }
        Err(e) => {
            eprintln!("[kaye error] Failed to execute git: {}", e);
            1
        }
    }
}
