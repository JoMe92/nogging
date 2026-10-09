# Bead mapping isolation — scoped execution evidence — 2026-10-09

This unsigned report covers `isolate-bead-mapping-failures`, TASK-BMF-005
(`SPEC-ygmv`), issue #49. It records scoped implementation and regression
checks, without human acceptance or a release sign-off.

| Field | Value |
| --- | --- |
| Executor | Nogging Lead |
| Implementation baseline | `d4d7611` |
| Implementation commits | `1b55a43`, `0ef1334`, `92a3e38`, `d4d7611` |
| Platform | Linux aarch64, Node 22.23.2 |
| Tracker evidence | Native installed Beads list/show/dependency schemas inspected read-only; fixture mutations use a stub tracker |
| Git evidence | Real scratch repositories, mirror commits and idempotency checks |

Classification distinguishes approved mapped tasks, explicit non-task follow-ups
and plain unmapped Beads. Repeated or conflicting inherited labels,
follow-up-plus-task labels, incomplete pairs and unreadable label containers
produce typed diagnostics with Bead IDs, task IDs and identifiable change
scope. Production code never repairs labels or deletes Beads automatically.
Task-only mappings can be scoped through a unique approved task owner.
Conflicting ownership quarantines every identifiable affected change. Duplicate
global task definitions, ambiguous Bead identities and unresolvable ownership
refuse every reconciliation write.

The two-change integration fixture uses real Git and a stateful stub tracker.
Malformed change `alpha` refuses materialization. Valid `beta` materializes
only its missing task, recognizes existing closed mappings and remains
idempotent. After the fixture independently closes beta's newly materialized
work, sync mirrors both beta tasks and records their closure events while
leaving alpha's checkbox and execution log untouched. Beta is archive-ready
while alpha remains quarantined. Strict audit still reports alpha's defect.
A repeated partial pass makes no new mirror commit. Explicitly repairing the
fixture association as a non-task follow-up lets alpha reconcile without an
invented checkbox, extra mapped Bead or follow-up execution-log entry.

Completion and sweep use approved task definitions and explicit transitive
`blocks` edges from the closed-inclusive tracker snapshot. Unlinked open or
blocked follow-ups do not prevent completion. Linked unresolved follow-ups or
prerequisites in other local changes do prevent it, including blockers beneath closed
prerequisites. Missing mappings, duplicate identities, malformed or unavailable
dependency state cannot establish completion. Existing merged/open PR
classification behavior is preserved.

A degraded pass exits `3` and atomically persists per-change failures separately
from the last complete-success timestamp. Doctor names both pass timestamps,
active Bead IDs/reasons and first/last-seen ages. Repairing one scope preserves
another unresolved scope and its first-seen time. A complete repair clears
active failures while preserving historical partial-pass IDs and reasons.
Interrupted replacement preserves previous bytes and cleans temporary files;
unreadable durable health refuses new mirror writes. Partial passes create no
repository-wide retry record.

| Validation | Result / reproduction |
| --- | --- |
| Mapping classification | pass — `bash scripts/bead-mapping.test.sh` |
| Two-change tracker/Git integration | pass — `bash scripts/scoped-mapping.test.sh` |
| Completion/dependency/archive/sweep semantics | pass — `bash scripts/followup-completion.test.sh` |
| Durable partial health and repair | pass — `bash scripts/sync-health.test.sh` |
| Existing bridge and observability regressions | pass — previous task runs of `scripts/nogg.test.sh` and `scripts/session-observability.test.sh`; included again in complete suite |
| Strict scoped OpenSpec validation | pass — `openspec validate isolate-bead-mapping-failures --strict` |
| Complete source and installed-consumer suite | pass — `bash scripts/test`: all script tests passed |

The complete-suite log is `/tmp/nogging-ygmv-tests.log`; the strengthened
integration log is `/tmp/nogging-ygmv-scoped.log`. Host-local logs are diagnostic
artifacts. Checked-in tests and the scenario description above provide the
durable reproduction path. Manual repair and sanctioned follow-up creation are
documented in `docs/failure-recovery.md`, preserving change association,
closure evidence, discovery notes and dependency edges.

The separate discovery about the older session-startup dependency helper is
retained on `SPEC-x830` for planning review; this report does not claim that
helper's failure/type semantics were changed by the completion work. A separate
read-only probe found that Pi's path classifier needs all registered checkout
roots for absolute writes into another linked worktree; recorded on `SPEC-ygmv`
for the upcoming supervised-planning execution-fence work. Mapping isolation
acceptance does not claim that cross-worktree guard case is fixed.

Signed-off-by:
