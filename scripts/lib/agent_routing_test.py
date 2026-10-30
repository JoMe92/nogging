"""Unit tests for the agent routing file loader and validator.

Covers every scenario of the agent-routing file and validation requirements
(change configurable-agent-routing): a valid file loads in order, a missing
file means no routing, and every malformed shape is refused naming the file,
the JSON path and the rule. Pure: model names and effort vocabularies are
injected, so no scripts/nogg import is needed.
"""
import unittest

from agent_routing import (AGENTS, DEFAULT_ROUTING_PATH, ROLES, SCHEMA_VERSION,
                           SKIP_REASONS, RoutingFatal, evaluate_route, load_routing,
                           normalize_agent, pin_entry, routing_errors)

EFFORTS = {"claude": ("low", "medium", "high"), "codex": ("none", "low", "medium", "high")}
TIERS = ("routine", "standard", "complex")


def validate_model(value, origin):
    if not isinstance(value, str) or not value or any(c.isspace() for c in value) \
            or value.startswith("-"):
        raise RuntimeError(f"{origin}: {value!r} is not a valid model name "
                           "(rule: model must be a non-empty name without whitespace)")


def errors_of(doc, **overrides):
    kwargs = dict(validate_model=validate_model, efforts_by_agent=EFFORTS, tiers=TIERS)
    kwargs.update(overrides)
    return routing_errors(doc, **kwargs)


def entry(agent="codex", **extra):
    return dict(agent=agent, **extra)


def valid_doc():
    return {"schema_version": SCHEMA_VERSION, "roles": {
        "lead": [entry("pi", backend="herdr"),
                 entry("codex", backend="herdr", on_unknown="deny",
                       models={"complex": {"model": "gpt-6-luna", "effort": "medium"}},
                       allow=[{"model": "gpt-6-luna"},
                              {"model": "gpt-6.1-sol", "efforts": ["low"],
                               "note": "extremely hard tasks only"}]),
                 entry("claude", backend="herdr")],
        "planning": [entry("claude")]}}


class ValidFileTests(unittest.TestCase):
    def test_valid_document_has_no_errors(self):
        self.assertEqual(errors_of(valid_doc()), [])

    def test_agy_is_normalized_on_load(self):
        doc = {"schema_version": 1, "roles": {"lead": [entry("agy")]}}
        self.assertEqual(normalize_agent("agy"), "antigravity")
        self.assertEqual(errors_of(doc), [])
        self.assertIn("antigravity", AGENTS)
        self.assertNotIn("agy", AGENTS)

    def test_specialist_role_is_allowed(self):
        doc = {"schema_version": 1, "roles": {"specialist": [entry("pi")]}}
        self.assertEqual(errors_of(doc), [])
        self.assertIn("specialist", ROLES)


class MissingAndShapeTests(unittest.TestCase):
    def test_missing_file_means_no_routing(self):
        routing, errs = load_routing("/nonexistent/agent-routing.json",
                                     main_checkout="/nonexistent",
                                     validate_model=validate_model,
                                     efforts_by_agent=EFFORTS, tiers=TIERS)
        self.assertEqual((routing, errs), ({}, []))

    def test_relative_path_resolves_against_main_checkout(self):
        import json, tempfile, os
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp, "main")
            (main / ".nogging").mkdir(parents=True)
            (main / ".nogging" / "agent-routing.json").write_text(json.dumps(valid_doc()))
            (Path(tmp) / "linked").mkdir()
            routing, errs = load_routing(".nogging/agent-routing.json",
                                         main_checkout=str(main),
                                         validate_model=validate_model,
                                         efforts_by_agent=EFFORTS, tiers=TIERS)
            self.assertEqual(errs, [])
            self.assertEqual(sorted(routing), ["lead", "planning"])
            self.assertEqual([e["agent"] for e in routing["lead"]],
                             ["pi", "codex", "claude"])

    def test_missing_roles_refused(self):
        errs = errors_of({"schema_version": 1})
        self.assertTrue(any("missing key 'roles'" in e for e in errs), "\n".join(errs))


class RefusalTests(unittest.TestCase):
    def error(self, doc, fragment):
        errs = errors_of(doc)
        self.assertTrue(any(fragment in e for e in errs),
                        f"no error mentions {fragment!r} in:\n  " + "\n  ".join(errs))
        return errs

    def test_every_error_names_the_file(self):
        errs = load_and_errors()
        self.assertTrue(errs and all(e.startswith(str(_LAST_PATH) + ": ") for e in errs),
                        "\n".join(errs))

    def test_orchestrator_role_refused(self):
        errs = self.error({"schema_version": 1,
                           "roles": {"orchestrator": [entry("claude")]}},
                          "roles.orchestrator")
        self.assertTrue(any("not routable" in e for e in errs))

    def test_unknown_role_refused(self):
        self.error({"schema_version": 1, "roles": {"leadz": [entry("claude")]}},
                   "unknown role 'leadz'")

    def test_empty_list_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": []}}, "non-empty list")

    def test_duplicate_agent_backend_pair_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("codex", backend="herdr"), entry("codex", backend="herdr")]}},
            "duplicate entry")

    def test_same_agent_different_backend_allowed(self):
        doc = {"schema_version": 1, "roles": {"lead": [
            entry("codex", backend="herdr"), entry("codex", backend="tmux")]}}
        self.assertEqual(errors_of(doc), [])

    def test_unknown_top_level_key_refused(self):
        self.error({"schema_version": 1, "roles": {}, "extra": 1}, "unknown key 'extra'")

    def test_unknown_entry_key_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [entry("claude", wat=1)]}},
                   "roles.lead[0]: unknown key 'wat'")

    def test_bad_schema_version_refused(self):
        self.error({"schema_version": 2, "roles": {"lead": [entry("claude")]}},
                   "schema_version")

    def test_unknown_backend_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("claude", backend="screen")]}}, "roles.lead[0].backend")

    def test_bad_tiers_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("claude", tiers=[])]}}, "roles.lead[0].tiers")
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("claude", tiers=["epic"])]}}, "roles.lead[0].tiers")

    def test_bad_on_unknown_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("claude", on_unknown="shrug")]}}, "roles.lead[0].on_unknown")

    def test_entry_note_too_long_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("claude", note="x" * 201)]}}, "roles.lead[0].note")
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("claude", note="two\nlines")]}}, "roles.lead[0].note")

    def test_pi_effort_refused(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("pi", models={"standard": {"model": "glm-5", "effort": "high"}})]}})
        self.assertTrue(any("effort is allowed only for claude and codex" in e
                            for e in errs), "\n".join(errs))

    def test_antigravity_effort_refused(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("agy", models={"standard": {"model": "gemini-3.8-flash-medium",
                                              "effort": "high"}})]}})
        self.assertTrue(any("effort is allowed only for claude and codex" in e
                            for e in errs), "\n".join(errs))

    def test_unknown_agent_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [entry("gptsh")]}},
                   "unknown agent")

    def test_bad_model_name_refused_naming_path(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("claude", models={"standard": {"model": "not a model"}})]}})
        self.assertTrue(any("roles.lead[0].models.standard.model" in e for e in errs),
                        "\n".join(errs))

    def test_unknown_effort_value_refused(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("codex", models={"standard": {"model": "gpt-6", "effort": "mega"}})]}})
        self.assertTrue(any("roles.lead[0].models.standard.effort" in e
                            and "none, low, medium, high" in e for e in errs),
                        "\n".join(errs))

    def test_empty_selection_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("codex", models={"standard": {}})]}}, "at least one of model or effort")

    def test_models_tier_outside_entry_tiers_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("codex", tiers=["complex"],
                  models={"standard": {"model": "gpt-6"}})]}},
            "outside the entry's tiers")

    def test_unknown_models_tier_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("codex", models={"epic": {"model": "gpt-6"}})]}}, "unknown tier 'epic'")

    def test_models_selection_must_satisfy_own_allow(self):
        doc = {"schema_version": 1, "roles": {"lead": [
            entry("codex", models={"complex": {"model": "gpt-7", "effort": "low"}},
                  allow=[{"model": "gpt-6-luna"}])]}}
        errs = errors_of(doc)
        self.assertTrue(any("outside the entry's allow list" in e for e in errs),
                        "\n".join(errs))

    def test_models_effort_outside_allow_efforts(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("codex", models={"complex": {"model": "gpt-6.1-sol", "effort": "high"}},
                  allow=[{"model": "gpt-6.1-sol", "efforts": ["low"]}])]}})
        self.assertTrue(any("allow list's efforts" in e for e in errs), "\n".join(errs))

    def test_empty_allow_refused(self):
        self.error({"schema_version": 1, "roles": {"lead": [
            entry("codex", allow=[])]}}, "non-empty list")

    def test_allow_efforts_only_for_claude_codex(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("pi", allow=[{"model": "glm-5", "efforts": ["low"]}])]}})
        self.assertTrue(any("allow[0].efforts" in e for e in errs), "\n".join(errs))

    def test_allow_efforts_must_be_known_values(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("claude", allow=[{"model": "claude-x", "efforts": ["low", "ultra"]}])]}})
        self.assertTrue(any("allow[0].efforts" in e and "low, medium, high" in e
                            for e in errs), "\n".join(errs))

    def test_allow_note_rules(self):
        errs = errors_of({"schema_version": 1, "roles": {"lead": [
            entry("codex", allow=[{"model": "gpt-6", "note": "y" * 201}])]}})
        self.assertTrue(any("allow[0].note" in e for e in errs), "\n".join(errs))


class DuplicateKeyTests(unittest.TestCase):
    def test_duplicate_json_key_is_refused_naming_path(self):
        import tempfile, os
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "routing.json")
            path.write_text('{"schema_version": 1, "roles": {"lead": ['
                            '{"agent": "pi", "agent": "codex"}]}}')
            routing, errs = load_routing(path, main_checkout=tmp,
                                         validate_model=validate_model,
                                         efforts_by_agent=EFFORTS, tiers=TIERS)
        self.assertIsNone(routing)
        self.assertTrue(any("duplicate JSON key" in e and "roles.lead[0]." in e
                            for e in errs), "\n".join(errs))

    def test_duplicate_top_level_key_is_refused(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "routing.json")
            path.write_text('{"schema_version": 1, "schema_version": 1, "roles": {}}')
            _, errs = load_routing(path, main_checkout=tmp,
                                   validate_model=validate_model,
                                   efforts_by_agent=EFFORTS, tiers=TIERS)
        self.assertTrue(any("schema_version" in e and "duplicate" in e for e in errs),
                        "\n".join(errs))


class Probes:
    """Recording probes: each call is logged so the check order is assertable.

    An override is either a plain value (returned as is) or a callable.
    """
    DEFAULTS = {"binary": True, "authority": None, "backend": None,
                "selection": {}, "usage": {"state": "ok"}}

    def __init__(self, **overrides):
        self.calls = []
        self.table = dict(self.DEFAULTS, **overrides)

    def _make(self, name):
        def probe(*args):
            self.calls.append((name,) + tuple(
                a["agent"] if isinstance(a, dict) and "agent" in a else a
                for a in args))
            value = self.table[name]
            return value(*args) if callable(value) else value
        return probe

    def as_dict(self):
        return {name: self._make(name) for name in self.DEFAULTS}

    def names(self):
        return [c[0] for c in self.calls]


def route(entries, **kwargs):
    probes = kwargs.pop("probes", None) or Probes()
    if isinstance(probes, Probes):
        probes = probes.as_dict()
    return evaluate_route(entries, probes=probes, **kwargs)


def reasons(decision):
    return [(s["index"], s["reason"]) for s in decision["skipped"]]


class OrderTests(unittest.TestCase):
    def test_first_entry_passing_every_check_is_chosen(self):
        decision = route([entry("pi"), entry("codex")])
        self.assertEqual(decision["chosen"]["index"], 1)
        self.assertEqual(decision["chosen"]["agent"], "pi")
        self.assertEqual(decision["skipped"], [])
        self.assertEqual(decision["exit_code"], 0)

    def test_reason_codes_are_the_documented_vocabulary(self):
        self.assertEqual(SKIP_REASONS, (
            "operator-skip", "tier", "binary-missing", "authority",
            "backend-unavailable", "model-not-allowed", "usage-denied",
            "usage-unknown"))

    def test_operator_skip_matches_agent_and_alias(self):
        decision = route([entry("antigravity"), entry("codex")], skip={"agy"})
        self.assertEqual(reasons(decision), [(1, "operator-skip")])
        self.assertEqual(decision["chosen"]["index"], 2)

    def test_operator_skip_runs_before_every_probe(self):
        probes = Probes()
        route([entry("pi")], skip={"pi"}, probes=probes)
        self.assertEqual(probes.calls, [])

    def test_tier_excludes_entry(self):
        decision = route([entry("pi", tiers=["routine"]), entry("codex")], tier="complex")
        self.assertEqual(reasons(decision), [(1, "tier")])
        self.assertIn("complex", decision["skipped"][0]["detail"])

    def test_entry_with_tiers_is_skipped_when_launch_has_no_tier(self):
        decision = route([entry("pi", tiers=["routine"]), entry("codex")])
        self.assertEqual(reasons(decision), [(1, "tier")])
        self.assertEqual(decision["skipped"][0]["detail"], "no tier given")

    def test_entry_without_tiers_accepts_any_tier(self):
        self.assertEqual(route([entry("pi")], tier="complex")["chosen"]["index"], 1)

    def test_binary_missing(self):
        probes = Probes(binary=lambda agent: agent != "pi")
        decision = route([entry("pi"), entry("codex")], probes=probes)
        self.assertEqual(reasons(decision), [(1, "binary-missing")])
        self.assertEqual(decision["chosen"]["agent"], "codex")

    def test_authority_refusal_carries_detail(self):
        probes = Probes(authority=lambda e: "planning needs --profile"
                        if e["agent"] == "codex" else None)
        decision = route([entry("codex"), entry("claude")], probes=probes)
        self.assertEqual(reasons(decision), [(1, "authority")])
        self.assertEqual(decision["skipped"][0]["detail"], "planning needs --profile")

    def test_backend_unavailable_uses_entry_backend(self):
        seen = []

        def backend(e, effective):
            seen.append(effective)
            return "herdr missing" if effective == "herdr" else None
        decision = route([entry("pi", backend="herdr"), entry("claude", backend="tmux")],
                         probes=Probes(backend=backend))
        self.assertEqual(seen, ["herdr", "tmux"])
        self.assertEqual(reasons(decision), [(1, "backend-unavailable")])
        self.assertEqual(decision["chosen"]["backend"], "tmux")

    def test_explicit_backend_replaces_the_entry_backend(self):
        seen = []
        probes = Probes(backend=lambda e, effective: seen.append(effective))
        decision = route([entry("pi", backend="herdr")], backend="tmux", probes=probes)
        self.assertEqual(seen, ["tmux"])
        self.assertEqual(decision["chosen"]["backend"], "tmux")

    def test_entry_without_backend_leaves_it_to_the_host(self):
        self.assertIsNone(route([entry("pi")])["chosen"]["backend"])

    def test_check_order_stops_at_the_first_failure(self):
        for overrides, expected in (
                (dict(binary=False, authority="no", backend="no"), ["binary"]),
                (dict(authority="no", backend="no"), ["binary", "authority"]),
                (dict(backend="no"), ["binary", "authority", "backend"])):
            probes = Probes(**overrides)
            route([entry("codex")], probes=probes)
            self.assertEqual(probes.names(), expected)

    def test_a_later_entry_is_not_probed_once_one_is_chosen(self):
        probes = Probes()
        route([entry("pi"), entry("codex")], probes=probes)
        self.assertTrue(all(c[1] == "pi" for c in probes.calls))

    def test_absent_probes_never_skip(self):
        self.assertEqual(evaluate_route([entry("pi")])["chosen"]["index"], 1)

    def test_detail_is_one_line_and_redacted(self):
        probes = Probes(authority=lambda e: "token=abc123\nsecond line")
        decision = route([entry("codex")], probes=probes,
                         redact=lambda text: text.replace("abc123", "<redacted>"))
        self.assertEqual(decision["skipped"][0]["detail"], "token=<redacted> second line")


class FatalTests(unittest.TestCase):
    def test_fatal_probe_error_propagates_instead_of_skipping(self):
        def broken(e):
            raise RoutingFatal("launch profile unreadable: /p")
        probes = Probes(authority=broken)
        with self.assertRaises(RoutingFatal):
            route([entry("codex"), entry("claude")], probes=probes)
        self.assertEqual(probes.names(), ["binary", "authority"])

    def test_other_probe_errors_also_propagate(self):
        def broken(*args):
            raise OSError("disk")
        with self.assertRaises(OSError):
            route([entry("codex")], probes=Probes(binary=broken))

    def test_routing_fatal_is_a_runtime_error(self):
        self.assertTrue(issubclass(RoutingFatal, RuntimeError))


class ExitClassificationTests(unittest.TestCase):
    def test_all_skipped_for_non_usage_reasons_exits_1(self):
        decision = route([entry("pi"), entry("codex")], probes=Probes(binary=False))
        self.assertIsNone(decision["chosen"])
        self.assertEqual(decision["exit_code"], 1)
        self.assertIsNone(decision["retry_at"])
        self.assertEqual([s["index"] for s in decision["skipped"]], [1, 2])


def table_selection(model="gpt-6.1-sol", effort="high", effort_source="table"):
    """A baseline selection probe standing in for the host's table lookup."""
    def selection(e, tier):
        return {"model": model, "model_source": "table", "effort": effort,
                "effort_source": effort_source, "tier_effort": effort,
                "tier_effort_source": effort_source}
    return selection


class SelectionTests(unittest.TestCase):
    def chosen(self, entries, **kwargs):
        return route(entries, **kwargs)["chosen"]

    def test_entry_models_replace_the_table_with_route_provenance(self):
        e = entry("codex", models={"complex": {"model": "gpt-6-luna", "effort": "medium"}})
        sel = self.chosen([e], tier="complex",
                          probes=Probes(selection=table_selection()))["selection"]
        self.assertEqual((sel["model"], sel["model_source"]), ("gpt-6-luna", "route"))
        self.assertEqual((sel["effort"], sel["effort_source"]), ("medium", "route"))
        self.assertEqual((sel["tier"], sel["tier_effort"], sel["tier_effort_source"]),
                         ("complex", "medium", "route"))

    def test_entry_effort_beats_a_project_override(self):
        e = entry("codex", models={"complex": {"effort": "medium"}})
        sel = self.chosen([e], tier="complex", probes=Probes(
            selection=table_selection("gpt-6.1-sol", "low", "project")))["selection"]
        self.assertEqual((sel["effort"], sel["effort_source"]), ("medium", "route"))
        self.assertEqual(sel["model"], "gpt-6.1-sol")
        self.assertEqual(sel["model_source"], "table")

    def test_entry_without_models_for_the_tier_keeps_the_baseline(self):
        e = entry("codex", models={"routine": {"model": "gpt-6-luna"}})
        sel = self.chosen([e], tier="complex",
                          probes=Probes(selection=table_selection("m", "low", "project")))[
            "selection"]
        self.assertEqual((sel["model"], sel["effort"], sel["effort_source"]),
                         ("m", "low", "project"))
        self.assertEqual(sel["tier_effort_source"], "project")

    def test_models_are_ignored_without_a_tier(self):
        e = entry("codex", models={"complex": {"model": "gpt-6-luna"}})
        sel = self.chosen([e], probes=Probes(
            selection=lambda e, t: {"model": "profile-m", "model_source": "profile"}))[
            "selection"]
        self.assertEqual((sel["model"], sel["model_source"]), ("profile-m", "profile"))
        self.assertIsNone(sel["tier"])
        self.assertIsNone(sel["tier_effort"])

    def test_pi_records_the_tier_with_a_null_tier_effort(self):
        sel = self.chosen([entry("pi")], tier="standard")["selection"]
        self.assertEqual(sel["tier"], "standard")
        self.assertIsNone(sel["tier_effort"])
        self.assertIsNone(sel["effort"])
        self.assertIsNone(sel["effort_source"])
        self.assertIsNone(sel["model"])
        self.assertEqual(sel["model_source"], "runtime-default")

    def test_pi_takes_its_model_from_the_entry(self):
        e = entry("pi", models={"standard": {"model": "glm-5"}})
        sel = self.chosen([e], tier="standard")["selection"]
        self.assertEqual((sel["model"], sel["model_source"]), ("glm-5", "route"))
        self.assertIsNone(sel["tier_effort"])

    def test_runtime_default_effort_is_named_for_claude_and_codex(self):
        sel = self.chosen([entry("claude")])["selection"]
        self.assertEqual((sel["effort"], sel["effort_source"]), (None, "runtime-default"))

    def test_explicit_model_and_effort_win_but_keep_the_tier_effort(self):
        e = entry("codex", models={"complex": {"model": "gpt-6-luna", "effort": "medium"}})
        sel = self.chosen([e], tier="complex", explicit={"model": "x", "effort": "low"},
                          probes=Probes(selection=table_selection()))["selection"]
        self.assertEqual((sel["model"], sel["model_source"]), ("x", "launch"))
        self.assertEqual((sel["effort"], sel["effort_source"]), ("low", "launch"))
        self.assertEqual((sel["tier_effort"], sel["tier_effort_source"]), ("medium", "route"))

    def test_selection_is_resolved_for_the_candidate_with_the_launch_tier(self):
        probes = Probes(selection=table_selection())
        route([entry("codex")], tier="complex", probes=probes)
        self.assertEqual(probes.calls[-2:], [("selection", "codex", "complex"),
                                             ("usage", "codex", probes.calls[-1][2])])

    def test_fatal_selection_error_propagates(self):
        def broken(e, t):
            raise RoutingFatal("profile unreadable")
        with self.assertRaises(RoutingFatal):
            route([entry("codex"), entry("claude")], probes=Probes(selection=broken))


class AllowTests(unittest.TestCase):
    ALLOW = [{"model": "gpt-6-luna"}, {"model": "gpt-6.1-sol", "efforts": ["low"]}]

    def decide(self, model, effort, **extra):
        probes = Probes(selection=lambda e, t: {"model": model, "effort": effort})
        return route([entry("codex", allow=self.ALLOW, **extra), entry("claude")],
                     probes=probes)

    def test_allowed_pair_is_chosen(self):
        self.assertEqual(self.decide("gpt-6.1-sol", "low")["chosen"]["index"], 1)

    def test_unrestricted_efforts_accept_any_effort(self):
        self.assertEqual(self.decide("gpt-6-luna", "high")["chosen"]["index"], 1)

    def test_model_outside_allow_is_skipped(self):
        decision = self.decide("gpt-7", "low")
        self.assertEqual(reasons(decision), [(1, "model-not-allowed")])
        self.assertIn("gpt-7", decision["skipped"][0]["detail"])

    def test_effort_outside_the_allowed_efforts_is_skipped(self):
        decision = self.decide("gpt-6.1-sol", "high")
        self.assertEqual(reasons(decision), [(1, "model-not-allowed")])
        self.assertIn("high", decision["skipped"][0]["detail"])

    def test_unknown_runtime_default_model_is_skipped_under_allow(self):
        decision = self.decide(None, "low")
        self.assertEqual(reasons(decision), [(1, "model-not-allowed")])
        self.assertIn("runtime default", decision["skipped"][0]["detail"])

    def test_unknown_effort_is_skipped_when_the_allowed_efforts_restrict_it(self):
        self.assertEqual(reasons(self.decide("gpt-6.1-sol", None)),
                         [(1, "model-not-allowed")])

    def test_unknown_model_without_allow_is_accepted(self):
        self.assertEqual(route([entry("codex")])["chosen"]["index"], 1)

    def test_allow_check_uses_the_entry_resolved_selection(self):
        e = entry("codex", allow=self.ALLOW,
                  models={"complex": {"model": "gpt-6.1-sol", "effort": "low"}})
        decision = route([e], tier="complex", probes=Probes(
            selection=table_selection("gpt-7", "high")))
        self.assertEqual(decision["chosen"]["selection"]["model"], "gpt-6.1-sol")

    def test_explicit_selection_outside_allow_is_refused(self):
        e = entry("codex", allow=self.ALLOW)
        decision = route([e], explicit={"model": "gpt-6.1-sol", "effort": "high"})
        self.assertEqual(reasons(decision), [(1, "model-not-allowed")])
        decision = route([e], explicit={"model": "gpt-6.1-sol", "effort": "low"})
        self.assertEqual(decision["chosen"]["selection"]["model"], "gpt-6.1-sol")

    def test_allow_runs_before_the_usage_gate(self):
        probes = Probes(selection=lambda e, t: {"model": "gpt-7"})
        route([entry("codex", allow=self.ALLOW)], probes=probes)
        self.assertNotIn("usage", probes.names())


class UsageTests(unittest.TestCase):
    def test_denied_entry_is_skipped_and_the_next_is_admitted(self):
        probes = Probes(usage=lambda e, sel: {"state": "denied", "retry_at": 100}
                        if e["agent"] == "codex" else {"state": "ok"})
        decision = route([entry("codex"), entry("claude")], probes=probes)
        self.assertEqual(reasons(decision), [(1, "usage-denied")])
        self.assertEqual(decision["chosen"]["agent"], "claude")

    def test_only_the_chosen_entry_reaches_the_admission_probe_after_it(self):
        probes = Probes()
        route([entry("codex"), entry("claude")], probes=probes)
        self.assertEqual(sum(1 for c in probes.calls if c[0] == "usage"), 1)

    def test_unknown_is_admitted_with_a_warning_by_default(self):
        probes = Probes(usage=lambda e, sel: {"state": "unknown", "detail": "no data"})
        chosen = route([entry("codex")], probes=probes)["chosen"]
        self.assertEqual(chosen["index"], 1)
        self.assertEqual(chosen["warnings"], ["usage unknown: no data"])

    def test_entry_on_unknown_deny_skips_with_usage_unknown(self):
        probes = Probes(usage=lambda e, sel: {"state": "unknown"})
        decision = route([entry("codex", on_unknown="deny"), entry("claude")],
                         probes=Probes(usage=lambda e, sel: {"state": "unknown"}
                                       if e["agent"] == "codex" else {"state": "ok"}))
        self.assertEqual(reasons(decision), [(1, "usage-unknown")])
        self.assertEqual(decision["chosen"]["agent"], "claude")

    def test_entry_on_unknown_warn_overrides_a_denying_gate(self):
        probes = Probes(usage=lambda e, sel: {"state": "unknown", "on_unknown": "deny"})
        decision = route([entry("codex", on_unknown="warn")], probes=probes)
        self.assertEqual(decision["chosen"]["index"], 1)

    def test_gate_on_unknown_applies_when_the_entry_sets_none(self):
        probes = Probes(usage=lambda e, sel: {"state": "unknown", "on_unknown": "deny"})
        decision = route([entry("codex")], probes=probes)
        self.assertEqual(reasons(decision), [(1, "usage-unknown")])

    def test_usage_probe_receives_the_resolved_selection(self):
        seen = []
        probes = Probes(selection=table_selection(),
                        usage=lambda e, sel: seen.append(sel["model"]) or {"state": "ok"})
        route([entry("codex")], tier="complex", probes=probes)
        self.assertEqual(seen, ["gpt-6.1-sol"])

    def test_chosen_carries_the_admitted_usage_result(self):
        probes = Probes(usage=lambda e, sel: {"state": "ok", "ticket": "t1"})
        self.assertEqual(route([entry("codex")], probes=probes)["chosen"]["usage"]["ticket"], "t1")


class AllSkippedTests(unittest.TestCase):
    def test_usage_denied_entry_makes_the_exit_75_with_the_earliest_retry(self):
        retries = {"codex": 300, "claude": 200}
        probes = Probes(usage=lambda e, sel: {"state": "denied",
                                              "retry_at": retries[e["agent"]]})
        decision = route([entry("codex"), entry("claude")], probes=probes)
        self.assertIsNone(decision["chosen"])
        self.assertEqual(decision["exit_code"], 75)
        self.assertEqual(decision["retry_at"], 200)
        self.assertEqual([s["retry_at"] for s in decision["skipped"]], [300, 200])

    def test_retry_ignores_denied_entries_without_a_retry_time(self):
        probes = Probes(usage=lambda e, sel: {"state": "denied",
                                              "retry_at": 50 if e["agent"] == "codex" else None})
        decision = route([entry("codex"), entry("claude")], probes=probes)
        self.assertEqual((decision["exit_code"], decision["retry_at"]), (75, 50))

    def test_denied_without_any_retry_time_still_exits_75(self):
        decision = route([entry("codex")], probes=Probes(usage=lambda e, s: {"state": "denied"}))
        self.assertEqual((decision["exit_code"], decision["retry_at"]), (75, None))

    def test_one_usage_denied_entry_among_others_exits_75(self):
        probes = Probes(binary=lambda a: a != "pi",
                        usage=lambda e, sel: {"state": "denied", "retry_at": 9})
        decision = route([entry("pi"), entry("codex")], probes=probes)
        self.assertEqual(reasons(decision), [(1, "binary-missing"), (2, "usage-denied")])
        self.assertEqual(decision["exit_code"], 75)

    def test_usage_unknown_alone_exits_1(self):
        probes = Probes(usage=lambda e, sel: {"state": "unknown"})
        decision = route([entry("codex", on_unknown="deny")], probes=probes)
        self.assertEqual((decision["exit_code"], decision["retry_at"]), (1, None))

    def test_model_not_allowed_alone_exits_1(self):
        probes = Probes(selection=lambda e, t: {"model": "x"})
        decision = route([entry("codex", allow=[{"model": "y"}])], probes=probes)
        self.assertEqual(decision["exit_code"], 1)


class PinEntryTests(unittest.TestCase):
    ENTRIES = [entry("pi"), entry("codex", backend="tmux"), entry("codex", backend="herdr")]

    def test_first_entry_for_the_agent_is_pinned(self):
        self.assertEqual(pin_entry(self.ENTRIES, "codex"), (2, self.ENTRIES[1]))

    def test_explicit_backend_picks_the_first_matching_entry(self):
        self.assertEqual(pin_entry(self.ENTRIES, "codex", "herdr"), (3, self.ENTRIES[2]))

    def test_alias_is_normalized(self):
        entries = [entry("antigravity")]
        self.assertEqual(pin_entry(entries, "agy"), (1, entries[0]))

    def test_unlisted_agent_is_off_list(self):
        self.assertIsNone(pin_entry(self.ENTRIES, "claude"))
        self.assertIsNone(pin_entry(self.ENTRIES, "codex", "unknown"))

    def test_entry_without_a_written_backend_does_not_match_an_explicit_one(self):
        self.assertIsNone(pin_entry([entry("pi")], "pi", "herdr"))


_LAST_PATH = None


def load_and_errors():
    """Helper for the file-prefix assertion: errors from a stored invalid file."""
    global _LAST_PATH
    import json, tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp, "routing.json")
        doc = {"schema_version": 1, "roles": {"lead": [entry("nope")]}}
        path.write_text(json.dumps(doc))
        _LAST_PATH = path
        _, errs = load_routing("routing.json", main_checkout=tmp,
                               validate_model=validate_model,
                               efforts_by_agent=EFFORTS, tiers=TIERS)
    return errs


if __name__ == "__main__":
    unittest.main(verbosity=2)
