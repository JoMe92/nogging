# Product identity decision — Nogging

Date: 2026-09-14

## Decision

The canonical project identity is **Nogging**, with the repository at
`JoMe92/nogging` and the tagline “Structure for what's next.” The command and
package name are `nogg`.

This decision supersedes
[`decision-2026-09-10.md`](decision-2026-09-10.md), which adopted Agentsembli
SpecForge while intentionally preserving the earlier technical identifiers.
That document remains in the repository as historical provenance; it is no
longer the current naming authority.

## Technical identifiers

The running and installed system uses these identifiers:

| Surface | Identifier |
| --- | --- |
| Package and CLI | `nogg` |
| Repository | `JoMe92/nogging` |
| State and configuration | `.nogging/` |
| Entry script | `scripts/nogg` |
| Commit writer trailer | `Nogging-Writer` |
| Writer environment variable | `NOGGING_WRITER` |
| Generated systemd units | `nogg-*` |
| Orchestrator singleton | `nogg-orchestrator-<slug>` |
| Beads issue prefix | `SPEC-` (unchanged) |

The rename does not make the repository public, publish the package to npm, or
claim trademark clearance. Those remain explicit owner decisions.

## Historical OpenSpec wording

Seventeen capability specifications approved before this rename retain literal
references to the former runtime identifiers. This is an accepted documentation
boundary: those specifications remain historical behavioral baselines and are
not mechanically rewritten by this change. The running implementation and all
maintained user, operator, and agent guidance use the identifiers above.

Future planning work that materially changes one of those capabilities may
refresh its terminology as part of the separately reviewed behavior change.
Until then, a legacy identifier in those capability specs is provenance, not a
supported command or installation path.
