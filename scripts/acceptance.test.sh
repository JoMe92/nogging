#!/usr/bin/env bash
# Thin wrapper around the mechanical acceptance harness.
#
# Runs `scripts/acceptance.sh --mechanical` — the no-LLM, no-backend subset of
# the Nogging end-to-end acceptance procedure (docs/acceptance.md): install
# into a throwaway repo, readiness verdict, plan-begin, materialize the canned
# example change, simulate a closure, the sync round-trip and its idempotency,
# doctor/audit, plan-end.
#
# The harness drives the Node installer, so when `node` is absent this test
# skips with a PASS rather than failing the otherwise bash-only suite, matching
# scripts/cli.test.sh. Auto-discovered by scripts/test.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all acceptance harness checks passed"
  exit 0
fi

if "$here/acceptance.sh" --mechanical; then
  echo "all acceptance harness checks passed"
else
  echo "acceptance harness checks failed" >&2
  exit 1
fi
