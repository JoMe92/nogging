# Glossary

This page defines the terms Nogging uses, one line each, with a link to the
page that explains the term. It is for readers who meet a word in a guide or a
command and want the short answer first. Terms are in the order you meet them.

## Roles

- **Product Owner**: the human who approves intent, reviews pull requests and signs acceptance; see [Operating model](operating-model.md).
- **Planning Agent**: the agent that writes and validates an OpenSpec change in a planning session and is the only one allowed to edit `openspec/`; see [Operating model](operating-model.md).
- **Lead Agent** and **Main Worker**: the agent that claims a Bead, implements it in its own worktree and closes it; the two names mean the same role; see [Operating model](operating-model.md#delegation-model-and-the-lead-agent-knowledge-path).
- **specialist**: a narrow subagent (architect, UI/UX designer, backend or frontend engineer, code reviewer, test runner) that a Lead Agent delegates one isolated slice to; see [Operating model](operating-model.md#delegation-model-and-the-lead-agent-knowledge-path).
- **Orchestration Agent**: the always-on, Claude-only session that drives Planning and Lead sessions through `nogg` and never signs acceptance; see [Operating model](operating-model.md#orchestration).

## Work

- **change**: one OpenSpec change directory holding the proposal, design, specs and `tasks.md` for an agreed piece of work; see [Concepts](concepts.md).
- **task ID**: the stable `TASK-…` identifier of one line in `tasks.md`, carried by its Bead as an `openspec:task:` label; see [Operating model](operating-model.md).
- **task sizing**: the configured line ranges for one task (and so one Bead) and for one commit; a task is a vertical slice delivering one testable capability, tagged with its production-line estimate `[~N loc]`; see [`task_sizing`](configuration.md#task_sizing).
- **Bead**: one tracked unit of work in the Beads issue tracker, normally one task of a change; see [Concepts](concepts.md).
- **claim**: taking a Bead for yourself with `bd update <id> --claim` before you start; see [Your first change](first-change.md).
- **discovery**: a finding that matters to the plan, recorded on the Bead with the `discovery` label and a prose note; see [Operating model](operating-model.md#discoveries).
- **evidence note**: the Bead note that lists every commit SHA of the Bead and the validation output before the Bead is closed; see [Operating model](operating-model.md).
- **materialize**: creating the Beads of a change from its `tasks.md`; see [`materialize`](commands.md#materialize).
- **sync**: the mechanical pass that mirrors Bead state back into `tasks.md` and reconciles closed Beads; see [`sync`](commands.md#sync).
- **acceptance report**: the written record of an acceptance run that the Product Owner signs; see [Acceptance](acceptance.md).

## Sessions and safety

- **writer (planning, sync)**: the role named in a commit's `Nogging-Writer` trailer; only the planning writer commits `openspec/` and only the sync writer commits the mirrored evidence; see [Operating model](operating-model.md).
- **sentinel and fence**: the sentinel is the `openspec.readonly` marker that `plan-end` writes; the fence is the read-only `openspec/` root that a launched non-planning session gets; together they keep execution agents out of the spec; see [Architecture](architecture.md).
- **planning lock**: the `planning.lock` file that makes sync skip while a planning session is open; see [Failure recovery](failure-recovery.md).
- **worktree record**: the JSON file under `.nogging/state/worktrees/` that remembers which worktree, branch and Bead belong together; see [`worktree`](commands.md#worktree).
- **LIMBO**: a Bead with committed work whose status was never closed; the commits may hold all of the work or only its first steps, so what is missing is finished, then noted and closed; see [Failure recovery](failure-recovery.md).
- **tier**: the difficulty label (`routine`, `standard`, `complex`) that picks an agent's model and effort; see [Model selection](model-selection.md#tiers).
- **authority level** (restricted, trusted, full access): how much a session may do, from vendor-restricted approvals and network to autonomous edits, commits, integration and pushing; see [Security model](security-model.md#trust-boundaries-and-authority-levels).
- **command floor**: the fixed set of commands denied to every launched session whatever its profile, lifted only for the Orchestration Agent; see [Security model](security-model.md).
