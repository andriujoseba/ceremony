#!/usr/bin/env bash
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
else
  # Fixture tests source the pure functions and deliberately inspect failures.
  set -u
fi

# ci-rerun.sh — the servicing #423 could only park. `rerun-owed` says the head
# is red on a rerun no identity in the fleet can start: rerunning a fork PR's
# run needs `actions: write` in the BASE repository, which no fleet identity
# holds. A workflow in that base repository can be granted exactly that right
# and nothing else, for the length of one run, and that is what calls this
# script (#424).
#
# It never runs PR-authored code, and that is the property the whole design
# rests on (#424 D2): it checks out nothing from the head, sources no file from
# the PR, and executes exactly one thing — API calls against the base
# repository. A privileged trigger plus a fork's tree is the shape
# `runner-isolated` exists to refuse; this answers it by construction.
#
# Four gates, all four measured HERE and never inherited from the label (D3):
# the actor is a fleet identity, the head has not moved under the evidence, the
# run's conclusion is `failure`, and the run is on its first attempt. A refusal
# leaves the label standing and says which gate refused — a service that
# silently drops the state is the stall again, with a robot in it (D4).
#
# DRY_RUN=1 narrates every mutation instead of performing it, the way the rest
# of this family is rehearsed against a live repo.

LABEL=rerun-owed

# The evidence marker BUILDER.md tells the builder to open with, and the one
# labels-reconcile.sh reads for its moved-head test (#423). Byte-identical to
# that constant on purpose: two machines reading one builder's line must read
# it the same way, and test/ci-rerun.test.sh drives both parsers over one
# fixture table rather than trusting this comment.
RERUN_OWED_MARKER='🔁 rerun owed at head '
# What this machine writes back. Markers, not prose: the head an outcome
# belongs to is a fact, so it is written where a machine can read it, in the
# shape this repo's other head-scoped markers already use.
STARTED_MARKER='🔁 rerun started at head '
REFUSED_MARKER='🚫 rerun refused at head '

# The fleet identities named by the consumer's own .github/labels.conf — the
# same file the panel and `triage-actors` come from (D3.1). No second roster:
# a list of who may spend this credential that lives anywhere else drifts from
# the one the board already reads.
FLEET=()

# The servicing workflow's own runs are never rerun candidates (#208's rule for
# the same reason: a workflow grading its own runs answers a question about
# itself). GITHUB_WORKFLOW is ambient in every Actions step and names the
# caller; empty means "filter nothing", for a rehearsal outside Actions.
SELF_WORKFLOW="${SELF_WORKFLOW:-${GITHUB_WORKFLOW:-}}"

log() { printf 'ci-rerun: %s\n' "$*"; }

run() { # every mutation goes through here — DRY_RUN=1 logs instead of doing
  if [ -n "${DRY_RUN:-}" ]; then log "DRY_RUN: $*"; else "$@"; fi
}

fleet_add() { # append each login not already in FLEET, first-seen order (#453)
  # The dedup is HERE and not in fleet_roster: FLEET is the roster, so the
  # array a future reader iterates is already the set and the printer stays a
  # printer. First-seen order keeps the roster reading as the file reads —
  # panel='s reviewers hold their position and a bracketed login appears where
  # its row does — which is what makes the gate-1 refusal comment actionable,
  # since its whole servicing instruction is "ask one of these, or add
  # yourself to that file".
  #
  # The membership test is is_fleet_actor and not a second scan of its own:
  # the set this builds and the set the gate reads must be the same set, and
  # sharing the predicate makes that structural rather than asserted.
  #
  # The test is written `if ! …` rather than `… && continue` deliberately: a
  # loop whose last iteration appends nothing would leave this function
  # returning 1, and under this file's own `set -e` that aborts the load on a
  # conf whose final login happens to be a repeat.
  local login
  for login in "$@"; do
    if ! is_fleet_actor "$login"; then FLEET+=("$login"); fi
  done
}

load_fleet() { # $1 = labels.conf → FLEET, the identities allowed to spend this
  # Every failure is a hard one that names the file: this script's whole
  # authorization is this list, so an unreadable conf must refuse loudly rather
  # than fall back to an empty set that reads as "nobody may" — or, worse, to
  # a default roster nobody wrote down.
  local conf="$1" line seen=false login rest
  local -a row=()
  [ -f "$conf" ] || {
    echo "ci-rerun: missing config: $conf (a panel= line is required)" >&2
    return 2
  }
  FLEET=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # "panel[" is matched QUOTED for #224 D7's reason: unquoted, panel[abc]=*
    # is a bracket expression matching panela=…, silently rerouting ordinary
    # settings.
    case "$line" in
      panel=*)
        seen=true
        read -r -a row <<<"${line#panel=}"
        fleet_add ${row[@]+"${row[@]}"}
        ;;
      "panel["*"]="*)
        # Both halves of a per-author row are fleet: the bracketed login is the
        # builder the row is written for (#224), and the row itself is that
        # builder's panel. A repo that names its builders only there would
        # otherwise refuse the very identities it was configured for.
        seen=true
        login="${line#panel[}"
        login="${login%%]=*}"
        case "$login" in
          "" | *[!A-Za-z0-9-]*) ;; # malformed rows are labels-reconcile's to refuse
          *) fleet_add "$login" ;;
        esac
        rest="${line#*]=}"
        read -r -a row <<<"$rest"
        fleet_add ${row[@]+"${row[@]}"}
        ;;
      triage-actors=*)
        seen=true
        read -r -a row <<<"${line#triage-actors=}"
        fleet_add ${row[@]+"${row[@]}"}
        ;;
    esac
  done <"$conf"
  if [ "$seen" != true ] || [ "${#FLEET[@]}" -eq 0 ]; then
    echo "ci-rerun: $conf names no fleet identity (panel=, panel[<login>]= or triage-actors=)" >&2
    return 2
  fi
}

is_fleet_actor() { # $1 = login
  local identity
  for identity in ${FLEET[@]+"${FLEET[@]}"}; do
    [ "$identity" = "$1" ] && return 0
  done
  return 1
}

fleet_roster() { printf '%s' "${FLEET[*]-}"; }

evidence_named_head() { # evidence first-lines on stdin → the head the newest names
  # The parse labels-reconcile.sh calls rerun_owed_named_head, byte-for-byte in
  # behaviour and pinned to it by a fixture table both implementations are
  # driven over (test/ci-rerun.test.sh). It is duplicated rather than extracted
  # because #424's scope fence is this action, its workflow, its test and the
  # doctrine rows; hoisting a shared parser edits labels-reconcile.sh, which is
  # a different PR's diff. The tripwire is what makes the duplicate honest.
  #
  # Newest wins, which is the order the comments API returns: a builder who
  # evidences a second unrerunnable head has said something newer, and the
  # older marker is history — even when the newest names no readable SHA, or
  # this would service a head nobody currently names.
  local line rest sha=""
  while IFS= read -r line; do
    case "$line" in "$RERUN_OWED_MARKER"*) ;; *) continue ;; esac
    sha=""
    rest="${line#"$RERUN_OWED_MARKER"}"
    rest="${rest#\`}"          # the house style backticks a SHA
    rest="${rest,,}"           # ...and a pasted one may be upper-case
    rest="${rest%%[!0-9a-f]*}" # everything after the hex run is prose
    # Seven is git's own floor for an abbreviation and forty is a whole one;
    # outside that the line is decoration somebody wrote, not a fact.
    if [ "${#rest}" -ge 7 ] && [ "${#rest}" -le 40 ]; then sha="$rest"; fi
  done
  [ -z "$sha" ] || echo "$sha"
}

evidence_marker_time() { # `created_at<TAB>first-line` on stdin → the newest marker's time
  # The cutoff pick_run grades against, read off the same stream and by the same
  # newest-wins rule evidence_named_head uses, so the head and the moment it was
  # evidenced always come from ONE comment. Kept separate from that parser on
  # purpose: it is pinned byte-for-byte to labels-reconcile.sh's and a second
  # field in its input would break the tripwire that makes the duplicate honest.
  local line rest at="" tab=$'\t'
  while IFS= read -r line; do
    # A line carrying no tab is not a `created_at<TAB>line` record at all, and a
    # marker read out of one would date the evidence by its own text.
    case "$line" in *"$tab"*) ;; *) continue ;; esac
    rest="${line#*"$tab"}"
    case "$rest" in "$RERUN_OWED_MARKER"*) at="${line%%"$tab"*}" ;; esac
  done
  [ -z "$at" ] || echo "$at"
}

earlier_time() { # $1, $2 = ISO-8601 stamps, either possibly empty → the earlier one
  # An empty stamp is "no bound", not "the beginning of time": a rehearsal that
  # reads neither must filter nothing rather than everything.
  if [ -z "${1:-}" ]; then printf '%s' "${2:-}"
  elif [ -z "${2:-}" ]; then printf '%s' "$1"
  elif [[ "$1" < "$2" ]]; then printf '%s' "$1"
  else printf '%s' "$2"; fi
}

run_created_at() { # runs JSON on stdin, $1 = a run id → that run's creation time
  jq -r --arg id "${1:-}" '
    [ .workflow_runs[]? | select($id != "" and (.id | tostring) == $id)
      | (.created_at // .run_started_at // empty) ] | .[0] // empty'
}

names_this_head() { # $1 = the head the evidence names, $2 = the head now
  # Prefix, not equality: a marker naming an abbreviated SHA names this head as
  # surely as a full one, and reading it as a moved head would refuse on a
  # spelling (#423). Both empty-guards are load-bearing — an unread head is not
  # a differing one, and neither is a service to start on.
  [ -n "$1" ] && [ -n "$2" ] && [ "${2:0:${#1}}" = "$1" ]
}

pick_run() { # runs JSON on stdin, $1 self, $2 cutoff → id<TAB>conclusion<TAB>attempt<TAB>url<TAB>name
  # The candidate is the NEWEST run at the head that did not succeed, and it is
  # picked before it is graded — which is what lets gate 3 refuse at all. A
  # selector that took "the newest FAILING run" could never meet a cancelled
  # one, and a cancelled run is exactly what #139 and #209 rule is not a
  # verdict and must not be resurrected into one.
  #
  # Newest by start time, not by completion: a cancelled run can outlive its
  # replacement's start (#139), and the same ordering the green rule uses is
  # the one this must use.
  #
  # But newest among WHAT. The label event that wakes this service wakes every
  # other `labeled` workflow in the base repository at the same instant, and a
  # `pull_request_target` run carries the PR head's SHA — so those siblings are
  # in this list, exactly as this workflow's own run is. Picking one refuses the
  # happy path when it is still in flight ("has not concluded" about a run
  # nobody asked about), and, worse, reruns the SIBLING when it concluded
  # `failure`: the label comes off, a comment says an attempt started, and the
  # red the evidence named is untouched — D4's dropped state, reached through a
  # start instead of a refusal.
  #
  # So a candidate must PRE-DATE the evidence: the builder evidenced a head it
  # saw red, and a run that did not exist when that comment was written cannot
  # be the run it names. That excludes the whole cohort the label event creates
  # by construction rather than by name — which is the property `SELF_WORKFLOW`
  # can only have for one name. A run whose creation time is unreadable is not a
  # candidate under a cutoff either: it cannot be shown to pre-date anything.
  # An empty cutoff filters nothing, for a rehearsal outside Actions.
  local self="${1:-}" cutoff="${2:-}"
  jq -r --arg self "$self" --arg cutoff "$cutoff" '
    [ .workflow_runs[]?
      | select($self == "" or .name != $self)
      | select($cutoff == ""
               or ((.created_at // .run_started_at // "") != ""
                   and (.created_at // .run_started_at) < $cutoff))
      | select(.conclusion != "success") ]
    | sort_by(.run_started_at // .created_at) | reverse | .[0] // empty
    | [ (.id | tostring), (.conclusion // ""), (.run_attempt | tostring),
        (.html_url // ""), (.name // "") ] | @tsv'
}

service_decision() { # → START | REFUSE:actor | REFUSE:head | REFUSE:verdict | REFUSE:allowance
  # $1 actor_is_fleet (yes|no), $2 evidence head, $3 head now, $4 run id,
  # $5 run conclusion, $6 run attempt
  #
  # Pure, and the whole of D3: four gates in the order a refusal is cheapest to
  # explain. Nothing here reads the label — the label is what woke the run, and
  # a gate that trusted it would be inheriting the state it exists to check.
  local actor_ok="$1" named="$2" head="$3" run_id="$4" conclusion="$5" attempt="$6"
  [ "$actor_ok" = yes ] || { echo REFUSE:actor; return; }
  names_this_head "$named" "$head" || { echo REFUSE:head; return; }
  [ -n "$run_id" ] || { echo REFUSE:verdict; return; }
  [ "$conclusion" = failure ] || { echo REFUSE:verdict; return; }
  [ "$attempt" = 1 ] || { echo REFUSE:allowance; return; }
  echo START
}

refusal_body() { # $1 gate, $2 head now, $3 actor, $4 evidence head, $5 conclusion, $6 attempt, $7 run url
  # Every refusal names the gate, the fact that failed it, and what a human
  # would have to do — and the label stays on (D4). A refusal that dropped the
  # state would be the stall this action exists to end.
  local gate="$1" head="$2" actor="$3" named="$4" conclusion="$5" attempt="$6" url="$7" why=""
  case "$gate" in
    actor)
      why="**Gate 1 — the actor.** \`$LABEL\` was applied by \`$actor\`, which is not a fleet identity in this repository's \`.github/labels.conf\` (\`$(fleet_roster)\`). Nothing was rerun.

To service it: have one of those identities re-apply the label, or add \`$actor\` to \`panel=\`, \`panel[<login>]=\` or \`triage-actors=\` in that file if it belongs there."
      ;;
    head)
      if [ -z "$named" ]; then
        why="**Gate 2 — the head.** No comment from the PR author opens with \`${RERUN_OWED_MARKER}<sha>\`, so nothing names the head this label is about. Nothing was rerun.

To service it: post the evidence comment BUILDER.md asks for, naming the full head SHA, then re-apply the label."
      else
        why="**Gate 2 — the head.** The evidence names \`$named\`; this PR's head is now \`$head\`. A head that moved has its own checks, and rerunning the old one publishes a verdict about a tree nobody is reviewing. Nothing was rerun.

To service it: if the current head is red on the same unstartable rerun, evidence it at \`$head\` and re-apply the label."
      fi
      ;;
    verdict)
      if [ -z "$url" ]; then
        why="**Gate 3 — the verdict.** No run at \`$head\` that pre-dates the evidence is anything other than a success, so there is nothing here to rerun. Nothing was rerun.

To service it: nothing — a head with no failing run needs no attempt. Remove \`$LABEL\` if it is standing on a head that recovered. A run created *after* the evidence — including everything the label event itself woke — is never a candidate: it cannot be the run the evidence names."
      else
        why="**Gate 3 — the verdict.** The newest non-successful run at \`$head\` that pre-dates the evidence concluded \`${conclusion:-in flight}\`, not \`failure\`: $url. A cancelled run is not a verdict (#139, #209) and an in-flight one has not reached one, so neither is resurrected into one here. Nothing was rerun.

To service it: wait for the run to conclude, and re-apply the label if it concludes \`failure\`."
      fi
      ;;
    allowance)
      why="**Gate 4 — the allowance.** That run is already on attempt \`$attempt\`: $url. One rerun per head is BUILDER.md's existing allowance and this action adds none. Nothing was rerun.

To service it: a second failure at one head is no longer retryable-unknown — read the run, and either fix it or take it to the operator by hand."
      ;;
  esac
  # shellcheck disable=SC2016 # the backticks are markdown, not a substitution
  printf '%s`%s`\n\n%s\n\n<sub>`%s` is left standing: a refused service that drops the state is worse than no service at all (#424 D4).</sub>\n' \
    "$REFUSED_MARKER" "$head" "$why" "$LABEL"
}

started_body() { # $1 head, $2 run url, $3 attempt url, $4 run name
  # shellcheck disable=SC2016 # the backticks are markdown, not a substitution
  printf '%s`%s`\n\n**%s** was on attempt 1 and is now on attempt 2: %s\n\nThe run that was rerun: %s. `%s` is removed and this head is back in the ordinary red-or-green flow — if the rerun reds again the failure is no longer retryable-unknown, `blocker:ci-red` returns, and it is the builder'"'"'s (#423 D5).\n' \
    "$STARTED_MARKER" "$1" "$4" "$3" "$2" "$LABEL"
}

api_read() { # $1 = description, rest = gh api args → stdout, or a loud failure
  local what="$1"
  shift
  local out=""
  if ! out="$(gh api "$@" 2>&1)"; then
    echo "ci-rerun: could not read $what: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

post_comment() { # $1 = body
  run gh api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" -f "body=$1" --silent
}

remove_label() {
  # REST, not `gh pr edit`: a DELETE of one label is idempotent, touches no
  # other label on the PR (the #130 clobber, one surface over), and needs no
  # GraphQL — which is where `gh pr edit` dies on a repo wearing classic
  # projects.
  run gh api -X DELETE "repos/$REPO/issues/$PR_NUMBER/labels/$LABEL" --silent
}

main() {
  : "${REPO:?ci-rerun: REPO is required}"
  : "${PR_NUMBER:?ci-rerun: PR_NUMBER is required}"
  : "${ACTOR:?ci-rerun: ACTOR is required}"
  LABELS_CONF="${LABELS_CONF:-.github/labels.conf}"

  # The event's own label, when the caller passes it: this workflow is woken by
  # one label and must be inert for every other. Checked here as well as in the
  # workflow's `if:` because a caller is a file a consumer copies, and a gate
  # that lives only in copied YAML is a gate one consumer will paste away.
  if [ -n "${EVENT_LABEL:-}" ] && [ "${EVENT_LABEL}" != "$LABEL" ]; then
    log "labeled '$EVENT_LABEL' — not $LABEL; nothing to do"
    return 0
  fi

  load_fleet "$LABELS_CONF" || return $?

  local actor_ok=no
  is_fleet_actor "$ACTOR" && actor_ok=yes

  local head named="" runs="" record="" run_id="" conclusion="" attempt="" url="" name=""
  # One read for both facts: the head this service is about and the author whose
  # evidence names it. Two reads of one endpoint would also let the two disagree
  # across a push landing between them.
  local pr author
  pr="$(api_read "PR #$PR_NUMBER" "repos/$REPO/pulls/$PR_NUMBER" \
    --jq '[.head.sha, .user.login] | @tsv')" || return 1
  IFS=$'\t' read -r head author <<<"$pr"

  # The evidence is the PR AUTHOR's, as the reconciler reads it (#423): the
  # label is the builder's to set with its evidence, so a marker quoted back by
  # a reviewer is a quotation and not a second flag.
  local evidence="" cutoff=""
  if [ "$actor_ok" = yes ]; then
    # Each comment reduces to `created_at<TAB>first line`: the head the evidence
    # names and the moment it was written are one comment's two facts, and the
    # selector needs both. @tsv escapes a tab inside a body, so the record is
    # two fields whatever the builder typed.
    evidence="$(RERUN_OWED_AUTHOR="$author" api_read "PR #$PR_NUMBER's comments" --paginate \
      "repos/$REPO/issues/$PR_NUMBER/comments" \
      --jq '.[] | select(.user.login == env.RERUN_OWED_AUTHOR)
            | [ .created_at, (.body | split("\n")[0] | sub("\r$"; "")) ] | @tsv')" || return 1
    named="$(cut -f2- <<<"$evidence" | evidence_named_head)"
    cutoff="$(evidence_marker_time <<<"$evidence")"
  fi

  # Only reached once the head is known to be the evidenced one: a run list for
  # a head nobody named answers no question this service asks.
  if [ "$actor_ok" = yes ] && names_this_head "$named" "$head"; then
    runs="$(api_read "the runs at $head" \
      "repos/$REPO/actions/runs?head_sha=$head&per_page=100")" || return 1
    # This service's own run is in that list — a `pull_request_target` run
    # carries the PR head's SHA — so the list already carries the moment the
    # label event fired, at no extra API call. Floor the evidence cutoff with
    # it: BUILDER.md has the evidence comment SET the label, so the evidence is
    # normally the earlier of the two, but a builder who labelled first would
    # otherwise widen the window back over the cohort that event created.
    cutoff="$(earlier_time "$cutoff" "$(run_created_at "${GITHUB_RUN_ID:-}" <<<"$runs")")"
    record="$(pick_run "$SELF_WORKFLOW" "$cutoff" <<<"$runs")"
    # `|| true` because an empty record is an answer — a head whose every run
    # succeeded — and gate 3 is where that is said, not here.
    IFS=$'\t' read -r run_id conclusion attempt url name <<<"$record" || true
  fi

  local decision
  decision="$(service_decision "$actor_ok" "$named" "$head" "${run_id:-}" \
    "${conclusion:-}" "${attempt:-}")"

  if [ "$decision" != START ]; then
    local gate="${decision#REFUSE:}"
    log "refused at $head: gate $gate (actor=$ACTOR evidence=${named:-none} cutoff=${cutoff:-none} run=${run_id:-none} conclusion=${conclusion:-none} attempt=${attempt:-none})"
    echo "::warning::ci-rerun: refused at $head — gate $gate; $LABEL left standing"
    post_comment "$(refusal_body "$gate" "$head" "$ACTOR" "$named" "$conclusion" "$attempt" "$url")" ||
      { echo "ci-rerun: the refusal comment could not be posted" >&2; return 1; }
    return 0
  fi

  # The one privileged act, and the only one. It comes FIRST: the label removal
  # and the comment are bookkeeping about an attempt that either started or did
  # not, and doing them first would announce one that never did.
  if ! run gh api -X POST "repos/$REPO/actions/runs/$run_id/rerun-failed-jobs" --silent; then
    echo "ci-rerun: the rerun of $run_id could not be started" >&2
    post_comment "$REFUSED_MARKER\`$head\`

**The API refused the rerun.** \`$name\` (run \`$run_id\`) passed all four gates and \`POST /actions/runs/$run_id/rerun-failed-jobs\` failed anyway: $url. Nothing was rerun and \`$LABEL\` is left standing.

To service it: check the caller grants \`actions: write\`, then re-apply the label." || true
    return 1
  fi

  remove_label || { echo "ci-rerun: $LABEL could not be removed" >&2; return 1; }
  post_comment "$(started_body "$head" "$url" "$url/attempts/$((attempt + 1))" "$name")" ||
    { echo "ci-rerun: the start comment could not be posted" >&2; return 1; }
  log "started attempt $((attempt + 1)) of $name (run $run_id) at $head; $LABEL removed"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
