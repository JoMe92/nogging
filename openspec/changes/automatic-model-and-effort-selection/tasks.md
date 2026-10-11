## 1. Rule table

- [x] TASK-MES-001 Ship templates/model-selection.json with the design decision 3 table, scaffold it to .nogging/model-selection.json only when absent, and add loader/validator plus nogg models [--agent --tier --json] and models check. Verify the shipped table is valid, invalid tables are refused, the agy alias works, consumer edits survive update, and doc/JSON agree. See design decisions 1–3 and the table requirements.

## 2. Tier-resolved launch

- [ ] TASK-MES-002 Add session launch --tier: resolve after agent resolution with --model over tier over profile over default; forward Codex effort via the wrapper's --reasoning-effort and the Antigravity model; Claude gets the model plus a NOTE about the unapplied effort; refuse Pi/unknown/invalid before side effects; record selection_tier and list tier=. Verify stub argv per agent and tier, plus legacy records. Depends on TASK-MES-001; see design decisions 4–6.

- [ ] TASK-MES-003 Add doctor NOTEs for Codex catalog drift, bounded agy models drift and an installed table older than the packaged one; report unavailable sources honestly and never change the exit status. Verify fixtures for present, absent and unavailable sources. Depends on TASK-MES-002; see design decision 8 and the drift requirement.

## 3. Orchestrator procedure and documentation

- [ ] TASK-MES-004 Require tier classification before every launch in the orchestrator launch prompt, the /orchestrate command and operating-model Orchestration (reason note, escalation, no quota downgrade); write docs/model-selection.md with the table, research and sources; update the architecture/session docs. Verify that the docs match the JSON and the CLI help. Depends on TASK-MES-003; see design decisions 2, 7 and 9.

## 4. Claude effort and verification

- [ ] TASK-MES-005 Forward Claude tier effort through the support-claude-reasoning-effort wrapper --effort under claude-effort-forwarding negotiation, with source launch and explicit --effort over tier; remove the pending NOTE and update the docs. Verify argv, stale-helper refusal and provenance. Depends on TASK-MES-004 and TASK-CRE-003; see design decision 6.

- [ ] TASK-MES-006 Run scripts/test with inherited NOGG_* cleared and without bd, plus packed init/update scaffold and tier launch fixtures and a read-only live models/doctor probe; record unsigned versions and evidence. Depends on TASK-MES-004; see all delta scenarios.
