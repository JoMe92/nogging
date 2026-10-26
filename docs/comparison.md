# How Nogging compares

Nogging is not a replacement for the tools below. It is built on two of them
(OpenSpec and Beads) and adds the part none of them claims to provide: a
named role and a write boundary for each agent, plus Git evidence that is
mirrored back into the plan. This page states what each tool describes about
itself, with a source for every claim, and where Nogging sits next to it.

Statements about other projects come from their own documentation as read on
2026-10-26. They move fast; follow the source link before relying on a detail.

## At a glance

| | What it is | Roles and write boundaries between agents | Task tracking | Where Nogging differs |
| --- | --- | --- | --- | --- |
| [spec-kit](https://github.com/github/spec-kit) | Open source toolkit giving AI coding agents "structured processes, reusable templates, and documented outcomes" | Not described as a feature | `/speckit-tasks` and `/speckit-implement` commands in chat | Nogging keeps the plan in OpenSpec, execution in Beads, and fences who may write each |
| [OpenSpec](https://github.com/Fission-AI/OpenSpec) alone | "Spec-driven development (SDD) for AI coding assistants"; one folder per change with proposal, specs, design, `tasks.md` | Not described as a feature; the human reviews the plan before code | `tasks.md` is an "implementation checklist" | Nogging materializes `tasks.md` into claimable Beads and mirrors evidence back |
| [Beads](https://github.com/gastownhall/beads) alone | "Distributed graph issue tracker for AI agents, powered by Dolt" | Not described as a feature | Dependency graph, `bd ready` | Nogging adds the approved-spec side and the role fences around it |
| [Claude Code subagents](https://code.claude.com/docs/en/sub-agents) | Specialized assistants, each with its own context window, system prompt and tool access | Per-subagent tool allowlist (`tools`) and denylist (`disallowedTools`) | None built in | Nogging adds a planning phase, durable task ownership, worktrees and cross-agent coverage |

## spec-kit

spec-kit describes Spec-Driven Development as a set of chat commands:
`/speckit-constitution`, `/speckit-specify`, `/speckit-plan`, `/speckit-tasks`
and `/speckit-implement`. It is MIT licensed. Both projects are spec-driven.
The difference is what surrounds the spec. Nogging does not define its own
spec format: it uses OpenSpec for intent and Beads for executable work, and
makes the boundary between them explicit (see
[Non-negotiable boundaries](../README.md#non-negotiable-boundaries)).

Source: <https://github.com/github/spec-kit>.

## OpenSpec alone

OpenSpec gives each change its own folder with a proposal, specs, a design and
a `tasks.md`, and archives completed changes. It is MIT licensed. If you want
specs and a human-reviewed plan and nothing more, OpenSpec alone is enough.
Nogging uses OpenSpec as its source of intent and adds what happens after the
plan is approved: stable `TASK-...` IDs become Beads, a Lead Agent claims and
closes them, and `nogg sync` writes the execution evidence back into the
OpenSpec change. Nogging does not change OpenSpec itself.

Source: <https://github.com/Fission-AI/OpenSpec>.

## Beads alone

Beads is a Dolt-backed issue tracker with a dependency graph and hierarchical
IDs for epics, tasks and sub-tasks; `bd ready` lists unblocked work. Its own
documentation does not describe a dedicated spec or planning-document feature.
Nogging adopts Beads as its only tracker and adds the approved specification
that tasks are derived from, the planning/execution split and the write
boundary between them. Nogging is independent of the Beads maintainers; see
[Inspiration and related projects](../README.md#inspiration-and-related-projects).

Source: <https://github.com/gastownhall/beads>.

## Plain Claude Code subagents

Claude Code subagents are Markdown files with YAML frontmatter, stored for
example in `.claude/agents/`, each running "in its own context window with a
custom system prompt, specific tool access, and independent permissions". The
`tools` field is an allowlist and `disallowedTools` a denylist. Nogging ships
six specialist subagents of exactly this kind (see `.claude/agents/`), so
subagents are part of Nogging, not an alternative to it. What plain subagents
do not give you is the surrounding structure: an approved plan, durable
claims that survive a session ending, one worktree per piece of work, a
guard on who may edit `openspec/`, and the same loop for Codex and Pi.

Source: <https://code.claude.com/docs/en/sub-agents>.

## Choosing

- You want specs only: use OpenSpec or spec-kit.
- You want an agent-native issue tracker only: use Beads.
- You want one agent with helpers inside a single Claude Code session: use
  subagents.
- You want several agents, possibly from different vendors, to work one repo
  from an approved plan with enforced roles and Git evidence: that is Nogging.

Back to the [README](../README.md) or the [documentation index](README.md).
