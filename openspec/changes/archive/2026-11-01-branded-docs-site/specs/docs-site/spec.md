## ADDED Requirements

### Requirement: The site builds on GitHub Pages without a build workflow

The documentation site SHALL be built by GitHub Pages from `main:/docs` with
the Pages-provided Jekyll. No repository workflow SHALL build or deploy it.
The theme SHALL be Just the Docs, loaded as a `remote_theme` pinned to an
exact release tag. Every Jekyll plugin SHALL be on the GitHub Pages
allow-list, and the site SHALL contain no custom Ruby plugin. A viewed page
SHALL load fonts, scripts and styles only from the site itself. It SHALL use
no CDN, no third-party font service, no analytics and no cookies.

#### Scenario: The configuration is checked offline

- **WHEN** `scripts/docs-site.test.sh` runs in `scripts/test`
- **THEN** it fails if `remote_theme` names no exact `@vX.Y.Z` tag, if a plugin is not on the allow-list it carries, if a `.rb` file exists under `docs/`, or if a published page or include references an external `http(s)` URL for a font, script or stylesheet

#### Scenario: A maintainer builds the site locally

- **WHEN** a maintainer runs `scripts/docs-site-build`
- **THEN** it builds `docs/` in a throwaway container with the `github-pages` gem version that GitHub Pages currently publishes, into a temporary directory outside the repository
- **AND** it checks every internal link and `#fragment` in the built HTML and exits non-zero naming each broken one

### Requirement: The landing page introduces Nogging to a first-time visitor

The site root SHALL be a site-only landing page (`docs/index.md`). It SHALL
show the Nogging mark, the wordmark and the tagline "Structure for a team of
agents.". It SHALL say in at most three sentences what Nogging is. It SHALL
name the problems it solves, show how it works with the existing diagrams
(each with descriptive alt text), and give a pinned quick start. It SHALL
link to the installation guide, the GitHub repository, the latest release and
GitHub Discussions, and it SHALL link to the security model before any
mention of full access. Its support claims SHALL match the compatibility
matrix: Linux is the only supported host, and Antigravity is marked
experimental wherever it is named.

#### Scenario: A visitor opens the site root

- **WHEN** a visitor opens `https://jome92.github.io/nogging/`
- **THEN** they see the mark, the wordmark, the tagline, the what-it-is sentence and a pinned install command without scrolling on a 1280×800 viewport
- **AND** the diagrams, the links to installation, GitHub, releases and Discussions follow on the same page

#### Scenario: The landing page overstates support

- **WHEN** the landing page names Antigravity without "experimental", or names macOS or Windows as supported
- **THEN** `scripts/docs-site.test.sh` fails and names the claim

### Requirement: Navigation separates user documentation from maintainer material

Every published page SHALL belong to exactly one sidebar section. The
sections SHALL be, in order: Getting started, Concepts, Guides, Operations,
Reference, and Project & maintainers. Maintainer pages (release procedure,
acceptance runbook, project identity) SHALL appear only in the last section.
Each section SHALL have an overview page that lists its pages with one line
each. Navigation placement, page titles and descriptions SHALL be set in
`docs/_config.yml` `defaults` scoped by file path, not in the page.

#### Scenario: A page is added without a place in the navigation

- **WHEN** a new Markdown page under `docs/` is neither excluded nor assigned to a section
- **THEN** `scripts/docs-site.test.sh` fails and names the page

#### Scenario: A visitor reads a user guide

- **WHEN** a visitor opens any user page
- **THEN** the sidebar shows the six sections with the current one expanded, the page shows breadcrumbs, and the search box finds the page by words from its title

### Requirement: Internal material is excluded from the site

The site SHALL exclude, through `docs/_config.yml` `exclude`, the dated
acceptance reports and investigations under `docs/acceptance/`, the
acceptance report template and the public-cutover checklist. Excluded files
SHALL stay in the repository. `docs/README.md` SHALL remain the GitHub folder
index, grouped like the site sections with internal material in its own
group, and SHALL itself be excluded from the site. No published page SHALL
link relatively to an excluded file; such a link SHALL be an absolute GitHub
URL.

#### Scenario: A published page links to an internal file

- **WHEN** a published page contains a relative link to an excluded file
- **THEN** `scripts/docs-site.test.sh` fails and names the page and the link

#### Scenario: A visitor guesses an internal URL

- **WHEN** a visitor requests the site path of an acceptance report
- **THEN** the site serves its branded 404 page, and the report is not in the sitemap or the search index

### Requirement: The site's look derives from the Nogging brand

The site SHALL use a Nogging colour scheme derived from the brand palette:
dark green `#22301F`, sage `#7E9C7E` and `#97B190`, grey-green `#4A5B4C` and
off-white `#F6F6F4`. It SHALL have light and dark variants. The site SHALL
open in the variant the operating system prefers. A visible toggle SHALL
switch the variant and remember the choice where browser storage is
available, and the page SHALL still work where it is not. Headings, navigation and the
wordmark SHALL use self-hosted Poppins, shipped with its SIL OFL 1.1 licence.
The header SHALL show an SVG version of the existing mark with the wordmark.
The site SHALL ship a favicon set derived from the mark. Body text, links
and code SHALL meet WCAG 2.1 AA contrast (4.5:1) against their background in
both variants. Sage tones SHALL be used for text only where they meet that
ratio. Pages SHALL lay out without horizontal page scrolling at 375 px
width. Code blocks SHALL scroll inside themselves and SHALL offer a copy
button.

#### Scenario: A colour token fails contrast

- **WHEN** a text, link or code colour token in the scheme files has less than 4.5:1 contrast against its background token, in either variant
- **THEN** `scripts/docs-site.test.sh` fails and names the pair and the ratio

#### Scenario: A visitor on a phone in dark mode opens a guide

- **WHEN** a visitor whose system prefers dark mode opens a guide on a 375 px wide screen
- **THEN** the page renders in the dark variant without a flash of the light variant, the sidebar collapses behind a menu button, and long code lines scroll inside their block

### Requirement: Documentation Markdown stays plain and readable on GitHub

Existing pages under `docs/` SHALL carry no YAML front matter, so that GitHub
renders them as plain Markdown and the pages the installer copies into
consumer repositories stay unchanged in form. Only site-only pages (the
landing page, the section overview pages and the 404 page) MAY carry front
matter. A link in a published page SHALL resolve both on GitHub and on the
site. A link to a repository file outside `docs/` SHALL be an absolute
`https://github.com/JoMe92/nogging/...` URL. A page that the installer copies
into consumer repositories SHALL link relatively only to another such page.
It SHALL link any other docs page by its absolute site URL, so that the link
also resolves in a consumer copy. Liquid tag or output delimiters
SHALL NOT appear in a published page outside a fenced code block or a raw
block.

#### Scenario: Front matter is added to an existing page

- **WHEN** a page that existed before this change, or a page listed in the package `files`, starts with a `---` front matter block
- **THEN** `scripts/docs-site.test.sh` fails and names the page

#### Scenario: A link climbs out of docs/

- **WHEN** a published page links relatively to a path outside `docs/`
- **THEN** `scripts/docs-site.test.sh` fails and names the page and the link

#### Scenario: A consumer-copied page links a new page

- **WHEN** a page in the installer's `docs:` list links relatively to `troubleshooting.md`, which is not copied
- **THEN** `scripts/docs-site.test.sh` fails, and the fix is the page's absolute site URL

### Requirement: Every published page carries its own search metadata

Every published page SHALL have a unique title and its own description of at
most 160 characters. The site SHALL emit a canonical URL, Open Graph and
Twitter card tags through `jekyll-seo-tag`. The large social card
(`docs/brand/nogging-social-card.png`, 1280×640) SHALL be the default share
image. The square card SHALL be the structured-data logo. The site SHALL
publish a sitemap and a `robots.txt` that names it. Page URLs SHALL be flat,
lowercase paths that equal the file name (`/nogging/<name>/`). The site SHALL
NOT publish an `llms.txt`. Page metadata SHALL name the owner only as Jonas
or `JoMe92`, and no published page SHALL contain an email address.

#### Scenario: A page lacks a description

- **WHEN** a published page has no description in the `defaults`, or one longer than 160 characters, or one equal to another page's
- **THEN** `scripts/docs-site.test.sh` fails and names the page

#### Scenario: A built page is shared

- **WHEN** a built page is inspected
- **THEN** its head carries the page title, the page description, a canonical URL under `https://jome92.github.io/nogging/`, `og:image` and `twitter:card` `summary_large_image`

### Requirement: The site gives install commands from one source per surface

The landing page SHALL render its install commands from
`docs/_data/install.yml`. That file SHALL hold the release tag and the
bootstrap and `npx … init` commands. These commands SHALL be byte-identical
to the ones in `README.md` and `docs/installation.md`. No other published
page SHALL carry the pinned bootstrap or `npx … init` line. Other pages SHALL
use the `<tag>` placeholder or link to the installation guide.

#### Scenario: A guide copies the pinned install line

- **WHEN** a published page other than `docs/installation.md` contains the pinned `curl … | bash` bootstrap line
- **THEN** `scripts/docs-site.test.sh` fails and names the page

#### Scenario: One surface's install command drifts

- **WHEN** the bootstrap or `npx … init` command in `docs/_data/install.yml`, `README.md` or `docs/installation.md` differs from the others
- **THEN** `scripts/docs-site.test.sh` fails and shows the differing lines

### Requirement: User pages are accurate, consistent and self-explanatory

Each user page SHALL open with a short paragraph that says what the page
covers and who it is for. User pages SHALL NOT contradict `README.md`, the
compatibility matrix or one another on install commands, supported hosts,
agent support levels or role names. Outside Project & maintainers pages, they
SHALL NOT refer to internal tracking items (real Bead IDs, task IDs, design
decision numbers or weakness codes) as context. Placeholder IDs in command or
commit samples (such as `SPEC-abc123` or `SPEC-xxx`) remain allowed. They
SHALL NOT link to a private repository.
The site SHALL offer at least these user pages: installation, compatibility,
a guided first change, concepts, a guide per supported agent (Claude Code,
Codex, Pi, and Antigravity marked experimental), a security model,
troubleshooting, an FAQ, a glossary, a configuration reference for every
`.nogging/config.json` key, and a command reference for every top-level
`nogg` subcommand. A guide for an experimental integration SHALL say
"experimental" in its title or first paragraph. Where a page states the
behaviour of a launch profile, a command or a configuration key, the
statement SHALL match the shipped code.

#### Scenario: A subcommand is added without documentation

- **WHEN** `scripts/nogg --help` lists a top-level subcommand that has no heading in `docs/commands.md`
- **THEN** `scripts/docs-site.test.sh` fails and names the subcommand

#### Scenario: A configuration key is added without documentation

- **WHEN** `templates/nogging-config.json` or a literal `scfg("<key>")` call introduces a key that `docs/configuration.md` does not name
- **THEN** `scripts/docs-site.test.sh` fails and names the key

#### Scenario: An internal identifier reaches a user page

- **WHEN** a page outside Project & maintainers contains, outside a fenced code block, a Bead ID such as `SPEC-7ec` or a task ID such as `TASK-SYNC-006` that is not on the test's placeholder allow-list
- **THEN** `scripts/docs-site.test.sh` fails and names the page and the identifier

### Requirement: The site publishes the released documentation

The site SHALL keep building from `main:/docs`, so it changes only when a
release merges into `main`, and it documents the version that the pinned
install commands name. The README's *Documentation* section SHALL link the
site. The release procedure SHALL run the offline site suite and
`scripts/docs-site-build` before the tag. After the release it SHALL check
that the live site shows the new version's pinned install command.

#### Scenario: A release is prepared

- **WHEN** a maintainer follows `docs/releasing.md` for a release
- **THEN** the steps before the tag include `scripts/docs-site.test.sh` and `scripts/docs-site-build`, and a step after the release checks the live landing page's install command against the new tag
