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
CI_RERUN="$ROOT/.github/workflows/ci-rerun.yml"
CONSUMERS="$ROOT/docs/CONSUMERS.md"

runner_field_count() { # $1 = reusable workflow, $2 = exact field
  awk -v expected="        $2" '
    /^      runner:$/ { in_runner = 1; next }
    in_runner && /^      [a-zA-Z0-9_-]+:$/ { exit }
    in_runner && $0 == expected { count++ }
    END { print count + 0 }
  ' "$1"
}

count_fixed() { # $1 = literal, $2 = file
  grep -cF "$1" "$2"
}

for workflow in "$LABELS" "$SWEEP" "$RELEASE" "$CI_RERUN"; do
  check "$(basename "$workflow") declares runner as a string" 0 "1" \
    runner_field_count "$workflow" "type: string"
  check "$(basename "$workflow") declares runner as optional" 0 "1" \
    runner_field_count "$workflow" "required: false"
  check "$(basename "$workflow") keeps the JSON-encoded hosted default" 0 "1" \
    runner_field_count "$workflow" "default: '\"ubuntu-latest\"'"
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
# shellcheck disable=SC2016 # the GitHub expression is asserted literally
check "ci-rerun routes its service job through the runner input" 0 "1" \
  count_fixed 'runs-on: ${{ fromJSON(inputs.runner) }}' "$CI_RERUN"

# The local callers intentionally pass nothing: they exercise the unchanged
# default route on ceremony's GitHub-hosted runner (#383 decision 6).
for caller in self-labels.yml self-labels-sweep.yml self-release.yml self-ci-rerun.yml; do
  check "$caller does not override runner" 1 "" \
    grep -E '^[[:space:]]+runner:' "$ROOT/.github/workflows/$caller"
done

check "each caller stub shows the hosted JSON form" 0 "4" \
  count_fixed "runner: '\"ubuntu-22.04\"'" "$CONSUMERS"
check "each caller stub shows the multi-label JSON form" 0 "4" \
  count_fixed "runner: '[\"self-hosted\",\"ci-runner\"]'" "$CONSUMERS"
check "consumer doctrine carries the exact runner isolation requirement" 0 \
  "Route these to a runner isolated from anything the token should not reach — never to a host that is itself part of the deploy path." \
  grep -F "Route these to a runner isolated from anything the token should not reach — never to a host that is itself part of the deploy path." \
  "$CONSUMERS"
check "consumer doctrine warns that persistent runners retain state" 0 \
  "Self-hosted runners do **not** reset state between jobs unless run ephemerally." \
  grep -F "Self-hosted runners do **not** reset state between jobs unless run ephemerally." \
  "$CONSUMERS"
# shellcheck disable=SC2016 # Markdown backticks are asserted literally
cleanup_note='scheduled `docker system prune`'
check "consumer doctrine requires cleanup for persistent runners" 0 \
  "$cleanup_note" grep -F "$cleanup_note" "$CONSUMERS"
check "consumer doctrine explains single-job runner concurrency" 0 \
  "One runner process executes one job at a" \
  grep -F "One runner process executes one job at a" "$CONSUMERS"
check "consumer doctrine permits several services on one host" 0 \
  "Several services on one" grep -F "Several services on one" "$CONSUMERS"
check "consumer doctrine requires repo-scoped runner registration" 0 \
  "Keep these runners repo-scoped unless the organization can restrict a runner" \
  grep -F "Keep these runners repo-scoped unless the organization can restrict a runner" \
  "$CONSUMERS"
check "consumer doctrine explains the free-plan Default group exposure" 0 \
  "Default group is available to every repository" \
  grep -F "Default group is available to every repository" "$CONSUMERS"
# The indirection gap narrowed in #395: the guard now reads a caller's `with:`
# value, so the disclosure has two halves and both are tripwires. Asserting only
# the half that remains would let a future change close or reopen the other half
# in silence.
# shellcheck disable=SC2016 # Markdown backticks are asserted literally
guard_reads="guard reads this \`runner\` input's **value**"
check "consumer doctrine says the guard reads the runner input's value" 0 \
  "$guard_reads" grep -F "$guard_reads" "$CONSUMERS"
# shellcheck disable=SC2016 # Markdown backticks are asserted literally
guard_gap="does not follow the reusable-workflow call into the callee's own \`runs-on:\`"
check "consumer doctrine discloses the indirection gap that remains" 0 \
  "$guard_gap" grep -F "$guard_gap" "$CONSUMERS"
# shellcheck disable=SC2016 # Markdown backticks are asserted literally
deploy_role='`deploy-box` is the sole guest with the Coolify/tailnet grant'
# shellcheck disable=SC2016 # Markdown backticks are asserted literally
ci_role='`ci-box` has no grants and'
check "consumer doctrine keeps deploy-box on the deploy plane" 0 \
  "$deploy_role" grep -F "$deploy_role" "$CONSUMERS"
check "consumer doctrine routes ceremony to the ungranted ci-box" 0 \
  "$ci_role" grep -F "$ci_role" "$CONSUMERS"
# shellcheck disable=SC2016 # Markdown backticks are asserted literally
event_with_note='existing `with:` key (alongside `sweep_workflow` when present); do not repeat the key'
# shellcheck disable=SC2016 # Markdown backticks are asserted literally
sweep_with_note='key (alongside `pr_workflow_name` when present); do not repeat the key'
check "event caller preserves its existing with mapping" 0 \
  "$event_with_note" grep -F "$event_with_note" \
  "$CONSUMERS"
check "sweep caller preserves its existing with mapping" 0 \
  "$sweep_with_note" grep -F "$sweep_with_note" \
  "$CONSUMERS"

summary
