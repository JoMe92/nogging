#!/usr/bin/env bash
# Packed install, update and remove of the dashboard (TASK-DSH-011).
#
# Verifies that:
#   - npm pack carries the modules and every static asset, and no test file;
#   - the fonts, the licence and the logo still match their source in docs/assets;
#   - init installs the assets byte for byte, and the installed `nogg dashboard` serves them;
#   - update restores them in a consumer that lacks them, and the dashboard works there;
#   - remove deletes all of it and keeps the consumer's configuration.
#
# Offline: a stub `bd`, loopback on port 0, no Dolt and no sleeps.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v npm >/dev/null 2>&1; then
  printf 'SKIP: packed dashboard regression (npm unavailable)\n'
  exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# 1. The fonts, the licence and the logo are copies: docs/assets is not packaged.
for pair in \
  fonts/OFL.txt fonts/poppins-latin-400-normal.woff2 fonts/poppins-latin-500-normal.woff2 \
  fonts/poppins-latin-600-normal.woff2 fonts/poppins-latin-700-normal.woff2 \
  images/apple-touch-icon.png images/favicon.svg images/nogging-mark.svg images/nogging-mark-dark.svg
do
  cmp "$root/docs/assets/$pair" "$root/scripts/dashboard/$pair" \
    || fail "scripts/dashboard/$pair drifted from docs/assets/$pair"
done

# 2. Pack the repository and inspect the archive.
(cd "$root" && npm pack --ignore-scripts --json --pack-destination "$scratch" >"$scratch/pack.json")
archive=$(node -e 'console.log(require(process.argv[1])[0].filename)' "$scratch/pack.json")
tar -xzf "$scratch/$archive" -C "$scratch"
package="$scratch/package"

diff -r "$root/scripts/dashboard" "$package/scripts/dashboard" >"$scratch/diff.out" 2>&1 \
  || fail "the package's scripts/dashboard differs from the source: $(cat "$scratch/diff.out")"
for module in "$root"/scripts/lib/dashboard_*.py; do
  name=$(basename "$module")
  case "$name" in
    *_test.py) test ! -e "$package/scripts/lib/$name" || fail "package shipped $name" ;;
    *) cmp "$module" "$package/scripts/lib/$name" || fail "package lacks or changed $name" ;;
  esac
done
if find "$package/scripts" \( -name '*_test.py' -o -name '*dashboard*.test.sh' -o -name '__pycache__' -o -name '*.pyc' \) | grep -q .; then
  fail "package shipped dashboard tests or bytecode under scripts/"
fi

# 3. A consumer repository and a stub `bd`.
consumer="$scratch/consumer with spaces"
mkdir -p "$consumer" "$scratch/bin"
git -C "$consumer" init -q
cat >"$scratch/bin/bd" <<'STUB'
#!/usr/bin/env bash
# `bd --readonly --sandbox <verb> …`
case "${3:-}" in
  list) printf '[{"id":"SPEC-pack","title":"Packed Bead","status":"open","priority":2,"issue_type":"task"}]\n' ;;
  *) printf '[]\n' ;;
esac
STUB
chmod +x "$scratch/bin/bd"

cli() {
  (
    cd "$consumer"
    unset NOGGING_ROOT PYTHONDONTWRITEBYTECODE
    for v in $(compgen -e | grep '^NOGG_' || true); do unset "$v"; done
    node "$package/bin/cli.js" "$@" --no-beads --no-hooks --no-systemd >/dev/null
  )
}

# `nogg dashboard` from the installed copy serves its shell, a font and the stub's Bead.
serves() {
  (
    cd "$consumer"
    unset NOGGING_ROOT PYTHONDONTWRITEBYTECODE
    for v in $(compgen -e | grep '^NOGG_' || true); do unset "$v"; done
    PATH="$scratch/bin:$PATH" python3 - "$consumer" <<'PY'
import json, select, signal, subprocess, sys, threading, time, urllib.request
from pathlib import Path

consumer = Path(sys.argv[1])
process = subprocess.Popen(["./scripts/nogg", "dashboard", "--port", "0"], cwd=consumer, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as reply:
        return reply.read()


try:
    ready, _, _ = select.select([process.stdout], [], [], 30)
    line = process.stdout.readline() if ready else ""
    assert "127.0.0.1:" in line, f"the installed dashboard printed no address: {line!r}"
    port = int(line.split("127.0.0.1:")[1].split("/")[0])

    assert b"<title>" in get(port, "/"), "the shell did not load"
    font = "fonts/poppins-latin-400-normal.woff2"
    served = get(port, f"/assets/{font}")
    assert served == (consumer / "scripts/dashboard" / font).read_bytes(), "the served font differs"

    deadline, gate, beads = time.monotonic() + 30, threading.Event(), None
    while time.monotonic() < deadline:
        beads = json.loads(get(port, "/api/v1/beads"))
        if beads["data"]:
            break
        gate.wait(0.05)
    ids = [bead["id"] for bead in (beads["data"] or {}).get("beads", [])]
    assert ids == ["SPEC-pack"], f"the installed dashboard did not read the stub: {beads}"
    assert not (consumer / ".nogging/state/dashboard").exists(), "a loopback run created state"
finally:
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=20)
    process.stdout.close()
assert process.returncode == 0, f"the dashboard ended with {process.returncode}"
PY
  )
}

same_assets() {
  diff -r "$package/scripts/dashboard" "$consumer/scripts/dashboard" >"$scratch/diff.out" 2>&1 \
    || fail "$1: installed assets differ from the package: $(cat "$scratch/diff.out")"
  for font in "$root"/scripts/dashboard/fonts/*.woff2; do
    cmp "$font" "$consumer/scripts/dashboard/fonts/$(basename "$font")" || fail "$1: font bytes changed"
  done
}

# 4. init.
cli init
same_assets init
test ! -e "$consumer/scripts/lib/dashboard_server_test.py" || fail "init installed a test file"
serves || fail "the dashboard did not work after init"

# 5. update, in a consumer that predates the dashboard.
cfg_file="$consumer/.nogging/config.json"
python3 -c '
import json, sys
config = json.load(open(sys.argv[1]))
config["consumer_note"] = "keep me"
json.dump(config, open(sys.argv[1], "w"), indent=2)
' "$cfg_file"
rm -rf "$consumer/scripts/dashboard" "$consumer"/scripts/lib/dashboard_*.py
cli update
same_assets update
serves || fail "the dashboard did not work after update"

# 6. remove.
cli remove
# `remove` deletes files and leaves empty directories, as it does for every managed tree.
if find "$consumer/scripts" -type f \( -path '*/scripts/dashboard/*' -o -name 'dashboard_*' \) 2>/dev/null | grep -q .; then
  fail "remove left dashboard files"
fi
grep -q '"consumer_note": "keep me"' "$cfg_file" || fail "remove dropped the consumer's configuration"

printf 'ok - packed dashboard: payload, asset drift, init, update, remove\n'
