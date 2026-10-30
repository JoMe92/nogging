"""Unit tests for the agent routing file loader and validator.

Covers every scenario of the agent-routing file and validation requirements
(change configurable-agent-routing): a valid file loads in order, a missing
file means no routing, and every malformed shape is refused naming the file,
the JSON path and the rule. Pure: model names and effort vocabularies are
injected, so no scripts/nogg import is needed.
"""
import unittest

from agent_routing import (AGENTS, DEFAULT_ROUTING_PATH, ROLES, SCHEMA_VERSION,
                           load_routing, normalize_agent, routing_errors)

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
