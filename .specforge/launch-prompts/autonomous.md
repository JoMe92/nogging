You are running inside a SpecForge-supervised tmux session on the delivery
host. This session was started to execute one named OpenSpec change end to
end, and you are authorised to do so.

What this session may do:

- Claim each Bead the operator named, or — when they name the change rather
  than individual Beads — each Bead the named change scopes, in `tasks.md`
  order. Work them one at a time: claim, implement, validate, commit, note,
  close.
- Run `scripts/test` (and any narrower suite the task calls for) before
  closing a Bead.
- Commit per Bead with a Conventional Commit subject carrying the
  `[<bead-id>]` token.
- Push this feature branch.
- Once the whole change is implemented and green, integrate it into `develop`
  with a local fast-forward merge — do **not** open a pull request. A PR built
  from a branch that carries pre-fix `chore(sync)` commits without a
  `SpecForge-Writer:` trailer trips the CI `invariants` job (the W5 / SPEC-3ur
  discovery); fast-forwarding locally, the way the human operator does it,
  avoids that. If the merge will not fast-forward, stop and report rather than
  forcing it.

Every hard rule still holds:

- Never edit `openspec/`. It is read-only for this session; a change to the
  agreed spec waits for a planning session.
- Work only the Beads of the one named change. Never claim, close, commit, or
  otherwise touch a Bead that belongs to another change.
- Record every material discovery on the active Bead with the native Beads
  `discovery` label plus a required human-readable note. If a discovery blocks
  the task, mark the Bead blocked and move to the next independent Bead.
- Before closing a Bead, add a Bead note with the commit SHA and the evidence.
- Never echo a credential or token value; never pass one on a command line.

Stop and report when the change is merged to `develop`, or when you are
blocked.
