use std::collections::HashMap;
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::path::Path;
use std::process::{exit, Command, Stdio};

use serde::Serialize;

use crate::filter::{filter_kaye_output, parse_what_change_args};
use crate::git::{append_unique_line, has_head, kaye_command, run_kaye_git, KAYE_DIR};

#[derive(Serialize)]
struct CheckpointJson {
    num: usize,
    hash: String,
    short_hash: String,
    message: String,
    relative_time: String,
    timestamp: String,
    is_head: bool,
}

#[derive(Serialize)]
struct CheckpointListJson {
    total: usize,
    showing: usize,
    checkpoints: Vec<CheckpointJson>,
}

#[derive(Serialize)]
struct StatusJson {
    branch: String,
    clean: bool,
    staged: Vec<String>,
    modified: Vec<String>,
    untracked: Vec<String>,
    deleted: Vec<String>,
}

fn is_json_flag(arg: &str) -> bool {
    arg == "--json" || arg == "-json"
}

fn join_message_args(args: &[String]) -> String {
    match args {
        [flag, rest @ ..] if flag == "-m" => rest.join(" ").trim().to_string(),
        _ => args.join(" ").trim().to_string(),
    }
}

fn has_yes_flag(args: &[String]) -> bool {
    args.iter().any(|a| a == "-y" || a == "--yes")
}

fn strip_yes_flags(args: &[String]) -> Vec<String> {
    args.iter()
        .filter(|a| *a != "-y" && *a != "--yes")
        .cloned()
        .collect()
}

/// Initializes the local `.kaye` sandbox repository
pub fn cmd_init(current_dir: &Path) {
    let kaye_path = current_dir.join(KAYE_DIR);
    if let Err(e) = fs::create_dir_all(&kaye_path) {
        eprintln!(
            "[kaye error] Failed to create {} directory: {}",
            KAYE_DIR, e
        );
        exit(1);
    }

    let code = run_kaye_git(current_dir, &["init", "-q"], true);
    if code != 0 {
        eprintln!("[kaye error] Failed to initialize .kaye database");
        exit(code);
    }

    // Isolate .kaye/ and .git/ from each other without copying mutable .gitignore rules into exclude
    let exclude_path = kaye_path.join("info").join("exclude");
    let _ = append_unique_line(&exclude_path, ".kaye/");
    let _ = append_unique_line(&exclude_path, ".git/");

    let gitignore_path = current_dir.join(".gitignore");
    if let Ok(added) = append_unique_line(&gitignore_path, ".kaye/") {
        if added {
            println!("[kaye] Added '.kaye/' to .gitignore");
        }
    }

    println!("[kaye] Local sandbox ready at {}", kaye_path.display());
}

/// Prompts the user for `[y/N]` confirmation before destructive sandbox operations
fn confirm_action(prompt: &str) -> bool {
    print!("[kaye warning] {} [y/N]: ", prompt);
    let _ = io::stdout().flush();

    let mut input = String::new();
    if io::stdin().read_line(&mut input).is_err() {
        eprintln!("\n[kaye error] Failed to read confirmation input. Aborting.");
        exit(1);
    }

    let answer = input.trim().to_lowercase();
    answer == "y" || answer == "yes"
}

/// Removes the local `.kaye` sandbox directory with interactive y/n confirmation
pub fn cmd_remove(root_dir: &Path) {
    let kaye_path = root_dir.join(KAYE_DIR);
    if !kaye_path.exists() {
        eprintln!(
            "[kaye error] No .kaye sandbox directory found at {}.",
            root_dir.display()
        );
        exit(1);
    }

    if confirm_action("Are you sure you want to remove the .kaye sandbox and all its checkpoints?") {
        match fs::remove_dir_all(&kaye_path) {
            Ok(_) => {
                println!(
                    "[kaye] Successfully removed local sandbox ({}).",
                    kaye_path.display()
                );
            }
            Err(e) => {
                eprintln!(
                    "[kaye error] Failed to remove {}: {}",
                    kaye_path.display(),
                    e
                );
                exit(1);
            }
        }
    } else {
        println!("[kaye] Removal aborted.");
    }
}

/// Shortcut: `kaye save <message>` -> stages all files (`add -A`) and commits (`commit -m <message>`)
pub fn cmd_save(root_dir: &Path, args: &[String]) {
    let msg = join_message_args(args);
    if msg.is_empty() {
        eprintln!("[kaye error] Commit message is required for 'kaye save'.");
        eprintln!("Usage: kaye save \"<commit message>\"");
        eprintln!("Example: kaye save \"baseline before starting task\"");
        exit(1);
    }

    let add_code = run_kaye_git(root_dir, &["add", "-A"], true);
    if add_code != 0 {
        exit(add_code);
    }

    let commit_code = run_kaye_git(root_dir, &["commit", "-m", &msg], true);
    if commit_code == 0 {
        println!("[kaye] Success! Checkpoint recorded locally in .kaye/ sandbox (main .git is untouched).");
        println!("[kaye tip] You can save/commit as many local experiments as you want!");
    } else {
        println!("[kaye] No changes detected to save. Working tree is clean.");
    }
    exit(commit_code);
}

/// Handles `kaye status` with `--json` / `-json` support, compact passthrough, and human output
pub fn cmd_status(root_dir: &Path, args: &[String]) {
    if args.iter().any(|a| is_json_flag(a)) {
        let output = kaye_command(root_dir)
            .args(["status", "--porcelain=v1", "-b"])
            .output();
        match output {
            Ok(out) if out.status.success() => {
                let raw = String::from_utf8_lossy(&out.stdout);
                let mut branch = String::from("HEAD");
                let mut staged = Vec::new();
                let mut modified = Vec::new();
                let mut untracked = Vec::new();
                let mut deleted = Vec::new();

                for line in raw.lines() {
                    if let Some(rest) = line.strip_prefix("## ") {
                        let cleaned = rest
                            .strip_prefix("No commits yet on ")
                            .or_else(|| rest.strip_prefix("Initial commit on "))
                            .unwrap_or(rest);
                        branch = cleaned
                            .split("...")
                            .next()
                            .unwrap_or(cleaned)
                            .trim()
                            .to_string();
                        continue;
                    }
                    if line.len() < 4 {
                        continue;
                    }
                    let bytes = line.as_bytes();
                    let x = bytes[0] as char;
                    let y = bytes[1] as char;
                    let path = line[3..].to_string();

                    if x == '?' && y == '?' {
                        untracked.push(path);
                        continue;
                    }
                    if matches!(x, 'A' | 'M' | 'D' | 'R' | 'C') {
                        staged.push(path.clone());
                    }
                    if x == 'D' || y == 'D' {
                        deleted.push(path);
                    } else if matches!(y, 'M' | 'T' | 'U') {
                        modified.push(path);
                    }
                }

                let clean = staged.is_empty()
                    && modified.is_empty()
                    && untracked.is_empty()
                    && deleted.is_empty();

                let payload = StatusJson {
                    branch,
                    clean,
                    staged,
                    modified,
                    untracked,
                    deleted,
                };
                match serde_json::to_string_pretty(&payload) {
                    Ok(json) => {
                        println!("{}", json);
                        exit(0);
                    }
                    Err(e) => {
                        eprintln!("[kaye error] Failed to serialize status JSON: {}", e);
                        exit(1);
                    }
                }
            }
            Ok(out) => {
                eprint!(
                    "{}",
                    filter_kaye_output(&String::from_utf8_lossy(&out.stderr))
                );
                exit(out.status.code().unwrap_or(1));
            }
            Err(e) => {
                eprintln!("[kaye error] Failed to execute status: {}", e);
                exit(1);
            }
        }
    }

    let is_compact = args.iter().any(|a| {
        matches!(a.as_str(), "-s" | "--short" | "--porcelain" | "-z")
            || a.starts_with("--porcelain=")
    });
    if is_compact {
        let mut git_args = vec!["status"];
        for a in args {
            git_args.push(a.as_str());
        }
        let code = run_kaye_git(root_dir, &git_args, true);
        exit(code);
    }

    let mut cmd = kaye_command(root_dir);
    if io::stdout().is_terminal() {
        cmd.arg("-c").arg("color.status=always");
    }
    cmd.arg("status").args(args);

    match cmd.output() {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            if !stderr.is_empty() {
                eprint!("{}", filter_kaye_output(&stderr));
            }
            println!("=== KAYE SANDBOX STATUS ===");
            print!("{}", filter_kaye_output(&stdout));
            exit(out.status.code().unwrap_or(0));
        }
        Err(e) => {
            eprintln!("[kaye error] Failed to execute status: {}", e);
            exit(1);
        }
    }
}

/// Displays checkpoints as an ordered sequential list `[1]`, `[2]`, `[3]`... with relative time or JSON
pub fn cmd_list(root_dir: &Path, args: &[String]) {
    let mut json_mode = false;
    let mut limit: Option<usize> = None;

    for arg in args {
        let trimmed = arg.trim();
        if is_json_flag(trimmed) {
            json_mode = true;
        } else if let Ok(n) = trimmed.parse::<usize>() {
            if n > 0 {
                limit = Some(n);
            }
        } else if trimmed == "--help" || trimmed == "-h" {
            println!("List recorded checkpoints in .kaye sandbox.\n");
            println!("USAGE:");
            println!("  kaye list [N] [--json | -json]   (shortcut: kaye l [N] [--json])\n");
            println!("OPTIONS:");
            println!("  N              Show only the latest N checkpoints (keeping original numbers)");
            println!("  --json, -json  Output structured JSON for AI agents and scripts");
            exit(0);
        } else {
            eprintln!("[kaye error] Unknown argument for 'kaye list': {}", trimmed);
            eprintln!("Usage: kaye list [N] [--json | -json]");
            exit(1);
        }
    }

    let output = kaye_command(root_dir)
        .args([
            "log",
            "--reverse",
            "--format=%H%x1f%h%x1f%cr%x1f%cI%x1f%s",
        ])
        .output();

    match output {
        Ok(out) => {
            let mut items: Vec<CheckpointJson> = Vec::new();
            if out.status.success() {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let lines: Vec<&str> = stdout.lines().filter(|l| !l.is_empty()).collect();
                let total = lines.len();
                for (index, line) in lines.iter().enumerate() {
                    let parts: Vec<&str> = line.splitn(5, '\x1f').collect();
                    if parts.len() == 5 {
                        let num = index + 1;
                        items.push(CheckpointJson {
                            num,
                            hash: parts[0].to_string(),
                            short_hash: parts[1].to_string(),
                            relative_time: parts[2].to_string(),
                            timestamp: parts[3].to_string(),
                            message: parts[4].to_string(),
                            is_head: num == total,
                        });
                    }
                }
            }

            let total = items.len();
            let start_idx = match limit {
                Some(n) if n < total => total - n,
                _ => 0,
            };
            let visible: Vec<CheckpointJson> = items.into_iter().skip(start_idx).collect();

            if json_mode {
                let payload = CheckpointListJson {
                    total,
                    showing: visible.len(),
                    checkpoints: visible,
                };
                match serde_json::to_string_pretty(&payload) {
                    Ok(json) => {
                        println!("{}", json);
                        return;
                    }
                    Err(e) => {
                        eprintln!("[kaye error] Failed to serialize checkpoint JSON: {}", e);
                        exit(1);
                    }
                }
            }

            if visible.is_empty() {
                println!(
                    "[kaye] No checkpoints recorded yet. Run 'kaye save \"<message>\"' to create one."
                );
                return;
            }

            if visible.len() < total {
                println!(
                    "=== Keep All Your Experiments CHECKPOINTS (showing last {} of {}) ===",
                    visible.len(),
                    total
                );
            } else {
                println!("=== Keep All Your Experiments CHECKPOINTS ===");
            }

            for cp in &visible {
                let head_marker = if cp.is_head { " (HEAD)" } else { "" };
                println!(
                    "  [{}] {} ({}){}",
                    cp.num, cp.message, cp.relative_time, head_marker
                );
            }
            println!("=============================================");
            println!(
                "Use 'kaye go back <number>' (or 'kaye gb <number>') to jump back."
            );
        }
        Err(e) => {
            eprintln!("[kaye error] Failed to read checkpoint history: {}", e);
            exit(1);
        }
    }
}

/// Completely discards all uncommitted tracked modifications AND untracked files/directories
pub fn cmd_discard(root_dir: &Path, args: &[String]) {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("Discard all uncommitted changes (both tracked edits and untracked files).\n");
        println!("USAGE:");
        println!("  kaye discard [-y|--yes] [path...]\n");
        println!("INFO:");
        println!("  Restores tracked files to HEAD and removes untracked files/directories");
        println!("  while respecting .gitignore, .git/, and .kaye/.");
        exit(0);
    }

    let clean_paths = strip_yes_flags(args);

    let mut status_cmd = kaye_command(root_dir);
    status_cmd.args(["status", "--porcelain"]);
    if !clean_paths.is_empty() {
        status_cmd.arg("--");
        for p in &clean_paths {
            status_cmd.arg(p);
        }
    }
    if let Ok(out) = status_cmd.output() {
        if out.status.success() && String::from_utf8_lossy(&out.stdout).trim().is_empty() {
            println!("[kaye] Working tree is already clean.");
            return;
        }
    }

    if !has_yes_flag(args)
        && !confirm_action("Are you sure you want to discard all uncommitted changes and untracked files?")
    {
        println!("[kaye] Discard aborted.");
        return;
    }

    if has_head(root_dir) {
        let mut restore_args = vec!["restore", "--staged", "--worktree"];
        if clean_paths.is_empty() {
            restore_args.push(".");
        } else {
            for a in &clean_paths {
                restore_args.push(a.as_str());
            }
        }
        let restore_code = run_kaye_git(root_dir, &restore_args, true);
        if restore_code != 0 {
            exit(restore_code);
        }
    } else {
        let _ = run_kaye_git(root_dir, &["rm", "-rf", "--cached", "--ignore-unmatch", "."], false);
    }

    let mut clean_args = vec!["clean", "-fd"];
    if !clean_paths.is_empty() {
        clean_args.push("--");
        for a in &clean_paths {
            clean_args.push(a.as_str());
        }
    }
    let clean_code = run_kaye_git(root_dir, &clean_args, true);
    if clean_code != 0 {
        exit(clean_code);
    }

    println!("[kaye] Discarded all uncommitted changes and untracked files in working tree.");
}

/// Synchronizes current working tree / primary `.git` state into a new `.kaye/` checkpoint
pub fn cmd_sync(root_dir: &Path, args: &[String]) {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("Sync current working tree (e.g. after git pull or branch switch) into .kaye/.\n");
        println!("USAGE:");
        println!("  kaye sync [custom message]");
        exit(0);
    }

    let custom_msg = join_message_args(args);
    let sync_msg = if !custom_msg.is_empty() {
        custom_msg
    } else if root_dir.join(".git").exists() {
        let branch_out = Command::new("git")
            .current_dir(root_dir)
            .args(["rev-parse", "--abbrev-ref", "HEAD"])
            .output();
        let head_out = Command::new("git")
            .current_dir(root_dir)
            .args(["log", "-1", "--format=%h %s"])
            .output();
        match (branch_out, head_out) {
            (Ok(b), Ok(h)) if b.status.success() && h.status.success() => {
                let branch = String::from_utf8_lossy(&b.stdout).trim().to_string();
                let head = String::from_utf8_lossy(&h.stdout).trim().to_string();
                format!("[sync from main .git] {} ({})", branch, head)
            }
            _ => "[sync from main .git]".to_string(),
        }
    } else {
        "[sync working tree]".to_string()
    };

    let add_code = run_kaye_git(root_dir, &["add", "-A"], true);
    if add_code != 0 {
        exit(add_code);
    }

    let diff_clean = kaye_command(root_dir)
        .args(["diff", "--cached", "--quiet"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if diff_clean && has_head(root_dir) {
        println!("[kaye] Sandbox is already in sync with the working tree.");
        return;
    }

    let commit_code = run_kaye_git(root_dir, &["commit", "-m", &sync_msg], true);
    if commit_code == 0 {
        println!("[kaye] Synced working tree into .kaye/ checkpoint: \"{}\"", sync_msg);
    }
    exit(commit_code);
}

/// Prunes unreachable/dangling objects in `.kaye/` left by undo, go back, or change message
pub fn cmd_prune(root_dir: &Path) {
    let expire_code = run_kaye_git(
        root_dir,
        &["reflog", "expire", "--expire=now", "--all"],
        false,
    );
    if expire_code != 0 {
        eprintln!("[kaye error] Failed to expire sandbox reflogs.");
        exit(expire_code);
    }

    let gc_code = run_kaye_git(root_dir, &["gc", "--prune=now", "--quiet"], true);
    if gc_code == 0 {
        println!("[kaye] Pruned dangling sandbox objects and compacted .kaye/ storage.");
    }
    exit(gc_code);
}

/// Handles `kaye add` with friendly hints if invoked with empty pathspec
pub fn cmd_add(root_dir: &Path, args: &[String]) {
    if args.is_empty() {
        println!("Nothing specified, nothing added.");
        println!("hint: Maybe you wanted to say 'kaye add .'?");
        println!("hint: Or use 'kaye save \"<message>\"' to stage and commit all changes.");
        return;
    }

    let mut git_args = vec!["add"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    exit(code);
}

/// Handles `kaye commit` with explicit sandbox awareness and hints for LLMs
pub fn cmd_commit(root_dir: &Path, args: &[String]) {
    let has_msg = args.iter().any(|a| a == "-m" || a == "-F" || a == "-C");
    if !has_msg {
        let status_out = kaye_command(root_dir).arg("status").output();
        let (stdout_str, is_clean) = match status_out {
            Ok(ref out) => {
                let s = String::from_utf8_lossy(&out.stdout).to_string();
                let clean = s.contains("nothing to commit, working tree clean");
                (s, clean)
            }
            _ => (String::new(), false),
        };
        println!("=== KAYE SANDBOX STATUS ===");
        print!("{}", filter_kaye_output(&stdout_str));
        if is_clean {
            println!("---------------------------");
            println!(
                "[kaye] Sandbox is up to date. Use 'kaye save \"<message>\"' when you make changes."
            );
        } else {
            eprintln!("\n[kaye hint] To record a checkpoint in sandbox, provide a commit message:");
            eprintln!("  kaye save \"<message>\"");
            eprintln!("  or: kaye commit -m \"<message>\"");
            exit(1);
        }
        return;
    }

    let mut git_args = vec!["commit"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    if code == 0 {
        println!("[kaye] Committed locally in .kaye/ sandbox (main .git is untouched).");
        println!(
            "[kaye tip] Checkpoints are 100% local. Run 'kaye push \"<msg>\"' only when finalized."
        );
    }
    exit(code);
}

/// Handles `kaye restore` with helpful tips if invoked without arguments
pub fn cmd_restore(root_dir: &Path, args: &[String]) {
    if args.is_empty() {
        eprintln!("[kaye error] You must specify path(s) to restore.");
        eprintln!("Usage: kaye restore <file|.>");
        eprintln!("Tip  : Run 'kaye discard' to discard both tracked edits and untracked files.");
        exit(1);
    }

    let mut git_args = vec!["restore"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    exit(code);
}

/// Handles `kaye switch` with helpful tips if invoked without arguments
pub fn cmd_switch(root_dir: &Path, args: &[String]) {
    if args.is_empty() {
        eprintln!("[kaye error] Missing branch argument.");
        eprintln!("Usage: kaye switch <branch> or kaye checkout -b <new-branch>");
        exit(1);
    }

    let is_new_branch = args.iter().any(|a| a == "-c" || a == "-C");
    let mut git_args = vec!["switch"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    if code == 0 && is_new_branch {
        println!("[kaye] Experimental branch active locally inside .kaye/ sandbox.");
        println!(
            "[kaye tip] You can commit freely here without affecting other branches or main .git."
        );
    }
    exit(code);
}

/// Handles `kaye checkout` with explicit sandbox awareness when switching/creating branches
pub fn cmd_checkout(root_dir: &Path, args: &[String]) {
    let is_new_branch = args.iter().any(|a| a == "-b" || a == "-B");
    let mut git_args = vec!["checkout"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    if code == 0 && is_new_branch {
        println!("[kaye] Experimental branch active locally inside .kaye/ sandbox.");
        println!(
            "[kaye tip] You can commit freely here without affecting other branches or main .git."
        );
    }
    exit(code);
}

/// Handles `kaye branch` with local sandbox guidance
pub fn cmd_branch(root_dir: &Path, args: &[String]) {
    let is_creating = args.len() == 1 && !args[0].starts_with('-');
    let mut git_args = vec!["branch"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    if code == 0 && is_creating {
        println!("[kaye] Created local sandbox branch '{}'.", args[0]);
        println!(
            "[kaye tip] Switch to it with 'kaye checkout {}' to start an isolated experiment.",
            args[0]
        );
    }
    exit(code);
}

/// Handles `kaye merge` with offline sandbox safeguards
pub fn cmd_merge(root_dir: &Path, args: &[String]) {
    if args.is_empty() {
        eprintln!("[kaye error] Branch to merge is required.");
        eprintln!("Usage: kaye merge <branch>");
        eprintln!("Example: kaye merge experiment-refactor");
        exit(1);
    }

    let branch_name = &args[0];
    let mut git_args = vec!["merge"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    if code == 0 {
        println!(
            "[kaye] Successfully merged '{}' locally in .kaye/ sandbox.",
            branch_name
        );
        println!("[kaye tip] This merge is 100% local. Main .git is untouched until you run 'kaye push \"<msg>\".");
    }
    exit(code);
}

/// Handles `kaye rebase` with offline sandbox safeguards
pub fn cmd_rebase(root_dir: &Path, args: &[String]) {
    if args.is_empty() {
        eprintln!("[kaye error] Branch to rebase against is required.");
        eprintln!("Usage: kaye rebase <branch>");
        eprintln!("Example: kaye rebase main");
        exit(1);
    }

    let branch_name = &args[0];
    let mut git_args = vec!["rebase"];
    for a in args {
        git_args.push(a.as_str());
    }
    let code = run_kaye_git(root_dir, &git_args, true);
    if code == 0 {
        println!(
            "[kaye] Successfully rebased against '{}' locally in .kaye/ sandbox.",
            branch_name
        );
        println!("[kaye tip] Rebase is 100% local. Main .git is untouched until you run 'kaye push \"<msg>\".");
    }
    exit(code);
}

/// Shortcut: `kaye undo [-y|--yes]` -> hard resets 1 commit back inside `.kaye` with root-commit protection
pub fn cmd_undo(root_dir: &Path, args: &[String]) {
    let output = kaye_command(root_dir)
        .args(["rev-list", "--count", "HEAD"])
        .output();
    let count: usize = match output {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse()
            .unwrap_or(0),
        _ => 0,
    };

    if count == 0 {
        eprintln!("[kaye] Nothing to undo: no checkpoints have been saved yet.");
        exit(1);
    }
    if count == 1 {
        eprintln!("[kaye] Cannot undo: you are already at the first checkpoint (baseline).");
        eprintln!("Tip: Run 'kaye discard' if you want to discard uncommitted changes.");
        exit(1);
    }

    if !has_yes_flag(args)
        && !confirm_action("Are you sure you want to undo the latest checkpoint (reset --hard HEAD~1)?")
    {
        println!("[kaye] Undo aborted.");
        return;
    }

    println!("[kaye] Reverting working tree to the previous checkpoint (HEAD~1)...");
    let code = run_kaye_git(root_dir, &["reset", "--hard", "HEAD~1"], true);
    exit(code);
}

/// Resets sandbox to a specific checkpoint number from `kaye list`
pub fn cmd_go_back(root_dir: &Path, args: &[String]) {
    let filtered = strip_yes_flags(args);
    let target_num: usize = match filtered.first().and_then(|s| s.parse().ok()) {
        Some(n) => n,
        None => {
            eprintln!("Usage: kaye go back <number> [-y|--yes]  (shortcuts: kaye goback, kaye gb)");
            eprintln!("Example: kaye go back 1");
            exit(1);
        }
    };

    let output = kaye_command(root_dir)
        .args(["log", "--reverse", "--format=%H%x1f%s"])
        .output();

    match output {
        Ok(out) => {
            if !out.status.success() {
                eprintln!("[kaye error] No checkpoints available to restore.");
                exit(1);
            }
            let stdout = String::from_utf8_lossy(&out.stdout);
            let lines: Vec<&str> = stdout.lines().filter(|l| !l.is_empty()).collect();
            if target_num == 0 || target_num > lines.len() {
                eprintln!(
                    "[kaye error] Invalid checkpoint number [{}]. Available range: 1 to {}.",
                    target_num,
                    lines.len()
                );
                exit(1);
            }
            let parts: Vec<&str> = lines[target_num - 1].splitn(2, '\x1f').collect();
            let target_hash = parts[0];
            let target_msg = parts.get(1).copied().unwrap_or("");
            if !has_yes_flag(args)
                && !confirm_action(&format!(
                    "Are you sure you want to reset working tree to checkpoint [{}]: \"{}\"?",
                    target_num, target_msg
                ))
            {
                println!("[kaye] Restore aborted.");
                return;
            }
            println!(
                "[kaye] Restoring sandbox to checkpoint [{}]: \"{}\"...",
                target_num, target_msg
            );
            let code = run_kaye_git(root_dir, &["reset", "--hard", target_hash], true);
            if code == 0 {
                println!("[kaye] Sandbox is now at checkpoint [{}].", target_num);
            }
            exit(code);
        }
        Err(e) => {
            eprintln!("[kaye error] Failed to read checkpoint history: {}", e);
            exit(1);
        }
    }
}

fn flush_what_change_file(
    out: &mut String,
    pending_file: &mut Option<String>,
    file_status: &mut &'static str,
    use_color: bool,
) {
    if let Some(path) = pending_file.take() {
        let badge = match *file_status {
            "NEW" if use_color => "\x1b[32m[NEW]\x1b[0m",
            "DELETED" if use_color => "\x1b[31m[DELETED]\x1b[0m",
            "RENAMED" if use_color => "\x1b[36m[RENAMED]\x1b[0m",
            "MODIFIED" if use_color => "\x1b[33m[MODIFIED]\x1b[0m",
            s => {
                out.push_str(&format!("\n  [{}] {}\n", s, path));
                *file_status = "MODIFIED";
                return;
            }
        };
        out.push_str(&format!("\n  {} \x1b[1m{}\x1b[0m\n", badge, path));
        *file_status = "MODIFIED";
    }
}

fn format_what_change_output(raw: &str, use_color: bool) -> String {
    let mut out = String::new();
    let mut pending_file: Option<String> = None;
    let mut file_status: &'static str = "MODIFIED";
    let mut in_hunk = false;

    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("__KAYE_COMMIT__") {
            flush_what_change_file(&mut out, &mut pending_file, &mut file_status, use_color);
            in_hunk = false;

            let parts: Vec<&str> = rest.splitn(3, '\x1f').collect();
            let hash = parts.first().copied().unwrap_or("");
            let msg = parts.get(1).copied().unwrap_or("");
            let rel_time = parts.get(2).copied().unwrap_or("");

            if !out.is_empty() {
                out.push('\n');
            }
            if use_color {
                out.push_str(&format!(
                    "\x1b[36m================================================================\x1b[0m\n\x1b[1m[{}]\x1b[0m {} \x1b[2m({})\x1b[0m\n\x1b[36m================================================================\x1b[0m\n",
                    hash, msg, rel_time
                ));
            } else {
                out.push_str(&format!(
                    "================================================================\n[{}] {} ({})\n================================================================\n",
                    hash, msg, rel_time
                ));
            }
            continue;
        }

        if let Some(rest) = line.strip_prefix("diff --git ") {
            flush_what_change_file(&mut out, &mut pending_file, &mut file_status, use_color);
            in_hunk = false;
            let path = rest.split(" b/").last().unwrap_or(rest).trim();
            pending_file = Some(path.to_string());
            file_status = "MODIFIED";
            continue;
        }

        if line.starts_with("new file mode ") {
            file_status = "NEW";
            continue;
        }
        if line.starts_with("deleted file mode ") {
            file_status = "DELETED";
            continue;
        }
        if line.starts_with("rename from ") {
            file_status = "RENAMED";
            continue;
        }
        if let Some(new_path) = line.strip_prefix("rename to ") {
            pending_file = Some(new_path.trim().to_string());
            file_status = "RENAMED";
            continue;
        }
        if line.starts_with("index ")
            || line.starts_with("--- ")
            || line.starts_with("+++ ")
            || line.starts_with("old mode ")
            || line.starts_with("new mode ")
            || line.starts_with("similarity index ")
            || line.starts_with("dissimilarity index ")
        {
            continue;
        }

        if line.starts_with("@@ ") {
            flush_what_change_file(&mut out, &mut pending_file, &mut file_status, use_color);
            in_hunk = true;
            if use_color {
                out.push_str(&format!("    \x1b[36m{}\x1b[0m\n", line));
            } else {
                out.push_str(&format!("    {}\n", line));
            }
            continue;
        }

        if line.starts_with("Binary files ") {
            flush_what_change_file(&mut out, &mut pending_file, &mut file_status, use_color);
            in_hunk = false;
            out.push_str("    [binary file changed]\n");
            continue;
        }

        if in_hunk {
            if line.starts_with('+') {
                if use_color {
                    out.push_str(&format!("    \x1b[32m{}\x1b[0m\n", line));
                } else {
                    out.push_str(&format!("    {}\n", line));
                }
            } else if line.starts_with('-') {
                if use_color {
                    out.push_str(&format!("    \x1b[31m{}\x1b[0m\n", line));
                } else {
                    out.push_str(&format!("    {}\n", line));
                }
            } else {
                out.push_str(&format!("    {}\n", line));
            }
        } else if !line.trim().is_empty() {
            out.push_str(&format!("  {}\n", line));
        }
    }

    flush_what_change_file(&mut out, &mut pending_file, &mut file_status, use_color);
    out
}

/// Shortcut: `kaye what change [N|all] [+]` -> views checkpoint diffs with newest at bottom by default
pub fn cmd_what_change(root_dir: &Path, args: &[String]) {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("Show checkpoint diffs and commit patches in .kaye sandbox.\n");
        println!("USAGE:");
        println!("  kaye what change [N|all] [+]   (shortcut: kaye w c [N|all] [+])\n");
        println!("OPTIONS:");
        println!("  N       Number of recent checkpoints to show (default: 1)");
        println!("  all     Show all checkpoints from beginning");
        println!("  +       Display newest checkpoint at top (default is newest at bottom)\n");
        println!("EXAMPLES:");
        println!("  kaye what change       Show patch of latest checkpoint (newest at bottom)");
        println!("  kaye w c 2             Show patches of last 2 checkpoints (shortcut)");
        println!("  kaye what change all   Show patches of all checkpoints (newest at bottom)");
        println!("  kaye w c 2 +           Show patches of last 2 checkpoints (newest at top)");
        exit(0);
    }

    if !has_head(root_dir) {
        println!(
            "[kaye] No checkpoints recorded yet. Run 'kaye save \"<message>\"' to create one."
        );
        exit(0);
    }

    let (count, reverse, extra) = parse_what_change_args(args);
    let mut git_args: Vec<String> = vec![
        "log".to_string(),
        "-p".to_string(),
        "--no-color".to_string(),
        "--format=__KAYE_COMMIT__%h%x1f%s%x1f%ar".to_string(),
    ];
    if let Some(n) = count {
        git_args.push(format!("-{}", n));
    }
    if reverse {
        git_args.push("--reverse".to_string());
    }
    git_args.extend(extra);

    let output = kaye_command(root_dir).args(&git_args).output();
    match output {
        Ok(out) => {
            if !out.status.success() {
                let err = filter_kaye_output(&String::from_utf8_lossy(&out.stderr));
                if !err.is_empty() {
                    eprint!("{}", err);
                }
                exit(out.status.code().unwrap_or(1));
            }
            let raw = String::from_utf8_lossy(&out.stdout);
            let formatted = format_what_change_output(&raw, io::stdout().is_terminal());
            print!("{}", formatted);
        }
        Err(e) => {
            eprintln!("[kaye error] Failed to read checkpoint diff: {}", e);
            exit(1);
        }
    }
}

/// Handles `kaye change message <number> <new message>` (supports multi-word unquoted messages and preserves merge topology)
pub fn cmd_change_message(root_dir: &Path, args: &[String]) {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("Update the commit message of an existing checkpoint in .kaye sandbox.\n");
        println!("USAGE:");
        println!("  kaye change message <number> \"<new message>\"   (shortcut: kaye c m <number> \"<msg>\")\n");
        println!("EXAMPLES:");
        println!("  kaye change message 3 \"new message\"");
        println!("  kaye c m 3 \"new message\"");
        println!("  kaye cm 3 new message without quotes");
        exit(0);
    }

    let mut target_num: Option<usize> = None;
    let mut msg_parts: Vec<String> = Vec::new();

    for arg in args {
        let trimmed = arg.trim();
        if target_num.is_none() {
            if let Ok(n) = trimmed.parse::<usize>() {
                target_num = Some(n);
                continue;
            }
        }
        if trimmed == "-m" && msg_parts.is_empty() {
            continue;
        }
        if let Some(stripped) = trimmed.strip_prefix("-m=") {
            if msg_parts.is_empty() {
                msg_parts.push(stripped.trim().to_string());
                continue;
            }
        }
        msg_parts.push(trimmed.to_string());
    }

    let target_num = match target_num {
        Some(n) => n,
        None => {
            eprintln!("[kaye error] Checkpoint number is required.");
            eprintln!("Usage: kaye change message <number> \"<new message>\" (or: kaye c m <number> \"<msg>\")");
            eprintln!("Example: kaye change message 3 \"new message\"");
            exit(1);
        }
    };

    let joined_msg = msg_parts.join(" ").trim().to_string();
    let new_msg = if !joined_msg.is_empty() {
        joined_msg
    } else {
        print!("[kaye] Enter new message for checkpoint [{}]: ", target_num);
        let _ = io::stdout().flush();
        let mut input = String::new();
        if io::stdin().read_line(&mut input).is_err() || input.trim().is_empty() {
            eprintln!("\n[kaye error] Commit message cannot be empty.");
            exit(1);
        }
        input.trim().to_string()
    };

    let output = kaye_command(root_dir)
        .args([
            "log",
            "--reverse",
            "--format=%H%x1f%P%x1f%T%x1f%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd%x1f%s",
        ])
        .output();

    let stdout = match output {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).to_string(),
        _ => {
            eprintln!("[kaye error] No checkpoints recorded yet.");
            exit(1);
        }
    };

    let records: Vec<&str> = stdout.lines().filter(|l| !l.trim().is_empty()).collect();
    if records.is_empty() {
        eprintln!("[kaye error] No checkpoints recorded yet.");
        exit(1);
    }

    if target_num == 0 || target_num > records.len() {
        eprintln!(
            "[kaye error] Invalid checkpoint number [{}]. Available range: 1 to {}.",
            target_num,
            records.len()
        );
        exit(1);
    }

    struct CommitRecord {
        hash: String,
        parents: Vec<String>,
        tree: String,
        an: String,
        ae: String,
        ad: String,
        cn: String,
        ce: String,
        cd: String,
        subject: String,
    }

    let mut commits = Vec::new();
    for rec in &records {
        let fields: Vec<&str> = rec.split('\x1f').collect();
        if fields.len() >= 10 {
            let parents: Vec<String> = fields[1]
                .split_whitespace()
                .map(|s| s.to_string())
                .collect();
            commits.push(CommitRecord {
                hash: fields[0].to_string(),
                parents,
                tree: fields[2].to_string(),
                an: fields[3].to_string(),
                ae: fields[4].to_string(),
                ad: fields[5].to_string(),
                cn: fields[6].to_string(),
                ce: fields[7].to_string(),
                cd: fields[8].to_string(),
                subject: fields[9].to_string(),
            });
        }
    }

    let target_idx = target_num - 1;
    let old_msg = commits[target_idx].subject.clone();

    let mut hash_map: HashMap<String, String> = HashMap::new();
    let mut new_head_hash = String::new();

    for (i, c) in commits.iter().enumerate().skip(target_idx) {
        let msg_to_use = if i == target_idx {
            &new_msg
        } else {
            &c.subject
        };

        let mut cmd = kaye_command(root_dir);
        cmd.arg("commit-tree").arg(&c.tree);

        for parent in &c.parents {
            let mapped = hash_map.get(parent).unwrap_or(parent);
            cmd.arg("-p").arg(mapped);
        }

        cmd.arg("-m").arg(msg_to_use);
        cmd.env("GIT_AUTHOR_NAME", &c.an)
            .env("GIT_AUTHOR_EMAIL", &c.ae)
            .env("GIT_AUTHOR_DATE", &c.ad)
            .env("GIT_COMMITTER_NAME", &c.cn)
            .env("GIT_COMMITTER_EMAIL", &c.ce)
            .env("GIT_COMMITTER_DATE", &c.cd);

        let out = match cmd.output() {
            Ok(o) if o.status.success() => o,
            Ok(o) => {
                eprintln!(
                    "[kaye error] Failed to rewrite commit {}: {}",
                    i + 1,
                    String::from_utf8_lossy(&o.stderr)
                );
                exit(1);
            }
            Err(e) => {
                eprintln!("[kaye error] Failed to execute git commit-tree: {}", e);
                exit(1);
            }
        };

        let commit_hash = String::from_utf8_lossy(&out.stdout).trim().to_string();
        hash_map.insert(c.hash.clone(), commit_hash.clone());
        new_head_hash = commit_hash;
    }

    let update = kaye_command(root_dir)
        .args(["update-ref", "HEAD", &new_head_hash])
        .output();

    match update {
        Ok(out) if out.status.success() => {
            println!(
                "[kaye] Successfully updated checkpoint [{}] message:",
                target_num
            );
            println!("  Old: \"{}\"", old_msg);
            println!("  New: \"{}\"", new_msg);
        }
        _ => {
            eprintln!("[kaye error] Failed to update HEAD reference in .kaye");
            exit(1);
        }
    }
}

/// Promotes the final working state from `.kaye` into a single clean commit in the main `.git` repo
pub fn cmd_push(root_dir: &Path, args: &[String]) {
    if !root_dir.join(".git").exists() {
        eprintln!("[kaye error] Main .git directory not found in this project.");
        eprintln!("Run 'git init' first before promoting changes to the main Git repository.");
        exit(1);
    }

    let raw_msg = join_message_args(args);
    if raw_msg.is_empty() {
        eprintln!("Usage: kaye push \"<commit message>\" | kaye push -");
        eprintln!("Info : Squashes your final working state into 1 clean commit in local .git.");
        eprintln!("Tip  : Use '-' to reuse the latest checkpoint message from .kaye/.");
        exit(1);
    }

    // Ensure .kaye working tree is completely clean before promoting to main .git
    let status_out = kaye_command(root_dir)
        .args(["status", "--porcelain"])
        .output();
    let is_clean = match status_out {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().is_empty(),
        _ => false,
    };
    if !is_clean {
        eprintln!("[kaye error] Your .kaye sandbox working tree is not clean.");
        eprintln!("Please save or discard uncommitted changes before running 'kaye push':");
        eprintln!("  kaye save \"<message>\"   (to checkpoint changes first)");
        eprintln!("  kaye discard            (to discard uncommitted changes)");
        exit(1);
    }

    let commit_msg = if raw_msg == "-" {
        let output = kaye_command(root_dir)
            .args(["log", "-1", "--format=%s"])
            .output();
        let latest = match output {
            Ok(out) if out.status.success() => {
                String::from_utf8_lossy(&out.stdout).trim().to_string()
            }
            _ => String::new(),
        };
        let clean_latest = if let Some(stripped) = latest.strip_prefix("[kaye-push sync] ") {
            stripped.to_string()
        } else {
            latest
        };
        if clean_latest.is_empty() {
            eprintln!("[kaye error] No checkpoints found in .kaye/ to use as commit message.");
            eprintln!("Please specify a commit message: kaye push \"<message>\"");
            exit(1);
        }
        println!(
            "[kaye] Using latest checkpoint message: \"{}\"",
            clean_latest
        );
        clean_latest
    } else {
        raw_msg
    };

    // 1. Guarantee .kaye/ is listed in .gitignore before staging in main .git
    let gitignore_path = root_dir.join(".gitignore");
    let _ = append_unique_line(&gitignore_path, ".kaye/");

    println!("[kaye] Promoting current working state to the main .git repository...");

    // 3. Stage all files in the main .git repository
    let add_status = Command::new("git")
        .current_dir(root_dir)
        .args(["add", "-A"])
        .status();
    if add_status.map(|s| !s.success()).unwrap_or(true) {
        eprintln!("[kaye error] Failed to run 'git add -A' on main .git repository.");
        exit(1);
    }

    // 4. Create the clean commit in the main .git repository
    let commit_status = Command::new("git")
        .current_dir(root_dir)
        .args(["commit", "-m", &commit_msg])
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();

    match commit_status {
        Ok(s) if s.success() => {
            println!("[kaye] Success! Recorded as 1 clean commit in your local .git repository.");
            println!(
                "[kaye] Run 'git push' manually when you are ready to upload to GitHub/Remote."
            );
        }
        Ok(s) => exit(s.code().unwrap_or(1)),
        Err(e) => {
            eprintln!("[kaye error] Failed to execute main git commit: {}", e);
            exit(1);
        }
    }
}

/// Handles `kaye .gitignore` -> displays active `.gitignore` patterns respected natively by `.kaye`
pub fn cmd_gitignore(root_dir: &Path) {
    let gitignore_path = root_dir.join(".gitignore");
    let Ok(content) = fs::read_to_string(&gitignore_path) else {
        println!("[kaye] No .gitignore file found at {}.", root_dir.display());
        return;
    };

    let entries: Vec<&str> = content
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect();

    println!("=== KAYE ACTIVE .GITIGNORE PATTERNS ===");
    if entries.is_empty() {
        println!("  (none)");
    } else {
        for entry in entries {
            println!("  - {}", entry);
        }
    }
    println!("  (plus internal excludes: .kaye/, .git/)");
    println!("=======================================");
}
