#!/usr/bin/env bash
# Source-only helper: put inert agent executables (claude, codex, agy, pi) in a
# stub directory so `session launch` fixtures pass the agent-binary preflight
# without ever running a real agent. An existing stub of the same name is kept.
#
#   stub_agent_binaries <dir>

stub_agent_binaries() {
  local dir=$1 name
  mkdir -p "$dir"
  for name in claude codex agy pi; do
    [[ -e "$dir/$name" ]] && continue
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/$name"
    chmod +x "$dir/$name"
  done
}

# Append a shared stub directory to PATH so a fixture that never stubs the agent
# itself still passes the launch preflight on a host without the real binaries
# (GitHub runners). Appended, never prepended: a real or fixture-supplied agent
# earlier on PATH keeps winning. The directory is fixed per user and idempotent.
use_agent_stubs() {
  local dir="${TMPDIR:-/tmp}/nogg-agent-stubs-$(id -u)"
  stub_agent_binaries "$dir"
  case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$PATH:$dir" ;; esac
}
