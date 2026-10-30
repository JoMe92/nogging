#!/usr/bin/env bash
# Regression checks for `nogg pi-ext` and its doctor NOTEs (TASK-PXG-005).
#
# Covered:
#   - `pi-ext list` is read-only: it prints each available extension, whether
#     `pi_extensions` enables it and whether the personal Pi settings name its
#     path, reads settings.json (never auth.json) under PI_CODING_AGENT_DIR, and
#     resolves the settings-dir-relative path Pi itself writes;
#   - `pi-ext install|remove <name>` run `pi install|remove <main checkout>/
#     .pi/nogging/extensions/<name>/index.ts`, never pass -l, and from a linked
#     worktree still use the main checkout's path;
#   - an unknown name or a missing pi refuses, names the fix and runs no pi;
#   - nogg itself never edits the Pi settings file;
#   - the doctor NOTEs: enabled but not installed, npm:pi-glm-usage next to an
#     enabled or installed glm-usage, and a dangling personal install path.
#
# pi is a PATH-injected stub that records its argv; PI_CODING_AGENT_DIR is a
# scratch directory, so the operator's real Pi settings are never touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/pi-home"
cat >"$work/bin/pi" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ["PI_ARGV"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
STUB
chmod +x "$work/bin/pi"
export PATH="$work/bin:$PATH" PI_ARGV="$work/pi-argv" PI_CODING_AGENT_DIR="$work/pi-home"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# make_root <dir> <pi_extensions JSON | ABSENT>
make_root() {
  local r="$1" value="$2" name
  mkdir -p "$r/.nogging/state" "$r/scripts" "$r/openspec"
  cp "$repo_root/scripts/nogg" "$repo_root/scripts/nogg_usage.py" "$repo_root/scripts/nogg_usage_zai.py" "$r/scripts/"
  cp -r "$repo_root/scripts/lib" "$r/scripts/lib"
  for name in glm-usage other-ext; do
    mkdir -p "$r/.pi/nogging/extensions/$name"
    : >"$r/.pi/nogging/extensions/$name/index.ts"
  done
  copy_host_config "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  python3 - "$r/.nogging/config.json" "$value" <<'PY'
import json, sys
path, value = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg.pop("pi_extensions", None)
if value != "ABSENT":
    cfg["pi_extensions"] = json.loads(value)
json.dump(cfg, open(path, "w"), indent=2)
PY
  git init -q -b main "$r"
  printf '.nogging/state/\n' >"$r/.gitignore"
  git -C "$r" add -A >/dev/null && git -C "$r" commit -q -m init
}

main="$work/main"; make_root "$main" '["glm-usage"]'
main=$(cd "$main" && pwd -P)
ext="$main/.pi/nogging/extensions/glm-usage/index.ts"
settings="$PI_CODING_AGENT_DIR/settings.json"
pi_calls() { [ -f "$PI_ARGV" ] && cat "$PI_ARGV" || true; }
reset_pi() { rm -f "$PI_ARGV" "$settings" "$PI_CODING_AGENT_DIR/auth.json"; }
nogg() { (cd "$1" && shift && NOGGING_ROOT="$PWD" ./scripts/nogg "$@"); }

# --- install ----------------------------------------------------------------
reset_pi
if nogg "$main" pi-ext install glm-usage >"$work/out" 2>&1 \
   && [ "$(pi_calls)" = "[\"install\", \"$ext\"]" ]; then
  ok "install runs pi install with the main checkout index.ts and no -l"
else bad "install argv"; cat "$work/out"; pi_calls; fi

reset_pi
if nogg "$main" pi-ext remove glm-usage >"$work/out" 2>&1 \
   && [ "$(pi_calls)" = "[\"remove\", \"$ext\"]" ]; then
  ok "remove runs pi remove with the same path"
else bad "remove argv"; cat "$work/out"; pi_calls; fi

# --- linked worktree --------------------------------------------------------
git -C "$main" worktree add -q -b linked "$work/linked"
reset_pi
if nogg "$work/linked" pi-ext install glm-usage >"$work/out" 2>&1 \
   && [ "$(pi_calls)" = "[\"install\", \"$ext\"]" ]; then
  ok "install from a linked worktree uses the main checkout path"
else bad "linked worktree install"; cat "$work/out"; pi_calls; fi
reset_pi
if nogg "$work/linked" pi-ext remove glm-usage >"$work/out" 2>&1 \
   && [ "$(pi_calls)" = "[\"remove\", \"$ext\"]" ]; then
  ok "remove from a linked worktree uses the main checkout path"
else bad "linked worktree remove"; cat "$work/out"; pi_calls; fi

# --- refusals ---------------------------------------------------------------
for action in install remove; do
  reset_pi
  if ! nogg "$main" pi-ext "$action" no-such-ext >"$work/out" 2>&1 \
     && grep -q 'no-such-ext' "$work/out" && grep -q 'glm-usage' "$work/out" && [ -z "$(pi_calls)" ]; then
    ok "$action of an unknown name refuses, names the available extensions, runs no pi"
  else bad "$action unknown name"; cat "$work/out"; pi_calls; fi
done
reset_pi
if ! nogg "$main" pi-ext install '../escape' >"$work/out" 2>&1 && [ -z "$(pi_calls)" ]; then
  ok "a path-like name is refused as unknown"
else bad "path-like name"; cat "$work/out"; fi

mkdir -p "$work/nopi"
for action in install remove; do
  if ! PATH="$work/nopi:$(dirname "$(command -v python3)"):$(dirname "$(command -v git)"):/usr/bin:/bin" \
       nogg "$main" pi-ext "$action" glm-usage >"$work/out" 2>&1 \
     && grep -qi 'pi' "$work/out" && grep -qi 'not installed\|not found\|missing' "$work/out" && [ -z "$(pi_calls)" ]; then
    ok "$action refuses when pi is missing"
  else bad "$action without pi"; cat "$work/out"; fi
done

# --- list -------------------------------------------------------------------
reset_pi
printf 'SECRET-KEY-VALUE' >"$PI_CODING_AGENT_DIR/auth.json"
python3 - "$settings" "$ext" <<'PY'
import json, os, sys
settings, ext = sys.argv[1:]
# Pi writes local package paths relative to the settings directory.
rel = os.path.relpath(ext, os.path.dirname(settings))
json.dump({"packages": [rel, "npm:other"]}, open(settings, "w"))
PY
before=$(sha256sum "$settings" "$PI_CODING_AGENT_DIR/auth.json")
nogg "$main" pi-ext list >"$work/out" 2>&1 || { bad "list exits non-zero"; cat "$work/out"; }
if grep -E '^glm-usage\b.*enabled.*installed' "$work/out" | grep -vq 'not installed' \
   && grep -E '^other-ext\b' "$work/out" | grep -q 'not enabled' \
   && grep -E '^other-ext\b' "$work/out" | grep -q 'not installed'; then
  ok "list shows enabled and installed state, resolving Pi's relative path"
else bad "list output"; cat "$work/out"; fi
grep -q 'SECRET-KEY-VALUE' "$work/out" && bad "list printed auth.json" || ok "list never prints auth.json"
[ "$before" = "$(sha256sum "$settings" "$PI_CODING_AGENT_DIR/auth.json")" ] && [ -z "$(pi_calls)" ] \
  && ok "list is read-only and runs no pi" || bad "list changed state"

reset_pi
nogg "$main" pi-ext list >"$work/out" 2>&1 || bad "list without settings"
grep -E '^glm-usage\b' "$work/out" | grep -q 'not installed' \
  && ok "list tolerates absent Pi settings" || { bad "list absent settings"; cat "$work/out"; }

# --- nogg never edits Pi settings; install/remove leave the file alone ------
reset_pi; printf '{"packages":["npm:keep"]}' >"$settings"
before=$(sha256sum "$settings")
nogg "$main" pi-ext install glm-usage >/dev/null 2>&1; nogg "$main" pi-ext remove glm-usage >/dev/null 2>&1
[ "$before" = "$(sha256sum "$settings")" ] && ok "nogg leaves the Pi settings file to pi" || bad "settings edited"

# --- doctor NOTEs -----------------------------------------------------------
notes() { # notes <root> <settings JSON | NONE>
  reset_pi
  [ "$2" = NONE ] || printf '%s' "$2" >"$settings"
  NOGGING_ROOT="$1" python3 - "$1/scripts/nogg" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1])
for line in m["pi_extension_notes"]():
    print(line)
PY
}
out=$(notes "$main" NONE)
grep -q 'glm-usage' <<<"$out" && grep -q 'pi-ext install glm-usage' <<<"$out" \
  && ok "NOTE: enabled but not personally installed" || { bad "enabled-not-installed NOTE"; echo "$out"; }

out=$(notes "$main" "{\"packages\":[\"$ext\"]}")
grep -q 'not personally installed\|not installed' <<<"$out" && bad "installed extension still noted" \
  || ok "no NOTE when the enabled extension is installed"

out=$(notes "$main" '{"packages":["npm:pi-glm-usage"]}')
grep -q 'pi remove npm:pi-glm-usage' <<<"$out" \
  && ok "NOTE: npm:pi-glm-usage overlaps an enabled glm-usage" || { bad "overlap NOTE"; echo "$out"; }

other="$work/other"; make_root "$other" '[]'
out=$(notes "$other" '{"packages":["npm:pi-glm-usage"]}')
grep -q 'npm:pi-glm-usage' <<<"$out" && bad "overlap NOTE without glm-usage enabled or installed" \
  || ok "no overlap NOTE when glm-usage is neither enabled nor installed"
other_ext=$(cd "$other" && pwd -P)/.pi/nogging/extensions/glm-usage/index.ts
out=$(notes "$other" "{\"packages\":[\"npm:pi-glm-usage\",\"$other_ext\"]}")
grep -q 'pi remove npm:pi-glm-usage' <<<"$out" \
  && ok "NOTE: overlap with a personally installed glm-usage" || { bad "overlap installed NOTE"; echo "$out"; }

gone="$work/gone/.pi/nogging/extensions/glm-usage/index.ts"
out=$(notes "$main" "{\"packages\":[\"$gone\"]}")
grep -q "$gone" <<<"$out" && grep -qi 'no longer exists\|does not exist' <<<"$out" \
  && ok "NOTE: dangling personal install path" || { bad "dangling NOTE"; echo "$out"; }
out=$(notes "$main" '{"packages":["/opt/unrelated/index.ts"]}')
grep -q '/opt/unrelated' <<<"$out" && bad "unrelated path flagged dangling" || ok "an unrelated local package is not flagged"

[ "$fail" -eq 0 ] && echo "all pi-ext checks passed"
exit "$fail"
