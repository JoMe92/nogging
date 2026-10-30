# Pi extensions

Nogging ships a small home for optional **Pi extensions** and one extension
that uses it, `glm-usage`, which shows your Z.ai (GLM) coding-plan quota in
Pi's footer. This page is for operators who run Pi, and for anyone who wants to
write another extension. For the rest of the Pi setup see
[Using Nogging with Pi](using-with-pi.md).

Nothing on this page loads by default. An extension runs only after you enable
it, and `init` and `update` enable nothing.

## Layout and conventions

Optional extensions live under `.pi/nogging/`, beside the two mandatory ones:

```text
.pi/
  extensions/nogging-guard.ts       mandatory guard, auto-loaded
  extensions/nogging-lifecycle.ts   mandatory lifecycle reporter, auto-loaded
  prompts/                          workflow prompts
  nogging/                          optional features, never auto-loaded
    README.md                       conventions and the extension index
    lib/                            shared helpers (no Pi runtime import)
    extensions/<name>/
      index.ts                      Pi entry: default-exports the factory
      test/                         tests and fixtures, shipped with the code
```

The optional tree sits outside `.pi/extensions/` on purpose. Pi discovers
everything in `.pi/extensions/`, and a supervised launch passes `--approve`, so
anything placed there would load in every supervised Pi session. Pi discovers
nothing under `.pi/nogging/`, so an extension there loads only when you enable
it. The installer copies the tree verbatim on `init` and `update`, and a
consumer's other `.pi/*` content is never touched.

The conventions, which `scripts/pi-extensions.test.sh` lints:

- One kebab-case directory per extension. The directory name is the
  extension's name in config and commands.
- `index.ts` default-exports the factory and starts no work at top level.
- Runtime imports are `node:*` built-ins and relative paths with explicit
  `.ts` extensions. Pi types come only through `import type`.
- No `package.json` and no npm dependency anywhere under `.pi/nogging/`.
- Erasable TypeScript only: no enums, namespaces or constructor parameter
  properties.
- Footer keys are `nogging-<name>`. Timers start in `session_start`, are
  `unref`'d and are cleared in an idempotent `session_shutdown`.
- An extension never logs, stores or displays a credential.
- Shared usage snapshots go through `lib/usage-cache.ts`.

## Writing and testing an extension

There is no build step. Pi runs TypeScript through its own loader, and Node
runs the same file through type stripping, so the file you write is the file
that loads.

1. Create `.pi/nogging/extensions/<name>/index.ts` that default-exports a
   factory taking the `pi` API. Import Pi's types with `import type` only.
2. Register handlers and commands inside the factory. Start long-lived
   resources, such as a polling timer, in `session_start` and release them in
   `session_shutdown`.
3. Add a row to the table in `.pi/nogging/README.md`. The lint requires one
   index entry per extension.
4. Write `*.test.ts` files beside the code, using `node:test`. Because
   `index.ts` imports Pi only as a type, a test can import it and drive the
   factory with a fake `pi` and a fake `ctx`. Inject `fetch`, the clock and the
   environment through the factory's dependencies so a test needs no network and
   no real Pi.
5. Run the suite:

   ```bash
   ./scripts/pi-extensions.test.sh
   ```

   It lints the conventions with bash and grep, then runs every `*.test.ts`
   under `.pi/nogging/` with `node --test`, using temporary `HOME`,
   `XDG_CACHE_HOME` and `PI_CODING_AGENT_DIR`. It prints a skip line and passes
   when `node` is missing or too old to strip types. `scripts/test` runs it with
   the rest.

An extension that needs non-erasable syntax or an npm dependency does not fit
these conventions; it would need to be a Pi package.

## Enabling an extension for supervised sessions

List the names in `.nogging/config.json`:

```json
{ "pi_extensions": ["glm-usage"] }
```

Every `session launch --agent pi` then passes
`--extension <working directory>/.pi/nogging/extensions/<name>/index.ts` after
the guard, in the order you listed. The launch output prints
`pi-extensions=<names>` and the session record stores the loaded names. An
invalid value refuses the launch before any side effect; the details are in
[Using Nogging with Pi](using-with-pi.md#enabling-optional-extensions--pi_extensions)
and the key is in [configuration](configuration.md). Other agents ignore it.

## Enabling an extension for standalone Pi

To load an extension in Pi sessions you start yourself, install it through Pi's
own package command:

```bash
./scripts/nogg pi-ext list
./scripts/nogg pi-ext install glm-usage
./scripts/nogg pi-ext remove glm-usage
```

`list` is read-only. It shows each available extension, whether `pi_extensions`
enables it, and whether your personal Pi `settings.json` names it. It reads that
file from `PI_CODING_AGENT_DIR`, or `~/.pi/agent`, and never reads `auth.json`.

`install` and `remove` run `pi install` or `pi remove` with the main checkout's
`.pi/nogging/extensions/<name>/index.ts`, even when you run them from a linked
worktree, so the entry survives worktree cleanup. They refuse an unknown name or
a missing `pi`, leave `settings.json` to Pi, and never pass `-l`. Run
`install` once per machine; `init` and `update` never do, because it writes
personal configuration.

`nogg doctor` prints a NOTE, never a FAIL, for an enabled extension that is not
installed, for an install whose path no longer exists, and for the community
package `npm:pi-glm-usage` configured next to `glm-usage`. The last one gives
two footers and double polling; remove the community package with `pi remove
npm:pi-glm-usage`.

If you both enable an extension in `pi_extensions` and install it personally, a
supervised session can load the module twice. `glm-usage` guards against this
with a process-wide registry, so the second activation registers nothing.

## `glm-usage`

`glm-usage` reads the Z.ai coding-plan quota and shows it where you work.

**Footer.** The status entry `nogging-glm-usage` shows both windows, with the
free share and the time to reset:

```text
GLM 5h 63% free · reset 2h 14m | week 79% free · reset 3d 6h
```

"Free" is 100 minus the used percentage. The reset is recomputed from the
stored reset instant each time the footer renders.

**Command.** `/glm-usage` forces a refresh, at most once every 30 seconds, and
shows a report: the plan level, each window as used percent, free percent and
absolute and relative reset time, when the last good observation was taken, any
stale or error reason, and the snapshot path. Inside the 30-second interval it
shows the current state without a request.

**Polling.** Only interactive and RPC runs poll. The extension refreshes at
`session_start` and then every 180 seconds, with a 10-second request timeout. It
first reads the shared snapshot and uses it, with no request, when it is younger
than 120 seconds, so several Pi sessions on one host make about one request per
interval between them. Print and JSON runs make no request unless you run the
command.

**Stale.** A failed refresh keeps the last good values and appends
`· stale <age>`, where the age is the time since the last good observation. A
window whose reset instant has passed since then shows `reset passed` instead of
its old percentage.

**Errors.** Errors are reduced to a fixed set of reasons and never carry
response text: `no-key`, `http-<status>`, `api-code-<code>`, `timeout`,
`network` and `malformed`. With no good value yet, the footer reads
`GLM usage unavailable (<reason>)`.

**Missing key.** With no resolvable key, no request is sent and the footer
reads `GLM usage: no Z.ai key`. The next tick checks again, so signing in with
`/login` takes effect without a restart. The extension gets the key only from
Pi, through `ctx.modelRegistry.getApiKeyForProvider("zai")`, on each refresh.
That resolver covers `auth.json`, a `!command` secret-manager entry and the
`ZAI_API_KEY` environment variable. The extension never reads `auth.json`
itself, never caches the key, and sends it only in the `Authorization` header
of the request. It never appears in the footer, a notification, an error, the
snapshot or a log.

**Snapshot.** After each successful fetch the extension writes
`$XDG_CACHE_HOME/nogging/usage/pi-zai.json`, which is
`~/.cache/nogging/usage/pi-zai.json` by default. The directory is private (mode
0700) and the file is written by temporary file and rename with mode 0600. It
holds no key, account identifier, header or raw response:

```json
{"schema_version": 1, "provider": "zai", "source": "pi-extension",
 "observed_at": "2026-10-27T16:00:00Z", "plan_level": "pro",
 "windows": {"short":  {"used_percent": 37, "resets_at": "2026-10-27T18:14:00Z"},
             "weekly": {"used_percent": 21, "resets_at": "2026-10-30T22:00:00Z"}}}
```

A window the response lacked is omitted. A failed write does not stop the
footer, and `/glm-usage` reports it. `nogg usage --agent pi` reads and writes
the same file; see [Usage limits](usage-limits.md#pi-via-zai).

**Scope.** Only the Z.ai Global provider (`zai`) is supported. The China coding
plan and other Pi providers are out of scope.

## The undocumented endpoint

Z.ai does not document the quota endpoint. Both the extension and `nogg usage`
call `GET https://api.z.ai/api/monitor/usage/quota/limit` with a bearer token,
a request that the community package `pi-glm-usage` documented first. Z.ai can
change or remove it without notice.

Nogging handles that with strict parsing rather than guesses. A response counts
only with `code` 200 and a `data.limits` list. A `TOKENS_LIMIT` entry with unit
3 is the 5-hour window and unit 6 is the weekly one; everything else is
ignored. A percentage must be a finite number from 0 to 100 and the reset a
finite epoch-millisecond time, or that window is unavailable. When neither
window parses, the response is `malformed`. A plan without a weekly limit leaves
that window unknown.

When the shape changes, the footer says `malformed` and `nogg usage` reports the
quota as **unknown**, never zero. The launch gate then follows
`usage_gate.on_unknown`, which is `warn` by default.

The URL is a constant. No environment variable or setting overrides it, because
an override could send your key to another host.

## See also

- [Using Nogging with Pi](using-with-pi.md): the rest of the Pi setup.
- [Usage limits](usage-limits.md): `nogg usage --agent pi` and the launch gate.
- [Commands](commands.md#pi-ext): `nogg pi-ext`.
