<!-- nogging:instructions lean -->
## Nogging agent instructions

Read the active Bead before work. This is the lean block, installed because
`ceremony.mode` in `.nogging/config.json` is not `always-full`: it holds the
hard rules and the roles. Everything else lives in the skills listed at the
end, read when the situation calls for one. The block is tool-neutral;
`docs/nogging/operating-model.md` has the whole model.

### Hard rules

1. Execution agents (Main Worker and specialists) must not edit `openspec/`.
2. Work only on a Bead that has been claimed by the Main Worker.
3. Commit a Bead in several coherent steps, not as one commit at the end. Each
   commit stays within the configured commit range (`task_sizing.commit_lines`
   in `.nogging/config.json`; `./scripts/nogg task-sizing` prints it), is a
   Conventional Commit containing the Bead ID (e.g. `[SPEC-abc]`), and holds
   the tests for the code it changes. Test in stages, following the
   test policy (`docs/nogging/testing-policy.md`): `./scripts/nogg test changed` while
   working, `./scripts/nogg test commit` before each commit, and
   `./scripts/nogg test bead` once per Bead, before closing it. The full
   suite is CI's job: `./scripts/nogg test full` is only for a release, the
   nightly run or an explicit recorded reason. Weakening a test — deleting
   it, adding a skip, dropping assertions — takes a `Test-Integrity:
   <reason>` commit trailer and a discovery note on the Bead. Run a long
   command (a suite, a build) as one blocking call with a timeout long enough
   for it to finish — `./scripts/nogg run-quiet -- <command>` prints one line
   on success and only the tail on failure — and never poll a running command.
   Then close the Bead (`bd close <id>`) and immediately run
   `./scripts/nogg task-done <id>` to tick its mapped `tasks.md` line (it
   refuses unless the Bead is already closed), bundling that tick into the
   Bead's last commit, and add a Bead note listing every commit SHA and the
   evidence.
4. Record every material discovery on the active Bead with the native Beads
   `discovery` label plus a required human-readable note — never as serialized
   data, and never by editing `openspec/`
   (`bd update <id> --add-label discovery --append-notes "<prose>"`). A
   blocking discovery also sets the Bead status to `blocked`; the next
   planning session lists them with `bd list --label discovery`.
5. Leave an intent breadcrumb. Before an expensive or hard-to-reverse step, and
   before ending a turn with a Bead still `in_progress`, append a one-line
   `progress: <next step>` to the Bead note
   (`bd update <id> --append-notes "progress: …"`). On resume, in any tool, it
   is the primary "where was I" signal.
6. End every supervised run with a signal: a pushed pull request and
   `./scripts/nogg session signal done "PR #<n> open"`, or
   `./scripts/nogg session signal blocked "<why>"`. A Bead note alone is not a
   signal, because nobody reads it. A refused step means signal blocked at
   once: never route around a refusal by switching runtime or retrying.
7. On every session start — fresh, resumed or after a tool switch — run
   `./scripts/nogg recover` before selecting work with `bd ready`, and resolve
   what it reports first. Never re-implement committed work, and leave a Bead
   marked `owned by session <name>` alone.

### The write boundary

`openspec/` is read-only for every execution agent and writable only during a
planning session holding the canonical `.nogging/locks/planning.lock` in the
main checkout (`./scripts/nogg plan-begin` … `plan-end`). A held planning lock
never makes `openspec/` writable for an execution role. The lock toggles a
`.nogging/locks/openspec.readonly` sentinel that the write guard consults.

### Roles

- **Product Owner** — the human: decides intent, approves plans and signs
  acceptance reports.
- **Orchestration Agent** — always-on and orchestrate-only by default: drives
  Planning and Lead sessions through `scripts/nogg`, writes no `openspec/`
  file and no code outside an explicit `/orchestrate takeover`.
- **Planning Agent** — writes `openspec/` and materializes Beads, only in its
  own planning worktree and under the planning lock.
- **Main Worker (Lead Agent)** — claims one Bead, implements, tests, commits
  and closes it, and writes the evidence note.
- **Specialists** — work exactly one already-claimed Bead on delegation; they
  never claim, close, re-status or commit, and never write `openspec/`.

### Skills

Each skill is one file, installed twice with the same content: under
`.claude/skills/` (Claude Code loads it by itself) and under `.agents/skills/`
(Codex and other runtimes that load skills from there). An agent that does not
load skills by itself, such as Pi, reads the file by the path below when the
situation in the right column arises.

| Skill | Path | Read it when |
| --- | --- | --- |
| Lead workflow | `.agents/skills/nogging-lead-workflow/SKILL.md` (also `.claude/skills/nogging-lead-workflow/SKILL.md`) | you claim, implement, test, commit or close a Bead |
| Planning | `.agents/skills/nogging-planning/SKILL.md` (also `.claude/skills/nogging-planning/SKILL.md`) | you run a planning session, pick a lane, or write or size tasks |
| Sessions and orchestration | `.agents/skills/nogging-sessions/SKILL.md` (also `.claude/skills/nogging-sessions/SKILL.md`) | you run inside or drive a supervised session, act as the Orchestration Agent, use multi-machine mode, or need the notes for your runtime |
| Specialists | `.agents/skills/nogging-specialists/SKILL.md` (also `.claude/skills/nogging-specialists/SKILL.md`) | you delegate work to a specialist or run as one |
| Recovery | `.agents/skills/nogging-recovery/SKILL.md` (also `.claude/skills/nogging-recovery/SKILL.md`) | a session starts, `recover` reports something, or a run was interrupted |

A mode change in `.nogging/config.json` takes effect at the next update.
Update Nogging itself with `npx github:JoMe92/nogging update`.
