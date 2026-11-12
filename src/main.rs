use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};

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

const GIT_SUBCMDS: &[&str] = &[
    // Core & Status
    "add",
    "commit",
    "status",
    "diff",
    "log",
    "show",
    "init",
    "config",
    // Branching & Merging
    "branch",
    "checkout",
    "switch",
    "merge",
    "rebase",
    "cherry-pick",
    "revert",
    "bisect",
    // Working tree
    "restore",
    "reset",
    "rm",
    "mv",
    "clean",
    "stash",
    // References
    "tag",
    "reflog",
    "show-ref",
    "symbolic-ref",
    "rev-parse",
    "rev-list",
    "name-rev",
    "merge-base",
    "describe",
    // Inspection & Files
    "blame",
    "grep",
    "shortlog",
    "whatchanged",
    "ls-files",
    "ls-tree",
    "cat-file",
    // Diff & Patch
    "diff-tree",
    "diff-files",
    "diff-index",
    "format-patch",
    "apply",
    "am",
    // Metadata & Verification
    "notes",
    "check-ignore",
    "check-attr",
    "check-mailmap",
    "verify-commit",
    "verify-tag",
    "archive",
];

/// Rewrites explicit git command references in a line to kaye without touching .git repository references
fn rewrite_git_command_references(line: &str) -> String {
    let mut text = line.to_string();

    for &sc in GIT_SUBCMDS {
        // 1. Quoted references: 'git <cmd>', 'git <cmd> ...', "git <cmd>", "git <cmd> ..."
        text = text.replace(&format!("'git {}'", sc), &format!("'kaye {}'", sc));
        text = text.replace(&format!("'git {} ", sc), &format!("'kaye {} ", sc));
        text = text.replace(&format!("\"git {}\"", sc), &format!("\"kaye {}\"", sc));
        text = text.replace(&format!("\"git {} ", sc), &format!("\"kaye {} ", sc));

        // 2. Parenthesized suggestions: (use "git <cmd>...", (use 'git <cmd>...'
        text = text.replace(
            &format!("(use \"git {} ", sc),
            &format!("(use \"kaye {} ", sc),
        );
        text = text.replace(
            &format!("(use 'git {} ", sc),
            &format!("(use 'kaye {} ", sc),
        );
        text = text.replace(
            &format!("(use \"git {}\"", sc),
            &format!("(use \"kaye {}\"", sc),
        );
        text = text.replace(
            &format!("(use 'git {}'", sc),
            &format!("(use 'kaye {}'", sc),
        );

        // 3. See git-<cmd>(1) manual references -> Run 'kaye <cmd> --help'
        text = text.replace(
            &format!("See git-{}(1)", sc),
            &format!("Run 'kaye {} --help'", sc),
        );
        text = text.replace(&format!("git-{}(1)", sc), &format!("kaye-{}", sc));

        // 4. Lines starting with command or indented code blocks (with or without trailing space)
        let trimmed_start = text.trim_start();
        if trimmed_start.starts_with(&format!("git {}", sc)) {
            let after_cmd = &trimmed_start["git ".len() + sc.len()..];
            if after_cmd.is_empty()
                || after_cmd.starts_with(' ')
                || after_cmd.starts_with('\t')
                || after_cmd.starts_with('\n')
                || after_cmd.starts_with(':')
                || after_cmd.starts_with('\'')
                || after_cmd.starts_with('"')
            {
                let leading_len = text.len() - trimmed_start.len();
                let indent = &text[..leading_len];
                let remainder = &trimmed_start[4..]; // skip "git "
                text = format!("{}kaye {}", indent, remainder);
            }
        }

        // 5. Usage & syntax lines: "usage: git <cmd>", "   or: git <cmd>"
        text = text.replace(
            &format!("usage: git {}", sc),
            &format!("usage: kaye {}", sc),
        );
        text = text.replace(
            &format!("   or: git {}", sc),
            &format!("   or: kaye {}", sc),
        );
        text = text.replace(
            &format!("   or:  git {}", sc),
            &format!("   or:  kaye {}", sc),
        );

        // 6. Instruction phrases like "run 'git <cmd> ...'", "with 'git <cmd> ...'"
        text = text.replace(&format!("run 'git {} ", sc), &format!("run 'kaye {} ", sc));
        text = text.replace(
            &format!("run \"git {} ", sc),
            &format!("run \"kaye {} ", sc),
        );
        text = text.replace(
            &format!("with 'git {} ", sc),
            &format!("with 'kaye {} ", sc),
        );
        text = text.replace(
            &format!("with \"git {} ", sc),
            &format!("with \"kaye {} ", sc),
        );
        text = text.replace(&format!("run 'git {}'", sc), &format!("run 'kaye {}'", sc));
        text = text.replace(
            &format!("run \"git {}\"", sc),
            &format!("run \"kaye {}\"", sc),
        );

        // 7. General standalone command occurrences: " git <cmd> " or " git <cmd>"
        text = text.replace(&format!(" git {} ", sc), &format!(" kaye {} ", sc));
        text = text.replace(&format!(" git {}", sc), &format!(" kaye {}", sc));
    }

    text
}

/// Cleans and rewrites Git advice, hints, and command references to KAYE-specific sandbox semantics
fn filter_kaye_output(raw: &str) -> String {
    let mut result = Vec::new();

    for line in raw.lines() {
        let trimmed = line.trim();

        // 1. Strip internal git configuration advice that is irrelevant to local kaye sandbox
        if trimmed.starts_with("hint: Disable this message with \"git config")
            || trimmed.starts_with("hint: Turn off this advice with \"git config")
            || trimmed.starts_with("Turn off this advice by setting config variable advice.")
            || trimmed.contains("git config set advice.")
            || trimmed.contains("advice.addEmptyPathspec")
            || trimmed.contains("advice.statusHints")
            || trimmed.contains("advice.detachedHead")
            || trimmed.contains("--set-upstream-to")
            || trimmed.contains("tracking information for this branch")
            || trimmed.contains("Please specify which branch you want to rebase against")
        {
            continue;
        }

        // 2. Specific case: kaye add without arguments
        if trimmed == "hint: Maybe you wanted to say 'git add .'?" {
            result.push("hint: Maybe you wanted to say 'kaye add .'?".to_string());
            result.push(
                "hint: Or use 'kaye save \"<message>\"' to stage and commit all changes."
                    .to_string(),
            );
            continue;
        }

        let mut processed = line.to_string();

        // 3. Unknown command rewrite: git: 'xyz' is not a git command. See 'git --help'.
        if processed.starts_with("git: '") && processed.contains("is not a git command") {
            processed = processed
                .replace("git: '", "kaye: '")
                .replace("is not a git command", "is not a kaye command")
                .replace("See 'git --help'", "Run 'kaye help'");
        }

        // 4. Status and commit action suggestions
        let replacements = [
            (
                "(use \"git add <file>...\" to update what will be committed)",
                "(use \"kaye add <file>...\" or \"kaye save <msg>\" to checkpoint)",
            ),
            (
                "(use \"git add/rm <file>...\" to update what will be committed)",
                "(use \"kaye add/rm <file>...\" or \"kaye save <msg>\" to checkpoint)",
            ),
            (
                "(use \"git restore <file>...\" to discard changes in working directory)",
                "(use \"kaye restore <file>...\" to discard changes)",
            ),
            (
                "(use \"git checkout -- <file>...\" to discard changes in working directory)",
                "(use \"kaye restore <file>...\" to discard changes)",
            ),
            (
                "(use \"git restore --staged <file>...\" to unstage)",
                "(use \"kaye restore --staged <file>...\" to unstage)",
            ),
            (
                "(use \"git rm --cached <file>...\" to unstage)",
                "(use \"kaye rm --cached <file>...\" to unstage)",
            ),
            (
                "(use \"git reset HEAD <file>...\" to unstage)",
                "(use \"kaye reset HEAD <file>...\" to unstage)",
            ),
            (
                "(use \"git add <file>...\" to include in what will be committed)",
                "(use \"kaye add <file>...\" or \"kaye save <msg>\" to track)",
            ),
            (
                "(use \"git commit -a\" to commit)",
                "(use \"kaye save <msg>\" to commit)",
            ),
            (
                "(use \"git add\" and/or \"git commit -a\")",
                "(use \"kaye add\" and/or \"kaye save <msg>\")",
            ),
            (
                "(use \"git add\" to track)",
                "(use \"kaye add\" or \"kaye save <msg>\" to track)",
            ),
            (
                "git switch -c <new-branch-name>",
                "kaye checkout -b <new-branch-name>",
            ),
            ("git switch -", "kaye checkout -"),
            ("git switch ", "kaye checkout "),
            (
                "did not match any file(s) known to git",
                "did not match any file(s) known to kaye",
            ),
            ("known to git", "known to kaye"),
            ("not tracked by git", "not tracked by kaye"),
        ];

        for (from, to) in replacements {
            processed = processed.replace(from, to);
        }

        // 5. Transform all explicit git subcommand references
        processed = rewrite_git_command_references(&processed);

        result.push(processed);
    }

    if result.is_empty() {
        String::new()
    } else {
        let mut joined = result.join("\n");
        if raw.ends_with('\n') {
            joined.push('\n');
        }
        joined
    }
}

/// Executes a git command isolated inside the `.kaye` database
fn run_kaye_git(root_dir: &Path, args: &[&str], inherit_io: bool) -> i32 {
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

/// Initializes the local `.kaye` sandbox repository
fn cmd_init(current_dir: &Path) {
    let kaye_path = current_dir.join(KAYE_DIR);
    if let Err(e) = fs::create_dir_all(&kaye_path) {
        eprintln!(
            "[kaye error] Failed to create {} directory: {}",
            KAYE_DIR, e
        );
        exit(1);
    }

    // Use `-q` to suppress default "Initialized empty Git repository..." and branch hints
    let code = run_kaye_git(current_dir, &["init", "-q"], true);
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
        eprintln!(
            "[kaye error] No .kaye sandbox directory found at {}.",
            root_dir.display()
        );
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
    if commit_code == 0 {
        println!("[kaye] Success! Checkpoint recorded locally in .kaye/ sandbox (main .git is untouched).");
        println!("[kaye tip] You can save/commit as many local experiments as you want!");
    } else {
        println!("[kaye] No changes detected to save. Working tree is clean.");
    }
    exit(commit_code);
}

/// Handles `kaye status` with explicit sandbox indicators and kaye-specific tips
fn cmd_status(root_dir: &Path, args: &[String]) {
    // Pass machine-readable/compact flags directly to git without custom headers
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

    let kaye_dir = root_dir.join(KAYE_DIR);
    let mut cmd = Command::new("git");

    // Preserve ANSI colors when outputting to an interactive terminal
    if io::stdout().is_terminal() {
        cmd.arg("-c").arg("color.status=always");
    }

    cmd.arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .arg("status")
        .args(args);

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

/// Handles `kaye add` with friendly hints if invoked with empty pathspec
fn cmd_add(root_dir: &Path, args: &[String]) {
    if args.is_empty() {
        println!("Nothing specified, nothing added.");
        println!("hint: Maybe you wanted to say 'kaye add .'?\nhint: Or use 'kaye save \"<message>\"' to stage and commit all changes.");
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
fn cmd_commit(root_dir: &Path, args: &[String]) {
    let has_msg = args.iter().any(|a| a == "-m" || a == "-F" || a == "-C");

    // If no commit message flag is supplied
    if !has_msg {
        let kaye_dir = root_dir.join(KAYE_DIR);
        let status_out = Command::new("git")
            .arg(format!("--git-dir={}", kaye_dir.display()))
            .arg(format!("--work-tree={}", root_dir.display()))
            .arg("status")
            .output();

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
            println!("[kaye] Sandbox is up to date. Use 'kaye save \"<message>\"' when you make changes.");
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
fn cmd_restore(root_dir: &Path, args: &[String]) {
    if args.is_empty() {
        eprintln!("[kaye error] You must specify path(s) to restore.");
        eprintln!("Usage: kaye restore <file|.>");
        eprintln!("Tip  : Run 'kaye restore .' to discard all uncommitted changes in the sandbox.");
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
fn cmd_switch(root_dir: &Path, args: &[String]) {
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
fn cmd_checkout(root_dir: &Path, args: &[String]) {
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
fn cmd_branch(root_dir: &Path, args: &[String]) {
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
fn cmd_merge(root_dir: &Path, args: &[String]) {
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
fn cmd_rebase(root_dir: &Path, args: &[String]) {
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
                println!(
                    "[kaye] No checkpoints recorded yet. Run 'kaye save \"<message>\"' to create one."
                );
                return;
            }

            let stdout = String::from_utf8_lossy(&out.stdout);
            let lines: Vec<&str> = stdout.lines().filter(|l| !l.is_empty()).collect();

            if lines.is_empty() {
                println!(
                    "[kaye] No checkpoints recorded yet. Run 'kaye save \"<message>\"' to create one."
                );
                return;
            }

            println!("=== Keep All Your Experiments CHECKPOINTS ===");
            for (index, line) in lines.iter().enumerate() {
                let parts: Vec<&str> = line.splitn(2, '|').collect();
                if parts.len() == 2 {
                    let num = index + 1;
                    let msg = parts[1];
                    let marker = if num == lines.len() { " (HEAD)" } else { "" };
                    println!("  [{}] {}{}", num, msg, marker);
                }
            }
            println!("=============================================");
            println!(
                "Use 'kaye restore-num <number>' or 'kaye restore-msg \"<keyword>\"' to jump back."
            );
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

/// Parses arguments for `kaye what change [N|all] [+]`
fn parse_what_change_args(args: &[String]) -> (Option<usize>, bool, Vec<String>) {
    let mut count: Option<usize> = Some(1);
    let mut reverse = true; // Default: newest at bottom
    let mut extra = Vec::new();

    for arg in args {
        let trimmed = arg.trim();
        if trimmed == "+" {
            reverse = false; // '+' specifies newest at top
        } else if trimmed.eq_ignore_ascii_case("all") {
            count = None;
        } else if let Ok(n) = trimmed.parse::<usize>() {
            count = Some(n);
        } else if trimmed.starts_with('-') && trimmed[1..].parse::<usize>().is_ok() {
            count = Some(trimmed[1..].parse::<usize>().unwrap());
        } else {
            extra.push(trimmed.to_string());
        }
    }

    (count, reverse, extra)
}

/// Shortcut: `kaye what change [N|all] [+]` -> views checkpoint diffs with newest at bottom by default
fn cmd_what_change(root_dir: &Path, args: &[String]) {
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

    let kaye_dir = root_dir.join(KAYE_DIR);
    let check = Command::new("git")
        .arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .args(["rev-parse", "--verify", "HEAD"])
        .output();

    if let Ok(out) = check {
        if !out.status.success() {
            println!(
                "[kaye] No checkpoints recorded yet. Run 'kaye save \"<message>\"' to create one."
            );
            exit(0);
        }
    }

    let (count, reverse, extra) = parse_what_change_args(args);

    let mut git_args: Vec<String> = vec!["log".to_string(), "-p".to_string()];

    if let Some(n) = count {
        git_args.push(format!("-{}", n));
    }

    if reverse {
        git_args.push("--reverse".to_string());
    }

    git_args.extend(extra);

    let str_args: Vec<&str> = git_args.iter().map(|s| s.as_str()).collect();
    let code = run_kaye_git(root_dir, &str_args, true);
    exit(code);
}

/// Handles `kaye change message <number> "<new message>"`
fn cmd_change_message(root_dir: &Path, args: &[String]) {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("Update the commit message of an existing checkpoint in .kaye sandbox.\n");
        println!("USAGE:");
        println!("  kaye change message <number> \"<new message>\"   (shortcut: kaye c m <number> \"<msg>\")\n");
        println!("EXAMPLES:");
        println!("  kaye change message 3 \"new message\"");
        println!("  kaye c m 3 \"new message\"");
        println!("  kaye cm 3 \"new message\"");
        exit(0);
    }

    let mut target_num: Option<usize> = None;
    let mut new_msg: Option<String> = None;

    let mut iter = args.iter().peekable();
    while let Some(arg) = iter.next() {
        let trimmed = arg.trim();
        if trimmed == "-m" {
            if let Some(m) = iter.next() {
                new_msg = Some(m.trim().to_string());
            }
        } else if trimmed.starts_with("-m=") {
            new_msg = Some(trimmed["-m=".len()..].trim().to_string());
        } else if target_num.is_none() && trimmed.parse::<usize>().is_ok() {
            target_num = trimmed.parse::<usize>().ok();
        } else if new_msg.is_none() {
            new_msg = Some(trimmed.to_string());
        }
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

    let new_msg = match new_msg {
        Some(m) if !m.is_empty() => m,
        _ => {
            print!("[kaye] Enter new message for checkpoint [{}]: ", target_num);
            let _ = io::stdout().flush();
            let mut input = String::new();
            if io::stdin().read_line(&mut input).is_err() || input.trim().is_empty() {
                eprintln!("\n[kaye error] Commit message cannot be empty.");
                exit(1);
            }
            input.trim().to_string()
        }
    };

    let kaye_dir = root_dir.join(KAYE_DIR);
    let output = Command::new("git")
        .arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
        .args([
            "log",
            "--reverse",
            "--format=%H%x1f%T%x1f%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd%x1f%s",
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
        if fields.len() >= 9 {
            commits.push(CommitRecord {
                hash: fields[0].to_string(),
                tree: fields[1].to_string(),
                an: fields[2].to_string(),
                ae: fields[3].to_string(),
                ad: fields[4].to_string(),
                cn: fields[5].to_string(),
                ce: fields[6].to_string(),
                cd: fields[7].to_string(),
                subject: fields[8].to_string(),
            });
        }
    }

    let target_idx = target_num - 1;
    let old_msg = commits[target_idx].subject.clone();

    // Determine parent for the first commit being rewritten
    let mut current_parent = if target_idx > 0 {
        Some(commits[target_idx - 1].hash.clone())
    } else {
        None
    };

    let mut new_head_hash = String::new();

    // Replay commits from target_idx to end
    for (i, c) in commits.iter().enumerate().skip(target_idx) {
        let msg_to_use = if i == target_idx {
            &new_msg
        } else {
            &c.subject
        };

        let mut cmd = Command::new("git");
        cmd.arg(format!("--git-dir={}", kaye_dir.display()))
            .arg(format!("--work-tree={}", root_dir.display()))
            .arg("commit-tree")
            .arg(&c.tree);

        if let Some(ref p) = current_parent {
            cmd.arg("-p").arg(p);
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
        current_parent = Some(commit_hash.clone());
        new_head_hash = commit_hash;
    }

    // Update HEAD ref to point to the rewritten tip
    let update = Command::new("git")
        .arg(format!("--git-dir={}", kaye_dir.display()))
        .arg(format!("--work-tree={}", root_dir.display()))
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
fn cmd_push(root_dir: &Path, args: &[String]) {
    if !root_dir.join(".git").exists() {
        eprintln!("[kaye error] Main .git directory not found in this project.");
        eprintln!("Run 'git init' first before promoting changes to the main Git repository.");
        exit(1);
    }

    let raw_msg = match args {
        [flag, m, ..] if flag == "-m" => m.as_str(),
        [m, ..] => m.as_str(),
        [] => {
            eprintln!("Usage: kaye push \"<commit message>\" | kaye push -");
            eprintln!(
                "Info : Squashes your final working state into 1 clean commit in local .git."
            );
            eprintln!("Tip  : Use '-' to reuse the latest checkpoint message from .kaye/.");
            exit(1);
        }
    };

    let kaye_dir = root_dir.join(KAYE_DIR);

    // Resolve '-' to the latest commit message from .kaye/ HEAD
    let commit_msg = if raw_msg == "-" {
        let output = Command::new("git")
            .arg(format!("--git-dir={}", kaye_dir.display()))
            .arg(format!("--work-tree={}", root_dir.display()))
            .args(["log", "-1", "--format=%s"])
            .output();

        let latest = match output {
            Ok(out) if out.status.success() => {
                String::from_utf8_lossy(&out.stdout).trim().to_string()
            }
            _ => String::new(),
        };

        let clean_latest = if latest.starts_with("[kaye-push sync] ") {
            latest["[kaye-push sync] ".len()..].to_string()
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
        let trimmed = raw_msg.trim();
        if trimmed.is_empty() {
            eprintln!("[kaye error] Commit message cannot be empty.");
            eprintln!("Usage: kaye push \"<commit message>\" | kaye push -");
            exit(1);
        }
        trimmed.to_string()
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

fn print_help() {
    println!(
        "KAYE — Keep All Your Experiments (kaye) v1.0.0
Local Shadow-Git Version Control System for Developers & LLMs

USAGE:
  kaye <command> [args...]

KAYE CUSTOM COMMANDS (With Safe Shortcuts):
  kaye init                        Initialize local sandbox (.kaye/) & update .gitignore
  kaye save, kaye s \"<message>\"    Shortcut: stages all ('add -A') and commits ('commit -m')
  kaye list, kaye l                Show checkpoints as sequential numbers [1], [2], [3]...
  kaye what change, kaye w c       Show checkpoint diffs (default: 1, newest at bottom; '+' for newest at top)
  kaye change message, kaye c m    Change message of a checkpoint by number (e.g. kaye c m 3 \"new message\")
  kaye restore-num, kaye rn <n>    Reset sandbox to a specific checkpoint number from 'kaye list'
  kaye restore-msg, kaye rmsg      Reset sandbox to the latest checkpoint matching message text
  kaye undo, kaye u                Revert to the previous checkpoint ('reset --hard HEAD~1')
  kaye push, kaye p \"<msg>\" | -    Promote final working state into 1 clean commit in local .git ('-' uses latest checkpoint msg)
  kaye remove, kaye rm             Remove the local sandbox (.kaye/) with interactive confirmation

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

    // 1. Protect sandbox isolation: block global git flags that bypass .kaye
    for arg in &args {
        if arg == "-C"
            || arg.starts_with("-C=")
            || arg.starts_with("--git-dir")
            || arg.starts_with("--work-tree")
        {
            eprintln!(
                "[kaye blocked] Direct overriding of '--git-dir', '--work-tree', or '-C' is disabled to preserve sandbox isolation."
            );
            exit(1);
        }
    }

    // 2. Block network/remote commands so .kaye stays 100% local forever
    if matches!(subcmd, "remote" | "fetch" | "pull" | "clone" | "submodule") {
        eprintln!(
            "[kaye blocked] '{}' is disabled. kaye operates strictly as a 100% local sandbox.",
            subcmd
        );
        exit(1);
    }

    // 3. Block configuring remotes via 'kaye config'
    if subcmd == "config" && args.iter().any(|a| a.contains("remote.")) {
        eprintln!("[kaye blocked] Configuring remote repositories is disabled in local sandbox.");
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
        "status" => cmd_status(&root_dir, &args[1..]),
        "add" => cmd_add(&root_dir, &args[1..]),
        "commit" => cmd_commit(&root_dir, &args[1..]),
        "checkout" => cmd_checkout(&root_dir, &args[1..]),
        "branch" => cmd_branch(&root_dir, &args[1..]),
        "restore" => cmd_restore(&root_dir, &args[1..]),
        "switch" => cmd_switch(&root_dir, &args[1..]),
        "merge" => cmd_merge(&root_dir, &args[1..]),
        "rebase" => cmd_rebase(&root_dir, &args[1..]),
        "save" | "s" => cmd_save(&root_dir, &args[1..]),
        "undo" | "u" => cmd_undo(&root_dir),
        "list" | "l" => cmd_list(&root_dir),
        "restore-num" | "rn" => cmd_restore_num(&root_dir, &args[1..]),
        "restore-msg" | "rmsg" => cmd_restore_msg(&root_dir, &args[1..]),
        "what" | "w" => {
            if args.len() > 1 && (args[1] == "change" || args[1] == "c") {
                cmd_what_change(&root_dir, &args[2..]);
            } else {
                eprintln!(
                    "[kaye error] Unknown subcommand for '{}'. Did you mean 'kaye what change' (or 'kaye w c')?",
                    subcmd
                );
                eprintln!("Usage: kaye what change [N|all] [+]  (shortcut: kaye w c)");
                exit(1);
            }
        }
        "what-change" | "whatchange" | "wc" => cmd_what_change(&root_dir, &args[1..]),
        "change" => {
            if args.len() > 1 && (args[1] == "message" || args[1] == "msg" || args[1] == "m") {
                cmd_change_message(&root_dir, &args[2..]);
            } else {
                eprintln!(
                    "[kaye error] Unknown subcommand for 'change'. Did you mean 'kaye change message <number> \"<msg>\"'?"
                );
                eprintln!("Usage: kaye change message <number> \"<new message>\" (shortcut: kaye c m <number> \"<msg>\")");
                exit(1);
            }
        }
        "c" => {
            if args.len() > 1 && (args[1] == "message" || args[1] == "msg" || args[1] == "m") {
                cmd_change_message(&root_dir, &args[2..]);
            } else {
                eprintln!(
                    "[kaye error] Unknown subcommand for 'c'. Did you mean 'kaye c m <number> \"<msg>\"'?"
                );
                eprintln!("Usage: kaye c m <number> \"<new message>\"");
                exit(1);
            }
        }
        "cm" => cmd_change_message(&root_dir, &args[1..]),
        "push" | "p" => cmd_push(&root_dir, &args[1..]),
        // Only trigger sandbox removal for `kaye remove` or bare `kaye rm` (without file args).
        // That way `kaye rm --cached <file>` or `kaye rm <file>` safely passes through to git.
        "remove" => cmd_remove(&root_dir),
        "rm" if args.len() == 1 => cmd_remove(&root_dir),
        _ => {
            let ref_args: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            let code = run_kaye_git(&root_dir, &ref_args, true);
            exit(code);
        }
    }
}
