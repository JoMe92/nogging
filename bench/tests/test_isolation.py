"""The benchmark stays outside Nogging, and Nogging's published package stays free of it."""

from __future__ import annotations

import json
import pkgutil
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import BENCH

import nogg_bench

REPO_ROOT = BENCH.parent
MODULES = sorted(m.name for m in pkgutil.walk_packages(nogg_bench.__path__, "nogg_bench."))

CLEAN_IMPORT = """
import importlib, sys
module = sys.argv[1]
importlib.import_module(module)
bad = [p for p in sys.path if p.rstrip('/').endswith(('/scripts', '/scripts/lib'))]
assert not bad, bad
loaded = sorted(
    name for name, mod in sys.modules.items()
    if getattr(mod, '__file__', None) and '/scripts/' in mod.__file__ and 'site-packages' not in mod.__file__
)
assert not loaded, loaded
"""


@pytest.mark.parametrize("module", ["nogg_bench", *MODULES])
def test_the_package_imports_nothing_from_nogging(module):
    # -I: no PYTHONPATH, no user site, no working directory on sys.path; the
    # process starts without Nogging's scripts/ or scripts/lib/.
    done = subprocess.run(
        [sys.executable, "-I", "-c", CLEAN_IMPORT, module], capture_output=True, text=True, cwd=BENCH
    )
    assert done.returncode == 0, done.stderr


def test_the_published_package_does_not_contain_the_benchmark():
    # npm ships with the CI runners and the delivery host; a missing npm fails loudly.
    assert shutil.which("npm"), "npm is required to list the published package"
    assert (REPO_ROOT / "package.json").is_file(), "the repository root has no package.json"
    done = subprocess.run(
        ["npm", "pack", "--dry-run", "--json", "--ignore-scripts"],
        cwd=REPO_ROOT, capture_output=True, text=True, timeout=120,
    )
    assert done.returncode == 0, done.stderr
    packed = json.loads(done.stdout)[0]["files"]
    paths = [f["path"] for f in packed]
    assert paths, "npm pack listed no files"
    assert [p for p in paths if p == "bench" or p.startswith("bench/")] == []
