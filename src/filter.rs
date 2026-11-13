pub const GIT_SUBCMDS: &[&str] = &[
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
pub fn rewrite_git_command_references(line: &str) -> String {
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

        // 4. Lines starting with command or indented code blocks
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
pub fn filter_kaye_output(raw: &str) -> String {
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
                "hint: Or use 'kaye save <message>' to stage and commit all changes.".to_string(),
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
                "(use \"kaye restore <file>...\" or \"kaye discard\" to discard changes)",
            ),
            (
                "(use \"git checkout -- <file>...\" to discard changes in working directory)",
                "(use \"kaye restore <file>...\" or \"kaye discard\" to discard changes)",
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

/// Parses arguments for `kaye what change [N|all] [+]`
pub fn parse_what_change_args(args: &[String]) -> (Option<usize>, bool, Vec<String>) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_strips_git_config_advice() {
        let raw = "hint: Disable this message with \"git config set advice.detachedHead false\"\nActual output\n";
        let filtered = filter_kaye_output(raw);
        assert_eq!(filtered, "Actual output\n");
    }

    #[test]
    fn test_rewrites_git_commands_without_touching_dot_git() {
        let raw = "git: 'foo' is not a git command. See 'git --help'.\nKeep .git untouched and run 'git status'.\n";
        let filtered = filter_kaye_output(raw);
        assert!(filtered.contains("kaye: 'foo' is not a kaye command. Run 'kaye help'."));
        assert!(filtered.contains("Keep .git untouched and run 'kaye status'."));
    }

    #[test]
    fn test_parse_what_change_args() {
        let default_args: Vec<String> = vec![];
        assert_eq!(parse_what_change_args(&default_args), (Some(1), true, vec![]));

        let all_top: Vec<String> = vec!["all".into(), "+".into()];
        assert_eq!(parse_what_change_args(&all_top), (None, false, vec![]));

        let n_args: Vec<String> = vec!["3".into(), "src/main.rs".into()];
        assert_eq!(
            parse_what_change_args(&n_args),
            (Some(3), true, vec!["src/main.rs".into()])
        );
    }
}
