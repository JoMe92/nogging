# Design — opt-in multi-machine Beads sync

## Decision 1 — explicit session-boundary pull/push, not background auto-push

The issue's primary proposal (`dolt.auto-push: true` in `config.yaml`, plus
relaxing `restricted`'s deny list) was tried and found to carry a real,
unresolved risk: `bd`'s own auto-push is a background side effect of every
write command, and under a `restricted` session's network-off stance it
would attempt and fail on every single Bead write unless every such session
also passes `--sandbox` — a flag `bd` exposes only on the command line, with
no environment-variable equivalent in this version (confirmed by inspecting
the binary; `BD_IGNORE_SCHEMA_SKEW` has one, `--sandbox` does not). Nogging
does not wrap `bd` calls (deliberately — it is a third-party tool, agents
call it directly), so there is no single place to inject `--sandbox`
automatically, and leaving it to each agent's own discipline would
reintroduce exactly the "ask an agent to remember a rule" problem this
change exists to remove.

This change takes the issue's own fallback instead: **explicit pull/push at
session boundaries, trusted/orchestrator-level sessions only.**

- `bd dolt pull` once, at the start of a `trusted` or orchestrator session —
  before reading Beads state, so the session starts from the latest known
  state across machines.
- `bd dolt push` before such a session ends, if it made any Bead write
  (create, update, claim, close).
- `restricted` sessions do nothing differently. Their Bead writes land in
  the local Dolt commit history exactly as today (local writes are never
  blocked, only `push`/`pull`/`remote` are) — and reach the remote via the
  same machine's next `trusted`/orchestrator session's push, with no special
  handling needed, since a push pushes every pending local Dolt commit, not
  only the pushing session's own.

**No profile change is required.** `trusted.json` already allows `Bash(bd:*)`
with no Dolt-specific deny entry — `bd dolt push`/`pull` already work under
`trusted` today. Only `restricted` denies them, and `restricted` does not
need them under this design. The orchestrator profile already runs
unrestricted. This is a smaller change than the issue's own proposal assumed
was necessary.

## Decision 2 — visibility via `doctor`, not a new sync mode

`scripts/nogg doctor` gains a NOTE: "local Dolt is N commit(s) ahead of
`<remote>`" when applicable, read via `bd dolt status`/equivalent, mirroring
how `doctor` already surfaces a skipped sync tick. This directly satisfies
the issue's fourth acceptance criterion without adding a new sync mechanism
— the existing mechanical `sync`/`doctor` pass already runs regularly and is
the natural place to surface this, not a new background process.

## Decision 3 — diverged histories point at `bd`'s own recovery path

Two machines writing Beads before either has pulled is a newly *likely*
scenario once this mode is on (it was always possible, just unlikely without
an explicit protocol encouraging concurrent local writes). `bd` already
detects this (`Local and remote Dolt histories have diverged`) and already
documents a recovery path (`Recovery (bootstrap from one canonical clone)`,
per the binary's own string table). `docs/nogging/failure-recovery.md` gains
a short section naming this scenario and pointing at `bd`'s own guidance,
rather than Nogging inventing a second, parallel recovery procedure for the
same condition.

## Non-goals

- No change to `restricted`'s deny list or to any launch profile.
- No change to `dolt.auto-push`/`config.yaml`'s Dolt settings.
- No handling for the five grab-bag observations — see `proposal.md`, *Out
  of scope*.
- Default stays `false`: a repository that never sets `multi_machine: true`
  in `.nogging/config.json` behaves exactly as it does today, including
  every existing test and the acceptance harness.
