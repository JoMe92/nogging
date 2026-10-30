"""Agent routing file: schema_version 1 loader and validator.

Pure module, shipped beside scripts/nogg and loaded like session_backend.
It owns the `.nogging/agent-routing.json` schema (change
configurable-agent-routing, design Decisions 2-3 and 8): parsing that refuses
duplicate JSON keys, structural validation whose every error names the file,
the JSON path and the rule, and `agy` -> `antigravity` normalization.

The module deliberately imports nothing from scripts/nogg. The host injects
its own model-name validator and effort tables (`validate_model`,
`efforts_by_agent`, `tiers`), so this file stays testable without the CLI and
the CLI keeps one authority for those vocabularies. Missing file means no
routing; nothing here ever writes the file.
"""
from __future__ import annotations

import json
from pathlib import Path

DEFAULT_ROUTING_PATH = ".nogging/agent-routing.json"
SCHEMA_VERSION = 1
ROLES = ("lead", "specialist", "planning")
AGENTS = ("claude", "codex", "pi", "antigravity")
BACKENDS = ("tmux", "herdr")
ON_UNKNOWN = ("warn", "deny")
MAX_NOTE = 200
ENTRY_KEYS = ("agent", "backend", "tiers", "models", "allow", "on_unknown", "note")
ALLOW_KEYS = ("model", "efforts", "note")
SELECTION_KEYS = ("model", "effort")


def normalize_agent(agent):
    """`agy` is an alias for `antigravity`, as in the model-selection table."""
    return "antigravity" if agent == "agy" else agent


def _is_one_line_text(value):
    return (isinstance(value, str) and bool(value.strip())
            and "\n" not in value and len(value) <= MAX_NOTE)


class _RawPairs(dict):
    """Dict keeping its source pairs, so duplicate keys stay reportable.

    json.loads collapses duplicate keys silently; object_pairs_hook hands us
    the raw pairs instead, and a later walk turns every duplicate into a
    validation error naming its JSON path (design Decision 3).
    """
    pairs = ()


def _pairs(pairs):
    node = _RawPairs(pairs)
    node.pairs = pairs  # instance attribute; the class default stays empty
    return node


def _collect_pairs(value):
    """Recursively turn every mapping into a dict, collecting errors.

    Returns `(data, errors)`; `data` shares leaves with the parsed tree.
    """
    errors = []
    def walk(node, path):
        where = "".join(path)
        if isinstance(node, _RawPairs):
            seen = set()
            for key, _ in node.pairs:
                if key in seen:
                    errors.append(f"{where}{key}: duplicate JSON key "
                                  "(rule: every key must appear at most once)")
                seen.add(key)
            out = {}
            for key, item in node.pairs:
                out[key] = walk(item, path + [key, "."])
            return out
        if isinstance(node, list):
            base = where[:-1] if where.endswith(".") else where
            return [walk(item, [f"{base}[{i}]."]) for i, item in enumerate(node)]
        return node
    return walk(value, []), errors


def _parse(text, origin):
    """Parse routing JSON; returns `(data or None, errors)`."""
    try:
        parsed = json.loads(text, object_pairs_hook=_pairs)
    except ValueError as exc:
        return None, [f"{origin}: not valid JSON ({exc}) "
                      "(rule: the routing file must be one JSON object)"]
    data, errors = _collect_pairs(parsed)
    return data, errors


def _keys(obj, where, errors, required, optional=()):
    """Check object shape and unknown keys; returns False when unusable."""
    if not isinstance(obj, dict):
        errors.append(f"{where}: must be an object (rule: expected a JSON object)")
        return False
    for key in sorted(set(obj) - set(required) - set(optional)):
        errors.append(f"{where}: unknown key {key!r} (rule: allowed keys are "
                      f"{', '.join(required + optional)})")
    for key in required:
        if key not in obj:
            errors.append(f"{where}: missing key {key!r} (rule: {key!r} is required)")
    return True


def routing_errors(data, *, validate_model, efforts_by_agent, tiers):
    """Every reason `data` is not a valid routing document, each naming the
    JSON path and the rule. An empty list means the document is valid.

    `validate_model(value, origin)` raises RuntimeError naming `origin` for an
    unacceptable model name; `efforts_by_agent` maps agent -> allowed efforts;
    `tiers` is the ordered tier vocabulary. All are injected by the host.
    """
    errors = []
    if not _keys(data, "", errors, ("schema_version", "roles")):
        return errors
    if type(data["schema_version"]) is not int or data["schema_version"] != SCHEMA_VERSION:
        errors.append(f"schema_version: unsupported value {data['schema_version']!r}; "
                      f"expected {SCHEMA_VERSION} (rule: schema_version must be "
                      f"{SCHEMA_VERSION})")
    roles = data.get("roles")
    if not isinstance(roles, dict):
        errors.append("roles: must be an object (rule: roles maps role -> entry list)")
        return errors
    for role in sorted(roles):
        where = f"roles.{role}"
        if role == "orchestrator":
            errors.append(f"{where}: the orchestrator role is not routable "
                          "(rule: roles are lead, specialist and planning; the "
                          "orchestrator is driven by its own commands)")
            continue
        if role not in ROLES:
            errors.append(f"{where}: unknown role {role!r} "
                          f"(rule: roles are {', '.join(ROLES)})")
            continue
        entries = roles[role]
        if not isinstance(entries, list) or not entries:
            errors.append(f"{where}: must be a non-empty list of entries "
                          "(rule: an empty list is refused; remove the role key "
                          "instead)")
            continue
        seen_pairs = set()
        for index, entry in enumerate(entries):
            entry_where = f"{where}[{index}]"
            if not _keys(entry, entry_where, errors, ("agent",), ENTRY_KEYS[1:]):
                continue
            agent = entry.get("agent")
            if not isinstance(agent, str) or normalize_agent(agent) not in AGENTS:
                errors.append(f"{entry_where}.agent: unknown agent {agent!r} "
                              f"(rule: agent is one of {', '.join(AGENTS)}; "
                              "'agy' is accepted as an alias)")
                continue
            agent = normalize_agent(agent)
            backend = entry.get("backend")
            if backend is not None and backend not in BACKENDS:
                errors.append(f"{entry_where}.backend: unknown backend {backend!r} "
                              f"(rule: backend is one of {', '.join(BACKENDS)})")
            entry_tiers = entry.get("tiers")
            if entry_tiers is not None:
                if (not isinstance(entry_tiers, list) or not entry_tiers
                        or any(t not in tiers for t in entry_tiers)):
                    errors.append(f"{entry_where}.tiers: must be a non-empty subset of "
                                  f"{', '.join(tiers)} (rule: tiers narrows the entry's "
                                  "eligible tiers)")
            on_unknown = entry.get("on_unknown")
            if on_unknown is not None and on_unknown not in ON_UNKNOWN:
                errors.append(f"{entry_where}.on_unknown: unknown value {on_unknown!r} "
                              f"(rule: on_unknown is one of {', '.join(ON_UNKNOWN)})")
            note = entry.get("note")
            if note is not None and not _is_one_line_text(note):
                errors.append(f"{entry_where}.note: must be a one-line note of at most "
                              f"{MAX_NOTE} characters (rule: note is free text on one line)")
            allow_models = {}
            allow = entry.get("allow")
            if allow is not None:
                if not isinstance(allow, list) or not allow:
                    errors.append(f"{entry_where}.allow: must be a non-empty list "
                                  "(rule: allow lists acceptable model/effort pairs)")
                else:
                    for a_index, record in enumerate(allow):
                        a_where = f"{entry_where}.allow[{a_index}]"
                        if not _keys(record, a_where, errors, ("model",), ALLOW_KEYS[1:]):
                            continue
                        model = record.get("model")
                        origin = f"{a_where}.model"
                        try:
                            validate_model(model, origin)
                        except RuntimeError as exc:
                            errors.append(str(exc))
                            continue
                        efforts = record.get("efforts")
                        if efforts is not None:
                            if agent not in efforts_by_agent:
                                errors.append(f"{a_where}.efforts: not allowed for {agent} "
                                              "(rule: efforts is allowed only for claude "
                                              "and codex)")
                            elif (not isinstance(efforts, list) or not efforts
                                  or any(e not in efforts_by_agent[agent] for e in efforts)):
                                errors.append(f"{a_where}.efforts: must be a non-empty "
                                              f"subset of {', '.join(efforts_by_agent[agent])} "
                                              f"(rule: efforts values for {agent})")
                        allow_note = record.get("note")
                        if allow_note is not None and not _is_one_line_text(allow_note):
                            errors.append(f"{a_where}.note: must be a one-line note of at "
                                          f"most {MAX_NOTE} characters (rule: note is free "
                                          "text on one line)")
                        allow_models.setdefault(model, record)
            models = entry.get("models")
            if models is not None:
                if not isinstance(models, dict) or not models:
                    errors.append(f"{entry_where}.models: must be a non-empty object keyed "
                                  "by tier (rule: models maps tier -> {model, effort})")
                else:
                    for tier in sorted(models):
                        s_where = f"{entry_where}.models.{tier}"
                        selection = models[tier]
                        if tier not in tiers:
                            errors.append(f"{s_where}: unknown tier {tier!r} "
                                          f"(rule: models keys are {', '.join(tiers)})")
                        if (entry_tiers is not None and isinstance(entry_tiers, list)
                                and tier not in entry_tiers):
                            errors.append(f"{s_where}: tier {tier!r} is outside the entry's "
                                          f"tiers ({', '.join(entry_tiers)}) (rule: a models "
                                          "selection must be for an eligible tier)")
                        if not _keys(selection, s_where, errors, (), SELECTION_KEYS) \
                                or not isinstance(selection, dict):
                            continue
                        if not {"model", "effort"} & set(selection):
                            errors.append(f"{s_where}: must set at least one of model or "
                                          "effort (rule: an empty selection is refused)")
                        s_model = selection.get("model")
                        if s_model is not None:
                            origin = f"{s_where}.model"
                            try:
                                validate_model(s_model, origin)
                            except RuntimeError as exc:
                                errors.append(str(exc))
                        s_effort = selection.get("effort")
                        if s_effort is not None:
                            if agent not in efforts_by_agent:
                                errors.append(f"{s_where}.effort: not allowed for {agent} "
                                              "(rule: effort is allowed only for claude "
                                              "and codex)")
                            elif s_effort not in efforts_by_agent[agent]:
                                errors.append(f"{s_where}.effort: {s_effort!r} is not one of "
                                              f"{', '.join(efforts_by_agent[agent])} "
                                              f"(rule: effort values for {agent})")
                        # A models selection must satisfy the entry's own allow list.
                        if allow_models and s_model is not None:
                            record = allow_models.get(s_model)
                            if record is None:
                                errors.append(f"{s_where}.model: {s_model!r} is outside the "
                                              "entry's allow list (rule: every models "
                                              "selection must satisfy the entry's own allow)")
                            else:
                                allowed = record.get("efforts")
                                if s_effort is not None and allowed is not None \
                                        and s_effort not in allowed:
                                    errors.append(f"{s_where}.effort: {s_effort!r} is not in "
                                                  f"the allow list's efforts for {s_model!r} "
                                                  "(rule: every models selection must satisfy "
                                                  "the entry's own allow)")
            pair = (agent, backend)
            if pair in seen_pairs and backend is not None:
                errors.append(f"{entry_where}: duplicate entry for agent {agent!r} on "
                              f"backend {backend!r} (rule: two entries of one role must "
                              "not share agent and written backend)")
            seen_pairs.add(pair)
    return errors


def load_routing(path, *, main_checkout, validate_model, efforts_by_agent, tiers):
    """Read and validate the routing file at `path`.

    Returns `(routing, errors)`: `routing` maps role -> list of entries with
    `agy` normalized to `antigravity`, and is `{}` when the file is absent or
    carries no roles; `errors` is empty exactly when the file is absent or
    valid. A missing file means no routing and is not an error. Relative
    `agent_routing_file` keys resolve against `main_checkout`, so every linked
    worktree reads the same file.
    """
    path = Path(path)
    if not path.is_absolute():
        path = (Path(main_checkout) / path).resolve()
    origin = str(path)
    try:
        text = path.read_text()
    except FileNotFoundError:
        return {}, []
    except OSError as exc:
        return None, [f"{origin}: cannot be read ({exc}) "
                      "(rule: the routing file must be readable)"]
    data, errors = _parse(text, origin)
    if data is None:
        return None, errors
    # Every error names the file, the JSON path and the rule.
    errors = errors + [f"{origin}: {e}" for e in
                       routing_errors(data, validate_model=validate_model,
                                      efforts_by_agent=efforts_by_agent, tiers=tiers)]
    if errors:
        return None, errors
    return {role: [dict(entry, agent=normalize_agent(entry["agent"]))
                   for entry in data["roles"][role]]
            for role in data.get("roles", {})}, []
