#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# /// script
# requires-python = ">=3.11"
# ///
"""Offline behavioural probes: uv run tests/collect-runner-capacity.py."""

import copy
import importlib.util
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

SOURCE = (
    Path(__file__).resolve().parents[1]
    / "skills/github-project/scripts/collect-runner-capacity.py"
)
SPEC = importlib.util.spec_from_file_location("capacity", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def run_record(identity=1, attempt=1, head="a" * 40):
    return {
        "id": identity,
        "head_sha": head,
        "run_attempt": attempt,
        "updated_at": "2026-10-29T00:00:00Z",
        "status": "completed",
        "conclusion": "success",
    }


def job(identity=1, **extra):
    return {
        "id": identity,
        "run_id": 1,
        "name": f"job-{identity}",
        "status": "queued",
        "runner_id": 0,
        **extra,
    }


class CapacityTests(unittest.TestCase):
    def test_pagination_reads_page_after_full_page_and_retains_provenance(self):
        def request(endpoint):
            page = int(parse_qs(urlsplit(endpoint).query)["page"][0])
            return {
                "jobs": [job(i) for i in range(1, 101)] if page == 1 else [job(101)],
                "total_count": 101,
            }

        collector = MODULE.Collector(request)
        result = collector.pages("jobs", "jobs")
        self.assertEqual(len(result), 101)
        self.assertEqual(len(collector.reads), 2)
        self.assertIn("page=2", collector.reads[1]["endpoint"])
        self.assertIn("body", collector.reads[0])
        self.assertIn("completedAt", collector.reads[0])
        self.assertEqual(collector.errors, [])

    def test_search_cap_is_incomplete_instead_of_silent_1000(self):
        collector = MODULE.Collector(
            lambda _: {"workflow_runs": [run_record()], "total_count": 1000}
        )
        self.assertEqual(collector.pages("runs", "workflow_runs", capped=True), [])
        self.assertEqual(collector.errors[0]["error"], "search_cap_split_window")

    def test_duplicate_and_missing_pages_mark_incomplete(self):
        collector = MODULE.Collector(
            lambda _: {"jobs": [job(), job()], "total_count": 2}
        )
        collector.pages("jobs", "jobs")
        self.assertEqual(collector.errors[0]["error"], "duplicate_or_invalid_id")
        collector = MODULE.Collector(lambda _: {"jobs": [job()], "total_count": 3})
        collector.pages("jobs", "jobs")
        self.assertEqual(collector.errors[0]["error"], "incomplete_collection")

    def test_needs_blocked_record_is_not_reported_as_executor_wait(self):
        record = run_record()

        def request(endpoint):
            if "jobs?" in endpoint:
                return {
                    "jobs": [job(), job(2, runner_id=7, status="completed")],
                    "total_count": 2,
                }
            return record

        collector = MODULE.Collector(request)
        result = collector.run("acme/repo", record, "a" * 40)
        self.assertEqual(
            result["latestAttemptRecords"],
            {"jobs": 2, "assigned": 1, "statuses": {"queued": 1, "completed": 1}},
        )
        self.assertTrue(result["executorReadiness"].startswith("unknown"))
        self.assertNotIn("executorWaitSeconds", result)

    def test_obsolete_head_retained_and_retry_jobs_not_summed(self):
        record = run_record(attempt=2, head="b" * 40)

        def request(endpoint):
            if "/attempts/" in endpoint:
                identity = 11 if "/attempts/1/" in endpoint else 22
                return {
                    "jobs": [
                        job(identity, runner_id=7, started_at="2026-10-29T00:00:00Z")
                    ],
                    "total_count": 1,
                }
            return record

        collector = MODULE.Collector(request)
        result = collector.run("acme/repo", record, "a" * 40)
        self.assertEqual(result["headSelection"], "obsolete")
        self.assertEqual(len(result["attempts"]), 2)
        self.assertEqual(result["latestAttemptRecords"]["assigned"], 1)
        self.assertIn("do not sum attempts", result["attemptAccounting"])

    def test_moving_run_invalidates_snapshot(self):
        record = run_record()
        reads = 0

        def request(endpoint):
            nonlocal reads
            if "jobs?" in endpoint:
                return {"jobs": [], "total_count": 0}
            reads += 1
            response = copy.copy(record)
            if reads > 1:
                response["run_attempt"] = 2
            return response

        collector = MODULE.Collector(request)
        result = collector.run("acme/repo", record, None)
        self.assertFalse(result["stableDuringRead"])
        self.assertEqual(collector.errors[0]["error"], "run_changed_during_read")

    def test_api_failure_produces_incomplete_report_with_error(self):
        def request(_):
            raise OSError("private details must not leak")

        result = MODULE.Collector(request).collect(
            ["acme/repo"], None, "start", "end", {}
        )
        self.assertFalse(result["complete"])
        self.assertEqual(result["errors"][0]["error"], "OSError")
        self.assertNotIn("private details", str(result))

    def test_org_repository_enumeration_keeps_visibility_limit(self):
        def request(endpoint):
            if endpoint == "user":
                return {"id": 99, "login": "reader", "type": "User"}
            if endpoint.startswith("orgs/"):
                return [{"id": 1, "full_name": "acme/repo"}]
            return {"workflow_runs": [], "total_count": 0}

        result = MODULE.Collector(request).collect([], "acme", "start", "end", {})
        self.assertTrue(result["complete"])
        self.assertEqual(result["scope"]["repositories"], ["acme/repo"])
        self.assertIn("token visibility", result["scope"]["repositoryCoverage"])

    def test_malformed_api_responses_never_claim_complete(self):
        for body in (
            None,
            [],
            {"workflow_runs": [], "total_count": True},
            {"workflow_runs": [None], "total_count": 1},
        ):
            with self.subTest(body=body):
                result = MODULE.Collector(lambda _, body=body: body).collect(
                    ["acme/repo"], None, "start", "end", {}
                )
                self.assertFalse(result["complete"])

    def test_deleted_or_new_run_invalidates_final_inventory(self):
        inventory_reads = 0

        def request(endpoint):
            nonlocal inventory_reads
            if endpoint == "user":
                return {"id": 99, "login": "reader", "type": "User"}
            if "/actions/runs?" in endpoint:
                inventory_reads += 1
                return {
                    "workflow_runs": [] if inventory_reads == 1 else [run_record()],
                    "total_count": 0 if inventory_reads == 1 else 1,
                }
            raise AssertionError(endpoint)

        result = MODULE.Collector(request).collect(
            ["acme/repo"], None, "start", "end", {}
        )
        self.assertFalse(result["complete"])
        self.assertEqual(result["errors"][0]["error"], "run_inventory_changed")

    def test_incomplete_run_revision_cannot_be_labelled_obsolete(self):
        collector = MODULE.Collector(lambda _: {"id": 1, "run_attempt": 1})
        self.assertIsNone(collector.run("acme/repo", run_record(), "a" * 40))
        self.assertEqual(collector.errors[0]["error"], "invalid_run_revision")

    def test_runner_identity_and_attempt_validation_preserve_unassigned_null(self):
        for runner, attempt, valid in (
            (None, 1, True),
            (0, 1, True),
            (7, 1, True),
            (True, 1, False),
            (-1, 1, False),
            (7, 2, False),
        ):
            with self.subTest(runner=runner, attempt=attempt):

                def request(endpoint, runner=runner, attempt=attempt):
                    if "jobs?" in endpoint:
                        return {
                            "jobs": [job(runner_id=runner, run_attempt=attempt)],
                            "total_count": 1,
                        }
                    return run_record()

                collector = MODULE.Collector(request)
                collector.run("acme/repo", run_record(), None)
                self.assertEqual(not collector.errors, valid)

    def test_host_is_explicit_and_principal_is_recorded(self):
        def request(endpoint):
            if endpoint == "user":
                return {"id": 99, "login": "reader", "type": "User"}
            return {"workflow_runs": [], "total_count": 0}

        result = MODULE.Collector(request, hostname="github.example").collect(
            ["acme/repo"], None, "start", "end", {}
        )
        self.assertTrue(result["complete"])
        self.assertEqual(result["scope"]["hostname"], "github.example")
        self.assertEqual(result["scope"]["principal"]["login"], "reader")
        self.assertEqual(result["reads"][0]["endpoint"], "user")

    def test_boolean_identity_and_malformed_revision_fail_closed(self):
        for delta in (
            {"id": True},
            {"updated_at": "not-a-date"},
            {"updated_at": "2026-10-29"},
            {"conclusion": {"unexpected": "shape"}},
        ):
            with self.subTest(delta=delta):
                record = {**run_record(), **delta}
                collector = MODULE.Collector(lambda _, record=record: record)
                self.assertIsNone(collector.run("acme/repo", run_record(), None))
                self.assertTrue(collector.errors)

    def test_boolean_job_binding_cannot_match_integer_run_or_attempt(self):
        for delta in ({"run_id": True}, {"run_attempt": True}):
            with self.subTest(delta=delta):

                def request(endpoint, delta=delta):
                    if "jobs?" in endpoint:
                        return {"jobs": [{**job(), **delta}], "total_count": 1}
                    return run_record()

                collector = MODULE.Collector(request)
                collector.run("acme/repo", run_record(), None)
                self.assertTrue(collector.errors)

    def test_principal_boolean_or_empty_login_is_not_verified(self):
        for principal in ({"id": True, "login": "reader"}, {"id": 1, "login": ""}):
            with self.subTest(principal=principal):

                def request(endpoint, principal=principal):
                    if endpoint == "user":
                        return principal
                    return {"workflow_runs": [], "total_count": 0}

                result = MODULE.Collector(request).collect(
                    ["acme/repo"], None, "start", "end", {}
                )
                self.assertFalse(result["complete"])
                self.assertEqual(result["errors"][0]["error"], "unverified_principal")


if __name__ == "__main__":
    unittest.main()
