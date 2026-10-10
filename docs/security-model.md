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

  `trusted` ships the same `bypassPermissions` +
  `skipDangerousModePermissionPrompt: true` pairing, so that a genuinely
  unattended `--full-access` session never stalls on an interactive approval,
  a classifier review, or the first-run disclaimer. For either profile, the
  real boundary is the project's `deny` list and its fixed command floor, not
  the permission mode — `bypassPermissions` has no classifier reviewing
  actions beyond what those deny. A project that wants the `auto`-mode
  classifier's extra review back can set its own copy of `trusted` to `auto`,
  trading away the unattended reliability `--full-access` otherwise promises
  (see `design.md`, Decision 1, for why that tradeoff was rejected as the
  shipped default).
- **Codex:** restricted sessions use Codex's sandbox with outbound network off;
  trusted sessions use workspace-write with approvals disabled and network on.
  The repository execpolicy floor loads only after Codex trusts the `.codex/`
  layer. It is not a host-wide policy.
- **Pi:** neither restricted nor trusted mode has a filesystem or network
  sandbox. The project guard extension enforces only the command floor and the
  OpenSpec boundary. Supervised Pi explicitly loads the extension with run-scoped approval; no standing trust change is required. Treat Pi
  restricted mode as materially weaker than Claude or Codex restricted mode.

The ordinary command floor rejects a short list of high-risk command classes,
including privilege escalation and destructive host operations. It cannot
prevent equivalent actions through another executable, language runtime, API,
or manually changed configuration. The orchestrator profile lifts that floor.

## Supervised child launches from Claude auto mode

Use one command at a time from the checkout, with the canonical `./scripts/nogg`
spelling. Nogging adds these narrow rules to **per-session effective settings**
for Claude Lead and orchestrator parents:

```json
{
  "permissions": {
    "allow": [
      "Bash(./scripts/nogg session launch:*)",
      "Bash(./scripts/nogg session send:*)",
      "Bash(./scripts/nogg session kickoff:*)",
      "Bash(./scripts/nogg session stop:*)",
      "Bash(./scripts/nogg session list:*)",
      "Bash(./scripts/nogg session log:*)",
      "Bash(./scripts/nogg session watch:*)"
    ]
  }
}
```

For a manually started parent, deliberately add those entries to its settings;
merge them with existing rules. `./scripts/nogg doctor` names missing rules and
unsupported auto-mode setup. Installer init/update preserve unrelated permission
lists and the chosen mode; they install named Nogging hooks without globally
changing permission modes. Specialists receive no child-launch grant.

Claude normally checks narrow Bash allow rules before its auto classifier.
`autoMode.classifyAllShell: true` suspends those rules; unattended child creation
is unsupported in that combination. Keep the denial and ask the operator for a
deliberate approval or an explicitly selected `trusted`/`orchestrator` profile.
Project `autoMode` blocks do not configure the classifier. Nogging never rewrites
user/managed classifier settings. See the [Claude auto-mode reference](https://code.claude.com/docs/en/auto-mode-config).

Direct `claude`, `codex` or `pi` invocation and persistent service installation
are outside this grant. A denied supervised launch remains a failure: retain its
diagnostic and do not use an unprofiled fallback. An allow rule does not override
an explicit deny, an ask rule or a vendor policy.

Observed on installed Claude 2.1.296 in `--permission-mode auto` with inert
stubs (issue #52): with these effective settings, `./scripts/nogg session
launch` ran in every probe, while the classifier denied a direct `codex exec`
fallback in one of three runs. Classifier verdicts are not deterministic, and
without the rules it allowed both in three runs. The scoped rules make the
supervised path predictable. Only the prompts and this policy keep direct
agent invocation out; the classifier is not a guarantee.

## Interactive Orchestration Agent permission template

Nogging ships `templates/claude/orchestrator-permissions.example.json` as a
user-settings fragment for interactive Orchestration Agent sessions. Operators
can copy or merge it into their user settings (`~/.claude/settings.json`) to allow
necessary cross-worktree exploration and orchestration commands while retaining
strict safety boundaries.

Key security model properties and constraints:

- **Allow rules do not bypass the auto-mode classifier:** In auto mode, Claude Code's
  classifier reviews actions before they execute. Allow rules do not bypass this
  classifier: broad shell grants are suspended in auto mode, and the classifier can
  still evaluate and refuse actions (such as edits to security boundaries or
  unrecognized outbound exfiltration).
- **`autoMode` is read only from user settings:** Claude Code reads classifier
  configuration (`environment`, `allow`, `soft_deny`, `hard_deny`) strictly from
  user settings (`~/.claude/settings.json` or `~/.claude.json`). Project settings
  (`.claude/settings.json` or `.claude/settings.local.json`) cannot configure or
  customize auto mode trust rules.
- **Wildcards before subcommands are hazardous:** Permission patterns like
  `Bash(git -C * add)` or `Bash(git * add)` place a wildcard before the subcommand.
  Claude Code matches everything before the first `*`, so a rule like
  `Bash(git * main)` matches any git command and options—including
  `-c core.fsmonitor=<script>`, which permits arbitrary command execution.
  Allow and deny rules must anchor on the command and subcommand before wildcards
  (e.g. `Bash(./scripts/nogg:*)` or `Bash(git push --force:*)`).
- **Superset of the command floor:** The template's deny list includes every entry
  from Nogging's `FLOOR_DENY` plus history-destroying Git commands (`git push --force`,
  `git reset --hard`, `git clean`, `git branch -D`, `git filter-branch`).
- **Manual operator setup:** `nogg init` and `nogg update` never apply or write
  the template to user or project settings files. It is an example template for the
  operator to adapt manually.

## Planning sessions and the OpenSpec boundary

A supervised planning session (`--role planning`) is the only role that may
open the OpenSpec write boundary. It does so only through its own
`plan-begin`, which takes the canonical planning lock in the main checkout
and records the owning session, host and process. Launch never takes the
lock. An orchestrator never pre-acquires it for a child, and an optional
associated Bead grants no execution authority. Execution roles stay fenced
from `openspec/` even while some planner holds the lock. `session stop`,
cleanup and recovery never release a lock owned by another live session.
Recovery names the stale owner before it closes the boundary. A planner
retires its clean, integrated worktree before `plan-end` and runs
`plan-end` from a surviving canonical checkout.

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

Follow [Nogging’s security policy](https://github.com/JoMe92/nogging/blob/develop/SECURITY.md). Do not put a suspected vulnerability,
credential, private URL, or sensitive log in a public issue.

