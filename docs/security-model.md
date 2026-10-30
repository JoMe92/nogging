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

### Scheduled-loop approval

Loop definitions can be committed with repository code or stored at a configured
ignored path. Runtime state and the approval ledger are host-local. The ledger
binds approval to a hash of the timezone, normalized loop definition and prompt
bytes; an edit makes that loop unapproved until reviewed and approved again.
The ledger records the OS user name, not an email address. Prompt validation
rejects common secret and token forms without printing the matched value.
Approval is an operational safeguard against accidental changes, not a security
boundary against another process with host write access. Inspect loop prompts
and the launch authority before approving them. The Orchestration Agent may
manage loops only on explicit Product Owner instruction; other supervised
sessions cannot mutate loop definitions or host state.

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
  trading away the unattended reliability `--full-access` otherwise promises.
  Nogging ships `bypassPermissions` as the default for that reason.
- **Codex:** restricted sessions use Codex's sandbox with outbound network off;
  trusted sessions use workspace-write with approvals disabled and network on.
  The repository execpolicy floor loads only after Codex trusts the `.codex/`
  layer. It is not a host-wide policy. Under `on-request` a command inside the
  sandbox runs without a prompt, and one matching an `allow` rule in the user's
  `$CODEX_HOME/rules/` leaves the sandbox without one. A restricted scheduled-loop
  run therefore starts with no command tools and a read-only sandbox.
- **Pi:** neither restricted nor trusted mode has a filesystem or network
  sandbox. The project guard extension enforces only the command floor and the
  OpenSpec boundary. Supervised Pi explicitly loads the extension with run-scoped approval; no standing trust change is required. Treat Pi
  restricted mode as materially weaker than Claude or Codex restricted mode.

- **Antigravity (experimental):** the guard keeps the command floor and the
  OpenSpec boundary but there is no validated filesystem or network sandbox.
  Treat it as the weakest of the supported agents and review its first sessions
  closely.

Antigravity's guard treats `search_web` as guarded, read-only network access,
alongside `read_url_content`: trusted permits a non-empty query, while
restricted requires approval. Malformed queries and unsupported tools are
denied with sanitized reasons that do not echo argument values.

### Session backends: tmux and herdr

Supervised agent sessions run on either `tmux` (default) or `herdr` (experimental;
see [using-with-herdr](using-with-herdr.md)).

- **Socket isolation:** Both backends communicate over same-user local Unix
  domain sockets (`0600` permissions) without opening network listeners, remote
  endpoints, or web interfaces.
- **Identical wrapper and floor:** The Nogging launch wrapper, command floor,
  OpenSpec write boundary, and authority profiles apply identically regardless
  of whether tmux or herdr hosts the session.
- **Herdr security posture:** Nogging disables native auto-restore
  (`resume_agents_on_restore = false`) to prevent agents from being restarted
  outside the launch wrapper after a server restart. It disables herdr
  auto-updates, remote access, plugins, and pane history
  (`pane_history = false`) to avoid persisting secrets from console output to
  unrotated history files. Nogging never installs herdr agent integration hooks
  globally.
- **Orchestration Agent:** The Orchestration Agent always runs on tmux
  (`orchestrator run`), even if herdr is configured as the default session
  backend.

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
stubs: with these effective settings, `./scripts/nogg session
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
runs `plan-end` from its planning worktree, and only then retires its clean,
integrated worktree from the surviving canonical checkout (`plan-end` always
precedes worktree retirement).

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

### The Codex stop hook

Codex runs a local hook directly, outside its sandbox, so a hook is a way out of
the sandbox for whoever can define one. That decides three things about the stop
guard's hook:

- **It is user-level.** A project hook cannot be trusted in a fresh worktree: its
  trust key holds the absolute path of `.codex/hooks.json`, and every Lead gets a
  new one. `-c` trust has no effect. A persisted user-level record works from any
  working directory, because a user hook's key has no project path.
- **`--dangerously-bypass-hook-trust` is refused.** With it, a Lead in
  `workspace-write` could write `.codex/hooks.json` in its own worktree and get a
  command run outside its sandbox on its next stop. `session-launch` never passes
  it, and a test asserts that.
- **Only one constant command is ever trusted.** `nogg session-hooks install` is
  an explicit operator act on personal configuration, like `codex-prompts-link`.
  It records the hash Codex reports for the exact constant command, and only as
  Codex lists it from the user-level file. A sandboxed Lead cannot edit that file,
  and any later edit reads `modified` and is skipped. The command does nothing
  outside a supervised session, and the text the guard sends a Lead is fixed: it
  carries gap names, never agent output.

**Known limit: installing this hook removes the sandbox as a boundary for every
supervised Codex session in `workspace-write`, in every repository on that host.**
That covers Lead, specialist and planning sessions, because the hook fires for all
of them, and it holds under `on-request` approval too, because editing a file
inside a writable root needs no approval. The trusted hash pins the command's text,
not the file it runs. That file is `scripts/nogg` in the checkout, which such a
session can edit: the wrapper adds the checkout with `--add-dir`, and only
`openspec/` is read-only inside it. The hook then runs the edited file outside the
sandbox, with the network and the operator's full filesystem, at that session's
next stop. The hook also runs `git` on a checkout the session controls, where
repository configuration such as `core.fsmonitor` or a clean filter runs commands,
and session state under `.nogging/state/` is the session's to rewrite. An operator's
own runs of `scripts/nogg`, and the sync timer's, already run that same file
unsandboxed, so the weakness is not new, but the hook makes it immediate and under
the session's control. Refusing `--dangerously-bypass-hook-trust` does not close
this. Until the hook runs nothing a sandboxed session can write, install it only
where you accept that. `status` and `doctor` repeat this warning while it is
installed. Without it, Codex Leads run normally and only the stop guard is off.

Codex keys a hook by its position in the file, so `remove` leaves an empty group
in place of an entry that another hook follows. Splicing it out would renumber
that hook and silently untrust it.

### Runtime state grants

Runtime state grants are configured with `agent_state_roots` in
`.nogging/config.json`. Declaration does not grant access: a Bead label
`agent-state:antigravity` or launch option `--agent-state antigravity` selects
Antigravity state for a related session. Codex receives those existing
HOME-contained directories as sandbox writable roots. Records and listings
show the source and paths. Treat granting credential-bearing state as write
access to those credentials. See [Codex runtime state grants](using-with-codex.md).

## Beads data and privacy

Beads keeps every Bead — titles, descriptions, notes, `bd remember` memories,
and the audit event history — in a local Dolt database. When `bd init` wires
up synchronization, it points that database's Dolt sync remote at the
project's own Git remote by default: pushed data lands on the Git remote as
`refs/dolt/data` plus a `__dolt_remote_info__` branch, right next to the source
code. The `owner` field of a Bead records the Git `user.email` configured when
the Bead was created. Nogging does not configure this remote; it is Beads'
default.

On a public repository those refs are public too. Anyone can fetch them and
read every Bead title, description, note and memory, the recorded owner
identities, and the change history in events. Dolt keeps every earlier value
in its history, so editing or deleting a note later does not remove it from
the published refs.

For a public project:

1. **Keep the Beads database in a separate private repository.** Dolt Git
   remotes need an existing branch, so the new repository needs one initial
   commit — but create the repository itself empty and author that commit
   locally: the host's auto-seed option (`gh repo create --add-readme`)
   writes its commit with your account's email address unless email privacy
   is enabled, which is exactly the leak this section warns about. Seed it
   from a scratch directory with a privacy-safe identity:

   ```bash
   gh repo create <name>-beads --private
   cd "$(mktemp -d)"
   git init -b main
   echo "Beads database" > README.md
   git add README.md
   git -c user.name=<your-name> -c user.email=<your-noreply-address> commit -m "Initial commit"
   git push git+ssh://git@<host>/<you>/<name>-beads.git main
   ```

   Also turn on your host's email-privacy setting (on GitHub, block command
   line pushes that expose your email address) so an accidental push cannot
   publish the account address.

   Then repoint Beads and push the existing database to it:

   ```bash
   bd dolt remote remove origin
   bd dolt remote add origin git+ssh://git@<host>/<you>/<name>-beads.git
   bd dolt push
   ```

   `<host>` is your Git host (`github.com` for GitHub). Set the same URL as
   `sync.remote` in `.beads/config.yaml` so a fresh clone rediscovers the
   private remote. With multi-machine mode enabled, every machine must use
   that same private remote.

2. **Set a private-safe identity before creating Beads.** The Git
   `user.email` configured at creation time is what a Bead records as its
   `owner`. Use your host's noreply address form (GitHub's ends in
   `users.noreply.github.com`) rather than a personal address.

3. **Never write personal data into Beads text or memories.** Titles,
   descriptions, notes, and `bd remember` content all become part of the
   synchronized database and its permanent history.

If Beads data has already reached a public repository, move it first: check
the `owner` fields, notes and memories for personal data, replace anything
sensitive, commit, and push to the private remote. Then delete the published
refs from the public repository:

```bash
git push <public-remote> --delete refs/dolt/data refs/heads/__dolt_remote_info__
```

Be honest about the limits of that cleanup: anyone who fetched the refs
earlier still holds a copy, and GitHub removes unreachable objects only in a
later garbage-collection pass, so treat everything that was published as
compromised.

The token-usage sync ([token usage accounting](token-usage.md)) is independent
of Beads and pushes `.nogging/state/token-usage/database` to its own Dolt
remote. Configure that remote inside the database with
`dolt remote add <name> <url>`, or clone it onto a new device with
`dolt clone <url> .nogging/state/token-usage/database`. The same rule applies:
use a private remote that only your machines can read.

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
