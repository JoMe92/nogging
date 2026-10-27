# Frequently asked questions

Short answers with a pointer to the page that has the detail. The README
carries the same questions in brief; this page is the longer form.

## How do I run several coding agents on one repository?

Give every agent its own Git worktree and its own Bead. `./scripts/nogg
worktree implement <bead> <branch>` allocates an isolated worktree from
`develop`, and `./scripts/nogg session launch --role lead --bead <id>` starts a
supervised session on it. Claims are recorded in Beads, so two agents cannot
take the same task. See [Worktree workflow](worktree-workflow.md) and
[Running work in sessions](running-work-in-sessions.md).

## How do I stop an AI agent from editing the plan?

In Nogging the approved plan lives in `openspec/`, and only a supervised
planning session holding the planning lock may write it. Execution roles (the
Lead Agent and its specialists) are fenced from `openspec/` by the installed
guard hooks and instructions, even while a planner holds the lock. Protection
strength differs per agent runtime; read the
[security and threat model](security-model.md) and the
[architecture reference](architecture.md#the-openspec-write-boundary) for what
is enforced mechanically and what rests on instructions.

## Does Nogging work with Codex?

Yes. Codex is a supported integration (validated against a specific CLI
version, listed in the [compatibility matrix](compatibility.md)). Claude Code
and Pi are supported too; Antigravity is experimental. `AGENTS.md` is the
shared instruction file and `scripts/nogg` is the same bridge for every agent.
See [Using Nogging with Codex](using-with-codex.md),
[Pi](using-with-pi.md) and [Antigravity](using-with-antigravity.md).

## Does it replace an agent runtime?

No. Nogging launches and supervises the agent CLIs you already have (Claude
Code, Codex, Pi and, experimentally, Antigravity) and gives them roles, a plan, a task tracker and
an evidence trail. It is not an agent runtime, hosted service or model
provider. See [Vision and architecture](vision-and-architecture.md).

## Which operating systems are supported?

Linux is the supported host: Ubuntu on x86_64 in CI and Debian-family on
aarch64 with a dated acceptance report. macOS, Windows and WSL are not claimed.
The exact tool versions are in the [compatibility matrix](compatibility.md).

## What does it need installed?

Bash, Git, Python, Node.js 18 or newer, OpenSpec, Beads and Dolt; tmux and
systemd are optional. `scripts/bootstrap` provisions them on a fresh machine,
and `./scripts/nogg doctor` reports what is missing. See
[Installation](installation.md), then follow [Your first change](first-change.md).

## Is it safe to run agents with full access?

Only on a host and repository you trust. Nogging defaults to restricted
authority and documents what `--full-access` and the background sync service
change. Read the [security and threat model](security-model.md) first.

## What happens when a run is interrupted?

Claims, notes and worktree records persist, so work can be recovered rather
than redone. See [Failure recovery](failure-recovery.md).

## Where do I ask questions or show what I built?

In [GitHub Discussions](https://github.com/JoMe92/nogging/discussions)
(categories Q&A and Show and tell). Bugs and feature requests go to
[Issues](https://github.com/JoMe92/nogging/issues/new/choose); vulnerabilities
follow the [security policy](https://github.com/JoMe92/nogging/blob/main/SECURITY.md).

Back to the [README](https://github.com/JoMe92/nogging#readme) or the [documentation index](index.md).
