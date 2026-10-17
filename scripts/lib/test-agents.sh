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
