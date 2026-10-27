## 1. Site foundation and brand (feat/, UI)

- [x] TASK-BDS-001 [standard] Theme, information architecture, site suite and local build tool.
  Per design Decisions 2, 3, 4 and 11: first a build spike: the pinned Just
  the Docs remote_theme (v0.12.0 or newer, record the tag) must build on the
  github-pages gem with search and a custom scheme; otherwise record a
  blocking discovery and stop. Then rewrite docs/_config.yml (remote_theme,
  the allowed plugin set, strip_title false, permalink pretty, exclude list,
  header links, nav_external_links for Project & maintainers), add the six
  section pages and docs/404.md, place every existing page through defaults
  (no front matter), regroup docs/README.md for GitHub without the private
  repo link and with the cutover entry marked historical. Add
  scripts/docs-site.test.sh (config, placement, exclusions, front matter,
  link rules incl. the consumer-copied rule, Liquid, privacy, alt text) and
  scripts/docs-site-build (container build into a temp dir, link and anchor
  check, --serve). Specialist: frontend-engineer for the theme config.
  Check: scripts/docs-site.test.sh; scripts/docs-site-build passes with zero
  broken links; ci-security-gates links; cutover-checklist and
  nogging-identity suites; nogg validate. Branch feat/.

- [ ] TASK-BDS-002 [complex] [UI] Brand styling, complete third-party notices and screenshot tooling.
  Per design Decision 5: brand the theme. Light and dark schemes from the
  token table (any change keeps every text, link and code pair at 4.5:1 or
  more), the head script choosing the scheme before first paint (stored
  choice, then prefers-color-scheme, storage in try/catch), an accessible
  header toggle, self-hosted Poppins woff2 with OFL.txt and a
  THIRD_PARTY_NOTICES.md entry (Poppins OFL 1.1, Just the Docs MIT). In the
  same file, per design Decision 5 *Third-party notices*: add the full MIT
  licence texts with their upstream copyright lines for the distributed
  OpenSpec skills and the Beads skill material (today the file only points
  upstream), replace the stale steveyegge/beads link with gastownhall/beads,
  and extend scripts/legal.test.sh to require both copyright lines and the
  MIT permission text and to reject the old link. Then the SVG mark with a
  dark variant, the wordmark, the favicon set, styles for code, tables,
  callouts and focus, the footer without the LICENSE copyright line.
  Overrides only through head_custom, header_custom, footer_custom, schemes
  and _sass/custom. Add --screenshots to scripts/docs-site-build (pinned
  Playwright container, 375x812 and 1280x800, light and dark, axe-core with
  no serious or critical finding). Extend the site suite with the contrast
  check and the no-external-asset check. Specialists: ui-ux-designer for the
  visual spec, then frontend-engineer. Check: site suite; docs-site-build
  with screenshots and the a11y scan, screenshot directory recorded in the
  Bead note for the Product Owner; legal suite; nogg validate. Branch feat/.

- [ ] TASK-BDS-003 [standard] [UI] Landing page and the single install source.
  Per design Decisions 6 and 7: build docs/index.md with a home layout in
  the order hero, quick start, Why Nogging, How it works (two diagrams,
  captions, alt text), Works with (Antigravity experimental, Linux only),
  Safety link, Community links. Add docs/_data/install.yml (tag, bootstrap,
  init) as the landing page's single install source. The site suite checks
  byte equality with README.md and docs/installation.md, no pinned install
  line on other pages, and the landing support claims. Extend
  scripts/release-pins.test.sh to the data file. Name the data file in
  docs/releasing.md step 4. Link the site from the README Documentation
  section, keeping readme-structure and nogging-identity green. Specialists:
  ui-ux-designer, then frontend-engineer. Check: site suite; release-pins;
  readme-structure; docs-site-build with screenshots of the landing page at
  both widths and in both schemes recorded in the Bead note; nogg validate.
  Branch feat/.

## 2. Metadata and new user pages (chore/, docs/, test/)

- [ ] TASK-BDS-004 [standard] Search metadata, robots.txt and a description for every page.
  Per design Decision 9: configure jekyll-seo-tag (title format, default
  image the large social card, summary_large_image, logo the square card,
  lang en, GitHub-only social, author Jonas (JoMe92) or none). Fix the site
  description to mark Antigravity experimental. Add docs/robots.txt naming
  the sitemap and sitemap false on the 404 page. Write a searcher-oriented
  description of at most 160 characters, unique, for every published page
  present at rebase time. The site suite enforces descriptions for all
  published pages from now on, and enforces that no llms.txt exists. Check:
  site suite; docs-site-build, then inspect one built head for title,
  description, canonical, og:image and twitter:card; nogg validate. Branch
  chore/.

- [ ] TASK-BDS-005 [standard] Your first change page and Getting started fixes.
  Per design Decision 8 (new page first-change.md; light edits to
  installation.md, compatibility.md, faq.md and comparison.md): write Your
  first change from a ready repository to a closed first Bead, saying what
  you should see at each step, without repeating installation. Fix the
  installation payload table (twelve reference docs, the Antigravity row,
  four hooks) and state that the target needs develop and origin. Replace
  blob/develop and ../README.md and ../SECURITY.md links with absolute
  GitHub URLs. Keep the FAQ consistent with the README FAQ. Add intros.
  Place and describe the new page. Check: site suite; installation-docs,
  install-surface-consistency, compatibility and release-pins suites;
  ci-security-gates links; nogg validate. Branch docs/.

- [ ] TASK-BDS-006 [standard] Claude Code guide.
  Per design Decision 8 (new page using-with-claude-code.md): write the
  Claude Code guide, built like the Codex and Pi guides. It covers the
  installed .claude/ payload and PreToolUse guard, the slash commands
  including /orchestrate, the six specialists and delegation with co-author
  trailers, authority levels and effort, the Claude-only Orchestration Agent
  and Remote Control, and known limitations. Facts are checked against
  .claude/ and .nogging/launch-profiles/. Place and describe the page. Link
  it from the Guides overview and, for consumer-copied pages, by absolute
  site URL. Check: site suite; planning-docs and commands suites;
  ci-security-gates links; nogg validate. Branch docs/ (after TASK-BDS-005).

- [ ] TASK-BDS-007 [standard] Command reference.
  Per design Decision 8 (new page commands.md): write the command reference.
  One `##` heading per top-level subcommand in scripts/nogg --help, and one
  `###` per sub-subcommand of worktree, pr, orchestrator and session. Each
  entry gives purpose, common forms, the role that uses it and a guide link.
  Link it from the partial command tables in the sessions guide and the
  operating model (absolute site URL from consumer-copied pages). The site
  suite compares headings with the live --help output, offline. Record a
  non-blocking discovery listing the subcommands that lack a help string; do
  not change scripts/nogg. Check: site suite; commands and
  runtime-guidance-docs suites; nogg validate. Branch test/.

- [x] TASK-BDS-008 [standard] Troubleshooting page.
  Per design Decision 8 (new page troubleshooting.md): write symptom, cause
  and fix entries for the listed failures (doctor FAIL and WARN, held
  planning lock, unreachable Dolt server, sandboxed or missing tmux server,
  a stalled or failed session, usage limit, skipped or failing sync, refused
  worktree cleanup, half-applied rebase). Each entry links the
  failure-recovery.md anchor and the commands.md heading. Place and describe
  the page. Check: site suite; docs-site-build anchor check; nogg validate.
  Branch docs/ (after TASK-BDS-006, TASK-BDS-007 and TASK-BDS-011).

## 3. Consistency passes and reference pages (fix/, chore/, test/)

- [ ] TASK-BDS-009 [standard] Concept page consistency, docs-wide pin and internal-ID checks.
  Per design Decision 8 (concept pages): rewrite vision-and-architecture.md
  for today's state (no v1.0.0 roadmap, no Planned markers, no German
  heading, no SPEC-fc4 or TASK-SYNC-006, correct workflow name, pinned
  installer). Restructure operating-model.md (intro, the empty Acceptance
  heading, Main Worker introduced once, trusted Claude and Codex facts
  checked against .nogging/launch-profiles/). Edit architecture.md (W5, W6,
  SPEC-7ec, persona count, "in this repository"), security-model.md
  (plan-end before worktree retirement, Antigravity experimental, the orphan
  paragraph) and worktree-workflow.md (self-merge vs --full-access). Pin the
  installer lines in using-with-codex.md and using-with-pi.md. Extend
  release-pins to every docs page and add the real-ID check with its
  placeholder allow-list to the site suite. Check: site suite; release-pins,
  planning-docs, security-docs, runtime-guidance-docs, commands,
  model-selection, installed-diagnostics and packed-token-usage suites; nogg
  validate. Branch fix/.

- [ ] TASK-BDS-010 [standard] Agent guide consistency.
  Per design Decision 8 (agent guides): consistency edits to
  using-with-codex.md (broken sentence near the prompts link step, "in this
  change" wording, issue references), using-with-pi.md (docs/nogging/ paths
  for consumers), using-with-antigravity.md ("experimental" in the H1 and
  intro, blob/develop links), using-with-herdr.md (internals pointer to
  architecture, SPEC-xxx kept only as a placeholder), agent-identities.md
  (the implemented credential helper) and model-selection.md (internal
  planning references, version drift from the matrix). Add intros and apply
  the shipped-page link rule. Check: site suite; runtime-guidance-docs,
  session-delivery-docs, planning-docs, session-observability,
  model-selection, docs-herdr-foreign-note and installed-diagnostics suites;
  nogg validate. Branch fix/ (after TASK-BDS-009).

- [ ] TASK-BDS-011 [standard] Sessions and recovery page consistency.
  Per design Decision 8 (sessions and recovery): consistency edits to
  running-work-in-sessions.md (socket nogging, trusted Codex network, one
  correct deny list, the Antigravity source statement, a label on the
  section about this repository's own configuration, the misplaced
  test-isolation note, a link to commands.md) and failure-recovery.md (PR
  and issue numbers as context, "this repo's Dolt server", maintainer-only
  recipes labelled). Keep every heading slug that other pages link to, or
  update those links in the same commit. Check: site suite;
  session-delivery-docs, runtime-guidance-docs, planning-docs,
  session-observability, commands and installed-diagnostics suites; nogg
  validate. Branch fix/ (after TASK-BDS-010).

- [ ] TASK-BDS-012 [standard] Usage-limits rewrite and operations and maintainer page fixes.
  Per design Decision 8 (operations and maintainer pages): rewrite
  usage-limits.md around nogg usage and the usage gate, with probe detail in
  a short appendix and no owner time zone. Edit token-usage.md (intro),
  project-identity.md ("first public release" wording, socket name,
  Antigravity experimental) and acceptance.md (internal change name and W5
  wording). Place and describe as the IA says. Check: site suite;
  nogging-identity, packed-token-usage and installed-diagnostics suites;
  nogg validate. Branch chore/ (after TASK-BDS-004).

- [ ] TASK-BDS-013 [standard] Configuration reference and glossary.
  Per design Decision 8 (new pages configuration.md and glossary.md): write
  the configuration reference: every key from templates/nogging-config.json,
  every literal scfg() key, and the usage_gate, tier_overrides,
  multi_machine and sync_protected_branches blocks, each with type, default
  and effect, grouped. Write the glossary with the listed terms, one line
  and a link each. The site suite checks key coverage against the template
  and the scfg() literals. Place and describe both pages. Check: site suite;
  model-selection suite; nogg validate. Branch test/ (after TASK-BDS-007).

## 4. Verification and release steps (test/)

- [ ] TASK-BDS-014 [standard] [UI] Final site verification and release-procedure site steps.
  Per design Decisions 10 and 11: run the full verification on integrated
  develop. That is the site suite, docs-site-build with zero broken links
  and anchors, screenshots of the landing page, one guide, the
  troubleshooting page and the 404 page at both widths and in both schemes,
  and the axe scan with no serious or critical finding. Fix small defects
  found. Record anything larger as a discovery. Add the site steps to
  docs/releasing.md: before the tag, the site suite and docs-site-build;
  after the release, the live landing install command checked against the
  new tag. Record in the Bead note the screenshot directory for the Product
  Owner and the open question of a docs-only patch release. Specialists:
  test-runner for the runs, code-reviewer for a final content and claims
  pass. Check: everything above plus release-pins, readme-structure and nogg
  validate; CI green. Branch test/ (after TASK-BDS-013).

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` = A depends on B): 002<-001, 003<-002, 004<-001, 005<-001, 006<-005, 007<-001, 008<-006, 008<-007, 008<-011, 009<-001, 010<-009, 011<-010, 012<-004, 013<-007, 014<-003, 014<-008, 014<-012, 014<-013. The edges 006<-005, 012<-004 and the 008<-006 part are lane edges: shared branch prefixes, no content dependency. TASK-BDS-001 starts alone. After it, 002, 004, 005, 007 and 009 can start at once on five distinct prefixes. Branches are `<type>/branded-docs-site`, with lanes from design.md *Dependencies and parallel lanes*: feat/ 001, 002, 003; chore/ 004, 012; docs/ 005, 006, 008; fix/ 009, 010, 011; test/ 007, 013, 014. A lane's next task reuses the prefix only after the previous branch is integrated and deleted. Each task's full contract is its design Decision plus the requirements of the capability specs in this change.

## Execution contract

The Main Worker claims every task and implements it only in its own allocated worktree on its lane branch. A task's first line is its Bead title; its full slice is that line plus the indented paragraph under it. Before allocating a dependent worktree, verify that every prerequisite execution commit is integrated into develop; Bead closure alone is not enough. Follow design Decision 1 for every task: offline tests only in scripts/test (Docker and network only in scripts/docs-site-build), no new runtime dependency, no front matter on existing pages, consumer-copied pages link relatively only to each other, facts checked against the code, no email address, owner only as Jonas or JoMe92, Linux only, Antigravity and herdr experimental, pins stay v3.1.1. Run each task's named checks; the full scripts/test runs in CI. Then commit with a Conventional subject ending in the real Bead token, push the lane branch and open the pull request against develop. Only then run bd close and scripts/nogg task-done, and append the SHA and evidence to the Bead. UI tasks (marked [UI]) delegate the visual specification to the ui-ux-designer and the implementation to the frontend-engineer, with the matching Co-authored-by trailer. A Codex Lead does that work inline under the same constraints and needs --full-access or --profile trusted to reach the shared Dolt server. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Pages settings, tagging, releases and the decision on a docs-only patch release stay with the Orchestration Agent and the Product Owner; nobody signs human acceptance.
