#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}

# --- native-background cross-process handoff --------------------------------
# On the claude/grok native-background afk path the launcher and the daemon run
# in DIFFERENT processes with different environments:
#   - bin/fm-afk-launch.sh start-native runs in firstmate's OWN foreground pane,
#     so $TMUX_PANE / $HERDR_PANE_ID are present and discover_supervisor_target
#     resolves the real captain pane.
#   - The daemon is exec'd LATER by bin/fm-afk-start.sh THROUGH the harness's
#     native background tool, which runs detached with none of those pane markers
#     in its env, so its own discover_supervisor_target would silently fall back
#     to firstmate:0 (the 2026-07-21 wedge: escalations aimed at the wrong pane
#     for ~10.8h).
# The terminal-backed path avoids this by passing FM_SUPERVISOR_TARGET on the
# daemon command line; the native path cannot (no command line to inject env
# into), so the foreground launcher persists the resolved target/backend here and
# the background daemon entry loads it into FM_SUPERVISOR_TARGET/
# FM_SUPERVISOR_BACKEND before exec. Same resolution, two-process handoff.
FM_SUPERVISOR_TARGET_RECORD_NAME=".afk-supervisor-target"

# fm_supervisor_target_persist <state-dir>: resolve the captain pane in THIS
# process's env and, ONLY when it resolves cleanly (not the firstmate:0
# fallback), write "<backend>\t<target>" atomically to the record. A fallback
# result (discover returns non-zero) is deliberately NOT persisted, so the daemon
# keeps its own discovery-plus-warning path for a genuinely-undiscoverable pane
# instead of inheriting a bogus firstmate:0. Returns 0 when a real target was
# persisted, non-zero otherwise (caller treats that as "nothing to hand off").
fm_supervisor_target_persist() {  # <state-dir>
  local state=$1 target backend pending
  target=$(discover_supervisor_target) || return 1
  backend=$(discover_supervisor_backend) || return 1
  [ -n "$target" ] && [ -n "$backend" ] || return 1
  mkdir -p "$state" || return 1
  pending="$state/$FM_SUPERVISOR_TARGET_RECORD_NAME.pending.$$"
  printf '%s\t%s\n' "$backend" "$target" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$state/$FM_SUPERVISOR_TARGET_RECORD_NAME" || { rm -f "$pending"; return 1; }
}

# fm_supervisor_target_load_into_env <state-dir>: if FM_SUPERVISOR_TARGET is not
# already set and a well-formed record exists, export FM_SUPERVISOR_TARGET/
# FM_SUPERVISOR_BACKEND from it. Returns 0 when it loaded a target, non-zero when
# there was nothing valid to load (env left untouched so the caller's own
# discovery/fallback still runs). An explicit FM_SUPERVISOR_TARGET always wins, so
# the terminal-backed path's command-line env is never overridden.
fm_supervisor_target_load_into_env() {  # <state-dir>
  local state=$1 record backend target
  [ -z "${FM_SUPERVISOR_TARGET:-}" ] || return 1
  record="$state/$FM_SUPERVISOR_TARGET_RECORD_NAME"
  [ -f "$record" ] || return 1
  IFS=$'\t' read -r backend target < "$record" || return 1
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  case "$backend" in
    tmux|herdr) ;;
    *) return 1 ;;
  esac
  export FM_SUPERVISOR_TARGET="$target"
  export FM_SUPERVISOR_BACKEND="$backend"
}
