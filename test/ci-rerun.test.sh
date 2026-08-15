#!/usr/bin/env bash
# actions/ci-rerun's contract suite (#424). The gates and the parses are proved
# offline against a recording `gh` stub; the isolation and cadence properties
# are graded off the workflow YAML, which is how #424's own test plan grades
# them; and the live servicing is the end-to-end run recorded on the PR.
#
# File-wide, because the idiom is load-bearing here rather than incidental:
# shellcheck disable=SC2016 # a `bash -c` body's $1 belongs to that process
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=actions/ci-rerun/ci-rerun.sh
source "$ROOT/actions/ci-rerun/ci-rerun.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ACTION="$ROOT/actions/ci-rerun/ci-rerun.sh"
WORKFLOW="$ROOT/.github/workflows/ci-rerun.yml"
CALLER="$ROOT/.github/workflows/self-ci-rerun.yml"

# --- gate 1's roster: who may spend this credential ------------------------

printf '%s\n' \
  'panel=one-bot two-bot' \
  'triage-actors=triage-bot' \
  'scope:docs|C5DEF5|docs' >"$TMP/conf"

check "fleet: the panel, the triage actors and nothing invented" 0 "" \
  bash -c 'source "$1"; load_fleet "$2"
    [ "$(fleet_roster)" = "one-bot two-bot triage-bot" ] || { fleet_roster; exit 1; }' \
  _ "$ACTION" "$TMP/conf"

# #224's per-author rows name a builder on the left and its panel on the
# right. Both halves are fleet: a repo whose builders appear only there would
# otherwise refuse the identities it was configured for.
printf '%s\n' 'panel=one-bot' 'panel[builder-bot]=two-bot' 'triage-actors=triage-bot' \
  >"$TMP/bracketed.conf"
check "fleet: a panel[<login>]= row names its builder and its reviewers" 0 "" \
  bash -c 'source "$1"; load_fleet "$2"
    [ "$(fleet_roster)" = "one-bot builder-bot two-bot triage-bot" ] || { fleet_roster; exit 1; }' \
  _ "$ACTION" "$TMP/bracketed.conf"

# The whole authorization of this script is this list, so an unreadable conf
# refuses loudly rather than falling back to an empty set that reads as
# "nobody may" — or to a default roster nobody wrote down.
check "fleet: a missing conf is a hard failure, not an empty roster" 2 \
  "missing config" bash -c 'source "$1"; load_fleet "$2"' _ "$ACTION" "$TMP/nope.conf"
printf '%s\n' 'scope:docs|C5DEF5|docs' >"$TMP/rosterless.conf"
check "fleet: a conf naming no identity is a hard failure" 2 \
  "names no fleet identity" bash -c 'source "$1"; load_fleet "$2"' _ "$ACTION" "$TMP/rosterless.conf"

load_fleet "$TMP/conf"
check "fleet: a listed identity is fleet" 0 "" is_fleet_actor two-bot
check "fleet: an unlisted identity is not" 1 "" is_fleet_actor stranger
# The empty actor is the shape a caller passing no sender collapses to, and it
# must never satisfy the gate by matching an empty roster slot.
check "fleet: the empty actor is not fleet" 1 "" is_fleet_actor ""

# --- gate 2's evidence: the head the builder named -------------------------

# shellcheck disable=SC1090 # the path is this file's own $ACTION, resolved above
evidence() { printf '%s\n' "$@" | (source "$ACTION"; evidence_named_head); }

check "evidence: a full SHA is read whole" 0 "$(printf 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2')" \
  evidence '🔁 rerun owed at head a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'
check "evidence: the house style backticks it" 0 "abcdef1234" \
  evidence '🔁 rerun owed at head `abcdef1234` — the ci job died on the runner'
check "evidence: a pasted upper-case SHA is folded" 0 "abcdef1" \
  evidence '🔁 rerun owed at head ABCDEF1'
check "evidence: six characters name no head" 0 "" evidence '🔁 rerun owed at head abcdef'
check "evidence: a line without the marker is not evidence" 0 "" \
  evidence 'the head a1b2c3d4e5f6 is red and I cannot rerun it'
# Newest wins even when the newest is unreadable: a builder who evidences a
# second head has superseded the first, and an older marker outliving it would
# service a head nobody currently names.
check "evidence: the newest marker wins" 0 "bbbbbbb" \
  evidence '🔁 rerun owed at head aaaaaaa' '🔁 rerun owed at head bbbbbbb'
check "evidence: an unreadable newest marker supersedes a readable older one" 0 "" \
  evidence '🔁 rerun owed at head aaaaaaa' '🔁 rerun owed at head (the same one)'

# The tripwire that makes the duplicated parser honest (#424): two machines
# read one builder's line — this one and labels-reconcile.sh's moved-head test
# — and a drift between them is a label serviced under one reading and cleared
# under another. Both implementations are driven over one table; the marker
# constants are compared as bytes beside it.
RECONCILE="$ROOT/actions/labels-reconcile/labels-reconcile.sh"
parity() { # the two parsers over one line set
  local lines="$1" mine theirs
  mine="$(bash -c 'source "$1"; evidence_named_head' _ "$ACTION" <<<"$lines")"
  theirs="$(bash -c 'source "$1"; rerun_owed_named_head' _ "$RECONCILE" <<<"$lines")"
  [ "$mine" = "$theirs" ] || { printf 'ci-rerun:%s reconcile:%s\n' "$mine" "$theirs"; return 1; }
}
while IFS= read -r fixture; do
  check "parity: both parsers read '${fixture:0:48}' alike" 0 "" parity "$fixture"
done <<'FIXTURES'
🔁 rerun owed at head a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
🔁 rerun owed at head `abcdef1234` — the ci job died on the runner
🔁 rerun owed at head ABCDEF1
🔁 rerun owed at head abcdef
🔁 rerun owed at head (the same one)
the head a1b2c3d4e5f6 is red and I cannot rerun it
FIXTURES
check "parity: the marker constants are byte-identical" 0 "" \
  bash -c 'a="$(bash -c "source \"$1\"; printf %s \"\$RERUN_OWED_MARKER\"")"
    b="$(bash -c "source \"$2\"; printf %s \"\$RERUN_OWED_MARKER\"")"
    [ "$a" = "$b" ] || { printf "%s\n%s\n" "$a" "$b"; exit 1; }' _ "$ACTION" "$RECONCILE"

# Prefix, not equality: an abbreviated SHA names this head as surely as a whole
# one, and both empty-guards are load-bearing — an unread head is not a
# differing one, and neither is a service to start on.
check "head: an abbreviation names the head it abbreviates" 0 "" \
  names_this_head abcdef1 abcdef1234567
check "head: a different head is a moved head" 1 "" names_this_head abcdef1 999999999
check "head: an unnamed head is not this head" 1 "" names_this_head "" abcdef1234567
check "head: an unread head is not named" 1 "" names_this_head abcdef1 ""

# --- the candidate run: picked before it is graded -------------------------

runs_json() { # id conclusion attempt name started …
  local out="[]"
  while [ $# -gt 0 ]; do
    out="$(jq --arg id "$1" --arg c "$2" --arg a "$3" --arg n "$4" --arg s "$5" \
      '. + [{id: ($id|tonumber), conclusion: (if $c == "" then null else $c end),
             run_attempt: ($a|tonumber), name: $n, run_started_at: $s,
             html_url: ("https://github.com/owner/repo/actions/runs/" + $id)}]' <<<"$out")"
    shift 5
  done
  jq -n --argjson r "$out" '{workflow_runs: $r}'
}

pick() { pick_run "${2:-}" <<<"$1"; }

check "pick: the newest non-success at the head" 0 "22	failure	1" \
  pick "$(runs_json 11 failure 1 ci 2026-08-15T10:00:00Z 22 failure 1 ci 2026-08-15T11:00:00Z)"
check "pick: a success is never a candidate" 0 "11	failure	1" \
  pick "$(runs_json 11 failure 1 ci 2026-08-15T10:00:00Z 22 success 1 labels 2026-08-15T11:00:00Z)"
# Newest by START time, not completion: a cancelled run can outlive its
# replacement's start (#139), and this must order the way the green rule does.
check "pick: newest is by start time, not by completion" 0 "11	failure	1" \
  pick "$(runs_json 22 cancelled 1 ci 2026-08-15T09:00:00Z 11 failure 1 ci 2026-08-15T10:00:00Z)"
# A workflow that graded its own runs would be answering a question about
# itself (#208's rule, one surface over).
check "pick: the servicing workflow's own run is not a candidate" 0 "11	failure	1" \
  pick "$(runs_json 11 failure 1 ci 2026-08-15T10:00:00Z 99 failure 1 ci-rerun 2026-08-15T12:00:00Z)" ci-rerun
check "pick: nothing but successes picks nothing" 0 "" \
  pick "$(runs_json 11 success 1 ci 2026-08-15T10:00:00Z)"
# Picked before graded, which is what lets gate 3 refuse at all: a selector
# that took "the newest FAILING run" could never meet a cancelled one.
check "pick: a cancelled run is picked, so gate 3 can refuse it" 0 "22	cancelled	1" \
  pick "$(runs_json 11 failure 1 ci 2026-08-15T10:00:00Z 22 cancelled 1 ci 2026-08-15T11:00:00Z)"
check "pick: an in-flight run is picked, so gate 3 can refuse it" 0 "22		1" \
  pick "$(runs_json 11 failure 1 ci 2026-08-15T10:00:00Z 22 '' 1 ci 2026-08-15T11:00:00Z)"

# --- the decision: four gates, in order ------------------------------------

check "decision: every gate satisfied starts the rerun" 0 "START" \
  service_decision yes abcdef1 abcdef1234 11 failure 1
check "decision: gate 1 refuses an actor outside the roster" 0 "REFUSE:actor" \
  service_decision no abcdef1 abcdef1234 11 failure 1
check "decision: gate 2 refuses a head that moved" 0 "REFUSE:head" \
  service_decision yes abcdef1 999999999 11 failure 1
check "decision: gate 2 refuses when no evidence names a head" 0 "REFUSE:head" \
  service_decision yes "" abcdef1234 11 failure 1
check "decision: gate 3 refuses a cancelled run" 0 "REFUSE:verdict" \
  service_decision yes abcdef1 abcdef1234 11 cancelled 1
check "decision: gate 3 refuses an in-flight run" 0 "REFUSE:verdict" \
  service_decision yes abcdef1 abcdef1234 11 "" 1
check "decision: gate 3 refuses when the head has no failing run" 0 "REFUSE:verdict" \
  service_decision yes abcdef1 abcdef1234 "" "" ""
check "decision: gate 4 refuses a head that spent its allowance" 0 "REFUSE:allowance" \
  service_decision yes abcdef1 abcdef1234 11 failure 2
# The gates are measured here and never inherited: an actor outside the roster
# is refused AS an actor even when everything downstream would have passed, so
# a refusal names the first thing wrong and not the last.
check "decision: the first failing gate is the one named" 0 "REFUSE:actor" \
  service_decision no "" 999999999 11 cancelled 3

# --- executed runs: the two outcome shapes, through a stubbed gh -----------
#
# The shipped script is DRIVEN, not re-implemented: PATH-stubbed `gh`, the real
# main(), and the assertions read the call log the stub writes. A fixture that
# only exercised the pure functions could not see the one property D4 turns on
# — which writes happen, and in which order.

STUB="$TMP/bin"
mkdir -p "$STUB"
cat >"$STUB/gh" <<'STUBSH'
#!/usr/bin/env bash
set -u
D="$GH_STUB_DIR"
printf '%s\n' "$*" >>"$D/calls"
[ "${1:-}" = api ] || exit 0
shift
method=GET endpoint="" jqexpr="" body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --jq) jqexpr="$2"; shift ;;
    -f) case "$2" in body=*) body="${2#body=}" ;; esac; shift ;;
    --paginate | --silent) ;;
    -*) ;;
    *) [ -n "$endpoint" ] || endpoint="$1" ;;
  esac
  shift
done
if [ "$method" != GET ]; then
  case "$endpoint" in
    *rerun-failed-jobs) [ ! -f "$D/rerun.fails" ] || { echo "gh: HTTP 403" >&2; exit 1; } ;;
    */comments) printf '%s\n' "$body" >>"$D/posted" ;;
  esac
  exit 0
fi
case "$endpoint" in
  */pulls/*) file="$D/pull.json" ;;
  */comments*) file="$D/comments.json" ;;
  */actions/runs*) file="$D/runs.json" ;;
  *) file="" ;;
esac
[ -n "$file" ] && [ -f "$file" ] || { echo "gh: no fixture for $endpoint" >&2; exit 1; }
if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
STUBSH
chmod +x "$STUB/gh"

HEAD=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
scenario() { # $1 name, $2 head, $3 evidence body, $4 runs json → the scenario dir
  local d="$TMP/$1"
  rm -rf "$d"
  mkdir -p "$d"
  jq -n --arg h "$2" '{head: {sha: $h}, user: {login: "builder-bot"}}' >"$d/pull.json"
  jq -n --arg b "$3" '[{user: {login: "builder-bot"}, body: $b}]' >"$d/comments.json"
  printf '%s\n' "$4" >"$d/runs.json"
  : >"$d/calls"
  printf '%s' "$d"
}

service() { # $1 = scenario dir, $2 = actor
  (
    export PATH="$STUB:$PATH" GH_STUB_DIR="$1"
    REPO=owner/repo PR_NUMBER=7 ACTOR="$2" LABELS_CONF="$TMP/conf" \
      SELF_WORKFLOW=ci-rerun bash "$ACTION" 2>&1
  )
}
started() { grep -q "rerun-failed-jobs" "$1/calls" && echo yes || echo no; }
label_removed() { grep -q -- "-X DELETE .*labels/rerun-owed" "$1/calls" && echo yes || echo no; }
comment() { cat "$1/posted" 2>/dev/null; }

FAILING="$(runs_json 11 failure 1 ci 2026-08-15T10:00:00Z)"

# the happy path
d="$(scenario happy "$HEAD" "🔁 rerun owed at head \`$HEAD\` — the runner died" "$FAILING")"
check "service: the happy path starts the rerun" 0 "started attempt 2" service "$d" one-bot
check "service: exactly one attempt is started" 0 "1" \
  bash -c 'grep -c "rerun-failed-jobs" "$1/calls"' _ "$d"
check "service: the label comes off when the attempt starts" 0 "yes" label_removed "$d"
check "service: the comment carries the new attempt's URL" 0 \
  "https://github.com/owner/repo/actions/runs/11/attempts/2" comment "$d"

# gate 1 — an actor outside .github/labels.conf
d="$(scenario actor "$HEAD" "🔁 rerun owed at head \`$HEAD\`" "$FAILING")"
check "gate 1: a non-fleet actor is refused" 0 "gate actor" service "$d" stranger
check "gate 1: nothing was rerun" 0 "no" started "$d"
check "gate 1: the refusal names the gate and the actor" 0 "Gate 1 — the actor" comment "$d"
check "gate 1: the label is left standing" 0 "no" label_removed "$d"

# gate 2 — the head moved under the evidence
d="$(scenario moved 9999999999999999999999999999999999999999 \
  "🔁 rerun owed at head \`$HEAD\`" "$FAILING")"
check "gate 2: a moved head is refused" 0 "gate head" service "$d" one-bot
check "gate 2: nothing was rerun" 0 "no" started "$d"
check "gate 2: the refusal names the gate and both heads" 0 "Gate 2 — the head" comment "$d"
check "gate 2: the label is left standing" 0 "no" label_removed "$d"

# gate 2 — no evidence at all: told apart from a moved head, because one is a
# builder to talk to and the other is a head that changed
d="$(scenario unevidenced "$HEAD" "the ci job died on the runner again" "$FAILING")"
check "gate 2: an unevidenced label is refused" 0 "gate head" service "$d" one-bot
check "gate 2: the refusal says no comment names the head" 0 \
  "No comment from the PR author opens with" comment "$d"

# gate 3 — a cancelled run is not a verdict (#139, #209)
d="$(scenario cancelled "$HEAD" "🔁 rerun owed at head \`$HEAD\`" \
  "$(runs_json 11 cancelled 1 ci 2026-08-15T10:00:00Z)")"
check "gate 3: a cancelled run is refused" 0 "gate verdict" service "$d" one-bot
check "gate 3: nothing was rerun" 0 "no" started "$d"
check "gate 3: the refusal names the gate and the conclusion" 0 "Gate 3 — the verdict" comment "$d"
check "gate 3: the label is left standing" 0 "no" label_removed "$d"

# gate 4 — the allowance is one rerun per head
d="$(scenario spent "$HEAD" "🔁 rerun owed at head \`$HEAD\`" \
  "$(runs_json 11 failure 2 ci 2026-08-15T10:00:00Z)")"
check "gate 4: a second attempt is refused" 0 "gate allowance" service "$d" one-bot
check "gate 4: nothing was rerun" 0 "no" started "$d"
check "gate 4: the refusal names the attempt that spent it" 0 "already on attempt \`2\`" comment "$d"
check "gate 4: the label is left standing" 0 "no" label_removed "$d"

# A refusal that cleared the label is the tempting implementation — the one
# that removes it in a `finally` — and it is the stall again, with a robot in
# it (D4). Asserted for every gate at once so a fifth gate cannot arrive
# without one.
check "refusals: not one of the four gates ever removes the label" 0 "" \
  bash -c 'for d in "$1"/actor "$1"/moved "$1"/cancelled "$1"/spent; do
      grep -q -- "-X DELETE" "$d/calls" && { echo "$d cleared it"; exit 1; }
    done; exit 0' _ "$TMP"

# The label event this workflow is not about: inert, and without spending an
# API call on finding that out.
d="$(scenario otherlabel "$HEAD" "🔁 rerun owed at head \`$HEAD\`" "$FAILING")"
check "trigger: another label is not this action's event" 0 "nothing to do" \
  bash -c 'export PATH="$1:$PATH" GH_STUB_DIR="$2"
    REPO=owner/repo PR_NUMBER=7 ACTOR=one-bot EVENT_LABEL=blocked \
      LABELS_CONF="$3" bash "$4" 2>&1' _ "$STUB" "$d" "$TMP/conf" "$ACTION"
check "trigger: an unrelated label spends no API call" 0 "" cat "$d/calls"

# The API refusing the one privileged act: the label stays, the comment says
# so, and the run is red — an attempt nobody can see did not start.
d="$(scenario apifail "$HEAD" "🔁 rerun owed at head \`$HEAD\`" "$FAILING")"
: >"$d/rerun.fails"
check "service: a rerun the API refuses fails loudly" 1 "could not be started" service "$d" one-bot
check "service: and leaves the label standing" 0 "no" label_removed "$d"
check "service: and says so on the PR" 0 "The API refused the rerun" comment "$d"

# DRY_RUN narrates every mutation and performs none — how this is rehearsed
# against a live repo before it is trusted with one.
d="$(scenario dryrun "$HEAD" "🔁 rerun owed at head \`$HEAD\`" "$FAILING")"
check "service: DRY_RUN narrates the rerun" 0 "DRY_RUN: gh api -X POST" \
  bash -c 'export PATH="$1:$PATH" GH_STUB_DIR="$2"
    REPO=owner/repo PR_NUMBER=7 ACTOR=one-bot LABELS_CONF="$3" DRY_RUN=1 \
      bash "$4" 2>&1' _ "$STUB" "$d" "$TMP/conf" "$ACTION"
check "service: DRY_RUN starts nothing" 0 "no" started "$d"

# --- read, not run: the two properties graded off the YAML -----------------
#
# D2 is the security case and the issue grades it by READING the workflow. A
# step that reads the head tree is a blocking finding, so the shape is asserted
# here where a change to it reds a test rather than waiting for a reviewer.

# Comment lines are stripped first, and that is not a loophole: the prose in
# these files SAYS the head is never read, so a pattern matching it matches the
# claim as well as its violation — and the criterion is about steps (#424 D2).
# The stripped grep is what a reviewer performs; the prose is what tells them
# why.
check "isolation: no checkout of the PR head" 0 "" \
  bash -c 'uncommented() { grep -vE "^\s*#" "$@"; }
    uncommented "$1" "$2" | grep -nE "head\.(sha|ref)|pull_request\.head" && exit 1; exit 0' \
  _ "$WORKFLOW" "$CALLER"
check "isolation: every checkout is of the base default branch or pinned ceremony" 0 "" \
  bash -c 'grep -A3 "actions/checkout" "$1" | grep -E "^\s+ref:" \
    | grep -vE "default_branch|CEREMONY_SELF_REF" && exit 1; exit 0' _ "$WORKFLOW"
check "isolation: the reusable checks out with a full-SHA pin" 0 "actions/checkout@11d5960a" \
  grep -h "uses: actions/checkout" "$WORKFLOW"
# The permissions block, itemised: `actions: write` is the credential, and the
# two beside it are the label removal, the comment and the roster read. Any
# fourth grant on this job is a finding.
check "isolation: the job grants actions, pull-requests and contents: read" 0 "" \
  bash -c 'got="$(sed -n "/^    permissions:/,/^    [a-z]/p" "$1" | grep -E "^      [a-z-]+:" | tr -d " ")"
    want="contents:read
actions:write
pull-requests:write"
    [ "$got" = "$want" ] || { printf "%s\n" "$got"; exit 1; }' _ "$WORKFLOW"
check "isolation: the caller grants no more than the job uses" 0 "" \
  bash -c 'got="$(sed -n "/^permissions:/,/^jobs:/p" "$1" | grep -E "^  [a-z-]+:" | sed "s/ *#.*//" | tr -d " ")"
    want="contents:read
actions:write
pull-requests:write"
    [ "$got" = "$want" ] || { printf "%s\n" "$got"; exit 1; }' _ "$CALLER"
check "isolation: nothing here can write contents" 0 "" \
  bash -c 'grep -nE "contents: *write|id-token|packages: *write" "$1" "$2" && exit 1; exit 0' \
  _ "$WORKFLOW" "$CALLER"

# D5: no cadence. A sweep that re-attempted a refused rerun turns one bad state
# into a loop against the API — #109's `edited` runs and #110's draft runs, 75
# of 76 and 57% of them buying nothing.
check "cadence: neither workflow carries a schedule" 0 "" \
  bash -c 'grep -nE "^\s*schedule:|cron:" "$1" "$2" && exit 1; exit 0' _ "$WORKFLOW" "$CALLER"
check "cadence: the caller triggers on labeled and nothing else" 0 "types: [labeled]" \
  grep -h "types:" "$CALLER"
check "cadence: the action retries nothing" 0 "" \
  bash -c 'grep -nE "^\s*(sleep|until |while .*(retry|attempt))" "$1" && exit 1; exit 0' _ "$ACTION"

summary
