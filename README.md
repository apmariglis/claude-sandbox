# claude-sandbox

Run Claude Code in an isolated Docker container, giving it access to exactly one folder on your machine. Each container is ephemeral — created fresh on start, deleted on exit.

The core isolation is simple: a Docker volume mount. The infrastructure around it is what makes it usable as a persistent workflow:

- **Session tracking** — every run is recorded with its folder, timestamps, and fork lineage, so you can always find, resume, or branch a past conversation
- **Credential persistence** — authenticate once; all containers reuse the same credentials automatically
- **Ownership repair** — containers run as root, so files would otherwise become unreadable; the script fixes ownership after every run
- **Session management** — list, view, resume, fork, delete, and import sessions from the command line

No global installation of Claude required.

## Requirements

- Docker
- An Anthropic subscription (Claude.ai Pro or Max)

## Installation

To call the script from anywhere, symlink it into a directory on your `PATH`:

```bash
ln -s "$(pwd)/claude-sandbox" ~/.local/bin/claude-sandbox
```

If `~/.local/bin` is not on your `PATH`, add this to your `~/.bashrc` or `~/.zshrc` and reload your shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Setup

```bash
chmod +x claude-sandbox
```

No separate login step required. On your first session, Claude Code will prompt you that you are not logged in. Type `/login` inside Claude, open the printed URL in your browser, and complete the authentication. Your credentials are saved to `~/.claude-sandbox/` and reused automatically in all future sessions.

## Usage

```bash
# Start a new session
./claude-sandbox <folder-path>

# Resume a previous session
./claude-sandbox resume <session-id>

# List all recorded sessions
./claude-sandbox sessions

# Print the conversation from a session
./claude-sandbox view-session <session-id>

# List all sessions recorded for a specific folder
./claude-sandbox sessions-for <folder-path>

# Branch a new session from an existing one, carrying over its history
./claude-sandbox fork-session <session-id>

# Delete a session and its conversation log
./claude-sandbox delete-session <session-id>

# Import an external session (see below)
./claude-sandbox register-session <jsonl-path> <folder-path>

# Add or update a note on a session (shown in sessions list)
./claude-sandbox annotate-session <session-id> [text]
```

> **Note:** A session (including forks) only appears in `sessions` and `sessions-for` after the container exits — whether you quit with `/q`, close the terminal, or the container stops for any other reason. The session is recorded automatically on exit, and the `last active` timestamp is derived from the conversation log at that point.

**Examples:**

```bash
./claude-sandbox ~/projects/my-app
./claude-sandbox resume f07c1c53-bd85-4c36-8dd6-22fb5eafbc4a
./claude-sandbox sessions
./claude-sandbox view-session f07c1c53-bd85-4c36-8dd6-22fb5eafbc4a
./claude-sandbox sessions-for ~/projects/my-app
./claude-sandbox fork-session f07c1c53-bd85-4c36-8dd6-22fb5eafbc4a
./claude-sandbox delete-session f07c1c53-bd85-4c36-8dd6-22fb5eafbc4a
./claude-sandbox annotate-session f07c1c53-bd85-4c36-8dd6-22fb5eafbc4a "security audit"
```

## Importing external sessions

If you have Claude Code sessions from another setup (e.g. a global Claude installation, or a different machine), you can import them so they become available for `resume`, `fork-session`, and `view-session`.

Find the `.jsonl` file for the session you want to import — Claude Code stores them under `~/.claude/projects/` by default. Each file is named after the session UUID.

```bash
./claude-sandbox register-session \
  ~/.claude/projects/-home-you-projects-my-app/f07c1c53-bd85-4c36-8dd6-22fb5eafbc4a.jsonl \
  ~/projects/my-app
```

This copies the conversation log into `~/.claude-sandbox/projects/-workspace/` and registers the session in the index. After importing, the session is available like any other sandbox session.

### Importing from ClaudeBox

ClaudeBox stores each project under `~/.claudebox/projects/<project-name>/`. The original folder path is in `.project_path` and session JSONL files are nested inside `<8-char-hex-id>/.claude/projects/-workspace/`.

```bash
# Read the folder path for a ClaudeBox project
cat ~/.claudebox/projects/my-project/.project_path

# List the instance folders for that project
ls ~/.claudebox/projects/my-project/

# Import a specific session
./claude-sandbox register-session \
  ~/.claudebox/projects/my-project/<instance-id>/.claude/projects/-workspace/<conversation-id>.jsonl \
  "$(cat ~/.claudebox/projects/my-project/.project_path)"
```

If there are multiple `.jsonl` files inside `-workspace/`, use `view-session` with the file path directly to inspect each one before importing:

```bash
./claude-sandbox view-session \
  ~/.claudebox/projects/my-project/<instance-id>/.claude/projects/-workspace/<conversation-id>.jsonl
```

## What it does

- Mounts only the specified folder into the container — no other host directories are accessible
- Mounts `~/.claude-sandbox/` as Claude's config directory — credentials, session history, conversation logs, and settings persist across runs automatically via the volume mount
- On exit, copies `/root/.claude.json` from the container filesystem into the volume. This file holds account identity, cached subscription tier, feature flags, and UI state (onboarding status, tips, etc.) — it is outside the volume mount so must be explicitly saved. Without it, Claude Code would re-fetch subscription info on the next start and show onboarding prompts again
- Records each session ID and its folder in `~/.claude-sandbox/session-index/` so sessions can be resumed or forked by ID
- Derives `created` and `last_active` timestamps from the session's JSONL conversation log; records `forked_from` for forked sessions
- Fixes file ownership after each run so session files are immediately readable
- Removes the container automatically on exit

## Development

### What the tests cover

The script has two kinds of code: pure shell logic (parsing, recording, listing sessions) and Docker-dependent operations (`run_container`, `fix_ownership`, `run_sandbox`, `run_resume`, `run_fork`). The test suite covers the former; the latter requires a live Docker daemon and a real Anthropic session, so it is not unit-tested here.

The tests work by sourcing the script (rather than running it as a subprocess), which loads all the shell functions into the current shell without executing the entry point. This makes every pure function directly callable in tests. After sourcing, each test overrides `CLAUDE_HOME` and `SESSIONS_DIR` with a fresh temporary directory so tests are completely isolated from real user data.

**What is tested:**

| Area | What the tests verify |
|------|-----------------------|
| `read_session_field` | Returns the correct value for a key; returns empty string for missing keys; handles `=` signs in values |
| `write_session_file` | Creates an index file with the folder field; omits `forked_from` for new sessions; includes `forked_from` for forks |
| `annotate_session` | Sets a note; clears a note when called with no text; prompts for confirmation before replacing or clearing an existing note; fails for invalid or missing session IDs |
| `session_timestamps` | Extracts first and last timestamps from a JSONL file; returns `-` for both when no JSONL is found |
| `sort_sessions_by_last_active` | Returns nothing with no arguments; sorts by `last_active` descending; sessions with no JSONL sort after those with timestamps |
| `record_session` | Writes a session index entry when a new JSONL appears after a run; records `forked_from` when a source ID is provided; does nothing when no new JSONL is detected |
| `list_sessions` | Prints a message when no sessions exist; shows each session's ID and folder; groups forks under their parent with a `(fork)` prefix; sorts root sessions by `last_active` descending; shows annotation below sessions that have one |
| `sessions_for_folder` | Shows only sessions matching the given folder; prints a message when no sessions match; groups forks under their parent |
| `view_session` | Accepts a direct file path; accepts a session ID and locates the JSONL automatically; fails with an error when no JSONL is found for the given ID |
| `register_session` | Copies the JSONL and creates an index entry; fails if the session is already registered; fails if the source file does not exist; fails if the source file does not have a `.jsonl` extension |
| `delete_session` | Removes the session index file; removes the JSONL conversation file; refuses deletion if the session has forks; fails if the session is not in the index |

**What is not tested and why:**

- `run_container` / `fix_ownership` — require a live Docker daemon; no meaningful way to mock without rewriting the functions
- `run_sandbox` / `run_resume` / `run_fork` — depend on Docker and interactive terminal I/O; covered by manual testing
- `confirm` — reads from `/dev/tty` and is stubbed in tests that call functions depending on it

### Running the tests

The tests require `jq`. The easiest way without installing anything is:

```bash
docker run --rm -v "$(pwd)":/workspace \
  alpine:latest \
  sh -c "apk add --no-cache bash bats jq && bats /workspace/tests/claude-sandbox.bats"
```

Or install both locally:

```bash
# Debian/Ubuntu
sudo apt install bats jq
```

Then run:

```bash
bats tests/claude-sandbox.bats
```
