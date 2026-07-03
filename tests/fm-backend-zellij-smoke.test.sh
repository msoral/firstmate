#!/usr/bin/env bash
# tests/fm-backend-zellij-smoke.test.sh - real zellij smoke test for the zellij
# session-provider adapter (bin/backends/zellij.sh), the zellij analogue of
# tests/fm-backend-tmux-smoke.test.sh. Every other zellij suite fakes the CLI;
# this one talks to a REAL zellij server, isolated in a private throwaway
# session, and is the empirical check that the adapter's create/send/capture/
# current-path/kill primitives work against the actual binary (docs/zellij-
# backend.md).
#
# Gated: skips unless a real zellij >= 0.44.0, jq, and python3 (used to give
# zellij the controlling terminal it requires — unlike tmux it cannot start a
# session headlessly) are all present. So CI, which has none of these, simply
# skips, exactly like the herdr smoke test.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v zellij  >/dev/null 2>&1 || { echo "skip: zellij not found"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (needed to allocate a pty for zellij)"; exit 0; }
REAL_ZELLIJ=$(command -v zellij)
_ver=$("$REAL_ZELLIJ" --version 2>/dev/null | awk '{print $2}')
_low=$(printf '0.44.0\n%s\n' "$_ver" | sort -V | head -1)
[ "$_low" = "0.44.0" ] || { echo "skip: zellij $_ver < 0.44.0 (no --pane-id CLI automation)"; exit 0; }

SESSION="fm-zellij-smoke-$$"
SHIM_DIR=
PTY_PID=
trap cleanup_all EXIT

cleanup_all() {
  [ -n "${PTY_PID:-}" ] && kill "$PTY_PID" >/dev/null 2>&1
  "$REAL_ZELLIJ" delete-session "$SESSION" --force >/dev/null 2>&1 || true
  "$REAL_ZELLIJ" kill-session "$SESSION" >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# Start the real zellij session attached to a pty (zellij needs a controlling
# terminal). The python child keeps the session alive; cleanup kills it.
python3 - "$SESSION" "$REAL_ZELLIJ" <<'PY' &
import os, sys, pty, time
ses, zj = sys.argv[1], sys.argv[2]
pid, _ = pty.fork()
if pid == 0:
    os.environ["ZELLIJ_SESSION_NAME"] = ses
    os.execvp(zj, [zj, "-s", ses])
else:
    time.sleep(120)
    os._exit(0)
PY
PTY_PID=$!

# Wait for the session to come up.
for _ in $(seq 1 20); do
  "$REAL_ZELLIJ" list-sessions -sn 2>/dev/null | grep -qx "$SESSION" && break
  sleep 0.5
done
"$REAL_ZELLIJ" list-sessions -sn 2>/dev/null | grep -qx "$SESSION" \
  || { echo "skip: could not bring up a real zellij session in time"; exit 0; }

# A `zellij` shim on PATH that routes every `action ...` call to the private
# smoke session (the adapter itself issues bare `zellij action`, targeting the
# current session; the shim stands in for "firstmate runs inside its session").
# Mirrors the tmux smoke's private-socket shim.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-zellij-smoke.XXXXXX")
cat > "$SHIM_DIR/zellij" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = action ]; then exec "$REAL_ZELLIJ" --session "$SESSION" "\$@"; fi
exec "$REAL_ZELLIJ" "\$@"
SH
chmod +x "$SHIM_DIR/zellij"
PATH="$SHIM_DIR:$PATH"
export PATH

FM_BACKEND_LIB_DIR="$ROOT/bin"
# shellcheck source=bin/backends/zellij.sh
. "$ROOT/bin/backends/zellij.sh"

# container_ensure: inside the session, reuse its name.
ses=$(ZELLIJ=0 ZELLIJ_SESSION_NAME="$SESSION" fm_backend_zellij_container_ensure) \
  || fail "container_ensure failed"
[ "$ses" = "$SESSION" ] || fail "container_ensure should return the current session, got '$ses'"
pass "container_ensure: reuses the current zellij session"

# create_task: make a named pane in the repo root; expect a real pane id.
PANE=$(fm_backend_zellij_create_task "$SESSION" fm-smoke1 "$ROOT") || fail "create_task failed"
case "$PANE" in terminal_*) : ;; *) fail "create_task should return a terminal_<n> id, got '$PANE'" ;; esac
TARGET="$SESSION:$PANE"
pass "create_task: new-pane returned '$PANE'"

# duplicate refused.
fm_backend_zellij_create_task "$SESSION" fm-smoke1 "$ROOT" >/dev/null 2>&1 \
  && fail "create_task should refuse a duplicate label" || true
pass "create_task: refuses a duplicate label against live panes"

# current_path: the pane's cwd is the repo root.
sleep 1
CWD=$(fm_backend_zellij_current_path "$TARGET")
[ "$CWD" = "$ROOT" ] || fail "current_path should be '$ROOT', got '$CWD'"
pass "current_path: reads the real pane cwd"

# target_exists: present now.
fm_backend_zellij_target_exists "$TARGET" || fail "target_exists should find the live pane"
pass "target_exists: finds the live pane"

# send_text_line + capture: run a marker command, see it in the dump.
fm_backend_zellij_send_text_line "$TARGET" 'echo ZELLIJ_SMOKE_MARKER_OK'
sleep 1
CAP=$(fm_backend_zellij_capture "$TARGET" 60)
printf '%s' "$CAP" | grep -q ZELLIJ_SMOKE_MARKER_OK \
  || fail "capture should show the echoed marker; got:"$'\n'"$CAP"
pass "send_text_line + capture: text is delivered and captured"

# kill: the pane is gone afterward.
fm_backend_zellij_kill "$TARGET"
sleep 1
if fm_backend_zellij_target_exists "$TARGET"; then
  fail "target_exists should miss the pane after kill"
fi
pass "kill: closes the pane"

echo "# all fm-backend-zellij-smoke tests passed"
