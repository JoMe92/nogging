# Documentation

An index of everything under `docs/`. Start at the top-level
[`README.md`](../README.md) if you haven't yet — it covers the concept,
quick start, and safety warning. This page is for finding the right guide
once you're past that.

## Concepts

What Nogging is and why it's built the way it is.

| Guide | Covers |
| --- | --- |
| [Vision and architecture](vision-and-architecture.md) | What Nogging is for; the architecture as built today |
| [Architecture](architecture.md) | Exact data contracts, safety gates, session supervision, the OpenSpec write boundary |
| [Operating model](operating-model.md) | The five roles, the change lifecycle, and how planning and execution hand off |
| [Project identity](project-identity.md) | The canonical name, repository, and identifiers — the source of truth the README must match |

## Using Nogging

Installing it, running it day to day, and its guarantees.

| Guide | Covers |
| --- | --- |
| [Installation](installation.md) | `init`, `update`, flags, and what gets touched in your repo |
| [Compatibility matrix](compatibility.md) | Supported OS, tool versions, and agent integrations, with evidence |
| [Worktree workflow](worktree-workflow.md) | Why every planning and implementation run gets its own Git worktree |
| [Running work in sessions](running-work-in-sessions.md) | `scripts/nogg session` — starting, watching, and steering a supervised agent session |
| [Security and threat model](security-model.md) | What Nogging does and doesn't protect against; authority levels |
| [Failure recovery](failure-recovery.md) | `doctor`, `audit`, and recovering from an interrupted run |
| [Using Nogging with Codex](using-with-codex.md) | What's specific to running the loop from OpenAI Codex |
| [Using Nogging with Pi](using-with-pi.md) | What's specific to running the loop from Pi |

## Releasing and maintaining

For anyone cutting a release or proving one is ready.

| Guide | Covers |
| --- | --- |
| [Releasing Nogging](releasing.md) | The repeatable procedure for tagging a release candidate or final release |
| [Acceptance runbook](acceptance.md) | The reproducible end-to-end procedure a release must pass before sign-off |
| [Acceptance report template](acceptance-report-template.md) | Copy this into `acceptance/<date>-<host>.md` for each run |
| [`acceptance/`](acceptance/) | The dated, signed acceptance reports produced by that runbook |
| [Public cutover checklist](public-cutover.md) | The owner-executed, not-yet-run checklist for going public |

## Assets

[`brand/`](brand/) holds the logo, banner, social card, and the diagrams
embedded in the top-level README.

---

Product planning history — naming research, identity decisions, and internal
audit/status snapshots — lives in the private
[`JoMe92/rooftree`](https://github.com/JoMe92/rooftree) companion repository,
not here.
