#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { case "$tmp" in /tmp/tmp.*) rm -rf -- "$tmp" ;; esac; }
trap cleanup EXIT

fail=0
pass() { printf 'ok   - %s\n' "$1"; }
fail_() { printf 'FAIL - %s\n' "$1" >&2; fail=1; }

copy="$tmp/copy"
mkdir -p "$copy"
cp "$root/package.json" "$root/package-lock.json" "$copy/"
mkdir -p "$copy/bin" "$copy/scripts"
printf 'module.exports = {};\n' >"$copy/bin/cli.js"
cp "$root/scripts/release-artifacts" "$copy/scripts/release-artifacts"
chmod +x "$copy/scripts/release-artifacts"

out="$tmp/out"
( cd "$copy" && bash scripts/release-artifacts "$out" ) >"$tmp/run.log" 2>&1 \
  && pass "release-artifacts runs to completion" \
  || { fail_ "release-artifacts exited non-zero"; cat "$tmp/run.log"; }

tarball=$(find "$out" -maxdepth 1 -name '*.tgz' | head -1)
[[ -n "$tarball" && -f "$tarball" ]] \
  && pass "a package tarball was written" \
  || fail_ "no .tgz artifact found in $out"

[[ -f "$tarball.sha256" ]] \
  && pass "a checksum file was written for the tarball" \
  || fail_ "no .sha256 file found for $tarball"

if [[ -f "$tarball.sha256" && -f "$tarball" ]]; then
  ( cd "$out" && sha256sum -c "$(basename "$tarball.sha256")" >/dev/null 2>&1 ) \
    && pass "the checksum verifies against the tarball" \
    || fail_ "the checksum does not verify against the tarball"
fi

if [[ -f "$out/sbom.cdx.json" ]]; then
  node -e "JSON.parse(require('fs').readFileSync('$out/sbom.cdx.json'))" \
    && pass "sbom.cdx.json is valid JSON" \
    || fail_ "sbom.cdx.json is not valid JSON"
  grep -q '"bomFormat": "CycloneDX"' "$out/sbom.cdx.json" \
    && pass "sbom.cdx.json declares the CycloneDX format" \
    || fail_ "sbom.cdx.json missing bomFormat"
elif [[ -f "$out/sbom-not-applicable.txt" ]]; then
  [[ -s "$out/sbom-not-applicable.txt" ]] \
    && pass "SBOM not applicable, and a reason was recorded" \
    || fail_ "sbom-not-applicable.txt exists but is empty"
else
  fail_ "neither sbom.cdx.json nor sbom-not-applicable.txt was written"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "all release-artifacts checks passed"
else
  echo "release-artifacts checks FAILED" >&2
fi
exit "$fail"
