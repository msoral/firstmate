#!/usr/bin/env bash
# fm-zellij-lib.sh — shared zellij pane primitives for firstmate.
#
# The zellij analogue of bin/fm-tmux-lib.sh: ONE source of truth for busy
# detection, composer-empty (pending-input) detection, and a verify-and-retry
# submit, for the zellij session backend (bin/backends/zellij.sh, added by the
# tmux->zellij migration; docs/zellij-backend.md). Sourced by the zellij adapter
# and, through it, by fm-send.sh's backend-generic submit dispatch.
#
# Why a SEPARATE lib rather than reusing fm-tmux-lib.sh: the two share the same
# harness-level goals (tell an empty composer from a human mid-typing, ignore
# dim ghost/placeholder text, retry only the Enter) and the same dim-ghost
# stripping, but they read the pane through fundamentally different primitives.
# tmux exposes the exact cursor row (`display-message '#{cursor_y}'` +
# single-row `capture-pane -e -S cy -E cy`); zellij has no cursor-row query in
# its CLI, so this lib dumps the pane viewport WITH styling
# (`zellij action dump-screen -a --pane-id P`) and classifies the LAST non-blank
# line as the composer proxy. The dim/border stripping and the empty/pending
# verdicts are otherwise identical to fm-tmux-lib.sh so the two backends behave
# the same to callers; the single deliberate difference is which line is read.
# This last-line heuristic is the one piece the empirical smoke test
# (tests/fm-backend-zellij-smoke.test.sh) exists to keep honest.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# dim-ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / fm-tmux-lib.sh).
#
# All functions are `set -u` and `set -e` safe (guarded zellij calls, explicit
# returns) so they can be sourced into either context.

# Busy footers per harness (mirror fm-tmux-lib.sh's FM_TMUX_BUSY_REGEX_DEFAULT).
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel".
FM_ZELLIJ_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

# fm_zellij_action: run `zellij action <args...>` against the CURRENT session.
# firstmate and every crew pane it spawns live in the same zellij session (the
# panes are created with `zellij action new-pane` inside it), so `--pane-id`
# targeting resolves without a session flag; the recorded "<session>:<pane-id>"
# target keeps the session only for identification/recovery. Kept as a single
# choke point so a future cross-session flag lands in exactly one place.
fm_zellij_action() {  # <action-args...>
  zellij action "$@"
}

# fm_zellij_pane_of_target: the pane id from a "<session>:<pane-id>" target.
# The pane id (terminal_<n> / plugin_<n> / a bare number) never contains a
# colon, and the session is always the FIRST field, so split on the first
# colon only. A target with no colon is treated as already being a bare pane id.
fm_zellij_pane_of_target() {  # <target>
  case "$1" in
    *:*) printf '%s' "${1#*:}" ;;
    *)   printf '%s' "$1" ;;
  esac
}

# fm_zellij_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from one
# captured line, then drop any remaining escape sequences, leaving only the
# plain normal-intensity text a human actually typed. Byte-for-byte the same
# awk as fm-tmux-lib.sh's fm_tmux_strip_ghost — the ghost/placeholder problem is
# harness-level, not backend-level, so both backends strip it identically. Reads
# a styled line on stdin, prints plain text on stdout. LC_ALL=C makes awk walk
# bytes so multibyte glyphs and dim runs pass through or drop intact.
fm_zellij_strip_ghost() {
  LC_ALL=C awk '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update dim/faint state
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0) out = out c        # keep only normal-intensity bytes
        i++
      }
      print out
    }
  '
}

# fm_zellij_last_composer_line: the LAST non-blank line of the pane's styled
# viewport, with dim ghost text removed and escapes stripped. This is the zellij
# stand-in for tmux's exact cursor-row read: for every verified harness the
# bottom-most non-blank rendered line is the composer input row (or, mid-turn,
# the busy footer that classification already treats as empty). Prints the plain
# line (may be empty); returns 1 only when the pane could not be dumped at all.
fm_zellij_last_composer_line() {  # <target>
  local target=$1 pane raw
  pane=$(fm_zellij_pane_of_target "$target")
  raw=$(fm_zellij_action dump-screen -a -p "$pane" 2>/dev/null) || return 1
  printf '%s\n' "$raw" | fm_zellij_strip_ghost | grep -v '^[[:space:]]*$' | tail -1
}

# fm_zellij_composer_state: classify the composer line of <target> as
#   empty   - no pending input (blank, a bare prompt, a busy footer, or only dim
#             ghost text). Safe to inject; also the positive submit ack.
#   pending - real unsubmitted text (a human mid-typing, or a swallowed Enter).
#   unknown - the pane could not be read.
# Mirrors fm-tmux-lib.sh's fm_tmux_composer_state verdicts exactly; only the
# line source differs (last non-blank viewport line vs the tmux cursor row).
fm_zellij_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 line stripped
  line=$(fm_zellij_last_composer_line "$target") || { printf 'unknown'; return 0; }
  # Strip the composer box borders (literal glyphs — no character classes).
  stripped=${line//│/}      # U+2502 light vertical (claude)
  stripped=${stripped//┃/}  # U+2503 heavy vertical
  stripped=${stripped//|/}  # ASCII pipe
  # Trim surrounding whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # Nothing left = empty composer.
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # Just a bare prompt glyph = empty composer (idle).
  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer landing on the last line is not pending input.
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_ZELLIJ_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  printf 'pending'; return 0
}

# fm_zellij_pane_input_pending: 0 (pending) iff the composer holds real
# unsubmitted text, 1 otherwise. An unreadable pane is NOT pending (fail-safe,
# same bias as fm-tmux-lib.sh).
fm_zellij_pane_input_pending() {  # <target>
  [ "$(fm_zellij_composer_state "$1")" = pending ]
}

# fm_zellij_pane_is_busy: 0 iff the pane's last few non-blank lines show a busy
# footer (an agent mid-turn). Scans a 40-line tail like fm-watch.sh / fm-tmux-lib.
fm_zellij_pane_is_busy() {  # <target>
  local target=$1 pane tail40
  pane=$(fm_zellij_pane_of_target "$target")
  tail40=$(fm_zellij_action dump-screen -p "$pane" 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_ZELLIJ_BUSY_REGEX_DEFAULT}"
}

# fm_zellij_submit_enter_core / fm_zellij_submit_core: the zellij verify-and-retry
# submit, mirroring fm-tmux-lib.sh's fm_tmux_submit_* contract exactly. Type the
# text ONCE with `write-chars`, then submit with an Enter key, retrying Enter
# ONLY (never retyping — a swallowed Enter leaves our text in the composer and
# retyping would duplicate it). Echoes the final verdict on stdout
# (empty|pending|unknown|send-failed) so callers pick their own success policy.
fm_zellij_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 pane i=0 state
  pane=$(fm_zellij_pane_of_target "$target")
  while :; do
    fm_zellij_action send-keys -p "$pane" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_zellij_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_zellij_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 pane
  pane=$(fm_zellij_pane_of_target "$target")
  fm_zellij_action write-chars -p "$pane" -- "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_zellij_submit_enter_core "$target" "$retries" "$sleep_s"
}
