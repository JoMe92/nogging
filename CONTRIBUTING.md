# Contributing to Nogging

Nogging is developed through OpenSpec intent, Beads execution tasks, and Git
evidence. Contributions should preserve that separation.

## Before you start

For bugs and small improvements, open an issue using the appropriate template.
For behavior, architecture, or scope changes, discuss the outcome before
implementation so it can be planned in OpenSpec. Security vulnerabilities must
follow [SECURITY.md](SECURITY.md), not the public issue tracker.

## Development workflow

1. Fork or branch from `develop` using a supported conventional branch name.
2. Associate implementation with a claimed Bead; do not edit `openspec/` from
   an execution session.
3. Keep commits focused and use Conventional Commits with the Bead ID, for
   example `fix(sync): preserve evidence ordering [SPEC-abc1]`.
4. Run `scripts/test` and any focused checks relevant to the change.
5. Open a pull request targeting `develop` and complete the template.

See [the operating model](docs/operating-model.md) and
[worktree workflow](docs/worktree-workflow.md) for the repository's execution
rules.

## Community expectations

Participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By
contributing, you agree that your contribution may be distributed under the
repository's [ISC license](LICENSE).
