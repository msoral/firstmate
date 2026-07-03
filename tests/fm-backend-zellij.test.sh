#!/usr/bin/env bash
# tests/fm-backend-zellij.test.sh - fake-zellij-CLI unit tests for the zellij
# session-provider adapter (bin/backends/zellij.sh) and its composer/submit lib
# (bin/fm-zellij-lib.sh), the reference backend after the tmux->zellij migration
# (docs/zellij-backend.md). Mirrors tests/fm-backend-herdr.test.sh's fakebin/
# command-log convention: a small, LOG-based fake `zellij` that logs every
# invocation (unit-separated) and returns canned responses (new-pane id,
# list-panes --json, dump-screen output) read from files a test controls, plus
# real `jq` (a genuine adapter dependency, never faked). The real-binary smoke
# test lives in tests/fm-backend-zellij-smoke.test.sh, gated on a real zellij
# and an available terminal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the zellij adapter)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-backend-zellij-tests)

# make_zellij_fakebin: a `zellij` stub that logs every invocation (one line,
# unit-separated args, to $FM_ZELLIJ_LOG) and serves canned output from files a
# test points env vars at:
#   FM_FAKE_ZELLIJ_VERSION    -> printed for `zellij --version` (default 0.44.1)
#   FM_FAKE_ZELLIJ_SESSIONS   -> printed for `zellij list-sessions -sn`
#   FM_FAKE_ZELLIJ_NEW_PANE   -> printed for `zellij action new-pane ...`
#   FM_FAKE_ZELLIJ_PANES_JSON -> file cat for `zellij action list-panes --json`
#   FM_FAKE_ZELLIJ_DUMP       -> file cat for `zellij action dump-screen ...`
# send-keys / write-chars / close-pane are silent-on-success (log only).
make_zellij_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ZELLIJ_LOG:?}"
{
  printf 'call'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_ZELLIJ_VERSION:-zellij 0.44.1}"
  exit 0
fi
if [ "${1:-}" = list-sessions ]; then
  printf '%s' "${FM_FAKE_ZELLIJ_SESSIONS:-}"
  exit 0
fi
if [ "${1:-}" = action ]; then
  case "${2:-}" in
    new-pane)     printf '%s\n' "${FM_FAKE_ZELLIJ_NEW_PANE:-terminal_7}" ;;
    list-panes)   [ -f "${FM_FAKE_ZELLIJ_PANES_JSON:-}" ] && cat "$FM_FAKE_ZELLIJ_PANES_JSON" ;;
    dump-screen)  [ -f "${FM_FAKE_ZELLIJ_DUMP:-}" ] && cat "$FM_FAKE_ZELLIJ_DUMP" ;;
    *)            : ;;  # send-keys / write-chars / close-pane: silent success
  esac
  exit 0
fi
exit 0
SH
  chmod +x "$fb/zellij"
  printf '%s\n' "$fb"
}

# Load the adapter with a fake zellij on PATH.
setup_case() {  # <case-name>
  local c=$1 fb
  CASE_DIR="$TMP_ROOT/$c"; mkdir -p "$CASE_DIR"
  fb=$(make_zellij_fakebin "$CASE_DIR")
  export PATH="$fb:$BASE_PATH"
  export FM_ZELLIJ_LOG="$CASE_DIR/zellij.log"; : > "$FM_ZELLIJ_LOG"
  unset FM_FAKE_ZELLIJ_SESSIONS FM_FAKE_ZELLIJ_NEW_PANE FM_FAKE_ZELLIJ_PANES_JSON FM_FAKE_ZELLIJ_DUMP FM_FAKE_ZELLIJ_VERSION
}
BASE_PATH="$PATH"

# Source the adapter fresh (it sources fm-zellij-lib.sh).
FM_BACKEND_LIB_DIR="$ROOT/bin"
# shellcheck source=bin/backends/zellij.sh
. "$ROOT/bin/backends/zellij.sh"

log_has() {  # <substr>  -> 0 if any logged call contains substr (args unit-separated)
  grep -qF "$1" "$FM_ZELLIJ_LOG"
}

# --- preflight version gate --------------------------------------------------
test_preflight_version_gate() {
  setup_case preflight
  FM_FAKE_ZELLIJ_VERSION="zellij 0.44.1" fm_backend_zellij_preflight \
    || fail "preflight should accept zellij 0.44.1"
  FM_FAKE_ZELLIJ_VERSION="zellij 0.43.0" fm_backend_zellij_preflight 2>/dev/null \
    && fail "preflight should refuse zellij 0.43.0 (< 0.44.0)"
  FM_FAKE_ZELLIJ_VERSION="zellij 0.44.0" fm_backend_zellij_preflight \
    || fail "preflight should accept exactly the minimum 0.44.0"
  pass "fm_backend_zellij_preflight: >= 0.44.0 accepted, older refused"
}

# --- target parsing ----------------------------------------------------------
test_pane_of_target() {
  setup_case parse
  [ "$(fm_zellij_pane_of_target 'firstmate:terminal_5')" = terminal_5 ] \
    || fail "pane_of_target should return the pane id after the first colon"
  [ "$(fm_zellij_pane_of_target 'terminal_3')" = terminal_3 ] \
    || fail "pane_of_target should pass a bare pane id through"
  pass "fm_zellij_pane_of_target: splits <session>:<pane-id> on the first colon"
}

# --- capture -----------------------------------------------------------------
test_capture() {
  setup_case capture
  printf 'line1\nline2\nline3\nline4\n' > "$CASE_DIR/dump.txt"
  export FM_FAKE_ZELLIJ_DUMP="$CASE_DIR/dump.txt"
  local out
  out=$(fm_backend_zellij_capture 'firstmate:terminal_2' 2)
  [ "$out" = $'line3\nline4' ] || fail "capture should return the last N lines, got: $out"
  log_has $'dump-screen\x1f-p\x1fterminal_2' || fail "capture should dump-screen -p terminal_2"
  pass "fm_backend_zellij_capture: dump-screen -p <pane>, tail N lines"
}

# --- key translation ---------------------------------------------------------
test_send_key_translation() {
  setup_case sendkey
  fm_backend_zellij_send_key 'firstmate:terminal_1' Enter
  log_has $'send-keys\x1f-p\x1fterminal_1\x1fEnter' || fail "Enter should map to send-keys ... Enter"
  fm_backend_zellij_send_key 'firstmate:terminal_1' Escape
  log_has $'send-keys\x1f-p\x1fterminal_1\x1fEsc' || fail "Escape should map to Esc"
  fm_backend_zellij_send_key 'firstmate:terminal_1' C-c
  log_has $'send-keys\x1f-p\x1fterminal_1\x1fCtrl\x1fc' || fail "C-c should map to Ctrl c"
  pass "fm_backend_zellij_send_key: Enter/Escape/C-c translated to zellij key names"
}

# --- literal + line send -----------------------------------------------------
test_send_literal_and_line() {
  setup_case sendtext
  fm_backend_zellij_send_literal 'firstmate:terminal_4' 'hello world'
  log_has $'write-chars\x1f-p\x1fterminal_4\x1f--\x1fhello world' || fail "send_literal should write-chars only"
  grep -qF $'send-keys' "$FM_ZELLIJ_LOG" && fail "send_literal must NOT send Enter"
  : > "$FM_ZELLIJ_LOG"
  fm_backend_zellij_send_text_line 'firstmate:terminal_4' 'treehouse get'
  log_has $'write-chars\x1f-p\x1fterminal_4\x1f--\x1ftreehouse get' || fail "send_text_line should write-chars"
  log_has $'send-keys\x1f-p\x1fterminal_4\x1fEnter' || fail "send_text_line should then send Enter"
  pass "fm_backend_zellij_send_literal / send_text_line: literal vs literal+Enter"
}

# --- kill --------------------------------------------------------------------
test_kill() {
  setup_case kill
  fm_backend_zellij_kill 'firstmate:terminal_9'
  log_has $'close-pane\x1f-p\x1fterminal_9' || fail "kill should close-pane -p terminal_9"
  pass "fm_backend_zellij_kill: close-pane -p <pane>"
}

# --- current_path + target_exists via list-panes --json ----------------------
# Real zellij 0.44.1 reports list-panes `id` as a bare number plus an is_plugin
# flag (verified against the binary), so the adapter reconstructs
# "terminal_<id>"/"plugin_<id>" to match. These fixtures mirror that shape.
test_current_path_and_exists() {
  setup_case cwd
  cat > "$CASE_DIR/panes.json" <<'JSON'
[
  {"id":5,"is_plugin":false,"title":"fm-fix-login-k3","pane_cwd":"/home/cap/wt","is_focused":true},
  {"id":6,"is_plugin":false,"title":"fm-other","pane_cwd":"/home/cap/other"}
]
JSON
  export FM_FAKE_ZELLIJ_PANES_JSON="$CASE_DIR/panes.json"
  [ "$(fm_backend_zellij_current_path 'firstmate:terminal_5')" = /home/cap/wt ] \
    || fail "current_path should read pane_cwd for the target pane id"
  fm_backend_zellij_target_exists 'firstmate:terminal_6' || fail "target_exists should find terminal_6"
  fm_backend_zellij_target_exists 'firstmate:terminal_99' && fail "target_exists should miss terminal_99"
  pass "fm_backend_zellij_current_path / target_exists: read pane_cwd + presence from list-panes --json"
}

# Terminal and plugin panes share the numeric id space, so matching must respect
# is_plugin: a terminal_1 target must resolve to the terminal pane id 1, never a
# plugin pane that also has id 1.
test_current_path_plugin_id_collision() {
  setup_case cwdcollision
  cat > "$CASE_DIR/panes.json" <<'JSON'
[
  {"id":1,"is_plugin":true,"title":"zellij-attention","pane_cwd":"/plugin/dir"},
  {"id":1,"is_plugin":false,"title":"fm-task","pane_cwd":"/terminal/dir"}
]
JSON
  export FM_FAKE_ZELLIJ_PANES_JSON="$CASE_DIR/panes.json"
  [ "$(fm_backend_zellij_current_path 'firstmate:terminal_1')" = /terminal/dir ] \
    || fail "current_path must pick the terminal pane, not a plugin pane with the same numeric id"
  pass "fm_backend_zellij_current_path: disambiguates terminal vs plugin panes sharing a numeric id"
}

# --- create_task -------------------------------------------------------------
test_create_task() {
  setup_case create
  printf '[]\n' > "$CASE_DIR/panes.json"   # no existing panes
  export FM_FAKE_ZELLIJ_PANES_JSON="$CASE_DIR/panes.json"
  export FM_FAKE_ZELLIJ_NEW_PANE="terminal_11"
  local pid
  pid=$(fm_backend_zellij_create_task firstmate fm-newtask-a1 /proj/abs) \
    || fail "create_task should succeed and print a pane id"
  [ "$pid" = terminal_11 ] || fail "create_task should print the new pane id, got: $pid"
  log_has $'new-pane\x1f--name\x1ffm-newtask-a1\x1f--cwd\x1f/proj/abs' \
    || fail "create_task should new-pane --name <label> --cwd <proj>"
  pass "fm_backend_zellij_create_task: new-pane returns the pane id"
}

test_create_task_refuses_duplicate() {
  setup_case dup
  cat > "$CASE_DIR/panes.json" <<'JSON'
[ {"id":"terminal_3","title":"fm-dup-b2","pane_cwd":"/x"} ]
JSON
  export FM_FAKE_ZELLIJ_PANES_JSON="$CASE_DIR/panes.json"
  local out
  out=$(fm_backend_zellij_create_task firstmate fm-dup-b2 /proj/abs 2>&1) \
    && fail "create_task should refuse a label that already exists"
  assert_contains "$out" "already exists" "create_task duplicate error should say so"
  pass "fm_backend_zellij_create_task: refuses a duplicate pane label"
}

# --- container_ensure --------------------------------------------------------
test_container_ensure_inside_session() {
  setup_case inside
  local out
  out=$(ZELLIJ=0 ZELLIJ_SESSION_NAME=mycrew fm_backend_zellij_container_ensure) \
    || fail "container_ensure should succeed inside a zellij session"
  [ "$out" = mycrew ] || fail "container_ensure should reuse the current session name, got: $out"
  pass "fm_backend_zellij_container_ensure: reuses \$ZELLIJ_SESSION_NAME when inside zellij"
}

test_container_ensure_detached_firstmate_errors() {
  setup_case existing
  # A merely-detached 'firstmate' session is NOT usable: a bare `zellij action`
  # only reaches the CURRENT session, so container_ensure must refuse (not print
  # 'firstmate') when firstmate is not running inside zellij, even if such a
  # session exists.
  export FM_FAKE_ZELLIJ_SESSIONS=$'firstmate\nother\n'
  local out
  out=$(unset ZELLIJ ZELLIJ_SESSION_NAME; fm_backend_zellij_container_ensure 2>&1) \
    && fail "container_ensure should refuse a merely-detached firstmate session"
  assert_contains "$out" "zellij -s firstmate" "container_ensure should print actionable start guidance"
  pass "fm_backend_zellij_container_ensure: refuses a detached firstmate session (bare action can't reach it)"
}

test_container_ensure_no_session_errors() {
  setup_case nosession
  export FM_FAKE_ZELLIJ_SESSIONS=$'other\n'
  local out
  out=$(unset ZELLIJ ZELLIJ_SESSION_NAME; fm_backend_zellij_container_ensure 2>&1) \
    && fail "container_ensure should refuse when not inside zellij"
  assert_contains "$out" "zellij -s firstmate" "container_ensure should print actionable start guidance"
  pass "fm_backend_zellij_container_ensure: refuses with guidance when not inside zellij"
}

# --- composer detection (fm-zellij-lib) --------------------------------------
# The last non-blank viewport line is the composer proxy.
composer_dump() { printf '%s' "$1" > "$CASE_DIR/dump.txt"; export FM_FAKE_ZELLIJ_DUMP="$CASE_DIR/dump.txt"; }

test_composer_empty_bare() {
  setup_case comp-empty
  composer_dump $'some output above\n\n> \n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = empty ] \
    || fail "a bare prompt on the last line should read empty"
  pass "fm_zellij_composer_state: bare prompt -> empty"
}

test_composer_pending_text() {
  setup_case comp-pending
  composer_dump $'output\n> half-typed command\n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = pending ] \
    || fail "real unsubmitted text should read pending"
  pass "fm_zellij_composer_state: real text -> pending"
}

test_composer_bordered_empty() {
  setup_case comp-border
  # claude draws its composer as a box with a dim placeholder ellipsis inside:
  # "│ > <dim>…</dim> │". Border-strip + ghost-strip must leave just the bare
  # prompt, i.e. empty.
  composer_dump $'│ > \x1b[2m\xe2\x80\xa6\x1b[0m │\n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = empty ] \
    || fail "a bordered-but-empty composer should read empty"
  pass "fm_zellij_composer_state: bordered-empty composer -> empty"
}

test_composer_bottom_border_empty() {
  setup_case comp-bottom-border
  # A composer bottom border rendered BELOW the bare prompt must not read as
  # pending: scanning up past the border reaches the bare prompt -> empty.
  composer_dump $'> \n╰────────╯\n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = empty ] \
    || fail "a bottom border below a bare prompt should read empty"
  pass "fm_zellij_composer_state: bottom border below bare prompt -> empty"
}

test_composer_idle_hint_empty() {
  setup_case comp-hint
  # An idle keyboard-shortcut hint rendered below the input row must be skipped,
  # so the bare prompt above it decides the verdict -> empty.
  composer_dump $'> \n? for shortcuts\n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = empty ] \
    || fail "an idle hint line below a bare prompt should read empty"
  pass "fm_zellij_composer_state: idle hint line below bare prompt -> empty"
}

test_composer_pending_above_hint() {
  setup_case comp-pending-hint
  # A hint line below REAL typed input must not hide the pending text above it.
  composer_dump $'> half-typed command\n? for shortcuts\n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = pending ] \
    || fail "real text above an idle hint line should still read pending"
  pass "fm_zellij_composer_state: real text above an idle hint -> pending"
}

test_composer_busy_footer_empty() {
  setup_case comp-busy
  composer_dump $'working on it\nesc to interrupt\n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = empty ] \
    || fail "a busy footer on the last line is not pending input"
  pass "fm_zellij_composer_state: busy footer -> empty"
}

test_composer_dim_ghost_empty() {
  setup_case comp-ghost
  # A dim/faint (SGR 2) ghost suggestion in an otherwise-empty composer.
  composer_dump $'> \x1b[2mtry running the tests\x1b[0m\n'
  [ "$(fm_zellij_composer_state 'firstmate:terminal_1')" = empty ] \
    || fail "dim ghost text must not read as pending input"
  pass "fm_zellij_composer_state: dim ghost text stripped -> empty"
}

test_composer_unknown_on_dump_failure() {
  setup_case comp-unknown
  unset FM_FAKE_ZELLIJ_DUMP   # dump-screen prints nothing, but exit 0 -> blank
  # With a blank dump (no non-blank lines) the composer reads empty, not unknown;
  # unknown is reserved for an actual read failure. Force a read failure by
  # pointing at a zellij that exits non-zero for dump-screen.
  local fb="$CASE_DIR/failbin"; mkdir -p "$fb"
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" = dump-screen ] && exit 3
exit 0
SH
  chmod +x "$fb/zellij"
  local out
  out=$(PATH="$fb:$BASE_PATH" fm_zellij_composer_state 'firstmate:terminal_1')
  [ "$out" = unknown ] || fail "an unreadable pane should read unknown, got: $out"
  pass "fm_zellij_composer_state: dump failure -> unknown"
}

# --- submit core -------------------------------------------------------------
test_submit_core_empty_verdict() {
  setup_case submit-ok
  composer_dump $'> \n'   # composer reads empty after submit
  local verdict
  verdict=$(fm_zellij_submit_core 'firstmate:terminal_1' 'hi crew' 2 0.01 0.01)
  [ "$verdict" = empty ] || fail "submit should verdict 'empty' when composer clears, got: $verdict"
  log_has $'write-chars\x1f-p\x1fterminal_1\x1f--\x1fhi crew' || fail "submit should write-chars the text once"
  log_has $'send-keys\x1f-p\x1fterminal_1\x1fEnter' || fail "submit should send Enter"
  pass "fm_zellij_submit_core: types once, submits, verdict empty on clear"
}

test_submit_core_pending_verdict() {
  setup_case submit-stuck
  composer_dump $'> stuck text that never clears\n'
  local verdict
  verdict=$(fm_zellij_submit_core 'firstmate:terminal_1' 'hi' 2 0.01 0.01)
  [ "$verdict" = pending ] || fail "submit should verdict 'pending' when composer never clears, got: $verdict"
  pass "fm_zellij_submit_core: verdict pending when the composer never clears"
}

test_preflight_version_gate
test_pane_of_target
test_capture
test_send_key_translation
test_send_literal_and_line
test_kill
test_current_path_and_exists
test_current_path_plugin_id_collision
test_create_task
test_create_task_refuses_duplicate
test_container_ensure_inside_session
test_container_ensure_detached_firstmate_errors
test_container_ensure_no_session_errors
test_composer_empty_bare
test_composer_pending_text
test_composer_bordered_empty
test_composer_bottom_border_empty
test_composer_idle_hint_empty
test_composer_pending_above_hint
test_composer_busy_footer_empty
test_composer_dim_ghost_empty
test_composer_unknown_on_dump_failure
test_submit_core_empty_verdict
test_submit_core_pending_verdict

echo "# all fm-backend-zellij tests passed"
