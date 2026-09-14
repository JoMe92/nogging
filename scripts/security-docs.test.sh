#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guide="$root/docs/security-model.md"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

test -f "$guide" || fail "security guide exists"

for topic in \
  'What Nogging installs and runs' \
  'Trust boundaries and authority levels' \
  'Vendor-specific limits' \
  'Network, filesystem, and credentials' \
  'Safe enablement' \
  'Disable and remove safely'
do
  grep -Fq "$topic" "$guide" || fail "security guide covers $topic"
done

for runtime in 'Claude Code' 'Codex' 'Pi'; do
  grep -Fq "$runtime" "$guide" || fail "security guide covers $runtime"
done

grep -Fq '[security and threat model](docs/security-model.md)' "$root/README.md" \
  || fail "README links security guide"
grep -Fq '[security and threat model](docs/security-model.md)' "$root/SECURITY.md" \
  || fail "SECURITY links security guide"

readme_link="$(grep -n -m1 '\[security and threat model\](docs/security-model.md)' "$root/README.md" | cut -d: -f1)"
readme_enable="$(grep -n -m1 'session launch .*--full-access' "$root/README.md" | cut -d: -f1 || true)"
if [[ -n "$readme_enable" && "$readme_link" -ge "$readme_enable" ]]; then
  fail "README routes to security guide before full-access command"
fi

security_link="$(grep -n -m1 '\[security and threat model\](docs/security-model.md)' "$root/SECURITY.md" | cut -d: -f1)"
security_enable="$(grep -n -m1 'session launch .*--full-access' "$root/SECURITY.md" | cut -d: -f1 || true)"
if [[ -n "$security_enable" && "$security_link" -ge "$security_enable" ]]; then
  fail "SECURITY routes to guide before full-access command"
fi

printf 'ok   - public security guide and entry-point routing\n'
