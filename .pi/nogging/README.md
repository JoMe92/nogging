# Nogging optional Pi extensions

This directory holds Nogging's **optional** Pi features. Pi never discovers
it: nothing here loads until it is enabled. The mandatory guard stays at
`.pi/extensions/nogging-guard.ts`, and optional extensions never go into
`.pi/extensions/`, because `--approve` would load them in every supervised
session.

```text
.pi/nogging/
  README.md               this file: conventions and the extension index
  lib/                    shared helpers (no Pi runtime import)
  extensions/<name>/
    index.ts              Pi entry: default-exports the extension factory
    test/                 tests and fixtures, shipped with the code
```

## Conventions

`scripts/pi-extensions.test.sh` lints these and runs every `*.test.ts`
offline (no Pi, network or build step).

- One kebab-case directory per extension. The directory name is the
  extension's name in config and commands.
- `index.ts` default-exports the factory and starts no work at top level.
- Runtime imports are `node:*` built-ins and relative paths with explicit
  `.ts` extensions. Pi types come only through `import type`, so a test can
  import `index.ts` and drive the factory with a fake `pi` and `ctx`.
- No `package.json` and no npm dependency anywhere under `.pi/nogging/`.
- Erasable TypeScript only: no enums, namespaces or constructor parameter
  properties. Node type stripping and Pi's loader then read the same file.
- Footer keys are `nogging-<name>`. Timers start in `session_start`, are
  `unref`'d and are cleared in an idempotent `session_shutdown`.
- An extension never logs, stores or displays a credential.
- Shared usage snapshots go through `lib/usage-cache.ts`:
  `$XDG_CACHE_HOME/nogging/usage/` (default `~/.cache/nogging/usage/`),
  directory mode 0700, files 0600, written by temporary file and rename.

## Extensions

| Extension | Entry | Purpose |
| --- | --- | --- |

No extension is shipped yet.
