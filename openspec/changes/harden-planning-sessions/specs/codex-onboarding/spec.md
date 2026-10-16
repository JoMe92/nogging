## MODIFIED Requirements

### Requirement: A Codex session in a worktree can reach the shared checkout's .git and .beads

`session launch --agent codex` SHALL pass `--add-dir` naming the shared
checkout root alongside `--cd` naming the session's working directory, at
every authority level. A Codex session running from an implementation or
planning worktree (whose `.git` is a pointer file into the shared checkout's
object store, and whose Beads Dolt database lives under the shared checkout's
`.beads/`) SHALL be able to run `git commit`, `git push` (where its authority
level's network setting allows it), and `bd`/`scripts/nogg` commands that
read or write Beads, without a `workspace-write` sandbox filesystem-boundary
failure. Where Beads uses a Dolt server reached over TCP, as the shared server
does, those `bd` commands need the network: a restricted Codex session
(`network_access = false`) cannot reach the server, even on loopback. The
Codex guide SHALL state this limit and its remedy (`--profile trusted`, or an
operator-run `bd` step), and SHALL NOT present `bd` as working at the
restricted level with a shared Dolt server.

#### Scenario: A restricted Codex worktree session can commit and read Beads

- **WHEN** a Codex session is launched at the default (`restricted`) level
  with its working directory set to an implementation or planning worktree
- **THEN** the launch includes `--add-dir` naming the shared checkout root
- **AND** `git commit` succeeds from inside the worktree
- **AND** `scripts/nogg discoveries` succeeds where Beads needs no
  network-reached Dolt server

#### Scenario: A restricted Codex session and the shared Dolt server

- **WHEN** a restricted Codex session runs a `bd` command while Beads uses the shared Dolt server
- **THEN** the command fails as unreachable, and the Codex guide names this limit and the remedy

#### Scenario: A trusted Codex worktree session can push

- **WHEN** a Codex session is launched with `--full-access` (`trusted`) with
  its working directory set to an implementation worktree
- **THEN** the launch includes both `--add-dir` naming the shared checkout
  root and `sandbox_workspace_write.network_access=true`
- **AND** `git push` succeeds from inside the worktree
