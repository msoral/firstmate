# Zellij runtime backend (reference / default)

`zellij` is firstmate's default session-provider backend. It plays the same
role tmux played before the tmux->zellij migration: the visible pane firstmate
creates per crewmate and then watches, types into, captures, and kills. tmux
remains a fully implemented, still-selectable backend (`--backend tmux` /
`FM_BACKEND=tmux` / `config/backend`), and `herdr` remains the experimental
alternative. This document is the empirical record for the zellij adapter, the
counterpart of [docs/herdr-backend.md](herdr-backend.md).

## Status: reference backend

The zellij adapter (`bin/backends/zellij.sh`) and its composer/submit library
(`bin/fm-zellij-lib.sh`) provide the same function surface as the tmux adapter,
so every caller that dispatches through `bin/fm-backend.sh` (`fm-spawn`,
`fm-send`, `fm-peek`, `fm-watch`, `fm-teardown`, `fm-crew-state`) drives zellij
with no call-site change. A new spawn resolves to zellij by default
(`fm_backend_name`), and a zellij task records `backend=zellij` in its meta. The
absent-`backend=` compatibility default stays `tmux`, so every task spawned
before the migration keeps resolving to tmux with no forced rewrite.

## Requirements: zellij >= 0.44.0 and jq

The adapter relies on CLI-automation features that landed in **zellij 0.44.0**:
`--pane-id` targeting for `send-keys` / `write-chars` / `dump-screen`,
`list-panes --json`, and `new-pane` printing its created pane id. `jq` parses
`list-panes --json` for pane cwd and existence. Both are gated at spawn time by
`fm_backend_zellij_preflight` (a too-old or absent zellij, or a missing jq,
fails the spawn with an actionable message), and bootstrap
(`bin/fm-bootstrap.sh`) lists zellij as a core required tool with the same
>= 0.44.0 version check.

## Worktree provider stays treehouse

zellij is a session provider only. Worktrees are still created and torn down by
treehouse exactly as for tmux and herdr; `fm-spawn` runs `treehouse get` inside
the new pane and polls the pane cwd to detect the worktree.

## Task container shape: one named pane per task

Each task is a single zellij pane created with `zellij action new-pane --name
fm-<id> --cwd <project>` inside firstmate's own zellij session. `new-pane`
returns the pane id (`terminal_<n>`), and everything afterward addresses the
pane by `--pane-id`. firstmate and all its crew panes share the one session, so
each `zellij action --pane-id` resolves in the current session with no session
flag (`fm_zellij_action`). This is simpler than herdr's per-home workspace model
(see "Known limitations"); it trades herdr's workspace-per-home separation for a
deterministic pane id and no per-home glue.

## Target string and meta fields

The recorded target is `"<session>:<pane-id>"`, e.g. `firstmate:terminal_5` —
the same `<session>:<pane-id>` shape the herdr adapter uses, so
`fm_backend_resolve_selector` needs no zellij-specific logic (it returns the
meta `window=` value verbatim). The pane id never contains a colon, and the
session is the first field, so `fm_zellij_pane_of_target` splits on the first
colon. A zellij task additionally records `zellij_session=` and
`zellij_pane_id=` in its meta.

## Command mapping (verified against zellij 0.44.1)

| firstmate primitive        | zellij command                                            |
| -------------------------- | --------------------------------------------------------- |
| create task pane           | `action new-pane --name fm-<id> --cwd <proj>` -> `terminal_<n>` |
| bounded capture            | `action dump-screen -f -p <pane>` (tail N lines; `-f` gives scrollback parity with tmux) |
| styled capture (composer)  | `action dump-screen -a -p <pane>`                         |
| send named key             | `action send-keys -p <pane> <key>` (Enter / Esc / Ctrl c) |
| send literal text          | `action write-chars -p <pane> -- <text>`                  |
| current path               | `action list-panes --json` -> pane `pane_cwd`             |
| target exists              | `action list-panes --json` -> pane present                |
| kill task                  | `action close-pane -p <pane>`                             |
| container ensure           | reuse `$ZELLIJ_SESSION_NAME` (must run inside zellij) |

### Verified CLI facts

Verified by driving a real zellij 0.44.1 session (given a pty via python3, since
zellij needs a controlling terminal):

- `new-pane --name <label> --cwd <dir>` prints the created pane id as
  `terminal_<n>` on stdout and opens a default shell in `<dir>`.
- `list-panes --json` prints a **flat array** of pane objects. Each pane's `id`
  is a bare **number** (not `terminal_<n>`), accompanied by an `is_plugin`
  boolean; terminal and plugin panes share the numeric id space. The adapter
  therefore matches a stored `terminal_<n>`/`plugin_<n>` by **reconstructing**
  `(is_plugin ? "plugin_" : "terminal_") + id` rather than matching the raw
  number — otherwise a plugin pane sharing a terminal pane's number could be
  mismatched. Each pane object also carries `title`, `is_focused`, `pane_cwd`,
  `tab_id`/`tab_name`, `terminal_command`, and `cursor_coordinates_in_pane`.
- `dump-screen -p <pane>` dumps that pane's viewport to stdout (`-a` preserves
  ANSI styling, `-f` includes scrollback). It dumps only the pane's own content,
  not zellij's tab/status-bar chrome.
- `send-keys -p <pane> Enter` and `write-chars -p <pane> -- <text>` deliver to
  the targeted pane without moving focus. `send-keys` takes human-readable key
  names; firstmate's `Enter`/`Escape`/`C-<x>` are translated to `Enter`/`Esc`/
  `Ctrl <x>`.
- `close-pane -p <pane>` closes the targeted pane (returns 0).

## Composer verification: last-line, not ANSI-cursor-row

The one place the zellij adapter deliberately differs from tmux. tmux reads the
exact cursor row (`display-message '#{cursor_y}'` + a single-row styled
`capture-pane -e`) to tell an empty composer from a human mid-typing and to
strip dim ghost/placeholder text. zellij's CLI has **no cursor-row query**, so
`fm-zellij-lib.sh` dumps the styled viewport (`dump-screen -a`) and scans the
**last few non-blank lines from the bottom up** for the composer input row. A
harness may render a composer bottom border (`╰────╯`), a keyboard-shortcut hint
(`? for shortcuts`), or a submit hint (`↵ to send`) *below* the input row, so
the scan **skips** pure border/whitespace lines (stripping both vertical and
horizontal box-drawing glyphs) and idle hint/footer lines (overridable via
`FM_ZELLIJ_HINT_RE`), and lets the first genuine line decide the verdict. A busy
footer still reads as empty (an agent mid-turn). The dim-ghost stripping
(`fm_zellij_strip_ghost`) and the empty/pending/unknown verdicts are otherwise
byte-for-byte the same as `fm-tmux-lib.sh`, so both backends behave identically
to callers. `list-panes` does expose `cursor_coordinates_in_pane`, so a
future refinement could read the exact cursor row; the bottom-window heuristic is
what `tests/fm-backend-zellij-smoke.test.sh` keeps honest.

## Headless sessions: zellij needs a terminal

Unlike tmux (`new-session -d` starts a detached server session headlessly),
zellij sessions are bound to a client terminal and cannot be created without
one. The adapter also drives panes with a bare `zellij action` (no `--session`
flag), which only reaches the session the caller is *inside*, so a merely
detached session cannot be driven at all. So `fm_backend_zellij_container_ensure`:

1. reuses the current session (`$ZELLIJ_SESSION_NAME`) when firstmate runs
   inside zellij — the normal case, since zellij is the default a captain runs
   firstmate in; else
2. refuses with actionable guidance (`zellij -s firstmate`), because a detached
   session (even one named `firstmate`) is not reachable by a bare `zellij
   action` and zellij cannot create a headless session without a terminal.

The test suite gives zellij a pty via python3 to exercise the real binary;
`tests/fm-backend-zellij-smoke.test.sh` skips unless zellij >= 0.44.0, jq, and
python3 are all present, so CI skips it exactly like the herdr smoke test.

## Known limitations

- **Current-session only.** The adapter targets the session firstmate runs in,
  which is correct for normal operation (firstmate and its crew panes share one
  session). It does not thread an explicit `--session` through every call, so it
  does not target a pane in a *different* zellij session. The recorded
  `<session>:` prefix is kept for identification/recovery.
- **Away-mode daemon injection stays tmux-oriented.** The `/afk` supervise
  daemon (`bin/fm-supervise-daemon.sh`) injects escalations into firstmate's
  *own* supervisor pane through tmux-specific primitives. Its crewmate stale
  rechecks are already backend-aware (they go through `fm_backend_*`), but its
  injection into the firstmate pane assumes tmux; away-mode injection into a
  firstmate running inside zellij is a follow-up. The always-on watcher
  (`fm-watch.sh`), the normal supervision path, is fully backend-generic and
  works with zellij today.
- **Secondmate panes share the primary session.** herdr gives each firstmate
  home its own workspace; the zellij adapter (v1) puts every task pane in the
  current session, so a primary-launched secondmate's crew panes land in the
  primary's session rather than a separate per-home space. A per-home
  workspace/tab model is a possible future refinement.

## Testing

- `tests/fm-backend-zellij.test.sh` — fake-zellij-CLI unit tests (a logging
  fake `zellij` + real jq), covering the preflight version gate, target
  parsing, capture, key translation, literal/line send, kill, current-path and
  existence (including the terminal/plugin numeric-id collision), create-task
  and duplicate refusal, container-ensure, and the composer/submit logic
  (empty/pending/bordered/busy-footer/dim-ghost/unknown verdicts). Runs in CI.
- `tests/fm-backend-zellij-smoke.test.sh` — real zellij smoke test, gated on a
  real zellij >= 0.44.0 + jq + python3. Drives an actual session end to end:
  container-ensure, create-task, duplicate refusal, current-path, target-exists,
  send + capture, and kill.
