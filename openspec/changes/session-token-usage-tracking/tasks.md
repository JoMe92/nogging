## 1. Durable identities and runtime adapters

- [x] TASK-TUC-001 Add canonical sibling Dolt store, versioned facts/views and replay-safe identities; verify transactions, worktree sharing, copied-source dedup and schema refusal. See design 1–3 and token-store-sync storage requirement.
- [x] TASK-TUC-002 Add Claude/Codex adapters and durable ingestion/checkpoints; verify repeated/revised messages, overlapping summaries, cache semantics, partial lines and rotation. Depends on TASK-TUC-001; see design 2–3 and token-accounting normalization/recovery requirements.
- [ ] TASK-TUC-003 Verify exact supervised Antigravity usage/model retrieval and implement its adapter; verify nonzero counts, resume boundaries and command/quota separation, or file a blocking discovery. Depends on TASK-TUC-001; see design context/3 and token-accounting normalization requirement.

## 2. Supervision and reports

- [ ] TASK-TUC-004 Integrate host collection, complexity snapshots, runtime segments and pending-evidence cleanup; verify restricted authority, crashes, resumes, task/model transitions and tier disagreement refusal. Depends on TASK-TUC-002 and TASK-TUC-003; see design 4–5 and token-accounting requirements.
- [ ] TASK-TUC-005 Add token-usage collect/report/session/export/status JSON CLI; verify UTC half-open hour/day/session windows, all filters, coarse sources, unknown coverage and duration clipping. Depends on TASK-TUC-004; see design 6 and token-reporting requirements.

## 3. Multi-device delivery

- [ ] TASK-TUC-006 Add explicit independent usage sync with bounded retries and conflict diagnostics; verify two offline clones, both sync orders, replay, rejected pushes, outages and schema/identity conflicts. Depends on TASK-TUC-001; see design 7 and token-store-sync requirements.
- [ ] TASK-TUC-007 Ship helpers/docs through packed install/update/remove with owner-only lazy state; verify CLI payload, user-data/hook preservation and recovery/export guidance. Depends on TASK-TUC-005 and TASK-TUC-006; see design migration and token-store-sync storage requirement.
- [ ] TASK-TUC-008 Run full isolated scripts/test and packed/live acceptance; record nonzero usage for all three runtimes, model/task/complexity queries, Pi timing measurements and two-device convergence in unsigned evidence. Depends on TASK-TUC-007; see all delta scenarios and design risks.
