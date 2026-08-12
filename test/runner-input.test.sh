#!/usr/bin/env bash
set -u

# A consumer's runner choice is one JSON value per reusable workflow (#383):
# a scalar selects any hosted label, while an array selects the complete
# self-hosted label set. Pin both shapes in the workflow contract so a future
# cleanup cannot narrow the input back to a scalar-only runs-on value.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"

LABELS="$ROOT/.github/workflows/labels.yml"
SWEEP="$ROOT/.github/workflows/labels-sweep.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
CONSUMERS="$ROOT/docs/CONSUMERS.md"

runner_contract() { # $1 = reusable workflow
  awk '
    /^      runner:$/ { in_runner = 1; next }
    in_runner && /^      [a-zA-Z0-9_-]+:$/ { exit }
    in_runner && /^        (type: string|required: false|default: '\''"ubuntu-latest"'\'')$/ { print }
  ' "$1"
}

count_fixed() { # $1 = literal, $2 = file
  grep -cF "$1" "$2"
}

for workflow in "$LABELS" "$SWEEP" "$RELEASE"; do
  check "$(basename "$workflow") declares the JSON runner contract" 0 \
    $'type: string\n        required: false\n        default: '\''"ubuntu-latest"'\''' \
    runner_contract "$workflow"
  check "$(basename "$workflow") has no hardcoded hosted seat" 1 "" \
    grep -F 'runs-on: ubuntu-latest' "$workflow"
done

# shellcheck disable=SC2016 # the GitHub expression is asserted literally
check "labels routes both jobs through the runner input" 0 "2" \
  count_fixed 'runs-on: ${{ fromJSON(inputs.runner) }}' "$LABELS"
# shellcheck disable=SC2016 # the GitHub expression is asserted literally
check "labels-sweep routes reconcile through the runner input" 0 "1" \
  count_fixed 'runs-on: ${{ fromJSON(inputs.runner) }}' "$SWEEP"
# shellcheck disable=SC2016 # the GitHub expression is asserted literally
check "release routes both doors through the runner input" 0 "2" \
  count_fixed 'runs-on: ${{ fromJSON(inputs.runner) }}' "$RELEASE"

# The local callers intentionally pass nothing: they exercise the unchanged
# default route on ceremony's GitHub-hosted runner (#383 decision 6).
for caller in self-labels.yml self-labels-sweep.yml self-release.yml; do
  check "$caller does not override runner" 1 "" \
    grep -E '^[[:space:]]+runner:' "$ROOT/.github/workflows/$caller"
done

check "each caller stub shows the hosted JSON form" 0 "3" \
  count_fixed "runner: '\"ubuntu-22.04\"'" "$CONSUMERS"
check "each caller stub shows the multi-label JSON form" 0 "3" \
  count_fixed "runner: '[\"self-hosted\",\"ci-runner\"]'" "$CONSUMERS"
check "consumer doctrine carries the exact runner isolation requirement" 0 \
  "Route these to a runner isolated from anything the token should not reach — never to a host that is itself part of the deploy path." \
  grep -F "Route these to a runner isolated from anything the token should not reach — never to a host that is itself part of the deploy path." \
  "$CONSUMERS"
check "consumer doctrine warns that persistent runners retain state" 0 \
  "Self-hosted runners do **not** reset state between jobs unless run ephemerally" \
  grep -F "Self-hosted runners do **not** reset state between jobs unless run ephemerally" \
  "$CONSUMERS"
check "consumer doctrine explains single-job runner concurrency" 0 \
  "one runner executes one job at a time" \
  grep -F "one runner executes one job at a time" "$CONSUMERS"
check "event caller preserves its existing with mapping" 0 \
  'existing `with:` key (alongside `sweep_workflow` when present); do not repeat the key' \
  grep -F 'existing `with:` key (alongside `sweep_workflow` when present); do not repeat the key' \
  "$CONSUMERS"
check "sweep caller preserves its existing with mapping" 0 \
  'key (alongside `pr_workflow_name` when present); do not repeat the key' \
  grep -F 'key (alongside `pr_workflow_name` when present); do not repeat the key' \
  "$CONSUMERS"

summary
