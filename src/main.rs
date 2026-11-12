use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio, exit};

const KAYE_DIR: &str = ".kaye";

/// Traverses upwards from `start_dir` to find the project root containing `.kaye`
fn find_kaye_root(start_dir: &Path) -> Option<PathBuf> {
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
fn append_unique_line(file_path: &Path, entry: &str) -> std::io::Result<bool> {
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

/// Executes a git command isolated inside the `.kaye` database
fn run_kaye_git(root_dir: &Path, args: &[&str], inherit_io: bool) -> i32 {
    let kaye_dir = root_dir.join(KAYE_DIR);
    let mut cmd = Command::new("git");
    cmd.arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .args(args);

    if inherit_io {
        cmd.stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .stdin(Stdio::inherit());
    } else {
        cmd.stdout(Stdio::null()).stderr(Stdio::null());
    }

    match cmd.status() {
        Ok(status) => status.code().unwrap_or(0),
        Err(e) => {
            eprintln!("[kaye error] Failed to execute git: {}", e);
            1
        }
    }
}

/// Initializes the local `.kaye` sandbox repository
fn cmd_init(current_dir: &Path) {
    let kaye_path = current_dir.join(KAYE_DIR);
    if let Err(e) = fs::create_dir_all(&kaye_path) {
        eprintln!("[kaye error] Failed to create {} directory: {}", KAYE_DIR, e);
        exit(1);
    }

    let code = run_kaye_git(current_dir, &["init"], true);
    if code != 0 {
        eprintln!("[kaye error] Failed to initialize .kaye database");
        exit(code);
    }

    // 1. Ensure .kaye ignores both itself and the primary .git directory
    let exclude_path = kaye_path.join("info").join("exclude");
    let _ = append_unique_line(&exclude_path, ".kaye/");
    let _ = append_unique_line(&exclude_path, ".git/");

    // 2. Ensure the primary .git repository ignores .kaye/ via .gitignore
    let gitignore_path = current_dir.join(".gitignore");
    if let Ok(added) = append_unique_line(&gitignore_path, ".kaye/") {
        if added {
            println!("[kaye] Added '.kaye/' to .gitignore");
        }
    }

    println!("[kaye] Local sandbox ready at {}", kaye_path.display());
}

/// Removes the local `.kaye` sandbox directory with interactive y/n confirmation
fn cmd_remove(root_dir: &Path) {
    let kaye_path = root_dir.join(KAYE_DIR);
    if !kaye_path.exists() {
        eprintln!("[kaye error] No .kaye sandbox directory found at {}.", root_dir.display());
        exit(1);
    }

    print!("[kaye warning] Are you sure you want to remove the .kaye sandbox and all its checkpoints? [y/N]: ");
    let _ = io::stdout().flush();

    let mut input = String::new();
    if io::stdin().read_line(&mut input).is_err() {
        eprintln!("\n[kaye error] Failed to read confirmation input. Aborting.");
        exit(1);
    }

    let answer = input.trim().to_lowercase();
    if answer == "y" || answer == "yes" {
        match fs::remove_dir_all(&kaye_path) {
            Ok(_) => {
                println!("[kaye] Successfully removed local sandbox ({}).", kaye_path.display());
            }
            Err(e) => {
                eprintln!("[kaye error] Failed to remove {}: {}", kaye_path.display(), e);
                exit(1);
            }
        }
    } else {
        println!("[kaye] Removal aborted.");
    }
}

/// Shortcut: `kaye save "<message>"` -> stages all files (`add -A`) and commits (`commit -m "<message>"`)
fn cmd_save(root_dir: &Path, args: &[String]) {
    let raw_msg = match args {
        [flag, m, ..] if flag == "-m" => m.as_str(),
        [m, ..] => m.as_str(),
        [] => "",
    };

    let msg = raw_msg.trim();
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

    let commit_code = run_kaye_git(root_dir, &["commit", "-m", msg], true);
    exit(commit_code);
}

/// Shortcut: `kaye undo` -> hard resets 1 commit back inside `.kaye` with root-commit protection
fn cmd_undo(root_dir: &Path) {
    let kaye_dir = root_dir.join(KAYE_DIR);
    let output = Command::new("git")
        .arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
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
        eprintln!("Tip: Run 'kaye restore .' if you only want to discard uncommitted changes.");
        exit(1);
    }

    println!("[kaye] Reverting working tree to the previous checkpoint (HEAD~1)...");
    let code = run_kaye_git(root_dir, &["reset", "--hard", "HEAD~1"], true);
    exit(code);
}

/// Displays checkpoints as an ordered sequential list (1, 2, 3...) instead of raw SHA hashes
fn cmd_list(root_dir: &Path) {
    let kaye_dir = root_dir.join(KAYE_DIR);
    let output = Command::new("git")
        .arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .args(["log", "--reverse", "--format=%H|%s"])
        .output();

    match output {
        Ok(out) => {
            if !out.status.success() {
                println!("[kaye] No checkpoints recorded yet. Run 'kaye save \"<message>\"' to create one.");
                return;
            }

            let stdout = String::from_utf8_lossy(&out.stdout);
            let lines: Vec<&str> = stdout.lines().filter(|l| !l.is_empty()).collect();

            if lines.is_empty() {
                println!("[kaye] No checkpoints recorded yet. Run 'kaye save \"<message>\"' to create one.");
                return;
            }

            println!("=== KAYE EXPERIMENT CHECKPOINTS ===");
            for (index, line) in lines.iter().enumerate() {
                let parts: Vec<&str> = line.splitn(2, '|').collect();
                if parts.len() == 2 {
                    let num = index + 1;
                    let msg = parts[1];
                    let marker = if num == lines.len() { " (HEAD)" } else { "" };
                    println!("  [{}] {}{}", num, msg, marker);
                }
            }
            println!("===================================");
            println!("Use 'kaye restore-num <number>' or 'kaye restore-msg \"<keyword>\"' to jump back.");
        }
        Err(e) => {
            eprintln!("[kaye error] Failed to read checkpoint history: {}", e);
            exit(1);
        }
    }
}

/// Resets sandbox to a specific checkpoint number from `kaye list`
fn cmd_restore_num(root_dir: &Path, args: &[String]) {
    let target_num: usize = match args.first().and_then(|s| s.parse().ok()) {
        Some(n) => n,
        None => {
            eprintln!("Usage: kaye restore-num <number>");
            eprintln!("Example: kaye restore-num 1");
            exit(1);
        }
    };

    let kaye_dir = root_dir.join(KAYE_DIR);
    let output = Command::new("git")
        .arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .args(["log", "--reverse", "--format=%H|%s"])
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

            let parts: Vec<&str> = lines[target_num - 1].splitn(2, '|').collect();
            let target_hash = parts[0];
            let target_msg = parts.get(1).copied().unwrap_or("");

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

/// Resets sandbox to the latest checkpoint matching a commit message keyword
fn cmd_restore_msg(root_dir: &Path, args: &[String]) {
    let keyword = match args {
        [flag, m, ..] if flag == "-m" => m.as_str(),
        [m, ..] => m.as_str(),
        [] => {
            eprintln!("Usage: kaye restore-msg \"<commit message or keyword>\"");
            eprintln!("Example: kaye restore-msg \"baseline\"");
            exit(1);
        }
    };

    let kaye_dir = root_dir.join(KAYE_DIR);
    let output = Command::new("git")
        .arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .args(["log", "--format=%H|%s"])
        .output();

    match output {
        Ok(out) => {
            if !out.status.success() {
                eprintln!("[kaye error] No checkpoints available to restore.");
                exit(1);
            }

            let stdout = String::from_utf8_lossy(&out.stdout);
            let lines: Vec<&str> = stdout.lines().filter(|l| !l.is_empty()).collect();

            let mut target_hash: Option<String> = None;
            let mut matched_msg = String::new();

            let needle = keyword.to_lowercase();
            for line in lines {
                let parts: Vec<&str> = line.splitn(2, '|').collect();
                if parts.len() == 2 {
                    let h = parts[0];
                    let msg = parts[1];
                    if msg.to_lowercase().contains(&needle) {
                        target_hash = Some(h.to_string());
                        matched_msg = msg.to_string();
                        break;
                    }
                }
            }

            let hash = match target_hash {
                Some(h) => h,
                None => {
                    eprintln!(
                        "[kaye error] No checkpoint found matching message: \"{}\"",
                        keyword
                    );
                    eprintln!("Run 'kaye list' to see all available checkpoints.");
                    exit(1);
                }
            };

            println!("[kaye] Found matching checkpoint: \"{}\"", matched_msg);
            println!("[kaye] Restoring sandbox to this checkpoint...");

            let code = run_kaye_git(root_dir, &["reset", "--hard", &hash], true);
            if code == 0 {
                println!(
                    "[kaye] Sandbox successfully restored to: \"{}\"",
                    matched_msg
                );
            }
            exit(code);
        }
        Err(e) => {
            eprintln!("[kaye error] Failed to read checkpoint history: {}", e);
            exit(1);
        }
    }
}

/// Promotes the final working state from `.kaye` into a single clean commit in the main `.git` repo
fn cmd_push(root_dir: &Path, args: &[String]) {
    if !root_dir.join(".git").exists() {
        eprintln!("[kaye error] Main .git directory not found in this project.");
        eprintln!("Run 'git init' first before promoting changes to the main Git repository.");
        exit(1);
    }

    let commit_msg = match args {
        [flag, m, ..] if flag == "-m" => m.as_str(),
        [m, ..] => m.as_str(),
        [] => {
            eprintln!("Usage: kaye push \"Commit message for main .git\"");
            eprintln!("Info : Squashes your final working state into 1 clean commit in local .git.");
            exit(1);
        }
    };

    // 1. Auto-snapshot any uncommitted changes into .kaye first so both histories stay synced
    let _ = run_kaye_git(root_dir, &["add", "-A"], false);
    let sync_msg = format!("[kaye-push sync] {}", commit_msg);
    let _ = run_kaye_git(root_dir, &["commit", "-m", &sync_msg], false);

    // 2. Guarantee .kaye/ is listed in .gitignore before staging in main .git
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
        .args(["commit", "-m", commit_msg])
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();

    match commit_status {
        Ok(s) if s.success() => {
            println!("[kaye] Success! Recorded as 1 clean commit in your local .git repository.");
            println!("[kaye] Run 'git push' manually when you are ready to upload to GitHub/Remote.");
        }
        Ok(s) => exit(s.code().unwrap_or(1)),
        Err(e) => {
            eprintln!("[kaye error] Failed to execute main git commit: {}", e);
            exit(1);
        }
    }
}

fn print_help() {
    println!(
        "KAYE — Keep All Your Experiments (kaye) v1.0.0
Local Shadow-Git Version Control System for Developers & LLMs

USAGE:
  kaye <command> [args...]

KAYE CUSTOM COMMANDS:
  kaye init                      Initialize local sandbox (.kaye/) & update .gitignore
  kaye save \"<message>\"          Shortcut: runs 'kaye add -A' followed by 'kaye commit -m'
  kaye list                      Show checkpoints as sequential numbers [1], [2], [3]...
  kaye restore-num <number>      Reset sandbox to a specific checkpoint number from 'kaye list'
  kaye restore-msg \"<keyword>\"   Reset sandbox to the latest checkpoint matching message text
  kaye undo                      Revert to the previous checkpoint ('reset --hard HEAD~1')
  kaye push \"<message>\"          Promote final working state into 1 clean commit in local .git
  kaye remove | rm               Remove the local sandbox (.kaye/) with interactive confirmation

STANDARD GIT COMMANDS (100% Isolated Inside .kaye/):
  kaye status                    Show modified files in sandbox
  kaye diff                      Show unstaged line changes across all files
  kaye diff --staged             Show staged line changes
  kaye add <file|.>              Stage files into .kaye
  kaye commit -m \"<message>\"     Record an experimental checkpoint in .kaye
  kaye log --oneline             View raw experimental commit hashes in .kaye
  kaye branch                    List or manage experimental sandbox branches
  kaye checkout -b <branch>      Create and switch to an isolated experimental branch
  kaye reset --hard <hash>       Jump back to any specific checkpoint hash
  kaye restore .                 Discard uncommitted working tree changes"
    );
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        print_help();
        exit(0);
    }

    let subcmd = args[0].as_str();

    if matches!(subcmd, "help" | "--help" | "-h") {
        print_help();
        exit(0);
    }

    // Block network/remote commands so .kaye stays 100% local forever
    if matches!(subcmd, "remote" | "fetch" | "pull" | "clone" | "submodule") {
        eprintln!(
            "[kaye blocked] '{}' is disabled. kaye operates strictly as a 100% local sandbox.",
            subcmd
        );
        exit(1);
    }

    let current_dir = env::current_dir().unwrap_or_else(|e| {
        eprintln!("[kaye error] Failed to read current directory: {}", e);
        exit(1);
    });

    if subcmd == "init" {
        cmd_init(&current_dir);
        return;
    }

    let root_dir = match find_kaye_root(&current_dir) {
        Some(root) => root,
        None => {
            eprintln!(
                "[kaye error] Not a kaye repository (.kaye not found). Run 'kaye init' at the project root first."
            );
            exit(128);
        }
    };

    match subcmd {
        "save" => cmd_save(&root_dir, &args[1..]),
        "undo" => cmd_undo(&root_dir),
        "list" => cmd_list(&root_dir),
        "restore-num" => cmd_restore_num(&root_dir, &args[1..]),
        "restore-msg" => cmd_restore_msg(&root_dir, &args[1..]),
        "push" => cmd_push(&root_dir, &args[1..]),
        "remove" | "rm" => cmd_remove(&root_dir),
        _ => {
            let ref_args: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            let code = run_kaye_git(&root_dir, &ref_args, true);
            exit(code);
        }
    }
}
