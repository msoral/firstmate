#!/usr/bin/env bash
# bin/backends/zellij.sh - the zellij session-provider adapter.
#
# The default reference backend as of the tmux->zellij migration
# (docs/zellij-backend.md). Provides the same function surface as
# bin/backends/tmux.sh (create/send/capture/current-path/live-pane/kill), so
# every caller that dispatches through bin/fm-backend.sh (fm-spawn, fm-send,
# fm-peek, fm-watch, fm-teardown, fm-crew-state) drives zellij with no call-site
# changes. Sourced only through fm-backend.sh's fm_backend_source; the unit
# tests source it directly, so it must stand alone.
#
# Session provider ONLY: the worktree provider stays treehouse, exactly like the
# tmux and herdr adapters. zellij is a pure replacement for the "visible pane
# firstmate can watch, type into, capture, and kill" role.
#
# Target string shape: "<session>:<pane-id>", e.g. "firstmate:terminal_5" — the
# same <session>:<pane-id> shape the herdr adapter already uses, so
# fm_backend_resolve_selector needs no zellij-specific logic (it returns meta's
# window= verbatim). The pane id (terminal_<n> / plugin_<n> / a bare number)
# never contains a colon; the session is the first field.
#
# One named pane PER TASK (labeled fm-<id>), created with `zellij action
# new-pane` inside firstmate's own zellij session, and addressed thereafter by
# its `--pane-id`. firstmate and all its crew panes share that one session, so
# every `zellij action --pane-id` resolves in the current session with no
# session flag (see fm-zellij-lib.sh's fm_zellij_action).
#
# Requires zellij >= 0.44.0 (the release that added `--pane-id` targeting for
# send-keys/write-chars/dump-screen, `list-panes --json`, and new-pane returning
# its pane id) and jq (for reading pane_cwd out of `list-panes --json`). Both are
# gated at spawn time by fm_backend_zellij_preflight, so a machine that never
# selects zellij is unaffected. See docs/zellij-backend.md for the empirical
# basis and the container/headless-session limitation.

# shellcheck source=bin/fm-zellij-lib.sh
FM_BACKEND_ZELLIJ_LIB_DIR="${FM_BACKEND_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$FM_BACKEND_ZELLIJ_LIB_DIR/fm-zellij-lib.sh"

FM_BACKEND_ZELLIJ_MIN_VERSION="0.44.0"

# fm_backend_zellij_preflight: refuse the backend LOUDLY unless the runtime can
# actually drive it: zellij present and >= the min version, and jq present.
# Called by container-ensure at spawn time (the herdr version-gate pattern), so
# a too-old or absent zellij fails the spawn with an actionable message instead
# of producing broken panes.
fm_backend_zellij_preflight() {
  local ver lowest
  command -v zellij >/dev/null 2>&1 || {
    echo "error: zellij backend selected but 'zellij' is not installed (need >= $FM_BACKEND_ZELLIJ_MIN_VERSION)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: zellij backend selected but 'jq' is not installed (needed to read pane cwd from 'zellij action list-panes --json')" >&2
    return 1
  }
  ver=$(zellij --version 2>/dev/null | awk '{print $2}')
  if [ -n "$ver" ]; then
    lowest=$(printf '%s\n%s\n' "$FM_BACKEND_ZELLIJ_MIN_VERSION" "$ver" | sort -V | head -1)
    if [ "$lowest" != "$FM_BACKEND_ZELLIJ_MIN_VERSION" ]; then
      echo "error: zellij $ver is too old for the zellij backend (need >= $FM_BACKEND_ZELLIJ_MIN_VERSION for --pane-id CLI automation)" >&2
      return 1
    fi
  fi
  return 0
}

# fm_backend_zellij_resolve_bare_selector: the live-pane-listing fallback for a
# selector that is neither "session:pane" nor a bare "fm-<id>" routed through
# meta — an ad hoc pane label with no recorded task. Mirrors the tmux adapter's
# `list-windows | grep` fallback: find a live pane whose title matches <name>
# and return "<session>:<pane-id>". The pane id is RECONSTRUCTED as
# "terminal_<id>"/"plugin_<id>" (the same form new-pane returns and every other
# function here stores/matches), not the raw numeric `id`, so the resolved
# target is usable by the rest of the adapter. Best-effort; needs jq.
fm_backend_zellij_resolve_bare_selector() {  # <name>
  local name=$1 ses id
  ses=$(fm_backend_zellij_current_session)
  id=$(fm_zellij_action list-panes --json 2>/dev/null \
       | jq -r --arg t "$name" \
           'first(..|objects|select(.title? == $t)|((if .is_plugin then "plugin_" else "terminal_" end)+(.id|tostring))) // empty' 2>/dev/null)
  if [ -z "$id" ]; then
    echo "error: no zellij pane titled $name" >&2
    return 1
  fi
  printf '%s:%s' "$ses" "$id"
}

# fm_backend_zellij_current_session: the session firstmate is operating in. When
# firstmate runs inside zellij (the normal case) that is $ZELLIJ_SESSION_NAME;
# otherwise the dedicated "firstmate" session name (mirrors the tmux adapter's
# fixed "firstmate" session).
fm_backend_zellij_current_session() {
  if [ -n "${ZELLIJ:-}" ] && [ -n "${ZELLIJ_SESSION_NAME:-}" ]; then
    printf '%s' "$ZELLIJ_SESSION_NAME"
  else
    printf 'firstmate'
  fi
}

# fm_backend_zellij_capture: bounded plain-text pane capture. Dumps the pane's
# viewport (no styling) and returns its last <lines> lines — the zellij analogue
# of tmux's `capture-pane -p -S -"$N"`.
fm_backend_zellij_capture() {  # <target> <lines>
  local pane
  pane=$(fm_zellij_pane_of_target "$1")
  fm_zellij_action dump-screen -p "$pane" 2>/dev/null | tail -n "$2"
}

# fm_backend_zellij_send_key: one named key, translated from firstmate's tmux
# key vocabulary to zellij's. firstmate sends Enter, Escape, and C-<x> control
# keys; zellij's send-keys wants "Enter", "Esc", and "Ctrl <x>" (space-separated
# key strings). Anything unrecognized is passed through unchanged.
fm_backend_zellij_send_key() {  # <target> <key>
  local pane key=$2
  pane=$(fm_zellij_pane_of_target "$1")
  case "$key" in
    Enter)          fm_zellij_action send-keys -p "$pane" Enter ;;
    Escape|Esc)     fm_zellij_action send-keys -p "$pane" Esc ;;
    C-*)            fm_zellij_action send-keys -p "$pane" "Ctrl ${key#C-}" ;;
    *)              fm_zellij_action send-keys -p "$pane" "$key" ;;
  esac
}

# fm_backend_zellij_send_text_submit: type <text> once, then submit with Enter,
# retried (Enter only, never retyped) until the composer clears. Re-exports
# fm_zellij_submit_core (fm-zellij-lib.sh); see that file for the
# composer-verification contract and echoed verdicts.
fm_backend_zellij_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_zellij_submit_core "$@"
}

# fm_backend_zellij_container_ensure: ensure a usable zellij session and print
# its name. Succeeds ONLY when firstmate runs inside zellij ($ZELLIJ and
# $ZELLIJ_SESSION_NAME set); it reuses that session. A bare `zellij action`
# (fm_zellij_action) targets the CURRENT session and cannot reach a merely
# detached session, so an existing detached "firstmate" session is NOT usable —
# reporting success for one would make the very next new-pane fail with no
# session context. zellij, unlike tmux, also cannot spin up a headless detached
# session without a controlling terminal, so this refuses with actionable
# guidance instead of silently producing a broken target
# (docs/zellij-backend.md "Headless sessions"). Runs the version/jq preflight
# first.
fm_backend_zellij_container_ensure() {
  fm_backend_zellij_preflight || return 1
  if [ -n "${ZELLIJ:-}" ] && [ -n "${ZELLIJ_SESSION_NAME:-}" ]; then
    printf '%s' "$ZELLIJ_SESSION_NAME"
    return 0
  fi
  echo "error: the zellij backend needs firstmate to run inside a zellij session. Start one with: zellij -s firstmate  (a bare 'zellij action' only reaches the current session, so a detached session cannot be driven, and zellij cannot create a headless session without a terminal)" >&2
  return 1
}

# fm_backend_zellij_create_task: create the task's pane in <proj-abs>, labeled
# <pane-name>, refusing a live pane that already carries that label. Prints the
# created pane id (terminal_<n>). Mirrors the tmux adapter's
# duplicate-check-then-new-window sequence; <session> is accepted for signature
# parity with the tmux adapter (zellij new-pane targets the current session).
fm_backend_zellij_create_task() {  # <session> <pane-name> <proj-abs>
  local ses=$1 wname=$2 proj_abs=$3 existing pid
  existing=$(fm_zellij_action list-panes --json 2>/dev/null \
             | jq -r --arg t "$wname" 'first(..|objects|select(.title? == $t)|.id) // empty' 2>/dev/null)
  if [ -n "$existing" ]; then
    echo "error: zellij pane $ses:$wname already exists" >&2
    return 1
  fi
  pid=$(fm_zellij_action new-pane --name "$wname" --cwd "$proj_abs" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$pid" ]; then
    echo "error: zellij new-pane did not return a pane id for $wname" >&2
    return 1
  fi
  printf '%s' "$pid"
}

# fm_backend_zellij_current_path: the live pane's current working directory, or
# empty on any error. Reads pane_cwd out of `list-panes --json` for the target
# pane — the zellij analogue of tmux's `#{pane_current_path}`. `list-panes` (real
# zellij 0.44.1, verified) reports `id` as a bare NUMBER plus an `is_plugin`
# flag, and terminal and plugin panes share that numeric id space, so the pane
# is matched by RECONSTRUCTING its "terminal_<id>"/"plugin_<id>" string (the same
# form new-pane returns and this adapter stores) rather than the raw number.
fm_backend_zellij_current_path() {  # <target>
  local pane
  pane=$(fm_zellij_pane_of_target "$1")
  fm_zellij_action list-panes --json 2>/dev/null \
    | jq -r --arg id "$pane" \
        'first(.[]|select(((if .is_plugin then "plugin_" else "terminal_" end)+(.id|tostring)) == $id)|.pane_cwd) // empty' 2>/dev/null
}

# fm_backend_zellij_send_text_line: send one line of TEXT then Enter, no composer
# verification — the fixed spawn-time commands (`treehouse get`, the GOTMPDIR
# export). Mirrors the tmux adapter's `send-keys "<text>" Enter`.
fm_backend_zellij_send_text_line() {  # <target> <text>
  local pane
  pane=$(fm_zellij_pane_of_target "$1")
  fm_zellij_action write-chars -p "$pane" -- "$2"
  fm_zellij_action send-keys -p "$pane" Enter
}

# fm_backend_zellij_send_literal: send TEXT as literal characters with no
# submission — the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter). Mirrors `send-keys -l`.
fm_backend_zellij_send_literal() {  # <target> <text>
  local pane
  pane=$(fm_zellij_pane_of_target "$1")
  fm_zellij_action write-chars -p "$pane" -- "$2"
}

# fm_backend_zellij_kill: remove the task's pane, best-effort. Mirrors the tmux
# adapter's `kill-window ... || true`.
fm_backend_zellij_kill() {  # <target>
  local pane
  pane=$(fm_zellij_pane_of_target "$1")
  fm_zellij_action close-pane -p "$pane" 2>/dev/null || true
}

# fm_backend_zellij_target_exists: cheap READ-ONLY existence check — is the pane
# still present in `list-panes --json`? Matches the reconstructed
# "terminal_<id>"/"plugin_<id>" form (see fm_backend_zellij_current_path). Used
# by fm-backend.sh's fm_backend_target_exists zellij arm.
fm_backend_zellij_target_exists() {  # <target>
  local pane
  pane=$(fm_zellij_pane_of_target "$1")
  [ -n "$(fm_zellij_action list-panes --json 2>/dev/null \
       | jq -r --arg id "$pane" \
           'first(.[]|select(((if .is_plugin then "plugin_" else "terminal_" end)+(.id|tostring)) == $id)|.id) // empty' 2>/dev/null)" ]
}
