#!/usr/bin/env bash
set -u

# The labels TRIGGER SURFACE is a cost lever (#199): a full-board sweep is
# billed a 1-minute minimum every time a trigger fires, so how OFTEN it fires
# is what exhausted the fleet's shared Actions allotment. These assertions
# pin the reductions #199 made and the guard it must not trade away — none of
# them touch the reconciler's LOGIC, which its own fixtures cover.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"

REUSABLE="$ROOT/.github/workflows/labels.yml"
SELF="$ROOT/.github/workflows/self-labels.yml"
STUB="$ROOT/docs/CONSUMERS.md" # the published caller stub, a fenced yaml block

# The `cancel-in-progress:` value of a named top-level job, read from the first
# such line inside that job's block. Job keys sit at two-space indent.
job_cancel_in_progress() { # $1 = file, $2 = job name
  awk -v job="^  $2:\$" '
    $0 ~ job { f = 1; next }
    f && /^  [a-z]/ { exit }             # next job — stop before leaking into it
    f && /cancel-in-progress:/ { sub(/.*cancel-in-progress:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

# The `types:` list of a trigger key (issues:, pull_request_target:), read from
# the first `types:` line after the bare key. The key is bare (nothing after
# the colon) so it never collides with `issues: write` in the permissions block.
trigger_types() { # $1 = file, $2 = trigger key
  awk -v key="^  $2:\$" '
    $0 ~ key { f = 1; next }
    f && /^    types:/ { sub(/^    types:[[:space:]]*/, ""); print; exit }
    f && /^  [a-z]/ { exit }
  ' "$1"
}

# ---- the guard the cost fix must never trade away (#199 test plan must-fail) --
# cancel-in-progress: true on reconcile kills a sweep mid-board, the exact race
# the shared concurrency group exists to prevent. It WOULD cut run count — by
# trading correctness for minutes — so it stays false, forever.
check "reconcile serializes, never cancels mid-board" 0 "false" \
  job_cancel_in_progress "$REUSABLE" reconcile
# shellcheck disable=SC2016 # the awk program runs in the nested bash, not here
check "reconcile is never cancel-in-progress: true" 1 "" \
  bash -c 'job_cancel_in_progress() {
    awk -v job="^  reconcile:\$" "\$0 ~ job{f=1;next} f&&/^  [a-z]/{exit} f&&/cancel-in-progress:/{sub(/.*cancel-in-progress:[[:space:]]*/,\"\");print;exit}" "$1"
  }; [ "$(job_cancel_in_progress "$1")" = true ]' _ "$REUSABLE"
# scope MAY cancel — it is per-PR and additive, so a superseded run is waste,
# not a lost sweep. This asserts the must-fail above is scoped to reconcile.
check "scope stays cancel-in-progress: true (per-PR, additive)" 0 "true" \
  job_cancel_in_progress "$REUSABLE" scope

# ---- the cron is a backstop, relaxed to hourly (#199 candidate 1) -----------
# Scope the */15 assertion to the cron LINE — the prose comments cite */15 by
# name to explain the change, and must not re-red their own documentation.
check "self caller cron is hourly" 0 '0 * * * *' grep -F 'cron:' "$SELF"
# shellcheck disable=SC2016 # $1 expands in the nested bash, not here
check "self caller cron line no longer fires */15" 1 "" \
  bash -c 'grep -F "cron:" "$1" | grep -qF "*/15"' _ "$SELF"
check "stub cron is hourly" 0 '0 * * * *' grep -F 'cron:' "$STUB"
# shellcheck disable=SC2016 # $1 expands in the nested bash, not here
check "stub cron line no longer fires */15" 1 "" \
  bash -c 'grep -F "cron:" "$1" | grep -qF "*/15"' _ "$STUB"

# ---- issues: is narrowed to the two promptness-critical actions (#199) -------
# opened → mint→needs-triage; closed → blocker-closes→ready self-heal. The
# churn actions must not reappear on the issues surface without a fresh why.
# (labels.test.sh owns the exact-list and caller<->stub parity assertions; here
# we name each dropped action so its return produces a #199-specific failure.)
for churn in labeled unlabeled assigned unassigned edited reopened; do
  # shellcheck disable=SC2016 # the awk program runs in the nested bash, not here
  check "self caller issues surface drops '$churn'" 1 "" \
    bash -c 'trigger_types() {
      awk -v key="^  issues:\$" "\$0 ~ key{f=1;next} f&&/^    types:/{sub(/^    types:[[:space:]]*/,\"\");print;exit} f&&/^  [a-z]/{exit}" "$1"
    }; trigger_types "$1" | grep -qw "$2"' _ "$SELF" "$churn"
done

# ---- the PR handoff wake is NOT collateral of the issues narrowing ----------
# The handoff (state:needs-human, confirmed by the caller's labeled event) rides
# pull_request_target, not issues. A future edit that strips it there re-reds.
check "pull_request_target keeps the labeled handoff wake" 0 "labeled" \
  trigger_types "$SELF" pull_request_target

summary
