# Nogging public cutover checklist

This checklist is executed and signed by the repository owner only. Automation
may run the read-only verification commands, but must not change visibility,
archive or delete a repository, publish a release, enable security settings, or
fill an acceptance report's `Signed-off-by:` field.

## Before changing visibility

- [ ] Confirm `scripts/test` passes on the exact release-candidate commit.
- [ ] Confirm `scripts/successor-audit.sh JoMe92/nogging` passes
  and reports only the reviewed heads and tags.
- [ ] Confirm the successor is private with
  `gh repo view JoMe92/nogging --json isPrivate --jq .isPrivate`.
- [ ] Confirm the legacy `JoMe92/nogg` repository is private. Its hidden
  pull-request refs make public visibility unsafe.
- [ ] Confirm the private recovery bundle checksum and restore notes described
  in `reports/2026-09-10-successor-migration.md` in the private
  [`JoMe92/rooftree`](https://github.com/JoMe92/rooftree) companion repo.
- [ ] Confirm `SECURITY.md` gives the applicable private-phase reporting route.
- [ ] Confirm the candidate acceptance report is committed and its
  `Signed-off-by:` value is empty.

## GitHub repository settings

In the successor repository's GitHub **Settings → General** page:

- [ ] Set the description to: `Local-first spec-driven delivery for AI agents.`
- [ ] Set topics to: `agentic-development`, `beads`, `codex`, `openspec`,
  `software-delivery`.
- [ ] Set `main` as the default branch.
- [ ] Keep Issues enabled and verify the Issues tab is visible.
- [ ] Confirm the canonical URL is
  `https://github.com/JoMe92/nogging`.

Do not import, mirror-push, or restore refs from the legacy repository or the
private recovery set.

## Release preparation

- [ ] Verify the candidate tag resolves to the accepted commit.
- [ ] Verify clean installation from the exact candidate tag and record its
  checksum in the unsigned acceptance report.
- [ ] Draft a new successor GitHub Release from that tag. Do not copy legacy
  GitHub Release objects or describe rewritten historical tags as newly
  verified releases.
- [ ] Leave the release unpublished until all pre-public checks pass.

## Legacy repository retirement

Choose exactly one owner-controlled action:

- [ ] Keep `JoMe92/nogg` private and archive it; or
- [ ] Delete `JoMe92/nogg` only after verifying the private recovery set.

Never make the legacy repository public. Record the chosen state in the
acceptance report.

## Public visibility and security sequence

Perform these steps consecutively in the GitHub web interface:

1. [ ] Change **only** `JoMe92/nogging` from private to public.
2. [ ] Immediately open **Settings → Code security and analysis** and enable
   Private Vulnerability Reporting.
3. [ ] Verify **Security → Advisories → New draft security advisory** is
   available to a reporter.
4. [ ] Publish the prepared successor GitHub Release.
5. [ ] Re-run the read-only visibility query and successor history audit.
6. [ ] Only after those checks pass, fill the acceptance report's
   `Signed-off-by:` field and commit the owner acceptance separately.

## Local remotes

After public validation, each maintainer may update their own checkout:

```bash
git remote set-url origin git@github.com:JoMe92/nogging.git
git remote -v
git fetch --prune origin
```

Do not use `--mirror`, force-push, or push wildcard refspecs during this step.

## Rollback

Before public visibility, stop and either delete the still-private successor or
remove only its reviewed seed refs, then point local remotes back to the private
legacy repository. Restore the recovery bundle only into a private destination.

After public visibility, prefer a normal fix-forward commit. If a critical
privacy failure is found, the owner first makes the successor private in the
GitHub web interface, records what was exposed, and then follows the private
rollback procedure. Never replace public history with the dirty recovery set.
