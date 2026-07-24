# Away-mode injection delivery: supervisor-pane resolution and verify-before-trust

This doc owns the mechanism and evidence for how the away-mode daemon finds the captain pane and proves it can deliver into it.
`docs/wedge-alarm.md` owns the alert channels the failure path fires.
`.agents/skills/afk/SKILL.md` owns the agent-facing away-mode contract.
Exact flags and env knobs stay in each script's header and `--help`.

## Incident (2026-07-21 into 2026-07-22)

The away-mode sub-supervisor daemon could not deliver escalations into the captain pane for about 10.8 hours.
Three finished workers sat committed-but-idle because their terminal status never reached firstmate, and stacked follow-on work never dispatched.
Nothing was lost: the wedge alarm did fire and the return catch-up recovered every item.
The daemon was nevertheless blind for the whole night, which is the defect.

Two failures compounded at daemon start.

1. Supervisor-pane discovery failed on the claude native-background path.
   The daemon logged `could not auto-discover supervisor pane (no FM_SUPERVISOR_TARGET, TMUX_PANE, or HERDR_ENV/HERDR_PANE_ID)` and fell back to `firstmate:0`.
2. The composer-empty guard never saw an injectable state on that fallback target, so every injection deferred and only the max-defer wedge alarm eventually fired.

The second failure is a direct consequence of the first: the guard was reading a pane that was not firstmate's composer.

## Root cause: the native-background path had no captain-pane handoff

`bin/fm-afk-start.sh` execs the daemon in the foreground of whatever terminal it is already in, and the daemon resolves the captain pane from its own inherited environment.
That works for the terminal-backed path because `bin/fm-afk-launch.sh start` resolves the captain pane first and passes it to the new terminal as `FM_SUPERVISOR_TARGET` and `FM_SUPERVISOR_BACKEND`.

The native-background path (claude, grok) was assumed to need no handoff because the daemon would inherit the captain pane's environment.
That assumption is false for claude's background bash tool.
The two steps run in different processes with different environments:

- `bin/fm-afk-launch.sh start-native` runs in firstmate's own foreground pane, where `$TMUX_PANE` or `$HERDR_PANE_ID` is present.
- `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` runs later through the harness's native background tool, detached, with none of those pane markers in its environment.

So the only process that could see the captain pane never recorded it, and the process that needed it had nothing to read.
Discovery fell through to the `firstmate:0` default.

## Fix 1: persist the resolved captain pane for the detached daemon

`bin/fm-supervisor-target-lib.sh` stays the single owner of supervisor-pane discovery and now also owns the two-process handoff.

- `fm_supervisor_target_persist <state-dir>` resolves the captain pane in the calling process and writes `<backend>\t<target>` to `state/.afk-supervisor-target`.
  It writes only when discovery resolves cleanly.
  A fallback result is deliberately not persisted, so a genuinely undiscoverable pane still reaches the daemon's own discovery-and-warning path instead of inheriting a bogus `firstmate:0`.
- `fm_supervisor_target_load_into_env <state-dir>` exports `FM_SUPERVISOR_TARGET` and `FM_SUPERVISOR_BACKEND` from that record.
  An already-set `FM_SUPERVISOR_TARGET` always wins, so the terminal-backed path's explicit values are never overridden.
  A record naming an unsupported backend is declined and the environment is left untouched.

`bin/fm-afk-launch.sh start-native` persists after it prepares lifecycle state, and `stop` removes the record.
`fm_afk_clear_stale_artifacts` clears it on a fresh entry before the new one is written, so a fresh session can never inherit a prior session's pane.
`bin/fm-afk-start.sh` loads it into the environment immediately before `exec`, so the daemon starts with the real captain pane already resolved.

The record is a daemon input hint, not a durable work record.
The daemon still validates the target at startup and verify-once still probes it, so a stale or wrong record is caught rather than trusted.

## Fix 2: verify-before-trust startup self-check

Resolving the right pane is not proof that a delivery works.
The daemon now proves injectability once at away-mode entry instead of discovering a wedge hours later.

`verify_once_injectable` in `bin/fm-supervise-daemon.sh` runs the same non-destructive gate `inject_msg` uses (target exists, pane not busy, composer affirmatively empty) over a bounded retry window, without sending any message.
It runs only while `state/.afk` exists, because off-afk there is no captain relying on delivery yet.
It never aborts startup: the daemon still runs, so the durable buffer, wake-queue replay, and max-defer net all remain in force.

Verdicts are chosen so the alarm fires only on a positive wedge signature and never on a transient busy pane:

- Composer reads `empty` or `pending`: pass.
  Both are affirmative readings of a genuine bordered agent composer, which is exactly what a wrong pane or broken composer detection cannot produce.
  `empty` is injectable now; `pending` is a real composer that merely holds text, so injection lands once it clears.
- The pane is seen idle but its composer reads `unknown`: fail.
  An idle firstmate pane must read as a structural composer, so a persistent idle-unknown is the incident's signature (unreadable pane, dead shell, or a wrong non-agent pane).
- The target never resolves across the whole window: fail.
- The pane is busy for the entire window and is never read idle: inconclusive.
  A persistently busy pane has a recognized agent footer, so it is a valid pane, and alarming here would false-positive on a slow away-mode acknowledgement.
  The warning is logged and the max-defer alarm remains the backstop.

A failure raises the wedge alarm immediately through `verify_once_alarm`: the durable `state/.subsuper-inject-wedged` marker the return catch-up already surfaces, a tmux status-line flash where applicable, and the configured active alert.
It seeds the alarm throttle so a real escalation arriving moments later does not double-alarm inside the same max-defer window.

`FM_VERIFY_ONCE_TRIES` and `FM_VERIFY_ONCE_SLEEP` bound the window (default 40 tries at 0.5s, about 20 seconds), and `FM_VERIFY_ONCE_SKIP=1` disables the probe.

## Safety properties preserved

Every existing away-mode property is unchanged and none was relaxed to add the two fixes above.
The sentinel marker prefix, the busy guard, the affirmative-empty composer guard, the max-defer wedge alarm, the single-instance portable lock, the presence gate, and durable wake-queue recovery all behave exactly as before.
Verify-once adds a read-only probe and an earlier alarm; the handoff adds an input the daemon still validates.

## Verification (2026-07-24, GNU bash 5.3.9, Linux)

Reproduction of the root cause and the fix, run from the repo root against a throwaway home:

```
# A) launcher running in a captain pane persists the resolved target
TMUX_PANE="%42" FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bin/fm-afk-launch.sh start-native
state/.afk-daemon-terminal: none	-	native
state/.afk-supervisor-target: tmux	%42

# B) the detached daemon entry, with no pane markers in its env
without handoff: firstmate:0 (rc=1)      # the incident: silent wrong-pane fallback
with handoff:    %42 (backend=tmux)      # fixed: the real captain pane

# C) stop clears the handoff record
fm-afk-launch: away mode stopped; daemon terminal torn down and .afk cleared
record after stop: removed
```

Line B is the incident reproduced exactly: without the handoff the detached entry resolves `firstmate:0` with a non-zero discovery result, which is the pane the daemon then injected into for the whole night.

Verify-once verdict matrix, from `tests/fm-daemon.test.sh`:

```
ok - verify-once: an idle empty composer confirms injectable, no alarm
ok - verify-once: a genuine composer holding text is a valid pane, no alarm
ok - verify-once: an idle unreadable composer (wrong pane) alarms immediately with a durable marker
ok - verify-once: a target that never resolves alarms immediately (wrong-pane discovery failure)
ok - verify-once: a persistently busy pane is inconclusive, not a wedge - no false alarm
ok - verify-once: skipped when afk is inactive (no captain to protect yet)
```

Native handoff cases, from `tests/fm-afk-launch.test.sh`:

```
ok - native handoff: launcher persists the resolved captain pane for the detached daemon
ok - native handoff: stop clears the supervisor-target handoff record
ok - native handoff: an unresolvable pane writes NO handoff record (no bogus firstmate:0)
ok - native handoff: detached daemon entry exports the persisted captain pane into FM_SUPERVISOR_TARGET
ok - native handoff: an explicit FM_SUPERVISOR_TARGET is never overridden by the record
ok - native handoff: a record naming an unsupported backend is declined, env left untouched
```

Suite totals with the new cases: `tests/fm-daemon.test.sh` 103 ok / 0 not-ok, `tests/fm-afk-launch.test.sh` 47 ok / 0 not-ok.
`bin/fm-lint.sh` passes at the pinned ShellCheck 0.11.0.

## Backend and harness coverage

The handoff is backend-neutral: it records whichever supervisor backend discovery resolved, and the daemon still refuses an unsupported supervisor backend loudly at startup.
`tmux` and `herdr` remain the only supported supervisor backends, so a record naming anything else is declined rather than acted on.
The native-background path applies to harnesses with an in-pane tracked-background tool (claude, grok); the terminal-backed path (`start`) is unchanged and still passes the captain pane explicitly, which the handoff never overrides.
