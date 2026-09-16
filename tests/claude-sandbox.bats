#!/usr/bin/env bats

setup() {
  # Source first so the script's top-level assignments run, then override them
  # with a clean temp directory so tests are isolated from real user data.
  source "$BATS_TEST_DIRNAME/../claude-sandbox"

  export CLAUDE_HOME
  CLAUDE_HOME=$(mktemp -d)
  export SESSIONS_DIR="$CLAUDE_HOME/session-index"
  mkdir -p "$SESSIONS_DIR"
}

teardown() {
  rm -rf "$CLAUDE_HOME"
}

# ---------------------------------------------------------------------------
# validate_session_id
# ---------------------------------------------------------------------------

@test "validate_session_id accepts a valid UUID-style session ID" {
  run validate_session_id "f07c1c53-bd85-4c36-8dd6-22fb5eafbc4a"

  [ "$status" -eq 0 ]
}

@test "validate_session_id rejects a path traversal attempt" {
  run validate_session_id "../../etc/passwd"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid session ID"* ]]
}

@test "validate_session_id rejects an ID containing special characters" {
  run validate_session_id "abc; rm -rf ~"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid session ID"* ]]
}

@test "delete_session rejects an invalid session ID" {
  run delete_session "../../etc/passwd"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid session ID"* ]]
}

@test "view_session rejects an invalid session ID when no matching file exists" {
  run view_session "../../no-such-file"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid session ID"* ]]
}

# ---------------------------------------------------------------------------
# read_session_field
# ---------------------------------------------------------------------------

@test "read_session_field returns the value for an existing key" {
  printf "folder=/some/path\n" > "$SESSIONS_DIR/test-session"

  run read_session_field "$SESSIONS_DIR/test-session" folder

  [ "$status" -eq 0 ]
  [ "$output" = "/some/path" ]
}

@test "read_session_field returns empty string for a missing key" {
  printf "folder=/some/path\n" > "$SESSIONS_DIR/test-session"

  run read_session_field "$SESSIONS_DIR/test-session" forked_from

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "read_session_field handles folder paths containing equals signs" {
  printf "folder=/some/path=with=equals\n" > "$SESSIONS_DIR/test-session"

  run read_session_field "$SESSIONS_DIR/test-session" folder

  [ "$output" = "/some/path=with=equals" ]
}

# ---------------------------------------------------------------------------
# write_session_file
# ---------------------------------------------------------------------------

@test "write_session_file creates a new session file with folder" {
  write_session_file "$SESSIONS_DIR/new-session" "/my/project"

  [ -f "$SESSIONS_DIR/new-session" ]
  grep -q "^folder=/my/project$" "$SESSIONS_DIR/new-session"
}

@test "write_session_file does not add forked_from for a new session" {
  write_session_file "$SESSIONS_DIR/new-session" "/my/project"

  run grep "^forked_from=" "$SESSIONS_DIR/new-session"
  [ "$status" -ne 0 ]
}

@test "write_session_file for a fork includes forked_from" {
  write_session_file "$SESSIONS_DIR/forked-session" "/my/project" "source-session-id"

  run read_session_field "$SESSIONS_DIR/forked-session" forked_from
  [ "$output" = "source-session-id" ]
}

# ---------------------------------------------------------------------------
# annotate_session
# ---------------------------------------------------------------------------

@test "annotate_session sets a note on a session" {
  printf "folder=/some/path\n" > "$SESSIONS_DIR/test-session"

  annotate_session "test-session" "security audit"

  run read_session_field "$SESSIONS_DIR/test-session" note
  [ "$output" = "security audit" ]
}

@test "annotate_session clears a note when called with no text" {
  printf "folder=/some/path\nnote=old note\n" > "$SESSIONS_DIR/test-session"
  confirm() { return 0; }

  annotate_session "test-session" ""

  run read_session_field "$SESSIONS_DIR/test-session" note
  [ "$output" = "" ]
}

@test "annotate_session replaces an existing note after confirmation" {
  printf "folder=/some/path\nnote=old note\n" > "$SESSIONS_DIR/test-session"
  confirm() { return 0; }

  annotate_session "test-session" "new note"

  run read_session_field "$SESSIONS_DIR/test-session" note
  [ "$output" = "new note" ]
}

@test "annotate_session aborts replacement when confirmation is declined" {
  printf "folder=/some/path\nnote=keep this\n" > "$SESSIONS_DIR/test-session"
  confirm() { return 1; }

  annotate_session "test-session" "new note"

  run read_session_field "$SESSIONS_DIR/test-session" note
  [ "$output" = "keep this" ]
}

@test "annotate_session fails if the session does not exist" {
  run annotate_session "no-such-session" "hello"

  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "annotate_session rejects an invalid session ID" {
  run annotate_session "../../etc/passwd" "hello"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid session ID"* ]]
}

# ---------------------------------------------------------------------------
# session_timestamps
# ---------------------------------------------------------------------------

@test "session_timestamps returns created and last_active from JSONL" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"timestamp":"2026-01-01T10:00:00.000Z"}\n{"timestamp":"2026-01-02T15:30:00.000Z"}\n' \
    > "$projects_dir/my-session.jsonl"

  run session_timestamps "my-session"

  [ "$(echo "$output" | sed -n '1p')" = "2026-01-01 10:00:00" ]
  [ "$(echo "$output" | sed -n '2p')" = "2026-01-02 15:30:00" ]
}

@test "session_timestamps returns dashes when JSONL file is not found" {
  run session_timestamps "nonexistent-session"

  [ "$(echo "$output" | sed -n '1p')" = "-" ]
  [ "$(echo "$output" | sed -n '2p')" = "-" ]
}

# ---------------------------------------------------------------------------
# record_session
# ---------------------------------------------------------------------------

@test "record_session writes a session file when a new jsonl is detected" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{}' > "$projects_dir/existing.jsonl"

  local snapshot
  snapshot=$(find "$CLAUDE_HOME/projects" -name "*.jsonl" | sort)

  printf '{}' > "$projects_dir/new-session-id.jsonl"

  record_session "/my/project" "$snapshot"

  [ -f "$SESSIONS_DIR/new-session-id" ]
  run read_session_field "$SESSIONS_DIR/new-session-id" folder
  [ "$output" = "/my/project" ]
}

@test "record_session writes forked_from when source_id is provided" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"

  local snapshot
  snapshot=$(find "$CLAUDE_HOME/projects" -name "*.jsonl" | sort)

  printf '{}' > "$projects_dir/forked-session-id.jsonl"

  record_session "/my/project" "$snapshot" "source-session-id"

  run read_session_field "$SESSIONS_DIR/forked-session-id" forked_from
  [ "$output" = "source-session-id" ]
}

@test "record_session does nothing when no new jsonl is detected" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{}' > "$projects_dir/existing.jsonl"

  local snapshot
  snapshot=$(find "$CLAUDE_HOME/projects" -name "*.jsonl" | sort)

  record_session "/my/project" "$snapshot"

  [ -z "$(ls -A "$SESSIONS_DIR")" ]
}

# ---------------------------------------------------------------------------
# list_sessions
# ---------------------------------------------------------------------------

@test "list_sessions prints a message when no sessions exist" {
  run list_sessions

  [[ "$output" == *"No sessions recorded yet"* ]]
}

@test "list_sessions shows session id and folder for each recorded session" {
  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"
  printf "folder=/project/b\n" > "$SESSIONS_DIR/bbbb-2222"

  run list_sessions

  [[ "$output" == *"aaaa-1111"* ]]
  [[ "$output" == *"/project/a"* ]]
  [[ "$output" == *"bbbb-2222"* ]]
  [[ "$output" == *"/project/b"* ]]
}

@test "list_sessions shows fork sessions grouped under their parent with (fork) prefix" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"timestamp":"2026-01-01T10:00:00.000Z"}\n' > "$projects_dir/aaaa-1111.jsonl"
  printf '{"timestamp":"2026-01-01T11:00:00.000Z"}\n' > "$projects_dir/bbbb-2222.jsonl"

  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"
  printf "folder=/project/a\nforked_from=aaaa-1111\n" > "$SESSIONS_DIR/bbbb-2222"

  run list_sessions

  [[ "$output" == *"(fork)"* ]]
  [[ "$output" == *"bbbb-2222"* ]]
  # fork line must appear after its parent
  local parent_pos fork_pos
  parent_pos=$(echo "$output" | grep -n "aaaa-1111" | head -1 | cut -d: -f1)
  fork_pos=$(echo "$output" | grep -n "bbbb-2222" | head -1 | cut -d: -f1)
  [ "$fork_pos" -gt "$parent_pos" ]
}

@test "list_sessions sorts root sessions by last_active descending" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"timestamp":"2026-01-01T10:00:00.000Z"}\n{"timestamp":"2026-01-01T12:00:00.000Z"}\n' \
    > "$projects_dir/aaaa-1111.jsonl"
  printf '{"timestamp":"2026-01-02T10:00:00.000Z"}\n{"timestamp":"2026-01-02T10:00:00.000Z"}\n' \
    > "$projects_dir/bbbb-2222.jsonl"

  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"
  printf "folder=/project/b\n" > "$SESSIONS_DIR/bbbb-2222"

  run list_sessions

  local pos_a pos_b
  pos_a=$(echo "$output" | grep -n "aaaa-1111" | head -1 | cut -d: -f1)
  pos_b=$(echo "$output" | grep -n "bbbb-2222" | head -1 | cut -d: -f1)
  # bbbb-2222 has more recent last_active, must appear first
  [ "$pos_b" -lt "$pos_a" ]
}

@test "list_sessions shows NOTE column header" {
  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"

  run list_sessions

  [[ "$output" == *"NOTE"* ]]
}

@test "list_sessions shows note inline for a session that has one" {
  printf "folder=/project/a\nnote=security audit\n" > "$SESSIONS_DIR/aaaa-1111"

  run list_sessions

  [[ "$output" == *"security audit"* ]]
}

# ---------------------------------------------------------------------------
# register_session
# ---------------------------------------------------------------------------

@test "register_session copies the JSONL and creates an index entry" {
  local src_dir
  src_dir=$(mktemp -d)
  printf '{"timestamp":"2026-01-01T10:00:00.000Z"}\n' > "$src_dir/aaaa-1111.jsonl"

  local folder
  folder=$(mktemp -d)

  confirm() { return 0; }

  register_session "$src_dir/aaaa-1111.jsonl" "$folder"

  [ -f "$CLAUDE_HOME/projects/-workspace/aaaa-1111.jsonl" ]
  [ -f "$SESSIONS_DIR/aaaa-1111" ]
  run read_session_field "$SESSIONS_DIR/aaaa-1111" folder
  [ "$output" = "$folder" ]

  rm -rf "$src_dir" "$folder"
}

@test "register_session fails if the session is already registered" {
  local src_dir
  src_dir=$(mktemp -d)
  printf '{}' > "$src_dir/aaaa-1111.jsonl"
  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"

  local folder
  folder=$(mktemp -d)

  run register_session "$src_dir/aaaa-1111.jsonl" "$folder"

  [ "$status" -ne 0 ]
  [[ "$output" == *"already registered"* ]]

  rm -rf "$src_dir" "$folder"
}

@test "register_session fails if the source file does not exist" {
  run register_session "/nonexistent/aaaa-1111.jsonl" "/some/folder"

  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a file"* ]]
}

# ---------------------------------------------------------------------------
# delete_session
# ---------------------------------------------------------------------------

@test "delete_session removes the session index file" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{}' > "$projects_dir/aaaa-1111.jsonl"
  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"

  # Bypass confirm() by stubbing it
  confirm() { return 0; }

  delete_session "aaaa-1111"

  [ ! -f "$SESSIONS_DIR/aaaa-1111" ]
}

@test "delete_session removes the JSONL conversation file" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{}' > "$projects_dir/aaaa-1111.jsonl"
  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"

  confirm() { return 0; }

  delete_session "aaaa-1111"

  [ ! -f "$projects_dir/aaaa-1111.jsonl" ]
}

@test "delete_session fails if the session has forks" {
  printf "folder=/project/a\n" > "$SESSIONS_DIR/aaaa-1111"
  printf "folder=/project/a\nforked_from=aaaa-1111\n" > "$SESSIONS_DIR/bbbb-2222"

  run delete_session "aaaa-1111"

  [ "$status" -ne 0 ]
  [[ "$output" == *"has forks"* ]]
  [ -f "$SESSIONS_DIR/aaaa-1111" ]
}

@test "delete_session fails if session is not in the index" {
  run delete_session "nonexistent-id"

  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# sessions_for_folder
# ---------------------------------------------------------------------------

@test "sessions_for_folder shows only sessions matching the given folder" {
  local folder_a folder_b
  folder_a=$(mktemp -d)
  folder_b=$(mktemp -d)

  printf "folder=%s\n" "$folder_a" > "$SESSIONS_DIR/aaaa-1111"
  printf "folder=%s\n" "$folder_b" > "$SESSIONS_DIR/bbbb-2222"

  run sessions_for_folder "$folder_a"

  rm -rf "$folder_a" "$folder_b"

  [[ "$output" == *"aaaa-1111"* ]]
  [[ "$output" != *"bbbb-2222"* ]]
}

@test "sessions_for_folder prints a message when no sessions match the folder" {
  local folder_a folder_b
  folder_a=$(mktemp -d)
  folder_b=$(mktemp -d)

  printf "folder=%s\n" "$folder_a" > "$SESSIONS_DIR/aaaa-1111"

  run sessions_for_folder "$folder_b"

  rm -rf "$folder_a" "$folder_b"

  [[ "$output" == *"No sessions found for folder"* ]]
}

@test "sessions_for_folder shows fork sessions grouped under their parent with (fork) prefix" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"timestamp":"2026-01-01T10:00:00.000Z"}\n' > "$projects_dir/aaaa-1111.jsonl"
  printf '{"timestamp":"2026-01-01T11:00:00.000Z"}\n' > "$projects_dir/bbbb-2222.jsonl"

  local folder
  folder=$(mktemp -d)

  printf "folder=%s\n" "$folder" > "$SESSIONS_DIR/aaaa-1111"
  printf "folder=%s\nforked_from=aaaa-1111\n" "$folder" > "$SESSIONS_DIR/bbbb-2222"

  run sessions_for_folder "$folder"

  rm -rf "$folder"

  [[ "$output" == *"(fork)"* ]]
  [[ "$output" == *"bbbb-2222"* ]]
  local parent_pos fork_pos
  parent_pos=$(echo "$output" | grep -n "aaaa-1111" | head -1 | cut -d: -f1)
  fork_pos=$(echo "$output" | grep -n "bbbb-2222" | head -1 | cut -d: -f1)
  [ "$fork_pos" -gt "$parent_pos" ]
}

# ---------------------------------------------------------------------------
# sort_sessions_by_last_active
# ---------------------------------------------------------------------------

@test "sort_sessions_by_last_active returns nothing when called with no arguments" {
  run sort_sessions_by_last_active

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "sort_sessions_by_last_active returns sessions ordered by last_active descending" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"timestamp":"2026-01-01T10:00:00.000Z"}\n{"timestamp":"2026-01-01T12:00:00.000Z"}\n' \
    > "$projects_dir/aaaa-1111.jsonl"
  printf '{"timestamp":"2026-01-02T10:00:00.000Z"}\n{"timestamp":"2026-01-02T10:00:00.000Z"}\n' \
    > "$projects_dir/bbbb-2222.jsonl"

  run sort_sessions_by_last_active "aaaa-1111" "bbbb-2222"

  [ "$(echo "$output" | sed -n '1p')" = "bbbb-2222" ]
  [ "$(echo "$output" | sed -n '2p')" = "aaaa-1111" ]
}

@test "sort_sessions_by_last_active places sessions with no JSONL after those with timestamps" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"timestamp":"2026-01-01T10:00:00.000Z"}\n' > "$projects_dir/aaaa-1111.jsonl"
  # cccc-3333 has no JSONL — session_timestamps returns "-"

  run sort_sessions_by_last_active "cccc-3333" "aaaa-1111"

  [ "$(echo "$output" | sed -n '1p')" = "aaaa-1111" ]
  [ "$(echo "$output" | sed -n '2p')" = "cccc-3333" ]
}

# ---------------------------------------------------------------------------
# view_session
# ---------------------------------------------------------------------------

@test "view_session accepts a direct file path and reads it" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"type":"user","timestamp":"2026-01-01T10:00:00.000Z","message":{"content":"hello"}}\n' \
    > "$projects_dir/aaaa-1111.jsonl"

  run view_session "$projects_dir/aaaa-1111.jsonl"

  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

@test "view_session accepts a session ID and locates the JSONL automatically" {
  local projects_dir="$CLAUDE_HOME/projects/-workspace"
  mkdir -p "$projects_dir"
  printf '{"type":"user","timestamp":"2026-01-01T10:00:00.000Z","message":{"content":"hello from id"}}\n' \
    > "$projects_dir/aaaa-1111.jsonl"

  run view_session "aaaa-1111"

  [ "$status" -eq 0 ]
  [[ "$output" == *"hello from id"* ]]
}

@test "view_session fails with an error when the session ID has no matching JSONL" {
  run view_session "nonexistent-session-id"

  [ "$status" -ne 0 ]
  [[ "$output" == *"no session file found"* ]]
}

# ---------------------------------------------------------------------------
# register_session — additional validation
# ---------------------------------------------------------------------------

@test "register_session fails if the source file does not have a .jsonl extension" {
  local src_dir
  src_dir=$(mktemp -d)
  printf '{}' > "$src_dir/aaaa-1111.txt"

  run register_session "$src_dir/aaaa-1111.txt" "/some/folder"

  [ "$status" -ne 0 ]
  [[ "$output" == *".jsonl"* ]]

  rm -rf "$src_dir"
}
