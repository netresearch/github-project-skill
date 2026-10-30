#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
set -euo pipefail
PYTHONDONTWRITEBYTECODE=1 uv run "$(dirname "$0")/collect-runner-capacity.py"
