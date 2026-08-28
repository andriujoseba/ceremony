#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=actions/issueflow-reconcile/issueflow-reconcile.sh
source "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' \
  'panel=one two' \
  'triage-actors=triage-one triage-two' \
  'scope:one|C5DEF5|First scope' >"$TMP/good.conf"
check "triage actors parse beside panel and labels" 0 "" load_issueflow_config "$TMP/good.conf"
load_issueflow_config "$TMP/good.conf"
check "triage actor is recognized" 0 "" is_triage_actor triage-two
check "non-triage actor is rejected" 1 "" is_triage_actor builder
printf '%s\n' 'panel=one' >"$TMP/missing.conf"
check "missing triage actors fails loudly" 1 "missing triage-actors=" load_issueflow_config "$TMP/missing.conf"
printf '%s\n' 'triage-actors=one' 'triage-actors=two' >"$TMP/duplicate.conf"
check "duplicate triage actors fails loudly" 1 "duplicate triage-actors" load_issueflow_config "$TMP/duplicate.conf"
# A panel[<login>]= row (#224 D8) must not take the issue board down: this
# loader ignores every line that is not triage-actors=. That tolerance was
# incidental; this row makes it deliberate, so a future tightening cannot
# break the sweep as a side effect.
printf '%s\n' \
  'panel=one two' \
  'panel[builder-z]=two' \
  'triage-actors=triage-one' >"$TMP/bracketed.conf"
check "a per-author panel row is tolerated by the issue-flow loader" 0 "" \
  load_issueflow_config "$TMP/bracketed.conf"

# The dogfood caller and reusable workflow must expose the same runtime facts
# as the documented consumer stub. Static pins catch YAML blocks drifting to
# the adjacent composite step, which otherwise fails only after merge.
check "dogfood caller wakes on issue events" 0 "  issues:" \
  grep -F "  issues:" "$ROOT/.github/workflows/self-labels.yml"
dogfood_pr_step="$(sed -n \
  '/name: reconcile state + stale (dogfood/,/name: reconcile issue flow/p' \
  "$ROOT/.github/workflows/labels-sweep.yml")"
# shellcheck disable=SC2016 # GitHub expressions are asserted as literals
check "dogfood PR reconcile receives repository" 0 '          REPO: ${{ github.repository }}' \
  grep -F '          REPO: ${{ github.repository }}' <<<"$dogfood_pr_step"
# shellcheck disable=SC2016 # GitHub expressions are asserted as literals
check "dogfood PR reconcile receives token" 0 '          GH_TOKEN: ${{ github.token }}' \
  grep -F '          GH_TOKEN: ${{ github.token }}' <<<"$dogfood_pr_step"

# Invariant 1: exactly one queue category.
check "one ready queue label is valid" 0 "KEEP" queue_decision <<<"ready"
check "zero queue labels is derivably needs-triage" 0 "ADD_NEEDS_TRIAGE" queue_decision <<<"enhancement"
check "multiple queue labels are ambiguous" 0 "FLAG_CONFLICT" queue_decision <<< $'ready\nblocked'
check "needs-triage plus queue is a conflict" 0 "FLAG_CONFLICT" queue_decision <<< $'needs-triage\nready'
check "claimed plus post-merge is a conflict" 0 "FLAG_CONFLICT" \
  queue_decision <<< $'claimed\npost-merge'
check "post-merge plus needs-ruling is healthy" 0 "KEEP" \
  queue_decision <<< $'post-merge\nneeds-ruling'

# Invariant 2: claims have an owner and either a PR or recent activity.
check "claim with open PR stays claimed" 0 "KEEP" claim_decision 1 true 999999
check "unassigned claim is flagged" 0 "FLAG_UNASSIGNED" claim_decision 0 false 60
check "quiet unassigned claim is also reclaimed" 0 "RECLAIM" claim_decision 0 false $((STALE_AFTER + 1))
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "injected clock: below stale boundary stays claimed" 0 "KEEP" \
  bash -c 'ISSUEFLOW_NOW=100000 ISSUEFLOW_STALE_HOURS=1 source "$1"; claim_decision_at 1 false 96401' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "injected clock: exact stale boundary stays claimed" 0 "KEEP" \
  bash -c 'ISSUEFLOW_NOW=100000 ISSUEFLOW_STALE_HOURS=1 source "$1"; claim_decision_at 1 false 96400' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "injected clock: past stale boundary is reclaimed" 0 "RECLAIM" \
  bash -c 'ISSUEFLOW_NOW=100000 ISSUEFLOW_STALE_HOURS=1 source "$1"; claim_decision_at 1 false 96399' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # expansion belongs to the isolated bash -c process
check "invalid injected clock fails loudly" 1 "ISSUEFLOW_NOW must be UTC epoch seconds" \
  bash -c 'ISSUEFLOW_NOW=garbage source "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
check "reclaim marker is stable within a claim episode" 0 "claim-reclaimed-96399" \
  claim_reclaim_marker 96399
check "a later claim episode receives a new reclaim marker" 0 "claim-reclaimed-99999" \
  claim_reclaim_marker 99999
check "offsite exempts the claim clock" 0 "EXEMPT" claim_clock_exempt <<<"offsite"
check "needs-ruling still exempts through the shared gate" 0 "EXEMPT" \
  claim_clock_exempt <<<"needs-ruling"
check "both quiet flags still produce one exemption verdict" 0 "EXEMPT" \
  claim_clock_exempt <<< $'offsite\nneeds-ruling'
check "blocked does not exempt a claimed issue" 0 "SWEEP" claim_clock_exempt <<<"blocked"
check "attention does not exempt a claimed issue" 0 "SWEEP" \
  claim_clock_exempt <<<"attention"
check "ready does not exempt a claimed issue" 0 "SWEEP" claim_clock_exempt <<<"ready"
check "empty labels do not exempt a claimed issue" 0 "SWEEP" claim_clock_exempt </dev/null
refs_body=$'Refs #12\nAlso refs: #8 and heavy-duty/rig#4.\nCloses #99\nNot refs-ish #7\nfix refs parsing from #200\nCloses #40; refs: none\nRefs #175 (split from #150)'
check "Refs parser returns only references owned by a valid Refs marker" 0 "" \
  test "$(refs_references <<<"$refs_body")" = $'8\n12\n175'
open_records=$'BODY\tRefs #5\nCLOSING\t9\nBODY\tRefs heavy-duty/rig#112\nBODY\tRefs #5\nCLOSING\t5'
# The records carry the head state beside the number since #440, so these
# assert the WHOLE output rather than a substring of it: a set assertion that
# greps is satisfied by a superset, and the linkage rules below are about what
# is absent as much as what is present.
check "open PR linkage unions closing and local Refs body references" 0 "" \
  test "$(open_pr_issues <<<"$open_records")" = $'5\tUNREADABLE\n9\tUNREADABLE'
check "cross-repo Refs never enter the local open PR set" 0 "" \
  open_pr_issues <<< $'BODY\tRefs heavy-duty/rig#112'
check "an issue named by both linkage paths appears exactly once" 0 "1" \
  grep -cxF -- $'5\tUNREADABLE' <<<"$(open_pr_issues <<<"$open_records")"
# A group with no ROLLUP record classifies UNREADABLE, as above: the function
# never invents a rollup for facts it was not given (#101 D1). With one, the
# head is classified once per PR and every issue that PR names carries it.
stall_records=$'ROLLUP\t{"statusCheckRollup":[{"workflowName":"ci","name":"test","conclusion":"FAILURE","completedAt":"2026-08-16T10:00:00Z"}]}\nCLOSING\t5\nBODY\tRefs #6'
check "a PR head classifies once and reaches every issue that PR names" 0 "" \
  test "$(SELF_WORKFLOW="" open_pr_issues <<<"$stall_records")" = $'5\tFAILURE\n6\tFAILURE'
check "only FAILURE is a red head — PENDING, NONE and UNREADABLE are not" 0 "" \
  test "$(SELF_WORKFLOW="" issues_with_failing_head <<< $'5\tFAILURE\n6\tPENDING\n7\tNONE\n8\tUNREADABLE\n9\tSUCCESS')" = "5"
check "a second open PR on the same issue counts when either head is red" 0 "" \
  test "$(issues_with_failing_head <<< $'5\tSUCCESS\n5\tFAILURE')" = "5"
# ...and the same claim where the pipeline can actually break it. The line
# above enters BELOW the dedup, on an input `open_pr_issues` would have to
# produce first, so it passed for months of nothing while a `-u` keyed on the
# number alone deleted one of the two rows upstream. Deduping on the pair is
# what these assert, and the property is order-independence rather than either
# verdict: `-u` keeps whichever row sorted first, so the green-first order is
# the one that hid the red head and both orders must agree.
two_pr_green_first=$'ROLLUP\t{"statusCheckRollup":[{"workflowName":"ci","name":"test","conclusion":"SUCCESS","completedAt":"2026-08-16T10:00:00Z"}]}\nCLOSING\t5\nROLLUP\t{"statusCheckRollup":[{"workflowName":"ci","name":"test","conclusion":"FAILURE","completedAt":"2026-08-16T10:00:00Z"}]}\nCLOSING\t5'
two_pr_red_first=$'ROLLUP\t{"statusCheckRollup":[{"workflowName":"ci","name":"test","conclusion":"FAILURE","completedAt":"2026-08-16T10:00:00Z"}]}\nCLOSING\t5\nROLLUP\t{"statusCheckRollup":[{"workflowName":"ci","name":"test","conclusion":"SUCCESS","completedAt":"2026-08-16T10:00:00Z"}]}\nCLOSING\t5'
check "two open PRs on one issue both survive the dedup" 0 "" \
  test "$(SELF_WORKFLOW="" open_pr_issues <<<"$two_pr_green_first")" = $'5\tFAILURE\n5\tSUCCESS'
check "...whichever order the query paged them in" 0 "" \
  test "$(SELF_WORKFLOW="" open_pr_issues <<<"$two_pr_red_first")" = $'5\tFAILURE\n5\tSUCCESS'
check "...so the red head reaches the tripwire with the green PR paged first" 0 "" \
  test "$(SELF_WORKFLOW="" open_pr_issues <<<"$two_pr_green_first" \
    | issues_with_failing_head)" = "5"
check "...and with it paged second" 0 "" \
  test "$(SELF_WORKFLOW="" open_pr_issues <<<"$two_pr_red_first" \
    | issues_with_failing_head)" = "5"
# Two PRs on one issue at the SAME state is still one row: the pair key
# dedupes, it does not simply stop deduping.
check "two open PRs agreeing on the state still collapse to one row" 0 "" \
  test "$(SELF_WORKFLOW="" open_pr_issues <<<"${two_pr_green_first/FAILURE/SUCCESS}")" \
    = $'5\tSUCCESS'
# A ROLLUP record with an empty value is malformed, not absent, and it must
# still land on a value the classifier defines. Written with a brace default
# this classified as the empty string — jq refusing `\{}` as a parse error —
# which is a sixth state no caller of checks_state knows how to read.
check "a malformed empty ROLLUP record still classifies UNREADABLE" 0 "" \
  test "$(open_pr_issues <<< $'ROLLUP\t\nCLOSING\t42')" = $'42\tUNREADABLE'
malformed_rollup_stderr="$(open_pr_issues <<< $'ROLLUP\t\nCLOSING\t42' 2>&1 >/dev/null)"
check "...and it reaches that verdict without jq complaining" 1 "" \
  grep -q 'parse error' <<<"$malformed_rollup_stderr"
check "the membership test reads field one, not the whole record" 0 "" \
  issue_has_open_pr 5 <<< $'5\tFAILURE'
check "...and does not match an issue named only by another record's state" 1 "" \
  issue_has_open_pr 4 <<< $'5\tFAILURE\n40\tSUCCESS'
check "unchecked criteria preserve their source lines verbatim" 0 \
  $'- [ ] first criterion\n  * [ ] indented criterion\n1. [ ] numbered criterion' \
  unchecked_criteria <<< $'- [x] done\n- [ ] first criterion\r\n  * [ ] indented criterion\n1. [ ] numbered criterion'
check "merged Refs with unchecked criteria transitions" 0 "TRANSITION" \
  post_merge_decision 12 false false <<<"- [ ] verify after merge"
check "open Refs does not transition" 0 "KEEP" \
  post_merge_decision 12 true false <<<"- [ ] verify after merge"
check "a handled merged Refs episode does not transition again" 0 "KEEP" \
  post_merge_decision 12 false true <<<"- [ ] verify after merge"
check "merged Refs with all criteria checked does not transition" 0 "KEEP" \
  post_merge_decision 12 false false </dev/null

# The deliverable is the PR that merged last, not the one numbered highest
# (#242). The first row is crew#176's measured shape — #184 merged
# 19:05:16Z, #182 merged 19:05:18Z — so it fails against the old sort -n.
MERGED_REF_PR_RECORDS=$'176\t184\t2026-07-30T19:05:16Z\n176\t182\t2026-07-30T19:05:18Z'
check "the later merge wins over the higher PR number" 0 "182" \
  post_merge_pr_for_issue 176
MERGED_REF_PR_RECORDS=$'12\t100\t2026-07-30T10:00:00Z\n12\t101\t2026-07-30T11:00:00Z'
check "number order agreeing with merge order still answers the later merge" 0 "101" \
  post_merge_pr_for_issue 12
MERGED_REF_PR_RECORDS=$'176\t184\t2026-07-30T19:05:16Z\n321\t326\t2026-08-03T14:44:46Z\n176\t182\t2026-07-30T19:05:18Z\n321\t322\t2026-08-03T16:00:00Z'
check "interleaved issues each resolve to their own last merge" 0 "182" \
  post_merge_pr_for_issue 176
check "...and a neighbouring issue's later merge never leaks in" 0 "322" \
  post_merge_pr_for_issue 321
# Two PRs can share a mergedAt second, so the tie-break is specified rather
# than left to whichever record the sweep happened to emit first.
MERGED_REF_PR_RECORDS=$'55\t70\t2026-07-30T19:05:16Z\n55\t71\t2026-07-30T19:05:16Z'
check "an identical mergedAt breaks to the highest PR number" 0 "71" \
  post_merge_pr_for_issue 55
MERGED_REF_PR_RECORDS=$'55\t71\t2026-07-30T19:05:16Z\n55\t70\t2026-07-30T19:05:16Z'
check "...and swapping the two input lines gives the same answer" 0 "71" \
  post_merge_pr_for_issue 55
MERGED_REF_PR_RECORDS=$'176\t184\t2026-07-30T19:05:16Z'
check "an issue with no merged Refs PR still answers empty" 0 "" \
  test -z "$(post_merge_pr_for_issue 999)"
check "...so its post-merge decision is KEEP" 0 "KEEP" \
  post_merge_decision "$(post_merge_pr_for_issue 999)" false false \
  <<<"- [ ] verify after merge"
MERGED_REF_PR_RECORDS=""
# mergedAt must stay a field on the merged-PR node set already fetched: the
# record shape gets richer, the request count does not (#242).
check "the sweep still issues exactly two GraphQL queries" 0 "2" \
  grep -c 'gh api graphql' "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
check "...with mergedAt selected on the merged-PR node it already fetched" 0 "" \
  grep -qF 'nodes { number mergedAt body }' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

check "one closed offsite PR nudges" 0 "NUDGE" offsite_resolved_decision <<<"CLOSED"
check "two closed offsite PRs nudge" 0 "NUDGE" offsite_resolved_decision <<< $'CLOSED\nCLOSED'
check "one open offsite PR keeps quiet" 0 "QUIET" offsite_resolved_decision <<< $'CLOSED\nOPEN'
check "no visible offsite PR keeps quiet" 0 "QUIET" offsite_resolved_decision </dev/null
check "an unreadable offsite PR keeps quiet" 0 "QUIET" offsite_resolved_decision <<< $'CLOSED\nUNKNOWN'

timeline='[
  {"event":"cross-referenced","source":{"issue":{"number":112,"repository":{"full_name":"heavy-duty/rig"},"pull_request":{"url":"x"}}}},
  {"event":"cross-referenced","source":{"issue":{"number":7,"repository":{"full_name":"heavy-duty/rig"}}}},
  {"event":"mentioned","source":{"issue":{"number":9,"repository":{"full_name":"heavy-duty/box"},"pull_request":{"url":"x"}}}},
  {"event":"assigned"}
]'
check "offsite timeline extracts only cross-referenced PRs" 0 "heavy-duty/rig#112" \
  offsite_cross_referenced_prs <<<"$timeline"
check "empty offsite timeline extracts nothing" 0 "" offsite_cross_referenced_prs <<<"[]"

# Invariant 3: blocked declarations parse and release only when all close.
refs="$(blocked_references <<< $'Context #99. Blocked by #12 (first), #7 (second). Blocks #44.')"
check "blocked declaration extracts only declared refs" 0 $'7\n12' printf '%s\n' "$refs"
body=$'Blocked by #12 (first),\n#7 (soft-wrapped second). Blocks #44.'
check "soft-wrapped blocker declaration retains continuation refs" 0 "" test \
  "$(blocked_references <<<"$body")" = $'7\n12'
body=$'Blocked by #12 (known)\nFollow-up context mentions #7 without a sentence boundary'
check "unterminated blocker prose errs toward retaining dependencies" 0 "" test \
  "$(blocked_references <<<"$body")" = $'7\n12'
body="Part of #1. Blocked by #11 (needs a ceremony tag to pin), #12 (must be executed from the guide), #19 (the conversion vendors the doctrine). Blocks #14, #15 (they inherit the pilot's lessons)."
check "real issue 13 inline blockers parse" 0 "" test \
  "$(blocked_references <<<"$body")" = $'11\n12\n19'
body="Part of #1. Blocked by #13 (inherits the pilot's lessons). Can run in parallel with #15."
check "real issue 14 inline blocker parses" 0 "" test \
  "$(blocked_references <<<"$body")" = "13"
body="Part of #1. Blocked by #13 (pilot lessons). Can run in parallel with #14."
check "real issue 15 inline blocker parses" 0 "" test \
  "$(blocked_references <<<"$body")" = "13"
body="Part of #1. Blocked by #11, #12 (needs a released ceremony + the bootstrap guide); benefits from #13's lessons but does not need #14/#15."
check "real issue 16 inline blockers parse" 0 "" test \
  "$(blocked_references <<<"$body")" = $'11\n12'
check "qualified short repository reference drops" 0 "" test \
  -z "$(blocked_references <<<"Blocked by rig#112.")"
check "qualified owner/repository reference drops" 0 "" test \
  -z "$(blocked_references <<<"Blocked by heavy-duty/box#9.")"
check "parenthesized local reference survives" 0 "13" blocked_references <<<"Blocked by (#13)."
check "slash-adjacent local references survive" 0 $'14\n15' \
  blocked_references <<<"Blocked by #14/#15."
check "comma-adjacent local references survive" 0 $'11\n12' \
  blocked_references <<<"Blocked by #11, #12."
# A repeated declaration contributes every sentence, not just the first —
# rig#154's body promoted on `#152` alone while #153 and #148 were open (#184).
body="Part of #151. Blocked by #152. Blocked by #153. Blocked by #148 — the registry PR merges under landed governance. Blocks #155."
check "repeated blocker sentences all contribute" 0 "" test \
  "$(blocked_references <<<"$body")" = $'148\n152\n153'
body=$'Note: restored because it is blocked by an operator act. See below.\nBlocked by #152, #153, #148.'
check "earlier blocked-by prose does not hijack the declaration" 0 "" test \
  "$(blocked_references <<<"$body")" = $'148\n152\n153'
body=$'This was blocked by #9 before the split.\nBlocked by #12.'
check "prose refs are retained beside the declaration, never substituted" 0 "" test \
  "$(blocked_references <<<"$body")" = $'9\n12'
repeated_refs="$(blocked_references <<<"Blocked by #152. Blocked by #153.")"
check "repeated declaration with one open blocker keeps issue blocked" 0 "KEEP" \
  blocked_decision "$repeated_refs" $'CLOSED\nOPEN'
check "cross-repo ref in a later clause still flags" 0 "FLAG_CROSS_REPO" \
  blocked_decision "12" "CLOSED" \
  "$(blocked_cross_references <<<"Blocked by #12. Blocked by rig#7.")"
check "open blocker keeps issue blocked" 0 "KEEP" blocked_decision "$refs" $'CLOSED\nOPEN'
check "all closed blockers release issue" 0 "READY" blocked_decision "$refs" $'CLOSED\nCLOSED'
check "missing blocked declaration is flagged" 0 "FLAG_UNPARSEABLE" blocked_decision "" ""
check "unreadable dependency has its own skip verdict" 0 "SKIP_UNREADABLE_DEPENDENCY" \
  blocked_decision "12" "UNKNOWN"
check "an open blocker still wins beside an unreadable dependency" 0 "KEEP" \
  blocked_decision "12" $'OPEN\nUNKNOWN'
check "cross-repo-only blocker is flagged distinctly" 0 "FLAG_CROSS_REPO" \
  blocked_decision "" "" "rig#112"
check "cross-repo blocker prevents false promotion when locals close" 0 "FLAG_CROSS_REPO" \
  blocked_decision "9" "CLOSED" "rig#9"

# The parse echo (#252): the machine states what it read, so a
# readable-but-wrong declaration is visible in one sweep instead of five days.
check "the rendered set names the locals in parse order" 0 "{#7, #12}" \
  blocked_parse_set "$(printf '7\n12\n')" ""
check "a single blocker still renders as a set" 0 "{#12}" blocked_parse_set "12" ""
check "an empty parse renders as the empty set" 0 "{}" blocked_parse_set "" ""
check "cross-repo references are echoed beside the locals" 0 "{#12, rig#9}" \
  blocked_parse_set "12" "rig#9"
check "a cross-repo-only parse is echoed too" 0 "{heavy-duty/box#9}" \
  blocked_parse_set "" "heavy-duty/box#9"
# crew#308: a *negated* marker phrase unions as the thing it denies, and the
# silent result was a set nobody saw until a human ran the parser. Echoed, the
# union is visible in the thread that contains the declaration.
echo_308="$(blocked_parse_set \
  "$(blocked_references <<<'Blocked by #162, #265. It is no longer blocked by #221.')" \
  "$(blocked_cross_references <<<'Blocked by #162, #265. It is no longer blocked by #221.')")"
check "the #308 shape echoes the negation-unioned blocker verbatim" 0 "" test \
  "$echo_308" = "{#162, #221, #265}"
# The marker is scoped to the SET's value — the whole idempotency contract.
# Mutation proof, both directions: same set must reuse its marker (or a
# 15-minute cron repeats itself forever), different set must not (or a
# misparse is echoed under a marker the thread already carries, and stays
# invisible — exactly the failure this change exists to close).
check "an unchanged set reuses its marker" 0 "" test \
  "$(blocked_parse_marker '{#7, #12}')" = "$(blocked_parse_marker '{#7, #12}')"
check "a changed set takes a different marker" 1 "" test \
  "$(blocked_parse_marker '{#7, #12}')" = "$(blocked_parse_marker '{#7, #12, #19}')"
check "the empty set has a marker of its own" 0 "blockers-parsed-none-44136fa355b3" \
  blocked_parse_marker "{}"
check "the marker survives a cross-repo reference's punctuation" 0 \
  "blockers-parsed-12-heavy-duty-box-9-c8e36fe3b793" \
  blocked_parse_marker "{#12, heavy-duty/box#9}"
# The readable half of the marker is many-to-one and must not be the identity.
# Every pair below is two reference tokens `issue_references` classifies, that
# slug identically; a slug-keyed marker made the second one find the first
# one's marker and post nothing — silence in the one case the echo exists to
# speak about. Distinguishing `/` alone would close the first pair and leave
# the rest, so the digest of the whole rendered set is what decides.
#
# Classifies, not parses: three of the four are reachable as a declared set —
# `{acme.widgets#9}` is not, because the clause parser stops at the `.` and
# `blocked_reference_records` never hands that token through, though
# `issue_references` does answer CROSS for it. It stays in the family because
# the marker's contract is over the tokens the classifier admits, not over the
# subset today's clause parser happens to reach; the class proof does not rest
# on it either way, since `{acme-widgets#9}` vs `{acme_widgets#9}` is reachable
# on both sides and reds the cheap fix on its own.
check "the slug alone cannot separate a qualified ref from a hyphenated one" 0 "" \
  test "$(printf '%s' '{acme/widgets#9}' | tr -c '[:alnum:]' '-' | sed 's/--*/-/g; s/^-//; s/-$//')" \
     = "$(printf '%s' '{acme-widgets#9}' | tr -c '[:alnum:]' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
# Pairwise, and deliberately so. Anchoring every pair on the `/` spelling
# would pass under a fix that only taught the slug about `/` — and that fix
# leaves `{acme-widgets#9}`, `{acme_widgets#9}` and `{acme.widgets#9}` sharing
# one marker. The contract is that no two distinct parses collide, so the test
# is every pair, not every pair through one representative.
marker_family=(
  '{acme/widgets#9}' '{acme-widgets#9}' '{acme_widgets#9}' '{acme.widgets#9}'
)
for left in "${marker_family[@]}"; do
  for right in "${marker_family[@]}"; do
    [ "$left" != "$right" ] || continue
    check "...but the marker does: $left vs $right" 1 "" test \
      "$(blocked_parse_marker "$left")" = "$(blocked_parse_marker "$right")"
  done
done
check "the qualifier's punctuation reaches the marker's identity" 1 "" test \
  "$(blocked_parse_marker '{#12, heavy-duty/box#9}')" \
  = "$(blocked_parse_marker '{#12, heavy-duty-box#9}')"
# shellcheck disable=SC2016 # expansions belong to the generated fake gh
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "$1" = api ]; then [ ! -f "$GH_COMMENTS" ] || cat "$GH_COMMENTS"; exit; fi' \
  'if [ "$1 $2" = "issue comment" ]; then' \
  '  while [ "$#" -gt 0 ]; do' \
  '    if [ "$1" = --body ]; then shift; printf "%s\n" "$1" >>"$GH_COMMENTS"; exit; fi' \
  '    shift' \
  '  done' \
  'fi' >"$TMP/gh"
chmod +x "$TMP/gh"
: >"$TMP/comments"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "cross-repo warning is idempotent across two sweeps" 0 "" \
  env PATH="$TMP:$PATH" GH_COMMENTS="$TMP/comments" bash -c \
  'source "$1"; REPO=heavy-duty/ceremony
  ensure_comment 99 blocked-cross-repo "cross-repo warning"
  ensure_comment 99 blocked-cross-repo "cross-repo warning"
  test "$(grep -cF "<!-- issueflow:blocked-cross-repo -->" "$GH_COMMENTS")" -eq 1' \
  _ "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# Invariant 4: only configured triage actors mint directly into the queue.
check "triage-authored ready issue is accepted" 0 "KEEP" author_decision true <<<"ready"
check "outside author receives needs-triage" 0 "ADD_NEEDS_TRIAGE" author_decision false <<<"ready"
check "outside author already marked needs-triage is stable" 0 "KEEP" author_decision false <<<"needs-triage"
check "later sweep accepts a normalized outside-authored issue" 0 "KEEP" queue_decision <<<"ready"

# Invariant 5: completed epics get one nudge; incomplete/unparseable do not.
epic_refs="$(epic_references <<< $'## Definition of done\n- [ ] outside #8\n\n## Task list\n- [ ] #3 first\n- [x] #2 done\nplain #9')"
check "epic parser reads task-list refs only" 0 $'2\n3' printf '%s\n' "$epic_refs"
body=$'## Task list\n- [x] #2 done\n- [x] #3 done\n\n## Definition of done\n- [ ] open issue #99 must not suppress the nudge'
check "epic parser stops before later checkbox sections" 0 "" test \
  "$(epic_references <<<"$body")" = $'2\n3'
# shellcheck disable=SC2016 # backticks and ${{ }}-shaped prose are fixture literals
body=$'## Task list\n\n- [x] #2 Scaffold: layout, test harness, shellcheck + actionlint CI\n- [x] #3 `lib/version.sh` — one version abstraction, two backends\n- [x] #4 `lib/changelog.sh` — the one canonical section extractor\n- [x] #5 `actions/changelog-armed` — the version-keyed arming guard\n- [x] #6 `actions/changelog-monotonic` — shipped release headings are append-only\n- [x] #7 `actions/drill-recorded` — a release carries its evidence\n- [x] #8 `lib/decide.sh` — the merge door'\''s decision, pure\n- [x] #9 The reusable release workflow — both doors, one implementation\n- [x] #10 Labels machinery: reusable workflow + core/scope split\n- [x] #11 Dogfood: ceremony releases itself (0.1.0) — **shipped: tag `0.1.0`, release, `drills/0.1.0.md`; main re-armed at `0.1.1-dev`**\n- [x] #12 `docs/CONSUMERS.md` + README doctrine\n- [ ] #13 Convert rig (pilot) — **PR [rig#112](https://github.com/heavy-duty/rig/pull/112) is approved by the whole panel on head `3c72c1b` and sits at `state:needs-human` since 2026-07-23 10:47Z; the merge is the human'\''s. #14/#15 unblock when it lands**\n- [ ] #14 Convert box\n- [ ] #15 Convert cast (artifact hook debut)\n- [ ] #16 Adopt in incubator (greenfield consumer)\n\nAdjacent, same repo, separable from the release chain: the **agent team flow** (discussion → triage → issue → build → review → human merge) landed as doctrine in PR #17 (CONTRIBUTING.md, LABELS.md, TRIAGE.md, BUILDER.md, REVIEWER.md); #10'\''s bootstrap carries its labels, #12'\''s guide carries its adoption checklist. Consumption is split by what has a runtime: **machinery by reference** (GitHub materializes pinned workflows/actions at run time), **doctrine as a machine-verified mirror** (`.ceremony/` in each consumer, byte-identical to the pin, CI-guarded — agents read rules from the checkout, never cross-repo):\n\n- [x] #18 Issue-flow reconciliation — the work-queue sweep — **shipped 2026-07-23** in #32 (`66f1c08`)\n- [ ] #61 issueflow-reconcile — cross-repo references must not be read as local issue numbers (found in triage hygiene against the live corpus after #18 shipped; it is why this epic cannot currently be nudged complete)\n- [x] #19 actions/docs-sync — the vendored-doctrine mirror + guard\n- [x] #24 Entry templates — the pipeline'\''s doors made mechanical (from discussion #23)\n- [ ] #50 `needs-ruling` — the pending-human-decision flag (its own epic; from discussion #30)\n- [ ] #56 Fleet scope and cross-repo discovery — the two guards, the runner hole, the roster question (its own epic; from discussion #55, filed at @danmt'\''s request). Children: #57 (BUILDER/REVIEWER/FLEET discovery guards), #58 (`actions/runner-isolated`). Added to this list by triage 2026-07-23 — it is agent-team-flow work like #50, so a scan of this epic must see it.'
check "real epic 1 task list drops rig PR and retains local references" 0 \
  $'2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n18\n19\n23\n24\n30\n32\n50\n55\n56\n57\n58\n61' \
  epic_references <<<"$body"
check "completed epic is nudged" 0 "NUDGE" epic_decision "$epic_refs" $'CLOSED\nCLOSED'
check "open epic child suppresses nudge" 0 "KEEP" epic_decision "$epic_refs" $'CLOSED\nOPEN'
check "epic without parseable children is stable" 0 "KEEP" epic_decision "" ""

# Invariant 1 keeps ignoring the ruling flag (#50 D8): it composes with the
# queue labels and is not one of them.
check "claimed plus a pending ruling is a healthy issue" 0 "KEEP" \
  queue_decision <<< $'claimed\nneeds-ruling'
check "a ruling flag alone is still invariant 1's violation" 0 "ADD_NEEDS_TRIAGE" \
  queue_decision <<< $'needs-ruling'
check "claimed plus offsite is a healthy issue" 0 "KEEP" \
  queue_decision <<< $'claimed\noffsite'
check "offsite alone still needs triage" 0 "ADD_NEEDS_TRIAGE" \
  queue_decision <<<"offsite"
check "claimed plus attention is a healthy issue" 0 "KEEP" \
  queue_decision <<< $'claimed\nattention'
check "ready plus operator is one legal queue state" 0 "KEEP" \
  queue_decision <<< $'ready\noperator'
check "operator alone still has no queue state" 0 "ADD_NEEDS_TRIAGE" \
  queue_decision <<< operator
# shellcheck disable=SC2016 # positional parameters belong to the isolated shell
check "operator is not a queue label" 1 "" \
  bash -c 'printf "%s\n" "$@" | grep -qxF operator' _ "${QUEUE_LABELS[@]}"

# ---------------------------------------------------------------------------
# The ruling pass on the issue surface (#52), against a recording stub: the
# reclaim clock stops under a pending ruling, an applied stale heals off,
# label churn is not activity, the nudge resets on its own comment, and no
# edit anywhere names the flag (#50 D9). The stub serves fixture JSON per
# endpoint with the caller's --jq applied by real jq, appends posted comments
# back into the fixture (a second sweep sees the first one's writes), and
# records every label edit.
# ---------------------------------------------------------------------------
INOW=2000000000
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# gh's own rendering of a 5xx whose body carries a `message` key — the line
# crew#329's job log carried, verbatim (#247), and the payload beside it.
GH_STUB_STDERR="gh: We couldn't respond to your request in time. (HTTP 504)"
GH_STUB_ERROR_BODY='{"message":"We could not respond to your request in time.","documentation_url":"https://docs.github.com/rest"}'
export GH_STUB_STDERR # the PATH-stubbed gh of the executable runs reads it too
# The write-failure sentinel the PATH stub reads (#519). Exported empty so the
# per-call `GH_STUB_WRITE_FAILS=… sweep_run` form below reaches the
# subprocess, which is how GH_STUB_STDERR is already overridden per call.
GH_STUB_WRITE_FAILS=""
export GH_STUB_WRITE_FAILS

issue_stub_gh() {
  # A board write that fails the way the real one does (#519): the glob in
  # ISSUE_STUB_WRITE_FAILS is matched against the whole `gh issue …` argv, and
  # a match speaks on stderr and returns non-zero WITHOUT recording the write
  # — which is exactly what a lost write looks like from the reconciler's
  # side, and what the old commit loop discarded. Reads are never failed here;
  # `.http-error` and `.error` are the read side's sentinels and stay theirs.
  # Unset by default, so every fixture written before this one is untouched.
  if [ "$1" != api ] && [ -n "${ISSUE_STUB_WRITE_FAILS:-}" ]; then
    # shellcheck disable=SC2053 # the sentinel is a glob on purpose
    if [[ "$*" == $ISSUE_STUB_WRITE_FAILS ]]; then
      printf '%s\n' "$GH_STUB_STDERR" >&2
      return 1
    fi
  fi
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
    file="$TMP/$(printf '%s' "$endpoint" | tr '/' '_').json"
    printf '%s\n' "$endpoint" >>"$TMP/api-calls"
    # A `.http-error` sentinel is the real 5xx (#247): `gh api` prints the
    # response body — GitHub's JSON error object — to STDOUT, says why on
    # stderr, and exits non-zero. The `.error` sentinel models a failure with
    # no payload, which is the *safe* path (an empty label set is empty either
    # way), and is why this class was never caught. Both now speak on stderr,
    # because the real gh always does and the reason line renders it.
    if [ -f "$file.http-error" ]; then
      # A --jq call gets the filter applied to the error body, as gh does.
      # That is what "yields no timestamps" looks like — the shape that let
      # last_issue_activity fall back to created_at and reclaim a live claim.
      if [ -n "$jqexpr" ]; then
        jq -r "$jqexpr" "$file.http-error" 2>/dev/null || true
      else
        cat "$file.http-error"
      fi
      printf '%s\n' "$GH_STUB_STDERR" >&2
      return 1
    fi
    [ ! -f "$file.error" ] || { printf '%s\n' "$GH_STUB_STDERR" >&2; return 1; }
    # An absent fixture answers an empty list, and a --jq call gets the filter
    # applied to it — the arrival stub's shape, and gh's. Returning the raw
    # `[]` to a --jq caller made every missing fixture answer a literal `[]`
    # where the real API answers nothing, and `[]` outsorts an ISO-8601
    # timestamp in the C locale but not in a UTF-8 one, so last_issue_activity
    # dated an issue by a stub artifact on the runner and by its created_at
    # here. The old code swallowed the resulting date failure; #247's guards
    # turn it into a skip, which is what made the lie visible.
    local payload='[]'
    [ ! -f "$file" ] || payload="$(cat "$file")"
    if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$payload"; else printf '%s\n' "$payload"; fi
  elif [ "$1" = issue ] && [ "$2" = comment ]; then
    local n="$3" body="" file
    shift 3
    while [ $# -gt 0 ]; do
      case "$1" in --body) body="$2"; shift ;; esac
      shift
    done
    printf '%s\n----\n' "$body" >>"$TMP/posted-$n"
    file="$TMP/$(printf 'repos/%s/issues/%s/comments' "$REPO" "$n" | tr / _).json"
    [ -f "$file" ] || printf '[]\n' >"$file"
    jq --arg b "$body" --arg at "$(iso_at "$INOW")" \
      '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/posted","body":$b}]' \
      "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  elif [ "$1" = issue ] && [ "$2" = edit ]; then
    printf '%s\n' "$*" >>"$TMP/issue-edits"
  fi
}

issue_probe() { # $1 issue, $2 labels, $3 assignees, $4 false|closing|refs, $5 merged PR specs, $6 body
  (
    local assignees="${3:-1}" open_pr="${4:-false}" merged_ref_prs="${5:-}"
    local body="${6:-}" assignee_json='[]' open_pr_records="" spec pr merged_at
    [ "$assignees" -eq 0 ] || assignee_json='[{"login":"owner-bot"}]'
    # `PROBE_NOW` moves the sweep's clock without moving the fixtures — the
    # only way to prove a rule that self-rate-limits on its own comment's
    # timestamp (#254): sweep, then sweep again a day later and watch the
    # nudge stay silent because the comment it posted is now the activity.
    REPO="${PROBE_REPO:-owner/repo}" NOW="${PROBE_NOW:-$INOW}"
    ISSUE_LABELS="$2"
    ISSUE_JSON="$(jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
      --argjson assignees "$assignee_json" --arg body "$body" \
      '{created_at: $at, assignees: $assignees, body: $body}')"
    case "$open_pr" in
      true|closing) open_pr_records="$(printf 'CLOSING\t%s\n' "$1")" ;;
      refs|draft-refs) open_pr_records="$(printf 'BODY\tRefs #%s\n' "$1")" ;;
    esac
    OPEN_PR_ISSUES="$(open_pr_issues <<<"$open_pr_records")"
    # Records are ISSUE<TAB>PR<TAB>MERGED_AT (#242). A spec is `PR` or
    # `PR@<iso>`; the bare form takes a fixed hour-old merge, which is every
    # probe that does not care about merge order. An empty list is no record
    # at all, so the no-merged-PR probes read exactly as they did.
    MERGED_REF_PR_RECORDS="$(
      # shellcheck disable=SC2086 # the spec list is deliberately word-split
      for spec in $merged_ref_prs; do
        pr="${spec%%@*}"
        merged_at="${spec#*@}"
        [ "$merged_at" != "$spec" ] || merged_at="$(iso_at $((INOW - 3600)))"
        printf '%s\t%s\t%s\n' "$1" "$pr" "$merged_at"
      done)"
    run() { "$@"; }
    gh() { issue_stub_gh "$@"; }
    reconcile_issue "$1" 2>&1
  )
}

tfix() { printf '%s/repos_owner_repo_issues_%s_timeline.json' "$TMP" "$1"; }
cfix() { printf '%s/repos_owner_repo_issues_%s_comments.json' "$TMP" "$1"; }

# -- release epics announce an opened declared gate, comment-only (#253) -----
printf '{"state":"closed"}\n' >"$TMP/repos_owner_repo_issues_201.json"
printf '{"state":"closed"}\n' >"$TMP/repos_owner_repo_issues_202.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_203.json"
printf '[]\n' >"$(cfix 53)"
: >"$TMP/issue-edits"
release_init_edits_before="$(wc -l <"$TMP/issue-edits")"
release_init_body=$'Blocked by #201, #202.\n\n## Task list\n- [ ] #203 later work'
release_init="$(issue_probe 53 $'epic\nrelease' 0 false "" "$release_init_body")"
check "a release epic with every declared blocker closed announces init" 0 "" \
  grep -qF '<!-- issueflow:release-init-due -->' "$TMP/posted-53"
check "the init announce names all five steps" 0 "5" \
  grep -cE '^[1-5]\. ' "$TMP/posted-53"
# D6's other string: release-init is where the membership record is first
# written, so step 3 names it beside the waves and the progress task list.
# shellcheck disable=SC2016 # backticks are the comment body's own Markdown
check "step 3 names the membership record it first writes" 0 "" \
  grep -qF '3. Write ordered waves, the `## Members` record' "$TMP/posted-53"
# shellcheck disable=SC2016 # backticks are the literal portable doctrine citation
check "the init announce cites the portable vendored doctrine path" 0 "" \
  grep -qF 'See `.ceremony/RELEASES.md`.' "$TMP/posted-53"
check "the init announce names the never-automated operator blessing" 0 "" \
  grep -qF 'operator blessing the order is the one step this chain never automates' \
  "$TMP/posted-53"
check "the opened release gate is logged" 0 "" \
  grep -qF '#53: release-init due' <<<"$release_init"
release_init_gate_reads_before_repeat="$(
  grep -cE 'repos/owner/repo/issues/(201|202)$' "$TMP/api-calls"
)"
issue_probe 53 $'epic\nrelease' 0 false "" "$release_init_body" >/dev/null
check "an unchanged opened gate announces only once" 0 "1" \
  grep -cF '<!-- issueflow:release-init-due -->' "$TMP/posted-53"
check "an announced gate does not re-read its durable blockers" 0 \
  "$release_init_gate_reads_before_repeat" \
  grep -cE 'repos/owner/repo/issues/(201|202)$' "$TMP/api-calls"

printf '{"state":"closed"}\n' >"$TMP/repos_heavy-duty_ceremony_issues_201.json"
printf '{"state":"closed"}\n' >"$TMP/repos_heavy-duty_ceremony_issues_202.json"
printf '[]\n' >"$TMP/repos_heavy-duty_ceremony_issues_53_comments.json"
PROBE_REPO=heavy-duty/ceremony \
  issue_probe 53 $'epic\nrelease' 0 false "" "$release_init_body" >/dev/null
# shellcheck disable=SC2016 # backticks are the literal dogfood doctrine citation
check "the ceremony dogfood announce cites its root doctrine path" 0 "" \
  grep -qF 'See `RELEASES.md`.' "$TMP/posted-53"

printf '[]\n' >"$(cfix 54)"
issue_probe 54 $'epic\nrelease' 0 false "" \
  $'Blocked by #203.\n\n## Task list\n- [x] #201 complete' >/dev/null
check "an open declared blocker suppresses init despite a complete task list" 1 "" \
  grep -qF '<!-- issueflow:release-init-due -->' "$TMP/posted-54"
check "the independent epic-complete nudge still fires" 0 "" \
  grep -qF '<!-- issueflow:epic-complete -->' "$TMP/posted-54"

printf '[]\n' >"$(cfix 55)"
issue_probe 55 $'epic\nrelease' 0 false "" \
  $'Blocked by #201.\n\n## Task list\n- [x] #202 complete' >/dev/null
check "release-init and epic-complete can coexist" 0 "2" \
  grep -c -- '^----$' "$TMP/posted-55"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the coexisting comments keep distinct markers" 0 "" \
  bash -c 'grep -qF "<!-- issueflow:release-init-due -->" "$1" && grep -qF "<!-- issueflow:epic-complete -->" "$1"' \
  _ "$TMP/posted-55"

for n in 56 57 58 59; do printf '[]\n' >"$(cfix "$n")"; done
issue_probe 56 $'epic\nrelease' 0 false "" 'No dependency declaration.' >/dev/null
check "a release epic without a Blocked by declaration stays silent" 1 "" \
  test -f "$TMP/posted-56"
issue_probe 57 $'epic\nrelease' 0 false "" 'Blocked by heavy-duty/rig#9.' >/dev/null
check "a cross-repo release gate stays silent" 1 "" test -f "$TMP/posted-57"
issue_probe 58 $'epic\nrelease' 0 false "" 'Blocked by #204.' >/dev/null
check "an unreadable release gate stays silent" 1 "" test -f "$TMP/posted-58"
: >"$TMP/api-calls"
issue_probe 59 epic 0 false "" 'Blocked by #201.' >/dev/null
check "a plain epic does not parse or announce a release gate" 1 "" \
  test -f "$TMP/posted-59"
check "a plain epic pays no Blocked by reference read" 1 "" \
  grep -qF 'repos/owner/repo/issues/201' "$TMP/api-calls"

printf '[]\n' >"$(cfix 60)"
issue_probe 60 $'ready\nrelease' 0 false "" 'Blocked by #201.' >/dev/null
check "a non-epic release issue does not announce init" 1 "" \
  test -f "$TMP/posted-60"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "every release-init probe is comment-only" 0 "$release_init_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- malformed attention targets are diagnosed, never repaired (#232) -------
attention_episode() { # $1 issue, $2 labeled timestamp
  jq -n --arg at "$2" \
    '[{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
    >"$(tfix "$1")"
  printf '[]\n' >"$(cfix "$1")"
}

: >"$TMP/issue-edits"
attention_edits_before="$(wc -l <"$TMP/issue-edits")"
for n in 61 62 63; do
  attention_episode "$n" "$(iso_at $((INOW - 60)))"
done

# The assignment event is the claim clock's own activity fact. The live issue
# has since lost its assignee, which is exactly the claimed-unassigned shape.
jq --arg at "$(iso_at $((INOW - 60)))" \
  '. + [{"event":"assigned","created_at":$at}]' \
  "$(tfix 63)" >"$(tfix 63).tmp" && mv "$(tfix 63).tmp" "$(tfix 63)"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_999.json"

issue_probe 61 $'ready\nattention' 0 >/dev/null
check "unassigned attention under ready is diagnosed once" 0 "1" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-61"

issue_probe 62 $'blocked\nattention' 0 false "" 'Blocked by #999' >/dev/null
check "unassigned attention under blocked is diagnosed once" 0 "1" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-62"

claimed_attention="$(issue_probe 63 $'claimed\nattention' 0)"
check "claimed-unassigned owns the only board comment" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-63"
check "the claimed-unassigned marker, not attention's, was posted" 0 "1" \
  grep -cF '<!-- issueflow:claimed-unassigned -->' "$TMP/posted-63"
check "the suppressed attention detection remains in the log" 0 "1" \
  grep -cF 'comment suppressed by claimed-unassigned precedence' <<<"$claimed_attention"

attention_episode 64 "$(iso_at $((INOW - 60)))"
issue_probe 64 $'ready\nattention' 1 >/dev/null
check "assigned attention under ready is healthy" 1 "" test -f "$TMP/posted-64"
attention_episode 65 "$(iso_at $((INOW - 60)))"
issue_probe 65 $'claimed\nattention' 1 true >/dev/null
check "assigned attention under claimed is healthy" 1 "" test -f "$TMP/posted-65"
attention_episode 66 "$(iso_at $((INOW - 60)))"
issue_probe 66 $'blocked\nattention' 1 false "" 'Blocked by #999' >/dev/null
# A `blocked` issue now always carries one comment — the parse echo (#252) —
# so "healthy" can no longer be spelled "no comment file at all". It is spelled
# the way this section's other cases already spell it: no attention diagnostic.
# Both halves are pinned, so the case still fails if an attention comment
# appears beside the echo, or if a second comment of any kind does.
check "assigned attention under blocked is healthy" 1 "" \
  grep -qF '<!-- ceremony:attention-malformed:' "$TMP/posted-66"
check "...drawing the #252 parse echo and nothing else" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-66"

attention_episode 67 "$(iso_at $((INOW - 60)))"
# Recent activity keeps the evidence nudge (#254) off this probe: it is a
# precedence case, and "exactly one comment" is the assertion doing the work.
# The nudge's own coexistence with the post-merge diagnostic is pinned in its
# section below, on a probe that is quiet on purpose.
jq -n --arg at "$(iso_at $((INOW - 60)))" \
  '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c67","body":"still waiting on the tag"}]' \
  >"$(cfix 67)"
post_merge_attention="$(issue_probe 67 $'post-merge\nattention' 0)"
check "post-merge precedence leaves exactly its existing comment" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-67"
check "post-merge's existing diagnostic wins" 0 "1" \
  grep -cF '<!-- issueflow:post-merge-assigned -->' "$TMP/posted-67"
check "the post-merge suppression remains in the log" 0 "1" \
  grep -cF 'comment suppressed by post-merge-assigned precedence' <<<"$post_merge_attention"

attention_episode 68 "$(iso_at $((INOW - 120)))"
issue_probe 68 $'ready\nattention' 0 >/dev/null
issue_probe 68 $'ready\nattention' 0 >/dev/null
check "two sweeps in one malformed episode post once" 0 "1" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-68"
jq --arg at "$(iso_at $((INOW - 30)))" \
  '. + [{"event":"labeled","label":{"name":"attention"},"actor":{"login":"setter"},"created_at":$at}]' \
  "$(tfix 68)" >"$(tfix 68).tmp" && mv "$(tfix 68).tmp" "$(tfix 68)"
issue_probe 68 $'ready\nattention' 0 >/dev/null
check "a re-set flag creates a second episode comment" 0 "2" \
  grep -cF '<!-- ceremony:attention-malformed:' "$TMP/posted-68"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the two comments carry distinct episode markers" 0 "2" \
  bash -c 'grep -F "<!-- ceremony:attention-malformed:" "$1" | sort -u | wc -l' _ \
  "$TMP/posted-68"

: >"$(tfix 69).error"
printf '[]\n' >"$(cfix 69)"
unreadable_attention="$(issue_probe 69 $'ready\nattention' 0)"
check "an unreadable attention timeline posts nothing" 1 "" test -f "$TMP/posted-69"
check "the unreadable fact is visible in the log" 0 "1" \
  grep -cF 'attention timeline unreadable' <<<"$unreadable_attention"

: >"$TMP/api-calls"
printf '[]\n' >"$(tfix 70)"
printf '[]\n' >"$(cfix 70)"
issue_probe 70 ready 0 >/dev/null
check "a flag-free issue performs no attention episode read" 1 "" \
  grep -qF 'repos/owner/repo/issues/70/timeline' "$TMP/api-calls"

# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the attention sweep probes perform no issue edits" 0 "$attention_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- the reclaim clock stops under a pending ruling (48h quiet, no PR) -------
jq -n --arg l "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l},
    {"event":"assigned","created_at":$l}]' >"$(tfix 21)"
# The escalation is conforming and the rung markers are pre-seeded — by 10
# days in both rungs fired long ago (#73), so this probe observes the nudge
# wiring alone; shape and rung behavior have their own probes in
# test/ruling.test.sh.
jq -n --arg at "$(iso_at $((INOW - 10 * 86400 - 60)))" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
  --arg r12 "$(iso_at $((INOW - 10 * 86400 + 13 * 3600)))" \
  --arg r24 "$(iso_at $((INOW - 10 * 86400 + 25 * 3600)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc21","body":$b},
    {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
  >"$(cfix 21)"
exempt="$(issue_probe 21 $'claimed\nneeds-ruling')"
check "a 10-day-quiet claim under a ruling is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$exempt"
check "...the same silence still nudges the pending ruling" 0 "" \
  grep -q 'ruling nudge' <<<"$exempt"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "...and the nudge went to the decider with the escalation linked" 0 "" \
  bash -c 'grep -qF "@danmt" "$1" && grep -qF "https://x/esc21" "$1"' _ "$TMP/posted-21"
again="$(issue_probe 21 $'claimed\nneeds-ruling')"
check "the sweep right after the nudge holds its silence" 1 "" \
  grep -q 'ruling nudge' <<<"$again"
check "exactly one nudge across both sweeps" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-21"

# -- control: the same silence without the flag is reclaimed -----------------
jq -n --arg l "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"assigned","created_at":$l}]' >"$(tfix 22)"
printf '[]\n' >"$(cfix 22)"
control="$(issue_probe 22 claimed)"
check "the flag-free control is reclaimed (the clock still runs elsewhere)" 0 "" \
  grep -q 'stale claim reclaimed -> ready' <<<"$control"

# -- merged Refs work releases the claim before the reclaim clock ------------
printf '[]\n' >"$(cfix 35)"
COLLISION_FLAGS=$'35\tissueflow-reconcile=34'
WINDOW_FLAGS=$'35\t#50'
transition="$(issue_probe 35 claimed 1 false 350 $'- [x] built\n- [ ] verify dispatch\n  * [ ] confirm warning clears')"
unset COLLISION_FLAGS WINDOW_FLAGS
check "merged Refs + unchecked criteria transitions in the sweep body" 0 "" \
  grep -q 'merged Refs PR -> post-merge; claim released' <<<"$transition"
check "a pass concluding post-merge draws no precomputed collision flag" 1 "" \
  grep -q 'collision flag' <<<"$transition"
check "...and no precomputed window flag" 1 "" \
  grep -q 'window flag' <<<"$transition"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...names every remaining criterion verbatim in the comment" 0 "" \
  bash -c 'grep -qF -- "- [ ] verify dispatch" "$1" &&
    grep -qF -- "  * [ ] confirm warning clears" "$1"' _ "$TMP/posted-35"
check "...states triage owes completion with owner and wake condition" 0 "" \
  grep -qF 'Triage owes completion in a follow-up comment that names the owner and wake condition.' \
  "$TMP/posted-35"
check "...unassigns and swaps claimed to post-merge" 0 "" \
  grep -qF -- '--remove-assignee owner-bot --remove-label claimed --add-label post-merge' \
  "$TMP/issue-edits"

printf '[]\n' >"$(cfix 36)"
post_merge_quiet="$(issue_probe 36 post-merge 0)"
check "quiet unassigned post-merge work is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$post_merge_quiet"
# The quiet itself is now visible (#254) — this probe is 10 days old with no
# activity, so it draws the evidence nudge and nothing else. It used to
# assert no comment at all; that assertion described the starvation this
# issue exists to end, and the edit half of it is what still matters.
check "...and causes no edit" 1 "" grep -qF -- 'issue edit 36' "$TMP/issue-edits"
check "...only the evidence nudge speaks" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-36"

printf '[]\n' >"$(cfix 37)"
# The live shape of an assigned `post-merge` issue: the assignee in the issue
# payload AND the `assigned` event that put it there in the timeline. With an
# empty timeline this fixture could not see the defect it exists to guard —
# the evidence clock counting that hour-old assignment as activity and
# silencing the nudge for another 7 days, on the one board state where an
# assignee is itself the bug being reported.
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 37)"
issue_probe 37 post-merge 1 >/dev/null
check "assigned post-merge is flagged" 0 "" \
  grep -qF '<!-- issueflow:post-merge-assigned -->' "$TMP/posted-37"
check "...and the hand-assignment is not repaired" 1 "" \
  grep -qF -- 'issue edit 37' "$TMP/issue-edits"
# The flag and the nudge answer different questions — a board bug and a
# starved wake condition — so neither suppresses the other (#254).
check "...and the evidence nudge rides beside it, neither suppressed" 0 "2" \
  grep -c -- '^----$' "$TMP/posted-37"

# -- the post-merge evidence nudge (#254), the ruling nudge's twin ----------
# The ruling nudge solved "a wait goes quiet and nobody is told" for
# `needs-ruling`; `post-merge` had no equivalent, and crew#181's real-host
# criterion starved four times across two releases for want of one. Same
# 7-day constant (`ruling_nudge_decision`, reused not mirrored), same
# deliberate absence of an idempotency marker, and — unlike the ruling
# nudge — addressed to the triage actor, because `post-merge` is triage's
# completion queue and the operator owes nothing here (#254 D1).
nudge_edits_before="$(wc -l <"$TMP/issue-edits")"

quiet_comment() { # $1 issue, $2 seconds of quiet — one ordinary comment, then silence
  jq -n --arg at "$(iso_at $((INOW - $2)))" \
    '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c","body":"evidence pending"}]' \
    >"$(cfix "$1")"
  printf '[]\n' >"$(tfix "$1")"
}

quiet_comment 80 $((8 * 86400))
nudged="$(issue_probe 80 post-merge 0)"
check "8 quiet days on a post-merge item draws the evidence nudge" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$nudged"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "...addressed to the triage actor, never the human reviewer" 0 "" \
  bash -c 'grep -qF "@triage-one" "$1" && ! grep -qF "@danmt" "$1"' _ "$TMP/posted-80"
check "...with the issue link as the payload" 0 "" \
  grep -qF 'https://github.com/owner/repo/issues/80' "$TMP/posted-80"
check "...carrying the do-not-add-a-marker warning in the comment" 0 "" \
  grep -qF 'Do not add a marker.' "$TMP/posted-80"
# Asserted directly, not merely omitted: a marker would turn "once per 7
# quiet days" into "once per issue, forever" — the exact "fix" lib/ruling.sh's
# header records as the thing that breaks this rule.
check "...and no idempotency marker on the path" 1 "" \
  grep -qF '<!-- issueflow:' "$TMP/posted-80"

# Self-rate-limiting, proven by the property and not by the mechanism: sweep
# again a day later, against fixtures the first sweep's own comment mutated.
nudged_again="$(PROBE_NOW=$((INOW + 86400)) issue_probe 80 post-merge 0)"
check "a sweep one day after the nudge holds its silence" 1 "" \
  grep -q 'post-merge evidence nudge' <<<"$nudged_again"
check "...so exactly one nudge exists across both sweeps" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-80"

quiet_comment 81 $((6 * 86400))
six_days="$(issue_probe 81 post-merge 0)"
check "6 quiet days is inside the window and draws nothing" 1 "" \
  grep -q 'post-merge evidence nudge' <<<"$six_days"
check "...and posts no comment at all" 1 "" test -f "$TMP/posted-81"

# Label churn is not activity, or the sweep resets its own clock. The rule is
# `last_issue_activity`'s, shared with the reclaim and ruling clocks rather
# than restated here — this probe pins that the nudge inherits it.
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"labeled","label":{"name":"scope:docs"},"created_at":$at},
    {"event":"unlabeled","label":{"name":"scope:docs"},"created_at":$at}]' >"$(tfix 82)"
printf '[]\n' >"$(cfix 82)"
churn="$(issue_probe 82 post-merge 0)"
check "an hour-old label churn does not reset the 7-day clock" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$churn"

quiet_comment 83 3600
fresh="$(issue_probe 83 post-merge 0)"
check "an hour-old comment does reset it" 1 "" \
  grep -q 'post-merge evidence nudge' <<<"$fresh"

# Neither is an assignment. That event is the *claim* clock's activity fact —
# 48 hours of silence must not include the seconds between a claim and its
# required draft PR — and `post-merge` has no claim for it to protect: an
# assignee here is the invalid composition the flag above reports. Counting
# it would let a broken board buy the item another 7 days of quiet, which is
# this issue's failure direction taken backwards. No current assignee on this
# probe, so nothing stands between the clock rule and the nudge.
quiet_comment 93 $((8 * 86400))
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at},{"event":"unassigned","created_at":$at}]' >"$(tfix 93)"
assigned_clock="$(issue_probe 93 post-merge 0)"
check "an hour-old assignment does not reset the evidence clock either" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$assigned_clock"

# The two clocks over the one computation, asserted directly rather than
# through a probe: same fixture, one input's difference, and the reclaim
# clock is pinned unmoved by the split.
jq -n --arg at "$(iso_at $((INOW - 5 * 86400)))" \
  '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c95","body":"evidence pending"}]' \
  >"$(cfix 95)"
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 95)"
two_clocks="$( (REPO=owner/repo; gh() { issue_stub_gh "$@"; }
  printf '%s %s\n' \
    "$(last_issue_activity 95 "$(iso_at $((INOW - 10 * 86400)))")" \
    "$(last_issue_comment_activity 95 "$(iso_at $((INOW - 10 * 86400)))")") )"
check "the claim clock counts the assignment, the evidence clock the comment" 0 \
  "$((INOW - 3600)) $((INOW - 5 * 86400))" printf '%s\n' "$two_clocks"
# One body, two callers: a second activity computation is the drift the
# reuse exists to prevent, so the timeline read has exactly one spelling.
# shellcheck disable=SC2016 # the read is asserted as a literal, unexpanded
check "the timeline read is not respelled for the evidence clock" 0 "1" \
  grep -c 'issues/\$n/timeline' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# Both waits are quiet, both are owed, and to different parties: suppressing
# one because the other spoke is a starved criterion, which is the failure
# this nudge exists to remove.
jq -n --arg l "$(iso_at $((INOW - 9 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l}]' \
  >"$(tfix 84)"
jq -n --arg at "$(iso_at $((INOW - 9 * 86400 - 60)))" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
  --arg r12 "$(iso_at $((INOW - 9 * 86400 + 13 * 3600)))" \
  --arg r24 "$(iso_at $((INOW - 9 * 86400 + 25 * 3600)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc84","body":$b},
    {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
  >"$(cfix 84)"
both="$(issue_probe 84 $'post-merge\nneeds-ruling' 0)"
check "a quiet post-merge item under a pending ruling nudges both waits" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$both"
check "...and the ruling nudge is not suppressed by it" 0 "" \
  grep -q 'ruling nudge' <<<"$both"
# shellcheck disable=SC2016 # expansions belong to the isolated bash -c process
check "...each addressing its own party" 0 "" \
  bash -c 'grep -qF "@triage-one" "$1" && grep -qF "@danmt" "$1"' _ "$TMP/posted-84"

# Every other queue state: the nudge is `post-merge`'s alone. Each is equally
# quiet, and `claimed` carries an open PR so its own reclaim clock — the one
# other 10-day rule on this path — stays out of the way.
non_post_merge=(85:ready:0:false 86:claimed:1:true 87:blocked:0:false 88:epic:0:false 89:needs-triage:0:false)
for spec in "${non_post_merge[@]}"; do
  IFS=: read -r n state probe_assignees probe_pr <<<"$spec"
  printf '[]\n' >"$(cfix "$n")"
  printf '[]\n' >"$(tfix "$n")"
  check "a 10-day-quiet $state issue draws no evidence nudge" 1 "" \
    grep -q 'post-merge evidence nudge' \
    <<<"$(issue_probe "$n" "$state" "$probe_assignees" "$probe_pr")"
done

# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the pre-operator evidence-nudge probes perform no issue edits" 0 "$nudge_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- the operator-owned work nudge (#491), on the same quiet clock ----------
operator_edits_before="$(wc -l <"$TMP/issue-edits")"
quiet_comment 491 $((8 * 86400))
operator_nudged="$(issue_probe 491 $'ready\noperator' 0)"
check "ready plus operator stays legal through the reconcile body" 1 "" \
  grep -q 'needs-triage\|conflicting queue labels' <<<"$operator_nudged"
check "8 quiet days on operator-owned work draws its nudge" 0 "" \
  grep -q 'operator work nudge' <<<"$operator_nudged"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the operator nudge addresses the operator and links the issue" 0 "" \
  bash -c 'grep -qF "@danmt" "$1" && grep -qF "https://github.com/owner/repo/issues/491" "$1"' \
    _ "$TMP/posted-491"
check "the operator nudge names the body contract without parsing it" 0 "" \
  grep -qF 'evidence surface and command or observation' "$TMP/posted-491"
check "the operator nudge carries no idempotency marker" 1 "" \
  grep -qF '<!-- issueflow:' "$TMP/posted-491"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the operator nudge writes no label" 0 "$operator_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

operator_again="$(PROBE_NOW=$((INOW + 86400)) issue_probe 491 $'ready\noperator' 0)"
check "the sweep one day after an operator nudge stays silent" 1 "" \
  grep -q 'operator work nudge' <<<"$operator_again"
check "the operator nudge self-rate-limits to one comment" 0 "1" \
  grep -c -- '^----$' "$TMP/posted-491"

quiet_comment 492 $((8 * 86400))
plain_ready="$(issue_probe 492 ready 0)"
check "a plain ready issue of the same age draws no operator nudge" 1 "" \
  grep -q 'operator work nudge' <<<"$plain_ready"
check "the plain ready control posts no comment" 1 "" test -f "$TMP/posted-492"

quiet_comment 493 3600
fresh_operator="$(issue_probe 493 $'ready\noperator' 0)"
check "a fresh issue comment resets the operator clock" 1 "" \
  grep -q 'operator work nudge' <<<"$fresh_operator"

# D9's additive proof: each required queue shape runs twice from identical
# fixtures. The operator half may add its own nudge, but every other decision
# trace and every label write must remain byte-identical — ownership is a
# second axis and cannot move the queue (#491).
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_999.json"
additive_effects() { # $1 issue, $2 labels, $3 assignees, $4 open-pr, $5 body
  local n="$1" labels="$2" assignees="$3" open_pr="$4" body="$5"
  local base_trace operator_trace base_edits operator_edits
  printf '[]\n' >"$(cfix "$n")"
  printf '[]\n' >"$(tfix "$n")"
  : >"$TMP/issue-edits"
  base_trace="$(issue_probe "$n" "$labels" "$assignees" "$open_pr" "" "$body")"
  base_edits="$(cat "$TMP/issue-edits")"
  rm -f "$TMP/posted-$n"
  printf '[]\n' >"$(cfix "$n")"
  printf '[]\n' >"$(tfix "$n")"
  : >"$TMP/issue-edits"
  operator_trace="$(issue_probe "$n" "$labels"$'\noperator' "$assignees" "$open_pr" "" "$body" \
    | sed '/operator work nudge/d')"
  operator_edits="$(cat "$TMP/issue-edits")"
  [ "$base_trace" = "$operator_trace" ] && [ "$base_edits" = "$operator_edits" ]
}

check "operator preserves ready decisions and label writes" 0 "" \
  additive_effects 500 ready 0 false ""
check "operator preserves a stale claimed reclaim" 0 "" \
  additive_effects 501 claimed 1 false ""
check "operator preserves parseable blocked behavior" 0 "" \
  additive_effects 502 blocked 0 false 'Blocked by #999.'
check "operator preserves unparseable blocked behavior" 0 "" \
  additive_effects 503 blocked 0 false 'waiting, with no declaration'
check "operator preserves epic behavior" 0 "" \
  additive_effects 504 epic 0 false $'## Task list\n- [ ] #999'
check "operator preserves post-merge behavior past 7 quiet days" 0 "" \
  additive_effects 505 post-merge 0 false ""
check "operator preserves needs-triage behavior" 0 "" \
  additive_effects 506 needs-triage 0 false ""

builder_pick="$(sed -n '/Pick from issues labeled/,/Inside an epic take/p' "$ROOT/BUILDER.md")"
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the builder picking sentence refuses operator beside epic" 0 "" \
  bash -c 'grep -qF "never \`blocked\`, \`claimed\`, \`operator\`," <<<"$1" && grep -qF "or an \`epic\`" <<<"$1"' \
    _ "$builder_pick"
check "triage marks only an all-operator-owned criterion set" 0 "" \
  grep -qF 'When every acceptance criterion is operator-owned at mint' "$ROOT/TRIAGE.md"
check "triage keeps a mixed-reach issue on the criterion mechanism" 0 "" \
  grep -qF 'A single operator-owned criterion among' "$ROOT/TRIAGE.md"

# The additive corpus deliberately exercises label writes (notably stale
# claim reclamation). Start a fresh recorder for the remaining post-merge
# no-write probes; the earlier half was checked immediately above.
: >"$TMP/issue-edits"
nudge_edits_before=0

# The machine never judges prose: which criterion starved is not a fact the
# sweep reads, so a body it could not parse if it tried still nudges.
quiet_comment 90 $((8 * 86400))
unparseable_body="$(issue_probe 90 post-merge 0 false "" '¯\_(ツ)_/¯ wake: ask danmt sometime')"
check "an unparseable body still nudges — the link is the payload" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$unparseable_body"
check "...and the nudge quotes none of it" 1 "" \
  grep -qF 'ask danmt sometime' "$TMP/posted-90"

# One spelling of the 7-day rule. `lib/ruling.sh` exists because this family
# already paid for two copies of a constant; a second one here is the drift,
# and it is cheap to pin at the grep level.
# Code lines only: the branch's comment names the constant it must not
# respell, which is the sentence a future reader needs and not a second copy.
check "the 7-day rule is not respelled in the sweep" 1 "" \
  grep -nE '^[^#]*(7 \* 24 \* 3600|604800)' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # the call site is asserted as a literal
check "...it is reused from lib/ruling.sh" 0 "" \
  grep -qF 'ruling_nudge_decision "$NOW" "$evidence_age"' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# `post-merge` is the one queue state whose whole meaning is that the machine
# owes nothing (LABELS.md: the sweep never reclaims it). This issue makes the
# quiet visible; it must never make it actionable.
# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the evidence-nudge probes perform no issue edits" 0 "$nudge_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- the issue-side ruling clock is comments-only (#284) ---------------------
# #52 D10's "reuse the activity computation" made the issue-side ruling nudge
# ride the claim-reclamation clock, `assigned` events included — so claiming
# a flagged issue dated it, and the escalation the flag exists to keep
# visible went quiet for another 7 days at exactly the moment somebody
# started working through it. The ruling clock is now the comments-only one
# (D1); the reclaim clock keeps the assignment (D2), because there the
# assignment IS the claim. Every must-nudge probe below was run against the
# pre-#284 sweep and went red — the #274 round-1 discipline: the fixture
# proves the defect, not merely the fix.
ruling_clock_edits_before="$(wc -l <"$TMP/issue-edits")"
ruling_quiet() { # $1 issue — conforming escalation, both rungs fired, ~9d of comment quiet
  jq -n --arg l "$(iso_at $((INOW - 10 * 86400)))" \
    '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l}]' \
    >"$(tfix "$1")"
  jq -n --arg at "$(iso_at $((INOW - 10 * 86400 - 60)))" \
    --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  none — hard block' \
    --arg r12 "$(iso_at $((INOW - 10 * 86400 + 13 * 3600)))" \
    --arg r24 "$(iso_at $((INOW - 10 * 86400 + 25 * 3600)))" \
    '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc","body":$b},
      {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
      {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
    >"$(cfix "$1")"
}
timeline_add() { # $1 issue, $2 event, $3 seconds ago
  jq --arg e "$2" --arg at "$(iso_at $((INOW - $3)))" \
    '. + [{"event":$e,"created_at":$at}]' \
    "$(tfix "$1")" >"$(tfix "$1").tmp" && mv "$(tfix "$1").tmp" "$(tfix "$1")"
}
comment_add() { # $1 issue, $2 seconds ago
  jq --arg at "$(iso_at $((INOW - $2)))" \
    '. + [{"user":{"login":"decider"},"created_at":$at,"html_url":"https://x/d","body":"still thinking"}]' \
    "$(cfix "$1")" >"$(cfix "$1").tmp" && mv "$(cfix "$1").tmp" "$(cfix "$1")"
}

# The live shape, and the defect: a builder claims the flagged issue, the
# assignment is an hour old, the decider has been silent ~9 days.
ruling_quiet 101
timeline_add 101 assigned 3600
claimed_fresh="$(issue_probe 101 $'claimed\nneeds-ruling' 1 true)"
check "an hour-old claim does not silence a ruling 9 days quiet" 0 "" \
  grep -q 'ruling nudge' <<<"$claimed_fresh"
check "...and the fresh assignment is not reclaim bait either" 1 "" \
  grep -q 'reclaimed' <<<"$claimed_fresh"

# The claimed branch's top read, pinned. `claimed` + `needs-ruling` with no
# assignee is the one composition where this branch posts BEFORE the ruling
# block: `claim_decision` returns FLAG_UNASSIGNED and the
# `claimed-unassigned` comment goes out, so a ruling clock read down there
# would date the issue by the sweep's own writing and buy the escalation
# another 7 quiet days — the #274 hazard, on the very branch #284 D6 exists
# to hold. Probe 101 does not reach it: it carries an assignee and an open
# PR. One sweep, both outputs — the board diagnostic and the nudge it must
# not silence — because asserting only the nudge would pass with the
# diagnostic silently gone. Reds the moment the top read drifts below the
# post, and the deletion of that read is what proved it (#284 D6, #307).
ruling_quiet 110
timeline_add 110 assigned 3600
unassigned_flag="$(issue_probe 110 $'claimed\nneeds-ruling' 0 false)"
check "an unassigned claim under a ruling still draws its board flag" 0 "1" \
  grep -cF '<!-- issueflow:claimed-unassigned -->' "$TMP/posted-110"
check "...and the ruling nudge fires beside it, undated by it" 0 "" \
  grep -q 'ruling nudge' <<<"$unassigned_flag"

# The clock rule alone, no assignee in the way: an assigned/unassigned pair
# in the timeline is the claim's history, not activity toward the ruling.
ruling_quiet 102
timeline_add 102 assigned 3600
timeline_add 102 unassigned 3500
ready_pair="$(issue_probe 102 $'ready\nneeds-ruling' 0)"
check "a ready issue nudges through an hour-old assignment pair" 0 "" \
  grep -q 'ruling nudge' <<<"$ready_pair"

# post-merge + needs-ruling fires BOTH nudges in one sweep, from one read
# taken before either write. This probe is also the read-order pin: the
# evidence nudge posts first and the stub stamps it as fresh activity, so
# restoring a ruling-clock read below `ensure_comment` turns the second
# check red — the hazard #274 met and killed inside one round.
ruling_quiet 103
timeline_add 103 assigned 3600
timeline_add 103 unassigned 3500
both_fresh="$(issue_probe 103 $'post-merge\nneeds-ruling' 0)"
check "a fresh assignment starves neither post-merge wait" 0 "" \
  grep -q 'post-merge evidence nudge' <<<"$both_fresh"
check "...the ruling nudge fires beside it, not behind it" 0 "" \
  grep -q 'ruling nudge' <<<"$both_fresh"

# blocked composes the same way. The #252 parse echo is pre-seeded old so
# the probe isolates the clock rule — steady state, where the echo for this
# parse set already exists and the branch posts nothing before the tail.
ruling_quiet 104
timeline_add 104 assigned 3600
refs_104="$(blocked_references <<<'Blocked by #999.')"
cross_104="$(blocked_cross_references <<<'Blocked by #999.')"
marker_104="$(blocked_parse_marker "$(blocked_parse_set "$refs_104" "$cross_104")")"
jq --arg m "$marker_104" --arg at "$(iso_at $((INOW - 9 * 86400)))" \
  '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/echo","body":("<!-- issueflow:" + $m + " -->\necho")}]' \
  "$(cfix 104)" >"$(cfix 104).tmp" && mv "$(cfix 104).tmp" "$(cfix 104)"
blocked_fresh="$(issue_probe 104 $'blocked\nneeds-ruling' 0 false "" 'Blocked by #999.')"
check "a blocked issue nudges through an hour-old assignment" 0 "" \
  grep -q 'ruling nudge' <<<"$blocked_fresh"

# 6 days of comment quiet is 6, with or without an assignment inside it.
ruling_quiet 105
timeline_add 105 assigned 3600
comment_add 105 $((6 * 86400))
six_days="$(issue_probe 105 $'claimed\nneeds-ruling' 1 true)"
check "6 days of comment quiet draws no nudge" 1 "" \
  grep -q 'ruling nudge' <<<"$six_days"

# Label churn is not activity on this clock either — it reads no timeline
# at all, which closes the class rather than the spelling.
ruling_quiet 106
timeline_add 106 labeled 1800
timeline_add 106 unlabeled 1700
churn="$(issue_probe 106 $'ready\nneeds-ruling' 0)"
check "hour-old label churn does not hold the nudge back" 0 "" \
  grep -q 'ruling nudge' <<<"$churn"

# Self-rate-limiting, asserted as the property (#254's discipline): sweep
# again a day after probe 101's nudge and the nudge it posted is the
# activity that keeps it silent — no marker involved.
day_after="$(PROBE_NOW=$((INOW + 86400)) issue_probe 101 $'claimed\nneeds-ruling' 1 true)"
check "the sweep a day after its nudge holds its silence" 1 "" \
  grep -q 'ruling nudge' <<<"$day_after"

# No flag, no nudge, whatever the clock says.
quiet_comment 107 $((60 * 86400))
noflag="$(issue_probe 107 ready 0)"
check "an unflagged issue draws no ruling nudge at any age" 1 "" \
  grep -q 'ruling nudge' <<<"$noflag"

# D2's input doing its job — the one thing a "the clocks are the same now,
# merge them" refactor would break. Red the instant `last_issue_activity`
# loses `assigned`.
printf '[]\n' >"$(cfix 108)"
jq -n --arg at "$(iso_at $((INOW - 600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 108)"
not_reclaimed="$(issue_probe 108 claimed 1 false)"
check "a 10-minute-old claim on a silent issue is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$not_reclaimed"

# One fixture, two clocks, asserted directly and not by inspection: the
# newest event is the assignment; the reclaim clock returns it and the
# ruling clock returns the older comment.
jq -n --arg at "$(iso_at $((INOW - 8 * 86400)))" \
  '[{"user":{"login":"decider"},"created_at":$at,"html_url":"https://x/c9","body":"x"}]' >"$(cfix 109)"
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 109)"
clock_read() { # $1 clock fn — both against fixture 109
  ( REPO=owner/repo
    # shellcheck disable=SC2317 # reached indirectly, through the clock under test
    gh() { issue_stub_gh "$@"; }
    "$1" 109 "$(iso_at $((INOW - 10 * 86400)))" )
}
check "one fixture, two clocks: the reclaim clock returns the assignment" \
  0 "$((INOW - 3600))" clock_read last_issue_activity
check "...and the ruling clock returns the older comment" \
  0 "$((INOW - 8 * 86400))" clock_read last_issue_comment_activity

# The mechanical call-site pins: the reclaim clock can never reach
# reconcile_ruling, on any path, asserted against the source and not the
# diff. Beside them, the one-spelling pins this issue inherits stay green.
# shellcheck disable=SC2016 # the call sites are asserted as literals
check "reconcile_ruling is never handed the reclaim clock" 1 "" \
  grep -E '^[^#]*reconcile_ruling.*\$age' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # the call site is asserted as a literal
check "...its one call site is fed the comments-only clock" 0 "1" \
  grep -cF 'reconcile_ruling "$n" "$ruling_age" "$NOW"' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # the guarded_read is asserted as a literal
check "...and ruling_age is never fed by the reclaim clock" 1 "" \
  grep -E 'ruling_age.*last_issue_activity ' \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# shellcheck disable=SC2016 # positional parameter belongs to the isolated shell
check "the #284 probes perform no issue edits" 0 "$ruling_clock_edits_before" \
  bash -c 'wc -l <"$1"' _ "$TMP/issue-edits"

# -- non-triggers stay byte-for-byte outside the transition ------------------
recent_timeline() {
  jq -n --arg at "$(iso_at $((INOW - 60)))" \
    '[{"event":"assigned","created_at":$at}]' >"$(tfix "$1")"
  printf '[]\n' >"$(cfix "$1")"
}
edit_count_before="$(wc -l <"$TMP/issue-edits")"
recent_timeline 38
open_refs="$(issue_probe 38 claimed 1 refs 380 '- [ ] verify after merge')"
check "issue_probe: open Refs PR leaves the issue exactly as found" 0 "" \
  test -z "$open_refs"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...with no edit or comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$edit_count_before" "$TMP/issue-edits" "$TMP/posted-38"

recent_timeline 46
open_closing="$(issue_probe 46 claimed 1 closing 460 '- [ ] verify after merge')"
check "issue_probe: closing-linked open PR remains the unchanged control" 0 "" \
  test -z "$open_closing"

recent_timeline 39
merged_closes="$(issue_probe 39 claimed 1 false "" '- [ ] verify after merge')"
check "merged Closes PR leaves a recent claim exactly as found" 0 "" \
  test -z "$merged_closes"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...with no edit or comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$edit_count_before" "$TMP/issue-edits" "$TMP/posted-39"

recent_timeline 40
all_checked="$(issue_probe 40 claimed 1 false 400 '- [x] verified after merge')"
check "merged Refs with zero unchecked boxes leaves the issue exactly as found" 0 "" \
  test -z "$all_checked"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...with no edit or comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$edit_count_before" "$TMP/issue-edits" "$TMP/posted-40"

printf '[]\n' >"$(cfix 41)"
attention_transition="$(issue_probe 41 $'claimed\nattention' 1 false 410 '- [ ] verify')"
check "derived post-merge transition clears attention with the released claim" 0 "" \
  grep -qF -- '--remove-label claimed,attention --add-label post-merge' "$TMP/issue-edits"
check "...still completes the transition" 0 "" \
  grep -qF 'merged Refs PR -> post-merge; claim released' <<<"$attention_transition"

recent_timeline 43
jq -n --arg b '<!-- issueflow:post-merge-transition-pr-430 -->' \
  --arg at "$(iso_at $((INOW - 60)))" \
  '[{"body":$b,"created_at":$at}]' >"$(cfix 43)"
reentry_edit_count="$(wc -l <"$TMP/issue-edits")"
historical="$(issue_probe 43 claimed 1 false 430 '- [ ] corrective verification')"
check "a handled historical Refs merge cannot steal a re-entered claim" 0 "" \
  test -z "$historical"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...and re-entry produces no edit or duplicate transition comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$reentry_edit_count" "$TMP/issue-edits" "$TMP/posted-43"

printf '[]\n' >"$(cfix 44)"
second_transition="$(issue_probe 44 claimed 1 false 441 '- [ ] second verification')"
check "a later merged Refs PR gets an episode-specific transition comment" 0 "" \
  grep -qF '<!-- issueflow:post-merge-transition-pr-441 -->' "$TMP/posted-44"
check "...and the later episode still transitions" 0 "" \
  grep -qF 'merged Refs PR -> post-merge; claim released' <<<"$second_transition"

# End to end on the crew#321 shape: the later merge is the *lower*-numbered
# PR, and its marker is already on the issue. Selecting by number would find
# no marker for #461, fire the transition a second time, and release a claim
# the board already released (#242).
recent_timeline 46
jq -n --arg b '<!-- issueflow:post-merge-transition-pr-460 -->' \
  --arg at "$(iso_at $((INOW - 60)))" \
  '[{"body":$b,"created_at":$at}]' >"$(cfix 46)"
spent_edit_count="$(wc -l <"$TMP/issue-edits")"
spent="$(issue_probe 46 claimed 1 false \
  "461@$(iso_at $((INOW - 7200))) 460@$(iso_at $((INOW - 3600)))" \
  '- [ ] verify after merge')"
check "the marker of the later-merged lower-numbered PR is the one read" 0 "" \
  test -z "$spent"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...so the spent transition is not fired a second time" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$spent_edit_count" "$TMP/issue-edits" "$TMP/posted-46"

printf '[]\n' >"$(cfix 45)"
issue_probe 45 $'claimed\npost-merge' >/dev/null
# shellcheck disable=SC2016 # Markdown backticks are literal evidence
check "queue-conflict evidence lists every category including post-merge" 0 "" \
  grep -qF 'needs-triage`, `epic`, `ready`, `claimed`, `blocked`, or `post-merge`' \
  "$TMP/posted-45"

printf '[]\n' >"$(cfix 42)"
issue_probe 42 $'post-merge\nattention' 0 >/dev/null
check "hand-created post-merge plus attention is flagged, not rewritten" 0 "" \
  grep -qF '<!-- issueflow:post-merge-assigned -->' "$TMP/posted-42"

# -- offsite stops only the reclaim clock ------------------------------------
offsite="$(issue_probe 25 $'claimed\noffsite')"
check "a 10-day-quiet offsite claim is not reclaimed" 1 "" \
  grep -q 'reclaimed' <<<"$offsite"
issue_probe 26 $'claimed\noffsite' 0 >/dev/null
check "an unassigned offsite claim is still flagged" 0 "" \
  grep -q 'issueflow:claimed-unassigned' "$TMP/posted-26"
offsite_open="$(issue_probe 27 $'claimed\noffsite' 1 true)"
check "an offsite claim with an open PR stays claimed" 1 "" \
  grep -q 'reclaimed' <<<"$offsite_open"
offsite_both="$(issue_probe 28 $'claimed\noffsite\nneeds-ruling')"
check "offsite plus needs-ruling stays claimed" 1 "" \
  grep -q 'reclaimed' <<<"$offsite_both"

# -- resolved offsite work nudges once and only from complete evidence -------
jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at},
    {"event":"cross-referenced","source":{"issue":{"number":112,"repository":{"full_name":"heavy-duty/rig"},"pull_request":{"url":"x"}}}}]' \
  >"$(tfix 29)"
printf '{"state":"closed"}\n' >"$TMP/repos_heavy-duty_rig_pulls_112.json"
printf '[]\n' >"$(cfix 29)"
resolved="$(issue_probe 29 $'claimed\noffsite')"
check "a closed cross-referenced PR nudges and names the PR" 0 "" \
  grep -q 'heavy-duty/rig#112 is closed' "$TMP/posted-29"
check "the resolved nudge leaves the claim untouched" 1 "" \
  grep -q 'reclaimed' <<<"$resolved"
issue_probe 29 $'claimed\noffsite' >/dev/null
check "the resolved nudge is idempotent across sweeps" 0 "1" \
  grep -cF '<!-- issueflow:offsite-resolved -->' "$TMP/posted-29"

jq -n --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"event":"assigned","created_at":$at},
    {"event":"cross-referenced","source":{"issue":{"number":112,"repository":{"full_name":"heavy-duty/rig"},"pull_request":{"url":"x"}}}},
    {"event":"cross-referenced","source":{"issue":{"number":9,"repository":{"full_name":"heavy-duty/box"},"pull_request":{"url":"x"}}}}]' \
  >"$(tfix 30)"
printf '{"state":"open"}\n' >"$TMP/repos_heavy-duty_box_pulls_9.json"
printf '[]\n' >"$(cfix 30)"
issue_probe 30 $'claimed\noffsite' >/dev/null
check "one open cross-referenced PR suppresses the nudge" 1 "" \
  test -f "$TMP/posted-30"

printf '[]\n' >"$(tfix 31)"
printf '[]\n' >"$(cfix 31)"
issue_probe 31 $'claimed\noffsite' >/dev/null
check "no visible cross-referenced PR stays silent" 1 "" test -f "$TMP/posted-31"

: >"$(tfix 32).error"
printf '[]\n' >"$(cfix 32)"
unreadable="$(issue_probe 32 $'claimed\noffsite')"
check "an unreadable timeline stays silent" 1 "" test -f "$TMP/posted-32"
check "...and leaves the sweep running without an alarming log" 1 "" \
  grep -qiE 'error|failed' <<<"$unreadable"
# Both checks above still hold, and #247 D1 changed what reaches them:
# last_issue_activity reads the same timeline endpoint, so the issue is now
# skipped before the offsite verification runs. The skip is why nothing is
# posted, and its reason line is a deliberate report rather than an alarm
# (D4). D8 leaves offsite_timeline's own silence alone, so it is pinned here
# directly rather than through a probe that can no longer reach it.
offsite_timeline_probe() { ( REPO=owner/repo; gh() { issue_stub_gh "$@"; }; offsite_timeline "$1" ); }
check "an unreadable offsite timeline yields nothing and still fails closed" 1 "" \
  offsite_timeline_probe 32
check "...while a readable one answers its payload" 0 "[]" offsite_timeline_probe 31

: >"$TMP/api-calls"
printf '[]\n' >"$(tfix 33)"
printf '[]\n' >"$(cfix 33)"
issue_probe 33 claimed >/dev/null
check "a non-offsite claim performs only the ordinary timeline read" 0 "1" \
  grep -cF 'repos/owner/repo/issues/33/timeline' "$TMP/api-calls"
: >"$TMP/api-calls"
printf '[]\n' >"$(tfix 34)"
printf '[]\n' >"$(cfix 34)"
issue_probe 34 $'claimed\noffsite' >/dev/null
check "an offsite claim performs the one guarded verification read" 0 "2" \
  grep -cF 'repos/owner/repo/issues/34/timeline' "$TMP/api-calls"

check "a one-hour claim stays claimed for the ordinary age reason" 0 "KEEP" \
  claim_decision 1 false 3600
check "no reconciler mutation names offsite (#68 D4)" 1 "" \
  grep -E 'gh (issue|pr) edit.*offsite' \
    "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" \
    "$ROOT/actions/labels-reconcile/labels-reconcile.sh"

# -- the parse echo: one comment per changed set, none per sweep (#252) ------
# The whole point is a sweep-visible statement of what was read, so it is
# probed through the sweep and not only as a rendering: the marker has to
# survive the comment body, the second pass has to find it, and the third has
# to miss it because the declaration changed.
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_90.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_91.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_92.json"
printf '[]\n' >"$(cfix 35)"
echo_edits_before="$(wc -l <"$TMP/issue-edits")"
first_echo="$(issue_probe 35 blocked 1 false "" "Part of #1. Blocked by #90, #91.")"
check "a first parse is echoed, naming the set" 0 "" \
  grep -qF 'parse to: {#90, #91}' "$TMP/posted-35"
check "...and the sweep log carries the same set" 0 \
  "issueflow: #35: blocked declarations parse to {#90, #91}" \
  printf '%s\n' "$first_echo"
issue_probe 35 blocked 1 false "" "Part of #1. Blocked by #90, #91." >/dev/null
check "an unchanged parse draws nothing on the next sweep" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-35"
# AC-1's other input, and it is not the sweep above. A re-sweep of a
# BYTE-IDENTICAL body is quiet under both spellings of the decision — the one
# that keys on the parse and the one that keys on the body — so it cannot tell
# them apart. Only an edit that changes the prose and preserves the parse can:
# the refs are reordered and sentences are added on either side, and the set is
# still {#90, #91}. What this pins is that the marker is a function of the
# PARSE and not of the prose around it, which is the property the echo's whole
# idempotency rests on and which nothing else in the suite states.
preserved_edits_before="$(wc -l <"$TMP/issue-edits")"
issue_probe 35 blocked 1 false "" \
  "Some new prose here. Blocked by #91, #90. And more text." >/dev/null
check "a body edit that preserves the parse draws nothing" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-35"
check "...and adds no echo under any other marker either" 0 "1" \
  grep -cF '<!-- issueflow:blockers-parsed-' "$TMP/posted-35"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...and writes no label from the parse-preserving path" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$preserved_edits_before" "$TMP/issue-edits"
changed_echo="$(issue_probe 35 blocked 1 false "" "Part of #1. Blocked by #90, #91, #92.")"
check "a body edit that changes the set draws exactly one new echo" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91, #92}') -->" "$TMP/posted-35"
check "...naming the new set" 0 "" \
  grep -qF 'parse to: {#90, #91, #92}' "$TMP/posted-35"
check "...and saying so in the sweep log" 0 \
  "issueflow: #35: blocked declarations parse to {#90, #91, #92}" \
  printf '%s\n' "$changed_echo"
check "...and leaving the first echo alone" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-35"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "no label write comes from the echo path" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$echo_edits_before" "$TMP/issue-edits"

# crew#308, replayed through the sweep: the declaration denies #221 and the
# parse unions it anyway. Nobody saw that set for as long as it stayed inside
# the machine; the echo puts it in the thread that contains the declaration.
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_162.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_221.json"
printf '{"state":"open"}\n' >"$TMP/repos_owner_repo_issues_265.json"
printf '[]\n' >"$(cfix 36)"
issue_probe 36 blocked 1 false "" \
  'Blocked by #162, #265. It is no longer blocked by #221.' >/dev/null
check "the #308 misparse is echoed verbatim, denial and all" 0 "" \
  grep -qF 'parse to: {#162, #221, #265}' "$TMP/posted-36"

# The empty parse says so, and the flag that catches the UNREADABLE
# declaration is untouched beside it: one comment states what was read, the
# other states that nothing was.
printf '[]\n' >"$(cfix 37)"
issue_probe 37 blocked 1 false "" 'No declaration anywhere in this body.' >/dev/null
check "an empty parse is echoed as the empty set" 0 "" \
  grep -qF 'parse to: {}' "$TMP/posted-37"
check "...and blocked-unparseable still fires beside it" 0 "" \
  grep -qF '<!-- issueflow:blocked-unparseable -->' "$TMP/posted-37"

# The collision the round found, replayed through the sweep: two declarations
# whose parsed sets differ but whose slugs do not. Keyed on the slug, the
# second edit found the first echo's marker and posted nothing — the machine
# silently gating on `acme-widgets#9` while the thread said `acme/widgets#9`,
# which is the readable-but-wrong shape this whole change exists to surface.
# Asserted end-to-end, so it is the second echo landing that is observed.
printf '[]\n' >"$(cfix 38)"
issue_probe 38 blocked 1 false "" 'Blocked by acme/widgets#9.' >/dev/null
check "a qualified cross-repo declaration is echoed" 0 "1" \
  grep -cF 'parse to: {acme/widgets#9}' "$TMP/posted-38"
collision_edits_before="$(wc -l <"$TMP/issue-edits")"
issue_probe 38 blocked 1 false "" 'Blocked by acme-widgets#9.' >/dev/null
check "a slug-colliding edit still draws its own echo" 0 "1" \
  grep -cF 'parse to: {acme-widgets#9}' "$TMP/posted-38"
check "...under a marker of its own" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{acme-widgets#9}') -->" "$TMP/posted-38"
check "...leaving the colliding first echo alone" 0 "1" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{acme/widgets#9}') -->" "$TMP/posted-38"
# The cross-repo flag is marker-constant across both parses, so it stays at one
# while the echo moves: what spoke on the second sweep was the changed set.
check "...and not re-flagging cross-repo, which did not change" 0 "1" \
  grep -cF '<!-- issueflow:blocked-cross-repo -->' "$TMP/posted-38"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "no label write comes from the colliding-edit path either" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$collision_edits_before" "$TMP/issue-edits"

# A -> B -> A. The marker names the SET, so the return to A is a marker this
# thread has carried before; the question the echo has to answer is not "have I
# ever said this" but "is this still what I am saying". Searching the whole
# history answers the first, and the return went silent while the thread's
# newest echo asserted B and the sweep gated on A — a stale parse presented as
# the current one, which is the readable-but-wrong shape #252 exists to kill.
# All four sweeps are driven, because the bug is only visible as a sequence.
printf '[]\n' >"$(cfix 52)"
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91.' >/dev/null
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91, #92.' >/dev/null
return_edits_before="$(wc -l <"$TMP/issue-edits")"
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91.' >/dev/null
check "a set edited back to a previously echoed one speaks again" 0 "3" \
  grep -cF '<!-- issueflow:blockers-parsed-' "$TMP/posted-52"
check "...under the returning set's own marker, twice on the thread now" 0 "2" \
  grep -cF "<!-- issueflow:$(blocked_parse_marker '{#90, #91}') -->" "$TMP/posted-52"
# The assertion the silence used to fail: it is the NEWEST echo that has to
# name what the sweep gates on, not merely some echo somewhere in the thread.
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...leaving the newest echo naming the set the sweep now gates on" 0 \
  "parse to: {#90, #91}" \
  bash -c 'grep -o "parse to: {[^}]*}" "$1" | tail -n 1' _ "$TMP/posted-52"
issue_probe 52 blocked 1 false "" 'Blocked by #90, #91.' >/dev/null
check "an unchanged sweep after the return still draws nothing" 0 "3" \
  grep -cF '<!-- issueflow:blockers-parsed-' "$TMP/posted-52"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "no label write comes from the returning-set path either" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ "$return_edits_before" "$TMP/issue-edits"

# -- an already-applied stale heals off, and no edit names the flag ----------
jq -n --arg l "$(iso_at $((INOW - 3600)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$l}]' >"$(tfix 23)"
jq -n --arg at "$(iso_at $((INOW - 3660)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc23","body":"question, options, recommendation"}]' \
  >"$(cfix 23)"
healed="$(issue_probe 23 $'claimed\nneeds-ruling\nstale')"
check "an applied stale comes off under a pending ruling" 0 "" \
  grep -q 'unstale (a ruling is pending)' <<<"$healed"
check "...via an edit that removes exactly stale" 0 "" \
  grep -q -- '--remove-label stale' "$TMP/issue-edits"
check "no issue edit across every probe names the ruling flag (#50 D9)" 1 "" \
  grep -q 'needs-ruling' "$TMP/issue-edits"

# -- label churn is not activity: the nudge clock reads comments, not labels --
jq -n --arg flag "$(iso_at $((INOW - 8 * 86400)))" \
  --arg churn "$(iso_at $((INOW - 2 * 86400)))" \
  --arg assigned "$(iso_at $((INOW - 9 * 86400)))" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$flag},
    {"event":"labeled","label":{"name":"priority"},"actor":{"login":"anyone"},"created_at":$churn},
    {"event":"assigned","created_at":$assigned}]' >"$(tfix 24)"
jq -n --arg at "$(iso_at $((INOW - 8 * 86400 - 60)))" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc24","body":"question, options, recommendation"}]' \
  >"$(cfix 24)"
churn_last="$( (REPO=owner/repo; gh() { issue_stub_gh "$@"; }
  last_issue_activity 24 "$(iso_at $((INOW - 10 * 86400)))") )"
check "last activity ignores the 2-day-old label churn" 0 "" \
  test "$churn_last" = "$((INOW - 8 * 86400 - 60))"
churned="$(issue_probe 24 $'claimed\nneeds-ruling')"
check "8 real-quiet days nudge through a 2-day-old label churn" 0 "" \
  grep -q 'ruling nudge' <<<"$churned"

# ---------------------------------------------------------------------------
# An unreadable fact invents no verdict on the issue surface either (#247).
# `gh api` prints a 5xx body to stdout AND exits non-zero, and GitHub's 5xx
# body is a JSON object — so the payload that reached the guards was valid
# JSON, `.labels[]` came back empty, and queue_decision was handed the wrong
# input. The pure guards first, then the two decisions the fall-through
# reached.
# ---------------------------------------------------------------------------
payload_refused() { ! issue_payload_valid "$@"; } # 0 when the payload is refused

check "a healthy issue payload is accepted" 0 "" \
  issue_payload_valid 40 <<<'{"number":40,"labels":[{"name":"ready"}]}'
check "an issue carrying no labels at all is still a valid payload" 0 "" \
  issue_payload_valid 40 <<<'{"number":40,"labels":[]}'
# The reported shape: gh renders `gh: <message> (HTTP 504)` from a body with a
# `message` key, which proves the body was valid JSON. The status check is what
# catches this one; the shape check refuses it independently.
check "a JSON error object is not an issue payload" 0 "" \
  payload_refused 40 <<<"$GH_STUB_ERROR_BODY"
# The live path a status check alone would leave open (D3): 200, exit 0, and
# `.labels[]` empties exactly as it does on the 504.
check "an HTTP 200 whose body is null is refused" 0 "" payload_refused 40 <<<'null'
check "a payload missing .labels is refused" 0 "" \
  payload_refused 40 <<<'{"number":40}'
check "a payload whose .labels is not an array is refused" 0 "" \
  payload_refused 40 <<<'{"number":40,"labels":"ready"}'
check "a payload about a different issue is refused" 0 "" \
  payload_refused 40 <<<'{"number":41,"labels":[]}'
check "a payload that is not JSON at all is refused" 0 "" \
  payload_refused 40 <<<'not json'
check "an empty payload is refused" 0 "" payload_refused 40 </dev/null

# The reason line's shape (#101 D3/D4), reachable from this surface too — it
# is one implementation in lib/read.sh, not a second spelling.
check "empty stderr is reported as its own fact" 0 "no error output" \
  read_failure_reason ""
check "the captured 504 renders verbatim on one line" 0 \
  "$GH_STUB_STDERR" read_failure_reason "$GH_STUB_STDERR"
long_stderr="$(read_failure_reason "$(printf 'e%.0s' {1..400})")"
check "400 chars of stderr truncate to 300 plus an ellipsis" 0 "" \
  test "$long_stderr" = "$(printf 'e%.0s' {1..300})…"

# The D6 tail: silent on a whole pass, and naming both count and numbers on a
# partial one.
check "a whole pass adds no tail line" 0 "" test -z "$(skipped_tail 0 "")"
check "one skipped issue is named in the singular" 0 \
  "1 issue skipped this pass on an unreadable fact: #12" skipped_tail 1 "#12"
check "several skipped issues are all named" 0 \
  "2 issues skipped this pass on unreadable facts: #12 #40" \
  skipped_tail 2 "#12 #40"

# -- the lost-write report's two pure strings (#519 D2, D5) ------------------
# Three readers for the rows below. They run in THIS shell rather than behind
# `bash -c` on purpose: a `bash -c` subprocess cannot see a sourced function,
# so a row calling one through it measures an empty string and passes on a
# renderer that was never invoked.
line_count() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
emitted_line_count() { printf '%s\n' "$1" | grep -c '^issueflow:'; }
first_emitted_line() { printf '%s\n' "$1" | grep '^issueflow:' | head -n1; }
# The act renderer first. Every staged write on this surface is `gh issue
# edit` or `gh issue comment`, and `--body` is the only argument carrying a
# payload — so the rule is "cut at --body", not "shorten what looks long".
check "an edit's act renders whole: command, issue, repo and label flags" 0 \
  "gh issue edit 70 -R owner/repo --add-label needs-triage" \
  staged_write_act gh issue edit 70 -R owner/repo --add-label needs-triage
check "a comment's act stops at --body" 0 "gh issue comment 70 -R owner/repo" \
  staged_write_act gh issue comment 70 -R owner/repo --body "a body"
# The criterion is that the body is ABSENT, which a positive check on the
# prefix cannot assert: the prefix is present either way.
check_absent "...and the body itself never reaches the line" 0 "a body" \
  staged_write_act gh issue comment 70 -R owner/repo --body "a body"
act_multiline="$(staged_write_act gh issue comment 70 -R owner/repo \
  --body "$(printf '<!-- issueflow:m -->\nline one\nline two\n')")"
check "a multi-line body leaves the act one line" 0 "1" line_count "$act_multiline"
check_absent "...and no line of it appears in the act" 0 "line two" \
  printf '%s\n' "$act_multiline"
# The belt behind the cut: a payload-free argv is still bounded, because "a
# label name is short" is a fact about today's boards and not a guarantee.
long_act="$(staged_write_act gh issue edit 70 -R owner/repo \
  --add-label "$(printf 'L%.0s' {1..400})")"
check "an over-long payload-free act truncates to 200 plus an ellipsis" 0 "" \
  test "${#long_act}" -eq 201
check "...and the truncated act still ends in the ellipsis" 0 "…" \
  printf '%s\n' "${long_act: -1}"
# A newline reaching the renderer through an argument that is not --body
# would break the one-line-per-fact shape every reader of this log assumes.
act_embedded_newline="$(staged_write_act gh issue edit 70 -R owner/repo \
  --add-label "$(printf 'a\nb')")"
check "a newline inside a rendered argument is flattened" 0 "1" \
  line_count "$act_embedded_newline"
check "...into the one line, with both halves still on it" 0 \
  "gh issue edit 70 -R owner/repo --add-label a b" \
  printf '%s\n' "$act_embedded_newline"

# The tail, matching skipped_tail's shape because it is the same register.
check "a pass that lost nothing adds no tail line" 0 "" \
  test -z "$(lost_writes_tail 0 "")"
check "one lossy issue is named in the singular" 0 \
  "1 issue lost a board write this pass: #12" lost_writes_tail 1 "#12"
check "several lossy issues are all named" 0 \
  "2 issues lost board writes this pass: #12 #40" lost_writes_tail 2 "#12 #40"
# The two tails are independent facts and must not read as one another: a
# pass can be partly unreadable and partly unwritable, and a reader has to
# tell which (D2).
check_absent "the lossy tail never claims anything was skipped" 0 "skipped" \
  lost_writes_tail 1 "#12"
check_absent "...and the skipped tail never claims a write was lost" 0 "lost" \
  skipped_tail 1 "#12"

# -- the destroyed claim: a 504 on the comments read of a live claim ---------
# created_at long ago, a comment seconds old, and the comments read fails. The
# swallowed read dated the issue by created_at and reclaimed it, unassigning
# the builder under a comment asserting 48 hours of silence.
jq -n --arg at "$(iso_at $((INOW - 10)))" \
  '[{"user":{"login":"builder"},"created_at":$at,"html_url":"https://x/live","body":"still on it"}]' \
  >"$(cfix 50)"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$(cfix 50).http-error"
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"assigned","created_at":$at}]' >"$(tfix 50)"
claim_edits_before="$(wc -l <"$TMP/issue-edits")"
check "a 504 on the comments read skips the issue instead of grading its age" \
  3 "#50: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  issue_probe 50 claimed 1
check "...so the live claim is not reclaimed" 1 "" \
  grep -q 'stale claim reclaimed -> ready' <<<"$(issue_probe 50 claimed 1)"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...no unassign, no label swap, and no reclaim comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$claim_edits_before" "$TMP/issue-edits" "$TMP/posted-50"

# -- the quiet diagnostic: a 504 on a post-merge activity read (#254) --------
# The guarded read is unconditional at the top of the branch, so a
# `post-merge` issue can be skipped where before this change it never could —
# and the assigned flag, which needed no read at all, goes quiet with it.
# That is #247 D1's direction (a whole pass or none of it, never a verdict
# derived from a read that did not answer) and the trade `claimed`, `blocked`
# and `needs-ruling` already make. It is still a new way for that diagnostic
# to fall silent, so it is pinned here rather than left to inspection.
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"user":{"login":"triage-one"},"created_at":$at,"html_url":"https://x/c94","body":"evidence pending"}]' \
  >"$(cfix 94)"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$(cfix 94).http-error"
post_merge_skip_edits="$(wc -l <"$TMP/issue-edits")"
check "a 504 on a post-merge activity read skips the issue" \
  3 "#94: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  issue_probe 94 post-merge 1
check "...so neither the nudge nor the assigned flag speaks" 1 "" test -f "$TMP/posted-94"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...and the skipped pass edits nothing" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")"' _ \
  "$post_merge_skip_edits" "$TMP/issue-edits"

# -- the suppressed comment: a 504 on the marker read -----------------------
# The marker is on the issue. Read as "no marker", a failed read re-posts the
# comment the marker exists to suppress — every sweep, forever.
jq -n --arg b '<!-- issueflow:blocked-unparseable -->' \
  --arg at "$(iso_at $((INOW - 3600)))" \
  '[{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/m","body":$b}]' \
  >"$(cfix 51)"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$(cfix 51).http-error"
check "a 504 on the marker read skips rather than reading it as no marker" \
  3 "#51: skipped this pass — could not read its comments: $GH_STUB_STDERR" \
  issue_probe 51 blocked 1 false "" "no parseable declaration here"
check "...so no duplicate comment is posted" 1 "" test -f "$TMP/posted-51"

# -- a deliberate skip is counted; a genuine crash is still named (D4) -------
printf '%s\n' '{"number":60,"labels":[{"name":"ready"}],"assignees":[]}' \
  >"$TMP/repos_owner_repo_issues_60.json"
printf '%s\n' '{"number":61,"labels":[{"name":"ready"}],"assignees":[]}' \
  >"$TMP/repos_owner_repo_issues_61.json"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$TMP/repos_owner_repo_issues_61.json.http-error"
pass_probe() { # $1 issue; $2 non-empty makes reconcile_issue crash; $3 write-fail glob
  (
    REPO=owner/repo
    gh() { issue_stub_gh "$@"; }
    [ -z "${2:-}" ] || reconcile_issue() { return 9; }
    ISSUE_STUB_WRITE_FAILS="${3:-}"
    SKIPPED_COUNT=0
    SKIPPED_ISSUES=""
    LOST_COUNT=0
    LOST_ISSUES=""
    reconcile_issue_pass "$1"
    printf 'rc=%s count=%s issues=%s lost=%s lostissues=%s\n' \
      "$?" "$SKIPPED_COUNT" "$SKIPPED_ISSUES" "$LOST_COUNT" "$LOST_ISSUES"
  )
}
printf '%s\n' '{"number":62,"created_at":"2026-01-01T00:00:00Z","labels":[{"name":"ready"},{"name":"operator"}],"assignees":[],"body":"Surface: host. Evidence: run probe. Wake: operator comment."}' \
  >"$TMP/repos_owner_repo_issues_62.json"
printf '[]\n' >"$(cfix 62)"
printf '[]\n' >"$(tfix 62)"
: >"$TMP/issue-edits"
operator_pass="$(pass_probe 62)"
check "a staged full pass accepts ready plus operator" 1 "" \
  grep -q 'needs-triage\|conflicting queue labels' <<<"$operator_pass"
check "the staged full pass posts the operator nudge" 0 "" \
  grep -q 'operator work nudge' <<<"$operator_pass"
check "the staged full pass takes no label action" 1 "" \
  grep -qF 'issue edit 62' "$TMP/issue-edits"
check "a genuine non-read crash still names the failure byte-identically" 0 \
  "issueflow: #60: reconcile failed — continuing with the remaining issues" \
  pass_probe 60 crash
check "...and the pass still returns 0, so the loop reaches the next issue" 0 \
  "rc=0" pass_probe 60 crash
check "...and a crash is not counted as a skip" 0 "count=0" pass_probe 60 crash
check "a skipped issue is counted and named" 0 "count=1 issues=#61" pass_probe 61
check "...and is not also reported as a crash" 1 "" \
  grep -q 'reconcile failed' <<<"$(pass_probe 61)"
check "...leaving the loop free to continue" 0 "rc=0" pass_probe 61

# -- a lost board write, at the commit that loses it (#519) ------------------
# The commit is where the argv lives, so it is where the act can be named and
# the only place the status exists to be observed. These rows drive it through
# the real staging API — `ensure_comment` and `run` — rather than by hand, so
# what is asserted is the shape a live pass actually produces.
COMMIT_FIXTURE_BODY="$(printf '%s\n' \
  'A staged comment body, on more than one line.' \
  '' \
  'The second paragraph is the thing that must never reach the run log.')"
commit_probe() { # $1 = issue, $2 = write-fail glob (empty = every write lands)
  (
    REPO=owner/repo
    # shellcheck disable=SC2317 # reached through the staged effects' gh calls
    gh() { issue_stub_gh "$@"; }
    ISSUE_STUB_WRITE_FAILS="${2:-}"
    STAGING=true
    STAGED_EFFECTS=()
    ensure_comment "$1" write-status-fixture "$COMMIT_FIXTURE_BODY"
    log "#$1: the log line staged between the two writes"
    run gh issue edit "$1" -R "$REPO" --add-label ready >/dev/null
    commit_staged_effects "$1"
    printf 'rc=%s\n' "$?"
  )
}

# The clean commit first, because it is the steady state every consumer reads
# hourly and the criterion is that it did not move: the log line, both writes,
# and not one byte more.
: >"$TMP/issue-edits"
clean_commit_out="$(commit_probe 90)"
check "a commit whose writes all land returns 0" 0 "rc=0" \
  printf '%s\n' "$clean_commit_out"
check "...and still emits its staged log line" 0 \
  "issueflow: #90: the log line staged between the two writes" \
  printf '%s\n' "$clean_commit_out"
check_absent "...and says nothing about a failed write" 0 "board write failed" \
  printf '%s\n' "$clean_commit_out"
check_absent "...nor about writes that did not land" 0 "did not land" \
  printf '%s\n' "$clean_commit_out"
# Byte-identity, not just absence of the new strings: a clean commit's whole
# output is the one staged log line and nothing else.
check "a clean commit's output is exactly its staged log line" 0 "1" \
  emitted_line_count "$clean_commit_out"
check "...and its edit landed on the board" 0 "" \
  grep -qxF 'issue edit 90 -R owner/repo --add-label ready' "$TMP/issue-edits"

# Now the defect's own case: the FIRST of two writes fails.
: >"$TMP/issue-edits"
lost_commit_out="$(commit_probe 91 'issue comment*')"
check "a failed write is named by its act" 0 \
  "issueflow: #91: board write failed — gh issue comment 91 -R owner/repo" \
  printf '%s\n' "$lost_commit_out"
check "...and counted against the writes the pass staged" 0 \
  "issueflow: #91: 1 of 2 board writes did not land; the rest were applied" \
  printf '%s\n' "$lost_commit_out"
check "...and the commit reports it to its caller" 0 "rc=4" \
  printf '%s\n' "$lost_commit_out"
check "...with a status distinct from a deliberate skip's" 0 "" \
  test "$ISSUEFLOW_WRITE_FAILED" -ne "$ISSUEFLOW_SKIP"
check "...and distinct from a clean pass's" 0 "" \
  test "$ISSUEFLOW_WRITE_FAILED" -ne 0
# D5: the failing effect is a real ensure_comment call carrying a multi-line
# body, and none of it may reach the log. Asserted line by line, because a
# check on the first line alone passes on a report that spills the rest.
check_absent "...without the staged comment body's first line" 0 \
  'A staged comment body, on more than one line.' printf '%s\n' "$lost_commit_out"
check_absent "...or its second paragraph" 0 \
  'The second paragraph is the thing that must never reach the run log.' \
  printf '%s\n' "$lost_commit_out"
check_absent "...or the marker the body carries" 0 \
  '<!-- issueflow:write-status-fixture -->' printf '%s\n' "$lost_commit_out"
# D4: the effects staged AFTER the failing one are still applied — observed by
# the later write landing, not by inspecting the loop.
check "the log line staged after the failed write still speaks" 0 \
  "issueflow: #91: the log line staged between the two writes" \
  printf '%s\n' "$lost_commit_out"
check "the write staged after the failed one still lands" 0 "" \
  grep -qxF 'issue edit 91 -R owner/repo --add-label ready' "$TMP/issue-edits"
# ...and nothing is rolled back: the failed comment is the only loss, and no
# compensating write was attempted on the effects that did land.
check "a partial commit attempts no rollback" 0 "1" \
  line_count "$(cat "$TMP/issue-edits")"
# The failing act is named where it would have landed, not collected at the
# bottom: the report reads in staging order like every other line, so the
# failure of the FIRST staged write is the first line the commit emits.
check "the failure is reported in staging order" 0 \
  "issueflow: #91: board write failed — gh issue comment 91 -R owner/repo" \
  first_emitted_line "$lost_commit_out"

# The whole pass around it: the status crosses the subshell, the counters
# separate, and the two neighbouring lines keep their text (D1, D2).
printf '%s\n' \
  '{"number":63,"user":{"login":"triage-one"},"created_at":"2026-01-01T00:00:00Z","labels":[{"name":"enhancement"}],"assignees":[]}' \
  >"$TMP/repos_owner_repo_issues_63.json"
: >"$TMP/issue-edits"
check "a pass whose write lands is unchanged" 0 "#63: needs-triage" pass_probe 63
check_absent "...and reports no lost write" 0 "board write failed" pass_probe 63
check "...counting neither a skip nor a loss" 0 "count=0 issues= lost=0 lostissues=" \
  pass_probe 63
: >"$TMP/issue-edits"
check "a pass that loses its write names the act" 0 \
  "issueflow: #63: board write failed — gh issue edit 63 -R owner/repo --add-label needs-triage" \
  pass_probe 63 "" 'issue edit*'
check "...counts it out of the subshell for the run summary" 0 \
  "lost=1 lostissues=#63" pass_probe 63 "" 'issue edit*'
# D1 is the whole point of the third status: the pass still returns 0, so the
# loop reaches the next issue and the job stays green (#95, #101).
check "...and the pass still returns 0" 0 "rc=0" pass_probe 63 "" 'issue edit*'
check "...without counting the loss as a skip" 0 "count=0 issues=" \
  pass_probe 63 "" 'issue edit*'
# #247 D4 made the skip and crash lines byte-identical-but-separate on
# purpose. A third condition folded into either would hide behind it.
check_absent "...and never as the crash line" 0 "reconcile failed" \
  pass_probe 63 "" 'issue edit*'
check_absent "...and never as the skip line" 0 "skipped this pass" \
  pass_probe 63 "" 'issue edit*'
# The mirror: a skip and a crash must not start claiming a write was lost.
check_absent "a skipped issue is not reported as a lost write" 0 "board write failed" \
  pass_probe 61
check_absent "...and a crash is not either" 0 "board write failed" pass_probe 60 crash
check "...and neither is counted as one" 0 "lost=0 lostissues=" pass_probe 60 crash

# ---------------------------------------------------------------------------
# The arrival path, executed the way the action executes it (#91): four
# triage-authored mints died silently because the stand-down `return`s in
# reconcile_opened_issue carried the failed test's status into `set -e`. A
# sourced test takes the `set -u`-only branch and is blind to that class of
# bug by construction, so these run the script as a subprocess behind a
# PATH-stubbed gh — the house pattern from test/release-chain.test.sh.
# ---------------------------------------------------------------------------
ARRIVAL="$TMP/arrival"
mkdir -p "$ARRIVAL/stub" "$ARRIVAL/fixtures"
printf 'triage-actors=triage-one triage-two\n' >"$ARRIVAL/labels.conf"
cat >"$ARRIVAL/stub/gh" <<'EOF'
#!/usr/bin/env bash
# Endpoints map to files under $GH_FIXTURES ('/?&=' -> '_'); an absent file
# answers an empty list, a .error sentinel fails the call like a dead API.
if [ "$1" = api ]; then
  shift
  endpoint="" jqexpr="" query=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq) jqexpr="$2"; shift ;;
      -f|-F)
        case "$2" in query=*) query="${2#query=}" ;; esac
        shift ;;
      -*) ;;
      *) [ -n "$endpoint" ] || endpoint="$1" ;;
    esac
    shift
  done
  file="$GH_FIXTURES/$(printf '%s' "$endpoint" | tr '/?&=' '____').json"
  if [ "$endpoint" = graphql ]; then
    case "$query" in
      *'states: OPEN'*) file="$GH_FIXTURES/graphql-open.json" ;;
      *'states: MERGED'*) file="$GH_FIXTURES/graphql-merged.json" ;;
    esac
  fi
  # `.http-error` is the real 5xx (#247): the response body — GitHub's JSON
  # error object — goes to STDOUT, the reason to stderr, and the status is
  # non-zero. `.error` is the payload-free failure, which is the safe path.
  if [ -f "$file.http-error" ]; then
    if [ -n "$jqexpr" ]; then
      jq -r "$jqexpr" "$file.http-error" 2>/dev/null || true
    else
      cat "$file.http-error"
    fi
    printf '%s\n' "${GH_STUB_STDERR:-}" >&2
    exit 1
  fi
  [ ! -f "$file.error" ] || { printf '%s\n' "${GH_STUB_STDERR:-}" >&2; exit 1; }
  if [ -f "$file" ]; then payload="$(cat "$file")"; else payload='[]'; fi
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$payload"; else printf '%s\n' "$payload"; fi
  exit 0
fi
if [ "$1" = issue ]; then
  # The write side's failure sentinel (#519), matching issue_stub_gh's: the
  # glob in GH_STUB_WRITE_FAILS is tested against the whole argv, and a match
  # fails the write without recording it. Unset by default.
  if [ -n "${GH_STUB_WRITE_FAILS:-}" ]; then
    # shellcheck disable=SC2053 # the sentinel is a glob on purpose
    if [[ "$*" == $GH_STUB_WRITE_FAILS ]]; then
      printf '%s\n' "${GH_STUB_STDERR:-}" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$*" >>"$GH_FIXTURES/edits"; exit 0
fi
echo "gh stub: unexpected call: gh $*" >&2
exit 97
EOF
chmod +x "$ARRIVAL/stub/gh"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
cp "$ARRIVAL/fixtures/graphql-open.json" "$ARRIVAL/fixtures/graphql-merged.json"
arrival_fixture() { printf '%s\n' "$1" >"$ARRIVAL/fixtures/repos_owner_repo_issues_91.json"; }
arrival_run() {
  : >"$ARRIVAL/fixtures/edits"
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    EVENT_NAME=issues EVENT_ACTION=opened EVENT_ISSUE=91 \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
}

arrival_fixture '{"user":{"login":"triage-one"},"labels":[{"name":"ready"}]}'
triage_out="$(arrival_run 2>&1)"
triage_rc=$?
check "a triage-authored arrival exits 0 (#91's four dead mints)" 0 "" \
  test "$triage_rc" -eq 0
check "...and its output reaches the sweep" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$triage_out"
check "...and mints nothing" 1 "" test -s "$ARRIVAL/fixtures/edits"

arrival_fixture '{"user":{"login":"outsider"},"labels":[{"name":"ready"}]}'
outside_out="$(arrival_run 2>&1)"
outside_rc=$?
check "an outside-authored arrival exits 0" 0 "" test "$outside_rc" -eq 0
check "...still mints needs-triage" 0 "" \
  grep -qF 'needs-triage (opened by outsider)' <<<"$outside_out"
check "...still strips the smuggled queue label" 0 "" \
  grep -qxF 'issue edit 91 -R owner/repo --add-label needs-triage --remove-label ready' \
  "$ARRIVAL/fixtures/edits"
check "...and the sweep still runs after the mint" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$outside_out"

arrival_fixture '{"user":{"login":"outsider"},"labels":[],"pull_request":{"url":"x"}}'
pr_out="$(arrival_run 2>&1)"
pr_rc=$?
check "a PR arrival exits 0" 0 "" test "$pr_rc" -eq 0
check "...stands down without minting" 1 "" test -s "$ARRIVAL/fixtures/edits"
check "...and the sweep still runs" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$pr_out"

# Exercise both directions through main(): a merged-Refs transition still
# fires without a linked open PR, then the open-body gather suppresses it.
# A sourced decision probe cannot exercise the GraphQL gather and loop
# (#91's lesson).
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":400,"mergedAt":"2026-07-30T19:05:16Z","body":"Refs #40","closingIssuesReferences":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-merged.json"
printf '[{"number":40}]\n' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_state_open_per_page_100.json"
jq -n --arg at "$(iso_at "$INOW")" \
  '{number:40,user:{login:"triage-one"},created_at:$at,body:"- [x] built\n- [ ] verify live label",labels:[{name:"claimed"}],assignees:[{login:"builder"}]}' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_40.json"
printf '[]\n' >"$ARRIVAL/fixtures/repos_owner_repo_issues_40_comments.json"
: >"$ARRIVAL/fixtures/edits"
transition_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
transition_rc=$?
check "an executable sweep with no linked open PR exits 0" 0 "" \
  test "$transition_rc" -eq 0
check "...reaches the transition through GraphQL and the issue loop" 0 "" \
  grep -qF '#40: merged Refs PR -> post-merge; claim released' <<<"$transition_out"
check "...and performs the release edit from the executable path" 0 "" \
  grep -qF -- 'issue edit 40 -R owner/repo --remove-assignee builder --remove-label claimed --add-label post-merge' \
  "$ARRIVAL/fixtures/edits"

printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":401,"body":"Refs #40","isDraft":false,"closingIssuesReferences":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
: >"$ARRIVAL/fixtures/edits"
subprocess_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
subprocess_rc=$?
check "an open Refs-bodied PR suppresses the post-merge transition" 0 "" \
  test "$subprocess_rc" -eq 0
check "...leaves the live claim assigned" 1 "" \
  grep -qF '#40: merged Refs PR -> post-merge; claim released' <<<"$subprocess_out"
check "...performs no release edit" 1 "" \
  grep -qF -- 'issue edit 40 -R owner/repo --remove-assignee builder --remove-label claimed --add-label post-merge' \
  "$ARRIVAL/fixtures/edits"

# The query selects every OPEN PR and deliberately does not select isDraft;
# this fixture-only flip documents that draft identity cannot narrow the set.
sed 's/"isDraft":false/"isDraft":true/' "$ARRIVAL/fixtures/graphql-open.json" \
  >"$ARRIVAL/fixtures/graphql-open.json.tmp"
mv "$ARRIVAL/fixtures/graphql-open.json.tmp" "$ARRIVAL/fixtures/graphql-open.json"
: >"$ARRIVAL/fixtures/edits"
draft_transition_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
check "a draft Refs-bodied PR suppresses post-merge transition identically" 1 "" \
  grep -qF '#40: merged Refs PR -> post-merge; claim released' <<<"$draft_transition_out"

# The same body linkage protects the reclaim clock even when no Refs-linked
# PR has merged. This is the derived half of crew#321's destructive shape.
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":411,"body":"Refs #41","isDraft":false,"closingIssuesReferences":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-open.json"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql-merged.json"
printf '[{"number":41}]\n' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_state_open_per_page_100.json"
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '{number:41,user:{login:"triage-one"},created_at:$at,body:"- [ ] build",labels:[{name:"claimed"}],assignees:[{login:"builder"}]}' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_41.json"
printf '[]\n' >"$ARRIVAL/fixtures/repos_owner_repo_issues_41_comments.json"
jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
  '[{"event":"assigned","created_at":$at}]' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_41_timeline.json"
: >"$ARRIVAL/fixtures/edits"
reclaim_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    ISSUEFLOW_NOW="$INOW" REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
reclaim_rc=$?
check "an open Refs-bodied PR suppresses stale reclaim" 0 "" test "$reclaim_rc" -eq 0
check "...keeps the quiet live claim" 1 "" \
  grep -qF '#41: stale claim reclaimed -> ready' <<<"$reclaim_out"

# Drafts are live claim evidence by the same OPEN query (D4). The query does
# not select isDraft, so this fixture-only flip deliberately leaves production
# input byte-identical and guards the absence of a draft/readiness predicate.
sed 's/"isDraft":false/"isDraft":true/' "$ARRIVAL/fixtures/graphql-open.json" \
  >"$ARRIVAL/fixtures/graphql-open.json.tmp"
mv "$ARRIVAL/fixtures/graphql-open.json.tmp" "$ARRIVAL/fixtures/graphql-open.json"
: >"$ARRIVAL/fixtures/edits"
draft_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    ISSUEFLOW_NOW="$INOW" REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
check "a draft Refs-bodied PR suppresses stale reclaim identically" 1 "" \
  grep -qF '#41: stale claim reclaimed -> ready' <<<"$draft_out"

# D2 preserved: only the deliberate stand-downs changed; a genuine failure on
# the arrival path still kills the run loudly.
: >"$ARRIVAL/fixtures/repos_owner_repo_issues_91.json.error"
err_out="$(arrival_run 2>&1)"
err_rc=$?
check "a dead API on the arrival path still fails the run (D2)" 0 "" \
  test "$err_rc" -eq 1
check "...and the sweep does not run over a lying arrival" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$err_out"

# ---------------------------------------------------------------------------
# The whole sweep over an unreadable board (#247), executed. The sourced
# probes above drive one issue's pass; only this path exercises the loop, the
# counting and the tail — and only this path reproduces crew#329's log, which
# ended `issueflow: reconciled.` with rc=0 over a label it should never have
# written. Its own fixture directory: the arrival fixtures above are stateful
# across their cases.
# ---------------------------------------------------------------------------
SWEEP="$TMP/sweep"
mkdir -p "$SWEEP"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$SWEEP/graphql-open.json"
cp "$SWEEP/graphql-open.json" "$SWEEP/graphql-merged.json"
# 70: the 504 with a JSON error body on the per-issue read.
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$SWEEP/repos_owner_repo_issues_70.json.http-error"
# 71: healthy, and carrying no queue label — so if the sweep reaches it, it
# writes needs-triage. That write is the evidence the loop continued.
printf '%s\n' \
  '{"number":71,"user":{"login":"triage-one"},"labels":[{"name":"enhancement"}],"assignees":[]}' \
  >"$SWEEP/repos_owner_repo_issues_71.json"
# 72: HTTP 200 whose body is `null` — exit 0, and the label set empties just
# as it does on the 504. The shape check is the only thing that catches it.
printf 'null\n' >"$SWEEP/repos_owner_repo_issues_72.json"

sweep_board() { printf '%s\n' "$1" >"$SWEEP/repos_owner_repo_issues_state_open_per_page_100.json"; }
sweep_run() {
  : >"$SWEEP/edits"
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$SWEEP" ISSUEFLOW_NOW="$INOW" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
}

# The board read is a precondition for the whole pass (#257). A failed read
# cannot be inferred from an empty result: its status is the only fact that
# separates an unreadable board from a clean one. Drive both through main(),
# including gh's partial-pagination shape where stdout is non-empty on error.
board_fixture="$SWEEP/repos_owner_repo_issues_state_open_per_page_100.json"
printf '%s\n' "$GH_STUB_ERROR_BODY" >"$board_fixture.http-error"
board_504_out="$(sweep_run)"
board_504_rc=$?
check "an issue-list 504 aborts the whole pass" 0 "" test "$board_504_rc" -eq 1
check "...names the board read's stderr" 0 \
  "issueflow: could not read the issue board: $GH_STUB_STDERR" \
  printf '%s\n' "$board_504_out"
check "...writes no issue edit or comment" 1 "" test -s "$SWEEP/edits"
check "...never reports the pass reconciled" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$board_504_out"

board_silent_out="$(GH_STUB_STDERR="" sweep_run)"
board_silent_rc=$?
check "a silent issue-list failure still aborts" 0 "" test "$board_silent_rc" -eq 1
check "...renders the empty stderr as a fact" 0 \
  'issueflow: could not read the issue board: no error output' \
  printf '%s\n' "$board_silent_out"
check "...also writes nothing" 1 "" test -s "$SWEEP/edits"

printf '[{"number":71}]\n' >"$board_fixture.http-error"
partial_board_out="$(sweep_run)"
partial_board_rc=$?
check "partial pagination aborts the whole pass" 0 "" \
  test "$partial_board_rc" -eq 1
check "...does not reconcile the returned first page" 1 "" \
  grep -qF 'issue edit 71' "$SWEEP/edits"
check "...does not report the truncated pass reconciled" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$partial_board_out"

rm -f "$board_fixture.http-error"
sweep_board '[]'
empty_board_out="$(sweep_run)"
empty_board_rc=$?
check "a successful empty board stays green" 0 "" test "$empty_board_rc" -eq 0
check "...writes nothing" 1 "" test -s "$SWEEP/edits"
check "...names the empty-board outcome" 0 'issueflow: no open issues.' \
  printf '%s\n' "$empty_board_out"
check "...still ends with byte-identical reconciled." 0 \
  'issueflow: reconciled.' printf '%s\n' "$(tail -n1 <<<"$empty_board_out")"

sweep_board '[{"number":70},{"number":71}]'
sweep_out="$(sweep_run)"
sweep_rc=$?
check "an unreadable issue does not red the sweep (D7)" 0 "" test "$sweep_rc" -eq 0
check "the 504's JSON error body is skipped, with the reason named" 0 \
  "issueflow: #70: skipped this pass — could not read the issue: $GH_STUB_STDERR" \
  printf '%s\n' "$sweep_out"
check "...and crew#329's label is never written" 1 "" \
  grep -qF '#70: needs-triage (no queue state)' <<<"$sweep_out"
check "...nor any edit at all on the unreadable issue" 1 "" \
  grep -qF 'issue edit 70' "$SWEEP/edits"
check "...while the readable issue beside it is reconciled as before" 0 "" \
  grep -qxF 'issue edit 71 -R owner/repo --add-label needs-triage' "$SWEEP/edits"
check "...and the partial pass names its count and its issue" 0 \
  'issueflow: 1 issue skipped this pass on an unreadable fact: #70' \
  printf '%s\n' "$sweep_out"
check "...after a byte-identical reconciled. line" 0 "" \
  grep -qxF 'issueflow: reconciled.' <<<"$sweep_out"

sweep_board '[{"number":72}]'
null_out="$(sweep_run)"
null_rc=$?
check "an HTTP 200 whose body is null exits 0 and writes nothing" 0 "" \
  test "$null_rc" -eq 0
check "...because the shape check refuses it, on its own line" 0 \
  'issueflow: #72: skipped this pass — the issue read answered a payload that is not issue #72 carrying a label array' \
  printf '%s\n' "$null_out"
check "...so no label is derived from an empty label set" 1 "" \
  grep -qF 'issue edit 72' "$SWEEP/edits"
check "...and the tail names it too" 0 \
  'issueflow: 1 issue skipped this pass on an unreadable fact: #72' \
  printf '%s\n' "$null_out"

sweep_board '[{"number":70},{"number":72}]'
both_out="$(sweep_run)"
check "two skipped issues are both named, in the plural" 0 \
  'issueflow: 2 issues skipped this pass on unreadable facts: #70 #72' \
  printf '%s\n' "$both_out"

# -- the run summary tells a clean pass from a lossy one (#519 D1, D2) ------
# Through main(), because the summary is graded at the loop: the counters are
# per-pass and the tail is the run's, so re-entering reconcile_issue_pass by
# hand cannot see the line this criterion is about. Issue 71 is the healthy
# one that writes `needs-triage`, which is exactly the live instance the mint
# measured on heavy-duty/la-familia-incubator — a board where that label does
# not exist, so the write fails and the run reported success over it.
sweep_board '[{"number":71}]'
clean_tail_out="$(sweep_run)"
clean_tail_rc=$?
check "a sweep whose writes all land stays green" 0 "" test "$clean_tail_rc" -eq 0
check "...and its write reaches the board" 0 "" \
  grep -qxF 'issue edit 71 -R owner/repo --add-label needs-triage' "$SWEEP/edits"
check "...ending on a byte-identical reconciled." 0 "" \
  test "$(tail -n1 <<<"$clean_tail_out")" = "issueflow: reconciled."
# The steady state is the criterion here, so its absence is asserted rather
# than inferred from the lossy case passing.
check_absent "...with no lost-write tail on it" 0 "lost a board write" \
  printf '%s\n' "$clean_tail_out"
check_absent "...and no per-issue failure line" 0 "board write failed" \
  printf '%s\n' "$clean_tail_out"
check_absent "...and no count of writes that did not land" 0 "did not land" \
  printf '%s\n' "$clean_tail_out"

: >"$SWEEP/edits"
lossy_tail_out="$(GH_STUB_WRITE_FAILS='issue edit 71 *' sweep_run)"
lossy_tail_rc=$?
# D1 is preserved whole: this is about the report and never the exit code.
check "a sweep that lost a write still exits 0 (#95, #101)" 0 "" \
  test "$lossy_tail_rc" -eq 0
check "...names the act it lost" 0 \
  "issueflow: #71: board write failed — gh issue edit 71 -R owner/repo --add-label needs-triage" \
  printf '%s\n' "$lossy_tail_out"
check "...counts it against the writes the pass staged" 0 \
  "issueflow: #71: 1 of 1 board writes did not land; the rest were applied" \
  printf '%s\n' "$lossy_tail_out"
check "...still says reconciled. byte-identically" 0 "" \
  grep -qxF 'issueflow: reconciled.' <<<"$lossy_tail_out"
check "...and qualifies it on a line of its own, after it" 0 "" \
  test "$(tail -n1 <<<"$lossy_tail_out")" = \
    "issueflow: 1 issue lost a board write this pass: #71"
# The write genuinely did not land: the recorder is what says so, not the
# absence of a success message.
check "...over a board the write never reached" 1 "" \
  grep -qF 'issue edit 71' "$SWEEP/edits"
# The three conditions stay three. A lossy pass is not a skipped one and not
# a crashed one, and #247 D4's two lines keep their text.
check_absent "...and the pass is never called skipped" 0 "skipped this pass" \
  printf '%s\n' "$lossy_tail_out"
check_absent "...nor reported as a crash" 0 "reconcile failed" \
  printf '%s\n' "$lossy_tail_out"
check_absent "...and the skipped tail does not appear either" 0 \
  "skipped this pass on" printf '%s\n' "$lossy_tail_out"

# A dependency read is part of the issue's atomic pass. The parse echo is
# staged before this read, so an empty recorder proves both comments and edits
# were discarded rather than merely showing that the decision arm stayed quiet
# (#345). Bound and name the recorder here; the PR body carries the measured
# before/after counts beside the mutation evidence.
jq -n --arg at "$(iso_at "$INOW")" \
  '{number:73,user:{login:"triage-one"},created_at:$at,body:"Blocked by #74.",labels:[{name:"blocked"}],assignees:[]}' \
  >"$SWEEP/repos_owner_repo_issues_73.json"
printf '[]\n' >"$SWEEP/repos_owner_repo_issues_73_comments.json"
printf '%s\n' "$GH_STUB_ERROR_BODY" \
  >"$SWEEP/repos_owner_repo_issues_74.json.http-error"
sweep_board '[{"number":73}]'
dependency_edits_before="$(wc -l <"$SWEEP/edits")"
dependency_out="$(sweep_run)"
dependency_edits_after="$(wc -l <"$SWEEP/edits")"
check "a failed dependency read leaves the armed edit recorder empty" 0 "0 0" \
  printf '%s %s\n' "$dependency_edits_before" "$dependency_edits_after"
check "the blocked issue names the dependency read it skipped" 0 \
  "issueflow: #73: skipped this pass — could not read dependency #74: $GH_STUB_STDERR" \
  printf '%s\n' "$dependency_out"
check "the dependency skip ends with the partial-pass tail" 0 \
  'issueflow: 1 issue skipped this pass on an unreadable fact: #73' \
  printf '%s\n' "$dependency_out"
check "the failed dependency read never accuses the declaration" 1 "" \
  grep -qF 'blocked-unparseable' "$SWEEP/edits"

dependency_state_probe() {
  (
    REPO=owner/repo
    # shellcheck disable=SC2317 # reached indirectly by reference_states
    gh() { issue_stub_gh "$@"; }
    local states=""
    reference_states 75 states <<<"76"
    printf '%s\n' "$states"
  )
}
printf '{"state":"surprising"}\n' >"$TMP/repos_owner_repo_issues_76.json"
check "a non-issue dependency state skips instead of becoming UNKNOWN" 3 \
  "#75: skipped this pass — dependency #76 answered a state other than open or closed" \
  dependency_state_probe

sweep_board '[{"number":71}]'
whole_out="$(sweep_run)"
whole_rc=$?
check "a whole pass still exits 0" 0 "" test "$whole_rc" -eq 0
check "...ends on the byte-identical reconciled. line, with no tail after it" 0 \
  "issueflow: reconciled." printf '%s\n' "$(tail -n1 <<<"$whole_out")"
check "...and says nothing about skipping" 1 "" \
  grep -q 'skipped this pass' <<<"$whole_out"

# ---------------------------------------------------------------------------
# The ordering invariant (#247 D1): a skip implies ZERO writes, wherever in
# the pass the failed read lives. Round 1 measured what the per-read guards
# alone left standing — a pass could remove `stale`, or mint `needs-triage`,
# and only then reach a guarded read, fail it, and report the issue as
# skipped. The sweep said it had touched nothing while a write had landed:
# the same false report #247 exists to close, one layer along.
#
# Every composition is driven TWICE against identical fixtures, differing
# only in whether the late read answers. The healthy run is the control — it
# proves the mutation is genuinely on this path, so the failing run's "no
# edit" is a fact about the guard and not about a branch that never fired.
# Executed through the sweep, because staging is a property of the pass.
# ---------------------------------------------------------------------------
ORDER="$TMP/order"
mkdir -p "$ORDER"
cp "$SWEEP/graphql-open.json" "$SWEEP/graphql-merged.json" "$ORDER/"
order_board() { printf '%s\n' "$1" >"$ORDER/repos_owner_repo_issues_state_open_per_page_100.json"; }
order_fixture() { # $1 issue, $2 labels JSON, $3 body
  jq -n --argjson n "$1" --argjson labels "$2" --arg body "${3:-}" \
    --arg at "$(iso_at $((INOW - 10 * 86400)))" \
    '{number: $n, created_at: $at, user: {login: "triage-one"},
      labels: $labels, assignees: [], body: $body}' \
    >"$ORDER/repos_owner_repo_issues_$1.json"
}
order_run() {
  : >"$ORDER/edits"
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ORDER" ISSUEFLOW_NOW="$INOW" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
}
# The late read fails, or answers. `guarded_read` is what turns either into a
# skip, so which endpoint carries the sentinel is what picks the composition.
order_breaks() { printf '%s\n' "$GH_STUB_ERROR_BODY" >"$ORDER/repos_owner_repo_issues_$1_$2.json.http-error"; }
order_heals() { rm -f "$ORDER/repos_owner_repo_issues_$1_$2.json.http-error"; }
# A skip must leave no trace of the staged effect: not the write, and not the
# log line that would have announced it. Both halves, because a landed write
# under a "skipped" line and a "reconciled" line over no write are the same
# lie told from opposite ends.
order_wrote() { grep -qF "issue $2 $1" "$ORDER/edits"; }

# -- 1. unstale, then a failed activity read (the round's first composition) -
# `needs-ruling` heals an applied `stale` off before the tail reads the
# issue's activity. The read is two statements later; the write is already
# gone.
order_fixture 80 '[{"name":"ready"},{"name":"needs-ruling"},{"name":"stale"}]'
order_board '[{"number":80}]'
order_heals 80 comments
healthy_unstale="$(order_run)"
check "the control: a healthy pass really does unstale a pending ruling" 0 "" \
  order_wrote 80 edit
check "...and says so" 0 "issueflow: #80: unstale (a ruling is pending)" \
  printf '%s\n' "$healthy_unstale"
order_breaks 80 comments
broken_unstale="$(order_run)"
check "a failed activity read skips the unstale composition" 0 \
  "issueflow: #80: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_unstale"
check "...and the stale label is still on the issue" 1 "" order_wrote 80 edit
check "...and nothing claims it came off" 1 "" \
  grep -qF 'unstale (a ruling is pending)' <<<"$broken_unstale"

# -- 2. ADD_NEEDS_TRIAGE, then a failed activity read (the second) -----------
# The mint falls through — unlike FLAG_CONFLICT, which returns — into the
# same tail. crew#329's own label, written and then disowned by the log.
order_fixture 81 '[{"name":"enhancement"},{"name":"needs-ruling"}]'
order_board '[{"number":81}]'
order_heals 81 comments
healthy_mint="$(order_run)"
check "the control: a healthy pass really does mint needs-triage here" 0 "" \
  order_wrote 81 edit
check "...and says so" 0 "issueflow: #81: needs-triage (no queue state)" \
  printf '%s\n' "$healthy_mint"
order_breaks 81 comments
broken_mint="$(order_run)"
check "a failed activity read skips the needs-triage composition" 0 \
  "issueflow: #81: skipped this pass — could not read its activity history: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_mint"
check "...and crew#329's label is not written on the way out" 1 "" \
  order_wrote 81 edit
check "...and nothing claims it was" 1 "" \
  grep -qF '#81: needs-triage (no queue state)' <<<"$broken_mint"

# -- 3. the blockers->ready flip, then a failed COMMENTS read ----------------
# The read that guards this branch is the marker check ahead of the parse
# echo: a broken comments endpoint skips there, before the echo or the flip
# is staged. The timeline is no longer an input on this path at all (#284
# D1 — the ruling clock reads comments alone), so the unreadable-timeline
# case moved from "skips everything" to its own pin below.
printf '%s\n' '{"number":82,"state":"closed"}' \
  >"$ORDER/repos_owner_repo_issues_82.json"
order_fixture 83 '[{"name":"blocked"},{"name":"needs-ruling"}]' 'Blocked by #82.'
order_board '[{"number":83}]'
order_heals 83 comments
order_heals 83 timeline
healthy_flip="$(order_run)"
check "the control: a healthy pass really does flip cleared blockers to ready" 0 \
  "issueflow: #83: blockers closed -> ready" printf '%s\n' "$healthy_flip"
check "...writing the label edit" 0 "" order_wrote 83 edit
check "...and posting the blockers-cleared comment" 0 "" order_wrote 83 comment
order_breaks 83 comments
broken_flip="$(order_run)"
check "a failed comments read skips the blockers->ready composition" 0 \
  "issueflow: #83: skipped this pass — could not read its comments: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_flip"
check "...leaving the issue blocked" 1 "" order_wrote 83 edit
check "...with no comment posted about it" 1 "" order_wrote 83 comment
check "...and nothing claiming the flip happened" 1 "" \
  grep -qF 'blockers closed -> ready' <<<"$broken_flip"
# The read this path no longer takes cannot skip it (#284): with comments
# healthy and the timeline broken, the flip commits, and only the ruling
# ladder's own soft-failing read goes without — no verdict is invented, and
# no unrelated write is held hostage by an input the clocks stopped reading.
order_heals 83 comments
order_breaks 83 timeline
narrowed_flip="$(order_run)"
check "a failed timeline read no longer skips the flip" 1 "" \
  grep -qF 'skipped this pass' <<<"$narrowed_flip"
check "...the flip commits" 0 "" order_wrote 83 edit
check "...and the ruling ladder says what it could not read" 0 \
  "issueflow: #83: ruling timeline unreadable — no verdict invented this pass" \
  printf '%s\n' "$narrowed_flip"

# -- 4. a posted nudge, then a failed COMMENTS read -------------------------
# The comment-only half of the class: the epic nudge's own marker check is
# the read that fails, so the nudge is never staged and the skip reports the
# truth. A comment is as much a mutation as a label — it is the thing
# markers exist to make idempotent.
order_fixture 84 '[{"name":"epic"},{"name":"needs-ruling"}]' \
  '## Task list

- [x] #82'
order_board '[{"number":84}]'
order_heals 84 comments
order_heals 84 timeline
healthy_nudge="$(order_run)"
check "the control: a healthy pass really does nudge a completed epic" 0 \
  "issueflow: #84: completed epic nudged" printf '%s\n' "$healthy_nudge"
check "...by posting a comment" 0 "" order_wrote 84 comment
order_breaks 84 comments
broken_nudge="$(order_run)"
check "a failed comments read skips the epic-nudge composition" 0 \
  "issueflow: #84: skipped this pass — could not read its comments: $GH_STUB_STDERR" \
  printf '%s\n' "$broken_nudge"
check "...and the nudge comment is never posted" 1 "" order_wrote 84 comment
check "...and nothing claims it was" 1 "" \
  grep -qF 'completed epic nudged' <<<"$broken_nudge"
# The narrowed surface again (#284): a broken timeline neither skips nor
# suppresses the nudge; the ruling ladder alone goes without a verdict.
order_heals 84 comments
order_breaks 84 timeline
narrowed_nudge="$(order_run)"
check "a failed timeline read no longer skips the epic nudge" 1 "" \
  grep -qF 'skipped this pass' <<<"$narrowed_nudge"
check "...the nudge commits" 0 "" order_wrote 84 comment

# -- the skip is still just a skip: counted, tailed, and green (D4, D6, D7) --
check "a mutation-bearing composition that skips is still not a crash" 1 "" \
  grep -qF 'reconcile failed' <<<"$broken_flip"
check "...is still counted in the D6 tail" 0 \
  'issueflow: 1 issue skipped this pass on an unreadable fact: #83' \
  printf '%s\n' "$broken_flip"
order_board '[{"number":83}]'
order_run >/dev/null
check "...and still leaves the job green (D7)" 0 "" test $? -eq 0

# -- the two board flags (#293): the deliverable key, normalized ------------
# The 2026-08-04 miss spelled one deliverable two ways, so exact-prefix
# matching is specified away (D2). These pin the normalization itself.
count_lines() { deliverable_keys | grep -c .; }
keys_of() { # title on stdin -> its keys, each bracketed so `check` matches exactly
  # ANCHORED, because `check` compares its expectation as a substring: a bare
  # `issueflow-reconcile` expectation is satisfied by `issueflow-reconcile.test`
  # too, so the multi-extension row below stayed green under a normalization
  # stripping only the last extension — it asserted nothing it was named for.
  # Bracketing each key makes every row here fail for its own reason.
  deliverable_keys | sed 's/.*/[&]/'
}
check "the em-dash prefix is the key" 0 "[issueflow-reconcile]" \
  keys_of <<<"issueflow-reconcile — the ruling clock counts assigned"
check "a leading actions/ segment comes off" 0 "[issueflow-reconcile]" \
  keys_of <<<"actions/issueflow-reconcile — a failed board read"
check "...and so does .github/" 0 "[labeler]" \
  keys_of <<<".github/labeler.yml — one wrong answer left by D4"
check "...and lib/" 0 "[attention]" keys_of <<<"lib/attention.sh — the target"
check "...and bin/" 0 "[decide]" keys_of <<<"bin/decide.sh — the door"
check "every extension comes off, not just the last" 0 "[issueflow-reconcile]" \
  keys_of <<<"issueflow-reconcile.test.sh — the pre-read is unpinned"
check "the key folds case" 0 "[triage]" keys_of <<<"TRIAGE.md — the bullet"
check "a + title carries both segments" 0 $'[triage]\n[releases]' \
  keys_of <<<"TRIAGE.md + RELEASES.md — a standing window is a graph"
# A path segment the rule does not name stays part of the key: the strip list
# is closed on purpose (D2), so `test/issueflow-reconcile.test.sh` is its own
# deliverable and not the action it exercises.
check "an unlisted path segment stays in the key" 0 "[test/issueflow-reconcile]" \
  keys_of <<<"test/issueflow-reconcile.test.sh — the pre-read"
# One issue answers a SET. Normalization is many-to-one by design, so a `+`
# title can spell one deliverable twice — a deliverable and its test named
# together is the ordinary shape here, not an exotic one — and a repeated key
# makes the chain scan find the issue adjacent to ITSELF.
check "a + title whose segments normalize to one key answers that key once" 0 \
  "[issueflow-reconcile]" \
  keys_of <<<"issueflow-reconcile.sh + issueflow-reconcile.test.sh — one deliverable"
check "...and answers it exactly once, not twice" 0 "1" \
  count_lines <<<"issueflow-reconcile.sh + issueflow-reconcile.test.sh — one deliverable"
check "...and the path prefix folds onto the bare spelling the same way" 0 "1" \
  count_lines <<<"actions/issueflow-reconcile + issueflow-reconcile.sh — still one"
# No em dash, no key. Inventing one out of prose is the guessing this sweep
# never does; the malformed title is triage's own contract to enforce. The
# emptiness is asserted through grep's exit, since `check` cannot assert an
# empty expectation.
check "a title with no em dash names no deliverable" 1 "" \
  grep -q . < <(deliverable_keys <<<"a title that names nothing")

# -- the collision decision: a chain, never a fan (#288 D3) ------------------
# Sourced helpers, not `bash -c`: a subshell started with -c has none of these
# functions, and a pipeline ending in grep would then answer "no match" from a
# command-not-found and pass a negative case for the wrong reason.
collision_chain() { collision_key_index | collision_flags; }
collision_flags_issue() { collision_chain | grep -q "^$1"; }
window_flags_issue() { # $1 issue, $2 gate, $3 carriers; records on stdin
  window_flags "$2" "$3" | grep -qx "$1"
}
collision_board=$'253\tclaimed\tissueflow-reconcile — release-init\n257\tclaimed\tactions/issueflow-reconcile — a failed board read\n284\tready\tissueflow-reconcile — the ruling clock'
check "three issues on one deliverable chain, each naming the newest below it" 0 \
  $'257\tissueflow-reconcile=253\n284\tissueflow-reconcile=257' \
  collision_chain <<<"$collision_board"
check "...so the oldest carrier is never itself flagged" 1 "" \
  collision_flags_issue 253 <<<"$collision_board"
check "a lone carrier draws nothing" 0 "" \
  collision_chain <<<$'284\tready\tissueflow-reconcile — alone'
# `blocked` is the GOAL state of #288's rule; flagging it reports the fix as
# the defect. Both legs of the test plan, on one board.
check "two blocked twins are the declared chain, not a collision" 0 "" \
  collision_chain \
  <<<$'264\tblocked\tTRIAGE.md — one\n266\tblocked\tTRIAGE.md — two'
check "a blocked twin does not carry a ready one's edge either" 0 "" \
  collision_chain \
  <<<$'264\tblocked\tTRIAGE.md — one\n266\tready\tTRIAGE.md — two'
check "an epic carrying the key is outside the claimable set (#288 D6)" 0 "" \
  collision_chain \
  <<<$'264\tepic\tTRIAGE.md — one\n266\tready\tTRIAGE.md — two'
check "a post-merge carrier is outside it too" 0 "" \
  collision_chain \
  <<<$'264\tpost-merge\tTRIAGE.md — one\n266\tready\tTRIAGE.md — two'
# The #284 shape, stated as its own case (test plan): a `claimed` issue whose
# PR is already in flight is the STRONGEST collision on the board, not a
# weaker one, and the flag reads the queue label rather than the PR link.
check "a claimed carrier with a PR in flight still carries the collision" 0 \
  $'284\tissueflow-reconcile=253' \
  collision_chain \
  <<<$'253\tclaimed,scope:labels\tissueflow-reconcile — release-init\n284\tready\tissueflow-reconcile — the ruling clock'
# One issue, two colliding deliverables: ONE offending state, one comment (D4).
check "a multi-file title folds its collisions into one state" 0 \
  $'295\treleases=292,triage=264' \
  collision_chain \
  <<<$'264\tready\tTRIAGE.md — one\n292\tready\tRELEASES.md — two\n295\tready\tTRIAGE.md + RELEASES.md — three'
# ...and an issue can never be its own carrier. A `+` title whose segments
# normalize to one key contributed that key twice, and the chain scan, which
# reads adjacent rows within a key, then found the issue beside itself: the
# comment asked #402 to declare `Blocked by #402`.
check "a self-folding + title never chains an issue to its own number" 0 "" \
  collision_chain \
  <<<$'402\tready\tissueflow-reconcile.sh + issueflow-reconcile.test.sh — one deliverable'
check "...and two such carriers chain once, to each other" 0 \
  $'284\tissueflow-reconcile=257' \
  collision_chain \
  <<<$'257\tready\tissueflow-reconcile.sh + issueflow-reconcile.test.sh — one\n284\tready\tactions/issueflow-reconcile — two'
check "...with the older carrier still asked for nothing" 1 "" \
  collision_flags_issue 257 \
  <<<$'257\tready\tissueflow-reconcile.sh + issueflow-reconcile.test.sh — one\n284\tready\tactions/issueflow-reconcile — two'

# -- a release carrier is not a member of its own gate (#327 D1) -----------
self_gate_body='A member narrates Blocked by #163.'
check "a self-only parsed gate does not make its release issue a carrier" 1 "" \
  grep -q . < <(release_window_gate 163 $'163\n164' <<<"$self_gate_body")
mixed_gate_body='Blocked by #163, #164, #165.'
check "an open non-self member still makes the release issue a carrier" 0 \
  $'163\t164\n163\t165' \
  release_window_gate 163 $'163\n164' <<<"$mixed_gate_body"
# shellcheck disable=SC2016 # awk fields belong to awk, not the shell
check "the carrier number never contributes to its own WINDOW_GATE" 1 "" \
  awk -F '\t' '$2 == 163 { found = 1 } END { exit !found }' \
  < <(release_window_gate 163 $'163\n164' <<<"$mixed_gate_body")

# -- the membership record, read by heading (#343 D2) -----------------------
# The record is a machine record with one shape, and every case below is a
# shape a real release body already carries. The corpus is heavy-duty/crew#346
# — 21 members, a literal "## The members, in claim order" narration heading,
# rows citing merged PRs and another repository, one row annotating an issue as
# explicitly NOT a member, a verification lane that is not in the build queue,
# and a "## Task list" progress view beside all of it.
# Bracketed, so the assertion is the WHOLE set and not a prefix of it: a
# substring match on a bare list would let an extra member in silently, which
# is the one direction every mutation below travels.
membership_set() { # release body on stdin -> its members as one bracketed line
  printf '[%s]\n' "$(membership_references | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
}
membership_body="$(printf '%s\n' \
  'The 0.6.0 window. Blocked by #249.' \
  'A quoted declaration in narration: "Blocked by #906" is what the epic says.' \
  '' \
  '## The members, in claim order' \
  '- #900 — a narration heading, not the record' \
  '' \
  '## Members' \
  '- [ ] #253 — landed as #901, ports heavy-duty/crew#346, and #902 is not a member' \
  '- #257' \
  '- [x] #264 — landed' \
  '- crew#348 — a parallel track in another repository' \
  '- #266, #276 — two references on one row' \
  '- the verification lane, not in the build queue' \
  '- #249 — the sink itself' \
  '' \
  '## Task list' \
  '- [ ] #281 — the progress view')"
check "the record enrols exactly its rows' bare first tokens" 0 "[249 253 257 264]" \
  membership_set <<<"$membership_body"
# The heading is ANCHORED. crew#346 carries this exact narration heading, so a
# substring or prefix match reads it as the record and enrols its rows.
check "a narrated members heading is not the record" 1 "" \
  grep -qx 900 < <(membership_references <<<"$membership_body")
# The row's FIRST token, not every reference in it. epic_references prints the
# whole row and takes them all, which is right for a progress view and wrong
# here: these three are a merged PR, a sibling repository, and an issue the row
# itself names as a non-member.
check "a row's prose PR reference is not a member" 1 "" \
  grep -qx 901 < <(membership_references <<<"$membership_body")
check "...nor an issue the row names as explicitly not a member" 1 "" \
  grep -qx 902 < <(membership_references <<<"$membership_body")
check "...nor a qualified reference in the prose" 1 "" \
  grep -qx 346 < <(membership_references <<<"$membership_body")
# Silence, not a guess: a first token that is not a bare local reference
# contributes nothing, whether it is qualified, punctuated, or prose.
check "a qualified first token contributes no member" 1 "" \
  grep -qx 348 < <(membership_references <<<"$membership_body")
check "a punctuated first token contributes no member" 1 "" \
  grep -qx 266 < <(membership_references <<<"$membership_body")
check "...and the second reference on that row contributes none either" 1 "" \
  grep -qx 276 < <(membership_references <<<"$membership_body")
# The record ends at the next heading, so the progress view beside it is not
# membership — that separation is the whole reason the two lists are distinct.
check "a task-list reference is not a member" 1 "" \
  grep -qx 281 < <(membership_references <<<"$membership_body")
check "...nor a reference in narration outside the record" 1 "" \
  grep -qx 906 < <(membership_references <<<"$membership_body")
check "an unchecked row and a checked row enrol alike" 0 $'253\n264' \
  membership_references <<<"$membership_body"
check "a bare row with no checkbox enrols too" 0 "257" \
  membership_references <<<"$membership_body"
# Case-insensitive, trailing whitespace tolerated — the shape `## Task list`
# already has, stated once in RELEASES.md and implemented once here.
check "the heading matches case-insensitively with trailing whitespace" 0 "412" \
  membership_references <<<"$(printf '%s\n' '##   MEMBERS   ' '- #412 — admitted')"
# Every CommonMark list marker opens a row, and only those. A row is whatever a
# reader sees as one, so a marker class narrower than the set Markdown renders
# would drop a member a human wrote — and take the standing window down with
# it, which is silence in the one place D2 does not want silence. A class WIDER
# than it is the same error mirrored, and the more dangerous direction: a line
# no renderer reads as a row becomes a member, and one phantom open member
# keeps a window standing and suppresses its non-member flag. Only the first
# token rule decides what a row MEANS; the marker class decides what a row IS.
marker_body="$(printf '%s\n' \
  '## Members' \
  '- #412 — a hyphen row' \
  '* #413 — an asterisk row' \
  '+ #414 — a plus row' \
  '1. #415 — an ordered row' \
  '2) #416 — an ordered row, the paren form' \
  '123456789. #419 — nine digits, the widest ordered marker there is' \
  '1234567890. #420 — ten digits, which CommonMark does not render as a row' \
  '    #417 — no marker at all, so not a row')"
check "every Markdown list marker opens a member row" 0 \
  "[412 413 414 415 416 419]" \
  membership_set <<<"$marker_body"
check "a plus row enrols its member" 0 "" \
  grep -qx 414 < <(membership_references <<<"$marker_body")
check "an ordered row enrols its member" 0 "" \
  grep -qx 415 < <(membership_references <<<"$marker_body")
check "...and so does its paren form" 0 "" \
  grep -qx 416 < <(membership_references <<<"$marker_body")
# The bound is CommonMark 5.2's: an ordered marker is 1 to 9 digits then `.` or
# `)`. Both sides of it are asserted, because one alone is met by a class that
# is merely different rather than right — the 9-digit row is the widest marker
# a renderer accepts and must enrol, the 10-digit line is not a list row at all
# and must contribute nothing. The bound is written twice in the parser, in the
# row match and in the marker strip; a widening of either reds the pair.
check "the widest ordered marker CommonMark allows enrols its member" 0 "" \
  grep -qx 419 < <(membership_references <<<"$marker_body")
check "a tenth digit is not an ordered marker, so the line is not a row" 1 "" \
  grep -qx 420 < <(membership_references <<<"$marker_body")
# The marker is what makes the line a row, so a bare reference on its own line
# is narration inside the record, not a member. Indented deliberately: a `#`
# the terminator can reach would end the record, and this assertion is about
# the marker, not the terminator. FOUR spaces, not two, since #349 D8 gave the
# terminator the same three-column latitude a row has — at two it would be the
# terminator excluding this line, and the assertion would pass having tested
# nothing about the marker class.
check "a line with no list marker is not a row" 1 "" \
  grep -qx 417 < <(membership_references <<<"$marker_body")
# Indentation bounds the row the way the digit count bounds the marker, and both
# sides are asserted for the same reason: a bound met on one side alone is a
# class merely different rather than right. Three spaces still open a row —
# CommonMark 4.4 allows up to three, and refusing them would drop a member a
# human wrote and reads. A fourth does not, and what it means depends on context
# the line itself does not carry: GitHub renders `    - #N` after `## Members`
# as `<pre><code>`, and the same bytes under a `- #N` row as a nested `<li>`.
# The record is FLAT, so both are silence: an indented code block is not a row at
# all, and a sub-bullet annotating a member row is not a second member. Enrolling
# either is the phantom-member direction — an open reference taken from non-row
# content keeps a window standing and suppresses its non-member flag. A leading
# tab is four columns wherever indentation decides block structure, so it falls
# under the same bound.
indent_body="$(printf '%s\n' \
  '## Members' \
  '- #421 — column zero' \
  '   - #422 — three spaces, the deepest indentation that still opens a row' \
  '    - #423 — four spaces: a sub-row here, an indented code block alone' \
  $'\t- #424 — a tab, the same four columns, so neither is it')"
check "the record admits exactly its unindented and shallowly indented rows" 0 \
  "[421 422]" \
  membership_set <<<"$indent_body"
check "three spaces still open a row" 0 "" \
  grep -qx 422 < <(membership_references <<<"$indent_body")
check "a row indented past the bound is a sub-row, and not a second member" 1 "" \
  grep -qx 423 < <(membership_references <<<"$indent_body")
check "...and neither is the tab-indented one" 1 "" \
  grep -qx 424 < <(membership_references <<<"$indent_body")
# The same bytes with no row above them, which is the shape the panel found: no
# list is open, so the renderer reads an indented code block and there is nothing
# for the record to enrol. A body whose record is entirely non-rows enumerates
# no membership, and D4 then applies to it like any other empty record.
code_block_body="$(printf '%s\n' \
  '## Members' \
  '    - #425 — four spaces with no list open: an indented code block' \
  $'\t- #426 — and a tab, the same block')"
check "an indented code block inside the record enrols nobody" 0 "[]" \
  membership_set <<<"$code_block_body"
# The terminator itself, pinned where it can be seen: the record ends at the
# next line starting with `#`, the shape `## Task list` already has. A bare
# unindented reference is therefore the end of the record, not a member of it,
# and the rows after it are outside.
check "an unindented bare reference ends the record" 0 "[412]" \
  membership_set <<<"$(printf '%s\n' '## Members' '- #412' '#417' '- #418')"

# -- the three rules the two section parsers share (#349) --------------------
# `epic_references` and `membership_references` read two different records with
# one shape, and #349 made the three rules that shape rests on identical in
# both: the marker class, the indentation bound, and the fence. They are NOT a
# shared helper (#349 D5) — the checkbox requirement and row-vs-first-token
# would both have to be parameterized, and the contrast is worth writing down —
# so each rule is written twice in the tree, and every case below that can be
# runs through BOTH parsers in one check. That is the point: a ladder asserted
# against one parser cannot catch the two drifting apart, which is the failure
# this whole section exists to prevent.
#
# The two bodies come from one template rather than two hand-written literals,
# so "the same ladder through both" is a property of the fixture and not a
# promise about typing. `%H` is the record heading, `%C` the checkbox the epic
# row carries and the membership row does not, and `%I` the ladder's indent.
bracket() { # references on stdin -> the whole set as one bracketed token
  printf '[%s]' "$(tr '\n' ' ' | sed 's/[[:space:]]*$//')"
}
epic_set() { # epic body on stdin -> its task-list references, bracketed
  epic_references | bracket
}
render_body() { # $1 heading, $2 checkbox, $3 ladder indent, then template lines
  local heading="$1" checkbox="$2" indent="$3" line
  shift 3
  for line in "$@"; do
    line="${line//%H/$heading}"
    line="${line//%C/$checkbox}"
    line="${line//%I/$indent}"
    printf '%s\n' "$line"
  done
}
both_parsers() { # template lines -> both parsers' answer to the same body
  printf 'epic %s membership %s\n' \
    "$(render_body '## Task list' '[ ] ' '' "$@" | epic_references | bracket)" \
    "$(render_body '## Members' '' '' "$@" | membership_references | bracket)"
}
# One line, never five: the harness matches a substring, and grep reads an
# embedded newline as pattern alternation, so a multi-line expectation would
# pass on any single rung. The whole ladder is one token for the same reason
# membership_set brackets its set.
both_parsers_ladder() { # template lines using %I -> both parsers' five rungs
  local indent
  printf 'epic '
  for indent in '' '   ' '    ' '        ' "$(printf '\t')"; do
    render_body '## Task list' '[ ] ' "$indent" "$@" | epic_references | bracket
  done
  printf ' membership '
  for indent in '' '   ' '    ' '        ' "$(printf '\t')"; do
    render_body '## Members' '' "$indent" "$@" | membership_references | bracket
  done
  printf '\n'
}

# The marker class, now the same set on both sides. `epic_references` knew `-`
# and `*` only, so three rows of five dropped — and the drop was silent at both
# ends: GitHub renders all five identically, so the rendered issue tells its
# author nothing, and `epic_decision "" ""` is `KEEP`, so an empty reference set
# and an incomplete epic are one state. An epic enumerated under `+` therefore
# sat complete and unannounced forever, with nothing anywhere saying why.
check "every Markdown list marker opens a row in both records" 0 \
  "epic [101 102 103 104 105] membership [101 102 103 104 105]" \
  both_parsers \
  '%H' \
  '- %C#101 — a hyphen row' \
  '* %C#102 — an asterisk row' \
  '+ %C#103 — a plus row' \
  '1. %C#104 — an ordered row' \
  '1) %C#105 — an ordered row, the paren form'
# Both sides of CommonMark 5.2's bound, because one alone is met by a class
# that is merely different rather than right.
check "the ordered marker's digit bound is the same in both records" 0 \
  "epic [106] membership [106]" \
  both_parsers \
  '%H' \
  '123456789. %C#106 — nine digits, the widest ordered marker there is' \
  '1234567890. %C#107 — ten digits, which no renderer reads as a row'
# Where the two records deliberately differ, asserted on the epic side alone.
# `## Task list` is a *task* list, so a row with no checkbox is prose under it,
# and `#114` is what pins that: drop the checkbox requirement and it enrols.
# The marker-less line is indented past FOUR columns so the terminator cannot
# be what excludes it — the trap #347's own first cut fell into, and D8 moved
# where its floor sits: the terminator now reaches three columns like a row,
# so at two spaces this line would end the section, #114 would never be read,
# and the whole assertion would pass having tested neither rule.
check "a task list admits only checkbox rows under a list marker" 0 "[112]" \
  epic_set <<<"$(printf '%s\n' \
    '## Task list' \
    '- [ ] #112 — a task row' \
    '    #113 — no marker, and past the terminator, so the marker is what excludes it' \
    '- #114 — a marker but no checkbox, so prose under a task list')"
check "an unchecked row and a checked row enrol alike under one task list" 0 \
  "[110 111]" \
  epic_set <<<"$(printf '%s\n' \
    '## Task list' '- [ ] #110 — open' '1) [x] #111 — done, the paren form')"

# The fence. Both parsers reached their heading rule before their terminator,
# so a heading inside a code fence opened the section and a later real heading
# re-opened it: the two sets unioned, and an example record quoted in a fence
# enrolled its rows as real ones. A phantom open member keeps a window standing
# over a board of non-members; a phantom open child holds `epic_decision` at
# KEEP forever. The remedy is fence-awareness rather than a warning sentence
# because the parse must agree with what GitHub renders, and the divergence is
# invisible from the rendered issue — it shows a code block and gives the
# reader no signal that the sweep enrolled its rows (#349 D2).
check "a heading inside a fence opens no section, in either record" 0 \
  "epic [253 257] membership [253 257]" \
  both_parsers \
  'The record looks like this:' \
  '```' \
  '%H' \
  '- %C#202 — one row per member' \
  '```' \
  '' \
  '%H' \
  '- %C#253' \
  '- %C#257'
check "a fenced row under a real heading enrols nothing" 0 \
  "epic [253 257] membership [253 257]" \
  both_parsers \
  '%H' \
  '- %C#253' \
  '```' \
  '- %C#204 — quoted, not enumerated' \
  '```' \
  '- %C#257'
# The over-correction guard: a fence that opens and closes before the record
# must leave the real heading readable. A toggle that never clears would pass
# every case above and swallow the whole board.
check "a fence closed before the record leaves the record readable" 0 \
  "epic [253] membership [253]" \
  both_parsers \
  '```' \
  '- %C#203 — a row inside a fence, before any heading' \
  '```' \
  '%H' \
  '- %C#253'
check "a tilde fence indented three spaces is still a fence" 0 \
  "epic [253] membership [253]" \
  both_parsers \
  '   ~~~' \
  '%H' \
  '- %C#205 — inside a tilde fence indented three spaces' \
  '   ~~~' \
  '' \
  '%H' \
  '- %C#253'
# The delimiter carries the row's indentation bound for the row's reason: four
# columns is an indented code block, not a fence, so the backtick line is
# ordinary content and the rows after it are still the record's. Asserted on
# the space axis and the tab axis separately — the bound is one expression and
# a fix that took only one of the two axes passes the other.
check "a backtick line indented four spaces is not a fence delimiter" 0 \
  "epic [253 257] membership [253 257]" \
  both_parsers \
  '%H' \
  '- %C#253' \
  '    ```' \
  '- %C#257 — the rows after a four-space backtick line are still read'
check "a tab-indented backtick line is not a fence delimiter either" 0 \
  "epic [253 257] membership [253 257]" \
  both_parsers \
  '%H' \
  '- %C#253' \
  $'\t```' \
  '- %C#257 — the rows after a tab-indented backtick line are still read'
# A backtick run closes a backtick run and a tilde run closes a tilde run, so
# the inner delimiter is content. Without the character match the fence would
# close here, the next heading would re-open the section, and #206 would enrol
# — the phantom this rule exists to refuse.
check "a tilde line does not close a backtick fence" 0 \
  "epic [253 257] membership [253 257]" \
  both_parsers \
  '%H' \
  '- %C#253' \
  '```' \
  '~~~' \
  '%H' \
  '- %C#206 — still inside the backtick fence' \
  '```' \
  '- %C#257'
# And the converse, which is not the same assertion: the rule is written as one
# comparison against the character that OPENED the fence, so a fix that special-
# cased backticks would pass the case above and fail this one.
check "...and a backtick line does not close a tilde fence" 0 \
  "epic [253 257] membership [253 257]" \
  both_parsers \
  '%H' \
  '- %C#253' \
  '~~~' \
  '```' \
  '%H' \
  '- %C#208 — still inside the tilde fence' \
  '~~~' \
  '- %C#257'
# Decided behavior, not an oversight (#349 D3): an unclosed fence consumes the
# rest of the body, and GitHub renders that body exactly the same way — as one
# open code block. Under-reading a body a reader also sees as quoted is the
# correct direction of error, and it is the direction the marker gap and the
# indentation bound already fail in.
check "an unclosed fence consumes the rest of the body, in both records" 0 \
  "epic [] membership []" \
  both_parsers \
  '```' \
  '%H' \
  '- %C#207 — inside a fence nothing ever closes' \
  '' \
  '%H' \
  '- %C#253'

# The two ladders, both parsers, one check each. The bound is pinned on both
# sides rather than transcribed twice, so a bound in one parser merely
# DIFFERENT from the other's reds here rather than passing.
check "one row-indentation ladder, both records, the same answer at every rung" 0 \
  "epic [430 431][430 431][430][430][430] membership [430 431][430 431][430][430][430]" \
  both_parsers_ladder \
  '%H' \
  '- %C#430 — the control row, at column zero' \
  '%I- %C#431 — the rung'
# The heading takes the same bound, and it is read in two positions. The
# OPENER's failure is silent — `   ## Members` is an `h2` to GitHub but opened
# nothing, which is the absent-record direction #343 D4 already accepts.
check "one heading ladder in the opener position, both records, identical" 0 \
  "epic [440][440][][][] membership [440][440][][][]" \
  both_parsers_ladder \
  '%I%H' \
  '- %C#440'
# The TERMINATOR's is the unsafe one, so it is asserted separately and never as
# a rider on the opener: an indented heading did not close the record, so the
# parse ran on into the next section and took its rows. Past the bound the
# answer inverts for the same reason it does everywhere else — a four-space
# `## Dependencies` is an indented code block to GitHub too, so the record has
# not ended there and the row below it really is still the record's.
check "one heading ladder in the terminator position, both records, identical" 0 \
  "epic [441][441][441 442][441 442][441 442] membership [441][441][441 442][441 442][441 442]" \
  both_parsers_ladder \
  '%H' \
  '- %C#441' \
  '' \
  '%I## Dependencies' \
  '' \
  '- %C#442'

# -- the carrier decision reads the record (#343 D3, D4, D5) ----------------
check "an open member in the record makes the release issue a carrier" 0 \
  $'249\t253\n249\t257' \
  release_window_members 249 $'249\n253' \
  <<<"$(printf '%s\n' '## Members' '- #253' '- #257')"
# D4: no fallback. This is THE defect's own state — #317 from its mint until
# #249 closed at 2026-08-05T11:12Z, and crew's fifteen version epics at 0.6.0
# adoption: a version epic declaring its predecessor exactly as *Gates*
# instructs and enumerating nothing. Falling back to the gate here restores
# the reading that made a shut window stand.
check "a declared open predecessor with no record is not a carrier (D4)" 1 "" \
  grep -q . < <(release_window_members 317 $'249\n317\n343' <<<'Blocked by #249.')
check "...and an empty record is not a carrier either" 1 "" \
  grep -q . < <(release_window_members 249 $'249\n253' \
    <<<"$(printf '%s\n' '## Members' '' '## Task list' '- [ ] #253')")
check "...nor is a record whose every member has closed" 1 "" \
  grep -q . < <(release_window_members 249 $'249\n264' \
    <<<"$(printf '%s\n' '## Members' '- #218' '- #230')")
# D5: #327's self-exclusion, inherited rather than re-decided. Both readings
# share release_window_records, so the guard cannot hold on one side only.
check "a membership row naming the carrier contributes no member (D5)" 1 "" \
  grep -q . < <(release_window_members 249 $'249\n253' \
    <<<"$(printf '%s\n' '## Members' '- #249 — the sink itself')")
# shellcheck disable=SC2016 # awk fields belong to awk, not the shell
check "...and never contributes to WINDOW_MEMBERS beside a real member" 1 "" \
  awk -F '\t' '$2 == 249 { found = 1 } END { exit !found }' \
  < <(release_window_members 249 $'249\n253' \
    <<<"$(printf '%s\n' '## Members' '- #249' '- #253')")

# The snapshot may nominate a flag before this issue's own queue branch runs;
# the pure second gate reads the state that branch actually concluded.
check "a pass concluding ready still permits both board flags" 0 "" \
  board_flags_in_scope ready
check "a pass concluding claimed still permits both board flags" 0 "" \
  board_flags_in_scope claimed
check "a pass concluding post-merge silences both board flags" 1 "" \
  board_flags_in_scope post-merge

# -- the window decision (#292 D1) ------------------------------------------
window_board=$'249\tblocked,release\tRelease 0.6.0 — the board empties\n253\tclaimed\tissueflow-reconcile — a member\n264\tready\tTRIAGE.md — a non-member\n270\tepic\tsome epic — exempt\n271\tpost-merge\tsome item — exempt\n272\tblocked\tsome issue — already placed'
check "a ready non-member is flagged during a standing window" 0 "264" \
  window_flags "253" "249" <<<"$window_board"
check "...and a gate member is not" 1 "" \
  window_flags_issue 264 $'253\n264' 249 <<<"$window_board"
check "...nor an epic (#292 D1 exempts it by name)" 1 "" \
  window_flags_issue 270 253 249 <<<"$window_board"
check "...nor a post-merge issue" 1 "" \
  window_flags_issue 271 253 249 <<<"$window_board"
check "...nor a blocked issue, which is already placed behind something" 1 "" \
  window_flags_issue 272 253 249 <<<"$window_board"
# The release issue is the graph's SINK (#292 D2), so it can never be its own
# non-member — even when its own labels would otherwise admit it.
check "the window carrier is never flagged as its own non-member" 1 "" \
  window_flags_issue 249 253 249 \
  <<<$'249\tready,release\tRelease 0.6.0 — the board empties'
check "no standing window means no flag at all" 0 "" \
  window_flags "" "" <<<"$window_board"
check "two standing windows render as one state" 0 "#249, #250" window_state $'249\n250\n'
# ONE reading of `unblocked` across both flags. D2 as corrected glosses the
# word as "carrying `ready` or `claimed`" and D3b says D3 uses that gloss and
# names the domain as the claimable set, so an issue that is `needs-triage` or
# carries no queue label at all is outside BOTH flags. Excluding only
# `blocked`/`epic`/`post-merge` admitted them, and the second case is the one
# that showed: the same pass adds `needs-triage` to an unlabeled issue and
# then tells it about a membership call made at mint time.
scope_board=$'249\tblocked,release\tRelease 0.6.0 — the board empties\n253\tclaimed\tissueflow-reconcile — a member\n400\tneeds-triage\tTRIAGE.md — not through the door yet\n401\t\tTRIAGE.md — no queue label at all\n402\tclaimed\tREVIEWER.md — claimable, and a non-member'
check "a needs-triage issue is not in the window flag's domain" 1 "" \
  window_flags_issue 400 253 249 <<<"$scope_board"
check "...nor is an issue carrying no queue label at all" 1 "" \
  window_flags_issue 401 253 249 <<<"$scope_board"
check "...while the claimable non-member beside them still flags" 0 "402" \
  window_flags "253" "249" <<<"$scope_board"
# The same word, asserted through the other flag, so the two can never drift
# apart again without a red.
check "the collision flag reads that word identically" 0 "" \
  collision_chain <<<$'400\tneeds-triage\tTRIAGE.md — one\n401\t\tTRIAGE.md — two'
check "...and both flags answer one shared predicate" 1 "" \
  unblocked_claimable "needs-triage"
check "...which admits ready and claimed, and nothing else" 0 "" \
  unblocked_claimable "claimed,scope:labels"

# -- the 2026-08-04 board, replayed whole (D5) ------------------------------
# The corpus the operator ruled on. Both flags are decided over the WHOLE
# board, so a sourced decision probe cannot exercise the gather — these run
# the script as a subprocess behind the PATH-stubbed gh, #91's lesson applied
# to a board-wide check.
BOARD="$TMP/board"
mkdir -p "$BOARD"
cp "$ARRIVAL/fixtures/graphql-open.json" "$BOARD/graphql-open.json"
cp "$ARRIVAL/fixtures/graphql-merged.json" "$BOARD/graphql-merged.json"

board_issue() { # $1 number, $2 labels(csv), $3 title, $4 body, $5 assignee count
  local labels_json
  labels_json="$(printf '%s' "$2" | tr ',' '\n' \
    | jq -R . | jq -sc 'map(select(. != "") | {name: .})')"
  jq -n --argjson n "$1" --argjson labels "$labels_json" --arg t "$3" \
    --arg b "${4:-}" --argjson a "${5:-0}" --arg at "$(iso_at "$INOW")" \
    '{number: $n, state: "open", title: $t, body: $b, labels: $labels,
      created_at: $at, user: {login: "triage-one"},
      assignees: (if $a > 0 then [{login: "builder-bot"}] else [] end)}' \
    >"$BOARD/repos_owner_repo_issues_$1.json"
}

board_assemble() { # numbers… -> the open-issue list, with fresh comment threads
  local n
  for n in "$@"; do printf '[]\n' >"$BOARD/repos_owner_repo_issues_${n}_comments.json"; done
  # shellcheck disable=SC2016 # the filename expansion belongs to the loop below
  for n in "$@"; do cat "$BOARD/repos_owner_repo_issues_$n.json"; done \
    | jq -sc . >"$BOARD/repos_owner_repo_issues_state_open_per_page_100.json"
}

flag_count() { # $1 = collision|window|idle|deep|cycle, $2 = sweep output
  case "$1" in
    collision|window) grep -c ": $1 flag — " <<<"$2" ;;
    *) grep -c ": $1 graph flag — " <<<"$2" ;;
  esac
}

board_run() { # $1 optional: the workflow name the sweep runs under (#208)
  : >"$BOARD/edits"
  # GITHUB_WORKFLOW is unset rather than overridden, because the script reads
  # it through `${SELF_WORKFLOW:-${GITHUB_WORKFLOW:-}}` and `:-` treats an
  # empty override as absent — so exporting SELF_WORKFLOW="" would fall
  # straight back through to the runner's ambient name. Under CI that name is
  # `CI`, and any rollup fixture whose workflow happened to match it would
  # have its entries dropped by #208's exclusion and the verdict would flip
  # between a laptop and a runner. Unset means the exclusion filters nothing,
  # which is what every fixture below assumes.
  #
  # The one fixture that needs the exclusion ARMED passes the name here, and
  # not as a scoped assignment at the call site: this `env -u` would strip
  # that before the sweep ever started, and the case would test nothing while
  # reporting a pass. The two forms stay in one place so that cannot recur.
  if [ -n "${1:-}" ]; then
    env -u GITHUB_WORKFLOW SELF_WORKFLOW="$1" \
      PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$BOARD" ISSUEFLOW_NOW="$INOW" \
      REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
      bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
  else
    env -u GITHUB_WORKFLOW -u SELF_WORKFLOW \
      PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$BOARD" ISSUEFLOW_NOW="$INOW" \
      REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
      bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
  fi
}

# The morning shape, as the board actually stood at the 10:28:54Z mint:
# #253 `claimed` with no open PR (#285 was not created until 10:49:16Z),
# #257 `ready` since the evening before, #284 minted `ready` into both of
# them — six `ready` non-members against a standing gate, and one deliverable
# carried three times in two spellings.
# The declaration and the membership record side by side, which is the shape
# every version epic now carries: the gate answers the predecessor and the
# record answers the window (#343 D1, D3).
board_issue 249 blocked,release 'Release 0.6.0 — the board empties into the tag' \
  "$(printf '%s\n' 'Blocked by #253.' '' '## Members' '- #253')"
board_issue 253 claimed 'issueflow-reconcile — a release epic announces its own release-init' '' 1
board_issue 257 ready 'actions/issueflow-reconcile — a failed board read sweeps an empty board'
board_issue 264 ready 'TRIAGE.md — the no-assignee clause scopes to the flag'
# shellcheck disable=SC2016 # the backticks are the real issue title's Markdown
board_issue 266 ready 'TRIAGE.md — the epic task-list heading is literally `## Task list`'
board_issue 276 ready 'REVIEWER.md — the green-check precondition'
board_issue 281 ready 'LABELS.md — the attention row'
# The blocked twin on the same key, on the board rather than in a decision
# probe: it is neither a collision flag nor one of the six.
board_issue 282 blocked 'TRIAGE.md — the two comment links come out' 'Blocked by #266.'
# shellcheck disable=SC2016 # the backticks are the real issue title's Markdown
board_issue 284 ready 'issueflow-reconcile — the issue-side ruling clock counts `assigned`'
board_assemble 249 253 257 264 266 276 281 282 284
morning_out="$(board_run)"
morning_rc=$?

check "the morning board replays green" 0 "" test "$morning_rc" -eq 0
# D5's named pair, and the whole reason the key is normalized: #257 spells the
# deliverable `actions/issueflow-reconcile`, #284 spells it bare.
check "#284 draws the collision flag, naming #257 across the spelling variance" 0 \
  'issueflow: #284: collision flag — issueflow-reconcile=257' \
  printf '%s\n' "$morning_out"
check "...and #257 names #253, so the flag asks for a chain and not a fan" 0 \
  'issueflow: #257: collision flag — issueflow-reconcile=253' \
  printf '%s\n' "$morning_out"
check "...while #253, the oldest carrier, is asked for nothing" 1 "" \
  grep -qF 'issueflow: #253: collision flag' <<<"$morning_out"
check "the TRIAGE.md pair chains the same way" 0 \
  'issueflow: #266: collision flag — triage=264' printf '%s\n' "$morning_out"
check "...while the blocked twin beside them is the goal state, not a flag" 1 "" \
  grep -qF 'issueflow: #282: collision flag' <<<"$morning_out"
check "the morning board draws exactly three collision flags" 0 "3" \
  flag_count collision "$morning_out"
# D3's corpus: the six `ready` non-members that raced the emptying gate.
for nonmember in 257 264 266 276 281 284; do
  check "#$nonmember is flagged as an unblocked non-member under #249" 0 \
    "issueflow: #$nonmember: window flag — an unblocked non-member under #249" \
    printf '%s\n' "$morning_out"
done
check "the morning board draws exactly six window flags" 0 "6" \
  flag_count window "$morning_out"
check "...and never flags the gate member holding the window open" 1 "" \
  grep -qF 'issueflow: #253: window flag' <<<"$morning_out"
check "...nor the blocked issue already placed behind something" 1 "" \
  grep -qF 'issueflow: #282: window flag' <<<"$morning_out"
check "...nor the release issue that carries the window" 1 "" \
  grep -qF 'issueflow: #249: window flag' <<<"$morning_out"
# D1: comments only. Not "no unexpected edit" — no edit at all.
check "the whole replay writes no label and no state (D1)" 1 "" \
  grep -qF 'issue edit' "$BOARD/edits"
check "...and no new label is ever proposed" 1 "" \
  grep -qE 'add-label (collision|window)' "$BOARD/edits"
check "the collision comment cites the rule it is asking for" 0 "" \
  grep -qF 'collision edge' "$BOARD/edits"
check "...and names #288 as its authority" 0 "" grep -qF '#288 makes it unconditional' "$BOARD/edits"
check "the window comment names #292's invariant" 0 "" \
  grep -qF "#292's invariant" "$BOARD/edits"
# shellcheck disable=SC2016 # backticks are the comment body's own Markdown
check "...and states the subset rule with its exemptions" 0 "" \
  grep -qF 'the `ready` set is a subset of that' "$BOARD/edits"
# D6: both sentences that used to send triage to the declaration now name the
# record. The comment is the only place most consumers meet this rule, so a
# comment still saying "gate" would teach the misreading the issue removes.
# shellcheck disable=SC2016 # backticks are the comment body's own Markdown
check "...and tells triage where membership is actually read from" 0 "" \
  grep -qF 'Membership is read from the release issue'"'"'s own `## Members` record' \
  "$BOARD/edits"
# shellcheck disable=SC2016 # backticks are the comment body's own Markdown
check "...and says what a release issue's Blocked by line does answer" 0 "" \
  grep -qF 'answers its predecessor gate and never its membership' "$BOARD/edits"
check "...and asks the third write for a row, not a declaration" 0 "" \
  grep -qF 'the release issue gains a row for' "$BOARD/edits"
check "no window comment sends triage to a Blocked by declaration" 1 "" \
  grep -qF 'The gate is read from the release issue' "$BOARD/edits"
check "both comments carry idempotency markers (D4)" 0 "" \
  grep -qF '<!-- issueflow:collision-' "$BOARD/edits"
check "...the window one too" 0 "" grep -qF '<!-- issueflow:window-nonmember-' "$BOARD/edits"

# D4: a state that still stands is silent on the next sweep. The thread is
# seeded with the marker the first sweep wrote, which is exactly what the
# real API answers an hour later.
jq -n --arg b "<!-- issueflow:$(state_marker collision 'issueflow-reconcile=257') -->
said already" '[{"user": {"login": "sweep-bot"}, "body": $b}]' \
  >"$BOARD/repos_owner_repo_issues_284_comments.json"
jq -n --arg b "<!-- issueflow:$(state_marker window-nonmember '#249') -->
said already" '[{"user": {"login": "sweep-bot"}, "body": $b}]' \
  >"$BOARD/repos_owner_repo_issues_276_comments.json"
resweep_out="$(board_run)"
check "a standing collision is silent on the next sweep (D4)" 1 "" \
  grep -qF 'issueflow: #284: collision flag' <<<"$resweep_out"
check "a standing window non-membership is silent too" 1 "" \
  grep -qF 'issueflow: #276: window flag' <<<"$resweep_out"
check "...while every other flag on the board still speaks" 0 "2" \
  flag_count collision "$resweep_out"
check "...and the window flags with it" 0 "5" \
  flag_count window "$resweep_out"
# The value-keyed marker's whole point: a state that CHANGED speaks, even
# though this family has already had its say on the thread (#252's A -> B -> A).
jq -n --arg b "<!-- issueflow:$(state_marker collision 'issueflow-reconcile=253') -->
an older, different state" '[{"user": {"login": "sweep-bot"}, "body": $b}]' \
  >"$BOARD/repos_owner_repo_issues_284_comments.json"
changed_out="$(board_run)"
check "a changed collision state speaks over this family's last word" 0 \
  'issueflow: #284: collision flag — issueflow-reconcile=257' \
  printf '%s\n' "$changed_out"
# And a family only ever silences itself: the blocked-parse echo's marker
# lives on many of these threads and must not read as either flag's.
jq -n --arg b "<!-- issueflow:blockers-parsed-none-abc123def456 -->
a different family entirely" '[{"user": {"login": "sweep-bot"}, "body": $b}]' \
  >"$BOARD/repos_owner_repo_issues_284_comments.json"
foreign_out="$(board_run)"
check "another family's marker never silences the collision flag" 0 \
  'issueflow: #284: collision flag — issueflow-reconcile=257' \
  printf '%s\n' "$foreign_out"
# The direction that is actually load-bearing, and that the case above cannot
# reach: a foreign family's marker landing AFTER this flag's own must not make
# the flag speak again. Family-blind, "the last marker on the thread" is the
# blocked-parse echo's, which is not this state's marker, and the flag
# re-posts a comment that already stands — the noise D4's dedup exists to
# stop, on the one thread where three families all have something to say.
jq -n --arg b "<!-- issueflow:$(state_marker collision 'issueflow-reconcile=257') -->
this flag's own last word" \
  --arg c "<!-- issueflow:blockers-parsed-none-abc123def456 -->
a different family, later on the thread" \
  '[{"user": {"login": "sweep-bot"}, "body": $b},
    {"user": {"login": "sweep-bot"}, "body": $c}]' \
  >"$BOARD/repos_owner_repo_issues_284_comments.json"
later_foreign_out="$(board_run)"
check "a foreign family's LATER marker never makes the flag re-post" 1 "" \
  grep -qF 'issueflow: #284: collision flag' <<<"$later_foreign_out"
check "...while every other collision on the board still speaks" 0 "2" \
  flag_count collision "$later_foreign_out"

# -- the post-ruling board draws nothing (D5's must-not-flag leg) -----------
# The same issues after triage placed them: the TRIAGE.md triple chained
# oldest-first, the reconciler chain chained, and every one of them a gate
# member. Every flag above must go quiet, or the flag is reporting the fix.
board_issue 249 blocked,release 'Release 0.6.0 — the board empties into the tag' \
  "$(printf '%s\n' 'Blocked by #253.' '' '## Members' \
    '- #253' '- #257' '- #264' '- #266' '- #276' '- #281' '- #282' '- #284')"
board_issue 253 claimed 'issueflow-reconcile — a release epic announces its own release-init' '' 1
board_issue 257 blocked 'actions/issueflow-reconcile — a failed board read sweeps an empty board' \
  'Blocked by #253.'
board_issue 264 ready 'TRIAGE.md — the no-assignee clause scopes to the flag'
# shellcheck disable=SC2016 # the backticks are the real issue title's Markdown
board_issue 266 blocked 'TRIAGE.md — the epic task-list heading is literally `## Task list`' \
  'Blocked by #264.'
board_issue 276 ready 'REVIEWER.md — the green-check precondition'
board_issue 281 ready 'LABELS.md — the attention row'
board_issue 282 blocked 'TRIAGE.md — the two comment links come out' 'Blocked by #266.'
# shellcheck disable=SC2016 # the backticks are the real issue title's Markdown
board_issue 284 blocked 'issueflow-reconcile — the issue-side ruling clock counts `assigned`' \
  'Blocked by #257.'
board_assemble 249 253 257 264 266 276 281 282 284
ruled_out="$(board_run)"
check "the post-ruling board replays green" 0 "" test $? -eq 0
check "...and draws no collision flag at all" 1 "" \
  grep -qF ': collision flag' <<<"$ruled_out"
check "...and no window flag either" 1 "" grep -qF ': window flag' <<<"$ruled_out"
check "...and still reports a whole pass" 0 'issueflow: reconciled.' \
  printf '%s\n' "$ruled_out"

# -- an emptied window leaves the flag dormant (test plan) ------------------
# A membership RECORD never empties, exactly as the gate declaration it
# replaced never did: #249 enumerates fifteen members and still enumerates
# fifteen after all fifteen close. So the precondition is the record's OPEN
# members, not its parse — read straight off the board, which already is the
# open set. Under the parse reading the release issue, now `ready`, is itself
# an open unblocked non-`epic` non-member, and D3 would flag the sink at the
# exact moment the window ends.
board_issue 249 ready,release 'Release 0.6.0 — the board empties into the tag' \
  "$(printf '%s\n' 'Blocked by #217.' '' '## Members' \
    '- #218' '- #230' '- #232' '- #236' '- #237' '- #238' '- #241' '- #242' \
    '- #247' '- #248' '- #251' '- #252' '- #253' '- #254' '- #257')"
board_issue 264 ready 'TRIAGE.md — the no-assignee clause scopes to the flag'
# shellcheck disable=SC2016 # the backticks are the real issue title's Markdown
board_issue 266 ready 'TRIAGE.md — the epic task-list heading is literally `## Task list`'
board_assemble 249 264 266
empty_gate_out="$(board_run)"
check "a fifteen-member record with every member closed leaves D3 dormant" 1 "" \
  grep -qF ': window flag' <<<"$empty_gate_out"
check "...and the release issue is never flagged as its own non-member" 1 "" \
  grep -qF 'issueflow: #249' <<<"$empty_gate_out"
check "...while the collision flag beside it is unaffected" 0 \
  'issueflow: #266: collision flag — triage=264' printf '%s\n' "$empty_gate_out"

# -- both carriers claimed, both with their own PRs open (test plan) --------
# The ninety-three minutes from #285's creation to its merge: under D2's
# struck parenthetical the live collision went silent for all of them, so
# whether the flag ever fired depended on where the sweep tick fell relative
# to a builder opening a PR. It fires on the board, and only on the board.
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":285,"body":"","closingIssuesReferences":{"nodes":[{"number":253}]}},{"number":286,"body":"","closingIssuesReferences":{"nodes":[{"number":284}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$BOARD/graphql-open.json"
board_issue 253 claimed 'issueflow-reconcile — a release epic announces its own release-init' '' 1
# shellcheck disable=SC2016 # the backticks are the real issue title's Markdown
board_issue 284 claimed 'issueflow-reconcile — the issue-side ruling clock counts `assigned`' '' 1
board_assemble 253 284
both_claimed_out="$(board_run)"
check "two claimed carriers, both with PRs in flight, still draw the newer's flag" 0 \
  'issueflow: #284: collision flag — issueflow-reconcile=253' \
  printf '%s\n' "$both_claimed_out"
check "...and both live claims are left exactly as they were" 1 "" \
  grep -qF 'issue edit' "$BOARD/edits"
# The same board with the newer side `ready`, so the queue label is visibly
# the only input the flag has.
# shellcheck disable=SC2016 # the backticks are the real issue title's Markdown
board_issue 284 ready 'issueflow-reconcile — the issue-side ruling clock counts `assigned`'
board_assemble 253 284
in_flight_out="$(board_run)"
check "a claimed carrier with an open PR draws the ready issue's flag too" 0 \
  'issueflow: #284: collision flag — issueflow-reconcile=253' \
  printf '%s\n' "$in_flight_out"

# -- D3b's headline case, on the WINDOW side (acceptance criterion) ----------
# The criterion says a `claimed` non-member is flagged whether or not it has
# an open PR, and it is the line the 18:11Z ruling turned on — triage had
# excluded the open-PR case at 18:06Z and corrected it five minutes later.
# The collision fixtures above cover the PR-liveness question for their flag;
# this covers it for the other one. #292's charge against the third state is
# that a non-member competes with gate members for builders, and a non-member
# holding a builder AND a review round is that competition realized.
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":403,"body":"","closingIssuesReferences":{"nodes":[{"number":402}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$BOARD/graphql-open.json"
board_issue 249 blocked,release 'Release 0.6.0 — the board empties into the tag' \
  "$(printf '%s\n' 'Blocked by #253.' '' '## Members' '- #253')"
board_issue 253 claimed 'issueflow-reconcile — a member holding the window open' '' 1
board_issue 402 claimed 'REVIEWER.md — a non-member with a builder and a round' '' 1
board_assemble 249 253 402
nonmember_pr_out="$(board_run)"
check "a claimed non-member with an open PR still draws the window flag" 0 \
  'issueflow: #402: window flag — an unblocked non-member under #249' \
  printf '%s\n' "$nonmember_pr_out"
check "...and the gate member beside it, also claimed with a PR, is not" 1 "" \
  grep -qF 'issueflow: #253: window flag' <<<"$nonmember_pr_out"
check "...and the live claim is left exactly as it was" 1 "" \
  grep -qF 'issue edit' "$BOARD/edits"
check "...one window flag on the board, and only one" 0 "1" \
  flag_count window "$nonmember_pr_out"

# -- flagged, resolved, recreated unchanged: silent, and specified ----------
# D4's boundary, asserted rather than left accidental. Nothing is posted at
# the resolution — D1 admits no comment there — so the thread's last word is
# still the state itself and an identical return says nothing new. #292 D2b
# owns the recurrence: a board state violating the window invariants is
# triage's to repair in the tick it is seen, and triage has already been told
# about this one.
jq -n --arg b "<!-- issueflow:$(state_marker collision 'issueflow-reconcile=253') -->
flagged once" '[{"user": {"login": "sweep-bot"}, "body": $b}]' \
  >"$BOARD/repos_owner_repo_issues_284_comments.json"
board_assemble_keep() { # board_assemble without wiping the seeded threads
  local n
  for n in "$@"; do cat "$BOARD/repos_owner_repo_issues_$n.json"; done \
    | jq -sc . >"$BOARD/repos_owner_repo_issues_state_open_per_page_100.json"
}
board_assemble_keep 284
resolved_out="$(board_run)"
check "the collision resolves when its carrier leaves the board" 1 "" \
  grep -qF ': collision flag' <<<"$resolved_out"
check "...and the resolution itself writes nothing at all" 1 "" test -s "$BOARD/edits"
board_assemble_keep 253 284
recreated_out="$(board_run)"
check "an unchanged state recreated is silent — D4's stated boundary" 1 "" \
  grep -qF 'issueflow: #284: collision flag' <<<"$recreated_out"

# -- #426: the blocker declarations form a graph, so inspect its shape -----
# The board snapshot already carries every body and label needed here. These
# fixtures drive the full subprocess path to prove graph construction, flag
# placement, comment-only emission and marker dedup together.
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$BOARD/graphql-open.json"

# A four-node chain has one zero-indegree head. The flag belongs there only,
# and the named constant's value must be visible to the person reading it.
board_issue 501 ready 'alpha.sh — the chain head'
board_issue 502 blocked 'bravo.sh — second in the chain' 'Blocked by #501.'
board_issue 503 blocked 'charlie.sh — third in the chain' 'Blocked by #502.'
board_issue 504 blocked 'delta.sh — fourth in the chain' 'Blocked by #503.'
board_assemble 501 502 503 504
deep_out="$(board_run)"
check "a four-long chain flags its head" 0 \
  'issueflow: #501: deep graph flag — ≥4:#501 > #502 > #503 > #504' \
  printf '%s\n' "$deep_out"
check "the deep chain flags its head only" 0 "1" \
  flag_count deep "$deep_out"
# shellcheck disable=SC2016 # $1 expands in the isolated bash -c process
check "the one deep threshold constant is greppable" 0 "1" \
  bash -c 'grep -c "^GRAPH_DEEP_THRESHOLD=4$" "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
check "the deep flag text names the threshold number" 0 "" \
  grep -qF 'deep-chain threshold is **4**' "$BOARD/edits"
check "every graph tripwire comment carries its own marker family" 0 "" \
  grep -qF '<!-- issueflow:graph-deep-' "$BOARD/edits"
check "a fired graph tripwire writes no label or queue state" 1 "" \
  grep -qF 'issue edit' "$BOARD/edits"

# A complete acyclic graph is the adversarial form for simple-path
# enumeration: eighteen vertices previously exceeded the bound below. The
# threshold walk has no reason to inspect paths after its fourth vertex.
branch_records=""
branch_edges=""
for ((i = 601; i <= 618; i++)); do
  if [ "$i" -eq 601 ]; then label=ready; else label=blocked; fi
  branch_records+="${i}"$'\t'"${label}"$'\t'"branch-${i}"$'\n'
  for ((j = i + 1; j <= 618; j++)); do
    branch_edges+="${i}"$'\t'"${j}"$'\n'
  done
done
# shellcheck disable=SC2016 # expansions belong to the isolated bash process
branch_out="$(timeout 2 env BRANCH_RECORDS="$branch_records" BRANCH_EDGES="$branch_edges" \
  bash -c 'source "$1"; board_shape_flags 4 "$BRANCH_EDGES" "" 3 "" <<<"$BRANCH_RECORDS"' \
  _ "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh")"
branch_rc=$?
check "a branching DAG is bounded rather than enumerating every simple path" 0 "" \
  test "$branch_rc" -eq 0
# shellcheck disable=SC2016 # $1 expands in the isolated bash -c process
check "the bounded branching walk still finds the deep threshold" 0 \
  $'601\tdeep\t≥4:#601 > #602 > #603 > #604' \
  bash -c 'cut -f1-3 <<<"$1"' _ "$branch_out"

# A cycle is deliberately tested beside a ready issue so only the cycle
# signal fires. Mutual reachability puts the comment on every member, and the
# subprocess returning proves the traversal terminated.
board_issue 510 ready 'epsilon.sh — unrelated movable work'
board_issue 511 blocked 'foxtrot.sh — first cycle member' 'Blocked by #512.'
board_issue 512 blocked 'golf.sh — second cycle member' 'Blocked by #511.'
board_assemble 510 511 512
cycle_out="$(board_run)"
cycle_rc=$?
check "the cyclic fixture terminates successfully" 0 "" test "$cycle_rc" -eq 0
check "a cycle flags its first member" 0 \
  'issueflow: #511: cycle graph flag — #511,#512' printf '%s\n' "$cycle_out"
check "a cycle flags its second member" 0 \
  'issueflow: #512: cycle graph flag — #511,#512' printf '%s\n' "$cycle_out"
check "the cycle fixture emits exactly one cycle flag per member" 0 "2" \
  flag_count cycle "$cycle_out"
check "the non-idle cycle board emits no idle flag" 1 "" \
  grep -qF ': idle graph flag' <<<"$cycle_out"

# The unresolved external dependency is intentionally absent from the local
# graph. It leaves #523 as the one actionable chain head while all three open
# issues remain blocked, exactly the zero-ready/zero-claimed shape.
board_issue 521 blocked 'hotel.sh — idle tail' 'Blocked by #522.'
board_issue 522 blocked 'india.sh — idle middle' 'Blocked by #523.'
board_issue 523 blocked 'juliet.sh — idle head' 'Blocked by other/repo#99.'
board_issue 524 needs-triage 'kilo.sh — unrelated untriaged issue'
board_issue 525 epic 'lima.sh — unrelated epic'
board_assemble 521 522 523 524 525
idle_out="$(board_run)"
check "an idle board flags the chain head" 0 \
  'issueflow: #523: idle graph flag — 3:#521,#522,#523:#522>#521,#523>#522' \
  printf '%s\n' "$idle_out"
check "the idle board flags its head only" 0 "1" flag_count idle "$idle_out"
check "unrelated off-graph issues receive no idle carrier comment" 1 "" \
  grep -qE 'issueflow: #(524|525): idle graph flag' <<<"$idle_out"
check "the idle remedy names the priority route" 0 "" \
  grep -qF "following #425's priority route" "$BOARD/edits"

# A local predecessor absent from the open board is closed. That issue is on
# the existing blocked -> ready path, so it contributes no graph edge and the
# whole pre-pass idle snapshot stays silent while the same pass releases it.
board_issue 539 '' 'november.sh — closed predecessor'
jq '.state = "closed"' "$BOARD/repos_owner_repo_issues_539.json" \
  >"$BOARD/repos_owner_repo_issues_539.closed.json"
mv "$BOARD/repos_owner_repo_issues_539.closed.json" \
  "$BOARD/repos_owner_repo_issues_539.json"
board_issue 540 blocked 'oscar.sh — closed predecessor releases' 'Blocked by #539.'
board_issue 541 blocked 'papa.sh — external dependency remains' 'Blocked by other/repo#99.'
board_assemble 541 540
closed_predecessor_out="$(board_run)"
closed_predecessor_rc=$?
check "a last-position closed predecessor does not abort the graph gather" 0 "" \
  test "$closed_predecessor_rc" -eq 0
check "a closed predecessor follows the existing release path" 0 \
  'issueflow: #540: blockers closed -> ready' printf '%s\n' "$closed_predecessor_out"
check "a releasing predecessor suppresses the stale board-wide idle fact" 1 "" \
  grep -qF ': idle graph flag' <<<"$closed_predecessor_out"

# A dependent with one closed and one open local predecessor is not releasing:
# the open predecessor remains an edge, so the genuinely idle board still
# speaks. This pins the releasing predicate's any-open-match semantics.
board_issue 570 '' 'quebec.sh — closed half of mixed predecessors'
jq '.state = "closed"' "$BOARD/repos_owner_repo_issues_570.json" \
  >"$BOARD/repos_owner_repo_issues_570.closed.json"
mv "$BOARD/repos_owner_repo_issues_570.closed.json" \
  "$BOARD/repos_owner_repo_issues_570.json"
board_issue 571 blocked 'romeo.sh — open mixed predecessor' 'Blocked by other/repo#99.'
board_issue 572 blocked 'sierra.sh — mixed dependent' 'Blocked by #570, #571.'
board_assemble 571 572
mixed_predecessor_out="$(board_run)"
check "an open half keeps a mixed-predecessor issue in the graph" 0 \
  'issueflow: #571: idle graph flag — 2:#571,#572:#571>#572' \
  printf '%s\n' "$mixed_predecessor_out"
check "a mixed-predecessor idle board flags its head only" 0 "1" \
  flag_count idle "$mixed_predecessor_out"

# Stable epic and needs-triage heads are graph carriers even though they are
# not claimable. An unlabeled head changes to needs-triage during the pass and
# correctly waits until the next snapshot before speaking.
for head_state in epic needs-triage ''; do
  board_issue 550 "$head_state" 'quebec.sh — non-queue chain head'
  board_issue 551 blocked 'romeo.sh — second stable-state node' 'Blocked by #550.'
  board_issue 552 blocked 'sierra.sh — third stable-state node' 'Blocked by #551.'
  board_issue 553 blocked 'tango.sh — fourth stable-state node' 'Blocked by #552.'
  board_assemble 550 551 552 553
  stable_state_out="$(board_run)"
  if [ -n "$head_state" ]; then
    check "a stable $head_state head carries the deep flag" 0 \
      'issueflow: #550: deep graph flag — ≥4:#550 > #551 > #552 > #553' \
      printf '%s\n' "$stable_state_out"
    check "a stable $head_state head carries the idle flag" 0 \
      'issueflow: #550: idle graph flag — 3:#551,#552,#553:#550>#551,#551>#552,#552>#553' \
      printf '%s\n' "$stable_state_out"
    check "the stable $head_state idle board flags its head only" 0 "1" \
      flag_count idle "$stable_state_out"
  else
    check "an unlabeled head waits after becoming needs-triage" 1 "" \
      grep -qF ': deep graph flag' <<<"$stable_state_out"
  fi
done

# With no zero-indegree node, the actionable carriers are the blocked cycle
# members, whichever component each sits in. A tail fed by that cycle must
# not receive the idle comment as if every blocked member were a carrier.
board_issue 560 blocked 'uniform.sh — first source-cycle member' 'Blocked by #562.'
board_issue 561 blocked 'victor.sh — second source-cycle member' 'Blocked by #560.'
board_issue 562 blocked 'whiskey.sh — third source-cycle member' 'Blocked by #561.'
board_issue 563 blocked 'xray.sh — cycle tail' 'Blocked by #562.'
board_issue 564 blocked 'yankee.sh — cycle tail end' 'Blocked by #563.'
board_issue 570 needs-triage 'zulu.sh — unrelated untriaged issue'
board_assemble 560 561 562 563 564 570
cycle_tail_out="$(board_run)"
check "a headless cycle with a tail flags only the cycle as idle carriers" 0 "3" \
  flag_count idle "$cycle_tail_out"
check "the cycle tail receives no idle carrier comment" 1 "" \
  grep -qE 'issueflow: #(563|564): idle graph flag' <<<"$cycle_tail_out"
check "an off-graph issue does not suppress or carry headless-cycle idle" 1 "" \
  grep -qF 'issueflow: #570: idle graph flag' <<<"$cycle_tail_out"

# The same headless shape with two cycle components: an upstream cycle
# feeding a downstream one. The case above holds a single cycle, so "the
# upstream one" and "every one of them" name the same set there — which is how
# two comments describing this carrier set drifted in opposite directions with
# the suite green. The guard is the missing head, so both components carry,
# and the count is asserted rather than one member spot-checked (#444).
board_issue 580 blocked 'alpha.sh — first upstream-cycle member' 'Blocked by #582.'
board_issue 581 blocked 'bravo.sh — second upstream-cycle member' 'Blocked by #580.'
board_issue 582 blocked 'charlie.sh — third upstream-cycle member' 'Blocked by #581.'
board_issue 583 blocked 'delta.sh — downstream cycle, fed by the upstream one' 'Blocked by #582, #584.'
board_issue 584 blocked 'echo.sh — second downstream-cycle member' 'Blocked by #583.'
board_assemble 580 581 582 583 584
two_cycle_out="$(board_run)"
check "a two-component headless board carries idle on all five blocked members" 0 "5" \
  flag_count idle "$two_cycle_out"
check "the downstream cycle is a carrier and not merely something fed by one" 0 \
  'issueflow: #584: idle graph flag — 5:#580,#581,#582,#583,#584:' \
  printf '%s\n' "$two_cycle_out"
check "the upstream cycle renders as its own component" 0 \
  'issueflow: #580: cycle graph flag — #580,#581,#582' printf '%s\n' "$two_cycle_out"
check "the downstream cycle renders as a second, distinct component" 0 \
  'issueflow: #583: cycle graph flag — #583,#584' printf '%s\n' "$two_cycle_out"

# The fallback predicate is a conjunction — blocked AND cyclic — and every
# case above breaks only its head term. This one breaks the other: a cycle
# whose members are not blocked, feeding a blocked acyclic tail. The full
# board path cannot build that shape, because an edge is derived only from a
# blocked dependent, so an unblocked node can never hold indegree there; the
# function is driven directly for that reason alone. The cycle flags are
# asserted beside the silence, so an empty run cannot pass as a verdict.
conjunction_records=$'630\t\tunblocked cycle member\n631\t\tsecond unblocked cycle member\n632\tblocked\tblocked acyclic tail'
conjunction_edges=$'630\t631\n631\t630\n631\t632'
# shellcheck disable=SC2016 # expansions belong to the isolated bash process
conjunction_out="$(env CONJUNCTION_RECORDS="$conjunction_records" \
  CONJUNCTION_EDGES="$conjunction_edges" \
  bash -c 'source "$1"; board_shape_flags 4 "$CONJUNCTION_EDGES" "" 3 "" <<<"$CONJUNCTION_RECORDS"' \
  _ "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh")"
check "an unblocked cycle carries no idle flag even with no head" 1 "" \
  grep -qF $'\tidle\t' <<<"$conjunction_out"
check "...and that board really was the headless-cycle shape" 0 \
  $'630\tcycle\t#630,#631' printf '%s\n' "$conjunction_out"
check "...while the blocked acyclic tail carries nothing either" 1 "" \
  grep -qF '632' <<<"$conjunction_out"

# The explicit quiet case from the issue: two ready issues and a two-deep
# chain. Distinct deliverables keep the older collision flag out too, so any
# board-flag output is a regression rather than fixture noise.
board_issue 531 ready 'kilo.sh — first movable issue'
board_issue 532 ready 'lima.sh — second movable issue'
board_issue 533 blocked 'mike.sh — short chain tail' 'Blocked by #531.'
board_assemble 531 532 533
quiet_graph_out="$(board_run)"
check "a movable board with only a two-deep chain posts no graph flag" 1 "" \
  grep -qE ': (idle|deep|cycle|stalled) graph flag' <<<"$quiet_graph_out"
check "the graph tripwires never edit a label or queue state" 1 "" \
  grep -qF 'issue edit' "$BOARD/edits"

# Persisting state is silent, but extending the same chain changes the marker
# state and speaks. This is the existing per-family board-marker contract,
# proved on the new family rather than inferred from collision/window tests.
deep_display='≥4:#501 > #502 > #503 > #504'
deep_identity='nodes=#501,#502,#503,#504;edges=#501>#502,#502>#503,#503>#504'
jq -n --arg b "<!-- issueflow:$(state_marker graph-deep "$(graph_marker_state "$deep_display" "$deep_identity")") -->
said already" '[{"user": {"login": "sweep-bot"}, "body": $b}]' \
  >"$BOARD/repos_owner_repo_issues_501_comments.json"
board_assemble_keep 501 502 503 504
deep_repeat_out="$(board_run)"
check "a persisting deep shape is silent after its first word" 1 "" \
  grep -qF 'issueflow: #501: deep graph flag' <<<"$deep_repeat_out"
board_issue 505 blocked 'november.sh — a newly extended tail' 'Blocked by #504.'
printf '[]\n' >"$BOARD/repos_owner_repo_issues_505_comments.json"
board_assemble_keep 501 502 503 504 505
deep_changed_out="$(board_run)"
check "extending a deep shape changes its marker and speaks" 0 \
  'issueflow: #501: deep graph flag — ≥4:#501 > #502 > #503 > #504' \
  printf '%s\n' "$deep_changed_out"

# -- #440: the stalled head — a chain deep enough, claimed, and red ----------
# The shape a human found by hand on incubator#204: the fix everything was
# waiting on sat sixth in a chain, `claimed`, with its own PR red, and the
# sweep had nothing to say about it. Each fixture below breaks ONE term of the
# conjunction, because a signal proved only by its positive case is a signal
# whose predicate nobody has read.
#
# The rollup rides the open-PR query, so the fixtures are GraphQL-shaped —
# `checkSuite.workflowRun.workflow.name`, not the flat `workflowName` the
# classifier reads. That is deliberate: it puts the query's own projection
# under test alongside the flag, and a fixture written in the classifier's
# shape would have proved the projection by assuming it.
stall_ck() { # $1 name, $2 conclusion, $3 startedAt, $4 workflow
  jq -nc --arg n "$1" --arg o "$2" --arg t "${3:-2026-08-16T10:00:00Z}" \
    --arg w "${4:-ci}" \
    '{__typename: "CheckRun", name: $n, status: "COMPLETED", conclusion: $o,
      startedAt: $t, completedAt: $t,
      checkSuite: {workflowRun: {workflow: {name: $w}}}}'
}
stall_open_pr() { # $1 PR, $2 issue it closes, $3 contexts JSON array | NOCOMMIT
  local commits
  if [ "$3" = NOCOMMIT ]; then
    commits='{"nodes":[]}'
  else
    commits="$(jq -nc --argjson c "$3" \
      '{nodes: [{commit: {statusCheckRollup: {contexts: {nodes: $c}}}}]}')"
  fi
  jq -nc --argjson pr "$1" --argjson issue "$2" --argjson commits "$commits" \
    '{data: {repository: {pullRequests: {
       nodes: [{body: ("Refs #" + ($issue | tostring)),
                closingIssuesReferences: {nodes: [{number: $issue}]},
                commits: $commits}],
       pageInfo: {hasNextPage: false, endCursor: null}}}}}' \
    >"$BOARD/graphql-open.json"
}
stall_cited_pr() { # $1 issue, $2 the citing PR's contexts, $3 the issue's own PR's
  # Two open PRs on one issue, the one that merely CITES it paged first. That
  # is the order that hid the red head while the dedup keyed on the number
  # alone, and it is not a corner: open_pr_issues has read local `Refs` bodies
  # from every open PR since crew#321, and an issue at the head of a stalled
  # chain is exactly the issue other PRs cite.
  local citing owner
  citing="$(jq -nc --argjson c "$2" --argjson issue "$1" \
    '{body: ("Refs #" + ($issue | tostring)),
      closingIssuesReferences: {nodes: []},
      commits: {nodes: [{commit: {statusCheckRollup: {contexts: {nodes: $c}}}}]}}')"
  owner="$(jq -nc --argjson c "$3" --argjson issue "$1" \
    '{body: ("Refs #" + ($issue | tostring)),
      closingIssuesReferences: {nodes: [{number: $issue}]},
      commits: {nodes: [{commit: {statusCheckRollup: {contexts: {nodes: $c}}}}]}}')"
  jq -nc --argjson citing "$citing" --argjson owner "$owner" \
    '{data: {repository: {pullRequests: {nodes: [$citing, $owner],
       pageInfo: {hasNextPage: false, endCursor: null}}}}}' \
    >"$BOARD/graphql-open.json"
}
stall_chain() { # $1 head labels; the three-deep chain the fixtures share
  board_issue 801 "$1" 'alpha-stall.sh — the claimed chain head' '' 1
  board_issue 802 blocked 'bravo-stall.sh — second in the chain' 'Blocked by #801.'
  board_issue 803 blocked 'charlie-stall.sh — third in the chain' 'Blocked by #802.'
  board_assemble 801 802 803
}

stall_open_pr 900 801 "[$(stall_ck test FAILURE)]"
stall_chain claimed
stalled_out="$(board_run)"
check "a three-deep chain behind a claimed red head flags that head" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$stalled_out"
check "the stalled chain flags its head alone" 0 "1" flag_count stalled "$stalled_out"
check "no issue behind the head carries the flag" 1 "" \
  grep -qE 'issueflow: #(802|803): stalled graph flag' <<<"$stalled_out"
check "the stalled flag text names its own threshold number" 0 "" \
  grep -qF 'stalled-chain threshold is **3**' "$BOARD/edits"
check "the stalled remedy names servicing the red head and re-ordering" 0 "" \
  grep -qF 'rerun-owed' "$BOARD/edits"
check "...and the re-ordering route beside it" 0 "" grep -qF '#425' "$BOARD/edits"
check "the stalled comment carries its own marker family" 0 "" \
  grep -qF '<!-- issueflow:graph-stalled-' "$BOARD/edits"
check "a fired stalled tripwire writes no label or queue state" 1 "" \
  grep -qF 'issue edit' "$BOARD/edits"
check "...and the only line it wrote to the log is its own comment" 0 "1" \
  grep -c '^issue comment 801' "$BOARD/edits"
# The three-deep chain is below the deep threshold on purpose: the two
# tripwires must be separable, or the new one could be the old one misread.
check "a three-deep chain draws no deep flag" 1 "" \
  grep -qF ': deep graph flag' <<<"$stalled_out"
check "a board with a claimed head draws no idle flag" 1 "" \
  grep -qF ': idle graph flag' <<<"$stalled_out"

# The same firing shape with a SECOND open PR on the head, green, paged
# first — the whole pipeline rather than issues_with_failing_head alone. A
# dedup keyed on the issue number keeps the green row here and the flag goes
# silent, so this is the end-to-end half of that unit pair.
stall_cited_pr 801 "[$(stall_ck test SUCCESS)]" "[$(stall_ck test FAILURE)]"
stall_chain claimed
cited_out="$(board_run)"
check "a green PR citing the head never hides the head's own red PR" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$cited_out"
check "...and the flag is still the head's alone" 0 "1" flag_count stalled "$cited_out"
# The mirror: two open PRs both green is a green head and stays silent, so
# the case above is the red row surviving and not the dedup being abandoned.
stall_cited_pr 801 "[$(stall_ck test SUCCESS)]" "[$(stall_ck test SUCCESS)]"
stall_chain claimed
cited_green_out="$(board_run)"
check "two green open PRs on the head are silent" 1 "" \
  grep -qF ': stalled graph flag' <<<"$cited_green_out"
check "...and that board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$cited_green_out"

# The two constants are separate numbers for separate questions, and neither
# is spelled in terms of the other — writing 3 as GRAPH_DEEP_THRESHOLD - 1
# would let a staffing decision move the stall tripwire silently (D1).
# shellcheck disable=SC2016 # $1 expands in the isolated bash -c process
check "the stalled threshold constant is greppable" 0 "1" \
  bash -c 'grep -c "^GRAPH_STALLED_THRESHOLD=3$" "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # $1 expands in the isolated bash -c process
check "the deep threshold constant is still its own" 0 "1" \
  bash -c 'grep -c "^GRAPH_DEEP_THRESHOLD=4$" "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # $1 expands in the isolated bash -c process
check "neither threshold is defined in terms of the other" 1 "" \
  bash -c 'grep -E "^GRAPH_(DEEP|STALLED)_THRESHOLD=.*GRAPH_" "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# D7: a head nobody can rerun is exactly the head worth flagging. #423
# suppresses blocker:ci-red there because the BUILDER owes nothing; the board
# still owes the chain behind it. The signal reads the rollup and never a
# label, which is what makes this fixture pass without an exemption to write.
stall_open_pr 900 801 "[$(stall_ck test FAILURE)]"
stall_chain claimed,rerun-owed
rerun_owed_out="$(board_run)"
check "a rerun-owed head still fires the stalled flag" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$rerun_owed_out"
# The fixture above can only put the label on the ISSUE, while `rerun-owed`
# lives on the PR — so it proves no exemption was added on this surface and
# cannot prove one was not added on the other. What closes that gap is that
# the label is unreachable from here at all: every occurrence of the string in
# this script is inside the remedy sentence, so no branch can read it.
# shellcheck disable=SC2016 # $1 expands in the isolated bash -c process
check "every rerun-owed mention in the sweep is prose, never a predicate" 0 "2" \
  bash -c 'grep -c "rerun-owed" "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"
# shellcheck disable=SC2016 # $1 expands in the isolated bash -c process
check "...none of them reached by a label test" 1 "" \
  bash -c 'grep -E "(has_issue_label|grep -q[a-z]*F?).*rerun-owed" "$1"' _ \
  "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# -- the instrument, not the field (the acceptance criterion that names one) -
# GraphQL's `statusCheckRollup { state }` would call this rollup FAILURE: it
# is one enum over the whole array with none of #136's newest-entry collapse.
# The classifier collapses the context to its newest entry first and sees the
# SUCCESS that replaced the failure. Same fixture minus the newer entry must
# fire, or the silence above is the flag being broken rather than correct.
stall_open_pr 900 801 \
  "[$(stall_ck test FAILURE 2026-08-16T10:00:00Z),$(stall_ck test SUCCESS 2026-08-16T10:30:00Z)]"
stall_chain claimed
superseded_out="$(board_run)"
check "a superseded FAILURE beside its newer SUCCESS is not a red head" 1 "" \
  grep -qF ': stalled graph flag' <<<"$superseded_out"
stall_open_pr 900 801 "[$(stall_ck test FAILURE 2026-08-16T10:00:00Z)]"
stall_chain claimed
unsuperseded_out="$(board_run)"
check "...and the same rollup without the newer entry fires" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$unsuperseded_out"
# #139's other half travels with the classifier: an all-cancelled context
# never reported at all, so it classifies FAILURE and the head is red.
stall_open_pr 900 801 "[$(stall_ck test CANCELLED)]"
stall_chain claimed
cancelled_out="$(board_run)"
check "an all-cancelled context is a red head, per #139" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$cancelled_out"
# #208's half: a rollup of only the sweep's own runs classifies NONE, and a
# self-only rollup must never manufacture a red head. The workflow name goes
# through board_run's argument, because a scoped assignment at this call site
# is stripped by its `env -u` and `env SELF_WORKFLOW=... board_run` cannot run
# a shell function at all — that spelling failed with `No such file or
# directory`, left stdout empty, and satisfied the must-not-fire assertion
# below without the sweep ever running.
stall_open_pr 900 801 "[$(stall_ck reconcile CANCELLED 2026-08-16T10:00:00Z labels-sweep)]"
stall_chain claimed
self_only_out="$(board_run labels-sweep)"
check "a rollup of only the sweep's own runs is no red head, per #208" 1 "" \
  grep -qF ': stalled graph flag' <<<"$self_only_out"
check "...and that board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$self_only_out"
# The positive control, and the reason the silence above is evidence: the
# SAME rollup with the sweep running under any other name is an all-cancelled
# context, so #139 makes it a red head and the flag fires. One of this pair
# reds whichever direction the exclusion breaks in — dropped, and the first
# fires; widened to everything, and the second goes silent.
stall_open_pr 900 801 "[$(stall_ck reconcile CANCELLED 2026-08-16T10:00:00Z labels-sweep)]"
stall_chain claimed
other_workflow_out="$(board_run some-other-workflow)"
check "...while the same rollup under another workflow name fires" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$other_workflow_out"

# A check name is free text, and the ROLLUP record carries JSON text beside
# a tab. Emitted through @tsv that text was escaped a SECOND time, so a name
# carrying a quote reached the classifier unparseable: the head landed on the
# empty string — not FAILURE, so silent, and silent for a reason no caller of
# checks_state could name. The fixture goes through the real query jq in the
# stub rather than a hand-written record, or it would be testing this file's
# escaping instead of the sweep's. The name carries a quote and a backslash
# at once, and the head under it is genuinely red.
stall_open_pr 900 801 "[$(stall_ck 'say "hi"\back' FAILURE)]"
stall_chain claimed
quoted_name_out="$(board_run)"
check "a check name carrying a quote still reaches the classifier" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$quoted_name_out"
check "...and no record reached jq malformed" 1 "" \
  grep -qF 'parse error' <<<"$quoted_name_out"

# -- the four states that are not FAILURE, one fixture apiece (D4) ----------
# Each case runs in the file's own shell rather than a `bash -c` subshell:
# the fixture builders above are shell functions, and a subshell that cannot
# see them fails, produces no flag, and satisfies a must-not-fire assertion
# without ever reaching the sweep. So every must-not-fire case in this family
# carries a companion asserting the board was really swept: a silence a dead
# sweep also produces is not evidence of the term it stands for — that is
# exactly how a broken #208 fixture passed behind a green suite here (#440).
stall_open_pr 900 801 "[$(stall_ck test SUCCESS)]"
stall_chain claimed
green_head_out="$(board_run)"
check "a green head is silent" 1 "" \
  grep -qF ': stalled graph flag' <<<"$green_head_out"
check "...and the green-head board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$green_head_out"
stall_open_pr 900 801 "[$(stall_ck test QUEUED)]"
stall_chain claimed
pending_head_out="$(board_run)"
check "a pending head is silent" 1 "" \
  grep -qF ': stalled graph flag' <<<"$pending_head_out"
check "...and the pending-head board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$pending_head_out"
stall_open_pr 900 801 "[]"
stall_chain claimed
none_head_out="$(board_run)"
check "a head with no checks at all (NONE) is silent" 1 "" \
  grep -qF ': stalled graph flag' <<<"$none_head_out"
check "...and the no-checks board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$none_head_out"
# UNREADABLE in its own case, and it is the one that is easiest to get wrong:
# a failed read is not a failed check, and #101 D1 forbids the sweep
# recomputing on facts it did not read. The PR arrives with no commit node.
stall_open_pr 900 801 NOCOMMIT
stall_chain claimed
unreadable_head_out="$(board_run)"
check "an unreadable head is silent — a failed read is not a failed check" 1 "" \
  grep -qF ': stalled graph flag' <<<"$unreadable_head_out"
check "...and the unreadable-head board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$unreadable_head_out"

# -- the remaining terms of the conjunction, each broken alone --------------
stall_open_pr 900 801 "[$(stall_ck test FAILURE)]"
board_issue 801 claimed 'alpha-stall.sh — the claimed red head' '' 1
board_issue 802 blocked 'bravo-stall.sh — the only issue behind it' 'Blocked by #801.'
board_assemble 801 802
shallow_out="$(board_run)"
check "a two-deep chain behind the same red claimed head is silent" 1 "" \
  grep -qF ': stalled graph flag' <<<"$shallow_out"
check "...and the two-deep board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$shallow_out"
for head_state in ready blocked; do
  stall_open_pr 900 801 "[$(stall_ck test FAILURE)]"
  stall_chain "$head_state"
  head_state_out="$(board_run)"
  check "a three-deep chain whose head is $head_state is silent" 1 "" \
    grep -qF ': stalled graph flag' <<<"$head_state_out"
  check "...and the $head_state-head board was really swept" 0 "" \
    grep -qF 'issueflow: reconciled.' <<<"$head_state_out"
done
# A claimed red head with nothing queued behind it is one builder's fix round
# and no board's business — the depth term carrying its own weight at zero.
stall_open_pr 900 801 "[$(stall_ck test FAILURE)]"
board_issue 801 claimed 'alpha-stall.sh — a lone claimed red head' '' 1
board_assemble 801
lone_out="$(board_run)"
check "a claimed red head with nothing behind it is silent" 1 "" \
  grep -qF ': stalled graph flag' <<<"$lone_out"
check "...and the lone-head board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$lone_out"
# The head is claimed and three-deep, but its open PR belongs to another
# issue: the red head must be THIS head's, never any red PR on the board.
stall_open_pr 900 803 "[$(stall_ck test FAILURE)]"
stall_chain claimed
foreign_pr_out="$(board_run)"
check "a red PR belonging to another issue in the chain is not this head's" 1 "" \
  grep -qF ': stalled graph flag' <<<"$foreign_pr_out"
check "...and the foreign-PR board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$foreign_pr_out"

# -- the per-family marker contract, on this family (#293 D4) ---------------
# The board stub records a posted comment in its edit log and not in the
# comment thread the next sweep reads, so the standing marker is seeded by
# hand exactly as the deep family's own fixture seeds it.
stall_open_pr 900 801 "[$(stall_ck test FAILURE)]"
stall_chain claimed
first_word_out="$(board_run)"
check "the shape speaks once" 0 "1" flag_count stalled "$first_word_out"
stalled_display='≥3:#801 > #802 > #803'
stalled_identity='nodes=#801,#802,#803;edges=#801>#802,#802>#803'
# `created_at` is not decoration here: #801 is `claimed` and assigned, so the
# claim clock reads this thread, and a comment without a date skips the issue
# on an unreadable fact — which would make the silence below the sweep never
# reaching the flag rather than the marker suppressing it.
jq -n --arg at "$(iso_at "$INOW")" \
  --arg b "<!-- issueflow:$(state_marker graph-stalled "$(graph_marker_state "$stalled_display" "$stalled_identity")") -->
said already" \
  '[{"user": {"login": "sweep-bot"}, "created_at": $at, "body": $b}]' \
  >"$BOARD/repos_owner_repo_issues_801_comments.json"
board_assemble_keep 801 802 803
persisting_out="$(board_run)"
check "a persisting stalled shape is silent after its first word" 1 "" \
  grep -qF 'issueflow: #801: stalled graph flag' <<<"$persisting_out"
# The comment above names the reason this guard belongs here more than
# anywhere: this silence is the one most easily produced by the sweep
# skipping the issue rather than by the marker suppressing the word.
check "...and the persisting-shape board was really swept" 0 "" \
  grep -qF 'issueflow: reconciled.' <<<"$persisting_out"
board_issue 804 blocked 'delta-stall.sh — a newly extended tail' 'Blocked by #803.'
printf '[]\n' >"$BOARD/repos_owner_repo_issues_804_comments.json"
board_assemble_keep 801 802 803 804
extended_out="$(board_run)"
check "extending the stalled chain changes its marker and speaks" 0 \
  'issueflow: #801: stalled graph flag — ≥3:#801 > #802 > #803' \
  printf '%s\n' "$extended_out"

# -- today's board draws nothing (the post-ruling shape, live) --------------
# #249 the `blocked` sink, this issue `claimed` with no open PR and a gate
# member, #307 and #311 `blocked`. The `claimed` member is the case D3b would
# flag if membership were read wrong, which is why it is here.
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$BOARD/graphql-open.json"
board_issue 249 blocked,release 'Release 0.6.0 — the board empties into the tag' \
  "$(printf '%s\n' 'Blocked by #307.' '' '## Members' '- #293' '- #307')"
board_issue 293 claimed 'issueflow-reconcile — the sweep flags what the window and collision rules forbid' '' 1
board_issue 307 blocked 'test/issueflow-reconcile.test.sh — the ruling pre-read is unpinned' \
  'Blocked by #293.'
board_issue 311 blocked 'docs/CONSUMERS.md — a deliberate non-member' 'Blocked by #249.'
board_assemble 249 293 307 311
today_out="$(board_run)"
check "today's board draws no collision flag" 1 "" grep -qF ': collision flag' <<<"$today_out"
check "...and no window flag: the claimed member is a member" 1 "" \
  grep -qF ': window flag' <<<"$today_out"
check "...and still reports a whole pass" 0 'issueflow: reconciled.' \
  printf '%s\n' "$today_out"

# -- the defect's own board (#343): the shut window that read as standing ----
# #317 as it stood from its mint until #249 closed at 2026-08-05T11:12Z, and
# the shape crew's fifteen version epics were in at 0.6.0 adoption: a version
# epic declaring its predecessor exactly as *Gates* instructs and enumerating
# no members. Read as a gate that made the sink a carrier, THIS is a standing
# window — for precisely the interval in which the window is shut — and every
# `ready` issue the documented procedure had just admitted is told it is
# illegitimate. Read as a membership record it is what it is: nothing.
board_issue 317 epic,release '0.7.0 — rc becomes native' 'Blocked by #249.'
board_issue 249 epic,release 'Release 0.6.0 — the predecessor, still open' ''
board_issue 343 ready 'RELEASES.md + TRIAGE.md — membership gets its own record'
board_issue 345 ready 'actions/issueflow-reconcile — a failed dependency read'
board_assemble 317 249 343 345
shut_window_out="$(board_run)"
check "the shut window's board replays green" 0 "" test $? -eq 0
check "an epic declaring an open predecessor stands no window" 1 "" \
  grep -qF ': window flag' <<<"$shut_window_out"
check "...so the ready issues it would have accused are left alone" 1 "" \
  grep -qE '#(343|345): window flag' <<<"$shut_window_out"
check "...and no window state naming it is ever rendered" 1 "" \
  grep -qF 'under #317' <<<"$shut_window_out"
check "...and the board is still swept whole" 0 'issueflow: reconciled.' \
  printf '%s\n' "$shut_window_out"
# The over-correction guard, on the same board: the moment that epic
# enumerates an open member, the window stands and the non-member flags. A
# change that merely suppressed window detection would pass every assertion
# above and destroy the guard #292 exists for.
board_issue 317 epic,release '0.7.0 — rc becomes native' \
  "$(printf '%s\n' 'Blocked by #249.' '' '## Members' '- #343 — the first member')"
board_assemble 317 249 343 345
opened_window_out="$(board_run)"
check "the same epic enumerating an open member does stand a window" 0 \
  'issueflow: #345: window flag — an unblocked non-member under #317' \
  printf '%s\n' "$opened_window_out"
check "...and its enumerated member is not flagged" 1 "" \
  grep -qF 'issueflow: #343: window flag' <<<"$opened_window_out"
check "...one window flag on that board, and only one" 0 "1" \
  flag_count window "$opened_window_out"

# -- #364: a long release body must not kill the sweep ----------------------
# The hourly sweep died at exit 2 from 2026-08-10T04:24:00Z, reconciling
# nothing, on two lines: `jq: error: writing output failed: Broken pipe` and a
# status. `membership_references` bounds the record at its terminating heading
# with an awk `exit` (#349 D8, kept by #364 D2); fed through a pipe, that
# `exit` closed `jq`'s reader while `jq` was still writing, and `pipefail`
# carried the EPIPE out through the command substitution.
#
# THE FIXTURE FEEDS THE SWEEP'S OWN PATH (#364 D3). A case that hands the
# parser a herestring itself passes before the fix and after it and proves
# nothing about the call site; this one drives the script as a subprocess
# behind the stubbed gh, with errexit and pipefail live, which is the runner's
# own shape.
#
# The body is sized past ANY platform's buffering rather than past this one's.
# The failing size is a property of the runner's `jq` and `mawk` builds and not
# of this repository — the runner broke below 75868 bytes while this box
# survived past 227608 — so a fixture tuned to either machine reds only on the
# unlucky one.
board_issue_bodyfile() { # $1 number, $2 labels(csv), $3 title, $4 body FILE
  # board_issue's sibling for a body no argv can carry: a single argument is
  # capped at 128 KiB on Linux (MAX_ARG_STRLEN), so `--arg` cannot take a body
  # of the size this case exists to build. `--rawfile` reads it from the file.
  local labels_json
  labels_json="$(printf '%s' "$2" | tr ',' '\n' \
    | jq -R . | jq -sc 'map(select(. != "") | {name: .})')"
  jq -n --argjson n "$1" --argjson labels "$labels_json" --arg t "$3" \
    --rawfile b "$4" --arg at "$(iso_at "$INOW")" \
    '{number: $n, state: "open", title: $t, body: $b, labels: $labels,
      created_at: $at, user: {login: "triage-one"}, assignees: []}' \
    >"$BOARD/repos_owner_repo_issues_$1.json"
}

big_body_file="$TMP/364-release-body.txt"
{
  printf '%s\n' \
    'Blocked by #343.' \
    '' \
    '## Members' \
    '- #343 — the first member, claimed' \
    '- #345 — the second, so the record is never a single row' \
    '' \
    '## Waves'
  # Everything past the terminating heading is what the parser abandons, and
  # is exactly what the writer was still holding when the pipe closed. #317's
  # own body is measurements struck rather than deleted, so this stands in for
  # the shape the doctrine actually produces.
  awk 'BEGIN { for (i = 0; i < 20000; i++)
    printf "| run %d | schedule | consumed %d bytes before the exit | superseded, struck rather than deleted |\n",
      i, i * 7 }'
} >"$big_body_file"
big_body_bytes="$(wc -c <"$big_body_file")"
# The fixture going vacuous by shrinking is the failure this pins: a
# regression case that cannot red on the defect it names is not a case at all.
check "the #364 fixture body is past 1 MiB, so no platform's buffering absorbs it" 0 "" \
  test "$big_body_bytes" -gt 1048576

printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$BOARD/graphql-open.json"
board_issue_bodyfile 253 blocked,release \
  'Release 0.6.4 — a release body at the length this board produces' "$big_body_file"
board_issue 343 claimed 'actions/issueflow-reconcile — the first enumerated member' '' 1
board_issue 345 ready 'lib/changelog.sh — the second enumerated member' ''
board_issue 350 ready 'docs/CONSUMERS.md — an unblocked non-member' ''
board_assemble 253 343 345 350
big_out="$(board_run)"
big_rc=$?
check "a release body past 1 MiB no longer kills the sweep" 0 "" test "$big_rc" -eq 0
check "...and the pass is reported whole" 0 'issueflow: reconciled.' \
  printf '%s\n' "$big_out"
check "...with no broken pipe anywhere in its output" 1 "" \
  grep -qiF 'broken pipe' <<<"$big_out"
# The parse still happened, and is read back through the sweep's own verdict
# rather than trusted: the membership record is what decides who is a member.
check "...and the record parsed: the non-member draws the window flag" 0 \
  'issueflow: #350: window flag — an unblocked non-member under #253' \
  printf '%s\n' "$big_out"
check "...while both enumerated members are left alone" 1 "" \
  grep -qE '#(343|345): window flag' <<<"$big_out"
check "...one window flag on that board, and only one" 0 "1" \
  flag_count window "$big_out"
# D9: the stage report is silent and inert on a healthy run.
check "...and no stage report is printed on a green sweep" 1 "" \
  grep -qE 'issueflow: (the membership parse:|could not parse the release window membership|could not compute the board flags)' \
  <<<"$big_out"

# -- #364 D5: the fix changes the writer's status, never the parse ----------
# Same body, both feeds, same records. The parse was never wrong at any size —
# only the writer's exit status differed, and that status is what killed the
# sweep. Bracketed as an exact set: a substring assertion would accept a
# superset and this is the criterion that a member never silently joins.
big_body="$(cat "$big_body_file")"
big_open=$'253\n343\n345\n350'
here_records="$(release_window_members 253 "$big_open" <<<"$big_body")"
pipe_records="$(printf '%s\n' "$big_body" | release_window_members 253 "$big_open")"
check "the parsed member set is identical by herestring and by pipe" 0 "" \
  test "$here_records" = "$pipe_records"
check "...and it is the record's own set, exactly" 0 "" \
  test "$(cut -f2 <<<"$here_records")" = $'343\n345'
check "...carried by the release issue it was read from, exactly" 0 "" \
  test "$(cut -f1 <<<"$here_records" | sort -u)" = "253"

# -- #364 D8: a pre-loop death names the stage it died in -------------------
# Both failures of the 04:24Z class printed `jq`'s bare message and an exit
# code after 61 seconds of work, and nothing that placed the death above a
# loop which had never started. Forcing the membership feed to fail is what
# proves the report is wired to the stage rather than to a healthy path.
mkdir -p "$TMP/stage-stub"
issueflow_real_jq="$(command -v jq)"
cat >"$TMP/stage-stub/jq" <<EOF
#!/usr/bin/env bash
# Fails ONLY the membership body extraction — the sweep's sole \`--argjson\`
# caller (#364). Every other jq call, the board read above this stage and the
# flag computation below it included, is passed straight through, so the
# stage the report names is the stage that actually died.
for issueflow_arg in "\$@"; do
  if [ "\$issueflow_arg" = --argjson ]; then
    printf 'jq: error: writing output failed: Broken pipe\n' >&2
    exit 2
  fi
done
exec "$issueflow_real_jq" "\$@"
EOF
chmod +x "$TMP/stage-stub/jq"
stage_run() {
  : >"$BOARD/edits"
  env PATH="$TMP/stage-stub:$ARRIVAL/stub:$PATH" GH_FIXTURES="$BOARD" ISSUEFLOW_NOW="$INOW" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
}
stage_out="$(stage_run)"
stage_rc=$?
# D9: it reports and RE-RAISES. A named stage that swallowed the status would
# be the failure this whole issue is about, arriving from the other side — and
# a stage that reported a GENERIC status would lose the one fact the incident
# log did carry. `2` is the stub jq's own exit code, arriving unchanged.
check "a forced membership-parse failure still reds the sweep" 0 "" test "$stage_rc" -ne 0
check "...at the status the stage actually failed with, not a generic one" 0 "" \
  test "$stage_rc" -eq 2
check "...and the pre-loop region names the stage" 0 \
  'issueflow: could not parse the release window membership' \
  printf '%s\n' "$stage_out"
check "...naming the release issue whose record it died on" 0 \
  'issueflow: the membership parse: could not take release #253' \
  printf '%s\n' "$stage_out"
check "...rather than leaving only jq's bare message to read" 0 "" \
  test "$(grep -c '^issueflow: ' <<<"$stage_out")" -ge 2
check "...and never reports a pass it did not make" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$stage_out"
check "...nor writes one label over a board it never swept" 1 "" test -s "$BOARD/edits"

# -- #364 D1 is a call-site property, so it is pinned at the source ---------
# The defect was one call site against a file that otherwise already used the
# correct shape — `epic_references`, the other early-exiting parser, was safe
# by its call site rather than by its own construction. A property held only
# by every author remembering it is one the next composition reinstates, so it
# is pinned here, the shape the staged-mutation pin below already uses.
parser_pipe_call_sites() {
  grep -nE "\| *(membership_references|epic_references|blocked_references|refs_references|release_window_members|release_window_gate)" \
    "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" || true
}
check "no parser call site in the sweep is fed by a pipe" 0 "" \
  test -z "$(parser_pipe_call_sites)"
# And the pin must be able to see what it is guarding: a renamed parser would
# leave the grep above matching nothing and reporting that as compliance.
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...and every parser the pin names still exists to be guarded" 0 "" \
  bash -c 'for f in membership_references epic_references blocked_references \
      refs_references release_window_members release_window_gate; do
    grep -qE "^$f\(\)" "$1" || { printf "the pin names a parser that is gone: %s\n" "$f"; exit 1; }
  done' _ "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh"

# -- the invariant is enforced at the source, not remembered ----------------
# Staging only holds while every mutation goes through run(). A future call
# site reaching gh directly would reopen this hole silently, so it is pinned
# here rather than left to review — the shape lib/ruling.sh already uses for
# #50 D9. reconcile_opened_issue is deliberately exempt: it runs outside the
# per-issue subshell, under live errexit, and stages nothing (#247 D8).
mutation_calls() {
  grep -nE '(^|[^_[:alnum:]])gh issue (edit|comment)' \
    "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" "$ROOT/lib/ruling.sh" \
    | grep -vE '^\S+:[0-9]+: *#' || true
}
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "every issue mutation on this surface goes through run()" 0 "" \
  bash -c 'while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *"run gh issue "*) ;; *) printf "unstaged mutation: %s\n" "$line"; exit 1 ;; esac
  done <<<"$1"' _ "$(mutation_calls)"
check "...and the pin sees the call sites it is guarding" 0 "" \
  test "$(mutation_calls | wc -l)" -ge 8

summary
