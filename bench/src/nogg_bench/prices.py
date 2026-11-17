"""List prices for turning token counts into cost (design Decision 13).

``bench/prices.yaml`` maps a model ID to USD per million input, output,
cache-read and cache-write tokens, with the source URL and the date the price
was read. A model that is not listed has *unknown* cost: it is never priced at
zero.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Mapping

from nogg_bench.records import RecordError, load_yaml
from nogg_bench.schema import Problem

TOKEN_KINDS = ("input", "output", "cache_read", "cache_write")
_URL = re.compile(r"^https?://\S+$")


@dataclass(frozen=True)
class Price:
    input: float
    output: float
    cache_read: float
    cache_write: float
    source: str
    date: str


def check_prices(data: Any) -> list[Problem]:
    """Problems in a parsed ``prices.yaml``, with ``file`` left empty."""
    problems: list[Problem] = []

    def add(field: str, message: str) -> None:
        problems.append(Problem("", field, message))

    if not isinstance(data, dict):
        add("(file)", "must be a mapping")
        return problems
    for key in data:
        if key not in ("schema", "prices"):
            add(key, "unknown field")
    if data.get("schema") != 1:
        add("schema", "must be 1")
    prices = data.get("prices")
    if not isinstance(prices, dict) or not prices:
        add("prices", "must be a mapping from model ID to its prices")
        return problems
    for model, entry in prices.items():
        where = f"prices.{model}"
        if not isinstance(entry, dict):
            add(where, "must be a mapping")
            continue
        for key in entry:
            if key not in (*TOKEN_KINDS, "source", "date"):
                add(f"{where}.{key}", "unknown field")
        for kind in TOKEN_KINDS:
            value = entry.get(kind)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                add(f"{where}.{kind}", "is required and must be a number (USD per million tokens)")
            elif value < 0:
                add(f"{where}.{kind}", "must not be negative")
        source = entry.get("source")
        if not isinstance(source, str) or not _URL.match(source):
            add(f"{where}.source", "is required and must be an http(s) URL")
        when = entry.get("date")
        if not isinstance(when, date):
            add(f"{where}.date", "is required and must be a date (YYYY-MM-DD)")
    return problems


def load_prices(path: Path) -> dict[str, Price]:
    """Read and check ``prices.yaml``; raise :class:`RecordError` on a problem."""
    data = load_yaml(path)
    problems = check_prices(data)
    if problems:
        raise RecordError(problems[0].at(str(path)))
    return {
        model: Price(
            input=float(e["input"]),
            output=float(e["output"]),
            cache_read=float(e["cache_read"]),
            cache_write=float(e["cache_write"]),
            source=e["source"],
            date=e["date"].isoformat(),
        )
        for model, e in data["prices"].items()
    }


def run_cost(usage: Mapping[str, Mapping[str, int]], prices: Mapping[str, Price]) -> tuple[float | None, list[str]]:
    """Cost in USD of one run's per-model usage, and the models without a price.

    The cost is ``None`` (unknown) as soon as one model used has no price; a run
    with no usage at all costs 0.0 only because it used nothing.
    """
    missing = sorted(model for model in usage if model not in prices)
    if missing:
        return None, missing
    total = 0.0
    for model, counts in usage.items():
        price = prices[model]
        for kind in TOKEN_KINDS:
            total += counts.get(kind, 0) * getattr(price, kind) / 1_000_000
    return total, []
