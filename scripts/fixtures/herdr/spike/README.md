# herdr spike fixtures (TASK-HDR-001)

Captured on 2026-10-15 from herdr 0.9.5 (linux-aarch64, protocol 22) on the
delivery Raspberry Pi, for the fake herdr CLI stub (TASK-HDR-005) and the
herdr backend tasks. `FACTS.md` holds the gate results and the implementation
facts the later tasks code against.

| Path | Content |
| --- | --- |
| `version.txt`, `status-*.txt` | `herdr --version`, `herdr --session <name> status` (running / not running) |
| `help/` | `herdr --help` and each command group's usage (`herdr <group>`) |
| `json/` | stdout/stderr of each verified CLI form; socket API replies (`ping.json`, `layout-apply.json`) |
| `read/fixture-*` | `pane read` of a deterministic pane (`line one`, then a dim `dim placeholder` and plain `plain input`) for every `--source`, in `text` and `--format ansi`, plus the socket `pane.read` replies |
| `read/{claude,codex,agy}/` | agent screens read under the real wrapper: idle, working, blocked; `.ansi` files are the attribute (SGR) variant |
| `api/schema-excerpt.json` | the socket method list and the request schemas the backend uses (from `herdr api schema --json`) |
| `exit-codes.tsv` | exit status of each captured call |

Sanitization: home and scratch paths, user and host names, and session UUIDs
are replaced by neutral values. Agent screens contain only synthetic probe
prompts; no credential and no real conversation content is included.
