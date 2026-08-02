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

# -- per-author panel rows (#224): the config-parse matrix -------------------
# required_for loads a conf fresh in a subshell and prints the required set
# behind a RESULT: anchor, so substring matching cannot confuse "b c" with
# "a b c".
# shellcheck disable=SC2016 # expansion belongs to the nested bash
required_for() { # $1 = conf, $2 = author → RESULT:<required set>
  bash -c 'source "$1"; load_config "$2" || exit 1
    set_required_bots "$3"; printf "RESULT:%s\n" "${REQUIRED_BOTS[*]}"' _ \
    "$ROOT/actions/labels-reconcile/labels-reconcile.sh" "$1" "$2"
}
printf '%s\n' 'panel=a b c' >"$TMP/plain.conf"
check "no bracketed row: panelist author gets panel minus self" 0 "RESULT:b c" \
  required_for "$TMP/plain.conf" a
check "no bracketed row: outside author gets the whole panel" 0 "RESULT:a b c" \
  required_for "$TMP/plain.conf" z
printf '%s\n' 'panel=a b c' 'panel[z]=b c' >"$TMP/author.conf"
check "bracketed author gets exactly its row" 0 "RESULT:b c" \
  required_for "$TMP/author.conf" z
check "unbracketed author beside a bracketed row is unchanged" 0 "RESULT:b c" \
  required_for "$TMP/author.conf" a
printf '%s\n' 'panel[z]=b c' 'panel=a b c' >"$TMP/reversed.conf"
check "row order is irrelevant: bracketed row before panel=" 0 "RESULT:b c" \
  required_for "$TMP/reversed.conf" z
check "row order is irrelevant for the base panel too" 0 "RESULT:b c" \
  required_for "$TMP/reversed.conf" a
printf '%s\n' 'panel=a b c' 'panel[a]=a b' >"$TMP/self.conf"
check "author inside its own bracketed row is still recused" 0 "RESULT:b" \
  required_for "$TMP/self.conf" a
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "base panel is byte-identical with the bracketed rows deleted" 0 "SAME" \
  bash -c 'source "$1"; load_config "$2"; with="${BOTS[*]}"
    load_config "$3"; [ "$with" = "${BOTS[*]}" ] && echo SAME' _ \
  "$ROOT/actions/labels-reconcile/labels-reconcile.sh" \
  "$TMP/author.conf" "$TMP/plain.conf"
printf '%s\n' 'panel=a b c' 'panel[z]=b' 'panel[z]=c' >"$TMP/dup-author.conf"
check "duplicate rows for one login fail naming the line" 1 \
  "duplicate panel[z]= row" load_config "$TMP/dup-author.conf"
printf '%s\n' 'panel=a b c' 'panel[z]=' >"$TMP/empty-set.conf"
check "a bracketed row naming zero reviewers fails loudly" 1 \
  "panel[z]= must name at least one reviewer" load_config "$TMP/empty-set.conf"
printf '%s\n' 'panel=a b c' 'panel[]=b c' >"$TMP/empty-login.conf"
check "an empty login fails loudly" 1 "empty login in panel row" \
  load_config "$TMP/empty-login.conf"
printf '%s\n' 'panel=a b c' 'panel[z=b c' >"$TMP/broken-bracket.conf"
check "a malformed bracket is refused as a bracket (D4)" 1 \
  "malformed panel[<login>]= row" load_config "$TMP/broken-bracket.conf"
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "...and never as a label row" 1 "" bash -c \
  'source "$1"; load_config "$2" 2>&1 | grep -F "malformed label row"' _ \
  "$ROOT/actions/labels-reconcile/labels-reconcile.sh" "$TMP/broken-bracket.conf"
# The D7 tripwire: in a case pattern an unquoted panel[abc]=* is a bracket
# expression matching panela=… — this row going green as a panel setting is
# exactly the silent mis-route the quoted prefix exists to prevent.
printf '%s\n' 'panel=a b c' 'panela=b c' >"$TMP/glob-guard.conf"
check "panela= is still a malformed label row, never a panel setting (D7)" 1 \
  "malformed label row" load_config "$TMP/glob-guard.conf"
printf '%s\n' 'panel[z]=b c' >"$TMP/bracket-only.conf"
check "a bracketed row does not satisfy the mandatory panel=" 1 \
  "missing panel= line" load_config "$TMP/bracket-only.conf"
printf '%s\n' 'panel=a b c' 'panel[z]=b c' \
  'scope:one|C5DEF5|First scope' >"$TMP/mixed.conf"
check "configured_label_rows returns the scope rows alone" 0 \
  "scope:one|C5DEF5|First scope" configured_label_rows "$TMP/mixed.conf"
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "no panel[...] row reaches the bootstrap" 1 "" bash -c \
  'source "$1"; configured_label_rows "$2" | grep -F "panel["' _ \
  "$ROOT/actions/labels-reconcile/labels-reconcile.sh" "$TMP/mixed.conf"

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
