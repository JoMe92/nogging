## Context

The Product Owner (Jonas) made this request on 2026-10-27, verbatim in German:

> "Ich habe eine Möglichkeit gefunden, wie man den Usage by Pi von ZAI
> ausliest. Dazu brauchen wir eine kleine Zusatzfunktion für Pi, die wir
> selber entwickeln können. Die soll in Nogging entwickelt werden und
> verwendet werden. Dafür brauchen wir irgendwie eine Ordnerstruktur, damit
> wir in Zukunft, also weil der Pi soll jetzt als Coding-Tool weiter
> ausgebaut werden. Und da werden mehrere Plugins oder Kleinigkeiten
> entwickelt werden und dafür braucht es eine Ordnerstruktur innerhalb von
> Nogging, weil der Pi das neue Herzstück werden soll über die nächsten
> Wochen, Monate und immer mehr auch Funktionalitäten hinzubekommen soll."

In English: we need a small Pi add-on that reads the Z.ai usage. It is built and
used inside Nogging. Pi is to become the centrepiece over the coming weeks and
months, with more extensions to follow, so Nogging needs a folder structure for
them. His proposed first extension is one TypeScript file. It shows the
Z.ai/GLM windows in Pi's footer through `ctx.ui.setStatus()`, for example
"63 % frei · Reset in 2h 14m" for the short window and "79 % frei · Reset in
3d 6h" for the weekly one. It registers `/glm-usage` through
`pi.registerCommand()` and reads the key safely from Pi's configuration,
never printing it. It polls at most every 2–3 minutes, keeps the last value
and marks it stale on an error, and adds no npm dependency.

Facts gathered while planning, on `develop` at `67ffe65`, against the
installed `@earendil-works/pi-coding-agent@1.4.0`, its shipped `docs/` and
`dist/*.d.ts`:

- **Where Pi loads extensions.** It loads from `~/.pi/agent/extensions/`
  (personal; `PI_CODING_AGENT_DIR` relocates `~/.pi/agent`), from
  `<cwd>/.pi/extensions/` (project, only after project trust), from the
  `extensions` and `packages` arrays of the personal or project
  `settings.json`, and from `--extension`/`-e` on the command line. It loads
  direct `.ts`/`.js` files, plus subdirectories that hold an `index.ts`. Pi
  runs TypeScript through `jiti` with no compile step. `pi install <path>`
  adds a local source to the personal `settings.json` without copying it, and
  a file path loads one extension. Only `.pi/settings.json`, `.pi/mcp.json`,
  `.pi/{extensions,skills,prompts,themes}`, `.pi/SYSTEM.md` and
  `.pi/APPEND_SYSTEM.md` are project-trust resources. Pi discovers no other
  `.pi/` subdirectory.
- **Supervised Pi launches.** `scripts/session-launch` passes `--approve
  --extension <worktree>/.pi/extensions/nogging-guard.ts`, which loads every
  project resource for that run. Anything placed in `.pi/extensions/`
  therefore loads in every supervised Pi session of every consumer repository.
  The installer copies `.pi/extensions` and `.pi/prompts` verbatim, by
  `bin/lib/manifest.js` `verbatimDirs`.
- **Key access.** An extension context has
  `ctx.modelRegistry.getApiKeyForProvider(provider)`, which resolves a key
  the way Pi does: from `auth.json`, a `!command` secret-manager entry, or the
  `ZAI_API_KEY` environment variable. Outside Pi, `pi auth print-api-key
  --provider zai` prints the resolved key, and `pi auth check --provider zai`
  reports `ready`, `not_ready` or `invalid` without printing it. On this host
  the provider is `zai` (`defaultProvider: zai`, `defaultModel:
  glm-5.3-flash`).
- **Status and lifecycle.** `ctx.ui.setStatus(key, text)` sets a footer
  entry, and `ctx.hasUI` and `ctx.mode` tell interactive and RPC runs apart
  from print and JSON runs. Pi's docs forbid timers in the extension factory.
  Long-lived resources start in `session_start` and stop in an idempotent
  `session_shutdown`. A failing `tool_call` handler blocks the tool, and other
  handler errors are reported and do not crash Pi.
- **The endpoint.** The Product Owner already has the community package
  `npm:pi-glm-usage@0.1.2` (MIT) configured in his personal Pi settings. Its
  source documents the request this change relies on:
  `GET https://api.z.ai/api/monitor/usage/quota/limit` with `Authorization:
  Bearer <key>`. The response is `{code: 200, data: {level, limits: [...]}}`.
  Each limit has `type` (`TOKENS_LIMIT` or `TIME_LIMIT`), `unit` (3 is the
  5-hour window, 6 the weekly one, 5 a monthly tool limit), `percentage`
  (used, 0–100) and `nextResetTime` (epoch milliseconds). Z.ai does not
  document this endpoint. The community package reads `auth.json` directly,
  so it misses `!command` keys and the environment variable. It uses the
  footer key `glm-usage` and registers no command. This change copies no code
  from it.
- **Usage today.** `nogg_usage.inspect_usage()` supports `claude`, `codex`
  and `antigravity`. `observe('pi')` reports both windows unknown ("unsupported
  usage provider"), so the gate admits Pi with a WARN under the default
  `on_unknown: "warn"`. The Claude source is a cache file that Claude's own
  status line writes (`$XDG_CACHE_HOME/nogging/usage/claude.json`, schema 1).
  The Antigravity source is a cache file plus one bounded runtime probe when
  the cache is stale, which `scripts/test` disables with
  `AGY_NOGG_USAGE_PROBE=0`. Nogging reads no authentication file for usage
  today.
- **Routing.** `configurable-agent-routing` (open, nothing claimed) states that
  it "does not add a usage source for Pi", and lists "Pi usage is unknown" as a
  risk. Its decision engine calls the usage gate with each entry's
  `on_unknown`. A known Pi observation therefore flows into routing with no
  change to that change.
- **Tests.** `scripts/test` is bash plus coreutils and offline.
  `scripts/pi-guard.test.sh` imports the guard's TypeScript directly with
  Node type stripping, and passes with a skip notice when Node is missing or
  too old. CI runs Node 22.

## Goals / Non-Goals

**Goals:** a scalable, opt-in home for Nogging's Pi extensions. A GLM usage
footer and command that never leak the key. A known Pi quota for `nogg usage`
and the usage gate. Offline tests with no build step and no new dependency. A
docs page.

**Non-Goals:** moving or changing the guard extension. Changing
`configurable-agent-routing`, the model-selection table, or Pi's own settings
files. Quota for Pi providers other than Z.ai Global (`zai`), including the
China coding plan. Account identity. Token accounting for Pi sessions. A Pi CI
job. Publishing extensions to npm.

## Decisions

### Decision 1: Test and execution discipline

Every suite stays offline in `scripts/test`: no network, no real `pi`, no
Dolt, `bd`, tmux or herdr server. HTTP is injected (a `fetch` stub in
TypeScript, an injected opener in Python). Key resolution is injected (a fake
`modelRegistry`, a stub `pi` on `PATH`). `XDG_CACHE_HOME`, `HOME` and
`PI_CODING_AGENT_DIR` point into temporary directories. `scripts/test` exports
`PI_NOGG_USAGE_PROBE=0`, as it does for Antigravity, so no fixture runs the
developer's real `pi auth print-api-key`. A test that exercises the probe
opts in with a stub `pi`. Tests are written red first. Prompts, fixtures and
docs contain no email address and no real key. The owner is named only as
Jonas or JoMe92.

### Decision 2: The home is `.pi/nogging/`, beside the untouched guard

```text
.pi/
  extensions/nogging-guard.ts   mandatory guard, auto-loaded (unchanged)
  prompts/                      workflow prompts (unchanged)
  nogging/                      optional Nogging Pi features, never auto-loaded
    README.md                   conventions and the extension index
    lib/                        shared helpers (no Pi runtime import)
      usage-cache.ts
      usage-cache.test.ts
    extensions/
      glm-usage/
        index.ts                Pi entry: default factory
        quota.ts                pure parsing and formatting
        test/
          quota.test.ts
          index.test.ts
          fixtures/             Z.ai responses shared with the Python tests
```

This location wins over a top-level `pi/` folder for three reasons. First, the
source path equals the installed path, as it already does for `.pi/extensions`,
`.claude/agents` and `.codex/rules`, so one resolver serves this repository
and every consumer. Second, a consumer's own top-level `pi/` cannot collide
with it. Third, Pi never discovers `.pi/nogging/`, so nothing loads until it is
enabled. Optional extensions must not go into `.pi/extensions/`, because
`--approve` would load them in every supervised session.

Conventions, which the runner lints:

- Directory names are kebab-case, and the directory name is the extension's
  name in config and commands.
- Each extension has `index.ts` with a default export factory and nothing
  else at top level that starts work.
- Runtime imports are `node:*` built-ins and relative paths with explicit
  `.ts` extensions. Pi types come only through `import type`.
- There is no `package.json` and no npm dependency under `.pi/nogging/`.
- Code uses erasable TypeScript only, with no enums, namespaces or parameter
  properties. Node type stripping and Pi's `jiti` then load the same file
  unchanged.
- Footer keys are `nogging-<name>`. Timers start in `session_start`, are
  unref'd and are cleared in an idempotent `session_shutdown`.
- An extension never logs, stores or displays a credential.

Tests live beside the code they cover and ship with it. That is harmless, and
it keeps one copy rule for the whole tree.

### Decision 3: The offline runner `scripts/pi-extensions.test.sh`

The runner finds every `*.test.ts` under `.pi/nogging/` and runs them with
`node --test`. It adds `--experimental-strip-types` only on a Node that needs
it. It sets temporary `HOME`, `XDG_CACHE_HOME` and `PI_CODING_AGENT_DIR`, and
fails on any test failure. When `node` is missing or cannot strip types, it
prints a skip line and passes, like `scripts/pi-guard.test.sh`. Its lint step
also runs without Node and needs only bash and grep. The lint checks the
Decision 2 conventions: an `index.ts` per extension, a README index entry per
extension, no `package.json`, no bare-specifier runtime import, and no
non-type import of `@earendil-works/pi-coding-agent`. `index.ts` imports Pi
only as a type, so a test can import it and drive the factory with a fake `pi`
and a fake `ctx`. No Pi installation is needed.

### Decision 4: Activation is opt-in, per extension, in two places

**Supervised sessions.** A new config key, `pi_extensions` (array of names,
default `[]`, scaffolded in `templates/nogging-config.json`), lists the
extensions that every `session launch --agent pi` loads. The Python launch
path validates it before any side effect: an array of unique kebab-case
names, each with `.pi/nogging/extensions/<name>/index.ts` in the launch
working directory. A defect refuses the launch and names the key, the name and
the fix (`nogg update`, or remove the name). `validate` and `doctor` report
the same defects as FAIL. The wrapper then passes `--extension
<workdir>/.pi/nogging/extensions/<name>/index.ts` after the guard, in config
order, resolved like the guard from the session's working directory. The
record stores `pi_extensions` with the loaded names. The launch line prints
`pi-extensions=<names>` only when the list is non-empty, so a launch with an
empty list is unchanged. Other agents ignore the key.

**Standalone Pi.** `nogg pi-ext list` is read-only. It shows each available
extension, whether `pi_extensions` enables it, and whether the personal Pi
settings name it. It reads `settings.json` under `PI_CODING_AGENT_DIR` or
`~/.pi/agent`, never `auth.json`. `nogg pi-ext install <name>` runs `pi
install <main checkout>/.pi/nogging/extensions/<name>/index.ts`, and `nogg
pi-ext remove <name>` runs `pi remove` with the same path. Both always use the
main checkout's path, never a linked worktree, so the entry survives worktree
cleanup. Both refuse when `pi` is missing or the name is unknown. Both leave
Pi's settings file to Pi itself and never pass `-l`. This mirrors
`codex-prompts-link`: opt-in, never run by `init` or `update`.

`doctor` prints a NOTE, never a FAIL, for these cases:

- An enabled extension that is not personally installed. This is
  informational only.
- The community package `npm:pi-glm-usage` configured next to an enabled or
  installed `glm-usage`, which gives two footers and double polling.
- A personal install whose path no longer exists.

### Decision 5: The `glm-usage` extension

- **Key.** The extension gets the key only through
  `ctx.modelRegistry.getApiKeyForProvider("zai")`, on each refresh. It does
  not read `auth.json` and does not cache the key between refreshes. The key
  goes only into the `Authorization: Bearer` header of the request. It never
  appears in a status, notification, error text, snapshot or log. Error text
  is reduced to a fixed set of reasons: `no-key`, `http-<status>`,
  `api-code-<code>`, `timeout`, `network`, `malformed`.
- **Endpoint.** The URL is the constant
  `https://api.z.ai/api/monitor/usage/quota/limit`. No environment variable
  or setting overrides it, because an override could send the key to another
  host. Tests inject `fetch`. The request has a 10 s timeout.
- **Parsing** lives in pure `quota.ts`. A response needs `code` 200 and a
  `data.limits` array. `TOKENS_LIMIT` with unit 3 maps to `short` (5h), and
  `TOKENS_LIMIT` with unit 6 maps to `weekly`. Every other entry is ignored.
  `percentage` must be finite in 0–100, and `nextResetTime` must be a finite
  epoch-millisecond time. A window that is absent or invalid makes that window
  unavailable. If neither window parses, the response is `malformed`.
  `data.level` is kept as the plan level when it is a short string.
- **Polling.** Polling runs only when `ctx.hasUI` is true, that is in
  interactive and RPC mode. Print and JSON runs make no request unless the
  command runs. The first refresh happens at `session_start`, and later ones
  every 180 s from an unref'd timer, which `session_shutdown` clears. Before
  fetching, the extension reads the shared snapshot (Decision 6). If the
  snapshot is younger than 120 s, it uses the snapshot and makes no request.
  Several concurrent Pi sessions on one host therefore make about one request
  per interval between them.
- **Footer** (`ctx.ui.setStatus("nogging-glm-usage", …)`). In English, to
  match every other Nogging surface:
  `GLM 5h 63% free · reset 2h 14m | week 79% free · reset 3d 6h`.
  "Free" is 100 minus used. The reset is shown as relative time, recomputed
  on each render from the stored reset instant.
- **Errors and staleness.** A failed refresh keeps the last good values and
  appends `· stale <age>`, where age is the time since the last good
  observation. A window whose reset instant has passed since that observation
  shows `reset passed` instead of its old percentage. With no good value yet,
  the footer reads `GLM usage unavailable (<reason>)`. When no key resolves,
  no request is sent, the footer reads `GLM usage: no Z.ai key`, and the next
  tick checks again, so a later `/login` takes effect without a restart.
  Nothing escapes a handler.
- **`/glm-usage`.** The command forces a refresh, but at most one refresh
  every 30 s; inside that interval it shows the current state. It then
  notifies a multi-line report: plan level, each window as used percent, free
  percent, absolute and relative reset time, the time of the last good
  observation, the stale or error reason, and the snapshot path. It never
  includes the key.
- **Loaded twice.** A personal install plus a supervised `--extension` can load
  the module twice in one process. A process-global registry, kept under a
  `Symbol.for` key on `globalThis`, makes the second activation register
  nothing. `session_shutdown` releases the registry, so `ctx.reload()`
  re-registers cleanly. Live acceptance verifies this, since Pi's behaviour for
  duplicate local sources is undocumented.

### Decision 6: The shared snapshot

After a successful fetch, the extension writes
`$XDG_CACHE_HOME/nogging/usage/pi-zai.json` (default
`~/.cache/nogging/usage/pi-zai.json`). This is the directory where Claude's
status line already writes `claude.json`. The `lib/usage-cache.ts` helper
creates the directory with mode 0700 and writes a temporary file with mode
0600, then renames it into place. The content:

```json
{"schema_version": 1, "provider": "zai", "source": "pi-extension",
 "observed_at": "2026-10-27T16:00:00Z", "plan_level": "pro",
 "windows": {"short":  {"used_percent": 37, "resets_at": "2026-10-27T18:14:00Z"},
             "weekly": {"used_percent": 21, "resets_at": "2026-10-30T22:00:00Z"}}}
```

A window the response lacked is omitted. The snapshot holds no key, account
identifier, header or raw response. A write failure does not stop the footer,
and `/glm-usage` reports it. The Python probe (Decision 7) writes the same
file in the same format, with `source: "nogg-probe"`.

### Decision 7: `nogg usage --agent pi`

A small Z.ai quota module beside `scripts/nogg_usage.py` adds the Pi
provider to `inspect_usage()`.

- **Provider.** The Z.ai windows apply when the effective Pi provider is
  `zai`. The provider comes from the launch model's `zai/` prefix when present,
  otherwise from the Pi profile's `provider`, otherwise from `defaultProvider`
  in Pi's personal `settings.json`. A known different provider makes both
  windows unknown with the reason `no usage source for Pi provider <name>`.
- **Cache first.** A cache with schema 1, provider `zai` and an age of at most
  `usage_gate.stale_seconds` is used. Each window follows the existing rules:
  a reset in the past is unknown ("reset elapsed; fresh observation
  required"), and a reset before the observation is unknown. The report
  `model_group` is `zai-coding-plan`, and the account stays unknown.
- **Bounded probe.** When the cache is stale, missing or malformed, and
  `PI_NOGG_USAGE_PROBE` is not `0`, the module runs one probe:
  `pi auth print-api-key --provider zai` with a 15 s timeout and stdout
  captured in memory, then the same GET with a 10 s timeout. On success it
  writes the cache (Decision 6) and reports known windows. On failure it
  reports unknown windows with one reason:
  - `pi not installed`
  - `no Z.ai API key configured in Pi`
  - `Z.ai rejected the key (HTTP <status>)`
  - `quota probe failed (<timeout|network>)`
  - `unsupported quota response`

  The key is never written to disk, an argument vector, the environment of
  another process, a log, the session record, the report or an exception
  message. The probe passes no key on the command line. The endpoint is the
  same constant, with no override.
- **Hints.** A missing key carries the hint `configure the ZAI Coding Plan key
  in Pi (/login)`. A stale cache with the probe disabled carries `run nogg
  usage --agent pi`. A missing `pi` carries `install pi`. The hints are shown
  by `nogg usage`, the unknown-admitted launch warning and `doctor`, and they
  never change a decision.
- **Doctor** never probes and makes no network call. When `pi` is on `PATH`,
  its quota-freshness NOTE covers the Pi cache like the Antigravity one.
- **Gate and routing.** Known windows go through `evaluate_gate()` unchanged,
  with cap, estimate, reservations and exit 75 on denial. Unknown windows keep
  the configured `on_unknown`, including a routing entry's own
  `on_unknown`. A probe runs during launch admission. It therefore runs on the
  host side before any side effect, and it adds at most the two timeouts.
  Unknown is never zero.

### Decision 8: Packaging

`bin/lib/manifest.js` adds `{from: '.pi/nogging', to: '.pi/nogging'}` to
`verbatimDirs`, and `package.json` `files` lists the tree and the Z.ai quota
module. `templates/nogging-config.json` scaffolds `"pi_extensions": []`.
`init` writes the tree and enables nothing. `update` refreshes the tree and
keeps an existing `pi_extensions` value. `remove` deletes the tree as it
deletes every verbatim directory. A consumer's other `.pi/*` content is
never touched.

### Decision 9: This repository's own setup

This repository's tracked `.nogging/config.json` sets `"pi_extensions":
["glm-usage"]`, because the Product Owner's supervised Leads run Pi with GLM.
On the delivery host, a host task runs `nogg pi-ext install glm-usage`. On the
Product Owner's instruction (see *Product Owner decisions*), it also runs
`pi remove npm:pi-glm-usage`, so the footer is not doubled. Neither step
changes a shipped default.

### Decision 10: Lanes and integration

There are no Beads edges into another change. `configurable-agent-routing`
TASK-RTG-004 and TASK-PXG-003 both edit `scripts/nogg_usage.py`, in different
functions. TASK-RTG-001 and TASK-PXG-004 both add a key to
`docs/configuration.md` and `templates/nogging-config.json`. TASK-RTG-005 and
TASK-PXG-007 both edit `docs/using-with-pi.md`. `scheduled-loops` and
`branded-docs-site` touch the docs site and the installer manifest. Each lane
therefore rebases onto `develop` before it integrates, and resolves a textual
conflict by keeping both sides.

## Risks / Trade-offs

- **The endpoint is undocumented.** Z.ai can change or remove it. Mitigation:
  strict parsing, an explicit `malformed` reason, a footer that says so, and
  `nogg usage` reporting unknown, never zero. The fixtures pin the shape that
  this change knows.
- **The Python probe reads a credential.** It is the first Nogging code to
  handle a provider key. Mitigation: the key comes only from Pi's own
  resolver, lives only in memory and goes only into one HTTPS header to a
  constant host. Tests assert that the key never reaches output, the cache,
  the record or exception text. The probe is off in `scripts/test`.
- **Two parsers.** TypeScript and Python both parse the response.
  Mitigation: both test suites read the same fixture files under
  `.pi/nogging/extensions/glm-usage/test/fixtures/`, and both write and read
  the same snapshot schema.
- **Weekly window absent on some plans.** A plan without a weekly limit leaves
  that window unknown for the gate. Under `on_unknown: "warn"` the launch is
  admitted with a warning. A user who denies on unknown would be refused, and
  live acceptance records which windows this account's plan reports.
- **Shared quota across hosts.** Z.ai counts the account, not the host. A
  snapshot younger than the staleness limit can understate use made elsewhere
  in that interval. That is the same bound every cache-based provider has.
- **Type-stripping limits.** An extension that needs non-erasable syntax or
  an npm dependency does not fit these conventions. It would need a Pi
  package and a separate planning decision.

## Migration Plan

No migration. An existing install gets `.pi/nogging/` on `update`. A missing
`pi_extensions` key means `[]`. Pi usage changes from always unknown to known
when a Z.ai key is configured. A user who wants the old behaviour sets
`usage_gate.enabled: false` or leaves Pi unrouted. Rollback is a plain revert:
nothing outside the repository's own files and the cache directory is written,
apart from the opt-in `pi-ext install`.

## Product Owner decisions

Recorded at planning time. Revise them before materialization if the Product
Owner answers otherwise.

1. **Location.** `.pi/nogging/` (Decision 2), not a top-level `pi/`.
2. **Footer language.** English, like every Nogging surface; the Product
   Owner's German example is translated.
3. **Community package.** On this host it is replaced by `glm-usage`
   (Decision 9, TASK-PXG-008), assumed approved by the request to build our
   own.
4. **Routing policy.** No routing default changes. Whether the host-local
   Pi routing entry should switch to `on_unknown: "deny"` once Pi usage is
   known stays the Product Owner's call, through TASK-RTG-007 or an explicit
   later instruction.
