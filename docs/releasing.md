# Releasing Nogging

Nogging has no build step and no npm registry publication — a release is a
tagged, checked-in state of the repository that `npx github:JoMe92/nogging#<tag>`
installs directly. This is the repeatable procedure for cutting one, whether
a release candidate or a final release.

## Prerequisites

| Need | Why | Check |
| --- | --- | --- |
| `node` >= 18, `npm` | `npm pack`/`npm sbom`, the CLI itself | `node --version`, `npm --version` |
| `git` | tagging, `scripts/release-check` | `git --version` |
| A clean, up-to-date `develop` | the release commit sits on top of it | `git status`, `git fetch` |

## Steps

1. **Confirm `develop` is ready.** Every change intended for this release is
   merged, `scripts/test` is green, and CI is green on `develop`.

2. **Move `CHANGELOG.md`'s `[Unreleased]` section under the new version.**
   Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (or
   `## [X.Y.Z-rc.N] - YYYY-MM-DD` for a candidate), and start a fresh empty
   `## [Unreleased]` above it for whatever lands next.

3. **Bump the version** in `package.json` and run `npm install` (or
   `npm install --package-lock-only`) so `package-lock.json`'s top-level
   version matches.

4. **Bump the pinned install tag** to `vX.Y.Z` in `README.md`,
   `docs/installation.md`, the landing page's install data
   `docs/_data/install.yml` (its `tag`, `bootstrap` and `init` values) and
   `NOGGING_TAG` in `scripts/bootstrap`. This was
   missed across three prior releases before `v2.0.1`, leaving the documented
   quick start pointed at a stale tag — don't skip it. Run
   `scripts/release-pins.test.sh`: it reads the version from `package.json` and
   proves the bump is complete.

5. **Commit** the version bump, changelog, and pin update as
   `chore(release): prepare vX.Y.Z [<Bead ID>]`.

6. **Run the pre-tag consistency check:**

   ```bash
   scripts/release-check X.Y.Z
   ```

   This confirms the version is valid semver, `package.json` and
   `package-lock.json` agree, `CHANGELOG.md` has the new section, and the
   working tree is clean. It reports the `vX.Y.Z` tag as "does not exist
   yet" at this point — that is expected before step 8. Run it *after*
   committing (step 5): the working-tree-clean check is only meaningful
   once the version bump itself is committed.

7. **Verify the documentation site before the tag.** The site builds from
   `main:/docs`, so what you tag is what goes live. Run the offline site suite
   and the full site build (Docker and network):

   ```bash
   scripts/docs-site.test.sh
   scripts/docs-site-build
   ```

   The build checks every internal link and anchor in the rendered HTML and
   must report none broken. Optionally add `--screenshots <dir>` for the
   landing page, a guide, the troubleshooting page and the 404 page at both
   widths and in both colour schemes, plus the axe accessibility scan, which
   must report no serious or critical finding.

8. **Tag** the release commit with an annotated tag and push both:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin <branch> vX.Y.Z
   ```

9. **Run the consistency check again**, now against the tag:

   ```bash
   scripts/release-check X.Y.Z
   ```

   Every line SHALL report `OK`, including `tag 'vX.Y.Z' points at HEAD`.

10. **Generate release artifacts** (a package tarball, its SHA-256 checksum,
   and a CycloneDX SBOM generated from the lockfile, or an explicit
   not-applicable note if SBOM generation fails):

   ```bash
   scripts/release-artifacts
   ```

   Output lands under `dist/release/X.Y.Z/` (git-ignored — attach these
   files to the GitHub Release by hand, don't commit them).

11. **Run the exact-tag install smoke test** against the pushed tag:

    ```bash
    scripts/release-smoke-test github:JoMe92/nogging#vX.Y.Z
    ```

    Before pushing a real tag — for example while drafting this procedure or
    testing a change to it — run the same script against a local path
    instead for an offline dry run: `scripts/release-smoke-test .`

12. **Check the live site after the release.** Once the release has reached
    `main` and GitHub Pages has rebuilt, open the live landing page and
    confirm that its install command names the new `vX.Y.Z` tag, the same
    tag as in `docs/_data/install.yml`. If it still shows the old tag, the
    site has not rebuilt yet; check the Pages build before announcing the
    release.

13. **Hand off to acceptance.** A release candidate or final release still
    needs the full acceptance evidence (install, upgrade, rollback, uninstall,
    every supported agent path) described in
    [docs/acceptance.md](acceptance.md), filled in from
    [acceptance-report-template.md](https://github.com/JoMe92/nogging/blob/develop/docs/acceptance-report-template.md).
    That report — not this checklist — is what a human signs.

## Rollback

Nothing here changes repository visibility or publishes anything outside
Git. If a tag turns out to be wrong before anyone has relied on it:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
```

Never delete or force-move a tag that a real consumer may already have
installed from.

## What this procedure does not do

It does not change repository visibility, publish to the npm registry, or
sign an acceptance report — those remain explicit, separate, human-owned
actions.
