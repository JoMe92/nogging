# Antigravity contract investigation

Date: 2026-10-10. Bead: SPEC-brxc (TASK-AGR-001). Runtime: installed
Linux agy 1.3.2. Baseline: 280cee2. This records the initial partial investigation and its resumed live evidence,
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

## Initial environment block (resolved on resume)

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
contracts remain unsupported. At that point TASK-AGR-001 remained blocked; the resumed evidence below
supersedes the filesystem block and defines unsupported contracts explicitly.

## Resume investigation, 2026-10-10

The operator relaunched the existing allocated worktree with narrowly writable
`~/.gemini/antigravity-cli`. No runtime credentials were relocated. The original
partial commit was preserved. This resolves the filesystem block above; it does
not establish full runtime acceptance.

Installed version remains **1.3.2**, the exact investigated contract baseline.
The official hooks reference was rechecked; its documented tool list includes
single and multi-edit tools. The downstream prototype was inspected read-only
in `/home/jome/src/supply-doc` (`scripts/hooks/agy-guard` and the Antigravity
sections of `scripts/nogg`), alongside the issue #54 report and comments. Its
boundary resolver predates canonical WSS ownership and must not be copied as
an authorization source. Its claim that `force_ask` overrides global
always-proceed conflicts with its later issue comment; the latter reports that
it does not. Do not advertise that mode as enforceable restricted operation.

### Durable conversation and denied result

Repeating the original deny probe now created a nonempty conversation database
and captured matching PreToolUse and Stop IDs. A second process with
`--conversation <captured-id>` returned exactly that ID, advanced `num_turns`
from one to two, and correctly recalled the prior file request and denial.
The requested `probe.txt` still did not exist. `durable-result.json` and
`resume-result.json` preserve this relationship using the same sanitized ID.

Hook denial again exited zero with `status: SUCCESS` and no `denied_actions`.
A separate 60-second multi-tool prompt timed out without any tool event;
it too exited zero with `SUCCESS`, an empty response, zero usage and zero
duration. Only stderr identified the partial timeout. `tool-result.json`
preserves that result. Future validation must assert expected effects/events
and reject timeout stderr; these fields alone are not an execution oracle.

### Real tool payloads

Targeted low-effort headless probes captured `replace_file_content` with
`TargetFile`, `StartLine`, `EndLine`, `TargetContent`, `ReplacementContent`,
`AllowMultiple`, `Instruction`, `Description`, `toolAction` and `toolSummary`;
and `read_url_content` with `Url`, `toolAction` and `toolSummary`. Both were
denied before effects. The edit fixture remained unchanged.

The same model explicitly reported that `multi_replace_file_content` was
unavailable, making no hook call. Its result is preserved separately. That
contract remains **unsupported**, despite appearing in the current official
reference: deny unknown write-capable tools until a real payload is validated.
Model availability is not proof of a universal runtime schema.

### Interactive trust and permissions

The first interactive process displayed `Do you trust the contents of this
project?`. Accepting only the isolated probe folder saved its exact path in
`trustedWorkspaces`. That first process reached a native command permission
prompt but emitted no captured command hook. A new process after saved trust
loaded the hook, denied a harmless printf command and captured Stop events.
This confirms that accepting trust mid-launch is not evidence that guards
were active from the first tool call. Preparation must happen before start.

Under the unchanged default `request-review` setting, subsequent shell calls
with `force_ask` and `ask` each displayed `Run this command?` with the exact
hook reason (`Contract probe: force_ask` / `Contract probe: ask`). Both were
canceled through `No, cancel`; no persistent command grant was selected.
A hook `allow` still displayed the native command permission prompt, without
the hook reason. Thus hook allow alone does **not** establish unattended trusted
execution on this installation. A launcher must validate any additional
permission mechanism before relying on it. The existing global keys and
permission mode were not changed. Global always-proceed remains unsuitable
for restricted launches, based on the downstream observation, and is not
independently validated here. Unknown/strict permission settings must not be
silently treated as the verified default.

### Remaining unsupported contracts

No linked-worktree sandbox acceptance was performed; reject requested sandbox
operation. No quota was deliberately exhausted. The downstream exhausted-credit
text is imported evidence only: `Your AI credits balance is too low to
continue.` Exhausted quota classification and complete model-to-group mapping
remain unvalidated and must fail closed in AGR-005. The existing `/usage`
fixture demonstrates weekly and 5h buckets, not those classifications.

Atomic launcher trust preparation, refusal on trust-write failure, hook merging,
full trusted/restricted guard enforcement and full live lifecycle acceptance
remain later tasks, rather than being claimed by this investigation. No human
acceptance or full supported-runtime declaration is made here.

### Explicit trusted permission probe and validation

With `--dangerously-skip-permissions`, a shell hook returning `allow` ran
`printf AGR_TRUSTED_PROBE > trusted-probe.txt` without a prompt; the file's
exact contents were checked. A second process with the same flag and a shell
hook returning `deny` did not create `trusted-deny-probe.txt`. The corresponding
sanitized results are `trusted-result.json` and `trusted-deny-result.json`.
Thus this explicit flag retains observed hook denial in 1.3.2. It is a candidate
for the trusted wrapper, subject to later complete floor/boundary acceptance;
it must never be used for restricted prompting. Global always-proceed was
not modified or independently tested.

The full `scripts/test` passed on this branch with all inherited Nogging
session variables removed from the test subprocess and npm's cache redirected
to `/tmp/nogg-agr-npm-cache` (log: `/tmp/agr-001-clean-tests.log`). The previous
rerun retained the real task-tick broker and consequently sent fixture IDs to
the real tracker; it failed and is not counted as green evidence. Live execution
retains the real fence and broker. All committed fixtures parse, exact resume
ID/turn linkage and denied effects were checked, and `git diff --check` passes.

### Integration prerequisite

AGR-002 requires this investigation's execution commit integrated into develop
before allocating its separate implementation worktree. This session's delivery
instruction forbids merging its PR, so progression needs prerequisite
integration by an authorized operator or a planning revision of that contract.
No dependent task is implemented against an unintegrated prerequisite.
