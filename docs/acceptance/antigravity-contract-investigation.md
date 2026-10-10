# Antigravity contract investigation — incomplete

Date: 2026-10-10. Bead: SPEC-brxc (TASK-AGR-001). Runtime: installed
Linux agy 1.3.2. Baseline: 280cee2. This is partial investigation evidence,
not runtime acceptance or a supported-version declaration. Human sign-off is
not provided. No implementation adapter has been enabled.

References checked:

- Installed `agy --version` and `agy --help`.
- Installed `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`.
- https://antigravity.google/docs/cli/reference
- https://antigravity.google/docs/cli/headless
- https://antigravity.google/docs/hooks
- GitHub issue #54's downstream 1.3.0 prototype report (imported observations,
  not independent proof for 1.3.2).

## Live observations

The isolated workspace was `.nogging/state/agy-contract-probe` in the allocated
implementation worktree. A named hook matched every PreToolUse and recorded
stdin and its working directory, then returned
`{"decision":"deny","reason":"Contract probe: deny every tool"}`. The Stop
handler recorded its payload and returned the same non-continuing decision.
Every process set `AGY_CLI_DISABLE_AUTO_UPDATE=true`.

Command:

```
agy --print 'Use write_to_file to create probe.txt containing PROBE. Attempt exactly once. If denied, report denial and stop. Do not use other tools.' --output-format json --print-timeout 45s
```

Observed exit code: 0. The captured write_to_file call had TargetFile,
CodeContent, Overwrite, Description, toolAction and toolSummary arguments.
The hook ran in `.agents`, with camelCase conversationId, workspacePaths,
transcriptPath, artifactDirectoryPath and modelName. The file was not created.
Stop fired with the same conversationId, fullyIdle true, executionNum 0 and
terminationReason NO_TOOL_CALL. Sanitized fixtures are in
`scripts/fixtures/antigravity/1.3.2/`.

**Contract mismatch:** the headless result reported SUCCESS and omitted
`denied_actions` despite the hook denial. Its response text described the
denial. Exit zero plus SUCCESS cannot establish that a requested action ran;
absence of denied_actions cannot establish absence of hook denial. Future
acceptance must verify the expected effect and captured events. Do not invent
a universal response-text parser from this one sample.

`agy --print /usage --output-format json --print-timeout 30s` exited zero and
returned a command object with name usage, data.groups, and group buckets.
Both Gemini Models and Claude and GPT models had independent weekly and 5h
buckets with remaining_fraction and reset_time. The fixture preserves the
observed schema. It does not prove exhaustive model mapping or exhausted-quota
message handling; no quota was intentionally exhausted.

Help exposes --conversation, --prompt-interactive, --model, --mode and
--sandbox. Help alone does not validate exact resume, interactive permission
behavior or sandbox worktree compatibility. Installed hooks documentation
lists allow/deny/ask/force_ask; only deny was observed live here.

## Blocking environment condition

This managed session permits writes only to the repository/worktree, Git
metadata and temporary roots. `~/.gemini/antigravity-cli` is outside those
roots. The runtime reported read-only filesystem failures creating its
conversation database and artifact directories, saving refreshed credentials
and persisting conversation/cache state. The returned conversation's artifact
directory and transcript did not exist after exit. An ephemeral turn worked,
but that is insufficient evidence for durable conversation behavior.

The same boundary prevents the required atomic real settings/trust preparation
and controlled permission-mode verification. Existing trust includes an
ancestor of this workspace, so this run does not test fresh-workspace trust.
Do not modify global trust broadly, copy credentials into a scratch HOME or
claim exact resume works from this result. Resume the investigation in an
operator-provisioned session with narrowly writable Antigravity runtime state.
The current approval policy is never, so this session cannot request an
expanded filesystem grant.

Still unverified: real edit/multi-edit and URL payloads, interactive ask and
force_ask under relevant permission modes, fresh trust preparation, exact
persisted resume, exhausted-quota text and downstream prototype source. Unknown
contracts remain unsupported. TASK-AGR-001 must remain blocked until its
required investigation is complete; dependent implementation must not start.
