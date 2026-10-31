#!/usr/bin/env bash
# TASK-PXG-003 (openspec/changes/pi-extensions-glm-usage): `nogg usage --agent pi`.
#
# Covered, offline, with a stub `pi` and injected opener callables:
#   - the module unit tests (nogg_usage_zai_test.py);
#   - a fresh snapshot reports known windows with projection and fit against the cap,
#     model_group zai-coding-plan and an unknown account;
#   - a stale snapshot is refreshed by one probe (stub pi + injected opener) and
#     rewritten with source nogg-probe at mode 0600; a failed probe never falls back;
#   - no key makes no request; the probe is disabled by PI_NOGG_USAGE_PROBE=0 and
#     then no pi command runs; another provider is unknown and names the provider;
#   - the three Pi hints reach `nogg usage`, the unknown-admitted launch warning and
#     the doctor quota note; doctor never probes;
#   - a Pi launch whose weekly window is over the cap exits 75 before any side effect;
#   - a sentinel key never appears in any output, snapshot, record or error text.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

while IFS= read -r inherited; do
  case "$inherited" in
    NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_*|GIT_*|PI_*|XDG_*|*_PROXY|*_proxy) unset "$inherited" ;;
  esac
done < <(compgen -e)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out" 2>/dev/null || true; fail=1; }

SENTINEL="sk-SENTINEL-pi-usage-0123456789abcdef"

python3 -I "$here/nogg_usage_zai_test.py" >"$out" 2>&1 && ok "Z.ai quota module unit tests" || bad "Z.ai quota module unit tests"

mkdir -p "$work/bin" "$work/home/pi-agent" "$work/cache"
# The stub pi records every call. Exit 1 / empty output model a missing key.
cat >"$work/bin/pi" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == auth && "${2:-}" == print-api-key ]]; then
  printf '%s\n' "$*" >>"${PI_STUB_LOG:?}"
  [[ -n "${PI_STUB_EXIT:-}" ]] && exit "$PI_STUB_EXIT"
  printf '%s\n' "${PI_STUB_KEY:-}"; exit 0
fi
exit 0
STUB
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then printf '[{"id":"%s","title":"stub","labels":[]}]\n' "${2:-}"; exit 0; fi
if [[ "${1:-}" == "dep" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
echo "stub bd: refusing $*" >&2; exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
if [[ "$cmd" == new-session ]]; then a=("$@"); for i in "${!a[@]}"; do [[ "${a[i]}" == -s ]] && : >"$d/live-${a[i+1]}"; done; fi
case "$cmd" in has-session) [[ -e "$d/live-${2:-}" ]] || exit 1 ;; *) : ;; esac
STUB
chmod +x "$work/bin/"*
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; stub_agent_binaries "$work/bin"
export PATH="$work/bin:$PATH"
export HOME="$work/home" XDG_CACHE_HOME="$work/cache" PI_CODING_AGENT_DIR="$work/home/pi-agent" CODEX_HOME="$work/codex"
export PI_STUB_LOG="$work/pi.log"
: >"$PI_STUB_LOG"
snapshot="$XDG_CACHE_HOME/nogging/usage/pi-zai.json"

write_snapshot() {  # write_snapshot <age seconds> <short used> <weekly used> [reset hours short] [reset hours weekly]
  python3 - "$snapshot" "$@" <<'PY'
import datetime as dt, json, os, sys
path, age, short, weekly = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
rs = float(sys.argv[5]) if len(sys.argv) > 5 else 2
rw = float(sys.argv[6]) if len(sys.argv) > 6 else 72
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
iso = lambda t: t.isoformat().replace('+00:00', 'Z')
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
json.dump({'schema_version': 1, 'provider': 'zai', 'source': 'pi-extension', 'observed_at': iso(now - dt.timedelta(seconds=age)),
           'plan_level': 'pro', 'windows': {'short': {'used_percent': short, 'resets_at': iso(now + dt.timedelta(hours=rs))},
                                            'weekly': {'used_percent': weekly, 'resets_at': iso(now + dt.timedelta(hours=rw))}}},
          open(path, 'w'))
PY
}

# --- the report and the gate -------------------------------------------------
write_snapshot 120 37 21
"$nogg" usage --agent pi --model zai/glm-5 --json >"$out"
python3 - "$out" <<'PY' && ok "fresh snapshot: both windows known, group zai-coding-plan, account unknown, fit against the cap" || bad "fresh snapshot report"
import json, sys
r = json.load(open(sys.argv[1]))
assert r['provider'] == 'pi' and r['model_group'] == 'zai-coding-plan' and r['account'] is None, r
assert [w['bucket'] for w in r['windows']] == ['short', 'weekly'] and all(w['status'] == 'known' for w in r['windows']), r
assert [w['used_percent'] for w in r['windows']] == [37, 21], r
assert r['gate']['fits'] is True and all(w['fits'] for w in r['gate']['windows']), r['gate']
PY
[[ ! -s "$PI_STUB_LOG" ]] && ok "fresh snapshot: no pi command ran" || bad "fresh snapshot probed"

"$nogg" usage --agent pi --model zai/glm-5 >"$out"
grep -qF "pi (model zai/glm-5) usage" "$out" && grep -qF "short: 37% used" "$out" && ok "text report names the windows" || bad "text report"

# Weekly window over the cap.
write_snapshot 120 10 99
"$nogg" usage --agent pi --model zai/glm-5 --json >"$out"
python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["gate"]; assert g["decision"] == "denied" and g["fits"] is False' "$out" \
  && ok "weekly over the cap does not fit" || bad "weekly gate"

# Other provider: both windows unknown, naming the provider.
printf '{"defaultProvider":"anthropic"}\n' >"$PI_CODING_AGENT_DIR/settings.json"
printf '{"zai":{"key":"%s"}}\n' "$SENTINEL" >"$PI_CODING_AGENT_DIR/auth.json"
"$nogg" usage --agent pi --json >"$out"
python3 - "$out" <<'PY' && ok "other provider (settings defaultProvider): unknown, naming the provider" || bad "other provider"
import json, sys
r = json.load(open(sys.argv[1]))
assert r['status'] == 'unknown' and r['model_group'] is None, r
assert all(w['reason'] == 'no usage source for Pi provider anthropic' for w in r['windows']), r
PY
grep -qF "$SENTINEL" "$out" && bad "auth.json content leaked" || ok "auth.json is never read"
"$nogg" usage --agent pi --model zai/glm-5 --json >"$out"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"]=="known"' "$out" \
  && ok "the model's zai/ prefix wins over defaultProvider" || bad "model prefix precedence"
rm "$PI_CODING_AGENT_DIR/auth.json"
"$nogg" usage --agent pi --json >"$out"; grep -qF "Pi provider anthropic" "$out" || bad "provider rerun"
rm "$PI_CODING_AGENT_DIR/settings.json"
"$nogg" usage --agent pi --json >"$out"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["status"]=="unknown" and "provider unknown" in r["windows"][0]["reason"]' "$out" \
  && ok "no provider anywhere is unknown, never guessed" || bad "unresolved provider"

# --- the probe: in-process, injected run and opener ---------------------------
probe_case() {  # probe_case <label> <python body>; the body asserts
  python3 - "$repo_root/scripts" "$snapshot" "$work" "$SENTINEL" <<PY && ok "$1" || { bad "$1"; }
import datetime as dt, json, os, stat, subprocess, sys, urllib.error
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import nogg_usage as u
snapshot, work, SENTINEL = sys.argv[2], sys.argv[3], sys.argv[4]
NOW = dt.datetime.now(dt.timezone.utc)
body = json.dumps({'code': 200, 'data': {'level': 'pro', 'limits': [
    {'type': 'TOKENS_LIMIT', 'unit': 3, 'percentage': 37, 'nextResetTime': int((NOW.timestamp() + 7200) * 1000)},
    {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 21, 'nextResetTime': int((NOW.timestamp() + 259200) * 1000)}]}}).encode()
class R:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *a): return False
    sent = False
    def read(self, n=-1):
        if self.sent: return b''
        self.sent = True
        return body
calls = {'run': 0, 'open': 0}
def run_ok(argv, **kw):
    calls['run'] += 1
    return subprocess.CompletedProcess(argv, 0, stdout=SENTINEL + '\n', stderr='')
def run_nokey(argv, **kw):
    calls['run'] += 1
    return subprocess.CompletedProcess(argv, 1, stdout='', stderr='')
def opener_ok(request, timeout=None):
    calls['open'] += 1
    return R()
def opener_fail(request, timeout=None):
    calls['open'] += 1
    raise RuntimeError('boom ' + request.get_header('Authorization'))
def opener_401(request, timeout=None):
    calls['open'] += 1
    raise urllib.error.HTTPError(request.full_url, 401, SENTINEL, {}, None)
which = lambda name: '/usr/bin/pi'
def age(seconds):
    row = json.load(open(snapshot))
    row['observed_at'] = (NOW - dt.timedelta(seconds=seconds)).isoformat().replace('+00:00', 'Z')
    json.dump(row, open(snapshot, 'w'))
def stale(seconds=1200):
    os.makedirs(os.path.dirname(snapshot), mode=0o700, exist_ok=True)
    json.dump({'schema_version': 1, 'provider': 'zai', 'source': 'pi-extension',
               'observed_at': (NOW - dt.timedelta(seconds=seconds)).isoformat().replace('+00:00', 'Z'),
               'windows': {'short': {'used_percent': 5, 'resets_at': (NOW + dt.timedelta(hours=2)).isoformat().replace('+00:00', 'Z')}}},
              open(snapshot, 'w'))
$2
PY
}

probe_case "stale snapshot: one probe refreshes it, rewritten as nogg-probe at mode 0600" '
stale(1200)
r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=which)
assert r["status"] == "known" and [w["used_percent"] for w in r["windows"]] == [37, 21], r
assert calls == {"run": 1, "open": 1}, calls
row = json.load(open(snapshot))
assert row["source"] == "nogg-probe" and row["provider"] == "zai" and row["schema_version"] == 1, row
assert stat.S_IMODE(os.stat(snapshot).st_mode) == 0o600
assert SENTINEL not in open(snapshot).read()
# the refreshed snapshot is fresh: the next read probes nothing
r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=which)
assert calls == {"run": 1, "open": 1} and r["status"] == "known"
'

probe_case "missing snapshot is probed; a malformed one too" '
if os.path.exists(snapshot): os.unlink(snapshot)
assert u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=which)["status"] == "known"
open(snapshot, "w").write("{")
assert u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=which)["status"] == "known"
assert calls == {"run": 2, "open": 2}, calls
'

probe_case "no key: both windows unknown with the hint and no request is made" '
stale(1200)
r = u.pi_usage("zai/glm-5", now=NOW, run=run_nokey, opener=opener_ok, which=which)
assert r["status"] == "unknown" and calls == {"run": 1, "open": 0}, (r, calls)
for w in r["windows"]:
    assert w["reason"] == "no Z.ai API key configured in Pi", w
    assert w["hint"] == "configure the ZAI Coding Plan key in Pi (/login)", w
    assert w["used_percent"] is None
assert r["model_group"] == "zai-coding-plan"
'

probe_case "pi not installed: unknown with the install hint, stale data is not reused" '
stale(1200)
r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=lambda name: None)
assert all(w["reason"] == "pi not installed" and w["hint"] == "install pi" and w["status"] == "unknown" for w in r["windows"]), r
'

probe_case "probe disabled: no pi command or request, stale observation with the run-nogg-usage hint" '
os.environ["PI_NOGG_USAGE_PROBE"] = "0"
stale(1200)
r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=which)
assert calls == {"run": 0, "open": 0}, calls
assert all(w["reason"] == "stale observation" and w["hint"] == "run nogg usage --agent pi" for w in r["windows"]), r
os.environ["PI_NOGG_USAGE_PROBE"] = "1"
r = u.pi_usage("zai/glm-5", now=NOW, source=snapshot, run=run_ok, opener=opener_ok, which=which)
assert calls == {"run": 0, "open": 0} and r["status"] == "unknown", "an explicit source is read without probing"
'

probe_case "reset elapsed and an omitted window stay unknown per window" '
stale(60)
row = json.load(open(snapshot))
row["windows"]["short"]["resets_at"] = (NOW - dt.timedelta(minutes=1)).isoformat().replace("+00:00", "Z")
row["windows"]["weekly"] = {"used_percent": 3, "resets_at": (NOW - dt.timedelta(minutes=5)).isoformat().replace("+00:00", "Z")}
json.dump(row, open(snapshot, "w"))
r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=which)
assert [w["reason"] for w in r["windows"]] == ["reset elapsed; fresh observation required"] * 2, r
assert r["status"] == "unknown" and all(w["used_percent"] is None for w in r["windows"])
del row["windows"]["weekly"]
row["windows"]["short"]["resets_at"] = (NOW + dt.timedelta(minutes=1)).isoformat().replace("+00:00", "Z")
json.dump(row, open(snapshot, "w"))
r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener_ok, which=which)
assert [w["status"] for w in r["windows"]] == ["known", "unknown"] and r["windows"][1]["reason"] == "missing or malformed window", r
assert calls == {"run": 0, "open": 0}
'

probe_case "rejected key and network failure: the key reaches no reason, report, snapshot or error" '
for opener, reason in ((opener_401, "Z.ai rejected the key (HTTP 401)"), (opener_fail, "quota probe failed (network)")):
    stale(1200)
    before = open(snapshot).read()
    r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=opener, which=which)
    assert all(w["reason"] == reason for w in r["windows"]), r
    assert SENTINEL not in json.dumps(r) and open(snapshot).read() == before
'

probe_case "unsupported response is unknown, never zero" '
stale(1200)
class Bad(R):
    def read(self, n=-1):
        if self.sent: return b""
        self.sent = True
        return b"{\"code\": 200, \"data\": {\"limits\": []}}"
r = u.pi_usage("zai/glm-5", now=NOW, run=run_ok, opener=lambda q, timeout=None: Bad(), which=which)
assert all(w["reason"] == "unsupported quota response" and w["used_percent"] is None for w in r["windows"]), r
'

probe_case "observe(probe=False) is cache-only: only launch admission probes" '
stale(1200)
r = u.observe("pi", u.gate_config(None), now=NOW, model="zai/glm-5", probe=False)
assert r["status"] == "unknown" and all(w["reason"] == "stale observation" for w in r["windows"]), r
assert calls == {"run": 0, "open": 0}, calls
'

probe_case "missing Z.ai module degrades to unknown usage" '
import shutil, tempfile
d = tempfile.mkdtemp(); shutil.copy(os.path.join(sys.argv[1], "nogg_usage.py"), d)
sys.path.insert(0, d)
import importlib.util
spec = importlib.util.spec_from_file_location("lone_usage", os.path.join(d, "nogg_usage.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = m.observe("pi", m.gate_config(None), model="zai/glm-5")
assert r["status"] == "unknown" and "run Nogging update" in r["windows"][0]["reason"], r
'

# --- doctor note: cache only, never a probe -----------------------------------
: >"$PI_STUB_LOG"
rm -f "$snapshot"
doctor_note() {
  PI_NOGG_USAGE_PROBE=1 python3 - "$repo_root/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import nogg_usage as u
print('\n'.join(n for n in u.quota_freshness_notes(None) if '(pi)' in n))
PY
}
note=$(doctor_note)
case "$note" in *"run nogg usage --agent pi"*) ok "doctor note (no snapshot) names run nogg usage --agent pi" ;; *) echo "$note" >"$out"; bad "doctor missing note" ;; esac
write_snapshot 1200 5 5; note=$(doctor_note)
case "$note" in *"stale"*"run nogg usage --agent pi"*) ok "doctor note (stale) names run nogg usage --agent pi" ;; *) echo "$note" >"$out"; bad "doctor stale note" ;; esac
write_snapshot 60 5 5; note=$(doctor_note)
case "$note" in *"fresh"*) ok "doctor note (fresh)" ;; *) echo "$note" >"$out"; bad "doctor fresh note" ;; esac
[[ ! -s "$PI_STUB_LOG" ]] && ok "doctor never ran pi" || bad "doctor probed"
mkdir -p "$work/nopi"; ln -s "$(command -v python3)" "$work/nopi/python3"
note=$(PATH="$work/nopi" python3 - "$repo_root/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import nogg_usage as u
print('\n'.join(n for n in u.quota_freshness_notes(None) if '(pi)' in n))
PY
)
[[ -z "$note" ]] && ok "doctor is silent about Pi when pi is not on PATH" || { echo "$note" >"$out"; bad "doctor note without pi"; }

# --- CLI hints ----------------------------------------------------------------
rm -f "$snapshot"; : >"$PI_STUB_LOG"
PI_NOGG_USAGE_PROBE=0 "$nogg" usage --agent pi --model zai/glm-5 >"$out"
grep -qF "unknown (missing usage source) — run nogg usage --agent pi" "$out" && [[ ! -s "$PI_STUB_LOG" ]] \
  && ok "nogg usage with the probe disabled shows the run hint and runs no pi" || bad "disabled hint"
PI_NOGG_USAGE_PROBE=1 PI_STUB_EXIT=1 "$nogg" usage --agent pi --model zai/glm-5 >"$out"
grep -qF "unknown (no Z.ai API key configured in Pi) — configure the ZAI Coding Plan key in Pi (/login)" "$out" \
  && grep -qF "fits: unknown" "$out" && ok "nogg usage shows the key hint; the gate decision is unchanged" || bad "key hint"
[[ "$(wc -l <"$PI_STUB_LOG")" -eq 1 ]] && grep -qxF "auth print-api-key --provider zai" "$PI_STUB_LOG" \
  && ok "one pi auth print-api-key --provider zai call, key never on a command line" || bad "pi invocation"
PI_NOGG_USAGE_PROBE=1 PATH="$work/nopi:$(dirname "$(command -v python3)")" "$nogg" usage --agent pi --model zai/glm-5 >"$out" 2>&1 || true
grep -qF "install pi" "$out" && ok "nogg usage names install pi when pi is missing" || bad "install hint"

# --- launches ------------------------------------------------------------------
n=0
new_root() {
  n=$((n + 1)); root="$work/r$n"
  mkdir -p "$root/.nogging/state" "$root/scripts/hooks" "$root/openspec" "$root/.pi/extensions"
  cp "$repo_root/scripts/session-launch" "$repo_root/scripts/session-log-writer" "$repo_root/scripts/openspec-sandbox" \
     "$repo_root/scripts/nogg" "$repo_root/scripts/nogg_usage.py" "$repo_root/scripts/nogg_usage_zai.py" "$root/scripts/"
  cp -r "$repo_root/scripts/lib" "$root/scripts/lib"
  cp "$repo_root/.pi/extensions/nogging-guard.ts" "$root/.pi/extensions/"
  git init -q "$root"
  cp -r "$repo_root/.nogging/launch-profiles" "$repo_root/.nogging/launch-prompts" "$root/.nogging/"
  cp "$repo_root/templates/model-selection.json" "$root/.nogging/model-selection.json"
  copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
  python3 - "$root/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.pop("session_launch_profile", None); cfg.pop("session_launch_prompt", None); cfg.pop("usage_gate", None)
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
PY
  export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/t$n"; mkdir -p "$TMUX_STUB_DIR"
}
rc=0
run_launch() {
  rc=0
  "$nogg" session launch --role lead --bead SPEC-pxg --cwd "$root" --agent pi --full-access "$@" >"$out" 2>&1 || rc=$?
}
no_side_effects() {
  [[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null || true)" ]] \
    && ! grep -qF "new-session" "$TMUX_STUB_DIR/calls.log" 2>/dev/null \
    && ok "$1: no session record and no tmux session" || bad "$1: side effects left behind"
}

new_root; write_snapshot 120 10 99 2 48
run_launch --model zai/glm-5
[[ $rc -eq 75 ]] && grep -qF "weekly 99% used" "$out" && grep -qF "retry after" "$out" \
  && ok "Pi weekly over the cap: launch denied naming the weekly reset, exit 75" || bad "weekly denial (rc=$rc)"
no_side_effects "weekly denial"

new_root; write_snapshot 120 10 20
run_launch --model zai/glm-5
[[ $rc -eq 0 ]] && ! grep -q "usage is unknown" "$out" && ok "Pi launch within the cap is admitted without a warning" || bad "admitted launch (rc=$rc)"

new_root; rm -f "$snapshot"
PI_NOGG_USAGE_PROBE=0 run_launch --model zai/glm-5
[[ $rc -eq 0 ]] && grep -qF "WARN: pi usage is unknown (short: missing usage source — run nogg usage --agent pi" "$out" \
  && ok "unknown-admitted launch warning carries the hint, the launch proceeds" || bad "launch warning (rc=$rc)"

new_root; rm -f "$snapshot"
PI_STUB_EXIT=1 PI_NOGG_USAGE_PROBE=1 run_launch --model zai/glm-5
[[ $rc -eq 0 ]] && grep -qF "configure the ZAI Coding Plan key in Pi (/login)" "$out" \
  && ok "launch warning names the key hint" || bad "key hint on launch (rc=$rc)"

new_root; rm -f "$snapshot"
PI_NOGG_USAGE_PROBE=1 run_launch --model anthropic/claude-sonnet-4-6
[[ $rc -eq 0 ]] && grep -qF "no usage source for Pi provider anthropic" "$out" \
  && ok "Pi launch on another provider is unknown and admitted under warn" || bad "other provider launch (rc=$rc)"

# A sentinel key with a probe that fails (an unreachable proxy stands in for the network)
# must appear in no output, snapshot, record or log.
new_root; rm -f "$snapshot"
PI_STUB_KEY="$SENTINEL" PI_NOGG_USAGE_PROBE=1 https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 run_launch --model zai/glm-5
[[ $rc -eq 0 ]] && grep -qE "quota probe failed \((network|timeout)\)" "$out" \
  && ok "failed probe: unknown usage with a fixed reason" || bad "failed probe (rc=$rc)"
if grep -rqF -- "$SENTINEL" "$out" "$root" "$XDG_CACHE_HOME" "$TMUX_STUB_DIR" "$PI_STUB_LOG" 2>/dev/null; then
  bad "sentinel key leaked"
else
  ok "sentinel key appears in no output, record, snapshot, tmux call or log"
fi
[[ ! -e "$snapshot" ]] && ok "failed probe wrote no snapshot" || bad "snapshot written on failure"

exit $fail
