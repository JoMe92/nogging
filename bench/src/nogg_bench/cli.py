"""The ``nogg-bench`` command line.

``validate`` lives here. The other subcommands are written by later tasks, each
in its own module, so parallel branches do not edit the same file. A module
registers itself by defining ``add_parser(subparsers)``, which must set
``parser.set_defaults(handler=<callable taking the argparse Namespace and
returning an exit code>)``. Until a module exists its subcommand answers that it
is not available yet.
"""

from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path
from typing import Callable, Sequence

from nogg_bench import __version__
from nogg_bench.validate import find_bench_dir, validate

# subcommand -> module that defines add_parser(subparsers)
PLANNED_COMMANDS = {
    "run": "nogg_bench.run",  # BEN-002
    "review-pack": "nogg_bench.review_pack",  # BEN-004
    "report": "nogg_bench.report",  # BEN-005
}


def _validate_command(args: argparse.Namespace) -> int:
    bench = Path(args.bench_dir).resolve() if args.bench_dir else find_bench_dir()
    problems = validate([Path(p) for p in args.paths], bench)
    for problem in problems:
        print(problem)
    if problems:
        print(f"validate: {len(problems)} problem(s)", file=sys.stderr)
        return 1
    return 0


def _not_available(name: str) -> Callable[[argparse.Namespace], int]:
    def handler(_args: argparse.Namespace) -> int:
        print(f"nogg-bench {name}: not available in this build yet", file=sys.stderr)
        return 2

    return handler


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="nogg-bench", description="Impact benchmark for Nogging.")
    parser.add_argument("--version", action="version", version=f"nogg-bench {__version__}")
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    sub.required = True

    val = sub.add_parser(
        "validate",
        help="check tasks, arms, result lines, review records and the thresholds block",
        description="Validate benchmark records by their location. With no path, check all of bench/.",
    )
    val.add_argument("paths", nargs="*", help="files or directories to check (default: all of bench/)")
    val.add_argument("--bench-dir", help="the bench directory (default: found from the working directory)")
    val.set_defaults(handler=_validate_command)

    for name, module in PLANNED_COMMANDS.items():
        try:
            mod = importlib.import_module(module)
        except ModuleNotFoundError as exc:
            if exc.name != module:
                raise  # the module exists but one of its imports is missing
            stub = sub.add_parser(name, help="(not available in this build yet)")
            stub.set_defaults(handler=_not_available(name))
        else:
            mod.add_parser(sub)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.handler(args))
