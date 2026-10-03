# Opt-in multi-machine Beads sync

## Source

[GitHub issue #25](https://github.com/JoMe92/nogging/issues/25) — a Product
Owner working the same Nogging-managed repository from more than one machine
has no built-in guarantee that Beads created or closed on one machine reach
another: nothing pulls at session start or pushes at session end, the
managed instruction block's conservative default explicitly says the
opposite, `docs/nogging/failure-recovery.md` calls cross-machine propagation
"a separate concern," and the `restricted` profile denies `bd dolt push|pull`
outright.

The issue also lists five unrelated observations from the same rollout
(a Bead-ID case-mismatch regex gap, a stale `core.hooksPath` after install, a
worktree `install-hooks` failure, `doctor`/`validate` hard-requiring `tmux`,
and the one-branch-per-change convention limiting parallel delivery). The
reporter offered to split these into separate issues. This change does not
plan them — see *Out of scope*.

## Research performed

- Read `bd dolt --help` and `bd config --help` directly, and inspected the
  installed `bd` binary's string table, rather than trusting the issue's
  recalled config keys. Confirmed: `dolt.auto-push`, `dolt.auto-push-interval`,
  and `dolt.auto-push-timeout` are real `config.yaml` keys (present in the
  binary, just not in the curated `--help` key list) — the issue's workaround
  is accurate, not misremembered.
- Confirmed `--sandbox` genuinely suppresses `bd`'s internal auto-push
  attempt — the binary's own string table carries the exact message `dolt
  auto-push: skipped (sandbox mode)`. This resolves the issue's own open
  question ("not verified whether the profile's `Bash(bd dolt push:*)` deny
  applies to bd's internal auto-push" — it does not; only `--sandbox` does).
- Checked for a `BD_SANDBOX`/`BEADS_SANDBOX` environment variable the way
  other `bd` flags expose one (`BD_IGNORE_SCHEMA_SKEW` does): **none
  exists**. `--sandbox` is CLI-flag-only in this `bd` version (1.2.2). A
  design that depends on something always passing `--sandbox` to every `bd`
  write would need to wrap every `bd` invocation Nogging never otherwise
  wraps — see Decision 1 in `design.md` for why this change avoids that
  requirement entirely instead.
- Checked `trusted.json`: it already allows `Bash(bd:*)` with no Dolt-
  specific deny entry. A `trusted`/orchestrator-level session can already run
  `bd dolt push`/`bd dolt pull` today — **no profile change is needed** for
  the mechanism this change actually proposes (see `design.md`, Decision 1).
  Only `restricted` denies it, and `restricted` sessions do not need to
  change: their Bead writes land in the local Dolt history regardless of
  push rights, and reach the remote via the same machine's next
  trusted/orchestrator session.
- Found the binary's own string table already carries a documented recovery
  message for the one real risk multi-machine sync introduces: `Local and
  remote Dolt histories have diverged` paired with `Recovery (bootstrap from
  one canonical clone)`. This change points to that existing mechanism
  rather than inventing a parallel one.

## Why

A Product Owner who works from more than one machine today has to remember,
unaided, to push after every Bead change and pull before starting — a rule
that currently lives only in `bd remember`, invisible to any other tool or
session. The goal is to make that propagation structural when opted in,
without weakening the default (single-machine, sandboxed) behavior at all.

## What Changes

- An opt-in `"multi_machine": true` key in `.nogging/config.json` (default
  `false` — single-machine and sandboxed setups are unaffected).
- When enabled, the managed `AGENTS.md`/`CLAUDE.md` instruction block gains a
  multi-machine section: `bd dolt pull` at the start of a `trusted` or
  orchestrator session, `bd dolt push` before such a session ends if it made
  any Bead write. `restricted` sessions are unaffected — they already write
  locally regardless, and do not attempt a push.
- `scripts/nogg doctor` gains a NOTE when local Dolt commits are ahead of the
  configured remote, so unpushed state is visible without waiting for a push
  to fail.
- `docs/nogging/failure-recovery.md` gains a short section pointing at `bd`'s
  own diverged-history recovery path, since this change makes that scenario
  newly reachable in normal operation (two machines writing before either
  pulls).

## Out of scope

- **Not setting `dolt.auto-push` in `config.yaml`.** The issue's own
  proposal led with this; this change takes the simpler alternative the
  issue itself offered as a fallback — explicit pull-at-start/push-at-end —
  specifically because it needs no `--sandbox` workaround and no profile
  change at all (see `design.md`, Decision 1).
- **The five grab-bag observations are not planned here.** Each is an
  independent, unrelated bug (ID-case regex, hook-path handling after
  install, a worktree-specific `install-hooks` failure, an optional-tool
  dependency, and the branch-naming convention's one-branch-per-change
  limit). Folding five unrelated fixes into a change named for multi-machine
  sync would make this change's own diff and review harder to reason about
  for no benefit. They are listed below as recommended follow-up issues, not
  dropped silently:
  - Bead-ID case-mismatch between `bd`'s lower-case-only prefixes and the
    commit-msg/LIMBO token regex's upper-case requirement.
  - `core.hooksPath` pointing at a stale temp path after install.
  - `scripts/install-hooks` failing in a worktree (`.git` is a file there,
    not a directory).
  - `nogg validate`/`doctor` hard-requiring `tmux` instead of degrading to a
    NOTE.
  - The one-branch-per-change convention blocking real parallel delivery of
    one change's Beads — independently re-confirmed during this same
    delivery day: consolidating three Beads of `unblock-autonomous-sessions`
    worked around it by using temporary per-Bead branch names and
    renaming/re-opening a PR by hand after the fact, which is exactly the
    friction this observation describes. This one in particular deserves its
    own focused planning session, not a quick fix bundled here.
