# herdr gate spike: results and implementation facts

Spike for TASK-HDR-001 (design Decision 1), run 2026-10-15 on the delivery Pi
(linux-aarch64) with herdr 0.9.5, claude 2.1.300, codex-cli 0.162.1 and agy
1.3.5. Every agent ran inside the real wrapping: a prototype stdlib PTY
recorder as the pane command, then `scripts/session-launch` (with
`NOGG_STARTUP_LOG` and the `NOGG_SESSION_*` env), then the agent, with
`HERDR_AGENT=<claude|codex|agy>` on the recorder.

## Install

- Asset `herdr-linux-aarch64` of release `v0.9.5` was fetched with
  `gh release download v0.9.5 -R herdrdev/herdr -p herdr-linux-aarch64` (no
  curl/wget, no sudo).
- The published SHA-256 is the GitHub release asset digest
  (`gh api repos/herdrdev/herdr/releases/tags/v0.9.5`, field `digest`). It was
  checked with `sha256sum -c` before the first run:
  `17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c`.
- The binary is static and was installed with `install -m 0755` to
  `~/.local/bin/herdr`.

## Gate results

Result: 0 FAIL out of 5. Dependent tasks proceed without a fallback.

### (a) status: PASS

herdr reported `idle`, `working`, `blocked` and `done` for all three agents
under the wrapper. Unseen completions show as `done`; a focus marks them seen
and they then show as `idle`.

| Agent | blocked trigger | Matching rule (`agent explain`) |
| --- | --- | --- |
| Claude | an AskUserQuestion form | `live_blocked_form`; idle comes from `live_prompt_box` |
| Codex | an escalation approval | `osc_title_blocked` (the OSC title passes through the recorder) |
| Antigravity | a run-command approval | `permission_prompt` |

- `HERDR_AGENT` is required. Without it the recorder hides the agent: herdr
  reports `agent: null` and status `unknown`.
- The hint is read from the pane's foreground process (the recorder). Its
  literal name does not appear in `strings` of the binary, but it works.
- Detection manifests are remote-updated (see Auto-update). The spike ran
  with Claude and Codex manifests at `2026.10.11.1` and Antigravity at
  `2026.10.05.1`.

### (b) ANSI in `pane.read`: PASS

- CLI form: `herdr pane read <id> --source visible --format ansi`.
- Socket form: `pane.read` with `{"format":"ansi","strip_ansi":false}`.
- Both keep SGR attributes. Claude's suggested-prompt placeholder is wrapped
  in `ESC[2m` (dim); typed input carries no dim
  (`read/claude/idle-placeholder.ansi`, `read/claude/typed-input.ansi`).
- The Codex placeholder is also dim.
- The text format is LF-joined with trailing blank rows trimmed. The ansi
  format is CRLF-joined, opens each styled run with an `ESC[0m` reset, and
  has no final newline.

### (c) pane-ID stability: PASS

- After a server SIGKILL, a SIGTERM, or `herdr session stop`, and a restart,
  the same `pane_id`, `tab_id`, `workspace_id` and pane `label` come back
  from `session.json`.
- `terminal_id` changes, and the process is always new. Liveness must
  therefore stay process-bound, as Decision 6 says.

### (d) native resume plus restore disable: PASS

Native resume worked for each agent:

| Agent | Command herdr ran | Recall check |
| --- | --- | --- |
| Claude | `claude --resume <id>` | recalled the seeded codeword |
| Codex | `codex resume <id>` | recalled the seeded codeword |
| Antigravity | `agy --conversation <id>` | recalled the seeded codeword |

- Resume needs a stored session reference in the official integration format:
  `pane.report_agent_session` with source `herdr:claude`, `herdr:codex` or
  `herdr:antigravity_cli`.
- herdr answers a report with an unknown source with `ok` but ignores it.
- The resume runs after a crash-restart, and only once a client attaches.
  With restore on, a pane that holds a reference was not even listed before
  that attach (observed once).
- The resumed process starts outside the launch wrapper: in a plain
  `$SHELL`, with no `--settings`, no prompt and no `NOGG_*` env. Claude came
  back in accept-edits mode and Antigravity without plan mode. This confirms
  the least-authority concern of Decision 7.

The disable control is per dedicated session:

- Set `[session] resume_agents_on_restore = false` in a config file.
- Pass that file to the dedicated session's server through `HERDR_CONFIG_PATH`
  in the server environment.
- After restart and attach, the panes came back as plain labelled shells, and
  the stored reference was dropped.
- No per-pane switch exists.

Nogging never reports session references itself. But a herdr integration that
a user installed globally would still fire inside Nogging panes, because the
`HERDR_*` env passes through the wrapper. So the config switch is required.

### (e) PTY recorder log: PASS

- The prototype used stdlib `pty`, `select`, `termios` and `signal`, with a
  tee to `scripts/session-log-writer`.
- For Claude, Codex and Antigravity the TUIs rendered, accepted input, and
  re-rendered on resize. A controller resize from 40x119 to 28x90 or 26x84
  reached the inner PTY through SIGWINCH.
- After exit the log held the complete stream, and exit status 0 passed
  through.

Facts TASK-HDR-004 must implement:

- **Put the writer in its own session.** `pane.close`, and any pane kill,
  sends SIGHUP to the pane process group, then SIGKILL about 0.5 s later. If
  `session-log-writer` shares the recorder's process group, it dies and loses
  its buffered tail. Started with `start_new_session=True`, it gets EOF and
  flushes. This was verified on the close path.
- **Expect lagging logs.** `session-log-writer` is line-buffered
  (`read -r`). Claude and Codex emit few newlines, so their output reaches
  the log only at the next newline or at EOF. tmux `pipe-pane` behaves the
  same today: a live tmux Claude session's log held about 4 KB in 16 lines
  after roughly 30 minutes of work.
- **Guard writes to stdout.** After the pane PTY is gone, writing to stdout
  fails. Python then exits 120 while flushing, so the recorder should guard
  these writes and exit with an explicit status.
- **Expect the writer in `process-info`.** It shows up in
  `foreground_processes` when it shares the recorder's process group.
  `shell_pid` stays the recorder either way.

## Implementation facts

### CLI forms and JSON

- The fixtures under `json/`, `read/` and `help/` are authoritative.
- Server errors are JSON on stderr, exit 1, for example
  `{"error":{"code":"pane_not_found",...}}` or `server_not_running`.
- CLI syntax errors print plain usage, exit 2.
- `pane send-text`, `pane send-keys` and `pane run` print nothing on success
  (exit 0). The socket replies `{"result":{"type":"ok"}}`.
- Socket protocol: one JSON object per line,
  `{"id","method","params"}` in, `{"id","result"}` or `{"id","error"}` out.
  The socket is `<session_dir>/herdr.sock`, mode 0600.
- Pane and tab IDs are opaque (`w1:p9` is followed by `w1:pA`) and never
  reused.

### Creating a pane

- There is no CLI form that starts a pane with a given command.
  - `workspace create`, `tab create` and `pane split` start `$SHELL`.
  - `agent start` runs the agent binary itself, bypassing the wrapper.
- The clean form is socket `layout.apply` with a pane node:
  `{"workspace_id": W, "tab_label": L, "root": {"type": "pane", "command":
  [argv...], "cwd": D, "env": {...}, "label": L}}`. It opens a new tab and
  returns `result.layout.root.pane_id`.
- `layout.apply` needs an existing workspace; otherwise it returns
  `workspace_not_found`. Create the repo workspace once with
  `workspace create --label <slug> --cwd <dir> --no-focus`; its root shell
  pane keeps the workspace alive.
- `env` reaches the command. `label` is set on the pane.
- `pane rename <id> <label>` relabels.
- `pane process-info --pane <id>` returns `shell_pid`, which is the pane root
  process, the launched argv itself. The root is a session leader and a child
  of the herdr server. `foreground_processes` lists the foreground process
  group.

### Dedicated named session

- Address it with `herdr --session <name> <command>`.
- The state directory is `~/.config/herdr/sessions/<name>/`. It holds:
  - `herdr.sock` and `herdr-client.sock`;
  - `session.json` (mode 0664) and `session-snapshots/`;
  - `herdr-server.log` and `herdr-client.log`;
  - `herdr.sock.agent`, a symlink to the SSH agent socket.
- Manage it with `herdr session list --json`, `herdr session stop <name>
  --json` and `herdr session delete <name> --json`.
- Each session has its own server process and state. Config
  (`~/.config/herdr/config.toml`) and detection manifests are shared unless
  `HERDR_CONFIG_PATH` is set in the server env.
- The socket path must stay under 108 bytes (`sun_path`). A long `HOME` makes
  the session unreachable.

### Headless start

- `herdr --session <name> server` runs the server in the foreground. Detach
  it with `setsid`, stdin from `/dev/null` and output discarded, then poll
  `ping` or `api snapshot` until it is ready.
- API calls never auto-start a server: they return `server_not_running`,
  exit 1.
- A second start prints `herdr server is already running`, exit 1.
- The server env is inherited by every pane. Start it with a scrubbed env, or
  the starting session's variables (for example `CLAUDECODE`, `TMUX`, tokens)
  leak into panes.
- The headless size is 120x40. Panes get 119 columns because of the
  scrollbar.

### `pane.close`

- It returns `{"type":"ok"}`.
- It sends SIGHUP, then SIGKILL after about 0.5 s, to the pane's process
  group or session. The whole tree is gone, including children that ignore
  SIGHUP and background jobs.
- The backend therefore needs no own process-group kill.

### When the pane process exits

- The pane is removed at once, and its tab with it.
- A workspace is removed when its last pane closes.
- The exit status appears only in `herdr-server.log` (`pane.exit`).

### Restart persistence

- `session.json` is saved on change. It keeps each `layout.apply` pane's
  `launch_argv` (the full wrapper argv), `cwd`, `label` and any
  `agent_session`.
- It survives a stop, SIGTERM or SIGKILL. Only an empty session is cleared.
- A restart restores each pane as `$SHELL` in its saved cwd. `launch_argv` is
  not re-run, per-pane env is not restored, and `HERDR_ENV`/`HERDR_*_ID` are
  injected.

### send semantics

- `pane send-text <id> <text>` types literal text with no Enter. A newline in
  the text becomes a newline inside Claude's input; it does not submit.
- `pane send-keys <id> enter` submits.
- For Claude a single Enter submitted a two-line message. Nogging's second
  Enter landed on the busy, empty prompt and did nothing, so the
  double-Enter policy is safe as is.
- `pane run` sends text plus Enter.

### Read-only attach

- No interactive read-only client exists.
  - `herdr --session <s>` (full UI), `herdr agent attach <target>` and
    `herdr terminal attach <terminal_id>` are all writable.
  - `--takeover` steals input ownership.
- `herdr terminal session observe <pane> [--cols N --rows N]` is read-only. It
  streams NDJSON `terminal.frame` records with base64 ANSI bytes (see
  `json/terminal-observe.ndjson`).
- `terminal session control` is the writable counterpart. A controller resize
  stays in effect after release.

### Auto-update

- The binary never updates itself. The background `[update] version_check`
  only logs `update.check.start` and notifies.
- `herdr update` is explicit. Per the v0.9.5 docs it keeps
  endpoint-generation-1 servers and their panes running. Only a server
  restart, or the one-time pre-generation-1 upgrade, ends the pane
  processes.
- Agent detection manifests do auto-update from herdr.dev into
  `~/.local/state/herdr/agent-detection/remote/` (`[update] manifest_check`,
  default true). This changes status detection without a binary change.

### Pane screen history

- It is off by default (`[experimental] pane_history = false`).
- No `session-history.json` was written.

### Integrations

These were installed into a throwaway `HOME`; install and status run
client-side against `$HOME`. Each one only reports session identity through
`pane.report_agent_session`; none reports state.

| Integration | Files written | Config change | Version and source |
| --- | --- | --- | --- |
| claude | `~/.claude/hooks/herdr-agent-state.sh` | `SessionStart` hook in `~/.claude/settings.json`, matcher `^(startup\|resume\|clear\|compact\|fork)$` | v11, `herdr:claude` |
| codex | `~/.codex/herdr-agent-state.sh` | `SessionStart` hook in `~/.codex/hooks.json`; `[features] hooks = true` in `~/.codex/config.toml` | source `herdr:codex` |
| antigravity-cli | `~/.gemini/config/hooks/herdr-agent-state.sh` | a `herdr` `PreInvocation` block in `~/.gemini/config/hooks.json` | source `herdr:antigravity_cli` |

### Env inside a pane

- herdr adds `HERDR_ENV=1` and `HERDR_PANE_ID`, `HERDR_TAB_ID`,
  `HERDR_WORKSPACE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH` and
  `HERDR_BIN_PATH`. `HERDR_CONFIG_PATH` is inherited when set.
- These pass through the wrapper to the agent, so the agent can drive the
  herdr API of its own session. This matches the posture of the same-user
  tmux socket.
