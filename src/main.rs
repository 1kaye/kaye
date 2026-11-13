mod commands;
mod filter;
mod git;

use std::env;
use std::process::exit;

use git::find_kaye_root;

fn print_help() {
    println!(
        "KAYE - Keep All Your Experiments (kaye) v1.1.0
Local Shadow-Git Version Control System for Developers & LLMs

USAGE:
  kaye <command> [args...]

KAYE CUSTOM COMMANDS (With Safe Shortcuts):
  kaye init                        Initialize local sandbox (.kaye/) & update .gitignore
  kaye save, kaye s <message>      Stage all ('add -A') and commit checkpoint in .kaye/
  kaye list, kaye l [N] [--json]   Show checkpoints [1], [2], ... with relative time (or JSON)
  kaye what change, kaye w c       Show checkpoint diffs (default: 1, newest at bottom; '+' for top)
  kaye change message, kaye c m    Change message of checkpoint <n> (e.g. kaye c m 3 new message)
  kaye go back, kaye gb <n>        Reset sandbox to checkpoint number <n> from 'kaye list'
  kaye undo, kaye u                Revert to the previous checkpoint ('reset --hard HEAD~1')
  kaye discard                     Discard all uncommitted tracked & untracked working changes
  kaye sync [message]              Sync current working tree / main .git state into .kaye/
  kaye prune                       Prune dangling objects and compact .kaye/ storage
  kaye push, kaye p <msg> | -      Promote final working state into 1 clean commit in local .git
  kaye .gitignore                  Show active .gitignore patterns respected by .kaye/
  kaye remove, kaye rm             Remove the local sandbox (.kaye/) with interactive confirmation

STANDARD GIT COMMANDS (100% Isolated Inside .kaye/):
  kaye status [--json]             Show modified/untracked files in sandbox (or JSON)
  kaye diff                        Show unstaged line changes across all files
  kaye diff --staged             Show staged line changes
  kaye add <file|.>              Stage files into .kaye
  kaye commit -m \"<message>\"     Record an experimental checkpoint in .kaye
  kaye log --oneline             View raw experimental commit hashes in .kaye
  kaye branch                    List or manage experimental sandbox branches
  kaye checkout -b <branch>      Create and switch to an isolated experimental branch
  kaye reset --hard <hash>       Jump back to any specific checkpoint hash
  kaye restore .                 Discard uncommitted tracked file changes"
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
        commands::cmd_init(&current_dir);
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
        "status" => commands::cmd_status(&root_dir, &args[1..]),
        "add" => commands::cmd_add(&root_dir, &args[1..]),
        "commit" => commands::cmd_commit(&root_dir, &args[1..]),
        "checkout" => commands::cmd_checkout(&root_dir, &args[1..]),
        "branch" => commands::cmd_branch(&root_dir, &args[1..]),
        "restore" => commands::cmd_restore(&root_dir, &args[1..]),
        "switch" => commands::cmd_switch(&root_dir, &args[1..]),
        "merge" => commands::cmd_merge(&root_dir, &args[1..]),
        "rebase" => commands::cmd_rebase(&root_dir, &args[1..]),
        "save" | "s" => commands::cmd_save(&root_dir, &args[1..]),
        "undo" | "u" => commands::cmd_undo(&root_dir, &args[1..]),
        "discard" => commands::cmd_discard(&root_dir, &args[1..]),
        "sync" => commands::cmd_sync(&root_dir, &args[1..]),
        "prune" => commands::cmd_prune(&root_dir),
        "list" | "l" => commands::cmd_list(&root_dir, &args[1..]),
        "go" => {
            if args.len() > 1 && args[1] == "back" {
                commands::cmd_go_back(&root_dir, &args[2..]);
            } else {
                eprintln!(
                    "[kaye error] Unknown subcommand for 'go'. Did you mean 'kaye go back <number>' (or 'kaye gb <number>')?"
                );
                eprintln!("Usage: kaye go back <number> [-y|--yes]  (shortcuts: kaye goback, kaye gb)");
                exit(1);
            }
        }
        "goback" | "gb" => commands::cmd_go_back(&root_dir, &args[1..]),
        "what" | "w" => {
            if args.len() > 1 && (args[1] == "change" || args[1] == "c") {
                commands::cmd_what_change(&root_dir, &args[2..]);
            } else {
                eprintln!(
                    "[kaye error] Unknown subcommand for '{}'. Did you mean 'kaye what change' (or 'kaye w c')?",
                    subcmd
                );
                eprintln!("Usage: kaye what change [N|all] [+]  (shortcut: kaye w c)");
                exit(1);
            }
        }
        "what-change" | "whatchange" | "wc" => commands::cmd_what_change(&root_dir, &args[1..]),
        "change" => {
            if args.len() > 1 && (args[1] == "message" || args[1] == "msg" || args[1] == "m") {
                commands::cmd_change_message(&root_dir, &args[2..]);
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
                commands::cmd_change_message(&root_dir, &args[2..]);
            } else {
                eprintln!(
                    "[kaye error] Unknown subcommand for 'c'. Did you mean 'kaye c m <number> \"<msg>\"'?"
                );
                eprintln!("Usage: kaye c m <number> \"<new message>\"");
                exit(1);
            }
        }
        "cm" => commands::cmd_change_message(&root_dir, &args[1..]),
        ".gitignore" => commands::cmd_gitignore(&root_dir),
        "push" | "p" => commands::cmd_push(&root_dir, &args[1..]),
        // Only trigger sandbox removal for `kaye remove` or bare `kaye rm` (without file args).
        // That way `kaye rm --cached <file>` or `kaye rm <file>` safely passes through to git.
        "remove" => commands::cmd_remove(&root_dir),
        "rm" if args.len() == 1 => commands::cmd_remove(&root_dir),
        _ => {
            let ref_args: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            let code = git::run_kaye_git(&root_dir, &ref_args, true);
            exit(code);
        }
    }
}
