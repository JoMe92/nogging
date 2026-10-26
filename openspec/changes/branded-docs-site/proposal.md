## Why

The documentation site at https://jome92.github.io/nogging/ went live on
2026-10-26 (Bead SPEC-8klc). It looks unfinished. The Product Owner's
request of the same day: the site must match the project's look, and it
must be clean, well-structured documentation, because right now it says
"basically nothing but nonsense".

What a visitor sees today, verified on 2026-10-26:

- **Off-brand.** The stock `jekyll-theme-cayman` theme has a teal and green
  gradient header that has nothing to do with the Nogging brand assets in
  `docs/brand/` (Poppins, dark green, sage, off-white). The site has no
  logo, wordmark or favicon. It has no dark mode.
- **No landing page.** The home page is `docs/README.md`, an index table
  written for maintainers ("An index of everything under `docs/`"). It does
  not say what Nogging is, what problem it solves or how to start. It has no
  diagram and no link to install, releases or Discussions.
- **No structure.** Every page is a raw Markdown dump under one header. There
  is no sidebar, no breadcrumbs, no section grouping and no search.
- **Internal material looks like user documentation.** All of `docs/` is
  published: dated acceptance reports with raw evidence, the report
  template, an Antigravity contract investigation, the release procedure and
  a public-cutover checklist that still calls itself "not yet run". Visitors
  see them on a par with the user guides.
- **Content gaps and drift.** There is no guide for Claude Code, the default
  agent. There is no "first change" walkthrough, no troubleshooting entry
  page, no glossary, no configuration reference and no command reference
  for the 20 `nogg` subcommands. Shipped pages contradict each other and the
  code, for example on what the trusted profile allows. Some pages
  name the installer without a pinned tag. Some pages link to a private
  repository or to repository files outside `docs/` that do not exist on the
  site. Some carry internal Bead or task IDs that a visitor cannot decode.

## What Changes

- **A branded theme on the existing no-workflow build.** The site moves from
  Cayman to the Just the Docs theme, pinned to an exact release, as a GitHub
  Pages `remote_theme`. GitHub Pages keeps building `main:/docs` with its
  own Jekyll. No build workflow is added. A Nogging colour scheme for light
  and dark is derived from the brand palette. Poppins is self-hosted. The
  site gets an SVG mark and wordmark, a favicon set, a theme toggle that
  follows the operating system, readable code blocks with a copy button, a
  branded 404 page, and a layout that works on phones. Body text and links
  meet WCAG 2.1 AA contrast. The page makes no third-party request when
  someone views it: no CDN, no web fonts from Google, no analytics.
- **A real landing page.** A site-only `docs/index.md` says what Nogging is
  and which problem it solves. It shows how Nogging works with the existing
  diagrams and gives a pinned quick start. It links to installation, GitHub,
  releases and Discussions. Support claims stay those of the compatibility
  matrix: Linux only, Antigravity experimental.
- **An information architecture.** The sidebar has six sections: Getting
  started, Concepts, Guides, Operations, Reference, and Project &
  maintainers. The maintainer section is clearly separate and comes last.
  Internal material (acceptance reports and their template, the Antigravity
  investigation, the public-cutover checklist) is excluded from the site
  and stays in the repository. `docs/README.md` becomes the GitHub-only
  folder index, grouped like the site. Page URLs become flat, readable
  paths (`/nogging/installation/`).
- **Markdown stays plain.** Existing pages get no front matter. Fourteen of
  them ship in the package, and the installer copies twelve of those into
  consumer repositories. Navigation,
  titles and descriptions live in `docs/_config.yml` defaults. Links work
  both on GitHub and on the site. A link to a repository file outside
  `docs/` becomes an absolute GitHub URL.
- **Content a visitor needs.** New pages: *Your first change* (a guided
  walkthrough), *Using Nogging with Claude Code*, *Troubleshooting*, a
  *Command reference*, a *Configuration reference* and a *Glossary*. Every existing user page gets an accuracy and
  consistency pass. It removes stale facts, internal IDs, private-repository
  links and unpinned installer references, and it gives each page an intro
  that says who the page is for.
- **One install source per surface, pinned.** The landing page reads its
  install commands from `docs/_data/install.yml`. A test proves that these
  commands are byte-identical to the README and `docs/installation.md`. The
  release-pin rule now also covers that data file and every installer
  reference in a published page.
- **SEO and metadata.** Every published page has its own title and a
  description of at most 160 characters. Canonical URLs, Open Graph and
  Twitter cards (both existing social cards), a sitemap and `robots.txt` are
  in place. `llms.txt` stays out, by Product Owner decision.
- **Verification.** A new offline suite, `scripts/docs-site.test.sh`, runs in
  `scripts/test` and therefore in the existing CI. It checks configuration,
  navigation coverage, exclusions, links, metadata, front matter, privacy
  and colour contrast. A new `scripts/docs-site-build` builds the site
  locally with the GitHub Pages gem in a container, then checks every
  internal link and anchor in the output. The final task records visual
  evidence at phone and desktop width in light and dark mode, plus an
  automated accessibility check.
- **Complete third-party notices.** `THIRD_PARTY_NOTICES.md` gains the
  full MIT licence texts with copyright lines for the OpenSpec and Beads
  skill material the installer distributes, alongside the new Poppins and
  Just the Docs entries. The stale Beads link points at
  `gastownhall/beads`. The legal suite checks both.

## Non-Goals

- A GitHub Actions build or deploy workflow, or another generator
  (MkDocs Material, Zensical, Docusaurus). Design Decision 2 compares them.
  Changing the Product Owner's no-workflow decision is out of scope; a CI
  site-build check is listed as an optional follow-up.
- Publishing the site from `develop`. The site keeps building from `main`,
  so it matches the released version that the pinned install commands name.
- A demo GIF or video, npm publication, `llms.txt`, analytics or cookies.
- New brand artwork beyond vector versions of the existing mark and
  wordmark. The existing PNG diagrams and social cards are reused as they
  are.
- Rewriting the deep reference pages (`architecture.md`,
  `running-work-in-sessions.md`, `failure-recovery.md`) from scratch. They
  get the consistency pass, not a new structure.
- Changing repository visibility, Pages settings or the release cadence.
  Tagging and releasing stay with the Orchestration Agent and the Product
  Owner.

## Impact

- Site: `docs/_config.yml`, new `docs/index.md`, six section overview pages,
  `docs/404.md`, `docs/_sass/`, `docs/_includes/`, `docs/assets/` (fonts,
  SVG mark, favicons, a small theme-toggle script), `docs/_data/install.yml`.
- Content: new `docs/first-change.md`, `docs/using-with-claude-code.md`,
  `docs/troubleshooting.md`, `docs/commands.md`, `docs/configuration.md`,
  `docs/glossary.md`. Edits to the existing
  user pages and to `docs/README.md`. Fourteen `docs/*.md` pages ship in the
  package, and the installer copies twelve of them to consumers verbatim, so
  their edits reach consumers on the next `update`.
- Repository: `README.md` (*Documentation* section links the site),
  `THIRD_PARTY_NOTICES.md` (Poppins, SIL OFL 1.1; Just the Docs, MIT; full
  MIT texts with copyright lines for the OpenSpec and Beads skill material;
  the Beads link moves to `gastownhall/beads`),
  `docs/releasing.md` (site checks in the release procedure).
- Tests: new `scripts/docs-site.test.sh`. `scripts/release-pins.test.sh` and
  `scripts/legal.test.sh` are extended. `scripts/readme-structure.test.sh` and the content-pinning
  suites are adjusted only where a moved heading requires it. New tool
  script `scripts/docs-site-build` (needs Docker and network, not part of
  `scripts/test`).
- Specs: new `docs-site` capability. Modified requirements in
  `release-distribution` (install pins) and `public-project-readiness`
  (full MIT notices for distributed skill material).
- No change to the CLI or the installer manifest. The package `files` list
  gains no site asset; the new pages are not added to it.

This planning artifact authorizes no tag, release, Pages settings change or
human acceptance sign-off.
