#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { case "$tmp" in /tmp/tmp.*) rm -r -- "$tmp" ;; esac; }
trap cleanup EXIT

expect_failure() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL - bad %s fixture passed\n' "$name" >&2
    exit 1
  fi
  printf 'ok   - bad %s fixture fails its gate\n' "$name"
}

mkdir -p "$tmp/secrets" "$tmp/links" "$tmp/package/scripts" "$tmp/dependencies/bin"
printf 'fake-test-token=AKIAXXXXXXXXXXXXXXXX\n' >"$tmp/secrets/bad.txt"
expect_failure secret "$root/scripts/ci-security-gates.sh" secrets "$tmp/secrets"

printf '[missing](does-not-exist.md)\n' >"$tmp/links/README.md"
expect_failure link "$root/scripts/ci-security-gates.sh" links "$tmp/links"

printf '{"files":["docs"]}\n' >"$tmp/package/package.json"
cp "$root/scripts/package-manifest.test.sh" "$tmp/package/scripts/"
git -C "$tmp/package" init -q
git -C "$tmp/package" add package.json scripts/package-manifest.test.sh
expect_failure package "$root/scripts/ci-security-gates.sh" package "$tmp/package"

printf '#!/usr/bin/env bash\nprintf "high vulnerability fixture\\n" >&2\nexit 1\n' \
  >"$tmp/dependencies/bin/npm"
chmod +x "$tmp/dependencies/bin/npm"
expect_failure dependency env PATH="$tmp/dependencies/bin:$PATH" \
  "$root/scripts/ci-security-gates.sh" dependencies "$tmp/dependencies"

# A real, non-accepted high-severity advisory must still fail the gate --
# the waiver list is narrow, not a blanket bypass.
mkdir -p "$tmp/dependencies-unwaived/bin"
cat >"$tmp/dependencies-unwaived/bin/npm" <<'FAKE'
#!/usr/bin/env bash
printf '{"vulnerabilities":{"some-pkg":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-0000-0000-0000"}]}}}\n'
exit 1
FAKE
chmod +x "$tmp/dependencies-unwaived/bin/npm"
expect_failure unwaived-dependency env PATH="$tmp/dependencies-unwaived/bin:$PATH" \
  "$root/scripts/ci-security-gates.sh" dependencies "$tmp/dependencies-unwaived"

# Only the accepted GHSA-vfj7-8cjw-p6xm advisory present must pass.
mkdir -p "$tmp/dependencies-waived/bin"
cat >"$tmp/dependencies-waived/bin/npm" <<'FAKE'
#!/usr/bin/env bash
printf '{"vulnerabilities":{"braces":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-vfj7-8cjw-p6xm"}]}}}\n'
exit 1
FAKE
chmod +x "$tmp/dependencies-waived/bin/npm"
if ! env PATH="$tmp/dependencies-waived/bin:$PATH" \
    "$root/scripts/ci-security-gates.sh" dependencies "$tmp/dependencies-waived" >/dev/null 2>&1; then
  printf 'FAIL - accepted-only advisory fixture did not pass\n' >&2
  exit 1
fi
printf 'ok   - accepted-only advisory fixture passes, unwaived one still fails\n'

"$root/scripts/ci-security-gates.sh" secrets "$root"
"$root/scripts/ci-security-gates.sh" links "$root"
printf 'CI security gate negative fixtures: ok\n'
