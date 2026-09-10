#!/usr/bin/env bash
set -euo pipefail

repo=${1:-${SPECFORGE_SUCCESSOR_REPO:-}}
expected_identity=${SPECFORGE_PUBLIC_GIT_IDENTITY:-54026322+JoMe92@users.noreply.github.com}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v git >/dev/null || fail "git is required"
command -v gh >/dev/null || fail "gh is required for private-repository verification"
test -n "$repo" || fail "pass the owner/repository successor name as argument 1"

visibility=$(gh repo view "$repo" --json isPrivate --jq '.isPrivate')
test "$visibility" = true || fail "successor must remain private during pre-launch audit"

audit_root=$(mktemp -d /tmp/specforge-successor-audit.XXXXXX)
cleanup() {
  case "$audit_root" in
    /tmp/specforge-successor-audit.*) rm -r -- "$audit_root" ;;
  esac
}
trap cleanup EXIT

git clone --mirror "git@github.com:${repo}.git" "$audit_root/repo.git" >/dev/null
mirror="$audit_root/repo.git"

ref_names=$(git -C "$mirror" for-each-ref --format='%(refname)')
unexpected_refs=$(printf '%s\n' "$ref_names" | grep -Ev '^refs/(heads|tags)/' || true)
test -z "$unexpected_refs" || {
  printf '%s\n' "$unexpected_refs" >&2
  fail "successor advertises a non-branch/tag ref"
}

forbidden_paths=$(
  git -C "$mirror" rev-list --all --objects \
    | grep -E ' (\.beads/interactions\.jsonl$|docs/source/|docs/acceptance/2026-09-02-raspberrypi\.md$|systemd/specforge-sync\.(service|timer)$|scripts/__pycache__/|\.py[co]$|execution-log\.md$)' \
    || true
)
test -z "$forbidden_paths" || fail "successor history contains a forbidden path"

identity_mismatches=$(
  git -C "$mirror" log --all --format='%ae%n%ce' \
    | grep -Fvx "$expected_identity" \
    || true
)
test -z "$identity_mismatches" || fail "successor history contains a private or local commit identity"

test -z "$(git -C "$mirror" log --all -S'/home/jome' --format='%H' -- README.md)" \
  || fail "README history contains a maintainer checkout path"
test -z "$(git -C "$mirror" log --all --format='%B' | grep -E '/home/jome|/Users/[^ /]+' || true)" \
  || fail "commit messages contain a maintainer checkout path"

revisions=$(git -C "$mirror" rev-list --all)
credential_paths=$(
  git -C "$mirror" grep -IlE \
    '(gh[pousr]_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{16,}|sk-proj-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|https?://[^/@[:space:]]+:[^/@[:space:]]+@)' \
    $revisions -- 2>/dev/null \
    || true
)
test -z "$credential_paths" || fail "successor history contains a credential-shaped value"

git -C "$mirror" fsck --full --strict >/dev/null

ref_count=$(printf '%s\n' "$ref_names" | grep -c .)
printf 'successor audit: ok (%s private, %s branch/tag refs)\n' "$repo" "$ref_count"
printf 'Private Vulnerability Reporting: deferred to immediate post-public owner cutover\n'
