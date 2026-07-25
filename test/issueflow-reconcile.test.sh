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

# The dogfood caller and reusable workflow must expose the same runtime facts
# as the documented consumer stub. Static pins catch YAML blocks drifting to
# the adjacent composite step, which otherwise fails only after merge.
check "dogfood caller wakes on issue events" 0 "  issues:" \
  grep -F "  issues:" "$ROOT/.github/workflows/self-labels.yml"
dogfood_pr_step="$(sed -n \
  '/name: reconcile state + stale (dogfood/,/name: reconcile issue flow/p' \
  "$ROOT/.github/workflows/labels.yml")"
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
check "unreadable blocker is flagged" 0 "FLAG_UNPARSEABLE" blocked_decision "12" "UNKNOWN"
check "cross-repo-only blocker is flagged distinctly" 0 "FLAG_CROSS_REPO" \
  blocked_decision "" "" "rig#112"
check "cross-repo blocker prevents false promotion when locals close" 0 "FLAG_CROSS_REPO" \
  blocked_decision "9" "CLOSED" "rig#9"
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

issue_stub_gh() {
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
    [ ! -f "$file.error" ] || return 1
    [ -f "$file" ] || { printf '[]\n'; return 0; }
    if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
  elif [ "$1" = issue ] && [ "$2" = comment ]; then
    local n="$3" body="" file
    shift 3
    while [ $# -gt 0 ]; do
      case "$1" in --body) body="$2"; shift ;; esac
      shift
    done
    printf '%s\n----\n' "$body" >>"$TMP/posted-$n"
    file="$TMP/repos_owner_repo_issues_${n}_comments.json"
    [ -f "$file" ] || printf '[]\n' >"$file"
    jq --arg b "$body" --arg at "$(iso_at "$INOW")" \
      '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/posted","body":$b}]' \
      "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  elif [ "$1" = issue ] && [ "$2" = edit ]; then
    printf '%s\n' "$*" >>"$TMP/issue-edits"
  fi
}

issue_probe() { # $1 issue, $2 labels, $3 assignees, $4 open PR, $5 merged PR, $6 body
  (
    local assignees="${3:-1}" open_pr="${4:-false}" merged_ref_pr="${5:-}"
    local body="${6:-}" assignee_json='[]'
    [ "$assignees" -eq 0 ] || assignee_json='[{"login":"owner-bot"}]'
    REPO=owner/repo NOW="$INOW"
    ISSUE_LABELS="$2"
    ISSUE_JSON="$(jq -n --arg at "$(iso_at $((INOW - 10 * 86400)))" \
      --argjson assignees "$assignee_json" --arg body "$body" \
      '{created_at: $at, assignees: $assignees, body: $body}')"
    if [ "$open_pr" = true ]; then OPEN_PR_ISSUES="$1"; else OPEN_PR_ISSUES=""; fi
    if [ -n "$merged_ref_pr" ]; then
      MERGED_REF_PR_RECORDS="$(printf '%s\t%s\n' "$1" "$merged_ref_pr")"
    else
      MERGED_REF_PR_RECORDS=""
    fi
    run() { "$@"; }
    gh() { issue_stub_gh "$@"; }
    reconcile_issue "$1" 2>&1
  )
}

tfix() { printf '%s/repos_owner_repo_issues_%s_timeline.json' "$TMP" "$1"; }
cfix() { printf '%s/repos_owner_repo_issues_%s_comments.json' "$TMP" "$1"; }

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
transition="$(issue_probe 35 claimed 1 false 350 $'- [x] built\n- [ ] verify dispatch\n  * [ ] confirm warning clears')"
check "merged Refs + unchecked criteria transitions in the sweep body" 0 "" \
  grep -q 'merged Refs PR -> post-merge; claim released' <<<"$transition"
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
check "...and causes no comment or edit" 1 "" test -f "$TMP/posted-36"

printf '[]\n' >"$(cfix 37)"
issue_probe 37 post-merge 1 >/dev/null
check "assigned post-merge is flagged" 0 "" \
  grep -qF '<!-- issueflow:post-merge-assigned -->' "$TMP/posted-37"
check "...and the hand-assignment is not repaired" 1 "" \
  grep -qF -- 'issue edit 37' "$TMP/issue-edits"

# -- non-triggers stay byte-for-byte outside the transition ------------------
recent_timeline() {
  jq -n --arg at "$(iso_at $((INOW - 60)))" \
    '[{"event":"assigned","created_at":$at}]' >"$(tfix "$1")"
  printf '[]\n' >"$(cfix "$1")"
}
edit_count_before="$(wc -l <"$TMP/issue-edits")"
recent_timeline 38
open_refs="$(issue_probe 38 claimed 1 true 380 '- [ ] verify after merge')"
check "open Refs PR leaves the issue exactly as found" 0 "" \
  test -z "$open_refs"
# shellcheck disable=SC2016 # positional parameters belong to bash -c
check "...with no edit or comment" 0 "" \
  bash -c 'test "$1" -eq "$(wc -l <"$2")" && test ! -f "$3"' _ \
  "$edit_count_before" "$TMP/issue-edits" "$TMP/posted-38"

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
  endpoint="" jqexpr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq) jqexpr="$2"; shift ;;
      -f|-F) shift ;;
      -*) ;;
      *) [ -n "$endpoint" ] || endpoint="$1" ;;
    esac
    shift
  done
  file="$GH_FIXTURES/$(printf '%s' "$endpoint" | tr '/?&=' '____').json"
  [ ! -f "$file.error" ] || exit 1
  if [ -f "$file" ]; then payload="$(cat "$file")"; else payload='[]'; fi
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$payload"; else printf '%s\n' "$payload"; fi
  exit 0
fi
if [ "$1" = issue ]; then printf '%s\n' "$*" >>"$GH_FIXTURES/edits"; exit 0; fi
echo "gh stub: unexpected call: gh $*" >&2
exit 97
EOF
chmod +x "$ARRIVAL/stub/gh"
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql.json"
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

# The merged-Refs transition must survive the executable's set -e path too.
# Keep this at main() granularity: the GraphQL gather and loop are the code
# a sourced decision probe cannot exercise (#91's lesson).
printf '%s\n' \
  '{"data":{"repository":{"pullRequests":{"nodes":[{"number":400,"body":"Refs #40","closingIssuesReferences":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  >"$ARRIVAL/fixtures/graphql.json"
printf '[{"number":40}]\n' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_state_open_per_page_100.json"
jq -n --arg at "$(iso_at "$INOW")" \
  '{number:40,user:{login:"triage-one"},created_at:$at,body:"- [x] built\n- [ ] verify live label",labels:[{name:"claimed"}],assignees:[{login:"builder"}]}' \
  >"$ARRIVAL/fixtures/repos_owner_repo_issues_40.json"
printf '[]\n' >"$ARRIVAL/fixtures/repos_owner_repo_issues_40_comments.json"
: >"$ARRIVAL/fixtures/edits"
subprocess_out="$(
  env PATH="$ARRIVAL/stub:$PATH" GH_FIXTURES="$ARRIVAL/fixtures" \
    REPO=owner/repo LABELS_CONF="$ARRIVAL/labels.conf" \
    bash "$ROOT/actions/issueflow-reconcile/issueflow-reconcile.sh" 2>&1
)"
subprocess_rc=$?
check "executable sweep transitions merged Refs work" 0 "" \
  test "$subprocess_rc" -eq 0
check "...reaches the transition through GraphQL and the issue loop" 0 "" \
  grep -qF '#40: merged Refs PR -> post-merge; claim released' <<<"$subprocess_out"
check "...and performs the release edit from the executable path" 0 "" \
  grep -qF -- 'issue edit 40 -R owner/repo --remove-assignee builder --remove-label claimed --add-label post-merge' \
  "$ARRIVAL/fixtures/edits"

# D2 preserved: only the deliberate stand-downs changed; a genuine failure on
# the arrival path still kills the run loudly.
: >"$ARRIVAL/fixtures/repos_owner_repo_issues_91.json.error"
err_out="$(arrival_run 2>&1)"
err_rc=$?
check "a dead API on the arrival path still fails the run (D2)" 0 "" \
  test "$err_rc" -eq 1
check "...and the sweep does not run over a lying arrival" 1 "" \
  grep -qF 'issueflow: reconciled.' <<<"$err_out"

summary
