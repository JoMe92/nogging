# Security and threat model

Nogging coordinates coding agents inside a Git repository. It is not a security
sandbox and it does not make an untrusted repository, agent, prompt, dependency,
or host safe. Use the least authority that can complete the work, inspect the
installed files, and keep credentials outside the repository.

Read this guide before enabling `--full-access`, a background service, or the
always-on Orchestration Agent.

## What Nogging installs and runs

`init` can install repository instructions (`AGENTS.md` and `CLAUDE.md`), agent
configuration under `.claude/`, `.codex/`, and `.pi/`, Git hooks, executable
scripts, user documentation, and rendered systemd user units. Agent instructions
and hooks affect future work in the repository; review their diffs before use.
Existing configuration is merged where documented, but an active
`core.hooksPath` can prevent Nogging's `.git/hooks` from running.

The optional sync timer periodically reads OpenSpec and Beads state and can
create local Git commits that mirror execution evidence. The optional
orchestrator service keeps a Claude Code process alive, can resume its previous
conversation, and may be reachable through Claude Remote Control. Neither
service is required for manual use.

## Trust boundaries and authority levels

| Mode | Intended authority | Important residual risk |
| --- | --- | --- |
| `restricted` | Default supervised Lead/specialist mode. Claude and Codex use approval, filesystem, and network restrictions supplied by those vendors. | Vendor controls and configured allowlists can have gaps. Repository instructions, hooks, and locally available tools still influence the agent. |
| `trusted` / `--full-access` | Explicit opt-in for one named change. It permits autonomous edits, commits, integration, and network operations such as pushing where the agent adapter supports them. | A mistaken or compromised agent can change code, contact remote services, expose readable data, or push unwanted commits. The command floor is not a general OS sandbox. |
| `orchestrator` | Always-on Claude-only supervisor with unrestricted repository/host tooling. Its command floor and OpenSpec write boundary are mechanically lifted; discipline comes from its prompt and explicit takeover rules. | This is effectively host-level automation under the user's account. Prompt injection or operator error can affect repositories, credentials, processes, and remotes. |

Full access is not inherited permission to work outside the named change. An
Orchestration Agent remains orchestrate-only unless the operator explicitly
requests a single planning or code takeover.

### Vendor-specific limits

- **Claude Code:** repository hooks and generated permission settings reduce
  routine authority, but trust and bypass-permission dialogs are vendor
  controls. The orchestrator deliberately uses bypass-permission mode. Trust
  the workspace only after reviewing it.
- **Codex:** restricted sessions use Codex's sandbox with outbound network off;
  trusted sessions use workspace-write with approvals disabled and network on.
  The repository execpolicy floor loads only after Codex trusts the `.codex/`
  layer. It is not a host-wide policy.
- **Pi:** neither restricted nor trusted mode has a filesystem or network
  sandbox. The project guard extension enforces only the command floor and the
  OpenSpec boundary, and Pi must trust/approve the project extension. Treat Pi
  restricted mode as materially weaker than Claude or Codex restricted mode.

The ordinary command floor rejects a short list of high-risk command classes,
including privilege escalation and destructive host operations. It cannot
prevent equivalent actions through another executable, language runtime, API,
or manually changed configuration. The orchestrator profile lifts that floor.

## Network, filesystem, and credentials

An agent can disclose every secret it can read whenever its mode permits
outbound traffic. Keep API keys, SSH keys, cloud credentials, password stores,
browser profiles, production data, and unrelated repositories outside its
readable workspace where possible. Use narrowly scoped, short-lived tokens and
repository permissions; never put tokens in prompts, command arguments,
commits, Beads notes, acceptance reports, logs, or OpenSpec artifacts.

Git hooks and agent extensions run as the current user. A systemd user service
inherits the service environment and can outlive the terminal that enabled it.
Inspect generated units and environment sources; do not place secrets directly
in unit files. Session logs under `.nogging/state/sessions/` may contain prompts
and command output, so protect and review them before sharing or publishing.

## Safe enablement

Before broader authority:

1. Work on a private, backed-up repository and inspect `git status`.
2. Review the installed instructions, hooks, agent configuration, launch
   profiles, generated systemd units, and the exact task scope.
3. Run `./scripts/nogg doctor` and start with the default restricted mode.
4. Confirm the agent vendor's workspace-trust prompt yourself. Do not treat a
   remembered trust decision as approval of newly changed repository content.
5. Use `--full-access` only for one named change and monitor its session/log.
6. Enable the sync timer or orchestrator service only when persistent execution
   is desired and the host account contains no unnecessarily exposed secrets.

Only after those checks should an operator use commands such as:

```bash
./scripts/nogg session launch --role lead --bead SPEC-xxx --full-access
systemctl --user enable --now nogg-sync-<slug>.timer
systemctl --user enable --now nogg-orchestrator-<slug>.service
```

## Disable and remove safely

Stop persistent activity before moving or removing a checkout:

```bash
./scripts/nogg orchestrator stop
./scripts/nogg session list
systemctl --user disable --now nogg-orchestrator-<slug>.service
systemctl --user disable --now nogg-sync-<slug>.timer
```

Stop any remaining sessions explicitly with `./scripts/nogg session stop
<name>`. Then use `npx github:JoMe92/nogging#<tag> remove --dry-run` to review
what the matching release would remove before running `remove`. Review and
remove generated unit files only after disabling them. If hooks were copied or
composed into a custom `core.hooksPath`, remove only the Nogging-owned portions
there as well.

Removal must preserve target-owned `openspec/`, `.beads/`, configuration, and
unrelated agent settings. Keep a backup until `git status`, `git config
core.hooksPath`, running sessions, and user services confirm the intended
state. Revoking task-specific credentials after trusted or orchestrator work is
a prudent final step.

## Reporting a vulnerability

Follow [`SECURITY.md`](../SECURITY.md). Do not put a suspected vulnerability,
credential, private URL, or sensitive log in a public issue.

