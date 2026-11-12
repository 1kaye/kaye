# AI Agent Instructions: KAYE (`kaye`) Local Sandbox Version Control System

This repository uses **KAYE — Keep All Your Experiments** (`kaye`), a local Shadow-Git Version Control System designed for iterative development and AI-assisted coding.

## 1. Architecture Context for AI Agents

- `kaye` is a Rust CLI wrapper around Git that isolates all experimental version control data inside the `.kaye/` directory (`--git-dir=.kaye`) while operating on the project's root working tree (`--work-tree=.`).
- The primary `.git/` directory is strictly reserved for finalized, verified commits.
- `kaye` automatically maps sequential checkpoint numbers and commit message keywords to underlying Git SHA-1 hashes.

## 2. Strict Operational Rules

1. **Do NOT use raw `git` for experiments:** Never run `git add`, `git commit`, `git reset`, `git checkout`, or `git branch` directly against the primary `.git` repository while writing, testing, or debugging code.
2. **Always use `kaye` for checkpoints:** Use `kaye` commands for all intermediate saves, multi-file diffs, experimental branches, and rollbacks. Note: `kaye save "<message>"` strictly requires a commit message (running `kaye save` without a message is forbidden and will fail).
3. **Offline Only:** Do not attempt to run `kaye remote`, `kaye fetch`, `kaye pull`, or `kaye clone`. Network commands are blocked by design.
4. **Never auto-push to remote:** Do not run `git push` to a remote server unless explicitly instructed by the user.
5. **DO NOT run destructive sandbox removal:** Never run `kaye remove` or `kaye rm` autonomously. It permanently destroys the `.kaye/` sandbox and checkpoint history, and requires interactive user confirmation (`[y/N]`). Only human users may execute this command manually if they choose to completely wipe their sandbox.

## 3. Mandatory Agent Workflow

### Step 1: Initialization and Baseline

Before modifying any files at the start of a task:

1. Check if the sandbox is active:
~~~bash
kaye status
~~~
2. If `.kaye/` is not initialized, initialize it at the project root:
~~~bash
kaye init
~~~
3. Always create a clean baseline checkpoint before making code changes:
~~~bash
kaye save "baseline before starting task"
~~~

### Step 2: Iterative Checkpointing

Save a checkpoint after completing each logical change, file modification, or passing test:

~~~bash
kaye save "<clear, concise description of the change>"
# Or use the shortcut:
kaye s "<clear, concise description of the change>"
~~~

### Step 3: Inspecting Multi-File Diffs and History

- To see modified, staged, or untracked files:
~~~bash
kaye status
~~~
- To inspect detailed line-by-line changes across all modified files before saving:
~~~bash
kaye diff
~~~
- To inspect checkpoint patch diffs (default: 1 recent checkpoint, newest changes at bottom):
~~~bash
# Inspect patch of latest checkpoint (newest changes at bottom)
kaye what change       # or: kaye w c

# Inspect patches across last N checkpoints
kaye what change <N>   # or: kaye w c <N>

# Inspect patches across all checkpoints
kaye what change all   # or: kaye w c all

# Inspect with newest changes at top (normal git order)
kaye what change <N> + # or: kaye w c <N> +
~~~
- To inspect accumulated line-by-line changes across the last `N` checkpoints:
~~~bash
kaye diff HEAD~N
~~~
- To view the sequential numbered list of saved checkpoints (`[1]`, `[2]`, `[3]`, ...):
~~~bash
kaye list              # or: kaye l
~~~
- To change or update the message of an existing checkpoint by its number:
~~~bash
kaye change message <number> "<new message>"  # or: kaye c m <number> "<new message>"
~~~

### Step 4: Experimental Branching (Optional)

When attempting a high-risk architectural change, create an isolated branch inside `.kaye/`:

~~~bash
kaye checkout -b experiment-refactor
~~~

Switch back or merge within `.kaye/` once verified:

~~~bash
kaye checkout main
kaye merge experiment-refactor
~~~

### Step 5: Rolling Back Failed Experiments

If an edit breaks the build, fails tests, or produces undesirable results, recover immediately using one of the following commands:

- **Discard uncommitted edits in the working tree (keep current checkpoint):**
~~~bash
kaye restore .
~~~
- **Revert 1 checkpoint back:**
~~~bash
kaye undo               # or: kaye u
~~~
- **Revert to a specific checkpoint number from `kaye list`:**
~~~bash
kaye restore-num <number> # or: kaye rn <number>
~~~
- **Revert to a specific checkpoint by matching a keyword in its commit message:**
~~~bash
kaye restore-msg "<keyword>" # or: kaye rmsg "<keyword>"
~~~

### Step 6: Promoting Final Code to Primary `.git`

Only when the implementation is complete, builds/tests pass, and the user asks to finalize or commit the changes to the main repository:

~~~bash
# Option A: Specify a custom commit message
kaye push "<clean commit message for main git>"  # or: kaye p "<msg>"

# Option B: Reuse the latest checkpoint message from .kaye
kaye push -                                      # or: kaye p -
~~~

`kaye push` synchronizes the final state and records a single clean commit on the currently active branch in the primary `.git` repository. Passing `-` automatically extracts and reuses the commit message from the latest checkpoint (`HEAD`) in `.kaye/`.
