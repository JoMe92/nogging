## 1. Extension home and test runner (feat/)

- [ ] TASK-PXG-001 [standard] Pi extension home, conventions lint, shared usage-cache helper, Z.ai fixtures and the offline extension test runner.
  Per design Decisions 1-3 and 6 and the pi-extensions home, build-step and
  test-runner requirements: create .pi/nogging/README.md (the conventions of
  Decision 2 and an extension index), .pi/nogging/lib/usage-cache.ts (cache
  path from XDG_CACHE_HOME or HOME, 0700 directory, 0600 temp file plus
  rename, tolerant read that returns undefined on missing or malformed data),
  and the Z.ai response fixtures under
  .pi/nogging/extensions/glm-usage/test/fixtures/: both windows, the
  TIME_LIMIT unit 5 entry, weekly absent, code 500, missing limits, and
  out-of-range or non-finite values. Use placeholder plan levels and no
  real key. Add scripts/pi-extensions.test.sh: the bash and grep lint (an
  index.ts and README entry per extension, no package.json, no bare runtime
  import, no non-type Pi import), then node --test over every *.test.ts with
  temporary HOME, XDG_CACHE_HOME and PI_CODING_AGENT_DIR, with a skip-pass
  when node is missing or cannot strip types. Check: usage-cache.test.ts,
  red first, covering modes, atomic replace and tolerant read; lint
  self-tests with throwaway violating trees; scripts/test. Branch feat/.

## 2. The glm-usage extension (feat/)

- [ ] TASK-PXG-002 [standard] glm-usage extension: Pi-resolved key, Z.ai quota parsing, footer, /glm-usage, bounded shared polling, stale, error and missing-key behaviour.
  Per design Decisions 5 and 6 and every glm-usage requirement: add
  .pi/nogging/extensions/glm-usage/quota.ts (pure parsing of the fixture
  shapes, fixed error reasons, footer and report formatting from an injected
  clock) and index.ts. The default factory registers `/glm-usage` and the
  session_start and session_shutdown handlers. It resolves the key only
  through ctx.modelRegistry.getApiKeyForProvider("zai"), calls the constant
  URL with a Bearer header and a 10 s abort, and polls only with ctx.hasUI,
  at session_start and then every 180 s from an unref'd timer. It uses a
  shared snapshot younger than 120 s instead of fetching, rate-limits the
  command to one refresh per 30 s, writes the snapshot through
  lib/usage-cache.ts after each success, and keeps a process-global
  single-instance registry released on shutdown. Add it to the README index.
  Check: quota.test.ts and index.test.ts, red first, drive the factory with
  a fake pi, ctx and fetch. They cover every glm-usage scenario, including
  the exact footer strings, stale age, reset passed, the no-key no-request
  path, snapshot content and 0600 mode, the key absent from every status,
  notification and file, print mode starting no timer, the double load, and
  shutdown idempotence; scripts/pi-extensions.test.sh; scripts/test. Branch
  feat/ (after TASK-PXG-001).

## 3. Pi quota for nogg usage and the gate (feat/)

- [ ] TASK-PXG-003 [standard] [security] nogg usage --agent pi: Z.ai snapshot adapter, bounded key-safe probe, provider check, remediation hints and doctor note.
  Per design Decision 7 and the session-usage Pi requirements: add a Z.ai
  quota module beside scripts/nogg_usage.py, with pure parsing over the
  shared fixtures, a cache read, and a probe with injected run and opener
  callables. Wire it into inspect_usage() for agent pi. Add the provider
  resolution (model zai/ prefix, profile provider, then defaultProvider in
  the settings.json under PI_CODING_AGENT_DIR or ~/.pi/agent, never
  auth.json), the cache freshness from usage_gate.stale_seconds with the
  existing reset rules, model_group zai-coding-plan, the probe
  (`pi auth print-api-key --provider zai` with a 15 s timeout and captured
  stdout, then a GET to the constant URL with a 10 s timeout, writing the
  snapshot atomically with mode 0600 and source nogg-probe), the five failure
  reasons and the three Pi hints. The hints reach nogg usage, the
  unknown-admitted launch warning and the doctor quota-freshness NOTE.
  Doctor never probes. Export PI_NOGG_USAGE_PROBE=0 in scripts/test. Ship the
  module in bin/lib/manifest.js and package.json files. Check: new Python
  unit tests and scripts/pi-usage.test.sh, red first, with a stub pi and an
  injected opener. They cover every session-usage Pi scenario, including
  exit 75 on a weekly denial, the other-provider reason and a sentinel key
  that never appears in stdout, stderr, the snapshot, the record or an
  exception. Also run usage, usage-gate, usage-unknown-visibility,
  packed-usage-gate and scripts/test. Branch feat/ (after TASK-PXG-002).

## 4. Supervised activation (feat/)

- [ ] TASK-PXG-004 [standard] pi_extensions config key: launch validation and --extension wiring, record field, validate and doctor checks.
  Per design Decision 4 and the supervised-activation and validate/doctor
  requirements: add the pi_extensions key, defaulting to [] and scaffolded
  in templates/nogging-config.json. Validate it in the Python launch path
  before any worktree, trust, settings, record or backend side effect, and
  refuse with a message that names the key, the value and the fix. Pass the
  validated names to scripts/session-launch, whose Pi branch appends one
  --extension <workdir>/.pi/nogging/extensions/<name>/index.ts per name after
  the guard. Store pi_extensions in the record, and print
  pi-extensions=<names> only when the list is non-empty. Report the same
  defects as FAIL in validate and doctor. Document the key in
  docs/configuration.md, whose key coverage scripts/docs-site.test.sh checks.
  Check: new scripts/pi-extensions-launch.test.sh, red first, with a stub pi
  recording its argv. It covers enabled, unknown, duplicate, non-array and
  empty cases, no side effects on refusal, and a byte-identical launch with
  the key absent. Also run session.test.sh, pi-guard.test.sh, docs-site and
  scripts/test. Branch feat/ (after TASK-PXG-003).

## 5. Standalone install (feat/)

- [ ] TASK-PXG-005 [standard] nogg pi-ext list, install and remove through Pi's own package command, plus the doctor NOTEs.
  Per design Decision 4 and the standalone-install and validate/doctor
  requirements: add the `pi-ext` subcommand group. `list` is read-only and
  reads Pi's personal settings.json under PI_CODING_AGENT_DIR or ~/.pi/agent,
  never auth.json. `install <name>` runs `pi install <main
  checkout>/.pi/nogging/extensions/<name>/index.ts` and `remove <name>` runs
  `pi remove` with that path. Both resolve the main checkout from a linked
  worktree, refuse an unknown name or a missing pi, never edit Pi settings
  directly and never pass -l. Add the doctor NOTEs: enabled but not
  personally installed, the npm:pi-glm-usage overlap naming `pi remove
  npm:pi-glm-usage`, and a dangling personal install path. List the commands
  in docs/commands.md. Check: extend scripts/pi-extensions-launch.test.sh or
  add scripts/pi-ext.test.sh, red first, with a stub pi and a scratch
  PI_CODING_AGENT_DIR. It covers every scenario, including linked-worktree
  resolution and no pi call on refusal. Also run doctor and nogg suites and
  scripts/test. Branch feat/ (after TASK-PXG-004).

## 6. Packaging (test/)

- [ ] TASK-PXG-006 [standard] Ship .pi/nogging with init and update; packed install, update and remove coverage.
  Per design Decision 8 and the installer-shipping requirement: add
  {from: '.pi/nogging', to: '.pi/nogging'} to verbatimDirs in
  bin/lib/manifest.js and the tree to the package.json files list. In the
  packed suites, prove these behaviours: init writes the tree and
  scaffolds pi_extensions [] without enabling anything; update refreshes the
  tree and keeps an existing ["glm-usage"]; remove deletes the tree and
  leaves other .pi/* content; a packed consumer with glm-usage enabled
  launches Pi with the extra --extension; and a consumer without the key
  launches byte-for-byte as before. Check: extend
  scripts/packed-session-launch.test.sh and scripts/cli.test.sh, plus the
  package-manifest suite; one isolated full scripts/test with inherited
  NOGG_* cleared and bd absent. Branch test/ (after TASK-PXG-005).

## 7. Documentation (docs/)

- [ ] TASK-PXG-007 [standard] Pi extensions docs page and updates to the Pi, usage-limits, configuration, commands, AGENTS and changelog pages.
  Per design Decisions 2-8 and the docs goal: rebase onto develop first,
  because configurable-agent-routing TASK-RTG-005 and branded-docs-site
  edit the same pages. Add docs/pi-extensions.md, a docs-site page linked
  from docs/README.md and the guides index, covering six topics: the layout
  and conventions, writing and testing an extension with no build step,
  enabling it for supervised sessions with pi_extensions, standalone
  `nogg pi-ext install`, the glm-usage footer, command, stale, error and
  missing-key behaviour with the snapshot path and its key-free content, and
  the undocumented-endpoint risk. Update docs/using-with-pi.md
  (version 1.4.0 checked, the .pi/nogging/ payload row, extension loading
  beside the guard), docs/usage-limits.md (Pi via Z.ai, the probe, hints,
  PI_NOGG_USAGE_PROBE, routing's on_unknown now meaningful for Pi), the
  AGENTS.md Pi tool note (one line pointing to the page) and CHANGELOG.md
  [Unreleased]. Check: docs-site, runtime-guidance-docs, installation-docs
  and planning-docs suites; scripts/test. Branch docs/ (after TASK-PXG-005).

## 8. This repository and host (chore/)

- [ ] TASK-PXG-008 [routine] Enable glm-usage for this repository and the delivery host, replacing the community package.
  Per design Decision 9 and the Product Owner decisions in design.md: in
  this repository's tracked .nogging/config.json set "pi_extensions":
  ["glm-usage"], and commit only that key. On the delivery host, from the
  main checkout, run `./scripts/nogg pi-ext install glm-usage`, then
  `pi remove npm:pi-glm-usage`. Record `nogg pi-ext list`, `pi list` and
  `./scripts/nogg usage --agent pi` output as evidence, never printing the
  key. Change no shipped default. Needs a --full-access Lead. If the
  session cannot run pi against the personal Pi settings, record a blocking
  discovery and hand these two commands to the Orchestration Agent. Check:
  doctor shows no pi_extensions FAIL and no npm:pi-glm-usage overlap NOTE;
  scripts/test. Branch chore/ (after TASK-PXG-006).

## 9. Live acceptance (test/)

- [ ] TASK-PXG-009 [standard] Bounded live glm-usage and Pi quota acceptance on the delivery host with real Pi and Z.ai.
  Per design Decisions 4-7: on the delivery host, with the installed pi
  (record its version), use a disposable packed scratch consumer with
  glm-usage enabled and a private tmux socket. Never use the fleet socket,
  the canonical planning lock or the Orchestration Agent. Launch one
  supervised Pi session. Confirm from `session log` that the footer shows
  both windows, or record which windows this plan reports, and that
  /glm-usage reports. Confirm the snapshot is mode 0600 and that a script
  holding the key only in memory finds it in no snapshot, log or record. Use
  a scratch PI_CODING_AGENT_DIR without a key to show `GLM usage: no Z.ai
  key` and the nogg usage hint. Confirm a single footer with the personal
  install plus the supervised flag. Delete the snapshot and confirm
  `nogg usage --agent pi` probes to known. Confirm a scratch low cap_percent
  denies with exit 75. Stop and clean up every session. Write
  docs/acceptance/<date>-pi-extensions-glm-usage.md with honest
  pass/fail/skipped results, and leave Signed-off-by empty. Check: report
  committed unsigned; scripts/test. Branch test/ (after TASK-PXG-008).

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A
depends on B): 002<-001; 003<-002; 004<-003; 005<-004; 006<-005; 007<-005;
008<-006; 009<-008. TASK-PXG-006 and TASK-PXG-007 run in parallel after
TASK-PXG-005. There is no edge into another change. File overlaps with
configurable-agent-routing (scripts/nogg_usage.py, docs/configuration.md,
templates/nogging-config.json, docs/using-with-pi.md), scheduled-loops (the
installer manifest) and branded-docs-site (docs pages) are resolved by
rebasing onto develop and keeping both sides, as design Decision 10 states.

Branches are `<type>/pi-extensions-glm-usage` with these lanes: feat/ 001,
002, 003, 004, 005 in sequence; test/ 006 then 009; docs/ 007; chore/ 008. A
lane's next task reuses its prefix only after the previous branch is
integrated and deleted. Before allocating a dependent worktree, verify that
every prerequisite execution commit is integrated into develop; Bead closure
alone is not enough.

## Execution contract

A task's first line is its Bead title. Its full slice is that line plus the
indented paragraph under it, the design Decisions it names, design Decision 1,
and the matching requirements in specs/. The Main Worker claims each task and
implements it only in its own allocated worktree on its lane branch. Write the
tier classification to the Bead note on every launch, including Pi launches.
Every suite is offline in scripts/test: no Dolt, bd, shared tmux or herdr
server, real agent CLI or network, but stub binaries, injected fetch or opener,
and temporary HOME, XDG_CACHE_HOME and PI_CODING_AGENT_DIR. Run the task's
named checks; the full scripts/test runs in CI. Then commit with a Conventional
subject ending in the real Bead token, push the lane branch and open the pull
request against develop. Only then run bd close and `scripts/nogg task-done`,
and append the SHA and evidence to the Bead. A Codex Lead needs --full-access
or --profile trusted to reach the shared Dolt server. Agents never hand-edit
OpenSpec. Discoveries carry the discovery label and prose. No prompt, fixture,
doc, test output or evidence note contains an email address or a real API key,
and the owner is named only as Jonas or JoMe92. Nobody signs human acceptance.
