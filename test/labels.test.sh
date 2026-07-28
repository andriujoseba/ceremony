#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=actions/labels-reconcile/labels-reconcile.sh
source "$ROOT/actions/labels-reconcile/labels-reconcile.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' \
  'panel=one two three' \
  'triage-actors=triage-one' \
  '' \
  'scope:one|C5DEF5|First scope' \
  'scope:two|C5DEF5|Second scope' >"$TMP/good.conf"

check "config accepts panel, blanks, and scope rows" 0 "" load_config "$TMP/good.conf"
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "panel is parsed" 0 "one two three" bash -c \
  'source "$1"; load_config "$2"; printf "%s\n" "${BOTS[*]}"' _ \
  "$ROOT/actions/labels-reconcile/labels-reconcile.sh" "$TMP/good.conf"
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "core and config rows merge" 0 "scope:two|C5DEF5|Second scope" bash -c \
  'source "$1"; core_label_rows; configured_label_rows "$2"' _ \
  "$ROOT/actions/labels-reconcile/labels-reconcile.sh" "$TMP/good.conf"
attention_row='attention|D93F0B|A demand is parked here for the assignee: pick up the thread, ack by removing this label'
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "attention core row is emitted once, byte-exact" 0 "1" bash -c \
  'source "$1"; core_label_rows | grep -cxF "$2"' _ \
  "$ROOT/actions/labels-reconcile/labels-reconcile.sh" "$attention_row"
# shellcheck disable=SC2016 # fields are intentionally split in the nested shell
check "attention description survives label field splitting" 0 \
  "A demand is parked here for the assignee: pick up the thread, ack by removing this label" \
  bash -c 'source "$1"; while IFS="|" read -r name color desc; do
    [ "$name" != attention ] || printf "%s\n" "$desc"
  done < <(core_label_rows)' _ "$ROOT/actions/labels-reconcile/labels-reconcile.sh"
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "triage config is not parsed as a label row" 1 "" bash -c \
  'source "$1"; configured_label_rows "$2" | grep -F triage-actors' _ \
  "$ROOT/actions/labels-reconcile/labels-reconcile.sh" "$TMP/good.conf"
check "missing scope config is an empty table" 0 "" configured_label_rows "$TMP/missing.conf"

printf '%s\n' 'scope:bad|C5DEF5' >"$TMP/bad.conf"
check "wrong field count fails loudly" 1 "malformed label row" configured_label_rows "$TMP/bad.conf"
printf '%s\n' 'scope:bad|C5DEF5|description|with pipe' >"$TMP/pipe.conf"
check "pipe in description is explicitly refused" 1 "malformed label row" configured_label_rows "$TMP/pipe.conf"
printf '%s\n' 'scope:only|C5DEF5|No panel' >"$TMP/no-panel.conf"
check "missing panel fails loudly" 1 "missing panel= line" load_config "$TMP/no-panel.conf"
load_config "$TMP/good.conf"
set_required_bots two
check "PR author is recused from the required panel" 0 "one three" printf '%s\n' "${REQUIRED_BOTS[*]}"

# LABELS.md is mirrored byte-identically into every governed repo, so any
# scope enumeration it carries is true at home and false everywhere else —
# 14 of 16 vendored rows were false across the family when this fired (#104).
# The set lives in labels.conf and the repo's CONTRIBUTING; the mirror never
# names it. A concrete label is `scope:` followed by a name character — the
# doctrine spellings (bare `scope:`, wildcard `scope:*`) put a backtick or `*`
# there instead, so any name, current or future, in any shape (table row,
# name|color|description row, prose) re-reds this while doctrine stays green.
# grep -c prints the count and exits 1 when that count is 0.
check "LABELS.md enumerates no repo's scope labels" 1 "0" \
  grep -c 'scope:[a-z0-9]' "$ROOT/LABELS.md"

# The caller's trigger type lists and the CONSUMERS.md stub's must be the
# same lists. review_requested/review_request_removed are the wake that
# clears blocker:unrequested — the label sat false for as long as a quiet
# repo stayed quiet because the one event that falsifies it was never
# listed (#137). The issues list narrowed to [opened, closed, edited, reopened]
# (#199): each carries a queue-state change the hourly cron cannot wait one
# cadence for — opened drives mint→needs-triage, closed the blocker-closes→ready
# self-heal, edited a body rewrite of the `Blocked by #N` line the sweep parses,
# reopened a closed issue re-entering the queue — while the churn/validation
# actions (labeled/unlabeled/assigned/unassigned) came off. The stub is prose, so nothing but these rows
# keeps the lists from drifting: a type in one file only is a wake that fires
# at home and nowhere in the fleet, or the reverse — the drift #144 caught.
# The NF guard keeps `issues: write` under permissions: from matching the
# issues: trigger key.
event_types() { # $1 = file, $2 = trigger key → that trigger's types line, unindented
  awk -v key="$2:" '$1 == key && NF == 1 {f=1; next} f && /types: /{sub(/^ */,""); print; exit}' "$1"
}
types_in_sync() { # $1 = trigger key, $2 = caller, $3 = stub → 0 when both lists exist and match
  local a b
  a="$(event_types "$2" "$1")" b="$(event_types "$3" "$1")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}
CALLER="$ROOT/.github/workflows/self-labels.yml"
STUB="$ROOT/docs/CONSUMERS.md"
# event_types anchors on the bare trigger key (NF == 1), so it reads the real
# types line even though the #199 comments name pull_request_target: and
# issues: in prose above the keys — an inline /pull_request_target:/ scan would
# latch onto the first mention and read the wrong list.
pr_has_both_review_wakes() {
  event_types "$CALLER" pull_request_target | grep -F review_requested | grep -qF review_request_removed
}
check "caller and stub pull_request_target lists are identical" 0 "" \
  types_in_sync pull_request_target "$CALLER" "$STUB"
check "the caller lists both review-request wakes" 0 "" pr_has_both_review_wakes
check "caller and stub issues lists are identical" 0 "" \
  types_in_sync issues "$CALLER" "$STUB"
check "the caller lists exactly the queue-state-changing issue types" 0 \
  "types: [opened, closed, edited, reopened]" event_types "$CALLER" issues
# the failing cases: drop a type from either file, or reorder one list only,
# and the identity rows above go red — exercised here on mutated copies
mut_caller="$TMP/mut-caller.yml" mut_stub="$TMP/mut-stub.md"
sed 's/, review_request_removed//' "$CALLER" >"$mut_caller"
check "a type dropped from the caller goes red" 1 "" \
  types_in_sync pull_request_target "$mut_caller" "$STUB"
sed 's/, review_request_removed//' "$STUB" >"$mut_stub"
check "a type dropped from the stub goes red" 1 "" \
  types_in_sync pull_request_target "$CALLER" "$mut_stub"
sed 's/review_requested, review_request_removed/review_request_removed, review_requested/' \
  "$STUB" >"$mut_stub"
check "a reorder in one list only goes red" 1 "" \
  types_in_sync pull_request_target "$CALLER" "$mut_stub"
sed 's/, closed//' "$CALLER" >"$mut_caller"
check "an issue type dropped from the caller goes red" 1 "" \
  types_in_sync issues "$mut_caller" "$STUB"
sed 's/, closed//' "$STUB" >"$mut_stub"
check "an issue type dropped from the stub goes red" 1 "" \
  types_in_sync issues "$CALLER" "$mut_stub"
sed 's/opened, closed/closed, opened/' "$STUB" >"$mut_stub"
check "an issue-list reorder in one file only goes red" 1 "" \
  types_in_sync issues "$CALLER" "$mut_stub"

summary
