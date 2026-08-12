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

runner_contract() { # $1 = reusable workflow
  awk '
    /^      runner:$/ { in_runner = 1; next }
    in_runner && /^      [a-zA-Z0-9_-]+:$/ { exit }
    in_runner && /^        (type: string|required: false|default: '\''"ubuntu-latest"'\'')$/ { print }
  ' "$1"
}

for workflow in "$LABELS" "$SWEEP" "$RELEASE"; do
  check "$(basename "$workflow") declares the JSON runner contract" 0 \
    $'type: string\n        required: false\n        default: '\''"ubuntu-latest"'\''' \
    runner_contract "$workflow"
  check "$(basename "$workflow") has no hardcoded hosted seat" 1 "" \
    grep -F 'runs-on: ubuntu-latest' "$workflow"
done

check "labels routes both jobs through the runner input" 0 "2" \
  bash -c 'grep -cF '\''runs-on: ${{ fromJSON(inputs.runner) }}'\'' "$1"' _ "$LABELS"
check "labels-sweep routes reconcile through the runner input" 0 "1" \
  bash -c 'grep -cF '\''runs-on: ${{ fromJSON(inputs.runner) }}'\'' "$1"' _ "$SWEEP"
check "release routes both doors through the runner input" 0 "2" \
  bash -c 'grep -cF '\''runs-on: ${{ fromJSON(inputs.runner) }}'\'' "$1"' _ "$RELEASE"

# The local callers intentionally pass nothing: they exercise the unchanged
# default route on ceremony's GitHub-hosted runner (#383 decision 6).
for caller in self-labels.yml self-labels-sweep.yml self-release.yml; do
  check "$caller does not override runner" 1 "" \
    grep -E '^[[:space:]]+runner:' "$ROOT/.github/workflows/$caller"
done

summary
