#!/usr/bin/env bash
# Self-tests for the convention lint in scripts/pi-extensions.test.sh: each case
# builds a throwaway .pi/nogging tree, runs the lint on it (--lint-only, so no
# Node is needed) and checks that a violation fails and names the file.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
runner="$root/scripts/pi-extensions.test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
pass() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# A clean tree with one extension: the base every case perturbs.
new_tree() {
  local t=$work/$1
  mkdir -p "$t/lib" "$t/extensions/demo-ext"
  printf '# x\n\n| `demo-ext` | entry | demo |\n' > "$t/README.md"
  cat > "$t/extensions/demo-ext/index.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { helper } from "./helper.ts";
import {
  other,
} from "../../lib/other.ts";
export default function (_pi: ExtensionAPI) {}
TS
  echo "$t"
}

# expect_fail <name> <needle> <tree>: lint must exit non-zero and print <needle>.
expect_fail() {
  local out
  if out=$("$runner" --home "$3" --lint-only 2>&1); then
    bad "$1: lint passed but should fail"
  elif grep -Fq -- "$2" <<<"$out"; then
    pass "$1"
  else
    bad "$1: failure did not mention '$2'"; echo "$out"
  fi
}

t=$(new_tree clean)
if "$runner" --home "$t" --lint-only >/dev/null 2>&1; then
  pass "a conforming tree passes"
else
  bad "a conforming tree passes"; "$runner" --home "$t" --lint-only || true
fi

t=$(new_tree bare)
printf 'import x from "some-package";\n' > "$t/extensions/demo-ext/helper.ts"
expect_fail "bare runtime import names the file and import" 'extensions/demo-ext/helper.ts:1: bare runtime import "some-package"' "$t"

t=$(new_tree pi-value)
printf 'import { Foo } from "@earendil-works/pi-coding-agent";\n' > "$t/extensions/demo-ext/helper.ts"
expect_fail "non-type Pi import is rejected" 'helper.ts:1: non-type import of Pi package "@earendil-works/pi-coding-agent"' "$t"

t=$(new_tree pi-inline-type)
printf 'import { type Foo } from "@earendil-works/pi-coding-agent";\n' > "$t/extensions/demo-ext/helper.ts"
expect_fail "inline type specifier still resolves at runtime" 'helper.ts:1: non-type import of Pi package' "$t"

t=$(new_tree pi-multiline)
printf 'import {\n  Foo,\n} from "@earendil-works/pi-coding-agent";\n' > "$t/extensions/demo-ext/helper.ts"
expect_fail "multi-line non-type Pi import is rejected" 'helper.ts:1: non-type import of Pi package' "$t"

t=$(new_tree dynamic)
printf 'export async function f() { return await import("lodash"); }\n' > "$t/extensions/demo-ext/helper.ts"
expect_fail "dynamic bare import is rejected" 'helper.ts:1: bare runtime import "lodash"' "$t"

t=$(new_tree no-ext)
printf 'import { a } from "./other";\n' > "$t/extensions/demo-ext/helper.ts"
expect_fail "relative import without .ts is rejected" 'helper.ts:1: relative import "./other"' "$t"

t=$(new_tree pkg)
printf '{}\n' > "$t/lib/package.json"
expect_fail "package.json is named" 'lib/package.json: package.json is not allowed' "$t"

t=$(new_tree no-index)
mkdir -p "$t/extensions/other-ext"
printf '// x\n' > "$t/extensions/other-ext/quota.ts"
printf '| `demo-ext` | `other-ext` |\n' > "$t/README.md"
expect_fail "missing index.ts is named" 'extensions/other-ext: index.ts is missing' "$t"

t=$(new_tree no-readme-entry)
mkdir -p "$t/extensions/other-ext"
printf 'export default function () {}\n' > "$t/extensions/other-ext/index.ts"
expect_fail "missing README entry is named" 'extensions/other-ext: README.md has no index entry' "$t"

t=$(new_tree not-kebab)
mkdir -p "$t/extensions/Bad_Name"
printf 'export default function () {}\n' > "$t/extensions/Bad_Name/index.ts"
printf '| `demo-ext` | `Bad_Name` |\n' > "$t/README.md"
expect_fail "non-kebab directory is named" 'extensions/Bad_Name: directory name is not kebab-case' "$t"

t=$(new_tree enum)
printf 'export enum Mode { A, B }\n' > "$t/lib/other.ts"
expect_fail "enum is rejected" 'lib/other.ts:1: enum is not erasable' "$t"

t=$(new_tree namespace)
printf 'namespace N { export const a = 1; }\n' > "$t/lib/other.ts"
expect_fail "namespace is rejected" 'lib/other.ts:1: namespace' "$t"

t=$(new_tree param-prop)
printf 'class C { constructor(private x: number) {} }\n' > "$t/lib/other.ts"
expect_fail "parameter property is rejected" 'lib/other.ts:1: constructor parameter property' "$t"

t=$(new_tree fixtures-first)
mkdir -p "$t/extensions/later-ext/test/fixtures"
printf '{}\n' > "$t/extensions/later-ext/test/fixtures/a.json"
if "$runner" --home "$t" --lint-only >/dev/null 2>&1; then
  pass "fixtures without an entry yet are not an extension"
else
  bad "fixtures without an entry yet are not an extension"
fi

t=$(new_tree skip-node)
printf 'import test from "node:test";\ntest("x", () => {});\n' > "$t/lib/x.test.ts"
shim=$work/shim; mkdir -p "$shim"
for c in bash dirname find grep awk sed sort basename mktemp rm mkdir cat env head tr; do
  p=$(command -v "$c" || true); [[ -n $p ]] && ln -sf "$p" "$shim/$c"
done
out=$(PATH="$shim" "$runner" --home "$t" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && grep -Fq 'skipped (node not installed)' <<<"$out"; then
  pass "missing node still lints, skips tests and passes"
else
  bad "missing node still lints, skips tests and passes"; echo "$out"
fi

if [[ $fail -ne 0 ]]; then exit 1; fi
echo "all pi-extensions lint checks passed"
