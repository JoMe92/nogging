# Beads dashboard — delivery host acceptance — 2026-11-01

Unsigned execution evidence for TASK-DSH-011 (`SPEC-r465`), change `beads-dashboard`.

**Overall: partial, not accepted as it stands.** The packed install, update and remove
cycle passes, and the real `nogg dashboard` was measured over loopback on this host's real
Beads and its real usage store of 1.4 GB. Nothing in a browser has been tested yet: this
run had no browser, no phone and no network bind, since a supervised session refuses a
network bind on purpose. Every row that needs one of those is **open** below. No result
is claimed for an open row, and automated tests are not counted as live results here.
This report does not establish Product Owner acceptance.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-11-01, about 21:12Z to 21:16Z for the measurements |
| Host | `raspberrypi`, Raspberry Pi 5 Model B Rev 1.1, Linux aarch64, 16 GB of memory, 2 GB of swap; rebooted about 21:04Z |
| Operator | Nogging-supervised Claude Lead `sf-lead-spec-r465-20261101t210901-0e8a` |
| Toolkit version | 3.6.0 (`package.json`) |
| Git commit | `906e8c6`; the dashboard code there equals `develop` at `8896248` |
| Runbook | TASK-DSH-011 with the Product Owner's scope for this session; not `docs/acceptance.md` |
| Install path exercised | `npm pack`, then the packed `bin/cli.js`, in a scratch repository |
| Backend | Real `bd` 1.2.2 and the host's Dolt, real usage store, loopback only |
| Python | 3.13.5 |

## Results

Result is `pass`, `partial`, `fail` or `open`. `open` means nobody has done the check yet.

### Done on the host

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 1 | A consumer update: `init`, `update`, `remove` from a packed archive | pass | `scripts/packed-dashboard.test.sh` passes. The installed dashboard served its shell, a font and a stub Bead after `init` and again after `update` |
| 2 | Woff2 byte identity | pass | Same test: `diff -r` of the package against the consumer, `cmp` of each font against its source, and the served font equals the file |
| 3 | Drift of fonts, licence and logo against `docs/assets` | pass | Same test, for nine files. Red proof: one appended byte in `favicon.svg` made the test fail |
| 4 | No dashboard test ships | pass | Same test and `scripts/package-manifest.test.sh` |
| 5 | Real Beads over loopback | pass | Three runs, all five sources `fresh`. `/api/v1/beads` served 687 Beads, the number `bd list --all` gives. The task's 673 is the number at planning time |
| 6 | Real usage store read over loopback | pass | Three runs, source `fresh`, under the 45 second cap. Three runtimes returned; see *Findings* |
| 7 | The run adds no state | pass | No `.nogging/state/dashboard` in the main checkout, `git status` of the main checkout clean, exit code 0 in every run |
| 8 | Token read beside the collector | partial | `quarantined_batches` stayed 0, `last_error` stayed null. No collection fell into a read (`last_success_at` stayed 21:04:09Z), so the waiting path was not seen live. Unit and medium tests cover it |

### Open, to do by hand

Each needs a person with a browser or a phone. Start a network bind on your own terminal,
not inside a supervised session: `./scripts/nogg dashboard --list-binds`, then
`./scripts/nogg dashboard --bind <tailscale address>`.

| # | Check | Spec scenario | Result | Evidence |
| --- | --- | --- | --- | --- |
| 9 | Desktop browser: open the page, every view, no console or policy error | The interface works on desktop and phone | open | |
| 10 | Phone over Tailscale: open the access link; the token leaves the address bar | The phone opens the link | open | |
| 11 | Phone: come back later and stay signed in | The phone comes back | open | |
| 12 | Table on a phone at 360 CSS pixels: cards, no sideways page scroll | The table on a phone | open | |
| 13 | Graph by touch: pinch, drag and tap; the page itself does not scroll or zoom | The graph by touch | open | |
| 14 | Theme choice: applies at once and is remembered, on desktop and phone | Theme choice | open | |
| 15 | A note with markup shows as text and runs nothing | A note contains markup | open | |
| 16 | "Unencrypted connection" banner on a LAN bind | The interface works on desktop and phone | open | |
| 17 | First-load timing on the phone over Tailscale, in the browser | TASK-DSH-011 | open | |

## Loopback measurements

Three runs one after another, with one `nogg dashboard --port 0` process each, started from
the Bead's worktree and reading the main checkout's state. Host load about 2.5, about 12 GiB
of memory available at the start and never below 11.66 GiB. Every run had a guard that stops
it at 5 GiB for the process tree or below 3 GiB available; it never fired.

| Measure | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| Socket open after the start (s) | 0.41 | 0.40 | 0.36 |
| `beads` loaded after the start (s) | 1.52 | 1.80 | 1.45 |
| `git` loaded after the start (s) | 3.80 | 3.57 | 3.23 |
| `tokens` loaded after the start (s) | 6.96 | 7.01 | 6.75 |
| Token source: from `git` loaded to `tokens` loaded (s) | 3.16 | 3.44 | 3.52 |
| Token source: a `dolt` child seen for (s) | 2.04 | 2.29 | 2.05 |
| Peak, server and all children (MB) | 301 | 311 | 306 |
| Peak, server alone (MB) | 138 | 138 | 138 |
| Peak, `dolt` children together (MB) | 209 | 223 | 216 |
| Peak, `bd` children together (MB) | 84 | 104 | 85 |
| Peak, `git` children together (MB) | 55 | 56 | 55 |
| Server once loaded (MB) | 98 | 98 | 99 |
| Start page while loading, 28 requests (s) | 0.036 | 0.047 | 0.032 |
| Start page once loaded, first time (s) | 0.115 | 0.077 | 0.071 |
| Start page once loaded, again (s) | 0.031 | 0.021 | 0.029 |

Once loaded, the 28 requests of the start page (the shell, its assets, `/api/v1/freshness`,
`/api/v1/summary?range=30d` and `/api/v1/beads`) carry 163,320 bytes on the wire and 777,100
unpacked. `/api/v1/beads` alone is 90,153 and 527,850. Its first answer took 33 to 37 ms and
later ones about 1 ms. `/api/v1/summary?range=all` took 24 to 30 ms, a detail 2 to 7 ms and
`/api/v1/graph?scope=ready` 2 to 3 ms.

How to read these numbers:

- **Not a browser time.** The requests ran one after another from a Python client on the
  host, with no rendering, no parallel connections and no network. Row 17 is the real figure.
- **Memory** is `VmRSS` sampled every 0.2 s, about 33 samples per run. A shorter peak can be
  missed, and shared pages count more than once. The `bd` calls use the host's shared Dolt
  server, whose memory is not in these figures.
- **The disk cache was not dropped**, which needs root. Run 1 was the first read by this
  session after the reboot, but another reader may have come first, and it was no slower
  than the others. A cold read may take longer.
- **The planning estimate for the read was about 9 seconds.** On this host it is about 3.5 s,
  with the lease held for about 2 s. The guide now states the measured figure.

## Findings

Recorded on `SPEC-r465` with the `discovery` label. Nothing here was fixed; these wait for
a planning session. No Decision 9 contract changed.

1. **No Pi row in the real token panel (verified effect, cause unknown).** The store returned
   Antigravity, Claude and Codex with `partial: []`, while 17 Pi session records exist on this
   host. The guide claimed "Pi and Antigravity" as partial runtimes; that sentence is corrected
   here. Whether Pi usage is not collected or is waiting in the spool was not analysed.
2. **787 batches wait in the spool (verified count, cause unknown).** The token panel and the
   collector status agree on 787, the oldest from 2026-10-17, and the collector reports no
   error. The panel says these are not in its numbers, so that behaviour is correct, but
   known tokens may be well below the real figure for two weeks of work.
3. **`remove` leaves empty directories (minor).** It deletes `scripts/dashboard/` file by
   file and leaves the empty tree, as it does for every managed tree. The packed test
   checks for files.

## Deviations

- Beads: 687 real Beads instead of the task's 673, because the count grew after planning.
- No desktop browser, phone, network bind or Tailscale run: rows 9 to 17 are open, by the
  Product Owner's instruction for this session.
- The memory measurement was not part of the task's list. The Product Owner asked for it.
- `nogg test full` was not run, as the test policy says.

## Sign-off

Signed-off-by:
