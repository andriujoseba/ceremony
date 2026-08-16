#!/usr/bin/env bash
set -euo pipefail
# Byte-wise collation, matching CI: the probes sort ISO timestamps, and the
# verdict must not flip with the runner's ambient locale.
export LC_ALL=C

# Fixture tests for lib/checks.sh — the rollup classifier both reconcilers
# read. Every assertion below arrived here byte-identical from
# test/labels-reconcile.test.sh, where the classifier lived until #440 gave
# it a second caller; the incidents each one pins are named in its own
# comment, and they are the reason the move was a move and not a rewrite.
# Dependency-free beyond jq; no network, no daemon.

cd "$(dirname "$0")/.."
# shellcheck source=lib/checks.sh
. lib/checks.sh

pass=0 fail=0
expect() { # $1 = description, $2 = want, $3 = got
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$3"
  fi
}

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

printf 'checks tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
