#!/usr/bin/env bash
# Verifies documentation of session delivery, timing keys, queue acceptance
# versus submission, startup/hook diagnosis and deliberate recovery (TASK-RSI-007).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# 1. Timing keys and ranges in docs/running-work-in-sessions.md
guide="$root/docs/running-work-in-sessions.md"
for key in \
  "session_submit_delay_seconds" \
  "session_submit_verify_delay_seconds" \
  "session_delivery_timeout_seconds" \
  "session_startup_timeout_seconds"
do
  grep -Fq "$key" "$guide" || fail "$guide omits timing key $key"
done

# Verified send and kickoff documentation in running-work-in-sessions.md
grep -Fq "session send" "$guide" || fail "$guide omits session send"
grep -Fq "session kickoff" "$guide" || fail "$guide omits session kickoff"
grep -Fq "load-buffer" "$guide" || fail "$guide omits isolated paste transport"
grep -Fq "single Enter" "$guide" || fail "$guide omits single Enter description"

# 2. Codex queue acceptance vs submission in docs/using-with-codex.md
codex_doc="$root/docs/using-with-codex.md"
grep -Fq "codex queue" "$codex_doc" || fail "$codex_doc omits codex queue"
grep -Fq "Queue acceptance" "$codex_doc" || fail "$codex_doc omits queue acceptance distinction"
grep -Fq "unverified" "$codex_doc" || fail "$codex_doc omits unverified outcome"

# Obsolete claim: queue accept equals verified delivery must NOT appear
if grep -qi "When the queue accepts the message, delivery is verified" "$codex_doc"; then
  fail "$codex_doc contains obsolete claim that queue acceptance equals verified delivery"
fi

# 3. Antigravity startup readiness and hook diagnosis in docs/using-with-antigravity.md
agy_doc="$root/docs/using-with-antigravity.md"
grep -Fq "session_startup_timeout_seconds" "$agy_doc" || fail "$agy_doc omits startup timeout"
grep -Fq "Stop hook" "$agy_doc" || fail "$agy_doc omits Stop hook description"
grep -Fq "feedback survey" "$agy_doc" || fail "$agy_doc omits feedback survey description"

# 4. Failure recovery guidance in docs/failure-recovery.md
rec_doc="$root/docs/failure-recovery.md"
grep -Fq "session_startup_timeout_seconds" "$rec_doc" || fail "$rec_doc omits startup timeout in recovery"
grep -Fq "unverified" "$rec_doc" || fail "$rec_doc omits unverified recovery guidance"
grep -Fq "session nudge" "$rec_doc" || fail "$rec_doc omits deliberate nudge recovery"

# 5. Launch-name and Codex safeguards from TASK-LCD-007
for term in 'periods (`.`)' 'colons (`:`)' 'underscores' 'cleanup' 'older copy'; do
  grep -Fqi "$term" "$guide" || fail "$guide omits launch guidance: $term"
done
for term in \
  "[Pasted Content N chars]" \
  "startup turn" \
  "session_delivery_timeout_seconds" \
  "not busy" \
  "provable process identity" \
  "3.0.0"
do
  grep -Fqi "$term" "$codex_doc" || fail "$codex_doc omits Codex safeguard: $term"
done
for term in "#207, #216" "update the copy" "mismatched receipt" "older vendored"; do
  grep -Fqi "$term" "$rec_doc" || fail "$rec_doc omits recovery guidance: $term"
done
grep -Fq "Safe session launch and Codex delivery guidance" "$root/CHANGELOG.md" \
  || fail "$root/CHANGELOG.md omits the Unreleased entry"

printf 'ok   - session delivery documentation contract passes\n'
