# KAYE — Keep All Your Experiments

**KAYE** (`kaye`) is a lightweight, zero-dependency **Version Control System (VCS)** written in Rust, specifically engineered as a local experimentation sandbox for developers and AI coding agents (LLMs).

As a local sandbox Version Control System, KAYE allows you to record incremental checkpoints, inspect multi-file diffs, create experimental branches, and roll back broken code iterations without polluting your project's primary `.git` commit history. Once your experiment is verified and stable, a single `kaye push` command promotes the final working state into one clean commit in your main `.git` repository.

---

## Architecture: Shadow-Git Version Control System

Building a Version Control System from scratch using raw file-copying snapshots quickly leads to bloated disk usage and lacks reliable line-by-line diffing or merging. Instead, **KAYE** is architected as a **Shadow-Git wrapper** around Git's core engine:

1. **Isolated VCS Database (`--git-dir=.kaye`):** Every command run through `kaye` redirects Git's internal database (objects, refs, staging index, and commit logs) into a hidden `.kaye/` directory at your project root. Your primary `.git/` repository remains completely untouched while you experiment.
2. **Shared Working Tree (`--work-tree=.`):** While the version control database is isolated inside `.kaye/`, the working tree points directly to your project root so `kaye` can track, diff, branch, and restore your source files in place.
3. **Automatic Mutual Exclusion:** Running `kaye init` configures `.kaye/info/exclude` to ignore both `.kaye/` and `.git/`, and automatically appends `.kaye/` to your project's `.gitignore` so sandbox data never leaks into production commits.
4. **Human-Readable Checkpoint Resolution:** Under the hood, `.kaye/` stores commits using standard Git SHA-1 hashes. KAYE provides a built-in Rust translation layer (`kaye list`, `kaye what change`, `kaye restore-num`, and `kaye restore-msg`) that maps sequential numbers (`[1]`, `[2]`, `[3]`) and commit message keywords directly to their underlying SHA-1 hashes.
5. **100% Offline Enforcement:** Network operations (`remote`, `fetch`, `pull`, `clone`, `submodule`) are blocked at the binary level so the sandbox remains strictly local.

---

## Prerequisites

- **Git:** Must be installed and accessible in your system `PATH`.
- **Rust & Cargo:** Required to compile the binary from source ([rustup.rs](https://rustup.rs/)).

---

## Installation

### Linux and macOS

Clone the repository and execute the installer script:

~~~bash
git clone https://github.com/1kaye/kaye.git
cd kaye
chmod +x install.sh
./install.sh
~~~

The script builds the release binary and installs it to `~/.local/bin/kaye`. Make sure `~/.local/bin` is included in your shell `PATH`.

### Windows (PowerShell and CMD)

Clone the repository and execute the PowerShell installer:

~~~powershell
git clone https://github.com/1kaye/kaye.git
cd kaye
.\install.ps1
~~~

The script compiles `kaye.exe`, copies it to `%USERPROFILE%\.local\bin`, and registers the folder in your User `PATH` environment variable so `kaye` works globally in both PowerShell and Command Prompt (CMD).

### Updating KAYE

To update KAYE when new changes are available in the repository:

~~~bash
git pull
cargo build --release
~~~

Or re-run `./install.sh` (Linux/macOS) or `.\install.ps1` (Windows) to overwrite the installed binary.

---

## Command Reference

### Custom KAYE Commands

| Command | Shortcut | Description |
| :--- | :--- | :--- |
| `kaye init` | — | Initializes the `.kaye/` sandbox repository in the project root and adds `.kaye/` to `.gitignore`. |
| `kaye save "<message>"` | `kaye s "<msg>"` | Stages all changes (`add -A`) and records a checkpoint commit inside `.kaye/`. A commit message is required (cannot be empty). |
| `kaye list` | `kaye l` | Lists all recorded checkpoints in chronological order as sequential numbers (`[1]`, `[2]`, `[3]`). |
| `kaye what change` | `kaye w c` / `kaye wc` | Shows line-by-line patch diffs of recent checkpoints (`log -p`). Supports `<N>`, `all`, and `+` (e.g. `kaye w c 2`, `kaye w c all +`). By default, newest changes are shown at the bottom. |
| `kaye change message <number> "<new message>"` | `kaye c m` / `kaye cm` | Updates the commit message of checkpoint `<number>` (e.g. `kaye c m 3 "new message"`). |
| `kaye restore-num <number>` | `kaye rn <number>` | Hard-resets the working tree to the checkpoint matching `<number>` from `kaye list`. |
| `kaye restore-msg "<keyword>"` | `kaye rmsg "<keyword>"` | Searches commit messages (case-insensitive) and hard-resets the working tree to the latest checkpoint matching `<keyword>`. |
| `kaye undo` | `kaye u` | Reverts the working tree back by 1 checkpoint (`reset --hard HEAD~1`). |
| `kaye push "<message>"` / `kaye push -` | `kaye p "<msg>"` / `kaye p -` | Promotes the current working tree state into 1 clean commit on the active branch of the primary `.git` repository. Using `-` automatically reuses the latest checkpoint message from `.kaye/`. |
| `kaye .gitignore` | — | Lists `.gitignore` patterns that are automatically synced and ignored inside `.kaye/` on `init`, `add`, and `save`. |
| `kaye remove` | `kaye rm` | Removes the `.kaye/` sandbox directory and all checkpoints with interactive `[y/N]` confirmation. |

### Standard Git Commands (Isolated Inside `.kaye/`)

Because KAYE is a Shadow-Git Version Control System, standard local Git commands work directly inside the `.kaye/` sandbox:

- `kaye status` — Show modified, staged, and untracked files in the sandbox.
- `kaye diff` — Show detailed line-by-line unstaged changes across all modified files.
- `kaye diff --staged` — Show line-by-line changes currently staged in `.kaye/`.
- `kaye diff HEAD~2` — Show accumulated line-by-line changes across the last 2 checkpoints.
- `kaye diff --stat` — Show a file-level summary of additions and deletions.
- `kaye show <hash>` — Inspect the exact diff introduced by a specific checkpoint hash.
- `kaye log --oneline` — View the raw Git SHA-1 commit history inside `.kaye/`.
- `kaye restore .` — Discard uncommitted working tree modifications and revert to the latest checkpoint.
- `kaye branch` — List, create, or delete isolated experimental branches inside `.kaye/`.
- `kaye checkout -b <branch>` — Create and switch to an experimental branch without affecting the main `.git` branch.
- `kaye reset --hard HEAD~2` — Delete the last 2 checkpoints and reset the working tree.

---

## Typical Workflow Example

~~~bash
# 1. Initialize KAYE at the root of your project
cd /path/to/your/project
kaye init

# 2. Save a clean baseline before starting an experiment
kaye save "baseline before auth refactor"

# 3. Record checkpoints as you or an LLM iterate on the codebase
kaye save "add token validation logic"
kaye save "experimental sqlite session handler"

# 4. View all line-by-line changes across the last 2 checkpoints
kaye diff HEAD~2

# 5. View numbered checkpoint history and diff patches
kaye list
# Output:
# === KAYE EXPERIMENT CHECKPOINTS ===
#   [1] baseline before auth refactor
#   [2] add token validation logic
#   [3] experimental sqlite session handler (HEAD)
# ===================================

# Inspect exact commit patches (newest at bottom by default)
kaye what change        # Show patch of latest checkpoint
kaye what change 2      # Show patches of last 2 checkpoints
kaye what change all    # Show patches of all checkpoints
kaye what change 2 +    # Show patches of last 2 checkpoints with newest at top

# 6. Roll back if the latest experiments broke the build
# Option A: Restore by checkpoint number
kaye restore-num 2

# Option B: Restore by commit message keyword
kaye restore-msg "baseline"

# 7. Once verified, promote the final state into 1 clean commit in main .git
# Option A: Specify a custom commit message
kaye push "feat(auth): implement token validation"

# Option B: Reuse the latest checkpoint message from .kaye
kaye push -

# 8. Push your clean main .git history to your remote server when ready
git push
~~~

---

## License

MIT License. Created by [1kaye](https://github.com/1kaye).
