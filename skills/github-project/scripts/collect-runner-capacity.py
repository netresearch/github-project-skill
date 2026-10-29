#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# /// script
# requires-python = ">=3.11"
# ///
"""Collect a read-only, non-atomic Actions cohort; never infer executor readiness.

Run with Python 3.11+ and authenticated gh. Only GET requests are issued. Raw
responses and read timestamps are retained in the JSON output, including errors.
"""

import argparse
import json
import re
import subprocess
import sys
from datetime import UTC, datetime
from urllib.parse import urlencode


def now():
    return datetime.now(UTC).isoformat()


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def timestamp(value):
    if not isinstance(value, str):
        return False
    try:
        return datetime.fromisoformat(value).utcoffset() is not None
    except ValueError:
        return False


class Collector:
    def __init__(self, request=None, hostname="github.com"):
        self.hostname = hostname
        self.request = request or self.gh_get
        self.reads = []
        self.errors = []

    def gh_get(self, endpoint):
        result = subprocess.run(
            ["gh", "api", "--hostname", self.hostname, "--method", "GET", endpoint],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
        return json.loads(result.stdout)

    def get(self, endpoint):
        read = {"endpoint": endpoint, "startedAt": now()}
        self.reads.append(read)
        try:
            read["body"] = self.request(endpoint)
            if read["body"] is None:
                raise ValueError("null response")
            return read["body"]
        except (
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            ValueError,
            OSError,
        ) as error:
            # Do not include subprocess arguments, stderr, or credentials.
            read["error"] = type(error).__name__
            self.errors.append({"endpoint": endpoint, "error": type(error).__name__})
            return None
        finally:
            read["completedAt"] = now()

    def pages(self, path, key=None, query=None, capped=False):
        records, seen, total = [], set(), None
        for page in range(1, 1001):
            query_string = urlencode({**(query or {}), "per_page": 100, "page": page})
            body = self.get(f"{path}?{query_string}")
            if body is None:
                return records
            items = (
                body
                if key is None
                else body.get(key)
                if isinstance(body, dict)
                else None
            )
            count = body.get("total_count") if key and isinstance(body, dict) else None
            if not isinstance(items, list) or (
                key
                and (not isinstance(count, int) or isinstance(count, bool) or count < 0)
            ):
                self.errors.append({"endpoint": path, "error": "invalid_collection"})
                return records
            if total is not None and count != total:
                self.errors.append({"endpoint": path, "error": "collection_changed"})
            total = count
            if capped and count >= 1000:
                self.errors.append(
                    {"endpoint": path, "error": "search_cap_split_window"}
                )
                return records
            for item in items:
                identity = item.get("id") if isinstance(item, dict) else None
                if not positive_integer(identity) or identity in seen:
                    self.errors.append(
                        {"endpoint": path, "error": "duplicate_or_invalid_id"}
                    )
                    return records
                seen.add(identity)
                records.append(item)
            if len(items) < 100:
                if count is not None and len(records) != count:
                    self.errors.append(
                        {"endpoint": path, "error": "incomplete_collection"}
                    )
                return records
        self.errors.append({"endpoint": path, "error": "pagination_bound"})
        return records

    def run(self, repository, listed, expected_head):
        path = f"repos/{repository}/actions/runs/{listed['id']}"
        before = self.get(path)
        if before is None:
            return None
        if (
            not isinstance(before, dict)
            or not positive_integer(before.get("id"))
            or before.get("id") != listed["id"]
        ):
            self.errors.append({"endpoint": path, "error": "invalid_run"})
            return None
        if (
            not isinstance(before.get("head_sha"), str)
            or not re.fullmatch(r"[a-fA-F0-9]{40}", before["head_sha"])
            or not timestamp(before.get("updated_at"))
            or not isinstance(before.get("status"), str)
            or not before["status"]
            or "conclusion" not in before
            or (
                before["conclusion"] is not None
                and not isinstance(before["conclusion"], str)
            )
        ):
            self.errors.append({"endpoint": path, "error": "invalid_run_revision"})
            return None
        attempts = []
        number = before.get("run_attempt")
        if (
            not isinstance(number, int)
            or isinstance(number, bool)
            or not 1 <= number <= 51
        ):
            self.errors.append({"endpoint": path, "error": "invalid_attempt"})
            return None
        for attempt in range(1, number + 1):
            jobs = self.pages(f"{path}/attempts/{attempt}/jobs", "jobs")
            for job in jobs:
                if (
                    not positive_integer(job.get("run_id"))
                    or job.get("run_id") != before["id"]
                ):
                    self.errors.append({"endpoint": path, "error": "job_run_mismatch"})
                runner = job.get("runner_id")
                if (
                    isinstance(runner, bool)
                    or (
                        runner is not None
                        and (not isinstance(runner, int) or runner < 0)
                    )
                    or not isinstance(job.get("status"), str)
                    or (
                        "run_attempt" in job
                        and (
                            not positive_integer(job["run_attempt"])
                            or job["run_attempt"] != attempt
                        )
                    )
                ):
                    self.errors.append({"endpoint": path, "error": "invalid_job"})
            attempts.append({"attempt": attempt, "jobs": jobs})
        after = self.get(path)
        revision_keys = (
            "id",
            "head_sha",
            "run_attempt",
            "updated_at",
            "status",
            "conclusion",
        )
        stable = isinstance(after, dict) and all(
            type(before.get(k)) is type(after.get(k)) and before.get(k) == after.get(k)
            for k in revision_keys
        )
        if not stable:
            self.errors.append({"endpoint": path, "error": "run_changed_during_read"})
        latest_jobs = attempts[-1]["jobs"]
        assigned = [
            j
            for j in latest_jobs
            if isinstance(j.get("runner_id"), int)
            and not isinstance(j["runner_id"], bool)
            and j["runner_id"] > 0
        ]
        statuses = {}
        for job in latest_jobs:
            status = (
                job.get("status") if isinstance(job.get("status"), str) else "unknown"
            )
            statuses[status] = statuses.get(status, 0) + 1
        return {
            "repository": repository,
            "run": before,
            "stableDuringRead": stable,
            "headSelection": (
                "unspecified"
                if expected_head is None
                else "current"
                if before.get("head_sha") == expected_head
                else "obsolete"
            ),
            "attempts": attempts,
            "latestAttemptRecords": {
                "jobs": len(latest_jobs),
                "assigned": len(assigned),
                "statuses": statuses,
            },
            "executorReadiness": "unknown: API job status/timestamps do not expose needs or approvals",
            "attemptAccounting": "Carried jobs can have new IDs with old execution times; do not sum attempts as executions.",
        }

    def collect(self, repositories, organization, since, until, heads):
        started = now()
        identity = self.get("user")
        if (
            not isinstance(identity, dict)
            or not positive_integer(identity.get("id"))
            or not isinstance(identity.get("login"), str)
            or not identity["login"].strip()
        ):
            self.errors.append({"endpoint": "user", "error": "unverified_principal"})
        if organization:
            inventory = self.pages(f"orgs/{organization}/repos")
            repositories = []
            for repository in inventory:
                full_name = repository.get("full_name")
                if not isinstance(full_name, str) or not re.fullmatch(
                    r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", full_name
                ):
                    self.errors.append(
                        {
                            "endpoint": f"orgs/{organization}/repos",
                            "error": "invalid_repository",
                        }
                    )
                    continue
                repositories.append(full_name)
        repositories = sorted(set(repositories))
        runs = []
        for repository in repositories:
            listed = self.pages(
                f"repos/{repository}/actions/runs",
                "workflow_runs",
                {"created": f"{since}..{until}"},
                capped=True,
            )
            for item in listed:
                result = self.run(repository, item, heads.get(repository))
                if result:
                    runs.append(result)
            final_inventory = self.pages(
                f"repos/{repository}/actions/runs",
                "workflow_runs",
                {"created": f"{since}..{until}"},
                capped=True,
            )
            keys = (
                "id",
                "head_sha",
                "run_attempt",
                "updated_at",
                "status",
                "conclusion",
            )
            first = sorted(tuple(str(r.get(k)) for k in keys) for r in listed)
            last = sorted(tuple(str(r.get(k)) for k in keys) for r in final_inventory)
            if first != last:
                self.errors.append(
                    {
                        "endpoint": f"repos/{repository}/actions/runs",
                        "error": "run_inventory_changed",
                    }
                )
        return {
            "schemaVersion": 1,
            "scope": {
                "hostname": self.hostname,
                "principal": {k: identity.get(k) for k in ("id", "login", "type")}
                if isinstance(identity, dict)
                else None,
                "repositories": repositories,
                "organization": organization,
                "repositoryCoverage": "accessible repositories only; token visibility may omit repositories",
                "createdFrom": since,
                "createdThrough": until,
                "expectedHeads": heads,
                "limitations": [
                    "Non-atomic cohort of runs CREATED in this window; older active runs may be absent.",
                    "Runner IDs establish assignment records, not runner-pool type or executor-ready backlog.",
                    "Workflow definitions, dependency DAGs, approvals and effective capacity require separate evidence.",
                ],
            },
            "startedAt": started,
            "completedAt": now(),
            "complete": not self.errors,
            "runs": runs,
            "reads": self.reads,
            "errors": self.errors,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--hostname",
        default="github.com",
        help="Explicit GitHub API host (default github.com)",
    )
    scope = parser.add_mutually_exclusive_group(required=True)
    scope.add_argument(
        "--repo", action="append", default=[], help="OWNER/REPO (repeatable)"
    )
    scope.add_argument("--org", help="Enumerate all repositories visible to this token")
    parser.add_argument(
        "--since", required=True, help="UTC ISO 8601 run creation window start"
    )
    parser.add_argument(
        "--until", required=True, help="UTC ISO 8601 run creation window end"
    )
    parser.add_argument(
        "--head",
        action="append",
        default=[],
        help="OWNER/REPO=SHA; classify, never discard old runs",
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", args.hostname):
        parser.error("--hostname must be a DNS hostname")
    repository_pattern = r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"
    if any(not re.fullmatch(repository_pattern, r) for r in args.repo):
        parser.error("--repo must be OWNER/REPO")
    if args.org and not re.fullmatch(r"[A-Za-z0-9_-]+", args.org):
        parser.error("invalid --org")
    heads = {}
    for value in args.head:
        match = re.fullmatch(f"({repository_pattern})=([a-fA-F0-9]{{40}})", value)
        if not match:
            parser.error("--head must be OWNER/REPO=40_HEX_SHA")
        heads[match[1]] = match[2].lower()
    try:
        start = datetime.fromisoformat(args.since)
        end = datetime.fromisoformat(args.until)
        if start.utcoffset() is None or end.utcoffset() is None or start > end:
            raise ValueError
    except ValueError:
        parser.error("window must contain ordered ISO 8601 timestamps with timezones")
    result = Collector(hostname=args.hostname).collect(
        args.repo, args.org, args.since, args.until, heads
    )
    print(json.dumps(result, indent=2))
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    sys.exit(main())
