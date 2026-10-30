#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# /// script
# requires-python = ">=3.11"
# ///
"""Collect a read-only, non-atomic Actions cohort; never infer executor readiness.

Run with Python 3.11+ and authenticated gh. Only GET requests are issued.
Successful response bodies and read timestamps are retained in the JSON output.
Failed reads retain endpoint, timestamps and a redacted error class, without
subprocess arguments, stderr or credentials.
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


REVISION_KEYS = ("id", "head_sha", "run_attempt", "updated_at", "status", "conclusion")


def valid_revision(record):
    return (
        isinstance(record.get("head_sha"), str)
        and re.fullmatch(r"[a-fA-F0-9]{40}", record["head_sha"])
        and timestamp(record.get("updated_at"))
        and isinstance(record.get("status"), str)
        and bool(record["status"])
        and "conclusion" in record
        and (record["conclusion"] is None or isinstance(record["conclusion"], str))
    )


def valid_runner(runner):
    return runner is None or (
        isinstance(runner, int) and not isinstance(runner, bool) and runner >= 0
    )


def same_revision(before, after):
    return isinstance(after, dict) and all(
        type(before.get(k)) is type(after.get(k)) and before.get(k) == after.get(k)
        for k in REVISION_KEYS
    )


def inventory_revision(records):
    return sorted(tuple(str(r.get(k)) for k in REVISION_KEYS) for r in records)


def head_selection(head, expected_head):
    if expected_head is None:
        return "unspecified"
    if head == expected_head:
        return "current"
    return "obsolete"


def repository_identity(records):
    return sorted((r["id"], r.get("full_name")) for r in records)


def unique_repositories(repositories):
    identities = {}
    for repository in repositories:
        identities.setdefault(repository.casefold(), repository)
    return sorted(identities.values(), key=str.casefold)


def latest_records(jobs):
    statuses = {}
    for job in jobs:
        status = job.get("status") if isinstance(job.get("status"), str) else "unknown"
        statuses[status] = statuses.get(status, 0) + 1
    return {
        "jobs": len(jobs),
        "assigned": sum(positive_integer(j.get("runner_id")) for j in jobs),
        "statuses": statuses,
    }


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

    def collection_page(self, path, body, key):
        if key is None:
            items, count = body, None
        elif isinstance(body, dict):
            items, count = body.get(key), body.get("total_count")
        else:
            items, count = None, None
        invalid_count = key and (
            not isinstance(count, int) or isinstance(count, bool) or count < 0
        )
        if not isinstance(items, list) or invalid_count:
            self.errors.append({"endpoint": path, "error": "invalid_collection"})
            return None
        return items, count

    def admit_page(self, path, count, previous_total, capped):
        if previous_total is not None and count != previous_total:
            self.errors.append({"endpoint": path, "error": "collection_changed"})
        if capped and count >= 1000:
            self.errors.append({"endpoint": path, "error": "search_cap_split_window"})
            return False
        return True

    def append_records(self, path, items, records, seen):
        for item in items:
            identity = item.get("id") if isinstance(item, dict) else None
            if not positive_integer(identity) or identity in seen:
                self.errors.append(
                    {"endpoint": path, "error": "duplicate_or_invalid_id"}
                )
                return False
            seen.add(identity)
            records.append(item)
        return True

    def final_count(self, path, records, count):
        if count is not None and len(records) != count:
            self.errors.append({"endpoint": path, "error": "incomplete_collection"})

    def pages(self, path, key=None, query=None, capped=False):
        records, seen, total = [], set(), None
        for page in range(1, 1001):
            query_string = urlencode({**(query or {}), "per_page": 100, "page": page})
            body = self.get(f"{path}?{query_string}")
            if body is None:
                return records
            parsed = self.collection_page(path, body, key)
            if parsed is None:
                return records
            items, count = parsed
            if not self.admit_page(path, count, total, capped):
                return records
            total = count
            if not self.append_records(path, items, records, seen):
                return records
            if len(items) < 100:
                self.final_count(path, records, count)
                return records
        self.errors.append({"endpoint": path, "error": "pagination_bound"})
        return records

    def valid_run(self, path, record, listed):
        if (
            not isinstance(record, dict)
            or not positive_integer(record.get("id"))
            or record.get("id") != listed["id"]
        ):
            self.errors.append({"endpoint": path, "error": "invalid_run"})
            return False
        if not valid_revision(record):
            self.errors.append({"endpoint": path, "error": "invalid_run_revision"})
            return False
        number = record.get("run_attempt")
        if not positive_integer(number) or number > 51:
            self.errors.append({"endpoint": path, "error": "invalid_attempt"})
            return False
        return True

    def validate_job(self, path, job, run_id, attempt):
        if not positive_integer(job.get("run_id")) or job.get("run_id") != run_id:
            self.errors.append({"endpoint": path, "error": "job_run_mismatch"})
        if (
            not valid_runner(job.get("runner_id"))
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

    def run_attempts(self, path, record):
        attempts = []
        for attempt in range(1, record["run_attempt"] + 1):
            jobs = self.pages(f"{path}/attempts/{attempt}/jobs", "jobs")
            for job in jobs:
                self.validate_job(path, job, record["id"], attempt)
            attempts.append({"attempt": attempt, "jobs": jobs})
        return attempts

    def run(self, repository, listed, expected_head):
        path = f"repos/{repository}/actions/runs/{listed['id']}"
        before = self.get(path)
        if before is None or not self.valid_run(path, before, listed):
            return None
        attempts = self.run_attempts(path, before)
        stable = same_revision(before, self.get(path))
        if not stable:
            self.errors.append({"endpoint": path, "error": "run_changed_during_read"})
        return {
            "repository": repository,
            "run": before,
            "stableDuringRead": stable,
            "headSelection": head_selection(before.get("head_sha"), expected_head),
            "attempts": attempts,
            "latestAttemptRecords": latest_records(attempts[-1]["jobs"]),
            "executorReadiness": "unknown: API job status/timestamps do not expose needs or approvals",
            "attemptAccounting": "Carried jobs can have new IDs with old execution times; do not sum attempts as executions.",
        }

    def principal(self):
        identity = self.get("user")
        if (
            not isinstance(identity, dict)
            or not positive_integer(identity.get("id"))
            or not isinstance(identity.get("login"), str)
            or not identity["login"].strip()
        ):
            self.errors.append({"endpoint": "user", "error": "unverified_principal"})
        if isinstance(identity, dict):
            return {k: identity.get(k) for k in ("id", "login", "type")}
        return None

    def organization_repositories(self, organization):
        path = f"orgs/{organization}/repos"
        inventory = self.pages(path)
        repositories = []
        for repository in inventory:
            full_name = repository.get("full_name")
            if not isinstance(full_name, str) or not re.fullmatch(
                r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", full_name
            ):
                self.errors.append({"endpoint": path, "error": "invalid_repository"})
                continue
            repositories.append(full_name)
        return inventory, repositories

    def verify_repository_inventory(self, organization, inventory):
        path = f"orgs/{organization}/repos"
        final_inventory = self.pages(path)
        if repository_identity(inventory) != repository_identity(final_inventory):
            self.errors.append(
                {"endpoint": path, "error": "repository_inventory_changed"}
            )

    def repository_runs(self, repository, since, until, expected_head):
        path = f"repos/{repository}/actions/runs"
        query = {"created": f"{since}..{until}"}
        listed = self.pages(path, "workflow_runs", query, capped=True)
        runs = []
        for item in listed:
            result = self.run(repository, item, expected_head)
            if result:
                runs.append(result)
        final_inventory = self.pages(path, "workflow_runs", query, capped=True)
        if inventory_revision(listed) != inventory_revision(final_inventory):
            self.errors.append({"endpoint": path, "error": "run_inventory_changed"})
        return runs

    def collect(self, repositories, organization, since, until, heads):
        started = now()
        principal = self.principal()
        inventory = []
        if organization:
            inventory, repositories = self.organization_repositories(organization)
        repositories = unique_repositories(repositories)
        selected_heads = {name.casefold(): head for name, head in heads.items()}
        runs = []
        for repository in repositories:
            runs.extend(
                self.repository_runs(
                    repository, since, until, selected_heads.get(repository.casefold())
                )
            )
        if organization:
            self.verify_repository_inventory(organization, inventory)
        return {
            "schemaVersion": 1,
            "scope": {
                "hostname": self.hostname,
                "principal": principal,
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
