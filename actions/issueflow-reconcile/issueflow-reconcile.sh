#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in comment bodies are Markdown literals
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
else
  set -u
fi

# The issue-flow half of the labels state machine. Decisions are pure strings;
# API calls live below the divider so fixture tests can exercise every branch.

ISSUEFLOW_NOW="${ISSUEFLOW_NOW:-$(date -u +%s)}"
ISSUEFLOW_STALE_HOURS="${ISSUEFLOW_STALE_HOURS:-48}"
[[ "$ISSUEFLOW_NOW" =~ ^[0-9]+$ ]] || {
  echo "issueflow: ISSUEFLOW_NOW must be UTC epoch seconds" >&2
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 1; else return 1; fi
}
[[ "$ISSUEFLOW_STALE_HOURS" =~ ^[0-9]+$ ]] || {
  echo "issueflow: ISSUEFLOW_STALE_HOURS must be a non-negative integer" >&2
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 1; else return 1; fi
}
NOW="$ISSUEFLOW_NOW"
STALE_AFTER=$((ISSUEFLOW_STALE_HOURS * 3600))
QUEUE_LABELS=(ready claimed blocked post-merge)
TRIAGE_ACTORS=()

# The needs-ruling invariants (#52) — one implementation for both surfaces.
# shellcheck source=lib/ruling.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/ruling.sh"

log() { printf 'issueflow: %s\n' "$*"; }
run() { if [ -n "${DRY_RUN:-}" ]; then log "DRY_RUN: $*"; else "$@"; fi; }

load_issueflow_config() { # $1 = labels.conf
  local conf="$1" line seen=false
  [ -f "$conf" ] || { echo "issueflow: missing config: $conf" >&2; return 1; }
  TRIAGE_ACTORS=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      triage-actors=*)
        [ "$seen" = false ] || {
          echo "issueflow: duplicate triage-actors line in $conf" >&2
          return 1
        }
        seen=true
        read -r -a TRIAGE_ACTORS <<<"${line#triage-actors=}"
        [ "${#TRIAGE_ACTORS[@]}" -gt 0 ] || {
          echo "issueflow: triage-actors must name at least one actor in $conf" >&2
          return 1
        }
        ;;
    esac
  done <"$conf"
  [ "$seen" = true ] || {
    echo "issueflow: missing triage-actors= line in $conf" >&2
    return 1
  }
}

is_triage_actor() {
  local actor
  for actor in "${TRIAGE_ACTORS[@]}"; do
    [ "$actor" = "$1" ] && return 0
  done
  return 1
}

has_issue_label() { grep -qxF "$1" <<<"$ISSUE_LABELS"; }

queue_decision() { # labels on stdin -> KEEP | ADD_NEEDS_TRIAGE | FLAG_CONFLICT
  local labels count=0 label categories=0
  labels="$(cat)"
  grep -qxF needs-triage <<<"$labels" && categories=$((categories + 1))
  grep -qxF epic <<<"$labels" && categories=$((categories + 1))
  for label in "${QUEUE_LABELS[@]}"; do
    if grep -qxF "$label" <<<"$labels"; then count=$((count + 1)); fi
  done
  [ "$count" -gt 0 ] && categories=$((categories + 1))
  if [ "$categories" -eq 0 ]; then echo ADD_NEEDS_TRIAGE
  elif [ "$categories" -gt 1 ] || [ "$count" -gt 1 ]; then echo FLAG_CONFLICT
  else echo KEEP
  fi
}

author_decision() { # $1 = true when author is triage; labels on stdin
  local triage="$1" labels
  labels="$(cat)"
  if [ "$triage" = false ] && ! grep -qxF needs-triage <<<"$labels"; then
    echo ADD_NEEDS_TRIAGE
  else echo KEEP
  fi
}

claim_decision() { # $1 assignee count, $2 linked open PR, $3 age seconds
  local assignees="$1" open_pr="$2" age="$3"
  # Staleness wins over missing ownership: a stale unassigned claim is
  # derivably reclaimable, while a recent unassigned claim needs triage.
  if [ "$open_pr" = false ] && [ "$age" -gt "$STALE_AFTER" ]; then echo RECLAIM
  elif [ "$assignees" -eq 0 ]; then echo FLAG_UNASSIGNED
  else echo KEEP
  fi
}

claim_clock_exempt() { # labels on stdin -> EXEMPT | SWEEP
  local labels
  labels="$(cat)"
  # Cross-repo work has no local closing PR by construction (#68), so its
  # deliberate silence must share the one claim-clock gate with rulings.
  if grep -qxF offsite <<<"$labels" \
    || [ "$(ruling_stale_exempt <<<"$labels")" = EXEMPT ]; then
    echo EXEMPT
  else
    echo SWEEP
  fi
}

claim_decision_at() { # $1 assignee count, $2 linked open PR, $3 last activity epoch
  claim_decision "$1" "$2" "$((NOW - $3))"
}

claim_reclaim_marker() { # $1 = last activity epoch
  printf 'claim-reclaimed-%s\n' "$1"
}

refs_references() { # PR body on stdin -> local issue numbers named by Refs
  awk '
    tolower($0) ~ /(^|[^[:alnum:]_-])refs([[:space:]]|:)/ { print }
  ' | issue_references \
    | awk -F '\t' '$1 == "LOCAL" { print $2 }' | sort -nu
}

unchecked_criteria() { # issue body on stdin -> unchecked task-list lines verbatim
  awk '/^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]/ { print }'
}

post_merge_decision() { # $1 merged Refs-linked PR, unchecked criteria on stdin
  local merged="$1" unchecked
  unchecked="$(cat)"
  if [ "$merged" = true ] && [ -n "$unchecked" ]; then echo TRANSITION
  else echo KEEP
  fi
}

issue_references() { # text on stdin -> LOCAL/CROSS<TAB>reference
  # A qualified reference belongs to another repository. Classify the whole
  # token before extracting numbers so rig#112 can never become local #112.
  { grep -Eo '([[:alnum:]_.-]+/)?[[:alnum:]_.-]+#[0-9]+|#[0-9]+' || true; } \
    | awk '
      index($0, "#") == 1 { print "LOCAL\t" substr($0, 2); next }
      { print "CROSS\t" $0 }
    '
}

blocked_reference_records() { # body on stdin -> classified reference records
  # Dependency declarations sometimes soft-wrap after a comma. Continue
  # through the first sentence terminator; if prose omits one, conservatively
  # retain later references so ambiguity can keep an issue blocked, never
  # promote it prematurely.
  awk '
    {
      line = $0
      lower = tolower(line)
      if (!active) {
        marker = "blocked by"
        start = index(lower, marker)
        if (!start) next
        line = substr(line, start + length(marker))
        active = 1
      }
      if (line ~ /[.;]/) {
        sub(/[.;].*/, "", line)
        print line
        exit
      }
      print line
    }
  ' | issue_references
}

blocked_references() { # body on stdin -> local issue numbers, one per line
  blocked_reference_records | awk -F '\t' '$1 == "LOCAL" { print $2 }' | sort -nu
}

blocked_cross_references() { # body on stdin -> qualified refs, one per line
  blocked_reference_records | awk -F '\t' '$1 == "CROSS" { print $2 }' | sort -u
}

blocked_decision() { # $1 local refs, $2 OPEN/CLOSED states, $3 cross-repo refs
  local refs="$1" states="$2" cross_refs="${3:-}"
  if [ -n "$cross_refs" ]; then echo FLAG_CROSS_REPO
  elif [ -z "$refs" ]; then echo FLAG_UNPARSEABLE
  elif grep -qxF OPEN <<<"$states"; then echo KEEP
  elif grep -qxF UNKNOWN <<<"$states"; then echo FLAG_UNPARSEABLE
  else echo READY
  fi
}

epic_references() { # markdown task-list issue references from body on stdin
  awk '
    tolower($0) ~ /^##[[:space:]]+task list[[:space:]]*$/ { in_list = 1; next }
    in_list && /^#/ { exit }
    in_list && /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ { print }
  ' | issue_references \
    | awk -F '\t' '$1 == "LOCAL" { print $2 }' | sort -nu
}

epic_decision() { # $1 refs, $2 states
  local refs="$1" states="$2"
  if [ -n "$refs" ] && ! grep -Eq '^(OPEN|UNKNOWN)$' <<<"$states"; then echo NUDGE
  else echo KEEP
  fi
}

offsite_cross_referenced_prs() { # timeline JSON on stdin -> owner/repo#N
  jq -r '
    .[]
    | select(.event == "cross-referenced")
    | .source.issue
    | select(.pull_request != null)
    | select(.repository.full_name != null and .number != null)
    | "\(.repository.full_name)#\(.number)"
  ' | sort -u
}

offsite_resolved_decision() { # PR states on stdin -> NUDGE | QUIET
  local states
  states="$(cat)"
  if [ -n "$states" ] && ! grep -Eq '^(OPEN|UNKNOWN)$' <<<"$states"; then
    echo NUDGE
  else
    echo QUIET
  fi
}

# API edge. Marker comments make warnings and nudges idempotent across sweeps.
ensure_comment() { # $1 issue, $2 marker, $3 message
  local n="$1" marker="$2" message="$3"
  if gh api --paginate "repos/$REPO/issues/$n/comments" --jq '.[].body' \
      | grep -qF "<!-- issueflow:$marker -->"; then return; fi
  run gh issue comment "$n" -R "$REPO" --body "<!-- issueflow:$marker -->
$message" >/dev/null
}

reference_states() {
  local ref state
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    state="$(gh api "repos/$REPO/issues/$ref" --jq '.state' 2>/dev/null || echo UNKNOWN)"
    case "$state" in open) echo OPEN ;; closed) echo CLOSED ;; *) echo UNKNOWN ;; esac
  done
}

offsite_pr_states() {
  local ref repo number state
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    repo="${ref%#*}"
    number="${ref##*#}"
    state="$(gh api "repos/$repo/pulls/$number" --jq '.state' 2>/dev/null || echo UNKNOWN)"
    case "$state" in open) echo OPEN ;; closed) echo CLOSED ;; *) echo UNKNOWN ;; esac
  done
}

offsite_timeline() { # unreadable timelines are deliberately silent
  gh api --paginate "repos/$REPO/issues/$1/timeline" 2>/dev/null || return 1
}

last_issue_activity() {
  local n="$1" created="$2" latest
  latest="$({
      printf '%s\n' "$created"
      gh api --paginate "repos/$REPO/issues/$n/comments" --jq '.[].created_at'
      # Assignment is the claim itself. Ignoring it would let an old issue be
      # reclaimed in the seconds between assignment and its required draft PR.
      gh api --paginate "repos/$REPO/issues/$n/timeline" \
        --jq '.[] | select(.event == "assigned") | .created_at'
    } \
    | sort | tail -n1)"
  date -d "$latest" +%s
}

reconcile_issue() {
  local n="$1" decision refs cross_refs states age assignees open_pr=false label owners
  local merged_ref=false unchecked="" remove_claimed=claimed
  decision="$(queue_decision <<<"$ISSUE_LABELS")"
  case "$decision" in
    ADD_NEEDS_TRIAGE)
      run gh issue edit "$n" -R "$REPO" --add-label needs-triage >/dev/null
      log "#$n: needs-triage (no queue state)" ;;
    FLAG_CONFLICT)
      ensure_comment "$n" queue-conflict \
        'The issue-flow sweep found conflicting queue labels. It cannot infer intent safely; triage must leave exactly one of `needs-triage`, `epic`, `ready`, `claimed`, `blocked`, or `post-merge`.'
      log "#$n: conflicting queue labels; flagged"
      return ;;
  esac

  if has_issue_label claimed; then
    assignees="$(jq '.assignees | length' <<<"$ISSUE_JSON")"
    grep -qxF "$n" <<<"${OPEN_PR_ISSUES:-}" && open_pr=true
    grep -qxF "$n" <<<"${MERGED_REF_PR_ISSUES:-}" && merged_ref=true
    unchecked="$(unchecked_criteria <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    if [ "$(post_merge_decision "$merged_ref" <<<"$unchecked")" = TRANSITION ]; then
      ensure_comment "$n" post-merge-transition \
        "The Refs-linked PR merged with these acceptance criteria still unchecked:

$unchecked

The merge releases the claim; no builder owes a draft. Triage owes completion in a follow-up comment that names the owner and wake condition."
      owners="$(jq -r '[.assignees[].login] | join(",")' <<<"$ISSUE_JSON")"
      # `attention` is a demand for the assigned builder. The derived
      # transition releases that builder, so carrying the demand forward
      # would create an impossible parked-for state (#175 D4).
      has_issue_label attention && remove_claimed=claimed,attention
      if [ -n "$owners" ]; then
        run gh issue edit "$n" -R "$REPO" --remove-assignee "$owners" \
          --remove-label "$remove_claimed" --add-label post-merge >/dev/null
      else
        run gh issue edit "$n" -R "$REPO" \
          --remove-label "$remove_claimed" --add-label post-merge >/dev/null
      fi
      log "#$n: merged Refs PR -> post-merge; claim released"
    else
      age="$(last_issue_activity "$n" "$(jq -r '.created_at' <<<"$ISSUE_JSON")")"
      if [ "$(claim_clock_exempt <<<"$ISSUE_LABELS")" = EXEMPT ]; then
        # Legitimately quiet work does not run the reclaim clock. Only the
        # clock stops: an unassigned claim is still a repair the decision must
        # see, so it runs on a zero age rather than being skipped.
        decision="$(claim_decision "$assignees" "$open_pr" 0)"
      else
        decision="$(claim_decision_at "$assignees" "$open_pr" "$age")"
      fi
      case "$decision" in
        FLAG_UNASSIGNED)
          ensure_comment "$n" claimed-unassigned \
            'This issue is `claimed` but has no assignee. The sweep cannot infer an owner; triage must repair the claim.' ;;
        RECLAIM)
          # The last-activity epoch identifies a claim episode. A fixed marker
          # hid the required comment when the same issue was later claimed and
          # reclaimed again.
          ensure_comment "$n" "$(claim_reclaim_marker "$age")" \
            'This claim has no linked open PR and no activity for 48 hours. The sweep is reclaiming it for the ready queue.'
          owners="$(jq -r '[.assignees[].login] | join(",")' <<<"$ISSUE_JSON")"
          if [ -n "$owners" ]; then
            run gh issue edit "$n" -R "$REPO" --remove-assignee "$owners" \
              --remove-label claimed --add-label ready >/dev/null
          else
            run gh issue edit "$n" -R "$REPO" --remove-label claimed --add-label ready >/dev/null
          fi
          log "#$n: stale claim reclaimed -> ready" ;;
      esac
      if has_issue_label offsite; then
        local timeline
        if timeline="$(offsite_timeline "$n")"; then
          refs="$(offsite_cross_referenced_prs <<<"$timeline")"
          states="$(offsite_pr_states <<<"$refs")"
          if [ "$(offsite_resolved_decision <<<"$states")" = NUDGE ]; then
            ensure_comment "$n" offsite-resolved \
              "$(tr '\n' ' ' <<<"$refs" | sed 's/[[:space:]]*$//') is closed; this issue's \`offsite\` flag is still up. Clear it and close the issue, or say what is still outstanding. @$(jq -r '.assignees[0].login' <<<"$ISSUE_JSON")"
            log "#$n: resolved offsite PRs nudged"
          fi
        fi
      fi
    fi
  elif has_issue_label post-merge; then
    assignees="$(jq '.assignees | length' <<<"$ISSUE_JSON")"
    if [ "$assignees" -gt 0 ] || has_issue_label attention; then
      ensure_comment "$n" post-merge-assigned \
        'This `post-merge` issue has an assignee or `attention`. The sweep will not undo hand-set intent; triage must clear the invalid composition or move the issue back into buildable queue state.'
      log "#$n: assigned or attention-bearing post-merge issue flagged"
    fi
  elif has_issue_label blocked; then
    refs="$(blocked_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    cross_refs="$(blocked_cross_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    states="$(reference_states <<<"$refs")"
    decision="$(blocked_decision "$refs" "$states" "$cross_refs")"
    case "$decision" in
      FLAG_CROSS_REPO)
        ensure_comment "$n" blocked-cross-repo \
          "This issue's \`Blocked by\` declaration names cross-repo dependencies that the sweep cannot resolve: $(tr '\n' ' ' <<<"$cross_refs" | sed 's/[[:space:]]*$//'). Triage must verify those dependencies and flip this issue to \`ready\` by hand." ;;
      FLAG_UNPARSEABLE)
        ensure_comment "$n" blocked-unparseable \
          'This issue is `blocked`, but its body has no parseable `Blocked by #N` declaration. The sweep will not guess the dependency.' ;;
      READY)
        ensure_comment "$n" blockers-cleared \
          'Every issue named by `Blocked by` is closed. The sweep is moving this issue to `ready`.'
        run gh issue edit "$n" -R "$REPO" --remove-label blocked --add-label ready >/dev/null
        log "#$n: blockers closed -> ready" ;;
    esac
  elif has_issue_label epic; then
    refs="$(epic_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    states="$(reference_states <<<"$refs")"
    if [ "$(epic_decision "$refs" "$states")" = NUDGE ]; then
      ensure_comment "$n" epic-complete \
        "Every issue referenced by this epic's task list is closed. Please close the epic or extend its task list."
      log "#$n: completed epic nudged"
    fi
  fi

  # ---- the ruling invariants (#52), on any queue state ----
  # The flag composes with the queue labels (#50 D8), so this runs after the
  # queue branches rather than inside one of them. The FLAG_CONFLICT return
  # above still short-circuits it on purpose: a board lying about its queue
  # state is repaired by triage before anything else is derived from it.
  if has_issue_label needs-ruling; then
    # An already-applied stale comes off: waiting on a human is legitimately
    # quiet (#50 D10), and nothing on the issue side ever puts stale back.
    if has_issue_label stale; then
      run gh issue edit "$n" -R "$REPO" --remove-label stale >/dev/null
      log "#$n: unstale (a ruling is pending)"
    fi
    [ -n "${age:-}" ] \
      || age="$(last_issue_activity "$n" "$(jq -r '.created_at' <<<"$ISSUE_JSON")")"
    reconcile_ruling "$n" "$age" "$NOW"
  fi
}

reconcile_opened_issue() {
  local n="$1" author triage=false labels remove="" label
  ISSUE_JSON="$(gh api "repos/$REPO/issues/$n")"
  # The stand-downs return 0 explicitly: a bare return carries the failed
  # test's status, which under execution is live `set -e` — and it killed the
  # run on every triage-authored mint, before one issue was reconciled (#91).
  jq -e 'has("pull_request") | not' <<<"$ISSUE_JSON" >/dev/null || return 0
  author="$(jq -r '.user.login' <<<"$ISSUE_JSON")"
  is_triage_actor "$author" && triage=true
  labels="$(jq -r '.labels[].name' <<<"$ISSUE_JSON")"
  [ "$(author_decision "$triage" <<<"$labels")" = ADD_NEEDS_TRIAGE ] || return 0
  for label in epic "${QUEUE_LABELS[@]}"; do
    grep -qxF "$label" <<<"$labels" && remove="$remove,$label"
  done
  remove="${remove#,}"
  if [ -n "$remove" ]; then
    run gh issue edit "$n" -R "$REPO" --add-label needs-triage --remove-label "$remove" >/dev/null
  else
    run gh issue edit "$n" -R "$REPO" --add-label needs-triage >/dev/null
  fi
  log "#$n: needs-triage (opened by $author)"
}

main() {
  local owner name
  REPO="${REPO:?set REPO to owner/name}"
  LABELS_CONF="${LABELS_CONF:-.github/labels.conf}"
  load_issueflow_config "$LABELS_CONF"
  if [ "${EVENT_NAME:-}" = issues ] && [ "${EVENT_ACTION:-}" = opened ]; then
    reconcile_opened_issue "${EVENT_ISSUE:?set EVENT_ISSUE for issues:opened}"
  fi
  owner="${REPO%%/*}"
  name="${REPO#*/}"
  OPEN_PR_ISSUES="$(gh api graphql --paginate -f owner="$owner" -f name="$name" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 100, states: OPEN, after: $endCursor) {
          nodes { closingIssuesReferences(first: 100) { nodes { number } } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' --jq '.data.repository.pullRequests.nodes[].closingIssuesReferences.nodes[].number' \
    | sort -nu)"
  MERGED_REF_PR_ISSUES="$(gh api graphql --paginate -f owner="$owner" -f name="$name" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 100, states: MERGED, after: $endCursor) {
          nodes { body }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' --jq '.data.repository.pullRequests.nodes[].body' \
    | refs_references)"

  local n
  for n in $(gh api --paginate "repos/$REPO/issues?state=open&per_page=100" \
      --jq '.[] | select(has("pull_request") | not) | .number'); do
    (
      ISSUE_JSON="$(gh api "repos/$REPO/issues/$n")"
      jq -e 'has("pull_request") | not' <<<"$ISSUE_JSON" >/dev/null || exit 0
      ISSUE_LABELS="$(jq -r '.labels[].name' <<<"$ISSUE_JSON")"
      reconcile_issue "$n"
    ) || log "#$n: reconcile failed — continuing with the remaining issues"
  done
  log "reconciled."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
