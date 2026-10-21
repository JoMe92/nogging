#!/usr/bin/env bash
# Source-or-run test fixture helper.
#
# copy_host_config <src> <dest> [backend]
#   Copies a host .nogging/config.json into a scratch repository and pins its
#   session_backend to <backend> (default tmux), so a fixture never inherits the
#   host's backend choice. Every other key and value is kept; the destination
#   directory is created.
#
# Sourced:  source scripts/lib/test-fixture-config.sh; copy_host_config ...
# Executed: scripts/lib/test-fixture-config.sh <src> <dest> [backend]
#           (for Python heredoc fixtures, so there is one implementation).

copy_host_config() {
  [[ $# -ge 2 && $# -le 3 ]] || {
    echo "usage: copy_host_config <src> <dest> [backend]" >&2
    return 2
  }
  python3 - "$1" "$2" "${3:-tmux}" <<'PY'
import json, pathlib, sys

src, dest, backend = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
config = json.loads(pathlib.Path(src).read_text())
config["session_backend"] = backend
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(json.dumps(config, indent=2) + "\n")
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  copy_host_config "$@"
fi
