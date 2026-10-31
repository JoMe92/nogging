#!/usr/bin/env bash
# scripts/check-test-integrity on temporary repositories: the exit code and the
# report for a deleted test, a move, a justified removal and an unresolvable base.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/check-test-integrity"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}
git_() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }

repo="$work/repo"
git init -q -b main "$repo"
cd "$repo"
mkdir -p scripts/lib tests
cp "$root/scripts/check-test-integrity" scripts/
cp "$root"/scripts/lib/testing_diff.py "$root"/scripts/lib/token_usage_*.py scripts/lib/
rm -f scripts/lib/token_usage_*_test.py
cat > tests/a_test.py <<'PY'
import unittest


class T(unittest.TestCase):
    def test_one(self):
        self.assertEqual(1, 1)

    def test_two(self):
        self.assertEqual(2, 2)
PY
git_ add -A
git_ commit -q -m "base"
git_ branch base

reset() { git_ checkout -q -f -B work base; }
run() { scripts/check-test-integrity "$@" 2>&1; }

# A test is deleted without justification.
reset
python3 - <<'PY'
import re
s = open('tests/a_test.py').read()
open('tests/a_test.py', 'w').write(s.split('    def test_two')[0].rstrip() + '\n')
PY
git_ commit -q -am "test: drop one"
out=$(run base) && code=0 || code=$?
check "report mode exits 0" test "$code" -eq 0
check "report names the file" grep -q 'tests/a_test.py' <<<"$out"
check "report names the test" grep -q 'test_two' <<<"$out"
out=$(run base --enforce) && code=0 || code=$?
check "--enforce exits non-zero" test "$code" -ne 0

# A justified removal passes.
git_ commit -q --allow-empty -m "test: justify" -m "Test-Integrity: the behaviour was removed"
out=$(run base --enforce) && code=0 || code=$?
check "a justified removal passes --enforce" test "$code" -eq 0
check "the finding prints as justified" grep -q 'justified: deleted test' <<<"$out"

# A rename is not a deletion.
reset
git_ mv tests/a_test.py tests/b_test.py
git_ commit -q -m "test: rename"
out=$(run base --enforce) && code=0 || code=$?
check "a renamed test file passes" test "$code" -eq 0

# A test added and removed within the range shows nothing.
reset
printf 'def test_extra():\n    assert True\n' > tests/c_test.py
git_ add -A; git_ commit -q -m "test: add"
git_ rm -q tests/c_test.py; git_ commit -q -m "test: remove"
out=$(run base --enforce) && code=0 || code=$?
check "a test added and removed in the range passes" test "$code" -eq 0

# A new skip is flagged; a clean range passes.
reset
sed -i 's/    def test_two/    @unittest.skip("later")\n    def test_two/' tests/a_test.py
git_ commit -q -am "test: skip"
out=$(run base --enforce) && code=0 || code=$?
check "a new skip fails --enforce" test "$code" -ne 0
check "the skip is named" grep -q 'new skip' <<<"$out"
reset
out=$(run base --enforce) && code=0 || code=$?
check "an unchanged range passes" test "$code" -eq 0

# A blank trailer justifies nothing; an unresolvable base is a usage error.
reset
git rm -q tests/a_test.py
git_ commit -q -m "test: delete" -m "Test-Integrity:"
out=$(run base --enforce) && code=0 || code=$?
check "an empty trailer clears nothing" test "$code" -eq 1
out=$(run no-such-ref) && code=0 || code=$?
check "an unresolvable base exits 2" test "$code" -eq 2

exit "$fail"
