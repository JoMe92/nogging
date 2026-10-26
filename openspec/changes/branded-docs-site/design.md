## Context

The Product Owner asked on 2026-10-26 for a plan that makes
https://jome92.github.io/nogging/ a branded, well-structured documentation and
project site. Facts gathered while planning, on `develop` at `ae9e81f`:

**How the site is built today.** GitHub Pages builds `main:/docs` with its own
Jekyll. There is no build workflow. The Product Owner decided this the same
day (Bead SPEC-8klc, `docs/_config.yml`). GitHub Pages currently publishes
Jekyll 3.10.0, `github-pages` gem 232, `jekyll-remote-theme` 0.4.3,
`jekyll-include-cache` 0.2.1, `jekyll-sass-converter` 1.5.2 (libsass),
`jekyll-seo-tag` 2.8.0 and `jekyll-sitemap` 1.4.0
(`https://pages.github.com/versions.json`, read 2026-10-26). The theme is
`jekyll-theme-cayman`. The plugins are `jekyll-seo-tag`, `jekyll-sitemap`,
`jekyll-relative-links`, `jekyll-titles-from-headings`,
`jekyll-optional-front-matter` and `jekyll-readme-index`. `docs/README.md`
is promoted to the site index. The SPEC-8klc Lead verified a build with the
`github-pages` gem in Docker (27 pages). No `docs/*.md` page contains Liquid
delimiters. Pages builds only from `main`, so site changes become visible only
after a release.

**Pages and their readers.** `docs/` holds 24 top-level Markdown pages,
`docs/acceptance/` (18 dated reports and one investigation) and `docs/brand/`
(banner, logo, two social cards, four diagrams, all PNG). Fourteen pages are
in the package `files` list. The installer copies twelve of them verbatim
into consumer repositories under `docs/nogging/`
(`bin/lib/manifest.js`, `docs:`). Edits to those twelve reach every
consumer on `update`. GitHub renders YAML front matter as a table above the
page. Front matter would therefore show up on GitHub and in every consumer
copy.

**Content found** (a read-only audit of every page during planning; the
per-page actions are in Decision 8):

- **Missing pages.** There is no Claude Code guide, no first-change
  walkthrough, no troubleshooting page, no glossary and no configuration
  reference. Nothing documents the 20 top-level `nogg` subcommands as a
  reference (`scripts/nogg --help`). The two partial command tables (the
  sessions guide and the operating model) are incomplete. Half of the
  subcommands have no help string.
- **Shipped pages contradict each other or the code.** Trusted Codex is
  described as network-off (`operating-model.md`,
  `running-work-in-sessions.md`), but `trusted.codex.toml` sets
  `network_access = true`. The trusted Claude profile is said to deny
  `systemctl`, `curl`, `wget` and `WebFetch`, but the shipped
  `trusted.json` denies only the command floor. The tmux socket appears as
  `nogg` where the code uses `nogging`. `security-model.md` retires the
  planning worktree before `plan-end`. `worktree-workflow.md` says "never
  self-merge", while `--full-access` fast-forwards to `develop`. The
  Orchestration Agent is called the "third" persona in one page and the
  "fourth" in another. `using-with-antigravity.md` never says
  "experimental".
- **Stale pages.** `vision-and-architecture.md` is frozen at v1.0.0: it lists
  shipped features as "Planned", has a roadmap and a German heading.
  `agent-identities.md` says the GitHub App wiring is "not yet implemented",
  but `scripts/nogg` already sets the credential helper. `usage-limits.md`
  shows raw probes instead of documenting `nogg usage`. `docs/README.md`
  calls the public-cutover checklist "not yet run", says "five roles" and
  links the private `JoMe92/rooftree`.
- **Links that will 404 on the site.** `faq.md` and `comparison.md` link
  `../README.md` and `../SECURITY.md`. `compatibility.md` and
  `using-with-antigravity.md` link `blob/develop`.
- **Unpinned installer and internal IDs.** `vision-and-architecture.md`,
  `using-with-codex.md` and `using-with-pi.md` name `npx
  github:JoMe92/nogging init` without a tag. Real tracking IDs appear on user
  pages: `SPEC-fc4` and `TASK-SYNC-006` in `vision-and-architecture.md`,
  `SPEC-7ec` in `architecture.md`. Weakness codes (W5, W6), PR and issue
  numbers and "in this change" wording appear in `architecture.md`,
  `failure-recovery.md`, `security-model.md` and the agent guides.
  Placeholder IDs (`SPEC-abc`, `SPEC-abc123`, `SPEC-xxx`, `SPEC-yyy`) appear
  in samples and are fine.
- **Clean already.** No page contains Liquid delimiters, an owner email or
  surname, or a macOS or Windows support claim. Every acceptance report has
  a blank `Signed-off-by:` line.
- **Consumer link rule.** `scripts/installed-diagnostics.test.sh` requires
  every relative link in the twelve consumer-copied pages to resolve inside
  the consumer's `docs/nogging/`. Those pages can therefore link relatively
  only to each other. `scripts/packed-token-usage.test.sh` requires the
  installed copy to be byte-identical.

**Tests that pin doc text.** These suites assert strings in docs pages, so a
rewrite must keep the strings or move the assertion in the same commit:
`readme-structure`, `nogging-identity`, `security-docs`, `planning-docs`,
`runtime-guidance-docs`, `session-delivery-docs`, `installation-docs`,
`docs-herdr-foreign-note`, `install-surface-consistency`, `release-pins`,
`package-publication`, `commands`, `compatibility`, `model-selection`,
`session-observability`, `cutover-checklist`, `packed-token-usage` and
`installed-diagnostics` (all `scripts/<name>.test.sh`). `scripts/ci-security-gates.sh links`
checks that every relative Markdown link resolves inside the repository. It
does not know which files are published.

**Brand.** The assets in `docs/brand/` use Poppins (wordmark bold; tagline
Medium with wide tracking), dark green `#22301F`, sage `#7E9C7E` and
`#97B190`, grey-green `#4A5B4C` and off-white `#F6F6F4`. The mark is drawn
from rounded vertical studs crossed by horizontal noggings. It is simple
enough to redraw as SVG. Measured WCAG contrast on `#F6F6F4`: `#22301F` 12.9,
`#4A5B4C` 6.7, `#7E9C7E` 2.8, `#97B190` 2.2. Sage therefore fails as text in
light mode. Measured on a dark ground `#141B13`: `#97B190` 7.5, `#7E9C7E` 5.8.

## Goals / Non-Goals

**Goals:**

- The site looks like Nogging in light and dark mode, on a phone and on a
  desktop, and meets WCAG 2.1 AA contrast.
- A first-time visitor learns on the landing page what Nogging is and how to
  install it. A user finds every guide through a six-section sidebar and
  through search.
- Internal material is off the site. Maintainer material is clearly
  separate.
- User pages are accurate and consistent with each other and with the
  README. They are pinned, and they still read well as plain Markdown on
  GitHub.
- The no-workflow GitHub Pages build stays. An offline suite in
  `scripts/test` guards the site's invariants in the existing CI.

**Non-Goals:** see `proposal.md`. In short: no workflow, no other generator,
no publishing from `develop`, no demo, no npm, no `llms.txt`, no analytics,
no new brand artwork, no from-scratch rewrite of the deep reference pages,
and no tag.

## Decisions

### 1. Shared discipline for every task

- **Offline tests.** Every new or changed suite runs on GitHub runners with
  `python3 -I` and no Ruby, Docker, network, `bd` or Dolt. It sources
  `scripts/lib/test-env.sh`, and `scripts/test` picks it up. Docker and
  network are allowed only in `scripts/docs-site-build`, which is a
  maintainer tool and not part of `scripts/test`.
- **No new runtime dependency.** The package `files` list gains nothing.
  `scripts/package-manifest.test.sh` and `scripts/public-tree.test.sh` stay
  green. Site assets live only under `docs/` and are not shipped.
- **Plain Markdown.** Pages that exist before this change get no front
  matter (Decision 4). Only `docs/index.md`, the six section overview pages
  and `docs/404.md` may carry front matter.
- **Pinned strings stay pinned.** A suite from the list in *Context* may be
  edited only to follow a moved heading or a moved string, in the same commit.
  It is never weakened. The reviewer checks this.
- **Shipped pages.** Edits to the twelve consumer-copied pages are allowed,
  and they reach consumers. Such a page links relatively only to another
  consumer-copied page. It links any other docs page by its absolute site
  URL (`https://jome92.github.io/nogging/<name>/`), and any repository file
  by its absolute GitHub URL. This keeps `installed-diagnostics.test.sh`
  green and the links working on the site, on GitHub and in a consumer
  copy.
- **Facts are checked against the code.** A consistency edit that states
  behaviour checks it against the shipped source first: launch profiles
  under `.nogging/launch-profiles/`, `scripts/nogg` and its `--help`. Where
  code and docs disagree, the docs follow the code, and the Lead records a
  discovery only if the code looks wrong.
- **Privacy and claims.** No email address anywhere. The owner appears only
  as Jonas or `JoMe92`. Linux is the only supported host. Antigravity and the
  herdr backend are marked experimental wherever they are named. No page
  claims npm publication.
- **Pins.** Install pins stay `v3.1.1` until the next release preparation.
  This change does not bump the version.
- **Look before release.** Every UI task (BDS-002, BDS-003, BDS-014) saves
  screenshots with `scripts/docs-site-build --screenshots <dir>` and records
  the directory in its Bead note. The Orchestration Agent forwards them to
  the Product Owner. The live site changes only at the next release, so this
  is the Product Owner's preview.

### 2. Technical route: Just the Docs on the existing Pages build

Options considered:

| Option | Gains | Costs | Verdict |
| --- | --- | --- | --- |
| Keep Cayman, add CSS | Smallest diff | No sidebar, search or dark mode. The header layout is fixed, so the brand can only be approximated. | Rejected |
| **Just the Docs as `remote_theme`, pinned** | Sidebar with sections, breadcrumbs, client-side search from a self-hosted index, responsive layout, copy-code buttons, callouts, heading anchors, custom colour schemes, include hooks for head, header and footer. MIT, actively released (v0.12.0, 2026-01-23). Builds with the Pages gem. No workflow. | The theme is fetched at build time; a pinned tag keeps that reproducible, and a failed build leaves the last good site live. Runtime dark-mode switching needs a small script. It must be re-skinned so it does not look like a stock theme. libsass limits Sass features. | **Chosen** |
| Custom Jekyll layouts and CSS, no theme | Full control and no theme dependency | Navigation, search, mobile menu and accessibility must be built and maintained here, for a product that is not a website. | Fallback |
| MkDocs Material with a Pages Actions workflow | Best-known docs UX | In maintenance mode since 2025-11-05, with about twelve months of committed critical fixes, now ending. MkDocs itself is unmaintained. It adds a Python toolchain and a workflow file (needs the `workflow` token scope). Pages would have to switch to "GitHub Actions" as its source. That reverses the Product Owner's no-workflow decision. | Not recommended |
| Zensical, Docusaurus, Starlight, VitePress | Modern generators | Each needs a workflow and a new toolchain. Zensical's feature parity is still incomplete. | Not recommended |

Just the Docs is pinned as `remote_theme: just-the-docs/just-the-docs@v0.12.0`
(or the newest release at implementation time that builds on the Pages gem;
the Lead records the tag and the reason). Plugins: `jekyll-remote-theme`,
`jekyll-include-cache` (the theme needs it), `jekyll-seo-tag`,
`jekyll-sitemap`, `jekyll-relative-links`, `jekyll-optional-front-matter` and
`jekyll-titles-from-headings`. `jekyll-readme-index` is dropped because
`docs/index.md` becomes the root. `titles_from_headings.strip_title` becomes
`false`, because Just the Docs does not render `page.title` above the content
and the page's own H1 must stay.

**Fallback.** TASK-BDS-001 begins with a build spike on the Pages gem. If
the pinned theme cannot build there, or cannot run search or the custom
scheme, the Lead records a blocking discovery. A planning session then
switches to custom layouts. The IA, metadata, test and content decisions
below are independent of the theme.

**Recommendation to the Product Owner, not part of this change:** an
optional CI job that runs `scripts/docs-site-build` on pull requests that
touch `docs/`. It would catch a broken Pages build before release. It needs a
workflow edit, which needs the `workflow` token scope (the Orchestration
Agent can push it over SSH). Without it, `scripts/docs-site.test.sh` covers
the common breakages offline. The release procedure runs the full build
(Decision 10).

### 3. Information architecture

Flat, readable URLs: `permalink: pretty`, so `docs/<name>.md` is served at
`/nogging/<name>/`. File names stay unchanged. The README, `AGENTS.md`,
specs, tests and the installer manifest all name them. The site has been live
for one day, so the old `.html` URLs get no redirects.

Sidebar sections, in order, with their pages in order. The overview page of
each section is a new site-only page with a one-paragraph intro, and the
theme renders its child list.

| Section (overview page) | Pages | Audience |
| --- | --- | --- |
| Getting started (`getting-started.md`) | `installation.md`, `compatibility.md`, `first-change.md` (new), `faq.md` | user |
| Concepts (`concepts.md`) | `vision-and-architecture.md`, `operating-model.md`, `worktree-workflow.md`, `security-model.md`, `comparison.md` | user |
| Guides (`guides.md`) | `using-with-claude-code.md` (new), `using-with-codex.md`, `using-with-pi.md`, `using-with-antigravity.md` (experimental), `running-work-in-sessions.md`, `using-with-herdr.md` (experimental), `model-selection.md`, `agent-identities.md` | user |
| Operations (`operations.md`) | `troubleshooting.md` (new), `failure-recovery.md`, `usage-limits.md`, `token-usage.md` | user / operator |
| Reference (`reference.md`) | `commands.md` (new), `configuration.md` (new), `glossary.md` (new), `architecture.md` | user / advanced |
| Project & maintainers (`project.md`) | `releasing.md`, `acceptance.md`, `project-identity.md`; external links to Contributing, Code of Conduct, Security policy, Changelog and Releases on GitHub | maintainer |

Header links: GitHub repository, Releases and Discussions. The landing page
`docs/index.md` is excluded from the sidebar. `docs/404.md` is a branded
not-found page with search and a link home.

**Excluded from the site** (`exclude:` in `_config.yml`; the files stay in
the repository and on GitHub): `README.md`, `acceptance/`,
`acceptance-report-template.md` and `public-cutover.md`. `docs/README.md`
stays the GitHub folder index. It is regrouped under the same six headings,
plus an *Internal* group for the excluded material. Its private-repository
link is replaced with a sentence that has no link. The public-cutover entry
says that the checklist is historical: the project went public with v3.0.0.

### 4. Page metadata lives in `_config.yml` defaults

Just the Docs places a page through page variables (`parent`, `nav_order`,
`nav_exclude`, `search_exclude`), and `jekyll-seo-tag` reads
`description`. These are set per file in `docs/_config.yml` `defaults` with
`scope.path` equal to the file name. This keeps the Markdown free of front
matter on GitHub and in consumer copies. It also keeps one place to review
the whole IA. Titles come from each page's H1 through
`jekyll-titles-from-headings`. A `title` default is set only where the H1
would make a poor sidebar label, and the H1 itself stays. Several parallel
tasks add `defaults` blocks, so each task appends its own blocks in IA order
and rebases on conflict (see *Risks*).

### 5. Brand system

- **Colour tokens** live in `docs/_sass/color_schemes/nogging.scss` (light)
  and `nogging-dark.scss` (dark). Each switchable scheme gets its
  `docs/assets/css/just-the-docs-<scheme>.scss` entry. Starting values, all
  checked for contrast:

  | Token | Light | Dark |
  | --- | --- | --- |
  | page background | `#F6F6F4` | `#141B13` |
  | sidebar and code background | `#E9EDE6` | `#1D261C` |
  | body text | `#22301F` (12.9:1) | `#E6EBE3` (14.5:1) |
  | secondary text | `#4A5B4C` (6.7:1) | `#B8C9B3` (10.1:1) |
  | link | `#3D5C3A` (7.0:1), underlined | `#A9C3A2` (9.2:1), underlined |
  | accents (borders, active nav bar, mark, focus ring) | `#7E9C7E`, `#97B190` | `#7E9C7E`, `#97B190` |

  Sage is never body text or link text in light mode (2.8:1 and 2.2:1).
  The ui-ux-designer may adjust values, but every text, link and code pair
  must stay at 4.5:1 or above. `scripts/docs-site.test.sh` reads the
  token pairs from the scheme files and recomputes the ratios.
- **Theme selection.** A small inline script in `_includes/head_custom.html`
  picks the scheme before first paint. It uses the stored choice first, then
  `prefers-color-scheme`, and calls the theme's `jtd.setTheme`. Every
  storage access sits in `try/catch`. A toggle button in the header switches
  the scheme and has an accessible name and state. With JavaScript off, the
  light scheme renders.
- **Type.** Poppins 400, 500, 600 and 700 as latin-subset `woff2` under
  `docs/assets/fonts/`, with `OFL.txt`, loaded with `font-display: swap`.
  Headings, navigation, buttons and the wordmark use Poppins. Body text uses
  a system UI stack and code uses a system monospace stack, both chosen for
  long-form readability. The font source and version are recorded in
  `THIRD_PARTY_NOTICES.md`.
- **Mark and icons.** `docs/assets/images/nogging-mark.svg` redraws the
  existing mark: the studs in `#22301F`, the noggings in sage. It has a
  dark-mode variant. The header shows the mark and the wordmark "nogging" in
  Poppins Bold. Favicons come from the mark: `favicon.ico` (16/32), a 180 px
  `apple-touch-icon.png` and an SVG favicon.
- **Components.** Code blocks get the code background, a thin sage left
  rule, a scroll area and the theme's copy button. Tables scroll inside
  themselves on a phone. Callouts (note, warning, experimental) use the
  scheme colours. Focus outlines are always visible.
- **Footer.** "Nogging is released under the ISC License", links to GitHub,
  the Security policy and Discussions, and the version from
  `docs/_data/install.yml`. It does not copy the `LICENSE` copyright line.
- **Third-party notices** (Product Owner addition at plan review).
  `THIRD_PARTY_NOTICES.md` ships in the package. Today it only points
  upstream for the MIT-licensed skill material that the installer
  distributes. The task adds the full MIT licence text with each upstream
  copyright line: for the OpenSpec skills under `.agents/skills/openspec-*`
  (`Copyright (c) 2024 OpenSpec Contributors`, upstream
  `https://github.com/Fission-AI/OpenSpec`) and for the Beads skill under
  `.agents/skills/beads` (`Copyright (c) 2025 Beads Contributors`, upstream
  `https://github.com/gastownhall/beads`). These lines were read from both
  upstream `LICENSE` files on 2026-10-27; the implementer re-reads them
  before copying. The stale `https://github.com/steveyegge/beads` link (it
  now redirects) becomes the `gastownhall/beads` URL. The Gas Town link
  `steveyegge/gastown` in the README and `docs/project-identity.md` is a
  different repository and stays. `scripts/legal.test.sh` then requires
  both copyright lines and the MIT permission sentence, and rejects the old
  Beads link.

### 6. Landing page

`docs/index.md` uses a site-only `home` layout inside the theme, without the
sidebar. The order follows the README's first screen, so the two surfaces do
not diverge in message:

1. Hero: mark, wordmark, tagline, one to three sentences on what Nogging is
   (taken from the README intro), and two buttons: *Get started* (the
   installation guide) and *View on GitHub*.
2. Quick start: the pinned bootstrap command and the `npx … init` command,
   rendered from `docs/_data/install.yml` with copy buttons. Then a link to
   *Your first change*.
3. Why Nogging: the five problem/solution pairs from the README *Why
   Nogging?*, as cards.
4. How it works: the communication model and daily workflow diagrams, each
   with a caption and descriptive alt text. Links lead on to Concepts.
5. Works with: Claude Code, Codex and Pi, plus Antigravity (experimental).
   Then "Linux only", with a link to the compatibility matrix.
6. Safety: one sentence and a link to the security model.
7. Community: Releases, Discussions, Contributing.

### 7. Install commands: one source per surface

`docs/_data/install.yml` holds `tag`, `bootstrap` (the full `curl … | bash`
line) and `init` (the `npx github:JoMe92/nogging#<tag> init --no-systemd`
line). The landing page and the footer render from it. `README.md` and
`docs/installation.md` keep their literal commands, so they read well on
GitHub. `scripts/docs-site.test.sh` checks that the three surfaces carry
byte-identical bootstrap and init lines. It also checks that no other
published page carries the pinned bootstrap or init line: those pages use
the `<tag>` placeholder or link the installation guide. `scripts/release-pins.test.sh`
checks the data file's tag and every `github:JoMe92/nogging` /
`raw.githubusercontent.com/JoMe92/nogging/` reference in every `docs/*.md`
(see the `release-distribution` delta). `docs/releasing.md` step 4 names the
data file. *Your first change* and the guides link to the installation guide
and do not repeat the install sequence.

### 8. Content plan

**New pages.**

- `first-change.md`, *Your first change*: a guided walkthrough from a ready
  repository to a closed first Bead. It covers `doctor`, `/plan` or the
  supervised planner, `bd ready`, launching a Lead, watching it, reviewing
  the PR, `sync --now` and `/discovery-review`, and says at each step what
  you should see. It goes deeper than the README Quick Guide, links the
  guides for detail, and does not repeat installation.
- `using-with-claude-code.md`: a guide for the default agent, built like the
  Codex and Pi guides. It covers what is installed (`.claude/` commands,
  settings, the `PreToolUse` guard, the six specialists), the slash commands
  including `/orchestrate`, delegation and co-author trailers, authority
  levels and effort selection, the Orchestration Agent (Claude-only) with
  Remote Control, and known limitations.
- `troubleshooting.md`: symptom → cause → fix for the common failures. These
  include a `doctor` FAIL or WARN line, a planning lock that is already held,
  an unreachable shared Dolt server, a sandboxed or missing tmux server, a
  session that stalls or fails, a usage limit, a skipped or failing sync, a
  refused worktree cleanup and a half-applied rebase. Each fix links the
  deep procedure in `failure-recovery.md` by heading anchor.
- `commands.md`: one `##` heading per top-level `nogg` subcommand. Each has a
  `###` heading per sub-subcommand where one exists (`worktree`, `pr`,
  `orchestrator`, `session`), its purpose, the common forms, the role that
  uses it, and a link to the guide that explains it. It replaces neither the
  sessions guide nor the operating model; their partial tables link to it.
- `configuration.md`: every `.nogging/config.json` key, with its type,
  default and effect, grouped as sync, sessions, models, usage, multi-machine
  and agent state. The keys are those in `templates/nogging-config.json`, the
  keys read through `scfg()` in `scripts/nogg` and `scripts/lib/`, and the
  documented blocks (`usage_gate`, `tier_overrides`, `multi_machine`,
  `sync_protected_branches`).
- `glossary.md`: one-line definitions with a link each. Terms: Product
  Owner, Planning Agent, Lead Agent and Main Worker, specialist,
  Orchestration Agent, change, task ID, Bead, claim, discovery, evidence
  note, materialize, sync, writer (planning, sync), sentinel and fence,
  planning lock, worktree record, LIMBO, tier, authority level (restricted,
  trusted, full access), command floor, acceptance report.

**Existing pages, by action.**

| Action | Pages and the specific defects to fix |
| --- | --- |
| Rewrite for today's state | `vision-and-architecture.md`: remove the v1.0.0 roadmap and "Planned" markers, the German heading, `SPEC-fc4`, `TASK-SYNC-006` and the wrong workflow name; pin the installer; keep the H1. `usage-limits.md`: document `nogg usage` and the usage gate first, move raw probe detail into a short appendix, drop the owner's time zone. |
| Restructure | `operating-model.md`: add an intro, fix the empty *Acceptance* heading, introduce "Main Worker" once as the role name of the Lead Agent, correct the trusted-profile facts, link `commands.md` from its session table. `docs/README.md`: regroup for GitHub (Decision 3). |
| Consistency edit (facts, IDs, links, intro) | `architecture.md` (W5, W6, `SPEC-7ec`, "in this repository", persona count, version mentions), `security-model.md` (`plan-end` before worktree retirement, Antigravity experimental, the orphan paragraph, decision and issue references), `worktree-workflow.md` (reconcile "never self-merge" with `--full-access`), `running-work-in-sessions.md` (socket `nogging`, trusted Codex network, contradictory deny lists, the Antigravity source contradiction, a label on the section about this repository's own configuration, the test-isolation note placed inside the usage-gate section), `failure-recovery.md` (PR and issue numbers as context, "this repo's Dolt server", maintainer-only recipes labelled), `using-with-codex.md` (unpinned installer, broken sentence near the prompts link step, "in this change" wording), `using-with-pi.md` (unpinned installer, `docs/nogging/` paths for consumers), `using-with-antigravity.md` ("experimental" in the H1 and intro, `blob/develop` links), `using-with-herdr.md` (internals pointer to architecture), `agent-identities.md` (the implemented credential helper), `model-selection.md` (internal planning references, version drift from the matrix), `project-identity.md` ("first public release" wording, socket name, Antigravity experimental) |
| Light edit (intro, links) | `installation.md` (the payload table lists twelve reference docs and an Antigravity row, four hooks, the target needs `develop` and `origin`), `compatibility.md` (`blob/develop` links), `faq.md` and `comparison.md` (absolute links for `README.md` and `SECURITY.md`; FAQ answers consistent with the README FAQ), `token-usage.md`, `acceptance.md` ("end-to-end-acceptance change" and W5 wording), `releasing.md` (site steps, Decision 10) |
| Exclude from the site, keep in the repository | `acceptance/`, `acceptance-report-template.md`, `public-cutover.md` (its content is unchanged; `cutover-checklist.test.sh` keeps passing) |

**Rules for every user page:**

- the first paragraph says what the page covers and who it is for;
- no claim contradicts the README, the compatibility matrix or the code;
- no real Bead or task ID, design decision number, weakness code, or PR or
  issue number is given as context (placeholders in samples stay; a PR link
  in a changelog-like note on a maintainer page is fine);
- the installer is never named without a tag;
- no link points to a private repository;
- links follow the shipped-page rule of Decision 1;
- dates and versions in status text are current or removed;
- terms follow `glossary.md`.

**Deliberate duplication stays.** `planning-docs.test.sh` keeps the planning
sequence identical in nine places. Those copies stay, and the consistency
pass fixes only the one that contradicts the others (`security-model.md`).
Other repeated procedures (install, update and remove; resume; orchestrator
details) keep one full copy. In the guide, operating model, failure recovery
or installation page that owns it, the copy stays full. Elsewhere the text is
shortened to a sentence and a link, unless a test pins the text.

### 9. Search metadata

`jekyll-seo-tag` emits the title as "<page title> | Nogging", plus the
description, canonical URL, Open Graph and Twitter tags. The defaults are
`image: /brand/nogging-social-card.png` and `twitter.card:
summary_large_image`. `logo` is the square card. `lang: en`. `social` names
only the GitHub repository. `author` is "Jonas (JoMe92)" or is left out.
`jekyll-sitemap` writes `sitemap.xml`. A static `docs/robots.txt` allows
everything and names the sitemap. The 404 page carries `sitemap: false`.
There is no `llms.txt`. Every published page gets a description of at most
160 characters, unique across the site, written for a searcher rather than
copied from the first sentence.

### 10. Publishing flow

The site keeps building from `main:/docs`. Pros: the site documents exactly
the release that the pinned install commands install, with no workflow and
no second branch to protect. Cons: improvements wait for a release. When this
change lands on `develop`, the Product Owner decides whether to cut a
docs-only patch release (for example v3.1.2) so the new site goes live, or
to wait for the next feature release (open question in the plan summary).
`docs/releasing.md` gains two steps: before the tag, run
`scripts/docs-site.test.sh` and `scripts/docs-site-build`; after the release,
open the live landing page and check that its install command names the new
tag. The README *Documentation* section links the site.

### 11. Verification

- **`scripts/docs-site.test.sh`** (offline, in `scripts/test`). It parses
  `docs/_config.yml` (a minimal YAML subset reader, or a strict line parser;
  no PyYAML dependency) and asserts:
  - a pinned `remote_theme`, allow-listed plugins only, and no `.rb` files;
  - every published Markdown page has a section placement or `nav_exclude`,
    a unique description of at most 160 characters, and no front matter
    unless it is site-only;
  - the exact exclusion set;
  - no relative link from a published page to an excluded file or outside
    `docs/`;
  - no Liquid delimiters outside code;
  - no email address and no owner surname;
  - landing-page claims (Antigravity experimental, no macOS or Windows
    support);
  - no real tracking IDs outside Project & maintainers (placeholder
    allow-list);
  - the install-line equality of Decision 7;
  - `commands.md` headings cover `scripts/nogg --help`, and
    `configuration.md` covers every key in `templates/nogging-config.json`
    and every literal `scfg("<key>")`;
  - the Antigravity and herdr guides say "experimental" in the H1 or first
    paragraph;
  - the contrast ratios of Decision 5;
  - every image in a published page has alt text, and every referenced asset
    exists.

  Each task adds the assertions for its own area, so the suite grows with
  the change.
- **`scripts/docs-site-build`** (maintainer tool, Docker and network). It
  builds in a throwaway `ruby` container with the `github-pages` gem version
  from `pages.github.com/versions.json`, into a temporary directory. It
  checks every internal link and anchor in the HTML. `--serve` previews on
  localhost. `--screenshots <dir>` captures the landing page, one guide and
  the 404 page at 375×812 and 1280×800 in light and dark, plus an automated
  accessibility scan (axe-core) with no serious or critical finding, in a
  pinned Playwright container. It never writes into the repository.
- **Existing gates.** `scripts/ci-security-gates.sh links`, the doc-pinning
  suites, `scripts/release-pins.test.sh` and `./scripts/nogg validate` stay
  green in every task.

## Dependencies and parallel lanes

`A ← B` means A depends on B (`bd dep add A B`). The edges are explicit, not
inferred from task order. Branches follow `<type>/branded-docs-site`. Each
lane owns one prefix. Tasks in the same lane run one after another, and each
deletes its integrated branch before the next allocates it. Where two tasks
share a lane and have no content dependency, an explicit *lane* edge
serializes them, because they would otherwise collide on the branch name.
Before allocating a dependent worktree, a Lead verifies that every
prerequisite execution commit is integrated into `develop`. Bead closure
alone is not enough.

| Task | Tier | Depends on | Lane | Main files (ownership) | Specialists |
| --- | --- | --- | --- | --- | --- |
| BDS-001 theme, IA, site suite, build tool | standard | — | `feat/` | `docs/_config.yml`, six section pages, `docs/404.md`, `docs/README.md`, `scripts/docs-site.test.sh`, `scripts/docs-site-build`, `scripts/cutover-checklist.test.sh` only if a path string moves | frontend-engineer |
| BDS-002 brand styling | complex | 001 | `feat/` | `docs/_sass/`, `docs/_includes/`, `docs/assets/` (fonts, SVG, favicons, toggle), `THIRD_PARTY_NOTICES.md`, `scripts/legal.test.sh`, `--screenshots` in the build tool | **UI:** ui-ux-designer → frontend-engineer |
| BDS-003 landing page and install source | standard | 002 | `feat/` | `docs/index.md`, `docs/_layouts/home.html`, `docs/_data/install.yml`, `scripts/release-pins.test.sh` (data file), `docs/releasing.md` step 4, `README.md` *Documentation* | **UI:** ui-ux-designer → frontend-engineer |
| BDS-004 search metadata | standard | 001 | `chore/` | `docs/_config.yml` (site keys, descriptions), `docs/robots.txt` | — |
| BDS-005 getting started | standard | 001 | `docs/` | new `docs/first-change.md`, `docs/installation.md`, `docs/compatibility.md`, `docs/faq.md`, `docs/comparison.md` | — |
| BDS-006 Claude Code guide | standard | 005 (lane) | `docs/` | new `docs/using-with-claude-code.md` | — |
| BDS-007 command reference | standard | 001 | `test/` | new `docs/commands.md` | — |
| BDS-008 troubleshooting | standard | 006 (lane), 007, 011 | `docs/` | new `docs/troubleshooting.md` | — |
| BDS-009 concepts consistency, pin and ID checks | standard | 001 | `fix/` | `vision-and-architecture.md`, `operating-model.md`, `architecture.md`, `worktree-workflow.md`, `security-model.md`; the unpinned lines in `using-with-codex.md` and `using-with-pi.md`; docs-wide pin check in `scripts/release-pins.test.sh`; ID check in the site suite | — |
| BDS-010 agent guides consistency | standard | 009 | `fix/` | `using-with-codex.md`, `using-with-pi.md`, `using-with-antigravity.md`, `using-with-herdr.md`, `agent-identities.md`, `model-selection.md` | — |
| BDS-011 sessions and recovery consistency | standard | 010 | `fix/` | `running-work-in-sessions.md`, `failure-recovery.md` | — |
| BDS-012 operations and maintainer pages | standard | 004 (lane) | `chore/` | `usage-limits.md`, `token-usage.md`, `project-identity.md`, `acceptance.md` | — |
| BDS-013 configuration reference and glossary | standard | 007 | `test/` | new `docs/configuration.md`, new `docs/glossary.md` | — |
| BDS-014 final verification and release steps | standard | 003, 008, 012, 013 | `test/` | `docs/releasing.md`, fixes found by the full build, evidence | **UI:** test-runner, code-reviewer |

Why each edge exists:

- **002 ← 001, 003 ← 002.** Styling needs the theme in place. The landing
  page uses the scheme, fonts, mark and buttons from 002.
- **004, 005, 007, 009 ← 001.** Each adds pages or `defaults` blocks in the
  structure that 001 creates, and each extends the site suite that 001
  creates.
- **010 ← 009, 011 ← 010.** All three run the docs-wide checks that 009
  introduces, and they share the `fix/` lane. 010 and 011 touch pages that
  link to each other.
- **006 ← 005, 012 ← 004 (lane).** These are shared prefixes with no content
  dependency.
- **008 ← 007, 011.** The troubleshooting page links `commands.md` headings
  and `failure-recovery.md` anchors. Both must be final first. It also
  follows 006 in the `docs/` lane.
- **013 ← 007.** The glossary and configuration reference link
  `commands.md`, and they continue the `test/` lane.
- **014 ← 003, 008, 012, 013.** It verifies the finished site and edits
  `docs/releasing.md`. Every other task is reached transitively: 001, 002
  through 003; 004 through 012; 005, 006, 007, 009, 010, 011 through 008;
  and 013 directly.

The lanes run as follows:

- **After 001:** 002 (`feat/`), 004 (`chore/`), 005 (`docs/`), 007 (`test/`)
  and 009 (`fix/`) can run at once.
- **Spines:** `feat/` 002 → 003. `chore/` 004 → 012. `docs/` 005 → 006 →
  008. `fix/` 009 → 010 → 011. `test/` 007 → 013 → 014.

**Cross-change overlap, no edge.** Open acceptance tasks of other changes
(TASK-HPS-007, TASK-HSS-008) write `docs/acceptance/<date>-*.md`. That
directory is excluded from the site, so they do not conflict with this
change beyond a rebase.

## Risks / Trade-offs

- **Remote theme at build time.** A GitHub outage or a removed tag fails the
  Pages build. The last good deployment stays live. The tag is pinned, and
  the release procedure's local build catches a broken pin before release.
- **Theme upgrades.** Just the Docs changed its footer markup in v0.11 and
  v0.12. Overrides are kept to `head_custom`, `header_custom`,
  `footer_custom`, the colour schemes and `_sass/custom/`. Full template
  overrides are avoided, so a later theme bump stays small.
- **Dark-mode flash.** Swapping the stylesheet after first paint flashes the
  light scheme. The head script runs before the theme stylesheet is applied,
  and 002's screenshots prove that dark mode loads without a flash.
- **`defaults` merge conflicts.** Seven tasks append blocks to
  `docs/_config.yml`. Blocks are appended in IA order, one block per file.
  The second branch to land rebases with `nogg worktree rebase`. That is
  cheap and mechanical.
- **Shipped-page edits reach consumers.** Consistency edits to the twelve
  consumer-copied pages arrive at the next `update`. They are content
  improvements with the same file names. Under the link rule of Decision 1,
  a consumer copy reaches the new pages through absolute site URLs. Those
  URLs show the released documentation, which can be newer than the
  consumer's installed version. That is accepted, because the pages name
  their version where it matters.
- **Content drift between README and landing page.** The landing page reuses
  the README's intro, *Why Nogging?* and support claims. The install lines
  are guarded by a test. The prose is guarded by review and by the claim
  checks in the site suite.
- **Visible only after release.** The Product Owner sees the new site
  through the screenshots in 002, 003 and 011 until the next release
  reaches `main`.
- **Time.** Fourteen Lead sessions. 002 is the largest. It is rated
  complex, because the Product Owner's main complaint is the look. 011
  covers about 1,600 lines across two pages, but it fixes listed defects
  rather than restructuring.
- **Scope pressure on the deep pages.** The audit suggests splitting
  `running-work-in-sessions.md`. This change does not split it. It only
  fixes contradictions and labels the maintainer-only parts. A split can be
  a later change once `commands.md` and `configuration.md` exist.
