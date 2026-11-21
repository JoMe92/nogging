"""The ceremony switch and the triage rules (change adaptive-ceremony).

Pure: the configuration and every fact are passed in; nothing here reads a
file, the network, the clock or a model, so the same input always gives the
same output. `scripts/nogg` holds the one accessor that hands the parsed
`.nogging/config.json` to `parse()`; every other caller asks that accessor.

    { "ceremony": { "mode": "always-full",
                    "fast_lane": { "max_files": 2, "max_lines": 200 },
                    "lite": { "min_score": 6 } } }
"""
import re

MODES = ("always-full", "adaptive", "always-fast")
DEFAULT_MODE = "always-full"
# Flat, dotted keys: the same names the WARN lines and `nogg ceremony` print.
DEFAULTS = {"mode": DEFAULT_MODE, "fast_lane.max_files": 2,
            "fast_lane.max_lines": 200, "lite.min_score": 6}
_GROUPS = {"fast_lane": ("max_files", "max_lines"), "lite": ("min_score",)}
_WHERE = "in .nogging/config.json"

FULL, LITE, FAST = "full", "lite", "fast"
KINDS = ("bug", "refactor", "test", "config", "feature", "pipeline")
FULL_KINDS = ("feature", "pipeline")
FAST_KINDS = ("bug", "refactor", "test", "config")
FAST_MAX_FILES = 2
# A description holding one of these (whole word, any case, plural allowed)
# takes the full spec whatever the stated facts say.
TRIGGER_WORDS = ("security", "credential", "token", "permission", "authentication",
                 "migration", "schema", "public API", "pipeline", "new command")
_TRIGGER_RES = tuple(
    (word, re.compile(r"\b" + r"\s+".join(map(re.escape, word.split())) + r"s?\b", re.I))
    for word in TRIGGER_WORDS)


def parse(cfg):
    """Return (settings, configured keys, problems) for the `ceremony` block.

    `settings` always holds every key of DEFAULTS; an unknown mode or a
    non-positive limit keeps its default and adds one problem naming the key.
    """
    settings, configured, problems = dict(DEFAULTS), set(), []
    raw = cfg.get("ceremony", {}) if isinstance(cfg, dict) else {}
    if not isinstance(raw, dict):
        return settings, configured, [f"ceremony {_WHERE} must be an object; using the defaults"]
    for key, value in raw.items():
        if key == "mode":
            if isinstance(value, str) and value in MODES:
                settings["mode"] = value
                configured.add("mode")
            else:
                problems.append(f"ceremony.mode {_WHERE} must be one of {', '.join(MODES)}; "
                                f"using the default {DEFAULT_MODE}")
        elif key in _GROUPS:
            if not isinstance(value, dict):
                problems.append(f"ceremony.{key} {_WHERE} must be an object; using the defaults")
                continue
            for name, limit in value.items():
                dotted = f"{key}.{name}"
                if name not in _GROUPS[key]:
                    problems.append(f"ceremony.{dotted} {_WHERE} is not a known key; ignored")
                elif isinstance(limit, int) and not isinstance(limit, bool) and limit > 0:
                    settings[dotted] = limit
                    configured.add(dotted)
                else:
                    problems.append(f"ceremony.{dotted} {_WHERE} must be a positive integer; "
                                    f"using the default {DEFAULTS[dotted]}")
        else:
            problems.append(f"ceremony.{key} {_WHERE} is not a known key; ignored")
    return settings, configured, problems


def trigger_words(description):
    """The full-spec trigger words the description holds, in list order."""
    return [word for word, pattern in _TRIGGER_RES if pattern.search(description or "")]


def rules_lane(description, kind=None, files=None, public_interface=False,
               security=False, unclear=False):
    """Apply the four rules in order; return (lane, the reasons of the rule that decided)."""
    if kind is not None and kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}")
    if files is not None and (isinstance(files, bool) or not isinstance(files, int) or files < 1):
        raise ValueError("files must be a positive integer")
    reasons = []
    if kind in FULL_KINDS:
        reasons.append(f"kind is {kind}")
    if public_interface:
        reasons.append("a public interface is stated")
    if security:
        reasons.append("security is stated")
    if unclear:
        reasons.append("high ambiguity is stated")
    reasons.extend(f"the description holds the trigger word '{word}'"
                   for word in trigger_words(description))
    if reasons:
        return FULL, [f"rule 1 (full): {reason}" for reason in reasons]
    if files is not None and files > FAST_MAX_FILES:
        return LITE, [f"rule 2 (lite): {files} files, {FAST_MAX_FILES + 1} or more"]
    if kind in FAST_KINDS and files is not None:
        return FAST, [f"rule 3 (fast): kind is {kind}, {files} file{'s' if files > 1 else ''}"]
    missing = [text for text, absent in (("no kind stated", kind is None),
                                         ("no file estimate stated", files is None)) if absent]
    return LITE, [f"rule 4 (lite): {'; '.join(missing)}"]


def effective_lane(mode, lane):
    """Map the rules' lane through the mode: full by default, fast under always-fast."""
    if mode not in MODES:
        raise ValueError(f"mode must be one of {', '.join(MODES)}")
    return {"always-full": FULL, "always-fast": FAST}.get(mode, lane)


def triage(mode, description, **facts):
    """The triage result: mode, rules' lane, effective lane and every reason."""
    lane, reasons = rules_lane(description, **facts)
    return {"description": description, "mode": mode, "rules_lane": lane,
            "effective_lane": effective_lane(mode, lane), "reasons": reasons}


def triage_line(result):
    """The one line `nogg triage --bead <id>` appends to the Bead's note."""
    return (f"triage: {result['effective_lane']} (mode {result['mode']}; "
            f"rules: {result['rules_lane']}): {'; '.join(result['reasons'])}")
