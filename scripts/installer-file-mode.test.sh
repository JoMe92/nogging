#!/usr/bin/env bash
# Installed files keep the executable bit they have in the package (#263).
# Packs the repository, then installs from the packed distribution into a
# v2.2.0-shaped consumer that lacks scripts/session-pty-recorder. Offline: no
# network, tmux, Dolt, or agent binaries.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for tool in node npm tar git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ok   - skipped ($tool not installed)"
    exit 0
  fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/nogging-file-mode.XXXXXX")
trap 'rm -rf "$work"' EXIT

pass=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }
mode_of() { stat -c '%a' "$1"; }
is_exec() { [ -x "$1" ] && [ -f "$1" ]; }

(cd "$root" && npm pack --ignore-scripts --quiet --pack-destination "$work" >/dev/null)
tarball=$(ls "$work"/*.tgz)
tar -xzf "$tarball" -C "$work"
pkg="$work/package"
cli="$pkg/bin/cli.js"
flags=(--no-beads --no-hooks --no-systemd)
rec=scripts/session-pty-recorder

# An install shaped like v2.2.0: no recorder, no installed manifest.
legacy_repo() {
  local dir="$work/$1"
  mkdir -p "$dir"
  git init -q "$dir"
  (cd "$dir" && node "$cli" init "${flags[@]}" >/dev/null)
  rm -f "$dir/$rec" "$dir/.nogging/installed-manifest.json"
  printf '{"name":"legacy","nogging_version":"2.2.0"}\n' > "$dir/.nogging/config.json"
  echo "$dir"
}

run_update() { local dir=$1; shift; (cd "$dir" && node "$cli" update "${flags[@]}" "$@"); }

# --- legacy update creates the recorder executable
t=$(legacy_repo legacy)
run_update "$t" >/dev/null
[ -f "$t/$rec" ] || fail 'legacy update did not create the recorder'
is_exec "$t/$rec" || fail "legacy update created the recorder with mode $(mode_of "$t/$rec")"
ok 'legacy update creates scripts/session-pty-recorder executable'

# --- doctor's helper check does not FAIL for the recorder
doctor_out=$(cd "$t" && python3 scripts/nogg doctor 2>&1 || true)
if grep -E 'session-pty-recorder.*(missing or not executable|FAIL)|FAIL.*session-pty-recorder' <<<"$doctor_out" >/dev/null; then
  echo "$doctor_out" >&2
  fail 'doctor reports the recorder helper as failing'
fi
ok 'doctor session-helper check passes for the recorder'

# --- a 0664 copy with matching content is repaired once, then unchanged
chmod 0664 "$t/$rec"
out=$(run_update "$t" --dry-run --verbose)
grep -E "updated?  *$rec  *\(mode 0755\)" <<<"$out" >/dev/null || { echo "$out" >&2; fail 'dry-run did not report the repair'; }
[ "$(mode_of "$t/$rec")" = 664 ] || fail 'dry-run changed the mode'
ok 'dry-run reports the repair and leaves the mode alone'
out=$(run_update "$t" --verbose)
grep -E "updated?  *$rec  *\(mode 0755\)" <<<"$out" >/dev/null || { echo "$out" >&2; fail 'update did not report the repair'; }
is_exec "$t/$rec" || fail 'update did not repair the mode'
out=$(run_update "$t" --verbose)
if grep -E "(updated|created) +$rec" <<<"$out" >/dev/null; then echo "$out" >&2; fail 'second update touched the recorder'; fi
ok 'a 0664 helper with matching content is repaired once, then unchanged'

# --- a locally modified helper keeps mode and content; side file is executable
printf '#!/bin/sh\necho local\n' > "$t/$rec"
chmod 0664 "$t/$rec"
run_update "$t" >/dev/null
[ "$(cat "$t/$rec")" = $'#!/bin/sh\necho local' ] || fail 'modified helper content changed'
[ "$(mode_of "$t/$rec")" = 664 ] || fail 'modified helper mode changed'
is_exec "$t/$rec.nogging-new" || fail '.nogging-new is not executable'
cmp -s "$t/$rec.nogging-new" "$pkg/$rec" || fail '.nogging-new content differs from the package'
ok 'a modified helper keeps its mode and content; .nogging-new is executable'

# --- --force overwrite is executable; .orig keeps the local mode
run_update "$t" --force >/dev/null
is_exec "$t/$rec" || fail 'force-overwritten helper is not executable'
cmp -s "$t/$rec" "$pkg/$rec" || fail 'force did not write the package content'
[ "$(cat "$t/$rec.orig")" = $'#!/bin/sh\necho local' ] || fail '.orig content is wrong'
[ "$(mode_of "$t/$rec.orig")" = 664 ] || fail ".orig mode is $(mode_of "$t/$rec.orig"), expected 664"
ok '--force overwrite is executable and .orig keeps the local mode'

# --- a stale unmodified executable helper keeps the bit through update
t2=$(legacy_repo stale)
run_update "$t2" >/dev/null
printf 'stale\n' > "$t2/$rec"
chmod 0664 "$t2/$rec"
# Recorded as the installed digest so the stale content counts as unmodified.
node -e '
  const fs = require("fs"), crypto = require("crypto");
  const p = process.argv[1] + "/.nogging/installed-manifest.json";
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.files["scripts/session-pty-recorder"] = crypto.createHash("sha256").update("stale\n").digest("hex");
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$t2"
run_update "$t2" >/dev/null
cmp -s "$t2/$rec" "$pkg/$rec" || fail 'stale helper was not updated'
is_exec "$t2/$rec" || fail 'updated helper lost the executable bit'
ok 'a stale unmodified helper is updated and executable'

# --- sweep: every packaged executable file is executable after init; so is every listed one
t3="$work/fresh"
mkdir -p "$t3"
git init -q "$t3"
(cd "$t3" && node "$cli" init "${flags[@]}" >/dev/null)
missing=$(cd "$pkg" && node -e '
  const fs = require("fs"), path = require("path");
  const target = process.argv[1];
  const m = require("./bin/lib/manifest");
  const bad = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const rel = path.posix.join(dir === "." ? "" : dir, e.name);
      if (e.isDirectory()) walk(rel);
      else if (e.isFile() && (fs.statSync(rel).mode & 0o111)) {
        const dest = path.join(target, rel);
        if (fs.existsSync(dest) && !(fs.statSync(dest).mode & 0o111)) bad.push(rel);
      }
    }
  };
  for (const rel of m.verbatim) {
    const dest = path.join(target, rel);
    if ((fs.statSync(rel).mode & 0o111) && !(fs.statSync(dest).mode & 0o111)) bad.push(rel);
  }
  for (const d of m.verbatimDirs) walk(d.from);
  for (const rel of m.executable) {
    const dest = path.join(target, rel);
    if (!(fs.statSync(dest).mode & 0o111)) bad.push(rel);
  }
  console.log([...new Set(bad)].join("\n"));
' "$t3")
[ -z "$missing" ] || { echo "$missing" >&2; fail 'packaged executables installed non-executable (listed above)'; }
ok 'every executable packaged file installs executable'

echo "$pass checks passed"
