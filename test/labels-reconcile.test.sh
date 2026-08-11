#!/usr/bin/env bash
set -euo pipefail
# Byte-wise collation, matching CI: the probes sort ISO timestamps, and the
# verdict must not flip with the runner's ambient locale.
export LC_ALL=C

# Fixture tests for the labels-reconcile state machine: a comment is a
# non-verdict whatever its body says (the AUTHOR escalates by requesting the
# human), a stale approval does not promote unreviewed code, and an explicit
# human request outranks everything.
# Dependency-free beyond jq; no network, no daemon — pure decide_state.

cd "$(dirname "$0")/.."
# shellcheck source=actions/labels-reconcile/labels-reconcile.sh
. actions/labels-reconcile/labels-reconcile.sh

RTMP="$(mktemp -d)"
trap 'rm -rf "$RTMP"' EXIT

# The fixture roster is the test's own, and deliberately not the shipped one
# (#304). The state machine is roster-agnostic — it needs three distinct
# required logins, not THESE three — so binding the fixtures to
# .github/labels.conf by slot bought nothing and cost the file: when the
# operator shrank panel= from four members to three, the recused author left
# two, the third slot came up unbound, and set -u aborted this file before
# its first assertion. 217 assertions became 0, on main and on every branch cut
# from it, and no fixture here was about the panel's size. The shape below is
# test/labels.test.sh's, which has always written its own conf.
FIXTURE_CONF="$RTMP/fixture-labels.conf"
FIXTURE_AUTHOR=fixture-builder
# The DRAFT/HEAD_SHA/REQUESTED/REVIEWS_JSON assignments below are the state
# machine's inputs, consumed inside the sourced decide_state — not unused.
# shellcheck disable=SC2034
BOT1=fixture-bot-one BOT2=fixture-bot-two BOT3=fixture-bot-three
printf 'panel=%s %s %s %s\n' "$BOT1" "$BOT2" "$BOT3" "$FIXTURE_AUTHOR" \
  >"$FIXTURE_CONF"
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"
pass=0 fail=0

expect() { # $1 = description, $2 = want, $3 = got
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$3"
  fi
}

rev() { # $1=login $2=state $3=commit $4=body $5=submitted_at → one review object
  jq -n --arg u "$1" --arg s "$2" --arg c "$3" --arg b "$4" --arg t "$5" \
    '{user: {login: $u}, state: $s, commit_id: $c, body: $b, submitted_at: $t}'
}

reviews() { jq -s '.' <<<"$*"; } # collect review objects into an array

# The blocker:unrequested quiescence inputs (#236 D2). Every fixture below
# inherits a readable, settled world — a head commit an hour before this
# sweep's clock — so the cases written before #236 assert exactly what they
# always asserted. The #236 block sets both per case.
#
# One consequence a new fixture has to know: a case that means to raise
# blocker:unrequested needs a REAL submitted_at on its reviews, because the
# grace dates the round's newest review. The symbolic stamps this file uses
# elsewhere (`t1`, `t2`, …) are not unreadable — GNU date reads `t1` as 01:00
# in military timezone T, i.e. a time on WHATEVER day the suite runs — which is
# worse: the verdict would flip with the calendar, the hazard the LC_ALL pin at
# the top of this file guards on the other axis. Hence a fixed NOW here and
# real timestamps on the three stall fixtures below.
NOW="$(date -d 2026-08-03T12:00:00Z +%s)"
HEAD_COMMIT_AT=2026-08-03T11:00:00Z

# -- a sweep-wide read failure is visible without changing any PR ------------
warning="$(blind_sweep_warning 3 3 "HTTP 403: Resource not accessible by integration")"
expect "a wholly blind sweep warns, leading with the observed reason" \
  "::warning::labels: every open PR was unreadable; sampled reason: HTTP 403: Resource not accessible by integration — one candidate is missing checks: read, statuses: read and actions: read in the caller (private repos do not imply them)" \
  "$warning"
expect "the blind warning names checks: read" named \
  "$(grep -qF "checks: read" <<<"$warning" && echo named || echo missing)"
expect "the blind warning names statuses: read" named \
  "$(grep -qF "statuses: read" <<<"$warning" && echo named || echo missing)"
# must-fail (#101 D5): the #95 inference — disproven on incubator while the
# run held the evidence — must never again be stated as the cause
expect "the warning no longer asserts the permissions diagnosis as fact" no \
  "$(grep -qF "grant checks: read and statuses: read" <<<"$warning" && echo yes || echo no)"
warning="$(blind_sweep_warning 3 3 "")"
expect "with no reason captured the warning says exactly that" yes \
  "$(grep -qF "no reason was captured" <<<"$warning" && echo yes || echo no)"
expect "...and keeps the permissions candidate" named \
  "$(grep -qF "checks: read" <<<"$warning" && echo named || echo missing)"
expect "a partially blind sweep does not warn" "" "$(blind_sweep_warning 1 3 "x")"
expect "a sweep with no open PRs does not warn" "" "$(blind_sweep_warning 0 0 "")"

# -- the reason helper: facts in, one bounded line out (#101 D3/D4) ----------
expect "empty stderr is reported as its own fact" "no error output" \
  "$(read_failure_reason "")"
expect "multi-line stderr collapses to one line" \
  "GraphQL: Resource not accessible by integration (repository.pullRequest.mergeable) Resource not accessible by integration (repository.pullRequest.statusCheckRollup)" \
  "$(read_failure_reason $'GraphQL: Resource not accessible by integration (repository.pullRequest.mergeable)\nResource not accessible by integration (repository.pullRequest.statusCheckRollup)')"
long_reason="$(printf 'e%.0s' {1..400})"
short_reason="$(read_failure_reason "$long_reason")"
expect "400 chars of stderr truncate to 300 plus an ellipsis, one line" \
  "$(printf 'e%.0s' {1..300})…" "$short_reason"
expect "...within the 304-byte bound" yes \
  "$([ "${#short_reason}" -le 304 ] && echo yes || echo no)"
exact_reason="$(read_failure_reason "$(printf 'e%.0s' {1..300})")"
expect "a 300-char reason passes through whole" 300 "${#exact_reason}"

# -- a missing core taxonomy row is visible without mutating labels ----------
core_rows="$(core_label_rows)"
core_names="$(cut -d'|' -f1 <<<"$core_rows")"
expect "post-merge core row is byte-exact" \
  "post-merge|006B75|Refs-linked PR merged; post-merge criteria remain and triage owns completion" \
  "$(grep '^post-merge|' <<<"$core_rows")"
expect "a complete core taxonomy does not warn" "" \
  "$(missing_core_labels_warning "$core_rows" "$core_names")"
expect "one missing core label is named exactly" \
  "::warning::labels: missing core label(s): attention; bump the ceremony pin, then re-dispatch workflow_dispatch to bootstrap the taxonomy" \
  "$(missing_core_labels_warning "$core_rows" "$(grep -vxF attention <<<"$core_names")")"
expect "three missing core labels are named in table order" \
  "::warning::labels: missing core label(s): offsite, needs-ruling, attention; bump the ceremony pin, then re-dispatch workflow_dispatch to bootstrap the taxonomy" \
  "$(missing_core_labels_warning "$core_rows" "$(grep -vxF -e offsite -e needs-ruling -e attention <<<"$core_names")")"
expect "an unreadable empty label set does not report the taxonomy missing" "" \
  "$(missing_core_labels_warning "$core_rows" "")"
expect "unrelated scope labels do not affect a complete core taxonomy" "" \
  "$(missing_core_labels_warning "$core_rows" "$core_names
scope:consumer-one
scope:consumer-two")"

# -- the release-shape guard warns, never writes (#130; the #128 incident) ----
# The caller gates on NOT has_label release and NOT draft; these fix the
# version matrix. The warning is one line per call — reconcile_pr runs once
# per PR per sweep, so "exactly one warning per sweep" is by construction.
shape_warning="$(release_shape_warning 41 2.0.0 2.0.0-dev)"
expect "bare head over a -dev base warns" yes \
  "$(grep -qF '::warning::' <<<"$shape_warning" && echo yes || echo no)"
expect "...naming the PR and both versions" yes \
  "$(grep -qF '#41 is release-shaped (version 2.0.0-dev -> 2.0.0' <<<"$shape_warning" && echo yes || echo no)"
expect "...and pointing at the release label, not setting it" yes \
  "$(grep -qF 'apply release' <<<"$shape_warning" && echo yes || echo no)"
expect "an ordinary -dev head is silent" "" \
  "$(release_shape_warning 41 2.0.1-dev 2.0.0-dev)"
expect "a bare head equal to the base is silent" "" \
  "$(release_shape_warning 41 2.0.0 2.0.0)"
expect "an rc head is silent — pre-releases are not the merge door's shape" "" \
  "$(release_shape_warning 41 2.0.0-rc1 2.0.0-dev)"
expect "an unreadable head version is silent — never nag on a guess" "" \
  "$(release_shape_warning 41 "" 2.0.0-dev)"
expect "a bare head over an unreadable base still warns" yes \
  "$(release_shape_warning 41 2.0.0 "" | grep -qF '::warning::' && echo yes || echo no)"

# -- drafts are building, whoever is requested --------------------------------
DRAFT=true HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON='[]'
expect "draft PR is building" state:building "$(decide_state)"

# -- fresh ready PR with bots requested ---------------------------------------
DRAFT=false REQUESTED="$BOT1
$BOT2
$BOT3" REVIEWS_JSON='[]'
expect "requested bots mean bots-reviewing" state:bots-reviewing "$(decide_state)"

# -- a bot that never reviewed keeps the round open ---------------------------
#    With a live request that is the bots' ball; with NO request outstanding it
#    is the agent's, because nothing is coming until somebody asks.
REQUESTED="$BOT3" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED head1 "" 2026-08-03T10:01:00Z)")"
expect "a missing bot WITH a live request is bots-reviewing" state:bots-reviewing "$(decide_state)"
REQUESTED=""
expect "...but with nobody asked it is the agent's ball" state:addressing "$(decide_state)"
expect "...and the blocker names the stall" blocker:unrequested "$(blockers)"

# -- a comment is a non-verdict, agreement body or not: the author escalates --
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "✅ **Reviewed — I agree with everything.**" t1)" \
  "$(rev "$BOT2" APPROVED  head1 "" t2)" \
  "$(rev "$BOT3" APPROVED  head1 "" t3)")"
expect "comment-only agreement still parks on the author" state:addressing "$(decide_state)"
# ...and the author's escalation — requesting the human — flips it
REQUESTED="$HUMAN"
expect "author escalation flips to needs-human" state:needs-human "$(decide_state)"
REQUESTED=""

# -- three formal approvals need no author judgment ---------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "three formal approvals reach needs-human" state:needs-human "$(decide_state)"

# -- a comment WITHOUT a verdict parks the PR on the agent --------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "🔧 Reviewed — I agree with most; feedback below." t1)" \
  "$(rev "$BOT2" APPROVED  head1 "" t2)" \
  "$(rev "$BOT3" APPROVED  head1 "" t3)")"
expect "comment without verdict is addressing" state:addressing "$(decide_state)"

# -- changes requested blocks, at any head ------------------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED old1 "blockers below" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "changes-requested blocks even from an old head" state:addressing "$(decide_state)"

# -- a stale approval must not promote unreviewed code ------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED old1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "stale approval is addressing (agent owes re-request)" state:addressing "$(decide_state)"

# -- a re-requested bot reopens the round even with an old approval on file ---
REQUESTED="$BOT1"
expect "re-requested bot means bots-reviewing" state:bots-reviewing "$(decide_state)"
REQUESTED=""

# -- only the LATEST review per bot counts ------------------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED head1 "blockers" t1)" \
  "$(rev "$BOT1" APPROVED head1 "" t2)" \
  "$(rev "$BOT2" APPROVED head1 "" t3)" \
  "$(rev "$BOT3" APPROVED head1 "" t4)")"
expect "later approval supersedes earlier block" state:needs-human "$(decide_state)"

# -- an explicit human request outranks the bot rounds ------------------------
REQUESTED="$HUMAN" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "feedback, no verdict" t1)")"
expect "human requested outranks bots" state:needs-human "$(decide_state)"
REQUESTED=""

# -- human CHANGES_REQUESTED puts the ball back on the agent ------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)" \
  "$(rev "$HUMAN" CHANGES_REQUESTED head1 "not yet" t4)")"
expect "human block with bots approving is addressing" state:addressing "$(decide_state)"
# ...and re-requesting the human hands it back to them
REQUESTED="$HUMAN"
expect "re-requested human is needs-human again" state:needs-human "$(decide_state)"
REQUESTED=""

# -- an old human comment must not wedge the handoff (codex, #85 round 3) -----
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" COMMENTED old1 "early thoughts" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "old human comment + three approvals is needs-human" state:needs-human "$(decide_state)"
expect "old human comment still needs a fresh request" needed "$(human_request_needed && echo needed || echo not-needed)"
# ...a stale human APPROVAL likewise needs a re-request for the new head
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" APPROVED old1 "" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "stale human approval needs a fresh request" needed "$(human_request_needed && echo needed || echo not-needed)"
# ...a HEAD-CURRENT human approval needs nothing more
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" APPROVED head1 "" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "head-current human approval needs no request" not-needed "$(human_request_needed && echo needed || echo not-needed)"
# ...and a live request suppresses re-requesting
REQUESTED="$HUMAN"
expect "live human request suppresses re-request" not-needed "$(human_request_needed && echo needed || echo not-needed)"
REQUESTED=""

# ---------------------------------------------------------------------------
# #136: state:needs-human must mean "a human could merge this RIGHT NOW".
# Both cases below were observed live in this repo on 2026-07-20, and both
# showed state:needs-human while being unmergeable in different ways.
# ---------------------------------------------------------------------------
ALL_APPROVE="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"

# -- flavour 1: not mergeable. The merge button is disabled, yet the board
#    said "your turn" on #119/#120/#127 for hours. The branch fact now rides
#    the blocker axis; the state says whose ball it is, which is the agent's.
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=CONFLICTING CHECKS=SUCCESS
expect "a CONFLICTING PR is the agent's, not the human's" state:addressing "$(decide_state)"
expect "...and says WHY on the blocker axis" blocker:conflict "$(blockers)"
REQUESTED="$HUMAN"
expect "...even with the human explicitly requested" state:addressing "$(decide_state)"

# -- red CI is the same claim, but NOT the same work: a rebase does not fix a
#    failing test. Collapsing both into one needs-rebase label told the agent
#    to do the wrong thing, which is why the axis split exists.
REQUESTED="" MERGEABLE=MERGEABLE CHECKS=FAILURE
expect "a red PR is the agent's" state:addressing "$(decide_state)"
expect "...and is distinguishable from a conflict" blocker:ci-red "$(blockers)"
REQUESTED="$HUMAN"
expect "...and a human request does not override red CI" state:addressing "$(decide_state)"

# -- both at once. The single-axis design could not say this at all: one label
#    had to win, and the loser silently vanished off the board.
REQUESTED="" MERGEABLE=CONFLICTING CHECKS=FAILURE
expect "a conflicted AND red PR reports both blockers" "blocker:conflict
blocker:ci-red" "$(blockers)"
expect "...and is still just the agent's ball" state:addressing "$(decide_state)"

# -- UNKNOWN is NOT unmergeable. GitHub reports it for ~a minute after every
#    merge while it recomputes; treating it as broken would flap every open PR
#    on each merge — worse than the bug being fixed.
REQUESTED="" MERGEABLE=UNKNOWN CHECKS=PENDING
expect "UNKNOWN mergeability blocks nothing" state:needs-human "$(decide_state)"
expect "...and raises no blocker" "" "$(blockers)"

# -- blocker:unrequested — the stalled round. Nobody owes an answer because
#    nobody was ever asked, yet the board read "waiting on the bots" until
#    `stale` noticed 48h later.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="" REVIEWS_JSON='[]'
expect "ready, nobody asked, nothing reviewed raises unrequested" blocker:unrequested "$(blockers)"
# ...the partial case is equally stalled: one verdict in, nobody asked for the rest
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" 2026-08-03T10:00:00Z)")"
expect "one bot in, none requested is still unrequested" blocker:unrequested "$(blockers)"
# ...a STALE round with nobody asked is the same debt, and arguably worse: the
#    page carries approvals that no longer describe the tree. Guarding on
#    MISSING alone let this one through with no blocker at all.
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED oldhead "" 2026-08-03T10:01:00Z)" \
  "$(rev "$BOT3" APPROVED oldhead "" 2026-08-03T10:02:00Z)")"
expect "a stale round with nobody asked is unrequested too" blocker:unrequested "$(blockers)"
expect "...and is still the agent's ball" state:addressing "$(decide_state)"
# ...but a live request means an answer IS coming
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" t1)")"
REQUESTED="$BOT2"
expect "a live bot request is not a stalled round" "" "$(blockers)"
# ...and a draft is exempt: the bots ignore drafts by design
DRAFT=true REQUESTED="" REVIEWS_JSON='[]'
expect "a draft with nobody asked is not stalled" "" "$(blockers)"
# ...as is an explicit human request — claiming a PR early is deliberate
DRAFT=false REQUESTED="$HUMAN"
expect "an early human claim is not a stalled round" "" "$(blockers)"
REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS

# -- flavour 2 (the dangerous one): mergeable, green, human requested, and
#    NOBODY has reviewed this head. Observed on #119 after a rebase: every
#    signal read "merge me" and nothing on the page contradicted it.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="$HUMAN"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" t1)" \
  "$(rev "$BOT2" APPROVED oldhead "" t2)" \
  "$(rev "$BOT3" APPROVED oldhead "" t3)")"
expect "stale approvals outrank the human request (nobody reviewed this tree)" state:addressing "$(decide_state)"

# -- ...and a round that is BOTH unfinished and staled is still the agent's.
#    Deciding inside the bot loop made this depend on BOTS order: the MISSING
#    returned before any later bot's STALE was read, so the mixed round came
#    out needs-human with nothing bound to the head. Pinned at both ends of
#    the array, because the whole failure was one of ordering.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="$HUMAN"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" t1)" \
  "$(rev "$BOT2" APPROVED oldhead "" t2)")"
expect "stale approvals + a bot yet to review is addressing, not needs-human" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews "$(rev "$BOT3" APPROVED oldhead "" t3)")"
expect "...and the same when the stale verdict is the LAST bot in BOTS" \
  state:addressing "$(decide_state)"

# -- but an UNFINISHED round still yields to an explicit human request: a
#    maintainer pulling a PR to themselves early is deliberate, and was the
#    original precedence. MISSING differs from STALE — nobody has reviewed
#    YET, versus everyone reviewed something else.
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" t1)")"
expect "an unfinished round still yields to an explicit human request" state:needs-human "$(decide_state)"
REQUESTED=""
expect "...and without that request the agent owes the ask" state:addressing "$(decide_state)"

# ---------------------------------------------------------------------------
# checks_state: the rollup classifier. It lived inline in main() for the first
# round of this PR, which is why nothing here caught it calling ERROR,
# CANCELLED and STALE green. Extracted so the enum can be pinned down.
# ---------------------------------------------------------------------------
rollup() { jq -n --argjson c "$1" '{statusCheckRollup: $c}'; }
run_() { jq -n --arg n "$1" --arg o "$2" --arg t "${3:-2026-07-20T15:00:00Z}" \
  '{__typename:"CheckRun", workflowName:"ci", name:$n, conclusion:$o, completedAt:$t}'; }
ctx_() { jq -n --arg n "$1" --arg s "$2" --arg t "${3:-2026-07-20T15:00:00Z}" \
  '{__typename:"StatusContext", context:$n, state:$s, createdAt:$t}'; }

# Pinned empty for every fixture below except the #208 block, which sets its
# own. The script defaults SELF_WORKFLOW from the ambient GITHUB_WORKFLOW —
# present in any CI run of this suite — and an inherited name that happened
# to match a fixture's workflowName ("ci", "labels") would silently drop
# entries these fixtures rely on. The verdicts must not flip with the runner.
SELF_WORKFLOW=""

expect "no checks at all is NONE" NONE "$(rollup '[]' | checks_state)"
# A failed fetch leaves no rollup KEY; a PR with no checks leaves an empty
# ARRAY. Collapsing the two let an API hiccup read as "nothing is failing" —
# the same unknown-certified-as-green shape as #136, in the one place that
# fix did not look. The caller skips an UNREADABLE PR rather than relabelling.
expect "a failed read is UNREADABLE, not NONE" UNREADABLE "$(echo '{}' | checks_state)"
expect "...and a real empty rollup is still NONE" NONE \
  "$(echo '{"mergeable":"MERGEABLE","statusCheckRollup":[]}' | checks_state)"
expect "all green is SUCCESS" SUCCESS \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b SUCCESS)]" | checks_state)"
expect "a queued run is PENDING" PENDING \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b QUEUED)]" | checks_state)"
expect "a plain failure is FAILURE" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b FAILURE)]" | checks_state)"

# -- the round-1 gap: outcomes that are neither success nor pending, and that
#    leave a required check unsatisfied. All three reached the old `else`.
expect "a commit status ERROR blocks" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(ctx_ lint ERROR)]" | checks_state)"
expect "a CANCELLED run blocks" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b CANCELLED)]" | checks_state)"
expect "a STALE run blocks" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b STALE)]" | checks_state)"
expect "an outcome the enum does not know blocks, it does not pass" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b SOME_FUTURE_STATE)]" | checks_state)"

# -- NEUTRAL and SKIPPED satisfy branch protection; path-filtered jobs skip
#    constantly, and calling that red would park every PR on the agent.
expect "NEUTRAL and SKIPPED are not failures" SUCCESS \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b NEUTRAL),$(run_ c SKIPPED)]" | checks_state)"

# -- latest-wins. The rollup keeps superseded runs, so this PR's own tip
#    carried a CANCELLED `scope` beside the SUCCESS `scope` that replaced it.
#    Without collapsing, making CANCELLED block would strand it forever.
expect "a re-run supersedes the cancelled original" SUCCESS \
  "$(rollup "[$(run_ scope CANCELLED 2026-07-20T15:19:39Z),\
              $(run_ scope SUCCESS   2026-07-20T15:19:45Z)]" | checks_state)"
# The reverse order once pinned FAILURE — "the reverse order is not a re-run
# passing, it is one failing". That fixture imagined a cancelled run REPLACING
# a success; #139 recorded a cancelled run that replaced NOTHING: the
# repo-global reconcile queue keeps one pending run per group, so a sibling
# PR's event evicts the queued duplicate after it has already attached a
# check to this head. A run that never executed a step said nothing about
# these bytes — it is not a verdict, and the success beside it is. The
# survivor decides, whatever order the two arrived in (#139).
expect "a cancelled entry beside a success is not a verdict, the success is" SUCCESS \
  "$(rollup "[$(run_ scope SUCCESS   2026-07-20T15:19:39Z),\
              $(run_ scope CANCELLED 2026-07-20T15:19:45Z)]" | checks_state)"
# same job name in a different workflow is a different context, not a re-run
expect "same name in another workflow does not supersede" FAILURE \
  "$(rollup "[$(jq -n '{__typename:"CheckRun",workflowName:"labels",name:"scope",conclusion:"FAILURE",completedAt:"2026-07-20T15:00:00Z"}'),\
              $(run_ scope SUCCESS 2026-07-20T15:19:45Z)]" | checks_state)"

# -- the #139 carve-out, pinned by the recorded shape that bought it. PR #136
#    head a17e497: the reconcile succeeded 12:16:17→12:17:06, and the queued
#    duplicate — evicted by ANOTHER PR's run in the same repo-global group —
#    attached CANCELLED at 12:16:41, started_at == completed_at, no step ever
#    ran. Recorded payloads, not live fetches: the heads have moved on.
rec_() { jq -n --arg o "$1" --arg s "$2" --arg c "$3" \
  '{__typename:"CheckRun", workflowName:"labels", name:"reconcile",
    conclusion:$o, startedAt:$s, completedAt:$c}'; }
expect "a queue-cancelled duplicate beside the success that did its work (a17e497)" SUCCESS \
  "$(rollup "[$(rec_ SUCCESS   2026-07-24T12:16:17Z 2026-07-24T12:17:06Z),\
              $(rec_ CANCELLED 2026-07-24T12:16:41Z 2026-07-24T12:16:41Z)]" | checks_state)"
# ...but the discard needs a surviving verdict. A context that is ONLY
# cancelled never reported at all — a killed or timed-out required job — and
# certifying that green is the unknown-as-green shape checks_state refuses.
expect "a context whose only entry is CANCELLED still blocks" FAILURE \
  "$(rollup "[$(run_ b CANCELLED)]" | checks_state)"
expect "...and so does a context of two cancelled entries" FAILURE \
  "$(rollup "[$(rec_ CANCELLED 2026-07-24T12:16:17Z 2026-07-24T12:16:20Z),\
              $(rec_ CANCELLED 2026-07-24T12:16:41Z 2026-07-24T12:16:41Z)]" | checks_state)"
# ...and discarding the cancelled entry must never discard a real red: the
# survivor rule keeps the FAILURE, it does not resurrect anything green.
expect "a cancelled newest over an earlier FAILURE is still that failure" FAILURE \
  "$(rollup "[$(rec_ FAILURE   2026-07-24T12:16:17Z 2026-07-24T12:17:06Z),\
              $(rec_ CANCELLED 2026-07-24T12:16:41Z 2026-07-24T12:16:41Z)]" | checks_state)"

# -- the #208 exclusion: the label machine never grades its own runs. The
#    shared concurrency group displaces queued sweeps as CANCELLED, and the
#    displaced run's successor was triggered by a DIFFERENT PR or an issues
#    event — so on the victim PR the #139 carve-out's premise (a surviving
#    sibling on the same head) fails structurally: the newest self entry
#    stays CANCELLED, and the sweep set blocker:ci-red off its own corpse,
#    re-affirming it every cadence. Proven on crew#227: every real check
#    green, the only red rollup entry the sweep's own displaced run. rec_
#    already builds entries under workflowName "labels"; naming that as
#    self must drop them whole, before the newest-per-context collapse.
SELF_WORKFLOW="labels"
expect "a displaced self CANCELLED beside green others is no verdict (crew#227)" SUCCESS \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b SUCCESS),\
              $(rec_ CANCELLED 2026-08-01T15:17:56Z 2026-08-01T15:17:59Z)]" | checks_state)"
expect "a FAILED self run surfaces on the Actions tab, not as the PR's red" SUCCESS \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b SUCCESS),\
              $(rec_ FAILURE 2026-08-01T15:00:00Z 2026-08-01T15:01:00Z)]" | checks_state)"
expect "a rollup of ONLY self entries is honestly NONE, never SUCCESS" NONE \
  "$(rollup "[$(rec_ CANCELLED 2026-08-01T15:17:56Z 2026-08-01T15:17:59Z)]" | checks_state)"
# must-fail: the filter keys on the self workflow ALONE. Widening it — any
# cancelled entry, any labels-shaped name — certifies a genuine foreign
# failure green, which is #136's unknown-as-green shape all over again.
expect "a genuine foreign FAILURE still blocks beside a cancelled self entry" FAILURE \
  "$(rollup "[$(run_ a FAILURE),\
              $(rec_ CANCELLED 2026-08-01T15:17:56Z 2026-08-01T15:17:59Z)]" | checks_state)"
# ...and an empty self filters NOTHING: outside Actions no workflow name is
# ambient, and the exclusion must never drop entries on a guess — the same
# displaced-self rollup keeps blocking there, all-cancelled context intact.
SELF_WORKFLOW=""
expect "an empty SELF_WORKFLOW filters nothing — the same rollup still blocks" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b SUCCESS),\
              $(rec_ CANCELLED 2026-08-01T15:17:56Z 2026-08-01T15:17:59Z)]" | checks_state)"

# -- a run still IN FLIGHT. `run_()` cannot express this: it always carries a
#    real completedAt, which is exactly why the supersede rule shipped dating
#    runs by completion and nothing caught it. Both spellings of "no
#    completion" are pinned, because `gh` emits the zero sentinel (a string,
#    which `//` does not fall through) while the API emits null.
inflight_() { jq -n --arg n "$1" --arg t "$2" --arg c "${3:-0001-01-01T00:00:00Z}" \
  '{__typename:"CheckRun", workflowName:"ci", name:$n, status:"IN_PROGRESS",
    conclusion:"", startedAt:$t, completedAt:(if $c == "null" then null else $c end)}'; }

expect "a re-run in flight beats the success it superseded (zero sentinel)" PENDING \
  "$(rollup "[$(run_ build SUCCESS 2026-07-20T15:00:00Z),\
              $(inflight_ build 2026-07-20T15:10:00Z)]" | checks_state)"
expect "...and the same when the absent completion is null" PENDING \
  "$(rollup "[$(run_ build SUCCESS 2026-07-20T15:00:00Z),\
              $(inflight_ build 2026-07-20T15:10:00Z null)]" | checks_state)"
expect "a replacement in flight for a CANCELLED run is pending, not failed" PENDING \
  "$(rollup "[$(run_ build CANCELLED 2026-07-20T15:00:00Z),\
              $(inflight_ build 2026-07-20T15:10:00Z)]" | checks_state)"
# an entry carrying no usable timestamp is treated as newest, not oldest —
# ambiguity resolves toward "not settled" rather than toward a stale success.
# Guarded by the sort tiebreak rather than the dating expression: reverting
# only `at:` leaves this passing, so the two changes are separately pinned.
expect "an undateable in-flight run is not discarded for a stale success" PENDING \
  "$(rollup "[$(run_ build SUCCESS 2026-07-20T15:00:00Z),\
              $(jq -n '{__typename:"CheckRun",workflowName:"ci",name:"build",conclusion:"",startedAt:null,completedAt:null}')]" \
     | checks_state)"
# ...and the reverse direction, which stops "in flight sorts last" being
# widened into "in flight always wins": a run that FINISHED after an earlier
# in-flight entry is the newer word, and the context is settled.
expect "a finished re-run supersedes an earlier in-flight run" SUCCESS \
  "$(rollup "[$(inflight_ build 2026-07-20T15:19:00Z),\
              $(run_ build SUCCESS 2026-07-20T15:19:45Z)]" | checks_state)"

# -- the wind-down window. A predecessor cancelled by the concurrency group
#    does not stop the instant its replacement starts, so its completion
#    routinely lands AFTER the successor's start — on box's aa5a6ba the
#    replacement started 15:19:38 and the run it cancelled finished 15:19:51.
#    Dating by "newest stamp of any kind" compares the dead run's completion
#    against the live run's start, which is not an ordering on runs, and the
#    predecessor wins. Every fixture above spaces completion before start, so
#    none of them can see it. run_() cannot express the overlap either — it
#    carries no startedAt — hence the explicit payloads.
overlap_() { jq -n --arg n "$1" --arg o "$2" --arg s "$3" --arg c "$4" \
  '{__typename:"CheckRun", workflowName:"ci", name:$n, conclusion:$o,
    startedAt:$s, completedAt:$c}'; }
expect "a predecessor finishing after its replacement started is still older (CANCELLED)" PENDING \
  "$(rollup "[$(overlap_ scope CANCELLED 2026-07-20T15:19:00Z 2026-07-20T15:19:51Z),\
              $(inflight_ scope 2026-07-20T15:19:38Z)]" | checks_state)"
expect "...and the same when it finished green — mid-flight is not mergeable" PENDING \
  "$(rollup "[$(overlap_ build SUCCESS 2026-07-20T15:19:00Z 2026-07-20T15:19:51Z),\
              $(inflight_ build 2026-07-20T15:19:38Z)]" | checks_state)"

# -- the classifier feeds the state machine: a cancelled required check must
#    take the PR off the human's plate, which is the whole point of #136.
DRAFT=false HEAD_SHA=head1 REQUESTED="$HUMAN" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE
CHECKS="$(rollup "[$(run_ a SUCCESS),$(run_ b CANCELLED)]" | checks_state)"
expect "a cancelled check reaches decide_state as the agent's ball" state:addressing "$(decide_state)"
expect "...via blocker:ci-red, not a conflict" blocker:ci-red "$(blockers)"

# -- the happy path survives all of the above.
REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED=""
expect "mergeable + green + three head-current approvals is needs-human" state:needs-human "$(decide_state)"
# -- and a draft outranks everything, including a conflict.
DRAFT=true MERGEABLE=CONFLICTING
expect "a draft is building even when conflicted" state:building "$(decide_state)"
DRAFT=false MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="" REVIEWS_JSON='[]'

# ---------------------------------------------------------------------------
# reconcile_pr's cold-start path. Everything above tests pure functions, which
# is exactly why a per-PR `return` in the label pre-flight got through review:
# the fixtures could not reach it. A missing state:* label must skip the label
# EDIT only — merge-next clearing and the stale sweep are independent of the
# taxonomy, and stranding them reintroduced the false-invitation bug (a
# `merge-next` claim surviving on a PR the board had moved to the agent).
# ---------------------------------------------------------------------------
reconcile_probe() { # $1 = REPO_LABELS content → the log lines reconcile_pr emits
  (
    REPO_LABELS="$1" REPO=owner/repo NOW="$(date +%s)"
    LABELS="merge-next"                      # the PR carries a queue claim
    DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON='[]'
    MERGEABLE=MERGEABLE CHECKS=SUCCESS
    PR_JSON='{"created_at":"2020-01-01T00:00:00Z"}'
    run() { :; }                              # swallow mutations
    gh() { :; }                               # no network
    reconcile_pr 777 2>&1
  )
}

cold="$(reconcile_probe "merge-next")"        # state:* labels absent entirely
expect "a cold-start repo still clears merge-next" \
  yes "$(grep -q 'cleared merge-next' <<<"$cold" && echo yes || echo no)"
expect "...and still runs the stale sweep" \
  yes "$(grep -q 'stale (' <<<"$cold" && echo yes || echo no)"
expect "...while warning that the state label is missing" \
  yes "$(grep -q "state label 'state:addressing' does not exist" <<<"$cold" && echo yes || echo no)"

warm="$(reconcile_probe "$(printf 'state:addressing\nmerge-next\nstale\nblocker:unrequested')")"
expect "a bootstrapped repo converges the state as well" \
  yes "$(grep -q 'state -> state:addressing' <<<"$warm" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# needs-ruling (#51): a pending human decision. Hand-set intent the machine
# reads and never writes — an EXCLUSION on needs-human, never a blocker and
# never a latch. #50's D8 by construction: needs-ruling and state:needs-human
# can never share a PR.
# ---------------------------------------------------------------------------
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS
LABELS=""
expect "the ruling-free fixture hands off (control)" state:needs-human "$(decide_state)"
LABELS="needs-ruling"
expect "a pending ruling excludes needs-human" state:addressing "$(decide_state)"
LABELS=""
expect "...and clearing it hands off again — an exclusion, not a latch" state:needs-human "$(decide_state)"
LABELS="needs-ruling" DRAFT=true
expect "a draft with a ruling pending is still building" state:building "$(decide_state)"
DRAFT=false

# blockers() must not know the label exists: it is not a branch fact, and the
# converge loop strips every BLOCKERS entry the facts do not re-derive —
# emitting it there is exactly the trap #51 names.
MERGEABLE=CONFLICTING
LABELS=""
expect "conflict fixture emits its blocker (control)" blocker:conflict "$(blockers)"
LABELS="needs-ruling"
expect "needs-ruling adds nothing to blockers()" blocker:conflict "$(blockers)"
MERGEABLE=MERGEABLE LABELS=""

# ---------------------------------------------------------------------------
# blocked (#180): a directed hold. Same shape as needs-ruling — hand-set
# intent the machine reads and never writes, an EXCLUSION on needs-human,
# never a blocker and never a latch. During the #111 freeze rig#126/#128
# carried blocked beside state:needs-human, and rig#126 was merged seven
# minutes after the reconciler wrote the green label.
# ---------------------------------------------------------------------------
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS
LABELS=""
expect "the hold-free fixture hands off (control)" state:needs-human "$(decide_state)"
LABELS="blocked"
expect "a directed hold excludes needs-human" state:addressing "$(decide_state)"
LABELS=""
expect "...and clearing it hands off again — an exclusion, not a latch" state:needs-human "$(decide_state)"
LABELS="blocked" DRAFT=true
expect "a draft carrying blocked is still building" state:building "$(decide_state)"
DRAFT=false

# blockers() must not know this label exists either: it is not a branch fact,
# and the converge loop strips every BLOCKERS entry the facts do not
# re-derive — emitting it there would strip a live hold on the next tick.
MERGEABLE=CONFLICTING
LABELS=""
expect "conflict fixture emits its blocker (control)" blocker:conflict "$(blockers)"
LABELS="blocked"
expect "blocked adds nothing to blockers()" blocker:conflict "$(blockers)"
MERGEABLE=MERGEABLE LABELS=""

# The guard the other fixtures cannot see: an UNGUARDED has_label read under
# set -u does not go red — bash treats the unset expansion inside the
# herestring redirection as a redirection error (bash 5.2: rc 127, the shell
# survives), so has_label fails OPEN, answering "label absent" with only a
# stderr complaint. For needs-ruling that would wave a live escalation
# through to needs-human in any caller that never set LABELS. Pinned by
# re-sourcing in a clean shell: the LABELS="" init keeps the read silent,
# and deleting the init turns this red.
guard_noise="$(bash -uc '. actions/labels-reconcile/labels-reconcile.sh
  DRAFT=false HEAD_SHA=h REQUESTED="" REVIEWS_JSON="[]" MERGEABLE=MERGEABLE CHECKS=SUCCESS
  decide_state' 2>&1 >/dev/null)"
expect "a fresh source reads LABELS cleanly (no unbound complaint)" "" "$guard_noise"

# The full-sweep probes ride the needs-human-otherwise fixture (three
# head-current approvals, mergeable, green). reconcile_probe cannot serve
# here — its empty round lands on addressing for its own reasons, and the
# exclusion must be the ONLY thing moving the state.
ruling_probe() { # $1 = the PR's labels → the log lines reconcile_pr emits
  (
    REPO_LABELS="$(printf 'state:addressing\nstate:needs-human\nmerge-next\nstale\nneeds-ruling')"
    REPO=owner/repo NOW="$(date +%s)"
    LABELS="$1"
    DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE"
    MERGEABLE=MERGEABLE CHECKS=SUCCESS
    PR_JSON='{"created_at":"2020-01-01T00:00:00Z"}'
    run() { :; }                              # swallow mutations
    gh() { :; }                               # no network
    reconcile_pr 888 2>&1
  )
}

ruled="$(ruling_probe "$(printf 'needs-ruling\nmerge-next')")"
expect "the exclusion drives the full sweep to addressing" \
  yes "$(grep -q 'state -> state:addressing' <<<"$ruled" && echo yes || echo no)"
expect "...retracting merge-next: a PR awaiting a ruling is not merge-me-next" \
  yes "$(grep -q 'cleared merge-next' <<<"$ruled" && echo yes || echo no)"
expect "...and the sweep never touches needs-ruling itself" \
  no "$(grep -q 'needs-ruling' <<<"$ruled" && echo yes || echo no)"

# Staleness: waiting on a human is legitimately quiet (#50 D10) — same
# treatment as blocked, including taking an already-applied stale back off.
quiet="$(ruling_probe "needs-ruling")"
expect "quiet under a pending ruling is never stale" \
  no "$(grep -q 'stale (' <<<"$quiet" && echo yes || echo no)"
unstale="$(ruling_probe "$(printf 'needs-ruling\nstale')")"
expect "...and an already-applied stale comes off" \
  yes "$(grep -q 'unstale' <<<"$unstale" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# The ruling pass on the PR surface (#52): the bare-flag check and the 7-day
# nudge ride reconcile_pr behind the flag, on the same real-activity
# computation the stale sweep reads. A recording stub serves the API facts:
# fixture JSON per endpoint (with the caller's --jq applied by real jq),
# posted comments appended back into the fixture so a second sweep sees the
# first one's writes, and every label edit recorded.
# ---------------------------------------------------------------------------
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
RNOW=2000000000

ruling_sweep_probe() { # $1 labels, $2 PR, $3 assignees, $4 requested, $5 activity age days
  (
    local n="${2:-77}" assignees="${3:-0}" requested="${4:-}"
    local activity_days="${5:-8}"
    local assignee_json='[]'
    [ "$assignees" -eq 0 ] || assignee_json='[{"login":"owner-bot"}]'
    REPO_LABELS="$(printf 'state:addressing\nstate:needs-human\nmerge-next\nstale\nneeds-ruling')"
    REPO=owner/repo NOW="$RNOW"
    LABELS="$1"
    DRAFT=false HEAD_SHA=head1 REQUESTED="$requested"
    # Approvals submitted 8 days ago — the newest real activity anywhere.
    REVIEWS_JSON="$(reviews \
      "$(rev "$BOT1" APPROVED head1 "" "$(iso_at $((RNOW - activity_days * 86400)))")" \
      "$(rev "$BOT2" APPROVED head1 "" "$(iso_at $((RNOW - activity_days * 86400)))")" \
      "$(rev "$BOT3" APPROVED head1 "" "$(iso_at $((RNOW - activity_days * 86400)))")")"
    MERGEABLE=MERGEABLE CHECKS=SUCCESS
    PR_JSON="$(jq -n --arg at "$(iso_at $((RNOW - 10 * 86400)))" \
      --argjson assignees "$assignee_json" '{created_at: $at, assignees: $assignees}')"
    run() { "$@"; } # mutations reach the stub and are recorded, not swallowed
    gh() {
      if [ "$1" = api ]; then
        shift
        local jqexpr="" endpoint="" file
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqexpr="$2"; shift ;;
            -*) ;;
            *) [ -n "$endpoint" ] || endpoint="$1" ;;
          esac
          shift
        done
        file="$RTMP/$(printf '%s' "$endpoint" | tr '/' '_').json"
        printf '%s\n' "$endpoint" >>"$RTMP/api-calls"
        [ ! -f "$file.error" ] || return 1
        # A missing fixture is an empty collection — projected through the
        # caller's --jq exactly like real gh, so '.[].foo' yields no lines.
        [ -f "$file" ] || { printf '[]\n' | jq -r "${jqexpr:-.}"; return 0; }
        if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
      elif [ "$1" = issue ] && [ "$2" = comment ]; then
        local n="$3" body="" file
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$RTMP/posted-$n"
        file="$RTMP/repos_owner_repo_issues_${n}_comments.json"
        [ -f "$file" ] || printf '[]\n' >"$file"
        jq --arg b "$body" --arg at "$(iso_at "$RNOW")" \
          '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/posted","body":$b}]' \
          "$file" >"$file.tmp" && mv "$file.tmp" "$file"
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        printf '%s\n' "$*" >>"$RTMP/edits"
      fi
    }
    reconcile_pr "$n" 2>&1
  )
}

# The flag went up 10 days ago with its escalation posted seconds earlier;
# the newest activity is the reviews at 8 days. The escalation is conforming
# and the rung markers are pre-seeded — by now both rungs fired long ago
# (#73), older than the reviews so the quiet window still reads 8 days —
# and this probe observes the nudge wiring alone; shape and rung behavior
# have their own probes in test/ruling.test.sh.
jq -n --arg at "$(iso_at $((RNOW - 10 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$RTMP/repos_owner_repo_issues_77_timeline.json"
jq -n --arg at "$(iso_at $((RNOW - 10 * 86400 - 60)))" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
  --arg r12 "$(iso_at $((RNOW - 10 * 86400 + 13 * 3600)))" \
  --arg r24 "$(iso_at $((RNOW - 10 * 86400 + 25 * 3600)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc77","body":$b},
    {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
  >"$RTMP/repos_owner_repo_issues_77_comments.json"

wired="$(ruling_sweep_probe "needs-ruling")"
expect "8 quiet days under a ruling nudges on the PR surface" \
  yes "$(grep -q 'ruling nudge' <<<"$wired" && echo yes || echo no)"
expect "...while the quiet stays stale-free (#51's skip intact)" \
  no "$(grep -q 'stale (' <<<"$wired" && echo yes || echo no)"
expect "...the accompanied flag is not called bare" \
  no "$(grep -q 'ruling flag is bare' <<<"$wired" && echo yes || echo no)"
expect "the nudge addressed the decider and linked the escalation" \
  yes "$(grep -qF '@danmt' "$RTMP/posted-77" && grep -qF 'https://x/esc77' "$RTMP/posted-77" && echo yes || echo no)"
again="$(ruling_sweep_probe "needs-ruling")"
expect "the sweep right after the nudge holds its silence — the comment reset the window" \
  no "$(grep -q 'ruling nudge' <<<"$again" && echo yes || echo no)"
expect "exactly one nudge across both sweeps" \
  1 "$(grep -c '^----$' "$RTMP/posted-77")"
expect "no label edit across both sweeps names the ruling flag" \
  no "$(grep -q 'needs-ruling' "$RTMP/edits" 2>/dev/null && echo yes || echo no)"

# ---------------------------------------------------------------------------
# The attention pass on the PR surface (#232): every PR target is malformed,
# assigned or not. The episode marker makes the comment once-per-labeling;
# every other board mutation remains the ordinary state machine's concern.
# ---------------------------------------------------------------------------
attention_pr_fixture() { # $1 PR, $2 labeled timestamp
  jq -n --arg at "$2" \
    '[{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
    >"$RTMP/repos_owner_repo_issues_${1}_timeline.json"
  printf '[]\n' >"$RTMP/repos_owner_repo_issues_${1}_comments.json"
}

attention_pr_fixture 78 "$(iso_at $((RNOW - 120)))"
attention_mutations_before="$(wc -l <"$RTMP/edits")"
attention_pr="$(ruling_sweep_probe $'attention\nstate:needs-human' 78 0 danmt 1)"
expect "attention on an unassigned PR is diagnosed" yes \
  "$(grep -q 'malformed attention (pr)' <<<"$attention_pr" && echo yes || echo no)"
expect "the PR comment points to the assigned claim issue" yes \
  "$(grep -qF 'assigned issue that owns the claim' "$RTMP/posted-78" && echo yes || echo no)"
expect "the PR comment does not guess a target issue number" no \
  "$(grep -Eq '#[0-9]+' "$RTMP/posted-78" && echo yes || echo no)"
ruling_sweep_probe $'attention\nstate:needs-human' 78 0 danmt 1 >/dev/null
expect "two PR sweeps in one attention episode post once" 1 \
  "$(grep -cF '<!-- ceremony:attention-malformed:' "$RTMP/posted-78")"
jq --arg at "$(iso_at $((RNOW - 30)))" \
  '. + [{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
  "$RTMP/repos_owner_repo_issues_78_timeline.json" \
  >"$RTMP/repos_owner_repo_issues_78_timeline.json.tmp" \
  && mv "$RTMP/repos_owner_repo_issues_78_timeline.json.tmp" \
    "$RTMP/repos_owner_repo_issues_78_timeline.json"
ruling_sweep_probe $'attention\nstate:needs-human' 78 0 danmt 1 >/dev/null
expect "a re-set PR flag receives a second episode comment" 2 \
  "$(grep -cF '<!-- ceremony:attention-malformed:' "$RTMP/posted-78")"

attention_pr_fixture 79 "$(iso_at $((RNOW - 60)))"
ruling_sweep_probe $'attention\nstate:needs-human' 79 1 danmt 1 >/dev/null
expect "attention on an assigned PR is still diagnosed" 1 \
  "$(grep -cF '<!-- ceremony:attention-malformed:' "$RTMP/posted-79")"

attention_pr_fixture 80 "$(iso_at $((RNOW - 60)))"
: >"$RTMP/repos_owner_repo_issues_80_timeline.json.error"
unreadable_attention="$(ruling_sweep_probe $'attention\nstate:needs-human' 80 0 danmt 1)"
expect "an unreadable PR attention timeline posts nothing" no \
  "$([ -f "$RTMP/posted-80" ] && echo yes || echo no)"
expect "the unreadable fact is logged without a verdict" yes \
  "$(grep -qF 'attention timeline unreadable' <<<"$unreadable_attention" && echo yes || echo no)"

: >"$RTMP/api-calls"
ruling_sweep_probe state:needs-human 81 0 danmt 1 >/dev/null
expect "a flag-free PR performs no attention timeline read" no \
  "$(grep -qF 'repos/owner/repo/issues/81/timeline' "$RTMP/api-calls" && echo yes || echo no)"
expect "attention diagnosis caused no PR mutation" "$attention_mutations_before" \
  "$(wc -l <"$RTMP/edits")"

# ---------------------------------------------------------------------------
# The take-back's reason, on the PR (#377). incubator#94: a hand-set
# state:needs-human was taken back ~45 seconds later, three times in ten
# minutes, because the only record of the take-back was a line in the labels
# workflow's run log — which a builder driving a PR never opens. The :597
# precedence rule is correct and untouched here; what these fixtures pin is
# that it SAYS so where the builder is looking, exactly once per (blocker
# set, head), and that the three sibling exclusions stay silent.
# ---------------------------------------------------------------------------
TB="$RTMP/takeback"
mkdir -p "$TB"

takeback_probe() { # $1 PR, $2 labels, $3 head, $4 round, $5 checks, $6 mergeable, $7 draft
  (
    local n="$1" head="$3" round="$4" at
    at="$(iso_at $((RNOW - 3600)))"
    # The taxonomy from the script's own arrays: a fixture that hand-lists the
    # label names would keep passing after a rename while the sweep filtered
    # the add away.
    REPO_LABELS="$(printf '%s\n' "${STATES[@]}" "${BLOCKERS[@]}" \
      merge-next stale needs-ruling blocked)"
    REPO=owner/repo NOW="$RNOW"
    LABELS="$2"
    DRAFT="${7:-false}" HEAD_SHA="$head" REQUESTED=""
    MERGEABLE="${6:-MERGEABLE}" CHECKS="${5:-SUCCESS}"
    case "$round" in
      # every verdict a head-current approval — the round says needs-human
      approve) REVIEWS_JSON="$(reviews \
        "$(rev "$BOT1" APPROVED "$head" "" "$at")" \
        "$(rev "$BOT2" APPROVED "$head" "" "$at")" \
        "$(rev "$BOT3" APPROVED "$head" "" "$at")")" ;;
      # a standing block — the ROUND is what moves the state, not the branch
      block) REVIEWS_JSON="$(reviews \
        "$(rev "$BOT1" CHANGES_REQUESTED "$head" "" "$at")" \
        "$(rev "$BOT2" APPROVED "$head" "" "$at")" \
        "$(rev "$BOT3" APPROVED "$head" "" "$at")")" ;;
      # the only round that reaches decide_state's :587 draft clause: a
      # non-verdict outranks the draft, and the live human request carries
      # round_state to needs-human anyway — so on a draft the DRAFT rule
      # fires above :597, which is the carve-out under test.
      draftable)
        REQUESTED="$HUMAN"
        REVIEWS_JSON="$(reviews \
          "$(rev "$BOT1" COMMENTED "$head" "looks fine" "$at")" \
          "$(rev "$BOT2" APPROVED "$head" "" "$at")" \
          "$(rev "$BOT3" APPROVED "$head" "" "$at")")" ;;
    esac
    PR_JSON="$(jq -n --arg at "$at" '{created_at: $at, assignees: []}')"
    run() { "$@"; } # mutations reach the stub and are recorded, not swallowed
    gh() {
      if [ "$1" = api ]; then
        shift
        local jqexpr="" endpoint="" file
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqexpr="$2"; shift ;;
            -*) ;;
            *) [ -n "$endpoint" ] || endpoint="$1" ;;
          esac
          shift
        done
        file="$TB/$(printf '%s' "$endpoint" | tr '/' '_').json"
        [ -f "$file" ] || { printf '[]\n' | jq -r "${jqexpr:-.}"; return 0; }
        if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
      elif [ "$1" = issue ] && [ "$2" = comment ]; then
        local c="$3" body="" file
        shift 3
        while [ $# -gt 0 ]; do
          case "$1" in --body) body="$2"; shift ;; esac
          shift
        done
        printf '%s\n----\n' "$body" >>"$TB/posted-$c"
        # posted comments go back into the fixture, so the NEXT pass reads
        # this one's marker exactly as a real sweep would
        file="$TB/repos_owner_repo_issues_${c}_comments.json"
        [ -f "$file" ] || printf '[]\n' >"$file"
        jq --arg b "$body" --arg at "$(iso_at "$RNOW")" \
          '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/tb","body":$b}]' \
          "$file" >"$file.tmp" && mv "$file.tmp" "$file"
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        # recorded per PR: the atomicity assertion counts the EDIT CALLS one
        # pass makes, which is the property the comment must not disturb
        printf '%s\n' "$*" >>"$TB/edits-$3"
      fi
    }
    reconcile_pr "$n" 2>&1
  )
}

posted_count() { # $1 PR → take-back comments standing on it
  [ -f "$TB/posted-$1" ] || { echo 0; return; }
  grep -cF "$HANDOFF_TAKEBACK_MARKER_PREFIX" "$TB/posted-$1" || true
}
edit_count() { # $1 PR → label-edit calls recorded for it
  [ -f "$TB/edits-$1" ] || { echo 0; return; }
  wc -l <"$TB/edits-$1"
}

# -- the reported loop, as a regression -------------------------------------
loop1="$(takeback_probe 90 state:needs-human tbhead1 approve FAILURE)"
expect "a blocker takes the hand-set handoff back" yes \
  "$(grep -q 'state -> state:addressing' <<<"$loop1" && echo yes || echo no)"
expect "...and the take-back says so on the PR, exactly once" 1 "$(posted_count 90)"
expect "...naming the blocker standing" yes \
  "$(grep -qF "\`blocker:ci-red\`" "$TB/posted-90" && echo yes || echo no)"
expect "...and the head it is standing at" yes \
  "$(grep -qF 'tbhead1' "$TB/posted-90" && echo yes || echo no)"
expect "...and the precondition the handoff missed" yes \
  "$(grep -qF "no \`blocker:*\` standing" "$TB/posted-90" && echo yes || echo no)"
expect "...and the stop condition: re-setting the label is not the move" yes \
  "$(grep -qF 'setting it by hand only earns another take-back' "$TB/posted-90" && echo yes || echo no)"
expect "...logged as a take-back, not just as a state move" yes \
  "$(grep -q 'handoff taken back (blocker:ci-red at tbhead1)' <<<"$loop1" && echo yes || echo no)"
# The atomicity assertion (#377's last acceptance criterion): state and
# blocker ride ONE edit call, and the comment did not split them into two.
expect "one pass makes exactly one label-edit call" 1 "$(edit_count 90)"
expect "...carrying the state and the blocker together" yes \
  "$(grep -q -- '--add-label state:addressing,blocker:ci-red' "$TB/edits-90" && echo yes || echo no)"

# The loop itself: the builder re-sets the label, the sweep takes it back
# again — and this time says nothing, because the episode already spoke.
loop2="$(takeback_probe 90 state:needs-human tbhead1 approve FAILURE)"
expect "a re-set label at the same head is taken back again" yes \
  "$(grep -q 'state -> state:addressing' <<<"$loop2" && echo yes || echo no)"
expect "...in silence — one episode, one comment" 1 "$(posted_count 90)"
expect "...and the second pass still costs exactly one edit call" 2 "$(edit_count 90)"
for _ in 1 2 3 4 5 6 7 8; do
  takeback_probe 90 state:needs-human tbhead1 approve FAILURE >/dev/null
done
expect "ten passes over one episode post one comment in total" 1 "$(posted_count 90)"

# -- episode boundaries: the set and the head each open a new one -----------
takeback_probe 90 state:needs-human tbhead1 approve FAILURE CONFLICTING >/dev/null
expect "a different blocker set at the same head is a new episode" 2 "$(posted_count 90)"
expect "...and the new comment names both blockers" yes \
  "$(grep -qF "\`blocker:conflict\`, \`blocker:ci-red\`" "$TB/posted-90" \
    || grep -qF "\`blocker:ci-red\`, \`blocker:conflict\`" "$TB/posted-90" && echo yes || echo no)"
takeback_probe 90 state:needs-human tbhead2 approve FAILURE >/dev/null
expect "a new head with the same blocker is a new episode" 3 "$(posted_count 90)"
takeback_probe 90 state:needs-human tbhead2 approve FAILURE >/dev/null
expect "...which then repeats itself no more than the first did" 3 "$(posted_count 90)"
takeback_probe 90 state:needs-human tbhead1 approve FAILURE >/dev/null
expect "a head seen before is still its own episode, never a fresh one" 3 "$(posted_count 90)"

# -- the must-not-fire cases, each on its own PR so the count is its own ----
bots="$(takeback_probe 91 state:bots-reviewing tbhead1 block)"
expect "an ordinary bots-reviewing -> addressing move degrades" yes \
  "$(grep -q 'state -> state:addressing' <<<"$bots" && echo yes || echo no)"
expect "...and says nothing: the machine working is not a correction" 0 "$(posted_count 91)"

round="$(takeback_probe 92 state:needs-human tbhead1 block)"
expect "needs-human degrading on the ROUND still degrades" yes \
  "$(grep -q 'state -> state:addressing' <<<"$round" && echo yes || echo no)"
expect "...and says nothing: no blocker took anything back" 0 "$(posted_count 92)"

# The draft carve-out has the sharpest teeth here: the blocker IS standing,
# and only decide_state's :587 clause sitting above :597 keeps it quiet.
draft="$(takeback_probe 93 state:needs-human tbhead1 draftable FAILURE MERGEABLE true)"
expect "a draft degrades out of needs-human" yes \
  "$(grep -q 'state -> state:addressing' <<<"$draft" && echo yes || echo no)"
expect "...silently, though a blocker stands: the draft rule outranks :597" 0 \
  "$(posted_count 93)"
control="$(takeback_probe 94 state:needs-human tbhead1 draftable FAILURE MERGEABLE false)"
expect "the same fixture off draft degrades the same way (control)" yes \
  "$(grep -q 'state -> state:addressing' <<<"$control" && echo yes || echo no)"
expect "...and speaks — the draft was the only thing keeping it quiet" 1 \
  "$(posted_count 94)"

ruled_tb="$(takeback_probe 95 $'state:needs-human\nneeds-ruling' tbhead1 approve)"
expect "a pending ruling degrades out of needs-human" yes \
  "$(grep -q 'state -> state:addressing' <<<"$ruled_tb" && echo yes || echo no)"
expect "...silently: needs-ruling is its own visible carrier" 0 "$(posted_count 95)"

held="$(takeback_probe 96 $'state:needs-human\nblocked' tbhead1 approve)"
expect "a directed hold degrades out of needs-human" yes \
  "$(grep -q 'state -> state:addressing' <<<"$held" && echo yes || echo no)"
expect "...silently: blocked is its own visible carrier" 0 "$(posted_count 96)"

clean="$(takeback_probe 97 state:needs-human tbhead1 approve SUCCESS)"
expect "a clear branch keeps needs-human" no \
  "$(grep -q 'state -> state:addressing' <<<"$clean" && echo yes || echo no)"
expect "...and nothing was taken back, so nothing is said" 0 "$(posted_count 97)"

# -- an unreadable comment list must not invent a repeat --------------------
# Everywhere else in this file an unreadable fact invents no verdict; here the
# thing it must not invent is a SECOND comment, which is the whole harm.
tb_unreadable="$(
  (
    gh() {
      if [ "$1" = api ]; then return 1; fi
      printf '%s\n' "$*" >>"$TB/unreadable-calls"
    }
    REPO=owner/repo NOW="$RNOW" HEAD_SHA=tbhead1
    LABELS=state:needs-human DRAFT=false REQUESTED="" CHECKS=FAILURE
    MERGEABLE=MERGEABLE
    REVIEWS_JSON="$(reviews \
      "$(rev "$BOT1" APPROVED tbhead1 "" "$(iso_at $((RNOW - 3600)))")" \
      "$(rev "$BOT2" APPROVED tbhead1 "" "$(iso_at $((RNOW - 3600)))")" \
      "$(rev "$BOT3" APPROVED tbhead1 "" "$(iso_at $((RNOW - 3600)))")")"
    run() { "$@"; }
    reconcile_handoff_takeback 98 2>&1
  )
)"
expect "an unreadable comment list says so" yes \
  "$(grep -q 'take-back comments unreadable' <<<"$tb_unreadable" && echo yes || echo no)"
expect "...and posts nothing on a fact it could not read" no \
  "$(grep -q 'issue comment' "$TB/unreadable-calls" 2>/dev/null && echo yes || echo no)"

# -- the marker's own shape: one spelling per (set, head) -------------------
expect "the marker names the set and the head" \
  '<!-- handoff-taken-back:blocker:ci-red:abc123 -->' \
  "$(handoff_takeback_marker "$(printf 'blocker:ci-red\n' | handoff_takeback_set)" abc123)"
expect "a set is canonicalized by sort, so emitter order cannot re-fire it" \
  "$(printf 'blocker:conflict\nblocker:ci-red\n' | handoff_takeback_set)" \
  "$(printf 'blocker:ci-red\nblocker:conflict\n' | handoff_takeback_set)"
expect "...joined with commas, sorted" 'blocker:ci-red,blocker:conflict' \
  "$(printf 'blocker:conflict\nblocker:ci-red\n' | handoff_takeback_set)"

# -- the sweep wiring observes the existing per-PR skip without writing -------
blind_main_probe() {
  (
    GITHUB_EVENT_NAME=schedule
    REPO=owner/repo
    LABELS_CONF=.github/labels.conf
    gh() {
      if [ "$1" = label ] && [ "$2" = list ]; then
        core_label_rows | cut -d'|' -f1
      elif [ "$1" = pr ] && [ "$2" = list ]; then
        printf '101\n102\n'
      elif [ "$1" = pr ] && [ "$2" = view ]; then
        # a denial with its reason on stderr, the way real gh fails (#101)
        printf 'GraphQL: Resource not accessible by integration (repository.pullRequest.statusCheckRollup)\n' >&2
        return 1
      elif [ "$1" = api ] && [[ "$*" = *"/reviews"* ]]; then
        return 0
      elif [ "$1" = api ]; then
        jq -n --arg n "${*: -1}" \
          '{draft:false,user:{login:"author"},head:{sha:"head"},labels:[],requested_reviewers:[],created_at:"2026-07-23T00:00:00Z"}'
      elif [ "$1" = issue ] && [ "$2" = edit ]; then
        printf 'MUTATION: %s\n' "$*"
      fi
    }
    main
  )
}

blind_main="$(blind_main_probe)"
expect "a wholly blind main sweep emits exactly one annotation" 1 \
  "$(grep -c '^::warning::' <<<"$blind_main")"
expect "...leading with the reason the sweep actually observed" 1 \
  "$(grep -c '^::warning::.*Resource not accessible by integration' <<<"$blind_main")"
expect "...still naming the permissions candidate" 1 \
  "$(grep -c '^::warning::.*checks: read.*statuses: read' <<<"$blind_main")"
# must-fail (#101 D5): red if the disproven diagnosis is re-asserted as fact
expect "...never as a stated cause" 0 \
  "$(grep -c 'grant checks: read and statuses: read' <<<"$blind_main" || true)"
expect "a wholly blind main sweep leaves every PR untouched" no \
  "$(grep -q '^MUTATION:' <<<"$blind_main" && echo yes || echo no)"
expect "each blind PR keeps its counted line, matched by the sweep's own grep -qxF" yes \
  "$(grep -qxF 'labels: #101: could not read mergeability/checks — left alone this pass' <<<"$blind_main" \
    && grep -qxF 'labels: #102: could not read mergeability/checks — left alone this pass' <<<"$blind_main" \
    && echo yes || echo no)"
expect "each blind PR logs its reason as its own line beside the counted one" 2 \
  "$(grep -c '^labels: #10[12]: read failed: GraphQL: Resource not accessible by integration' <<<"$blind_main")"
# must-fail (#101 D1): red if a reason line whole-line-matches the counted
# string (the counter would double-count) or the counted line changed (the
# counter would miss it and the warning never fire)
expect "exactly the blind PRs match the counted shape whole-line — no more, no less" 2 \
  "$(grep -c '^labels: #[0-9]*: could not read mergeability/checks — left alone this pass$' <<<"$blind_main")"

# -- the grace's own wiring: the fixtures above prove the predicate, and only a
#    sweep can prove the fetch that feeds it (#236 D2). The fixture-only version
#    of this change would have passed with the global never assigned — the #91
#    shape, where the probes could not reach the per-PR path at all.
unrequested_main_probe() { # $1 = read | denied, the head-commit read's outcome
  (
    GITHUB_EVENT_NAME=schedule
    REPO=owner/repo
    LABELS_CONF=.github/labels.conf
    UMODE="$1"
    gh() {
      if [ "$1" = label ] && [ "$2" = list ]; then core_label_rows | cut -d'|' -f1; return 0; fi
      if [ "$1" = pr ] && [ "$2" = list ]; then printf '303\n'; return 0; fi
      if [ "$1" = pr ] && [ "$2" = view ]; then
        # green, so the D1 gate is open and D2 is the only question left
        jq -n '{mergeable:"MERGEABLE",
                statusCheckRollup:[{__typename:"CheckRun",workflowName:"ci",
                                    name:"check",conclusion:"SUCCESS",
                                    startedAt:"2026-07-01T00:00:00Z"}]}'
        return 0
      fi
      # recorded to a file, not to stdout: reconcile_pr sends the edit call's
      # stdout to /dev/null, so a narrating stub would look like no edit at all
      if [ "$1" = issue ] && [ "$2" = edit ]; then printf '%s\n' "$*" >>"$RTMP/uedits-$UMODE"; return 0; fi
      [ "$1" = api ] || return 0
      shift
      local jqexpr="" endpoint=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --jq) jqexpr="$2"; shift ;;
          -*) ;;
          *) [ -n "$endpoint" ] || endpoint="$1" ;;
        esac
        shift
      done
      case "$endpoint" in
        */commits/*) # the head-commit read; ordered before the commit LIST below
          if [ "$UMODE" = denied ]; then
            printf 'gh: Not Found (HTTP 404)\n' >&2
            return 1
          fi
          jq -n '{commit:{committer:{date:"2026-07-01T00:00:00Z"}}}' | jq -r "${jqexpr:-.}" ;;
        */pulls/303)
          jq -n '{draft:false,user:{login:"author"},head:{sha:"headsha"},
                  base:{sha:"basesha"},labels:[],requested_reviewers:[],
                  created_at:"2026-07-01T00:00:00Z"}' ;;
        *) printf '[]\n' | jq -r "${jqexpr:-.}" ;; # every collection empty
      esac
    }
    main
  )
}

read_sweep="$(unrequested_main_probe read)"
expect "the sweep reads the head's date and writes the stall it now dates" yes \
  "$(grep -q 'blocker:unrequested' "$RTMP/uedits-read" && echo yes || echo no)"
expect "...saying nothing about a degraded read" no \
  "$(grep -q "could not read the head commit's date" <<<"$read_sweep" && echo yes || echo no)"
denied_sweep="$(unrequested_main_probe denied)"
expect "a denied head-commit read names the denial (#101's shape)" yes \
  "$(grep -q "^labels: #303: could not read the head commit's date: gh: Not Found (HTTP 404)" <<<"$denied_sweep" \
    && echo yes || echo no)"
expect "...and writes no blocker it could not date" no \
  "$(grep -q 'blocker:unrequested' "$RTMP/uedits-denied" && echo yes || echo no)"
# ...while the PR is still converged: this read narrows one blocker, it does not
# skip the PR the way an unreadable rollup does
expect "...while the state still converges — one blocker unjudged, not a skip" yes \
  "$(grep -q 'state:addressing' "$RTMP/uedits-denied" && echo yes || echo no)"
expect "...and the sweep does not report it as a blind pass" 0 \
  "$(grep -c 'could not read mergeability/checks' <<<"$denied_sweep" || true)"

# ---------------------------------------------------------------------------
# bootstrap_labels retires the GitHub defaults (#93). LABELS.md published
# them as deleted at bootstrap; nothing deleted them — incubator's first
# dispatch (run 30041309187) ran green and left `good first issue` standing,
# the first honest read of the machine since the older repos were cleaned by
# hand. One registry beside the taxonomy, dispatch-only, and never fatal:
# absence is the NORMAL case from the second dispatch on (#91's set -e
# shape), and a 403 refusal must not cost the taxonomy the token CAN create.
# ---------------------------------------------------------------------------
BOOT="$RTMP/bootstrap"
mkdir -p "$BOOT"

RETIRED_WANT='duplicate
invalid
question
wontfix
help wanted
good first issue'
expect "the retired registry is exactly the six, no seventh" \
  "$RETIRED_WANT" "$(retired_label_names)"
# the sentence and the registry must not drift apart again: parse the names
# out of LABELS.md's own parenthetical and demand identity, name for name
# shellcheck disable=SC2016 # the backticks are LABELS.md literals, not expansions
doctrine="$(sed -n '/Default GitHub labels/,/are deleted at/p' LABELS.md \
  | tr '\n' ' ' | sed 's/.*(//;s/).*//' | grep -o '`[^`]*`' | tr -d '`')"
expect "...and matches LABELS.md name for name" "$doctrine" "$(retired_label_names)"

expected_upserts="$({ core_label_rows; configured_label_rows .github/labels.conf; } | cut -d'|' -f1)"

# -- happy path: the deletes ride the same dispatch, after an unchanged upsert set
(
  REPO=owner/repo LABELS_CONF=.github/labels.conf
  run() { printf '%s\n' "$*" >>"$BOOT/happy"; }
  bootstrap_labels
)
expect "a dispatch deletes the six in the same run as the upserts" \
  "$RETIRED_WANT" \
  "$(sed -n 's/^gh label delete \(.*\) -R owner\/repo --yes$/\1/p' "$BOOT/happy")"
expect "...and the recorded upsert set is unchanged from today's" \
  "$expected_upserts" \
  "$(sed -n 's/^gh label create \([^ ]*\) .*/\1/p' "$BOOT/happy")"

# -- a missing label is success: gh exits non-zero with not-found, and the
#    guard keeps that from aborting the dispatch. Red without the guard.
boot_missing_probe() {
  (
    REPO=owner/repo LABELS_CONF=.github/labels.conf
    run() { "$@"; }
    # shellcheck disable=SC2317 # reached through run's "$@", opaque to shellcheck
    gh() {
      if [ "$1" = label ] && [ "$2" = delete ]; then
        printf '%s\n' "$3" >>"$BOOT/missing-deletes"
        echo "could not delete label: HTTP 404: Not Found" >&2
        return 1
      fi
    }
    bootstrap_labels
  ) 2>&1
}
missing_rc=0
missing_out="$(boot_missing_probe)" || missing_rc=$?
expect "an already-absent label does not abort the dispatch" 0 "$missing_rc"
expect "...every deletion still ran" "$RETIRED_WANT" "$(cat "$BOOT/missing-deletes")"
expect "...and each absence is logged at most once per name" \
  1 "$(grep -c "retire: 'question'" <<<"$missing_out")"

# -- a refusal is tolerated: the blocker:drill-pending 403 shape, on a delete.
#    The other five still go, the taxonomy still lands, the log says who.
boot_refusal_probe() {
  (
    REPO=owner/repo LABELS_CONF=.github/labels.conf
    run() { "$@"; }
    # shellcheck disable=SC2317 # reached through run's "$@", opaque to shellcheck
    gh() {
      if [ "$1" = label ] && [ "$2" = delete ]; then
        if [ "$3" = question ]; then
          echo "HTTP 403: Resource not accessible by integration" >&2
          return 1
        fi
        printf '%s\n' "$3" >>"$BOOT/refusal-deletes"
      elif [ "$1" = label ] && [ "$2" = create ]; then
        printf '%s\n' "$3" >>"$BOOT/refusal-creates"
      fi
    }
    bootstrap_labels
  ) 2>&1
}
refusal_rc=0
refusal_out="$(boot_refusal_probe)" || refusal_rc=$?
expect "a refused delete does not abort the dispatch" 0 "$refusal_rc"
expect "...the other five still deleted" "duplicate
invalid
wontfix
help wanted
good first issue" "$(cat "$BOOT/refusal-deletes")"
expect "...the taxonomy still upserted whole" \
  "$expected_upserts" "$(cat "$BOOT/refusal-creates")"
expect "...and the log names the refused label" \
  yes "$(grep -q "retire: 'question'" <<<"$refusal_out" && echo yes || echo no)"

# -- DRY_RUN narrates the deletions like every other mutation, and does none
boot_dry_probe() {
  (
    REPO=owner/repo LABELS_CONF=.github/labels.conf DRY_RUN=1
    # shellcheck disable=SC2317 # reached through run's "$@", opaque to shellcheck
    gh() { printf '%s\n' "$*" >>"$BOOT/dry-real"; }
    bootstrap_labels
  )
}
dry_out="$(boot_dry_probe)"
expect "DRY_RUN narrates each deletion" \
  6 "$(grep -c '^labels: DRY_RUN: gh label delete' <<<"$dry_out")"
expect "...and performs none" \
  no "$(test -f "$BOOT/dry-real" && echo yes || echo no)"

# -- the case a sourced probe cannot see (#91): the script EXECUTED, set -e
#    live, every delete failing the way the second dispatch of every repo
#    fails. The run must end green with the taxonomy created whole.
EXEC="$RTMP/bootstrap-exec"
mkdir -p "$EXEC/stub"
cat >"$EXEC/stub/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "label delete")
    printf 'delete %s\n' "$3" >>"$GH_RECORD"
    echo "could not delete label: HTTP 404: Not Found (owner/repo)" >&2
    exit 1 ;;
  "label create")
    printf 'create %s\n' "$3" >>"$GH_RECORD" ;;
esac
exit 0
EOF
chmod +x "$EXEC/stub/gh"
printf 'panel=bot-a bot-b bot-c\n' >"$EXEC/labels.conf"

exec_env() { # $1 = event name → the real script, executed under the PATH stub
  : >"$EXEC/record"
  env PATH="$EXEC/stub:$PATH" GH_RECORD="$EXEC/record" \
    REPO=owner/repo LABELS_CONF="$EXEC/labels.conf" GITHUB_EVENT_NAME="$1" \
    bash actions/labels-reconcile/labels-reconcile.sh
}

exec_rc=0
exec_out="$(exec_env workflow_dispatch 2>&1)" || exec_rc=$?
expect "an executed dispatch with all six absent completes green" 0 "$exec_rc"
expect "...reaching the end of the sweep" \
  yes "$(grep -q 'reconciled.' <<<"$exec_out" && echo yes || echo no)"
expect "...having attempted all six deletions" \
  6 "$(grep -c '^delete ' "$EXEC/record")"
expect "...and created the full taxonomy" \
  "$(core_label_rows | cut -d'|' -f1)" \
  "$(sed -n 's/^create //p' "$EXEC/record")"

# -- bootstrap is dispatch-only, deletes included: the cron and
#    pull_request_target paths touch no label
for ev in schedule pull_request_target; do
  ev_rc=0
  exec_env "$ev" >/dev/null 2>&1 || ev_rc=$?
  expect "the $ev path completes green" 0 "$ev_rc"
  expect "...and deletes nothing" \
    no "$(grep -q '^delete ' "$EXEC/record" && echo yes || echo no)"
done
# -- a re-drafted fix round is not a build (#205) ----------------------------
# Draft used to short-circuit decide_state before the round was consulted, so
# a PR carrying a standing CHANGES_REQUESTED that its builder converted back
# to draft read state:building — and the staleness sweep read a dropped fix
# round as a build in progress.
load_config "$FIXTURE_CONF"
set_required_bots "$FIXTURE_AUTHOR"
MERGEABLE=MERGEABLE CHECKS=SUCCESS LABELS="" HEAD_SHA=head1
DRAFT=true REQUESTED="" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED head1 no t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a re-drafted PR with a standing block is addressing, not building" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews "$(rev "$BOT1" COMMENTED head1 thoughts t1)")"
expect "a re-drafted PR owing a round-reply is addressing" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head0 ok t1)" \
  "$(rev "$BOT2" APPROVED head0 ok t2)" \
  "$(rev "$BOT3" APPROVED head0 ok t3)")"
expect "a re-drafted PR whose approvals a push staled is addressing" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 ok t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)" \
  "$(rev "$HUMAN" CHANGES_REQUESTED head1 no t4)")"
expect "the human's standing changes-requested outranks draft too" \
  state:addressing "$(decide_state)"
# Approvals do NOT outrank draft: a re-draft after a passed round is
# deliberately building again — and a draft must never read needs-human.
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 ok t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a re-draft after a passed round is building again" \
  state:building "$(decide_state)"
REQUESTED="$HUMAN"
expect "...even with the human requested — a draft never reads needs-human" \
  state:building "$(decide_state)"
# Round 1's 224-case hole (claude's differential): a draft with a LIVE HUMAN
# REQUEST plus a standing block or comment fell through to round_state,
# whose human-request precedence sits above BLOCK/FEEDBACK — and read
# needs-human on a PR GitHub cannot merge. These are the same inputs as the
# addressing rows above with REQUESTED="$HUMAN", which is where the
# criterion can actually fail.
REQUESTED="$HUMAN" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED head1 no t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a draft with a human request and a standing block is addressing" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 thoughts t1)" \
  "$(rev "$BOT2" APPROVED head1 ok t2)" \
  "$(rev "$BOT3" APPROVED head1 ok t3)")"
expect "a draft with a human request and an owed reply is addressing" \
  state:addressing "$(decide_state)"

# The must-not-paper-over combination: a live panel request on a draft is a
# board defect (the bots ignore drafts by design) and stays VISIBLE as
# bots-reviewing rather than being absorbed into building.
REQUESTED="$BOT2" REVIEWS_JSON='[]'
expect "a live panel request on a draft surfaces as bots-reviewing" \
  state:bots-reviewing "$(decide_state)"
# The byte-identical baseline: a virgin draft still reads building.
REQUESTED="" REVIEWS_JSON='[]'
expect "a draft with no round history still reads building" \
  state:building "$(decide_state)"

# ---------------------------------------------------------------------------
# blocker:unrequested knows when the ask is permitted (#236). The blocker
# demands an act — request the panel — that BUILDER.md forbids under a head
# whose checks have not answered, so the predicate that flags the omission has
# to read CHECKS and has to let a round in motion finish moving. Two guards,
# each proved load-bearing by a mutation at the end of the block.
# ---------------------------------------------------------------------------
DRAFT=false HEAD_SHA=head1 REQUESTED="" MERGEABLE=MERGEABLE LABELS=""
NOW="$(date -d 2026-08-03T12:00:00Z +%s)"
# the genuine #26/#39 debt: three approvals of a head a push staled, nobody
# asked for the re-verdicts, and every fact hours old
OWED_QUIET_ROUND="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" 2026-08-03T10:00:00Z)" \
  "$(rev "$BOT2" APPROVED oldhead "" 2026-08-03T10:01:00Z)" \
  "$(rev "$BOT3" APPROVED oldhead "" 2026-08-03T10:02:00Z)")"
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=2026-08-03T11:00:00Z
CHECKS=SUCCESS
expect "green, quiescent, owed and unasked is the stall (the control)" \
  blocker:unrequested "$(blockers)"
# D1 — the gate. crew#318's shape: the same debt under a running check, where
# requesting is the one thing the builder must not do.
CHECKS=PENDING
expect "a pending head is CI's move, not a dropped ask" "" "$(blockers)"
CHECKS=FAILURE
expect "a red head raises ci-red alone — the two never co-occur" \
  blocker:ci-red "$(blockers)"
CHECKS=NONE
expect "no checks configured is nothing to wait for, so the stall still shows" \
  blocker:unrequested "$(blockers)"
# D2 — the grace. ceremony#235's shape: a sweep landing in the ~90 seconds
# between a round-answer push and the author's re-request.
CHECKS=SUCCESS HEAD_COMMIT_AT=2026-08-03T11:57:30Z
expect "a head pushed inside the grace is a round in motion, not a stall" \
  "" "$(blockers)"
HEAD_COMMIT_AT=2026-08-03T11:55:00Z
expect "...and exactly at the grace it flags — the boundary is inclusive" \
  blocker:unrequested "$(blockers)"
HEAD_COMMIT_AT=2026-08-03T11:50:00Z
expect "...and a later pass flags it with nothing else changed" \
  blocker:unrequested "$(blockers)"
# a verdict is the other supporting fact, and an old head does not license
# flagging a round whose newest verdict landed a minute ago
HEAD_COMMIT_AT=2026-08-03T10:00:00Z
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED oldhead "" 2026-08-03T11:59:00Z)")"
expect "a verdict submitted inside the grace is motion too" "" "$(blockers)"
# no verdicts at all is not an unreadable round — it is the first-ask stall,
# and the head's clock is the whole of it
REVIEWS_JSON='[]' HEAD_COMMIT_AT=2026-08-03T11:00:00Z
expect "nothing reviewed and nobody asked flags off the head's clock alone" \
  blocker:unrequested "$(blockers)"
# an unreadable fact never invents a verdict — the standing rule, applied to
# both timestamps
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=""
expect "an unread head date leaves the blocker unjudged" "" "$(blockers)"
HEAD_COMMIT_AT=null
expect "...and jq's literal null is unread, not epoch zero" "" "$(blockers)"
HEAD_COMMIT_AT=2026-08-03T11:00:00Z
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED oldhead "" not-a-timestamp)")"
expect "a round whose newest verdict cannot be dated is unread, not quiescent" \
  "" "$(blockers)"
# the constant is overridable the way this file's others are
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=2026-08-03T11:57:30Z
RECONCILE_UNREQUESTED_GRACE=60
expect "a shorter configured grace flags the same facts" \
  blocker:unrequested "$(blockers)"
RECONCILE_UNREQUESTED_GRACE=300

# the timestamp reader, directly: the three unreadable spellings it must refuse
expect "iso_epoch reads a real stamp" \
  "$(date -d 2026-08-03T12:00:00Z +%s)" "$(iso_epoch 2026-08-03T12:00:00Z)"
expect "iso_epoch refuses an absent stamp" "" "$(iso_epoch "")"
expect "iso_epoch refuses jq's null" "" "$(iso_epoch null)"
expect "iso_epoch refuses a stamp date cannot read" "" "$(iso_epoch not-a-timestamp)"
# ...and the trap it does NOT catch, recorded because a fixture author will
# reach for it: `t1` is a valid date to GNU date — 01:00 in military timezone T,
# on the day the suite runs — so it reads as a moving stamp rather than as an
# unreadable one. Real timestamps in any fixture the grace touches.
expect "a symbolic stamp is readable, and moves with the run's day" \
  "$(date -d t1 +%s)" "$(iso_epoch t1)"

# -- the mutation proofs: both guards are load-bearing, and this runs them ----
# A guard the fixtures cannot see removed is a guard nobody is testing, so each
# is deleted from a COPY of the script and the fixture that covers it must flip.
# The sed programs target one token each, so a refactor that moves a guard
# fails here loudly instead of passing silently.
mutant_blockers() { # $1 = sed program → blockers() from a copy of the script
  # The copy keeps its position in the tree — the script sources lib/ruling.sh
  # relative to its own path, and a copy dropped anywhere else would source
  # nothing and say so on stderr instead of failing.
  local root="$RTMP/mutant" mutated
  mutated="$root/actions/labels-reconcile/labels-reconcile.sh"
  mkdir -p "$root/actions/labels-reconcile"
  ln -sfn "$PWD/lib" "$root/lib"
  sed "$1" actions/labels-reconcile/labels-reconcile.sh >"$mutated"
  DRAFT="$DRAFT" HEAD_SHA="$HEAD_SHA" REQUESTED="$REQUESTED" \
    REVIEWS_JSON="$REVIEWS_JSON" MERGEABLE="$MERGEABLE" CHECKS="$CHECKS" \
    NOW="$NOW" HEAD_COMMIT_AT="$HEAD_COMMIT_AT" \
    RECONCILE_UNREQUESTED_GRACE="$RECONCILE_UNREQUESTED_GRACE" \
    bash -u -c '
      . "$1"
      load_config "$2"
      set_required_bots "$3"
      blockers
    ' bash "$mutated" "$FIXTURE_CONF" "$FIXTURE_AUTHOR"
}
# the harness itself, unmutated: it must reproduce the verdict the sourced
# functions give, or a "flip" below proves nothing about the guard
REVIEWS_JSON="$OWED_QUIET_ROUND" HEAD_COMMIT_AT=2026-08-03T11:00:00Z CHECKS=SUCCESS
expect "the mutation harness reproduces the control verdict" \
  blocker:unrequested "$(mutant_blockers 's/^#no-such-line$//')"
CHECKS=PENDING
expect "...and the pending fixture is green in the unmutated copy" \
  "" "$(mutant_blockers 's/^#no-such-line$//')"
expect "removing the green gate reds the pending fixture" \
  blocker:unrequested \
  "$(mutant_blockers 's/checks_permit_the_ask=false/checks_permit_the_ask=true/')"
CHECKS=SUCCESS HEAD_COMMIT_AT=2026-08-03T11:57:30Z
expect "removing the grace reds the inside-the-window fixture" \
  blocker:unrequested \
  "$(mutant_blockers 's/ \&\& unrequested_quiescent//')"
HEAD_COMMIT_AT=2026-08-03T11:00:00Z

# -- per-author panels (#224): the required set flows from the one ----------
#    resolution point, and convergence counts the effective set — never the
#    base panel beside a reduced request set (the must-fail the issue names)
PANEL_DIR="$RTMP/panel-author"
mkdir -p "$PANEL_DIR"
printf '%s\n' 'panel=bot-a bot-b bot-c bot-d' \
  'panel[builder-z]=bot-b bot-c bot-d' >"$PANEL_DIR/labels.conf"
load_config "$PANEL_DIR/labels.conf"
set_required_bots builder-z
expect "a bracketed author requires exactly its configured row" \
  "bot-b bot-c bot-d" "${REQUIRED_BOTS[*]}"
set_required_bots bot-a
expect "an unbracketed author beside a bracketed row requires panel minus self" \
  "bot-b bot-c bot-d" "${REQUIRED_BOTS[*]}"
set_required_bots outsider
expect "an unbracketed non-panelist author requires the whole base panel" \
  "bot-a bot-b bot-c bot-d" "${REQUIRED_BOTS[*]}"

# The engine shape: the three configured reviewers approving the head IS the
# whole round for a bracketed author — bot-a's absent verdict must not hold
# convergence, or the request side and the convergence side disagree forever
# (the deadlock crew#285 was filed over).
set_required_bots builder-z
THREE_APPROVE="$(reviews \
  "$(rev bot-b APPROVED head1 ok 2026-08-02T10:00:00Z)" \
  "$(rev bot-c APPROVED head1 ok 2026-08-02T10:01:00Z)" \
  "$(rev bot-d APPROVED head1 ok 2026-08-02T10:02:00Z)")"
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$THREE_APPROVE" \
  MERGEABLE=MERGEABLE CHECKS=SUCCESS LABELS=""
expect "the bracketed author's round converges on its three approvals" \
  state:needs-human "$(decide_state)"
expect "...with no blocker standing" "" "$(blockers)"
# The control: the same three approvals under the base panel are NOT a full
# round — the fourth verdict is owed and unrequested. If this pair ever
# reads the same, one side stopped consulting the resolution point.
printf '%s\n' 'panel=bot-a bot-b bot-c bot-d' >"$PANEL_DIR/labels.conf"
load_config "$PANEL_DIR/labels.conf"
set_required_bots builder-z
expect "without the row the same approvals leave the round incomplete" \
  state:addressing "$(decide_state)"
expect "...and the owed, unasked verdict is named" \
  blocker:unrequested "$(blockers)"

# -- the shipped roster, as a property rather than a slot (#304 D2) ----------
# The one case that reads the real .github/labels.conf, and it asserts only
# what that file can honestly prove here: it parses, and recusal removes the
# author from whatever it names. No index, no expected size — the panel is the
# operator's to resize (D3), and the fixtures above no longer care. What this
# does catch is a shipped conf that stopped parsing, which must never be
# reported as a green suite.
#
# The probe runs in a subshell so a refusal cannot leave this file's globals
# half-loaded, and it quantifies over every member rather than sampling one:
# there is no member whose recusal is special. load_config's stderr is dropped
# because the exit status is the assertion; the broken-conf case below would
# otherwise print its (correct) complaint into a passing run.
live_panel_probe() { # $1 = conf → PARSE:<rc> [RECUSED:<yes|no> SHRANK:<yes|no>]
  bash -u -c '
    . actions/labels-reconcile/labels-reconcile.sh
    rc=0
    load_config "$1" 2>/dev/null || rc=$?
    printf "PARSE:%s" "$rc"
    [ "$rc" -eq 0 ] || { printf "\n"; exit 0; }
    recused=yes shrank=yes
    for author in "${BOTS[@]}"; do
      set_required_bots "$author"
      for bot in ${REQUIRED_BOTS[@]+"${REQUIRED_BOTS[@]}"}; do
        [ "$bot" != "$author" ] || recused=no
      done
      [ "${#REQUIRED_BOTS[@]}" -eq "$((${#BOTS[@]} - 1))" ] || shrank=no
    done
    printf " RECUSED:%s SHRANK:%s\n" "$recused" "$shrank"
  ' bash "$1"
}
expect "the shipped labels.conf parses, and recuses each member from its own panel" \
  "PARSE:0 RECUSED:yes SHRANK:yes" "$(live_panel_probe .github/labels.conf)"
# ...and the teeth: the same probe on a copy whose panel= line names nobody.
# A roster edit that empties the line is the shape this catches — the file
# still looks like a conf, and every panel in the repo would resolve to
# nothing.
BROKEN_CONF="$RTMP/broken-labels.conf"
sed 's/^panel=.*/panel=/' .github/labels.conf >"$BROKEN_CONF"
expect "...and a malformed panel= line in that same file is refused, not passed" \
  PARSE:1 "$(live_panel_probe "$BROKEN_CONF")"

printf 'labels-reconcile tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
