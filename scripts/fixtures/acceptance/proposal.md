# Add an echo-note capability

> **Fixture change — not real product intent.** This change exists only to give
> the Nogging acceptance runbook (`docs/acceptance.md`) a small, complete
> OpenSpec change to carry through install → materialize → execute → sync. It is
> copied into a throwaway repository as `openspec/changes/acceptance-example/`
> and is never shipped, applied, or archived in a real project.

## Why

The acceptance procedure needs a change that is obviously throwaway, has exactly
two tasks, and touches nothing that could be mistaken for a Nogging feature.

## What changes

- A new `echo-note` capability: a trivial helper that takes a line of text and
  writes it back verbatim to an append-only notes file. No configuration, no
  product surface.

## Impact

- New capability spec: `acceptance-example`.
- No real code — the tasks are satisfied by a stub during an acceptance run.
