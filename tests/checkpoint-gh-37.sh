#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# tests/checkpoint-gh-37.sh — behavioural tests for checkpoint GH-37 in
# skills/github-project/checkpoints.yaml (the Renovate config extends the
# organisation's renovate-config preset).
#
# The script body is read out of checkpoints.yaml, never retyped here, so a
# change to the checkpoint is what these cases test. Each case builds a
# throwaway directory with the given Renovate config files, runs the body
# inside it with bash, and compares the exit code: 0 = pass, 1 = fail.
# Requires bash and awk.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKPOINTS="$(cd "$HERE/.." && pwd)/skills/github-project/checkpoints.yaml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
count=0

# Body of the `command: |` block of one checkpoint id, de-indented by the six
# spaces every body line carries in checkpoints.yaml.
block_body() {
    awk -v want="$1" '
        /^  - id:/ { id = $3; inblock = 0; next }
        id != want { next }
        /^    (pattern|command):[[:space:]]*\|[-+]?[[:space:]]*$/ { inblock = 1; next }
        inblock && /^      / { sub(/^      /, ""); print; next }
        inblock && /^[[:space:]]*$/ { print ""; next }
        inblock { inblock = 0 }
    ' "$CHECKPOINTS"
}

BODY="$(block_body GH-37)"
if [ -z "$BODY" ]; then
    echo "FAIL: no command body found for GH-37 in $CHECKPOINTS"
    exit 1
fi

# check <name> <expected exit> [<file> <content>]... — writes the files into a
# fresh directory and runs the checkpoint body there.
check() {
    local name="$1" want="$2"
    shift 2
    local dir="$WORK/case$count"
    mkdir -p "$dir"
    while [ "$#" -ge 2 ]; do
        mkdir -p "$dir/$(dirname "$1")"
        printf '%s\n' "$2" > "$dir/$1"
        shift 2
    done
    local got
    (cd "$dir" && bash -c "$BODY" >/dev/null 2>&1)
    got=$?
    count=$((count + 1))
    if [ "$got" = "$want" ]; then
        echo "  ok   $name (exit $got)"
    else
        echo "  FAIL $name: want exit $want, got $got"
        fail=1
    fi
}

echo "GH-37: Renovate config extends the organisation preset"

# --- passing ---------------------------------------------------------------
check "github> preset in renovate.json" 0 \
    renovate.json '{"extends": ["github>netresearch/renovate-config"]}'
check "local> preset with :preset, JSON5 single quotes" 0 \
    .github/renovate.json5 "{ extends: ['config:recommended', 'local>netresearch/renovate-config:pinning'] }"
check "preset with #ref after a comment, multi-line JSONC" 0 \
    renovate.jsonc '{
  // org defaults
  "extends": [
    "github>acme/renovate-config#v2"
  ]
}'
check "no Renovate config at all" 0 \
    README.md '# no bot'

# --- failing ---------------------------------------------------------------
check "only config:recommended" 1 \
    renovate.json '{"extends": ["config:recommended"]}'
check "preset only inside a // comment" 1 \
    renovate.jsonc '{
  // "extends": ["github>netresearch/renovate-config"]
  "extends": ["config:recommended"]
}'
check "preset only as a description value" 1 \
    renovate.json '{"description": "github>netresearch/renovate-config", "extends": ["config:recommended"]}'
check "preset named in ignorePresets, not in extends" 1 \
    renovate.json '{"extends": ["config:recommended"], "ignorePresets": ["github>netresearch/renovate-config"]}'
check "no extends key" 1 \
    renovate.json '{"packageRules": []}'
check "look-alike repository names" 1 \
    renovate.json '{"extends": ["github>netresearch/renovate-config-old", "github>netresearch/my-renovate-config"]}'
check "first config file decides (root renovate.json before .github/)" 1 \
    renovate.json '{"extends": ["config:recommended"]}' \
    .github/renovate.json '{"extends": ["github>netresearch/renovate-config"]}'

echo "---- $count cases, failures: $fail"
exit "$fail"
