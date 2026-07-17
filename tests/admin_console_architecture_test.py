#!/usr/bin/env python3
"""Contract tests for the MQTT administration-console architecture decision."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAN_DIR = ROOT / "docs" / "admin-console"
SCORECARD_PATH = PLAN_DIR / "scorecard.json"
ADR_PATH = ROOT / "docs" / "adr" / "0001-mqtt-admin-console.md"

CANDIDATES = {
    "eclipse-mosquitto-dashboard",
    "mqttctl",
    "custom-hybrid",
}

REQUIRED_CRITERIA = {
    "security-boundaries",
    "dynamic-security",
    "operator-auth-rbac",
    "auditability",
    "effective-permissions",
    "deployment-fit",
    "license",
}

REQUIRED_ARTIFACTS = [
    PLAN_DIR / "README.md",
    PLAN_DIR / "requirements.md",
    SCORECARD_PATH,
    PLAN_DIR / "evaluations" / "eclipse-mosquitto-dashboard.md",
    PLAN_DIR / "evaluations" / "mqttctl.md",
    PLAN_DIR / "poc" / "eclipse-mosquitto-dashboard" / "README.md",
    PLAN_DIR / "poc" / "eclipse-mosquitto-dashboard" / "compose.yaml",
    PLAN_DIR / "poc" / "eclipse-mosquitto-dashboard" / ".env.example",
    PLAN_DIR / "poc" / "eclipse-mosquitto-dashboard" / "Dockerfile",
    PLAN_DIR / "poc" / "eclipse-mosquitto-dashboard" / "mosquitto.conf",
    PLAN_DIR / "poc" / "mqttctl" / "README.md",
    PLAN_DIR / "poc" / "mqttctl" / "compose.yaml",
    PLAN_DIR / "poc" / "mqttctl" / ".env.example",
    ADR_PATH,
]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_scorecard() -> dict:
    return json.loads(read_text(SCORECARD_PATH))


class ArchitectureArtifactsTest(unittest.TestCase):
    def test_required_artifacts_exist(self) -> None:
        missing = [str(path.relative_to(ROOT)) for path in REQUIRED_ARTIFACTS if not path.is_file()]
        self.assertEqual([], missing, f"Missing architecture artifacts: {missing}")

    def test_requirements_cover_personas_workflows_and_constraints(self) -> None:
        requirements = read_text(PLAN_DIR / "requirements.md")
        for heading in (
            "## Personas",
            "## Primary workflows",
            "## Capability classification",
            "## Functional requirements",
            "## Non-functional requirements",
            "## Out of scope",
            "## Evidence requirements",
        ):
            self.assertIn(heading, requirements)

        for persona in ("Viewer", "Operator", "Security Admin", "Super Admin"):
            self.assertIn(persona, requirements)

        for constraint in ("OIDC", "Dynamic Security", "Docker socket", "audit", "rollback"):
            self.assertIn(constraint, requirements)

    def test_scorecard_is_complete_and_reproducible(self) -> None:
        scorecard = load_scorecard()
        self.assertEqual(1, scorecard["schema_version"])
        self.assertEqual("2026-07-17", scorecard["evaluated_on"])
        self.assertEqual("custom-hybrid", scorecard["decision"]["selected_candidate_id"])
        self.assertRegex(scorecard["decision"]["review_on"], r"^\d{4}-\d{2}-\d{2}$")

        criteria = scorecard["criteria"]
        criterion_ids = {criterion["id"] for criterion in criteria}
        self.assertEqual(len(criteria), len(criterion_ids), "Criterion IDs must be unique")
        self.assertEqual(100, sum(criterion["weight"] for criterion in criteria))
        self.assertTrue(REQUIRED_CRITERIA.issubset(criterion_ids))
        self.assertTrue(
            REQUIRED_CRITERIA.issubset(
                {
                    criterion["id"]
                    for criterion in criteria
                    if criterion["classification"] == "required"
                }
            )
        )
        for criterion in criteria:
            self.assertIn(criterion["classification"], {"required", "preferred"})
            self.assertGreater(criterion["weight"], 0)
            self.assertTrue(criterion["evidence_requirement"].strip())

        candidates = scorecard["candidates"]
        self.assertEqual(CANDIDATES, {candidate["id"] for candidate in candidates})
        allowed_statuses = {"verified", "partial", "unknown", "blocked", "planned"}
        required_ids = {
            criterion["id"]
            for criterion in criteria
            if criterion["classification"] == "required"
        }
        weights = {criterion["id"]: criterion["weight"] for criterion in criteria}
        minimum_required_score = scorecard["decision"]["minimum_required_score"]
        summaries = {summary["candidate_id"]: summary for summary in scorecard["summary"]}

        self.assertEqual(CANDIDATES, set(summaries))
        self.assertEqual({1, 2, 3}, {summary["rank"] for summary in summaries.values()})

        for candidate in candidates:
            source = candidate["source"]
            self.assertRegex(source["commit"], r"^[0-9a-f]{40}$")
            self.assertTrue(source["repository"].startswith("https://github.com/"))
            self.assertTrue(candidate["license"]["spdx"].strip())

            scores = candidate["scores"]
            self.assertEqual(criterion_ids, set(scores), f"Incomplete score set for {candidate['id']}")
            for criterion_id, result in scores.items():
                self.assertIsInstance(result["score"], int)
                self.assertGreaterEqual(result["score"], 0)
                self.assertLessEqual(result["score"], 5)
                self.assertIn(result["status"], allowed_statuses)
                self.assertTrue(result["evidence"].strip())
                self.assertTrue(result["sources"])
                for source_url in result["sources"]:
                    self.assertRegex(source_url, r"^https://(github\.com|mosquitto\.org|grafana\.com|docs\.influxdata\.com)/")

            weighted_score = round(
                sum(weights[criterion_id] * result["score"] / 5 for criterion_id, result in scores.items()),
                2,
            )
            required_failures = sorted(
                criterion_id
                for criterion_id in required_ids
                if scores[criterion_id]["score"] < minimum_required_score
            )
            summary = summaries[candidate["id"]]
            self.assertEqual(weighted_score, summary["weighted_score"])
            self.assertEqual(required_failures, sorted(summary["required_failures"]))
            self.assertEqual(not required_failures, summary["eligible"])

        selected = summaries[scorecard["decision"]["selected_candidate_id"]]
        self.assertTrue(selected["eligible"])

    def test_poc_definitions_are_pinned_isolated_and_documented(self) -> None:
        scorecard = load_scorecard()
        candidates = {candidate["id"]: candidate for candidate in scorecard["candidates"]}

        for candidate_id in ("eclipse-mosquitto-dashboard", "mqttctl"):
            with self.subTest(candidate=candidate_id):
                poc_dir = PLAN_DIR / "poc" / candidate_id
                compose = read_text(poc_dir / "compose.yaml")
                instructions = read_text(poc_dir / "README.md")
                env_example = read_text(poc_dir / ".env.example")
                commit = candidates[candidate_id]["source"]["commit"]

                self.assertIn(commit, compose)
                self.assertNotRegex(compose, r"(?m):(?:latest|dev)(?:\s|$)")
                self.assertNotIn("/var/run/docker.sock", compose)
                self.assertNotRegex(compose, r"(?m)^\s*-\s*[\"']?0\.0\.0\.0:")
                self.assertIn("127.0.0.1:", compose)
                self.assertIn("internal: true", compose)

                self.assertIn("docker compose --env-file .env -f compose.yaml config", instructions)
                self.assertIn("docker compose --env-file .env -f compose.yaml up", instructions)
                self.assertIn("docker compose --env-file .env -f compose.yaml down", instructions)
                self.assertIn("evaluation only", instructions.lower())
                self.assertIn("production", instructions.lower())

                self.assertIn("CHANGE_ME", env_example)
                self.assertNotRegex(env_example, r"(?i)(password|secret|api_key)=.{16,}")

    def test_evaluations_use_primary_evidence_and_record_limitations(self) -> None:
        for candidate_id in ("eclipse-mosquitto-dashboard", "mqttctl"):
            with self.subTest(candidate=candidate_id):
                evaluation = read_text(PLAN_DIR / "evaluations" / f"{candidate_id}.md")
                for heading in (
                    "## Evidence snapshot",
                    "## PoC procedure",
                    "## Findings",
                    "## Security review",
                    "## Limitations",
                    "## Scorecard conclusion",
                ):
                    self.assertIn(heading, evaluation)
                self.assertIn("https://github.com/", evaluation)
                self.assertIn("commit", evaluation.lower())
                self.assertIn("production", evaluation.lower())

    def test_adr_records_a_complete_actionable_decision(self) -> None:
        adr = read_text(ADR_PATH)
        for heading in (
            "## Status",
            "## Context",
            "## Decision drivers",
            "## Considered options",
            "## Decision",
            "## Consequences",
            "## Rollout and rollback",
            "## Review",
        ):
            self.assertIn(heading, adr)

        self.assertIn("Accepted", adr)
        self.assertIn("custom hybrid", adr.lower())
        self.assertIn("Eclipse Mosquitto Dashboard", adr)
        self.assertIn("MqttCtl", adr)
        for issue_number in (3, 4, 5, 6):
            self.assertRegex(adr, rf"(?<!\d)#{issue_number}(?!\d)")
        self.assertRegex(adr, r"Review date:\s*\d{4}-\d{2}-\d{2}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
