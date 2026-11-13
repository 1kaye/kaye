use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct TempWorkspace {
    path: PathBuf,
}

impl TempWorkspace {
    fn new(prefix: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("kaye_test_{}_{}", prefix, nanos));
        fs::create_dir_all(&path).expect("failed to create temp test dir");
        Self { path }
    }

    fn kaye(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_kaye"))
            .current_dir(&self.path)
            .env("GIT_AUTHOR_NAME", "Test User")
            .env("GIT_AUTHOR_EMAIL", "test@example.com")
            .env("GIT_COMMITTER_NAME", "Test User")
            .env("GIT_COMMITTER_EMAIL", "test@example.com")
            .args(args)
            .output()
            .expect("failed to execute kaye binary")
    }

    fn git(&self, args: &[&str]) -> Output {
        Command::new("git")
            .current_dir(&self.path)
            .env("GIT_AUTHOR_NAME", "Test User")
            .env("GIT_AUTHOR_EMAIL", "test@example.com")
            .env("GIT_COMMITTER_NAME", "Test User")
            .env("GIT_COMMITTER_EMAIL", "test@example.com")
            .args(args)
            .output()
            .expect("failed to execute git")
    }
}

impl Drop for TempWorkspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[test]
fn test_full_experiment_lifecycle_and_json() {
    let ws = TempWorkspace::new("lifecycle");

    // Initialize main git and kaye sandbox
    assert!(ws.git(&["init", "-q"]).status.success());
    let init_out = ws.kaye(&["init"]);
    assert!(init_out.status.success());
    assert!(ws.path.join(".kaye").is_dir());

    // Checkpoint 1 (quoted)
    fs::write(ws.path.join("app.txt"), "v1\n").unwrap();
    assert!(ws.kaye(&["save", "baseline v1"]).status.success());

    // Checkpoint 2 (unquoted multi-word message)
    fs::write(ws.path.join("app.txt"), "v2\n").unwrap();
    assert!(ws.kaye(&["save", "unquoted", "second", "step"]).status.success());

    // Checkpoint 3
    fs::write(ws.path.join("app.txt"), "v3\n").unwrap();
    assert!(ws.kaye(&["s", "third step"]).status.success());

    // Verify `kaye list -json` and `kaye list --json`
    let list_json_out = ws.kaye(&["list", "-json"]);
    assert!(list_json_out.status.success());
    let json_text = String::from_utf8_lossy(&list_json_out.stdout);
    let parsed: serde_json::Value = serde_json::from_str(&json_text).expect("valid JSON");
    assert_eq!(parsed["total"], 3);
    assert_eq!(parsed["showing"], 3);
    assert_eq!(parsed["checkpoints"][0]["num"], 1);
    assert_eq!(parsed["checkpoints"][0]["message"], "baseline v1");
    assert_eq!(parsed["checkpoints"][1]["num"], 2);
    assert_eq!(
        parsed["checkpoints"][1]["message"],
        "unquoted second step"
    );
    assert_eq!(parsed["checkpoints"][2]["num"], 3);
    assert_eq!(parsed["checkpoints"][2]["is_head"], true);

    // Verify `kaye list 2 --json` preserves original checkpoint numbers [2] and [3]
    let limited_json_out = ws.kaye(&["list", "2", "--json"]);
    let limited_parsed: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&limited_json_out.stdout)).unwrap();
    assert_eq!(limited_parsed["total"], 3);
    assert_eq!(limited_parsed["showing"], 2);
    assert_eq!(limited_parsed["checkpoints"][0]["num"], 2);
    assert_eq!(limited_parsed["checkpoints"][1]["num"], 3);

    // Change message of checkpoint 2 using unquoted words
    let cm_out = ws.kaye(&["c", "m", "2", "renamed", "checkpoint", "two"]);
    assert!(cm_out.status.success());

    // Inspect `kaye wc` output is formatted cleanly (no raw diff --git / index headers)
    let wc_out = ws.kaye(&["wc"]);
    assert!(wc_out.status.success());
    let wc_str = String::from_utf8_lossy(&wc_out.stdout);
    assert!(wc_str.contains("[MODIFIED] app.txt"));
    assert!(!wc_str.contains("diff --git"));
    assert!(!wc_str.contains("index "));

    // Undo back to checkpoint 2
    assert!(ws.kaye(&["undo", "-y"]).status.success());
    assert_eq!(fs::read_to_string(ws.path.join("app.txt")).unwrap(), "v2\n");

    // Go back aliases: `kaye gb`, `kaye goback`, and `kaye go back`
    assert!(ws.kaye(&["gb", "2", "-y"]).status.success());
    assert_eq!(fs::read_to_string(ws.path.join("app.txt")).unwrap(), "v2\n");
    assert!(ws.kaye(&["goback", "1", "-y"]).status.success());
    assert_eq!(fs::read_to_string(ws.path.join("app.txt")).unwrap(), "v1\n");
    assert!(ws.kaye(&["go", "back", "1", "-y"]).status.success());
    assert_eq!(fs::read_to_string(ws.path.join("app.txt")).unwrap(), "v1\n");

    // Push clean commit to main .git
    let push_out = ws.kaye(&["push", "feat:", "final", "clean", "commit"]);
    assert!(push_out.status.success());

    let git_log = ws.git(&["log", "--oneline"]);
    let log_str = String::from_utf8_lossy(&git_log.stdout);
    assert!(log_str.contains("feat: final clean commit"));
}

#[test]
fn test_discard_status_json_sync_and_prune() {
    let ws = TempWorkspace::new("discard_sync");
    assert!(ws.git(&["init", "-q"]).status.success());
    assert!(ws.kaye(&["init"]).status.success());

    fs::write(ws.path.join("tracked.txt"), "clean\n").unwrap();
    assert!(ws.kaye(&["save", "initial"]).status.success());

    // Dirty tracked file + create untracked file
    fs::write(ws.path.join("tracked.txt"), "dirty\n").unwrap();
    fs::write(ws.path.join("untracked_temp.txt"), "garbage\n").unwrap();

    // Check `kaye status --json`
    let status_out = ws.kaye(&["status", "--json"]);
    assert!(status_out.status.success());
    let status_json: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&status_out.stdout)).unwrap();
    assert_eq!(status_json["clean"], false);
    assert_eq!(status_json["modified"][0], "tracked.txt");
    assert_eq!(status_json["untracked"][0], "untracked_temp.txt");

    // Discard should clean both tracked and untracked changes
    assert!(ws.kaye(&["discard", "-y"]).status.success());
    assert_eq!(
        fs::read_to_string(ws.path.join("tracked.txt")).unwrap(),
        "clean\n"
    );
    assert!(!ws.path.join("untracked_temp.txt").exists());

    // Discard on an already-clean working tree should succeed without -y
    let clean_discard = ws.kaye(&["discard"]);
    assert!(clean_discard.status.success());
    let clean_stdout = String::from_utf8_lossy(&clean_discard.stdout);
    assert!(clean_stdout.contains("already clean"));

    // Simulate main .git commit and `kaye sync`
    fs::write(ws.path.join("from_main.txt"), "pulled\n").unwrap();
    assert!(ws.git(&["add", "."]).status.success());
    assert!(ws.git(&["commit", "-m", "main update"]).status.success());
    assert!(ws.kaye(&["sync"]).status.success());

    // Prune should succeed
    assert!(ws.kaye(&["prune"]).status.success());
}

#[test]
fn test_blocks_network_and_override_flags() {
    let ws = TempWorkspace::new("security");
    assert!(ws.kaye(&["init"]).status.success());

    assert!(!ws.kaye(&["remote", "-v"]).status.success());
    assert!(!ws.kaye(&["fetch"]).status.success());
    assert!(!ws.kaye(&["pull"]).status.success());
    assert!(!ws.kaye(&["clone", "https://example.com/repo.git"]).status.success());
    assert!(!ws.kaye(&["--git-dir=.git", "status"]).status.success());
    assert!(!ws.kaye(&["-C", "..", "status"]).status.success());
}
