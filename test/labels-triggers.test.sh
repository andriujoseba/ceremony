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
SWEEP="$ROOT/.github/workflows/labels-sweep.yml"
SELF="$ROOT/.github/workflows/self-labels.yml"
SELF_SWEEP="$ROOT/.github/workflows/self-labels-sweep.yml"
STUB="$ROOT/docs/CONSUMERS.md" # the published caller stubs, fenced yaml blocks

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
# trading correctness for minutes — so it stays false, forever. The job lives
# in labels-sweep.yml since #209; the guard moved with it.
check "reconcile serializes, never cancels mid-board" 0 "false" \
  job_cancel_in_progress "$SWEEP" reconcile
# shellcheck disable=SC2016 # the awk program runs in the nested bash, not here
check "reconcile is never cancel-in-progress: true" 1 "" \
  bash -c 'job_cancel_in_progress() {
    awk -v job="^  reconcile:\$" "\$0 ~ job{f=1;next} f&&/^  [a-z]/{exit} f&&/cancel-in-progress:/{sub(/.*cancel-in-progress:[[:space:]]*/,\"\");print;exit}" "$1"
  }; [ "$(job_cancel_in_progress "$1")" = true ]' _ "$SWEEP"
# scope MAY cancel — it is per-PR and additive, so a superseded run is waste,
# not a lost sweep. This asserts the must-fail above is scoped to reconcile.
check "scope stays cancel-in-progress: true (per-PR, additive)" 0 "true" \
  job_cancel_in_progress "$REUSABLE" scope

# ---- the sweep is detached from PR-triggered runs (#209) ---------------------
# While reconcile rode the PR-event run, every displacement in its shared
# queue recorded a CANCELLED check on some PR — fake red CI. The reusable
# labels.yml must never grow the job back; its trigger job wakes the sweep
# caller by dispatch instead, and that dispatch is the misconfiguration
# alarm: a pin bumped without the sweep caller must go loudly red at the
# trigger, so the dispatch line is never allowed to silence itself.
check "labels.yml carries no reconcile job" 1 "" \
  grep -E '^  reconcile:' "$REUSABLE"
check "labels-sweep.yml carries the reconcile job" 0 "  reconcile:" \
  grep -E '^  reconcile:' "$SWEEP"
check "the sweep keeps the ONE shared concurrency group" 0 "group: labels-reconcile" \
  grep -F 'group: labels-reconcile' "$SWEEP"
check "labels.yml carries the trigger job" 0 "  trigger:" \
  grep -E '^  trigger:' "$REUSABLE"
# shellcheck disable=SC2016 # $SWEEP_WORKFLOW is the workflow's own env var, asserted literally
check "the trigger dispatches the sweep caller, never bootstrapping" 0 \
  'gh workflow run "$SWEEP_WORKFLOW" -R "$GITHUB_REPOSITORY" -f bootstrap=no' \
  grep -F 'gh workflow run' "$REUSABLE"
# shellcheck disable=SC2016 # $1 expands in the nested bash, not here
check "the trigger dispatch is never silenced with || true" 1 "" \
  bash -c 'grep -F "gh workflow run" "$1" | grep -qF "|| true"' _ "$REUSABLE"
check "the sweep caller filename input defaults to labels-sweep.yml" 0 \
  "default: labels-sweep.yml" grep -F 'default: labels-sweep.yml' "$REUSABLE"
# the dogfood callers wear the split: the event caller names its deviant
# sweep filename, and the sweep caller declares the bootstrap input the
# trigger's -f flag requires (an undeclared input reds every dispatch)
check "self caller passes its dogfood sweep filename" 0 \
  "sweep_workflow: self-labels-sweep.yml" \
  grep -F 'sweep_workflow: self-labels-sweep.yml' "$SELF"
check "self sweep caller declares the bootstrap dispatch input" 0 \
  "bootstrap:" grep -E '^      bootstrap:' "$SELF_SWEEP"
check "stub sweep caller declares the bootstrap dispatch input" 0 \
  "bootstrap:" grep -E '^      bootstrap:' "$STUB"
# the labels caller's event runs must not carry the sweep's cron or manual
# dispatch — those relocated to the sweep caller with #209
check "self caller carries no cron" 1 "" grep -F 'cron:' "$SELF"
check "self caller carries no workflow_dispatch" 1 "" \
  grep -E '^  workflow_dispatch:' "$SELF"

# ---- the cron is a backstop, relaxed to hourly (#199 candidate 1) -----------
# Scope the */15 assertion to the cron LINE — the prose comments cite */15 by
# name to explain the change, and must not re-red their own documentation.
# The cron rides the sweep caller since #209.
check "self sweep caller cron is hourly" 0 '0 * * * *' grep -F 'cron:' "$SELF_SWEEP"
# shellcheck disable=SC2016 # $1 expands in the nested bash, not here
check "self sweep caller cron line no longer fires */15" 1 "" \
  bash -c 'grep -F "cron:" "$1" | grep -qF "*/15"' _ "$SELF_SWEEP"
check "stub cron is hourly" 0 '0 * * * *' grep -F 'cron:' "$STUB"
# shellcheck disable=SC2016 # $1 expands in the nested bash, not here
check "stub cron line no longer fires */15" 1 "" \
  bash -c 'grep -F "cron:" "$1" | grep -qF "*/15"' _ "$STUB"

# ---- issues: is narrowed to the queue-state-changing actions (#199) ----------
# Kept because each carries a queue-state change an event uniquely carries, so
# dropping it would trip #199's must-fail (a transition waiting on the schedule
# when an event could have carried it): opened → mint→needs-triage; closed →
# blocker-closes→ready self-heal; edited → a body rewrite of the `Blocked by #N`
# declaration the sweep parses; reopened → a closed issue re-entering the queue.
# (labels.test.sh owns the exact-list and caller<->stub parity assertions.)
for keep in opened closed edited reopened; do
  # shellcheck disable=SC2016 # the awk program runs in the nested bash, not here
  check "self caller issues surface keeps '$keep'" 0 "" \
    bash -c 'trigger_types() {
      awk -v key="^  issues:\$" "\$0 ~ key{f=1;next} f&&/^    types:/{sub(/^    types:[[:space:]]*/,\"\");print;exit} f&&/^  [a-z]/{exit}" "$1"
    }; trigger_types "$1" | grep -qw "$2"' _ "$SELF" "$keep"
done
# The churn actions must not reappear on the issues surface without a fresh why.
# labeled/unlabeled were the dominant issues-churn source; assigned/unassigned
# only feed validation and the 48h claim clock, caught within one cadence.
for churn in labeled unlabeled assigned unassigned; do
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
