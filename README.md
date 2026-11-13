# KAYE - Keep All Your Experiments

**KAYE** (`kaye`) is a lightweight **Version Control System (VCS)** written in Rust, specifically engineered as a local experimentation sandbox for developers and AI coding agents (LLMs).

As a local sandbox Version Control System, KAYE allows you to record incremental checkpoints, inspect multi-file diffs, create experimental branches, and roll back broken code iterations without polluting your project's primary `.git` commit history. Once your experiment is verified and stable, a single `kaye push` command promotes the final working state into one clean commit in your main `.git` repository.

---

## Architecture: Shadow-Git Version Control System

Building a Version Control System from scratch using raw file-copying snapshots quickly leads to bloated disk usage and lacks reliable line-by-line diffing or merging. Instead, **KAYE** is architected as a **Shadow-Git wrapper** around Git's core engine:

1. **Isolated VCS Database (`--git-dir=.kaye`):** Every command run through `kaye` redirects Git's internal database (objects, refs, staging index, and commit logs) into a hidden `.kaye/` directory at your project root. Your primary `.git/` repository remains completely untouched while you experiment.
2. **Shared Working Tree (`--work-tree=.`):** While the version control database is isolated inside `.kaye/`, the working tree points directly to your project root so `kaye` can track, diff, branch, and restore your source files in place.
3. **Clean Mutual Exclusion:** Running `kaye init` configures `.kaye/info/exclude` to ignore both `.kaye/` and `.git/`, and appends `.kaye/` to your project's `.gitignore`. `.kaye/` reads your project `.gitignore` dynamically without duplicating stale rules into `.kaye/info/exclude`.
4. **Human & Agent-Readable Checkpoint Resolution:** Under the hood, `.kaye/` stores commits using standard Git SHA-1 hashes. KAYE provides a Rust translation layer (`kaye list`, `kaye list --json`, `kaye status --json`, `kaye what change`, and `kaye go back`) that maps sequential numbers (`[1]`, `[2]`, `[3]`) directly to their underlying SHA-1 hashes.
5. **100% Offline Enforcement:** Network operations (`remote`, `fetch`, `pull`, `clone`, `submodule`) and directory override flags (`-C`, `--git-dir`, `--work-tree`) are blocked at the binary level so the sandbox remains strictly local.

---

## Prerequisites

- **Git:** Must be installed and accessible in your system `PATH`.
- **Rust & Cargo:** Required if compiling from source ([rustup.rs](https://rustup.rs/)), or download prebuilt binaries from GitHub Releases.

---

## Installation

### Linux and macOS (From Source)

Clone the repository and execute the installer script:

```bash
git clone https://github.com/1kaye/kaye.git
cd kaye
chmod +x install.sh
./install.sh
```

The script builds the release binary and installs it to `~/.local/bin/kaye`. Make sure `~/.local/bin` is included in your shell `PATH`.

### Windows (PowerShell and CMD, From Source)

Clone the repository and execute the PowerShell installer:

```powershell
git clone https://github.com/1kaye/kaye.git
cd kaye
.\install.ps1
```

The script compiles `kaye.exe`, copies it to `%USERPROFILE%\.local\bin`, and registers the folder in your User `PATH` environment variable so `kaye` works globally in both PowerShell and Command Prompt (CMD).

---

## Command Reference

### Custom KAYE Commands

| Command | Shortcut | Description |
| :--- | :--- | :--- |
| `kaye init` | | Initializes the `.kaye/` sandbox repository in the project root and adds `.kaye/` to `.gitignore`. |
| `kaye save <message>` | `kaye s <msg>` | Stages all changes (`add -A`) and records a checkpoint commit inside `.kaye/`. Supports both quoted and unquoted multi-word messages. |
| `kaye list [N] [--json \| -json]` | `kaye l` | Lists recorded checkpoints in chronological order (`[1]`, `[2]`, `[3]`) with relative timestamps. Optional `N` limits output to the latest `N` checkpoints while keeping original numbers. `--json` / `-json` outputs structured JSON. |
| `kaye what change [N\|all] [+]` | `kaye w c` / `kaye wc` | Shows line-by-line patch diffs of recent checkpoints (`log -p`). By default, newest changes are shown at the bottom; pass `+` for newest at top. |
| `kaye change message <n> <msg>` | `kaye c m` / `kaye cm` | Updates the commit message of checkpoint `<n>` (e.g., `kaye c m 3 fixed auth logic`) while preserving branch/merge topology. |
| `kaye go back <number> [-y]` | `kaye goback` / `kaye gb <n> [-y]` | Hard-resets the working tree to the checkpoint matching `<number>` from `kaye list` (prompts `[y/N]` unless `-y`/`--yes` is passed). |
| `kaye undo [-y]` | `kaye u [-y]` | Reverts the working tree back by 1 checkpoint (`reset --hard HEAD~1`, prompts `[y/N]` unless `-y`/`--yes` is passed). |
| `kaye discard [path...] [-y]` | | Discards all uncommitted tracked modifications AND removes untracked files/directories (`restore --staged --worktree` + `clean -fd`). Exits early if already clean; otherwise prompts `[y/N]` unless `-y`/`--yes` is passed. |
| `kaye sync [message]` | | Synchronizes working tree changes (such as after `git pull` or switching branches in main `.git`) into a new `.kaye/` checkpoint. |
| `kaye prune` | | Expires sandbox reflogs and prunes dangling Git objects inside `.kaye/` (`gc --prune=now`) to keep disk usage minimal. |
| `kaye push <message>` / `kaye push -` | `kaye p <msg>` / `kaye p -` | Promotes the current working tree state into 1 clean commit on the active branch of the primary `.git` repository. Using `-` automatically reuses the latest checkpoint message from `.kaye/`. |
| `kaye .gitignore` | | Displays active `.gitignore` patterns respected natively by `.kaye/`. |
| `kaye remove` | `kaye rm` | Removes the `.kaye/` sandbox directory and all checkpoints with interactive `[y/N]` confirmation. |

### Standard Git Commands (Isolated Inside `.kaye/`)

Because KAYE is a Shadow-Git Version Control System, standard local Git commands work directly inside the `.kaye/` sandbox:

- `kaye status [--json | -json]` — Show modified, staged, and untracked files in the sandbox (or structured JSON).
- `kaye diff` — Show detailed line-by-line unstaged changes across all modified files.
- `kaye diff --staged` — Show line-by-line changes currently staged in `.kaye/`.
- `kaye diff HEAD~2` — Show accumulated line-by-line changes across the last 2 checkpoints.
- `kaye diff --stat` — Show a file-level summary of additions and deletions.
- `kaye show <hash>` — Inspect the exact diff introduced by a specific checkpoint hash.
- `kaye log --oneline` — View the raw Git SHA-1 commit history inside `.kaye/`.
- `kaye restore .` — Discard uncommitted tracked file modifications and revert to the latest checkpoint.
- `kaye branch` — List, create, or delete isolated experimental branches inside `.kaye/`.
- `kaye checkout -b <branch>` — Create and switch to an experimental branch without affecting the main `.git` branch.
- `kaye reset --hard <hash>` — Jump back to any specific checkpoint hash.

---

## Typical Workflow Example

```bash
# 1. Initialize KAYE at the root of your project
cd /path/to/your/project
kaye init

# 2. Save a clean baseline before starting an experiment
kaye save "baseline before auth refactor"

# 3. Record checkpoints as you or an LLM iterate on the codebase (quotes optional)
kaye save add token validation logic
kaye save experimental sqlite session handler

# 4. View numbered checkpoint history with relative timestamps or JSON
kaye list
# Output:
# === Keep All Your Experiments CHECKPOINTS ===
#   [1] baseline before auth refactor (10 minutes ago)
#   [2] add token validation logic (4 minutes ago)
#   [3] experimental sqlite session handler (just now) (HEAD)
# =============================================

kaye list --json

# 5. Discard broken uncommitted edits (including newly generated untracked files)
kaye discard

# 6. Or roll back to an earlier checkpoint if a saved experiment broke the build
kaye go back 2   # or: kaye gb 2

# 7. Once verified, promote the final state into 1 clean commit in main .git
kaye push "feat(auth): implement token validation"
# Or reuse the latest checkpoint message from .kaye:
kaye push -

# 8. Push your clean main .git history to your remote server when ready
git push
```

---

## Running Tests

```bash
cargo test
```

---

## License

MIT License. Created by [1kaye](https://github.com/1kaye).
