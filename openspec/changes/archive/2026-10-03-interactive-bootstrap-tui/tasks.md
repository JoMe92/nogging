# Tasks — interactive bootstrap wizard

- [ ] TASK-IBT-001 Add TTY/flag detection to `scripts/bootstrap`:
      `[ -t 0 ] && [ -t 1 ]` plus a new `--non-interactive` flag (forces the
      existing flow regardless of TTY) and an implicit `--interactive` when
      the check passes. No behavior change when the result is
      non-interactive — confirm byte-for-byte identical output to the
      pre-change script for every existing flag combination.

- [ ] TASK-IBT-002 Add `whiptail` availability: check first, `apt-get
      install -y whiptail` only if missing (same pattern as the existing
      git/tmux/gh step); on failure, print a NOTE and fall back to
      non-interactive — never a hard failure over this step alone.

- [ ] TASK-IBT-003 Build the welcome/confirm screen: an ASCII Nogging
      wordmark + "structure for what's next." tagline, printed with ANSI
      colors approximating `docs/brand/nogging-logo.png` (dark forest green
      wordmark, sage-green accent), followed by a `whiptail --yesno`
      confirming the install target before anything happens.

- [ ] TASK-IBT-004 Build the install-path dialog (`whiptail --inputbox`,
      default: `--repo` if given, else the current directory) and the
      optional-components checklist (`whiptail --checklist`: Pi agent
      support, systemd sync timer, git hooks, Beads init — default
      checked/unchecked state matching today's actual flag defaults
      exactly). Map answers onto the exact flags `scripts/bootstrap`/`init`
      already accept per `design.md`, Decision 3 — no new install logic.

- [ ] TASK-IBT-005 Build the authentication step per `design.md`, Decision
      4's table: `gh auth status`, `codex login status`,
      `~/.claude/.credentials.json` existence — each skipped silently when
      already satisfied, otherwise a `whiptail --yesno` offering to log in
      now, handing the terminal to that tool's own login command on yes.

- [ ] TASK-IBT-006 Build the closing summary dialog (`whiptail --msgbox`)
      naming what was installed, what was skipped, and the next command to
      run.

- [ ] TASK-IBT-007 Factor every dialog's decision logic into plain shell
      functions independent of the `whiptail` calls themselves (per
      `design.md`, Decision 5). Add a test file stubbing `whiptail` on
      `PATH` with canned responses, proving: the non-interactive fallback
      triggers correctly (no TTY, `--non-interactive`, missing whiptail
      with failed install), each checklist/dialog answer maps to the
      correct underlying flag, and an already-authenticated tool shows no
      auth dialog.

- [ ] TASK-IBT-008 Document both invocation shapes in
      `docs/installation.md`: the existing piped one-liner (stays
      non-interactive, unaffected) and the download-then-run form that gets
      the wizard (`curl -fsSL .../bootstrap -o bootstrap && bash
      bootstrap`). Run `scripts/test`. Manually verify the rendered wizard
      end to end on a real TTY (per `docs/releasing.md`'s evidence pattern)
      and record the result.
