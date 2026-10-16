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

### Host-namespace server start and fenced refusal
The dedicated herdr server must run in the host's PID namespace so that its
process tree survives agent teardown and is observable by host-level recovery tools.
To enforce this:
- **Fenced refusal:** When a session runs inside a sandbox or container where
  `NOGG_OPENSPEC_FENCED=1` is set (the marker set by `openspec-sandbox`), Nogging
  **refuses** to spawn a herdr server if it is down. The refusal occurs immediately,
  before any worktree allocation, session record, workspace, or pane side effect.
  The refusal message directs the operator or Orchestration Agent to start the
  server host-side:
  ```bash
  ./scripts/nogg session herdr-server start
  ```
  (or launch the session from an unsandboxed shell).
- **Server receipt:** On startup, Nogging writes `.nogging/state/herdr/<session>/server.json`
  containing `{pid, start, pid_ns, socket: {dev, ino, ctime_ns}}`. `pid_ns` records
  the server's PID namespace, and `socket` records the Unix socket's device, inode,
  and `ctime_ns` from `lstat`.
- **Server ownership verification:** Every caller verifies running server ownership
  before connecting: the config file must match Nogging's immutable config byte-for-byte,
  the socket must be a regular Unix domain socket owned by the current user with mode `0600`,
  and the socket identity must match the receipt. Callers sharing the server's PID
  namespace additionally verify that `pid` matches `start`. Fenced callers treat legacy
  receipts (lacking `pid_ns` or socket metadata) as unverifiable and refuse.

### Idempotent server start command (`session herdr-server start`)
`./scripts/nogg session herdr-server start` provides explicit host-side server management:
- Idempotently verifies an existing owned server or starts a new dedicated headless
  server with Nogging's config, scrubbed environment, and receipt.
- Refuses if invoked from a fenced environment (`NOGG_OPENSPEC_FENCED=1`).
- Refuses if a running server fails ownership checks, naming the failed check and
  advising the operator to stop the unowned server with `herdr --session <ns> server stop`.
  Nogging never stops or kills an unowned herdr server itself.
- Upgrades legacy receipts in place when run host-side.
- Writes no session metadata records and creates no workspaces or panes.

### Transport, pane creation, and root pane cleanup
Nogging reaches herdr through the local `herdr` CLI for every lifecycle and
steering operation except pane creation. Because herdr 0.9.5 has no CLI form that
starts a pane with a given argv, pane creation connects to the dedicated Nogging
server's local Unix socket and issues a `layout.apply` call with a pane node.
Before connecting, Nogging verifies that the socket file is owned by the
invoking user, has mode `0600`, is not a symlink, and its path is under 108
bytes. The transport is strictly a local `AF_UNIX` connection: no TCP listeners,
no `--remote`/`--machine` endpoints, and no remote access.

- **Root pane cleanup:** When Nogging creates a workspace (`workspace create`),
  herdr automatically opens an initial unlabelled root `$SHELL` pane. Nogging records
  this root pane's IDs (`workspace_id`, `pane_id`, `terminal_id`) in `workspace.json`.
  After the next successful `layout.apply` into that workspace, Nogging closes this
  unlabelled root pane via `pane close` after re-verifying its IDs and terminal
  identity. No stray root shell panes remain open.
- **Vanished workspace handling:** Herdr workspaces automatically disappear when
  their last pane exits. If `layout.apply` receives an explicit `workspace_not_found`
  error reply, Nogging recreates the workspace and retries `layout.apply` once.

### Live byte log recorder and writer
Because herdr does not have an exact equivalent of tmux `pipe-pane`, the herdr
backend captures console output through `scripts/session-pty-recorder` piped to
`scripts/session-log-writer`:
- **Inner PTY recorder:** `scripts/session-pty-recorder` is written using Python standard
  library modules (`pty`, `select`, `termios`, `signal`). It allocates an inner PTY,
  handles raw-mode forwarding, initial window geometry, and `SIGWINCH` resize events.
  It runs `scripts/session-log-writer` in its own process group (`start_new_session=True`)
  so pane-close signals do not terminate the writer before flushing.
- **Live byte log writer:** `scripts/session-log-writer` is implemented in standard Python:
  - Reads stdin in binary chunks of up to 64 KiB (`os.read`) and appends them immediately
    through an `O_APPEND` file descriptor without waiting for newlines (LF). This prevents
    the log freezing and unbounded line-buffer growth seen with full-screen TUIs.
  - Strictly bounds each file generation by `max-bytes`: if appending a chunk would exceed
    `max-bytes`, only the remaining room is written, the active file is rotated, and the
    remainder is written to the new generation.
  - Rotates up to `depth` (`<name>.log.1..N`), dropping older generations.
  - Preserves exact bytes, including terminal escape sequences and non-UTF-8 output.
  - On `session cleanup`, Nogging archives all rotated generations (`.1..N`) alongside
    the active log under the same archive timestamp.
  - Implements a side-effect-free `--contract` query; preflight checks negotiate the
    `byte-stream` feature.

---

## Liveness, terminal identity, and server-down recovery

### Terminal identity and cross-namespace liveness
Each session's `backend_ref` records:
- `terminal_id`: the pane's unique terminal ID reported by herdr `pane list`.
- `session_pid`: the pane's root process ID (`shell_pid`).
- `session_pid_ns`: the server's PID namespace, read from the server receipt.
- `session_pid_start`: recorded only when the launching caller shares the server's PID namespace, otherwise `null`.

Liveness is evaluated through `HerdrBackend.live()`:
1. The pane must resolve by recorded ID or unique label.
2. Herdr must report matching `terminal_id` and `shell_pid` for that pane.
3. If the querying caller shares the server's PID namespace and a start time was recorded,
   `/proc/<pid>/stat` start time must also match.

Because herdr assigns a new `terminal_id` whenever a pane or server restarts, this check
is exact and reliable across foreign PID namespaces without reading foreign `/proc` entries
or sending cross-namespace signals.

Termination via `session stop` or `kill()` calls `pane close`, which ends the entire
underlying process tree. Signaling process groups is reserved as a fallback only when
the caller shares the server's PID namespace and has verified the process start time.

### Server-down recovery (definite down)
When the dedicated herdr server is stopped or down, Nogging determines a **definite down**
state if two independent queries agree:
1. `herdr --session <ns> status` exits 0 and reports `server: status: not running`.
2. `herdr session list --json` reports that session with `running: false`.

When definite down is confirmed:
- All session records belonging to that dedicated namespace are reconciled to `vanished`
  (displayed as `failed` in `session list`).
- `session reap` marks them failed and `session cleanup` can retire them.
- New launches (and `--resume`) for the same Bead are not blocked by a false "live lead
  session already covers" check.
- If either check fails, times out, or the two answers disagree, liveness safely stays
  `unknown` (untouched by reap and cleanup).

---

## Disabled auto-restore and checkout-scoped orphans

Herdr includes a native session restore feature that restarts agents upon
server restart. However, native restore re-runs the agent in a bare shell
without Nogging's launch wrapper, effective settings, command floor, or OpenSpec
boundary guards—violating least-authority principles.

To preserve security and isolation:
1. Nogging sets `resume_agents_on_restore = false` in the dedicated server
   configuration passed via `HERDR_CONFIG_PATH`.
2. Resuming work is performed strictly through Nogging's exact resume:
   ```bash
   ./scripts/nogg session launch --resume <session-id>
   ```

### Checkout-scoped orphan panes
Orphan pane detection in `session list` and `session cleanup` is strictly scoped to the
current checkout's records:
- A pane is an orphan only when its label matches a session record belonging to the
  **current checkout** (across all lifecycle states, including `retired`) and no active
  record owns it alive or starting.
- Restored panes or lingering panes matching a retired or failed record of the current checkout
  are closed by `session cleanup`.
- Any `sf-` pane whose label matches no record of the current checkout is classified as
  **foreign** (belonging to another checkout, worktree, or deleted state). Foreign panes
  are **never closed and never adopted**.
- `session list` reports foreign panes in an advisory NOTE with their count:
  `NOTE: <N> foreign herdr pane(s) left untouched`.

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
