#!/usr/bin/env bash
# Fixtures that copy the host .nogging/config.json must pin their session
# backend instead of inheriting the host's (design Decisions 5-7,
# install-mode-test-pin / TASK-IMT-002).
#
#   (a) scripts/lib/test-fixture-config.sh copy_host_config unit checks;
#   (b) the affected suites pass from a scratch checkout whose host config
#       selects herdr (offline: no herdr binary, tmux server or live session;
#       agent binaries are the test-agents.sh stubs, CI has no codex or agy);
#   (c) a static guard: a scripts/*.test.sh that reads the host config without
#       copy_host_config fails unless it carries a
#       `# fixture-backend-pin: allow - <reason>` comment.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/lib/test-env.sh
source "$here/lib/test-env.sh"
# shellcheck source=scripts/lib/test-fixture-config.sh
source "$here/lib/test-fixture-config.sh"
# shellcheck source=scripts/lib/test-agents.sh
source "$here/lib/test-agents.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# The suites that launch a session through a copied host config. Keep this the
# single list; the guard in (c) keeps the set of copying suites honest.
AFFECTED_SUITES=(
  antigravity-usage codex-exact-resume nogg planning-launch-profile planning-role
  session session-effort session-launch-agent-binary session-model-forwarding
  session-model-record session-models session-observability session-pid-identity
  session-startup session-tier session-tier-overrides session-tmux-fenced-server
  session-usage-collection usage-gate usage-history worktree-workflow
)

# --- (a) helper unit checks --------------------------------------------------
src="$work/host.json"
cat >"$src" <<'JSON'
{"name": "Host", "session_backend": "herdr", "personas": {"lead": {"name": "L"}},
 "tier_overrides": {"standard": {"claude": "m"}}, "unknown_key": [1, 2, {"a": null}]}
JSON
copy_host_config "$src" "$work/nested/dir/pinned.json"
python3 - "$src" "$work/nested/dir/pinned.json" <<'PY' && ok "helper pins tmux, creates dir, keeps every other key" || bad "helper default pin"
import json, sys
host, out = (json.load(open(p)) for p in sys.argv[1:3])
assert out.pop("session_backend") == "tmux"
host.pop("session_backend")
assert out == host, (out, host)
PY
copy_host_config "$src" "$work/explicit.json" herdr
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["session_backend"])' "$work/explicit.json")" == herdr ]] \
  && ok "helper honours an explicit backend" || bad "helper explicit backend"
printf '{"name": "NoBackend"}\n' >"$work/nokey.json"
copy_host_config "$work/nokey.json" "$work/nokey-out.json"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["session_backend"])' "$work/nokey-out.json")" == tmux ]] \
  && ok "helper adds tmux when the host sets no backend" || bad "helper without host key"
bash "$here/lib/test-fixture-config.sh" "$src" "$work/cli.json" \
  && [[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["session_backend"])' "$work/cli.json")" == tmux ]] \
  && ok "helper CLI entry pins tmux" || bad "helper CLI entry"

# --- (c) static guard --------------------------------------------------------
guard_out="$(python3 - "$here" <<'PY'
import pathlib, re, sys
here = pathlib.Path(sys.argv[1])
host = re.compile(
    r"""(\$\{?(?:repo_root|source_root)\}?|\$\{?here\}?/\.\.)/\.nogging/config\.json"""
    r"""|\b(?:source|scripts\.parent|src)\s*/\s*['"]\.nogging/config\.json['"]""")
for path in sorted(here.glob("*.test.sh")):
    if path.name == "fixture-backend-pin.test.sh":
        continue
    text = path.read_text()
    if not host.search(text):
        continue
    if "copy_host_config" in text or "test-fixture-config.sh" in text:
        continue
    if re.search(r"^#\s*fixture-backend-pin: allow - \S", text, re.M):
        continue
    print(path.name)
PY
)"
if [[ -z "$guard_out" ]]; then
  ok "every suite that reads the host config uses copy_host_config or is allowlisted"
else
  while IFS= read -r name; do bad "$name copies the host .nogging/config.json without copy_host_config"; done <<<"$guard_out"
fi
for name in "${AFFECTED_SUITES[@]}"; do
  grep -q "test-fixture-config.sh" "$here/$name.test.sh" \
    && grep -qE "copy_host_config|test-fixture-config\.sh" "$here/$name.test.sh" \
    || bad "affected suite $name does not use the helper"
done

# --- (b) affected suites under a herdr host config ---------------------------
scratch="$work/checkout"
mkdir -p "$scratch"
git -C "$repo_root" ls-files -z | (cd "$repo_root" && tar --null -T - -cf -) | tar -x -C "$scratch"
python3 - "$scratch/.nogging/config.json" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["session_backend"] = "herdr"
json.dump(cfg, open(path, "w"), indent=2)
PY
git -C "$scratch" init -q -b develop
git -C "$scratch" add -A
git -C "$scratch" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm seed
use_agent_stubs
export XDG_CACHE_HOME="$work/cache" CODEX_HOME="$work/codex" AGY_NOGG_USAGE_PROBE=0 \
  NOGG_LAUNCH_SETTLE_SECONDS=0.25
mkdir -p "$XDG_CACHE_HOME" "$CODEX_HOME"
for name in "${AFFECTED_SUITES[@]}"; do
  log="$work/$name.log"
  if (cd "$scratch" && bash "scripts/$name.test.sh") >"$log" 2>&1; then
    ok "$name passes with a herdr host config"
  else
    bad "$name fails with a herdr host config"
    tail -n 25 "$log" | sed 's/^/     | /'
  fi
done

exit "$fail"
