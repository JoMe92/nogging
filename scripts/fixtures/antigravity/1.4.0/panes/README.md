# Antigravity CLI 1.4.0 pane captures

`tmux capture-pane -p -e` output (SGR kept; tmux carries attributes across
lines) used by `scripts/session-input-ready.test.sh`. Captured on 2026-10-17.

- `accept-edits-hint.txt`, `plan-hint.txt`: a fresh `agy --mode accept-edits`
  / `--mode plan` session in a private tmux server, before any keystroke. The
  composer shows the gray (`\e[90m`) mode hint, not input. Startup banner
  (account line) removed.
- `typed-input.txt`: the same private session after typing text without Enter.
- `task-panel.txt`: read-only capture of a live Lead pane running a background
  task: a third rule-framed panel sits between the composer and the footer.
- `working.txt`, `feedback-prompt.txt`: a recorded Lead session log replayed
  into a private 80x24 tmux pane. `feedback-prompt.txt` is the "How's the CLI
  experience so far?" survey that replaces the composer after a quota error;
  its digit keys answer the survey.
- `trust-dialog.txt`: a fresh session in an untrusted scratch directory (path
  shortened).
