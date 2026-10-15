# Using Nogging with herdr (Experimental)

Nogging supports **herdr** (`https://herdr.dev/`) as a second, switchable
session backend for supervised agent sessions alongside tmux. The herdr
backend is **experimental** in this release; **tmux remains the default and
permanent fallback**.

The Orchestration Agent always runs on tmux, regardless of the configured
session backend (`orchestrator run` pins to tmux and refuses `--backend herdr`).

The verified upstream version range is **herdr 0.9.x** (validated with
**v0.9.5** on `linux-aarch64` and `linux-x86_64`).

---

## User-level installation and verification

Herdr must be installed at the user level without root or `sudo`. To comply
with the Nogging command floor (which rejects `curl` and `wget`), download the
release asset with GitHub CLI (`gh`):

```bash
# Download the v0.9.5 release binary for your architecture
gh release download v0.9.5 -R herdrdev/herdr -p herdr-linux-aarch64
# (or herdr-linux-x86_64 on x86_64 hosts)
```

Verify the release asset against the published SHA-256 digest before first run:

```bash
# Example verification for v0.9.5 herdr-linux-aarch64:
echo "17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c  herdr-linux-aarch64" | sha256sum -c -
```

Install the static binary into `~/.local/bin` (or another directory on `PATH`):

```bash
install -m 0755 herdr-linux-aarch64 ~/.local/bin/herdr
```

Verify the installation:

```bash
herdr --version
./scripts/nogg doctor
```

`./scripts/nogg doctor` checks for the herdr binary and reports version and
reachability when herdr is in use.

---

## Backend selection

You can select the session backend per session or globally for the repository:

1. **Per-launch override**: pass `--backend {tmux|herdr}` to `session launch`:
   ```bash
   ./scripts/nogg session launch --backend herdr --role lead --bead SPEC-xxx
   ```
2. **Repository default**: set `"session_backend": "herdr"` in `.nogging/config.json`.
3. **Default fallback**: when neither the `--backend` flag nor the
   `session_backend` configuration key is specified, Nogging uses `tmux`.

Precedence is:
`--backend` flag > `.nogging/config.json` `session_backend` key > default `tmux`.

### Refusal before side effects
If an invalid backend is passed, or if `herdr` is selected but the `herdr`
binary or backend module is unavailable, launch is refused immediately
**before** any worktree allocation, trust entry, usage reservation, metadata
record, log, or backend session side effect.

### Mixed-backend coexistence
Sessions running on tmux and herdr can run concurrently. Every lifecycle
command (`session list`, `attach`, `stop`, `cleanup`, `send`, `nudge`,
`kickoff`, `watch`, `reap`) resolves the backend directly from the session's
metadata record under `.nogging/state/sessions/`, never from the currently
active repository configuration. Changing `session_backend` in
`.nogging/config.json` never strands an active session.

---

## Dedicated herdr session, server and log recorder

### Dedicated herdr session
Each Nogging supervised session runs in its own pane, labelled with the session
name, inside a dedicated local herdr session namespace:
`session_herdr_session` (default `nogging`), analogous to `tmux -L nogging`.

Nogging starts and owns a dedicated headless herdr server on demand:
- **Dedicated config:** Nogging supplies its own server configuration via
  `HERDR_CONFIG_PATH`. The configuration disables native agent restore
  (`[session] resume_agents_on_restore = false`) and disables background
  updates (`[update] version_check = false` and `manifest_check = false`).
- **Scrubbed environment:** The server starts with a scrubbed environment so
  that inherited parent variables (such as `CLAUDECODE`, `TMUX`, and API tokens)
  do not leak into agent panes.
- **Socket length constraint:** Herdr uses a local Unix domain socket
  (`herdr.sock`). The socket path must not exceed 108 bytes (`sun_path`);
  Nogging verifies this and refuses startup if the path cannot fit.
- **Agent detection:** Panes run with `HERDR_AGENT=<agent>` so that herdr's
  detection manifest correctly identifies the agent process through the wrapper.

### Transport and pane creation
Nogging reaches herdr through the local `herdr` CLI for every lifecycle and
steering operation except pane creation. Because herdr 0.9.5 has no CLI form that
starts a pane with a given argv, pane creation connects to the dedicated Nogging
server's local Unix socket and issues a `layout.apply` call with a pane node.
Before connecting, Nogging verifies that the socket file is owned by the
invoking user, has mode `0600`, is not a symlink, and its path is under 108
bytes. The transport is strictly a local `AF_UNIX` connection: no TCP listeners,
no `--remote`/`--machine` endpoints, and no remote access.

### The PTY log recorder
Because herdr does not have an exact equivalent of tmux `pipe-pane`, the herdr
backend captures console output through `scripts/session-pty-recorder`:
- Written using only Python standard library modules (`pty`, `select`,
  `termios`, `signal`) with no third-party dependencies.
- Allocates an inner PTY, handles raw-mode forwarding, initial window size, and
  `SIGWINCH` resize events.
- Tees output to `scripts/session-log-writer`, which runs in its own process
  group / session (`start_new_session=True`). This ensures that pane-close
  `SIGHUP` and subsequent `SIGKILL` cannot terminate the log writer before it
  flushes its buffered tail.
- Passes the child process's exit status through cleanly.
- If log capture fails, the agent process continues running.
- Implements a side-effect-free `--contract` query for preflight negotiation.

---

## Liveness, updates, and restart semantics

### Process-bound liveness
A herdr session record is considered alive **only** when both conditions hold:
1. Its pane resolves (by recorded `pane_id` or unique pane `label`).
2. The pane's root process matches the recorded `session_pid` and
   `session_pid_start` time.

If the herdr CLI tool fails or is temporarily unavailable, Nogging marks the
session's liveness as `unknown`. `session reap` and `cleanup` leave unknown
records untouched; a tool failure is never treated as proof that a session died.

### Effects of update and server restart
- **Plain `herdr update`:** On herdr v0.9.5, running plain `herdr update` keeps
  endpoint-generation-1 servers and their active panes running.
- **Server restart:** A herdr server restart ends every Nogging herdr session.
  When the herdr server restarts, any restored pane receives a new process with
  a new PID. Because Nogging liveness is process-bound, `session list` and
  `session reap` reconcile those records to `failed`.
- The one-time upgrade from before endpoint generation 1 is the exception that
  ends running panes.

---

## Disabled auto-restore and exact resume

Herdr includes a native session restore feature that restarts agents upon
server restart. However, native restore re-runs the agent in a bare shell
without Nogging's launch wrapper, effective settings, command floor, or OpenSpec
boundary guards—violating least-authority principles.

To preserve security and isolation:
1. Nogging sets `resume_agents_on_restore = false` in the dedicated server
   configuration passed via `HERDR_CONFIG_PATH`.
2. Any restored pane with a Nogging label that is not owned by an active record
   is reported by `session list` and closed by `session cleanup`; it is never
   adopted.
3. Resuming work is performed strictly through Nogging's exact resume:
   ```bash
   ./scripts/nogg session launch --resume <session-id>
   ```

---

## Nudge and send verification

The session steering policy (`session nudge` and `session send`) remains
backend-neutral:
- **With ANSI capture attributes:** When herdr's `pane.read` provides SGR
  attributes, dim placeholder detection operates identically to tmux.
- **Without ANSI capture attributes:**
  - A Claude prompt box holding text is classified as `unknown` (never assumed to
    be input or placeholder).
  - A nudge without `--message` submits nothing and prompts the operator to
    supply `--message`.
  - A `--message` nudge or `send --verify` uses a **replacement check**:
    the submission is verified if either herdr reports the agent `working` after
    submit, or the identifiable prompt box no longer holds the sent text. If
    unverified, the submit step is retried once before failing.

---

## Attach and read-only behaviour

`session attach <name>` attaches the client to the dedicated herdr session,
focused on the session pane:

```bash
./scripts/nogg session attach <name>
```

Herdr does not currently provide an interactive read-only client. Therefore:
- `session attach <name> --read-only` on a herdr session is **refused**.
- The refusal directs the operator to use `session log --follow <name>` instead.
- Nogging never silently attaches read-write when read-only was requested.

---

## Live agent status (`AGENT_STATUS`)

`session list` includes an `AGENT_STATUS` column:
- For live herdr sessions, this column displays herdr's reported status:
  `idle`, `working`, `blocked`, `done`, or `unknown`.
- For tmux sessions, terminal records, or unsupported backends, the column
  displays `-`.
- The status query is read-only, fast, and bounded; query failures fall back to
  `unknown` without breaking the listing.

---

## Security posture

The herdr backend adheres to the same security model as tmux:
- **Local Unix socket:** The herdr server listens exclusively on a local Unix
  domain socket (`0600` permissions) owned by the current non-privileged user.
- **No network listeners or plugins:** Nogging never enables herdr remote
  access, web interfaces, or third-party plugins.
- **No global integrations installed by Nogging:** Nogging does not install
  global herdr agent integration hooks. (If installed globally by an operator,
  they place hooks in `~/.claude/hooks/herdr-agent-state.sh`,
  `~/.codex/herdr-agent-state.sh`, or `~/.gemini/config/hooks/herdr-agent-state.sh`).
- **Pane screen history disabled:** The herdr server config keeps
  `pane_history = false` to prevent terminal streams (which may contain
  secrets) from being persisted to unrotated history files.
- **Launch wrapper and floor:** The Nogging launch wrapper, command floor,
  OpenSpec boundary fence, and authority profiles apply identically regardless
  of whether tmux or herdr is the backend.

---

## Fallback to tmux and orchestrator pin

- **tmux as fallback:** If herdr is unavailable or encounters an issue, switch
  back to tmux by passing `--backend tmux` or setting `"session_backend": "tmux"`
  in `.nogging/config.json`.
- **Orchestration Agent pin:** The Orchestration Agent always runs on tmux
  (`nogg-orchestrator-<slug>`), even when `session_backend` is set to `herdr`.
  `orchestrator run` refuses to launch on herdr.

See also:
- [Operating model](operating-model.md)
- [Architecture](architecture.md)
- [Security and threat model](security-model.md)
- [Failure recovery](failure-recovery.md)
- [Compatibility policy and matrix](compatibility.md)
