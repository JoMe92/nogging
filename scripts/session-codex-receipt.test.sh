#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$root/scripts/lib/session_codex_delivery_test.py"

scratch="$(mktemp -d)"
git -C "$scratch" init -q
trap 'rm -rf "$scratch"' EXIT
(cd "$scratch" && node "$root/bin/cli.js" init --no-beads --no-hooks --no-systemd >/dev/null)
test -f "$scratch/scripts/lib/session_codex_delivery.py"
(cd "$scratch" && node "$root/bin/cli.js" update --no-beads --no-hooks --no-systemd >/dev/null)
test -f "$scratch/scripts/lib/session_codex_delivery.py"
printf 'session Codex receipt reader install/update: ok\n'
