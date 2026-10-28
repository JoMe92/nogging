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
3. Commit a Bead in coherent steps within the configured commit range
   (`./scripts/nogg task-sizing` prints it), each a Conventional Commit with
   the Bead ID that holds the tests for the code it changes, for example
   `fix(sync): preserve evidence ordering [SPEC-abc1]`.
4. Test in stages: the affected tests while working, the affected suite plus
   lint of the changed files before each commit, and `scripts/test` (the
   full suite) once per Bead before hand-off. CI stays the final gate.
5. Open a pull request targeting `develop` and complete the template.

See [the operating model](docs/operating-model.md) and
[worktree workflow](docs/worktree-workflow.md) for the repository's execution
rules. Maintainers cutting a release follow
[docs/releasing.md](docs/releasing.md).

## Community expectations

Participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By
contributing, you agree that your contribution may be distributed under the
repository's [ISC license](LICENSE).

## Tests and CI

```bash
scripts/test   # runs every scripts/**/*.test.sh; also `npm test`
```

The runner is language-neutral and offline: bash and coreutils only, no Node,
no network, and no running Beads/Dolt server (tests that need `bd` stub it). It
covers the `commit-msg` boundary hook — Beads ID accepted, missing ID rejected,
and the `planning`/`sync` `NOGGING_WRITER` exemptions. In a repository
Nogging was installed into, the same runner skips Nogging's shipped self-tests
unless `NOGG_SELFTEST=1` is set; here, with no installed manifest, every test
runs.

[Nogging validation](.github/workflows/nogging-validate.yml) runs this suite,
plus the following, on every push and pull request:

| Job | Checks |
| --- | --- |
| `compatibility` | The tool-version matrix from [docs/compatibility.md](docs/compatibility.md) |
| `script-tests` | `scripts/test` — every `scripts/**/*.test.sh` |
| `installer` | `nogg init` / `update` against a scratch repository |
| `validate` | strict, non-interactive OpenSpec validation of the committed changes (`openspec validate <change> --strict --no-interactive`) |
| `acceptance` | The mechanical subset of [docs/acceptance.md](docs/acceptance.md) |
| `invariants` | The `openspec/` write boundary and archived-change consistency |
| `public-release-gates` | Release-readiness checks from [docs/releasing.md](docs/releasing.md) |
| `dependency-review` | `npm audit`-based dependency scanning |

The badge at the top of this file tracks the `main` branch.
