#!/usr/bin/env bash
# Shared session-name contract for generated names and both backend boundaries.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$here" <<'PY'
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

here = Path(sys.argv[1])
sys.path[:0] = [str(here / "lib"), str(here)]
from session_backend import BackendError
from session_backend_tmux import TmuxBackend
from session_backend_herdr import HerdrBackend

from session_backend import safe_session_name
assert safe_session_name("SF-Lead-Supply.Doc:V0zu.1-ABC") == "sf-lead-supply_doc_v0zu_1-abc"

calls = []
def run(*args, **kwargs):
    calls.append((args, kwargs))
    return subprocess.CompletedProcess(args, 0, "", "")

tmux = TmuxBackend({}, run)
for operation in (lambda: tmux.prepare("unsafe.name", "/tmp"),
                  lambda: tmux.start("unsafe:name", "/tmp", {}, ["true"], None)):
    try:
        operation()
    except BackendError:
        pass
    else:
        raise AssertionError("tmux accepted a name that requires rewriting")
assert not calls, "tmux performed a side effect before rejecting an unsafe name"

herdr = HerdrBackend({"session_repository_root": "/tmp"}, run)
with patch.object(herdr, "_ensure_server", side_effect=lambda: calls.append("server")):
    for operation in (lambda: herdr.prepare("unsafe.name", "/tmp"),
                      lambda: herdr.start("unsafe:name", "/tmp", {}, ["true"], None)):
        try:
            operation()
        except BackendError:
            pass
        else:
            raise AssertionError("herdr accepted a name that requires rewriting")
assert not calls, "herdr performed a side effect before rejecting an unsafe name"

import nogg
with patch.object(nogg, "session_name_in_use", return_value=False):
    generated = nogg.gen_session_name("lead", "supply-doc-v0zu.1")
assert generated.startswith("sf-lead-supply-doc-v0zu_1-")
assert "." not in generated and ":" not in generated
assert nogg.orchestrator_session_name() == safe_session_name(nogg.orchestrator_session_name())
print("ok - shared safe session names, generation, and backend preflight")
PY
