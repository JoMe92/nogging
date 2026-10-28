## ADDED Requirements

### Requirement: Optional Pi extensions live in a Nogging home that Pi never auto-loads

Nogging's optional Pi extensions SHALL live under `.pi/nogging/extensions/<name>/`, one kebab-case directory per extension with an `index.ts` entry that default-exports the extension factory. Shared helpers SHALL live under `.pi/nogging/lib/`, and a `.pi/nogging/README.md` SHALL state the conventions and index every extension. No optional extension SHALL be placed in `.pi/extensions/`, which stays reserved for the mandatory guard. The guard extension SHALL remain at `.pi/extensions/nogging-guard.ts`, unchanged.

#### Scenario: A new extension follows the layout

- **WHEN** an extension named `glm-usage` is added
- **THEN** its entry is `.pi/nogging/extensions/glm-usage/index.ts`
- **AND** the README lists it

#### Scenario: Supervised project trust does not load optional extensions

- **WHEN** a Pi session starts with `--approve` in a repository that contains `.pi/nogging/extensions/glm-usage/index.ts`
- **AND** `glm-usage` is not enabled
- **THEN** Pi does not load `glm-usage`

### Requirement: Pi extensions load without a build step or npm dependency

Every file under `.pi/nogging/` SHALL be loadable both by Pi and by Node's type stripping without compilation. Runtime imports SHALL be limited to `node:` built-ins and relative paths with explicit `.ts` extensions. Pi types SHALL be imported only with `import type`. No `package.json` and no npm dependency SHALL exist under `.pi/nogging/`. Code SHALL use only erasable TypeScript syntax.

#### Scenario: A bare runtime import is rejected

- **WHEN** an extension adds `import x from "some-package"`, or a non-type import of `@earendil-works/pi-coding-agent`
- **THEN** the extension test runner fails and names the file and the import

#### Scenario: A package.json is rejected

- **WHEN** a `package.json` appears anywhere under `.pi/nogging/`
- **THEN** the extension test runner fails and names it

### Requirement: Pi extensions have an offline test runner

`scripts/pi-extensions.test.sh` SHALL run every `*.test.ts` under `.pi/nogging/` with Node's built-in test runner and type stripping. It SHALL set temporary `HOME`, `XDG_CACHE_HOME` and `PI_CODING_AGENT_DIR` and need no Pi, network or build step. It SHALL fail when any test fails. It SHALL also lint the layout and import conventions, and the lint SHALL need only bash and grep. When `node` is missing or cannot strip types, the runner SHALL still lint, print a skip line for the tests and pass.

#### Scenario: Extension tests run without Pi

- **WHEN** `scripts/test` runs on a host with Node 22 and no `pi`
- **THEN** every extension test runs and its result decides the suite

#### Scenario: Old or missing Node

- **WHEN** `node` is absent, or cannot load TypeScript
- **THEN** the convention lint still runs
- **AND** the tests are reported as skipped and the runner passes

### Requirement: Supervised Pi sessions load only the extensions the project enables

The config key `pi_extensions` SHALL be an array of unique extension names. It SHALL default to `[]` when absent, and `templates/nogging-config.json` SHALL scaffold it as `[]`. `session launch --agent pi` SHALL validate the key before any worktree, trust, settings, record or backend side effect. It SHALL refuse a non-array value, a name that is not kebab-case, a duplicate name, or a name with no `.pi/nogging/extensions/<name>/index.ts` in the launch working directory, and the refusal SHALL name the key, the value and the fix. For a valid list, the launched `pi` SHALL receive one `--extension <working directory>/.pi/nogging/extensions/<name>/index.ts` per name, after the guard and in config order. The session record SHALL store `pi_extensions` with the loaded names. The launch output SHALL print `pi-extensions=<names>` when the list is non-empty. With an empty or absent list, the launch arguments, record and output SHALL be unchanged. Launches of other agents SHALL ignore the key.

#### Scenario: An enabled extension loads in a supervised session

- **WHEN** `pi_extensions` is `["glm-usage"]` and `session launch --agent pi` runs
- **THEN** `pi` receives `--extension <workdir>/.pi/nogging/extensions/glm-usage/index.ts` after the guard
- **AND** the record lists `glm-usage`

#### Scenario: An unknown extension refuses before side effects

- **WHEN** `pi_extensions` names `no-such-ext`
- **THEN** `session launch --agent pi` refuses and names `pi_extensions` and `no-such-ext`
- **AND** creates no worktree, settings, record or backend session

#### Scenario: Nothing enabled is unchanged

- **WHEN** `pi_extensions` is absent or empty
- **THEN** the Pi launch arguments, record and output equal those of a launch before this change

### Requirement: validate and doctor check the enabled extensions

`./scripts/nogg validate` and `doctor` SHALL report a FAIL for every `pi_extensions` defect that launch refuses. `doctor` SHALL also print NOTEs, never failures, for three cases. The first is an enabled extension that the personal Pi settings do not name. The second is the community package `npm:pi-glm-usage` configured while `glm-usage` is enabled or personally installed. The third is a personally installed Nogging extension path that no longer exists. `doctor` SHALL read Pi's personal `settings.json`, under `PI_CODING_AGENT_DIR` or `~/.pi/agent`, and SHALL NOT read `auth.json`.

#### Scenario: A broken enabled name fails validate

- **WHEN** `pi_extensions` is `["glm-usage", "glm-usage"]`
- **THEN** `validate` and `doctor` report a FAIL that names the duplicate

#### Scenario: A doubled GLM footer is surfaced

- **WHEN** the personal Pi settings list `npm:pi-glm-usage` and `glm-usage` is enabled
- **THEN** `doctor` prints a NOTE naming both and `pi remove npm:pi-glm-usage`
- **AND** exits zero because of that NOTE

### Requirement: Standalone Pi installs an extension through Pi's own package command

`nogg pi-ext list` SHALL be read-only and SHALL print each available extension, whether `pi_extensions` enables it, and whether the personal Pi settings name its path. `nogg pi-ext install <name>` SHALL run `pi install <main checkout>/.pi/nogging/extensions/<name>/index.ts`, and `nogg pi-ext remove <name>` SHALL run `pi remove` with the same path. Both SHALL resolve the main checkout even when run from a linked worktree. Both SHALL refuse an unknown name or a missing `pi` and change nothing. Neither SHALL edit Pi's settings file directly, pass `-l`, or run during `init` or `update`.

#### Scenario: Install from a linked worktree uses the main checkout

- **WHEN** `nogg pi-ext install glm-usage` runs in a linked planning or Lead worktree
- **THEN** it runs `pi install` with the main checkout's `index.ts` path

#### Scenario: Unknown name

- **WHEN** `nogg pi-ext install no-such-ext` runs
- **THEN** it refuses, names the available extensions, and runs no `pi` command

### Requirement: The extension home ships with the installer

`init` and `update` SHALL copy `.pi/nogging/` verbatim to consumer repositories, and `remove` SHALL delete it. `init` SHALL enable no extension. `update` SHALL keep an existing `pi_extensions` value. The package `files` list SHALL include the tree and the Z.ai quota module.

#### Scenario: Fresh install ships but enables nothing

- **WHEN** `init` runs in a new repository
- **THEN** `.pi/nogging/extensions/glm-usage/index.ts` exists
- **AND** the scaffolded `pi_extensions` is `[]`

#### Scenario: Update keeps the enabled list

- **WHEN** `update` runs where `pi_extensions` is `["glm-usage"]`
- **THEN** the tree is refreshed and `pi_extensions` is still `["glm-usage"]`
