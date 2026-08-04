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
# The attention target invariants (#232) — diagnosis only, both surfaces.
# shellcheck source=lib/attention.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/attention.sh"
# The guarded read and its reason line (#101, #247) — one implementation for
# both surfaces.
# shellcheck source=lib/read.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/read.sh"

# The status a per-issue subshell exits with when it walked away from an
# unreadable fact (#247 D4). Distinguished from every other non-zero status so
# a deliberate skip is counted rather than reported as a crash — and so the
# existing crash handler still names a genuine one.
ISSUEFLOW_SKIP=3
# Set by reconcile_issue_pass, read once by main for the D6 tail.
SKIPPED_COUNT=0
SKIPPED_ISSUES=""

# A per-issue pass is ATOMIC: it commits its whole effect or none of it
# (#247 D1). Inside reconcile_issue_pass's subshell, `run` and `log` do not
# act — they append here, and commit_staged_effects replays them in order
# once the pass has completed. Everywhere else (the arrival path, the sweep's
# own lines) they act immediately, as they always did.
#
# This is the ordering invariant itself, not a fix for the two sites that
# happened to violate it: a mutation reached before a later guarded read is
# what let a pass remove `stale`, or mint `needs-triage`, and THEN report the
# issue as skipped — the sweep saying it touched nothing while a write had
# landed, which is the same false-report class #247 exists to close. Stated
# per site it would hold until the next composition; stated here it holds for
# compositions nobody has written yet, because reconcile_issue has no way to
# mutate directly.
#
# Reads are deliberately NOT staged. They may happen anywhere in the pass,
# because nothing lands until the end.
STAGING=false
STAGED_EFFECTS=()

emit() { printf 'issueflow: %s\n' "$*"; }
apply() { if [ -n "${DRY_RUN:-}" ]; then emit "DRY_RUN: $*"; else "$@"; fi; }

stage() { # $1 = LOG|WRITE, rest = the effect's argv, kept exact by the count
  STAGED_EFFECTS+=("$#" "$@")
}

log() { if [ "$STAGING" = true ]; then stage LOG "$@"; else emit "$@"; fi; }
run() { if [ "$STAGING" = true ]; then stage WRITE "$@"; else apply "$@"; fi; }

commit_staged_effects() {
  # In staging order, so a completed pass's log and writes read exactly as
  # they did when each acted at its own call site. The `>/dev/null` is the one
  # every `run` call site already applies: a redirection cannot travel with
  # the argv, so it is applied here instead — uniformly, because on this
  # surface every staged write has it.
  local i=0 argc
  STAGING=false
  while [ "$i" -lt "${#STAGED_EFFECTS[@]}" ]; do
    argc="${STAGED_EFFECTS[i]}"
    if [ "${STAGED_EFFECTS[i + 1]}" = LOG ]; then
      emit "${STAGED_EFFECTS[@]:i + 2:argc - 1}"
    else
      apply "${STAGED_EFFECTS[@]:i + 2:argc - 1}" >/dev/null
    fi
    i=$((i + 1 + argc))
  done
  STAGED_EFFECTS=()
}

skip_issue() { # $1 = issue, $2 = the whole reason clause — ends this issue's pass
  # Leaves the issue exactly as it is: nothing is derived from a read that
  # did not answer, and nothing this pass staged is ever committed — `exit`
  # discards the subshell that holds the buffer. So a skip implies zero
  # `gh issue edit`, zero `gh issue comment`, and no log line claiming an
  # effect that never landed, wherever in the pass the failed read lives.
  # Called from the read itself, so no call site can forget to check — which
  # is why it exits rather than returns. The reason rides its own
  # `#$n:`-prefixed line (#247 D5), emitted directly: the skip is a fact
  # about the pass, not one of the effects the pass staged.
  emit "#$1: skipped this pass — $2"
  exit "$ISSUEFLOW_SKIP"
}

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
    {
      line = $0
      lower = tolower(line)
      if (match(lower, /(^|[^[:alnum:]_-])refs[[:space:]:]+/)) {
        line = substr(line, RSTART + RLENGTH)
        if (line ~ /^(#|([[:alnum:]_.-]+\/)?[[:alnum:]_.-]+#)[0-9]+/) {
          sub(/[.(;].*/, "", line)
          print line
        }
      }
    }
  ' | issue_references \
    | awk -F '\t' '$1 == "LOCAL" { print $2 }' | sort -nu
}

open_pr_issues() { # records on stdin: CLOSING|BODY<TAB>value -> issue numbers
  local kind value
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      CLOSING) [ -n "$value" ] && printf '%s\n' "$value" ;;
      BODY) refs_references <<<"$value" ;;
    esac
  done | sort -nu
}

unchecked_criteria() { # issue body on stdin -> unchecked task-list lines verbatim
  awk '
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[[[:space:]]\]/ {
      sub(/\r$/, "")
      print
    }
  '
}

post_merge_decision() { # $1 merged Refs PR, $2 linked open PR, $3 already handled
  local merged="$1" open_pr="$2" handled="$3" unchecked
  unchecked="$(cat)"
  if [ -n "$merged" ] && [ "$open_pr" = false ] && [ "$handled" = false ] \
      && [ -n "$unchecked" ]; then echo TRANSITION
  else echo KEEP
  fi
}

post_merge_pr_for_issue() { # $1 issue; records are ISSUE<TAB>PR<TAB>MERGED_AT
  # The deliverable is the PR that merged last, not the one numbered highest.
  # Merge order is not number order in this family: crew#176's two Refs PRs
  # merged #184 at 19:05:16Z and #182 at 19:05:18Z — the higher number two
  # seconds earlier. Number order is also what spends a marker on the wrong
  # PR: crew#321 carries `post-merge-transition-pr-326` while its real
  # deliverable crew#322 — a lower number, merging later — is still open, so
  # under the old rule the transition it owes could never fire (#242).
  # mergedAt is ISO-8601 UTC, so it sorts as a string; ties break by highest
  # PR number so the answer never depends on input order.
  awk -F '\t' -v issue="$1" '$1 == issue { print $3 "\t" $2 }' \
    <<<"${MERGED_REF_PR_RECORDS:-}" \
    | sort -t $'\t' -k1,1 -k2,2n | tail -n1 | cut -f2
}

post_merge_transition_marker() { # $1 merged PR number
  printf 'post-merge-transition-pr-%s\n' "$1"
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
  # Every occurrence of the marker contributes a clause. Binding to the first
  # occurrence alone dropped the later sentences of a repeated declaration
  # ("Blocked by #152. Blocked by #153. Blocked by #148 — …") and let earlier
  # prose that merely mentioned being blocked hijack the parse — the false
  # `ready` promotion on rig#154 (#184). Each clause runs to its own first
  # sentence terminator; declarations sometimes soft-wrap after a comma, so
  # an open clause continues across lines, and if prose omits the terminator
  # it retains to end of input. Unioning can over-retain — prose like "this
  # was blocked by #9 before the split" now contributes #9 — and that is the
  # correct direction of error: a stale `blocked` is a triage comment away,
  # a false `ready` sends a builder into work that cannot merge (#184).
  awk '
    BEGIN { marker = "blocked by" }
    {
      line = $0
      while (1) {
        if (!active) {
          start = index(tolower(line), marker)
          if (!start) next
          line = substr(line, start + length(marker))
          active = 1
        }
        if (match(line, /[.;]/)) {
          print substr(line, 1, RSTART - 1)
          line = substr(line, RSTART + 1)
          active = 0
        } else {
          print line
          next
        }
      }
    }
  ' | issue_references
}

blocked_references() { # body on stdin -> local issue numbers, one per line
  blocked_reference_records | awk -F '\t' '$1 == "LOCAL" { print $2 }' | sort -nu
}

blocked_cross_references() { # body on stdin -> qualified refs, one per line
  blocked_reference_records | awk -F '\t' '$1 == "CROSS" { print $2 }' | sort -u
}

blocked_parse_set() { # $1 local refs, $2 cross refs -> "{#7, #12}" | "{}"
  # The parse, rendered once. The comment, the marker and the log line all
  # read this one string, so the three can never disagree about what the
  # machine read. Both classes are shown because both are parsed: the locals
  # in the numeric order blocked_references answers, then the qualified
  # references blocked_cross_references answers — a cross-repo clause is as
  # capable of being readable-but-wrong as a local one.
  local rendered
  rendered="$(
    { [ -z "$1" ] || awk '{ print "#" $0 }' <<<"$1"
      [ -z "${2:-}" ] || printf '%s\n' "$2"
    } | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 } END { printf "\n" }'
  )"
  printf '{%s}\n' "$rendered"
}

blocked_parse_marker() { # $1 rendered set -> the echo's idempotency marker
  # Scoped to the SET's value, not to the issue and not to the sweep: the
  # marker names WHAT was echoed, and blocked_parse_echo_needed decides whether
  # it is still what the thread is saying.
  #
  # The identity is the DIGEST, not the slug beside it. Slugging is many-to-one
  # — `{acme/widgets#9}` and `{acme-widgets#9}` are both parses this reconciler
  # accepts, and both slug to `acme-widgets-9` — so a slug-keyed marker lets a
  # changed set find the old marker and say nothing, silence in precisely the
  # case the echo exists to speak about. Distinguishing `/` would close that
  # pair and leave the class: `-`, `_` and `.` are legal in a qualifier token
  # and all collapse the same way. The slug stays in front so a human reading
  # the raw comment can still see which set it belongs to; it decides nothing.
  local slug digest
  slug="$(printf '%s' "$1" | tr -c '[:alnum:]' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  digest="$(printf '%s' "$1" | sha256sum | cut -c1-12)"
  printf 'blockers-parsed-%s-%s\n' "${slug:-none}" "$digest"
}

blocked_parse_echo_needed() { # $1 issue, $2 this parse's marker → 0 echo, 1 quiet
  # Idempotency for the parse echo is against the LAST parse echo on the
  # thread, not against any historical one. ensure_comment's any-occurrence
  # grep is right for a flag like `blocked-unparseable`, whose question is
  # "have I ever said this"; it is wrong for a value that changes, whose
  # question is "is this still what I am saying". The difference is A -> B -> A:
  # under an any-occurrence search the return to A finds A's own first echo and
  # stays silent, leaving the thread's most recent echo asserting B while the
  # sweep gates on A. A stale parse presented as the current one is the exact
  # failure #252 exists to kill, and the third edit changed the parsed set, so
  # the criterion says it speaks.
  #
  # Comparing markers rather than re-rendering the last set keeps the digest as
  # the only identity: two sets are the same here iff blocked_parse_marker says
  # so, the same rule the marker itself is built on.
  local bodies last
  guarded_read bodies gh api --paginate "repos/$REPO/issues/$1/comments" --jq '.[].body' \
    || skip_issue "$1" "could not read its comments: $(read_failure_reason "$READ_FAILURE_STDERR")"
  # The read fails closed above (#247 D1): an unreadable history skips the
  # issue rather than answering "nothing echoed yet" and re-posting.
  last="$(grep -o '<!-- issueflow:blockers-parsed-[[:alnum:]-]* -->' <<<"$bodies" | tail -n 1)"
  [ "$last" != "<!-- issueflow:$2 -->" ]
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

issue_payload_valid() { # $1 = the requested issue; payload on stdin
  # The second of D3's two required guards, and neither subsumes the other.
  # The status check catches the 504 whose body is GitHub's JSON error object
  # — valid JSON that passes every jq guard and empties the label set. THIS
  # one catches an HTTP 200 whose body is `null`, which exits 0 and empties it
  # just the same. `.number` is checked against the issue asked for, so a
  # payload about some other issue can never be reconciled as this one.
  jq -e --arg n "$1" '
    type == "object" and (.number | tostring) == $n and (.labels | type) == "array"
  ' >/dev/null 2>&1
}

skipped_tail() { # $1 = skip count, $2 = the issue numbers → the D6 line, or nothing
  # `reconciled.` stays byte-identical when the pass was whole — tests pin that
  # exact string, and #101 D1 is the precedent for not folding new text into a
  # matched line. A partial pass says so on a line of its own, after it, so a
  # consumer reading only the tail of a job log can see it.
  [ "$1" -gt 0 ] || return 0
  if [ "$1" -eq 1 ]; then
    printf '%s issue skipped this pass on an unreadable fact: %s\n' "$1" "$2"
  else
    printf '%s issues skipped this pass on unreadable facts: %s\n' "$1" "$2"
  fi
}

# API edge. Marker comments make warnings and nudges idempotent across sweeps.
ensure_comment() { # $1 issue, $2 marker, $3 message
  local n="$1" marker="$2" message="$3"
  if issue_comment_has_marker "$n" "$marker"; then return; fi
  run gh issue comment "$n" -R "$REPO" --body "<!-- issueflow:$marker -->
$message" >/dev/null
}

issue_comment_has_marker() { # $1 issue, $2 marker → 0 found, 1 genuinely absent
  # A failed read used to answer "no marker", which re-posts the comment the
  # marker exists to suppress — absence of evidence read as evidence of
  # absence (#247 D1). It cannot be a return value: every caller treats
  # non-zero as "absent", so the skip is taken here, at the read.
  local bodies
  guarded_read bodies gh api --paginate "repos/$REPO/issues/$1/comments" --jq '.[].body' \
    || skip_issue "$1" "could not read its comments: $(read_failure_reason "$READ_FAILURE_STDERR")"
  grep -qF "<!-- issueflow:$2 -->" <<<"$bodies"
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

issue_activity_at() { # $1 issue, $2 created_at, $3 with-assignment|comments-only
  # One body, two clocks over it — a second activity computation is the drift
  # the reuse exists to prevent, and the two callers below are the whole
  # difference between them.
  #
  # Both reads are checked, and a failure reports rather than answering an age
  # (#247 D1). Swallowed, the comments read falls back to `created_at`, and a
  # `claimed` issue created months ago but commented on seconds earlier is
  # reclaimed — the live builder unassigned, under a comment asserting 48
  # hours of silence. `needs-triage` is cheap to remove; that is not.
  # gh's stderr is left to flow to this function's own, where the caller's
  # guarded_read captures it for the reason line.
  local n="$1" created="$2" mode="$3" comments timeline="" latest
  comments="$(gh api --paginate "repos/$REPO/issues/$n/comments" --jq '.[].created_at')" \
    || return 1
  if [ "$mode" = with-assignment ]; then
    timeline="$(gh api --paginate "repos/$REPO/issues/$n/timeline" \
      --jq '.[] | select(.event == "assigned") | .created_at')" || return 1
  fi
  latest="$(printf '%s\n%s\n%s\n' "$created" "$comments" "$timeline" | sort | tail -n1)"
  date -d "$latest" +%s
}

last_issue_activity() { # $1 issue, $2 created_at → epoch; non-zero if a read failed
  # The claim clock, and the ruling clock with it. Assignment is the claim
  # itself. Ignoring it would let an old issue be reclaimed in the seconds
  # between assignment and its required draft PR.
  issue_activity_at "$1" "$2" with-assignment
}

last_issue_comment_activity() { # $1 issue, $2 created_at → epoch; non-zero on a failed read
  # The evidence nudge's clock (#254). Same computation, one input fewer, and
  # the input it drops is the one that would starve the criterion: on
  # `post-merge` there is no claim for an assignment to protect, and an
  # assignee there is the invalid composition the `post-merge-assigned` flag
  # reports. Counting it would let a broken board buy the item another 7 days
  # of silence — the failure direction of #254 taken backwards.
  #
  # A comment the sweep itself wrote is still activity here, deliberately:
  # the nudge carries no marker, so its own comment is what rate-limits it,
  # and no machine comment can be exempted without exempting that one too.
  # Reading authorship back into the clock would mean a body read this issue
  # forbids.
  issue_activity_at "$1" "$2" comments-only
}

reconcile_issue() {
  local n="$1" decision refs cross_refs states age evidence_age created assignees open_pr=false label owners
  local merged_ref_pr="" transition_marker="" transition_handled=false parsed_set="" parse_marker=""
  local unchecked="" remove_claimed=claimed
  local attention_active=true attention_suppression=""
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
    merged_ref_pr="$(post_merge_pr_for_issue "$n")"
    if [ -n "$merged_ref_pr" ]; then
      transition_marker="$(post_merge_transition_marker "$merged_ref_pr")"
      issue_comment_has_marker "$n" "$transition_marker" \
        && transition_handled=true
    fi
    unchecked="$(unchecked_criteria <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    if [ "$(post_merge_decision "$merged_ref_pr" "$open_pr" "$transition_handled" \
        <<<"$unchecked")" = TRANSITION ]; then
      ensure_comment "$n" "$transition_marker" \
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
      attention_active=false
    else
      created="$(jq -r '.created_at' <<<"$ISSUE_JSON")"
      guarded_read age last_issue_activity "$n" "$created" \
        || skip_issue "$n" "could not read its activity history: $(read_failure_reason "$READ_FAILURE_STDERR")"
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
      [ "$decision" != FLAG_UNASSIGNED ] || attention_suppression=claimed-unassigned
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
    # The evidence nudge's clock is read BEFORE any comment this branch
    # posts. `ensure_comment` below is itself activity, so reading after it
    # would let the assigned-flag comment silence the nudge for another 7
    # days — the same self-silencing the ruling nudge avoids by reading its
    # facts once, at the top of the pass.
    #
    # Its own variable, not `age`: the ruling block below reuses `age` when
    # it is already set, and the evidence clock is deliberately narrower than
    # the ruling clock. Leaking it there would silently change what a ruling
    # nudge means depending on which queue label the issue sits under.
    created="$(jq -r '.created_at' <<<"$ISSUE_JSON")"
    guarded_read evidence_age last_issue_comment_activity "$n" "$created" \
      || skip_issue "$n" "could not read its activity history: $(read_failure_reason "$READ_FAILURE_STDERR")"
    # The ruling clock is read HERE, not in the ruling block, for the same
    # reason the evidence clock is: that block reads only when `age` is
    # unset, and by the time it runs this branch may have posted the
    # evidence nudge — so its read would date the issue by this sweep's own
    # comment and silence the ruling nudge. Both waits are answered from
    # facts that predate anything this pass writes. The cost is one extra
    # comments read on `post-merge` + `needs-ruling`, and only there: an
    # ordinary `post-merge` issue reads once.
    if has_issue_label needs-ruling; then
      guarded_read age last_issue_activity "$n" "$created" \
        || skip_issue "$n" "could not read its activity history: $(read_failure_reason "$READ_FAILURE_STDERR")"
    fi
    if [ "$assignees" -gt 0 ] || has_issue_label attention; then
      ensure_comment "$n" post-merge-assigned \
        'This `post-merge` issue has an assignee or `attention`. The sweep will not undo hand-set intent; triage must clear the invalid composition or move the issue back into buildable queue state.'
      log "#$n: assigned or attention-bearing post-merge issue flagged"
    fi
    attention_suppression=post-merge-assigned
    # ---- the post-merge evidence nudge (#254), the ruling nudge's twin ----
    # A `post-merge` item waits on named evidence with a named owner, and
    # nothing nudged when the wait went quiet: crew#181's real-host criterion
    # starved four separate times across two releases, crew#240/#264 sat
    # until an operator happened to run the right read. Same 7-day rule, same
    # constant, same no-marker property — `ruling_nudge_decision` is the one
    # spelling of all three (lib/ruling.sh), and a second `7 * 24 * 3600`
    # here is the drift that file exists to prevent.
    #
    # The addressee is the triage actor, not `HUMAN_REVIEWER`: `post-merge`
    # is triage's completion queue by contract (TRIAGE.md), so a starving
    # wake condition is triage's to answer, and routing it to the operator
    # asks the wrong party for a move it does not owe. `triage-actors=` is
    # mandatory config — `load_issueflow_config` refuses to run without it —
    # so there is nothing to fall back to, and a silent fallback is exactly
    # how the wrong addressee comes back.
    if [ "$(ruling_nudge_decision "$NOW" "$evidence_age")" = NUDGE ]; then
      local quiet_days=$(((NOW - evidence_age) / 86400))
      run gh issue comment "$n" -R "$REPO" --body "@${TRIAGE_ACTORS[0]} — this \`post-merge\` item has had no comment for ${quiet_days} days: https://github.com/$REPO/issues/$n

Its wake evidence is still owed. \`post-merge\` means the merge landed and
triage owns completion — judge the remaining criteria against the evidence
and close the issue, or say what is still outstanding and who owes it. The
sweep names no criterion: which one starved is prose, and the machine never
judges prose (the link is the payload).

*This nudge is comment-only and carries no idempotency marker on purpose: the comment itself is activity, so posting it resets the 7-day window and the rule self-rate-limits to one nudge per 7 quiet days. Do not add a marker.*" >/dev/null
      log "#$n: post-merge evidence nudge (${quiet_days}d quiet — triage owes the wake evidence)"
    fi
  elif has_issue_label blocked; then
    refs="$(blocked_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    cross_refs="$(blocked_cross_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    # The parse is echoed before any verdict is derived from it (#252). The
    # clause parse is exact and unforgiving, and its output was invisible:
    # crew#308 silently parsed a negated "no longer blocked by #221" as a
    # blocker, crew#71 spent five days as an unresolvable queue conflict, and
    # crew#284's declaration had to be re-derived by hand-running the parser.
    # Every one of those was found by a human running the parser, hours or
    # days late. `blocked-unparseable` already catches the UNREADABLE
    # declaration; this catches the readable-but-wrong one, which no flag can
    # detect because the machine cannot judge what a human meant — only state
    # what it read, and let the human see the divergence in one sweep.
    #
    # The illustrative `#9` in the body below is code-spanned for the same
    # reason `blocked-unparseable` code-spans its `Blocked by #N`: an
    # unbackticked `#N` in a comment this sweep posts on a cron linkifies, and
    # writes a "mentioned in" event onto an unrelated issue once per echo.
    parsed_set="$(blocked_parse_set "$refs" "$cross_refs")"
    parse_marker="$(blocked_parse_marker "$parsed_set")"
    if blocked_parse_echo_needed "$n" "$parse_marker"; then
      run gh issue comment "$n" -R "$REPO" --body "<!-- issueflow:$parse_marker -->
This issue's \`Blocked by\` declarations parse to: $parsed_set

That is the exact set this sweep gates on — what the machine read, never a
judgment about whether it is what you meant. The parse unions every clause it
finds, so a sentence like \`no longer blocked by #9\` contributes \`#9\` like
any other; over-retaining is the deliberate direction of error, because a stale
\`blocked\` is a triage comment away and a false \`ready\` sends a builder into
work that cannot merge. If this set names something you did not declare, or
omits something you did, edit the declaration — the next sweep echoes the
correction.

*Comment only: nothing on this path writes a label. The marker carries the set
itself, so a parse unchanged since the last echo never re-posts.*" >/dev/null
    fi
    log "#$n: blocked declarations parse to $parsed_set"
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
    if has_issue_label release; then
      refs="$(blocked_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
      cross_refs="$(blocked_cross_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
      states="$(reference_states <<<"$refs")"
      if [ "$(blocked_decision "$refs" "$states" "$cross_refs")" = READY ]; then
        ensure_comment "$n" release-init-due \
          "This release epic's declared gate is open. Release initialization is due:

1. Mint the window's members.
2. Graph hard dependencies and same-file clusters.
3. Write ordered waves and the progress task list.
4. Ask the operator to bless the order, then open the first wave.
5. Ship the release, close this epic, and trigger the next window.

See [\`RELEASES.md\`](https://github.com/$REPO/blob/main/RELEASES.md). The operator blessing the order is the one step this chain never automates."
        log "#$n: release-init due"
      fi
    fi
    refs="$(epic_references <<<"$(jq -r '.body // ""' <<<"$ISSUE_JSON")")"
    states="$(reference_states <<<"$refs")"
    if [ "$(epic_decision "$refs" "$states")" = NUDGE ]; then
      ensure_comment "$n" epic-complete \
        "Every issue referenced by this epic's task list is closed. Please close the epic or extend its task list."
      log "#$n: completed epic nudged"
    fi
  fi

  # The flag composes with every build queue state, but requires an assignee.
  # Existing post-merge/claimed diagnostics take precedence so one board bug
  # draws one comment (#232 D5); the shared helper still logs the suppression.
  if [ "$attention_active" = true ] && has_issue_label attention; then
    [ -n "${assignees:-}" ] || assignees="$(jq '.assignees | length' <<<"$ISSUE_JSON")"
    reconcile_attention "$n" issue "$assignees" "$attention_suppression"
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
    if [ -z "${age:-}" ]; then
      created="$(jq -r '.created_at' <<<"$ISSUE_JSON")"
      guarded_read age last_issue_activity "$n" "$created" \
        || skip_issue "$n" "could not read its activity history: $(read_failure_reason "$READ_FAILURE_STDERR")"
    fi
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

reconcile_issue_pass() { # $1 = issue — one issue's whole pass, in its own subshell
  # The subshell is #91's resilience: one unreadable or broken issue must not
  # take the sweep down. What it is NOT is an errexit boundary — a command
  # whose status is tested by `||` runs with errexit suppressed, and the
  # suppression extends through the whole subshell body, so the handler below
  # is what disables the errexit that would have caught a failed read (#247
  # D2). Removing it would revive errexit and lose #91. Explicit per-read
  # checks are the mechanism instead, and each one exits with ISSUEFLOW_SKIP.
  #
  # What the subshell IS, since #247's first round, is the atomicity
  # boundary: the staged effects live in it, so ending it — by a skip, or by
  # a crash — discards them, and no partial pass can ever reach the board.
  local n="$1" status=0
  (
    # Everything below stages rather than acts, and commits at the bottom —
    # so a skip taken at any read, and a crash at any statement, leaves the
    # issue exactly as it was (D1). `|| exit $?` keeps a crash's status the
    # subshell's own, as it was when reconcile_issue was the last command
    # here: the commit must not overwrite it, and must not run under it.
    STAGING=true
    guarded_read ISSUE_JSON gh api "repos/$REPO/issues/$n" \
      || skip_issue "$n" "could not read the issue: $(read_failure_reason "$READ_FAILURE_STDERR")"
    issue_payload_valid "$n" <<<"$ISSUE_JSON" \
      || skip_issue "$n" "the issue read answered a payload that is not issue #$n carrying a label array"
    jq -e 'has("pull_request") | not' <<<"$ISSUE_JSON" >/dev/null || exit 0
    ISSUE_LABELS="$(jq -r '.labels[].name' <<<"$ISSUE_JSON")"
    reconcile_issue "$n" || exit $?
    commit_staged_effects
  ) || status=$?
  if [ "$status" -eq "$ISSUEFLOW_SKIP" ]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    SKIPPED_ISSUES="${SKIPPED_ISSUES:+$SKIPPED_ISSUES }#$n"
  elif [ "$status" -ne 0 ]; then
    # Byte-identical, and still owed: a skip is deliberate, a crash is not,
    # and folding the two together would hide one behind the other (D4).
    log "#$n: reconcile failed — continuing with the remaining issues"
  fi
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
  # crew#321 released a live claim because the open side read only closing
  # links while the merged side parsed Refs bodies. One parser now supplies
  # the local body references on both sides, so transition and reclaim agree.
  OPEN_PR_ISSUES="$(gh api graphql --paginate -f owner="$owner" -f name="$name" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 100, states: OPEN, after: $endCursor) {
          nodes { body closingIssuesReferences(first: 100) { nodes { number } } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' --jq '.data.repository.pullRequests.nodes[]
      | (.closingIssuesReferences.nodes[].number
          | ["CLOSING", tostring] | @tsv),
        ((.body // "") | split("\n")[] | ["BODY", .] | @tsv)' \
    | open_pr_issues)"
  MERGED_REF_PR_RECORDS="$(gh api graphql --paginate -f owner="$owner" -f name="$name" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 100, states: MERGED, after: $endCursor) {
          nodes { number mergedAt body }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' --jq '.data.repository.pullRequests.nodes[]
      | .number as $pr | .mergedAt as $merged | .body | split("\n")[]
      | [$pr, $merged, .] | @tsv' \
    | while IFS= read -r record; do
        # Split on exact tabs rather than IFS: tab is IFS whitespace, so bash
        # collapses a run of them, and a middle column that ever came back
        # empty would silently shift the body one field left. The body is
        # arbitrary text and stays last, where the remainder belongs.
        pr="${record%%$'\t'*}"
        rest="${record#*$'\t'}"
        merged="${rest%%$'\t'*}"
        body="${rest#*$'\t'}"
        while IFS= read -r issue; do
          [ -n "$issue" ] && printf '%s\t%s\t%s\n' "$issue" "$pr" "$merged"
        done < <(refs_references <<<"$body")
      done)"

  local n tail_line
  SKIPPED_COUNT=0
  SKIPPED_ISSUES=""
  for n in $(gh api --paginate "repos/$REPO/issues?state=open&per_page=100" \
      --jq '.[] | select(has("pull_request") | not) | .number'); do
    reconcile_issue_pass "$n"
  done
  log "reconciled."
  # The job stays green (D7): an hourly sweep over a hundred-issue board meets
  # transient 504s as a matter of course, and reddening the whole run for one
  # skipped issue trains consumers to ignore red — the outcome #95 and #101
  # both steered away from on the PR surface. This line is what buys back the
  # auditability that costs.
  tail_line="$(skipped_tail "$SKIPPED_COUNT" "$SKIPPED_ISSUES")"
  [ -z "$tail_line" ] || log "$tail_line"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
