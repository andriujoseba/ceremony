#!/usr/bin/env bash
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
else
  # Fixture tests source the pure functions and deliberately inspect failures.
  set -u
fi

# labels-reconcile.sh — the automation LABELS.md promises: state labels are
# written by machinery, never by hand. Every run derives each open PR's
# state:* from GitHub's own facts (draft flag, requested reviewers, submitted
# reviews) and converges the labels to it, so a killed run or a hand-moved
# label heals on the next pass. Stale is judged from real activity — commits,
# comments, reviews — never from label churn, or the sweep would un-stale its
# own mark every tick.
#
# The verdict contract (CONTRIBUTING.md): reviews end in approve or
# request-changes. Some live bots are comment-only and post agreement as a
# COMMENTED review — a non-verdict this machine refuses to guess about (body
# parsing is a heuristic, and a wrong guess promotes an unapproved PR). The
# judgment call belongs to the PR AUTHOR, who reads the round and escalates
# by requesting the human's review — an explicit request is a fact, and it is
# the one this machine trusts (see decide_state's top precedence). The
# machine auto-requests the human only in the no-judgment-needed case: every
# required verdict is a formal head-current approval. Any approval that counts
# must be bound to
# the CURRENT head SHA: GitHub keeps approvals alive across pushes, and a
# stale approval must never promote unreviewed code to the human.
#
# DRY_RUN=1 narrates every mutation instead of performing it (how this script
# is rehearsed against the live repo). A workflow_dispatch run also bootstraps
# the taxonomy (label create --force) — that heal is dispatch-only; the cron
# sweep tolerates a missing label rather than recreating it.
#
# The state machine below is pure (globals in, state out) and covered by
# fixture tests in test/labels-reconcile.test.sh.

HUMAN="${HUMAN_REVIEWER:-danmt}"
BOTS=()
# Per-author panels (#224): parallel arrays because the conf is tiny and an
# associative array buys nothing but a bash-4 dependency statement. One entry
# per panel[<login>]= row — PANEL_AUTHORS holds the login, PANEL_ROWS the
# space-joined reviewer set at the same index.
PANEL_AUTHORS=()
PANEL_ROWS=()
REQUIRED_BOTS=()
STATES=(state:building state:bots-reviewing state:addressing state:needs-human)
BLOCKERS=(blocker:conflict blocker:ci-red blocker:unrequested)
# The PR's current labels, set per PR by the sweep. Initialized here because
# the script runs under `set -u` even when sourced, and the pure-function
# fixtures call decide_state — which now reads has_label — without ever
# setting it (#51). An empty default keeps has_label honest for every caller.
LABELS=""
# The head SHA named by the newest `rerun-owed` evidence comment on this PR;
# empty when the PR does not carry the label, no evidence names a head, or the
# comments could not be read. Read only on PRs carrying the label — one API
# call, paid by the few (#423).
RERUN_OWED_HEAD=""
# What that evidence comment opens with. A marker, not a prose match: the head
# it names is a fact the machine acts on, so it is written where a machine can
# read it, in the shape this repo's other head-scoped markers already use.
RERUN_OWED_MARKER='🔁 rerun owed at head '
# Labels this machine used to own and no longer does. Cleared on sight so a
# retirement heals the board instead of stranding a label nothing recomputes.
RETIRED=(state:needs-rebase)
STALE_AFTER=$((48 * 3600))
# How long the facts behind blocker:unrequested must have stood still before it
# is written (#236 D2). The operator's "more than 5 minutes", measured off the
# inputs' own timestamps rather than off sweep memory — this script is
# stateless per pass and stays that way. Overridable the way this file's other
# constants are, for a caller whose round cadence is slower or faster.
RECONCILE_UNREQUESTED_GRACE="${RECONCILE_UNREQUESTED_GRACE:-300}"
# The workflow whose runs checks_state must never grade — its own (#208).
# GITHUB_WORKFLOW is ambient in every Actions step and names the CALLER (the
# consumer's PR-facing workflow, since consumers name the caller), so this
# self-serves with no workflow-file change. The explicit override exists for
# two readers: the fixtures, and #209's detached sweep caller, which will
# need to point this at the PR-facing caller's name once reconcile no longer
# runs inside it. Empty means "filter nothing" — a caller outside Actions
# (a local rehearsal, an older pin) must not silently start dropping entries.
SELF_WORKFLOW="${SELF_WORKFLOW:-${GITHUB_WORKFLOW:-}}"

# The needs-ruling invariants (#52) — one implementation for both surfaces.
# shellcheck source=lib/ruling.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/ruling.sh"
# The attention target invariants (#232) — diagnosis only, both surfaces.
# shellcheck source=lib/attention.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/attention.sh"
# The guarded read and its reason line (#101) — one implementation for both
# surfaces. read_failure_reason lived here until the issue surface needed the
# identical rule (#247); a second copy of it is the failure lib/ruling.sh's
# own header was written to record.
# shellcheck source=lib/read.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/read.sh"
# The rollup classifier (#136, #139, #208) — one implementation for both
# reconcilers since #440, which gave the issue surface a second reader. Its
# SELF_WORKFLOW contract is the assignment above; the lib defaults nothing.
# shellcheck source=lib/checks.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/checks.sh"

log() { printf 'labels: %s\n' "$*"; }

run() { # every mutation goes through here — DRY_RUN=1 logs instead of doing
  if [ -n "${DRY_RUN:-}" ]; then log "DRY_RUN: $*"; else "$@"; fi
}

blind_sweep_warning() { # $1 = unreadable PRs, $2 = all open PRs, $3 = sampled read-failure reason
  # Report, do not diagnose (#101 D5). The old text asserted the caller's
  # checks:/statuses: grants as THE cause — an inference #95 made from a
  # control case, and the merged consumer-side fix (incubator#48/PR #49)
  # left the symptom standing while the run emitting this warning held the
  # evidence that would have said so. Lead with what gh actually said this
  # sweep; the permissions hint stays, demoted to one named candidate.
  if [ "$2" -gt 0 ] && [ "$1" -eq "$2" ]; then
    local reason="${3:-}"
    if [ -n "$reason" ]; then
      echo "::warning::labels: every open PR was unreadable; sampled reason: $reason — one candidate is missing checks: read, statuses: read and actions: read in the caller (private repos do not imply them)"
    else
      echo "::warning::labels: every open PR was unreadable; no reason was captured — one candidate is missing checks: read, statuses: read and actions: read in the caller (private repos do not imply them)"
    fi
  fi
}

missing_core_labels_warning() { # $1 = declared rows, $2 = repo label names
  local rows="$1" repo_labels="$2" row name missing=""
  [ -n "$repo_labels" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="${row%%|*}"
    if ! grep -qxF "$name" <<<"$repo_labels"; then
      if [ -n "$missing" ]; then missing="$missing, $name"; else missing="$name"; fi
    fi
  done <<<"$rows"
  if [ -n "$missing" ]; then
    echo "::warning::labels: missing core label(s): $missing; bump the ceremony pin, then re-dispatch workflow_dispatch to bootstrap the taxonomy"
  fi
}

load_config() { # $1 = consumer labels.conf; panel is mandatory, scopes optional
  local conf="$1" line panel_seen=false
  [ -f "$conf" ] || {
    echo "labels: missing config: $conf (a panel= line is required)" >&2
    return 1
  }
  BOTS=()
  PANEL_AUTHORS=()
  PANEL_ROWS=()
  # shellcheck disable=SC2094 # parse_panel_author_row takes $conf for its
  # error messages only — nothing in this loop writes the file it reads
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # The panel[ prefix is matched QUOTED (#224 D7): in a case pattern an
    # unquoted panel[abc]=* is a bracket expression that matches panela=…,
    # panelb=…, panelc=… — silently rerouting ordinary settings. The
    # panela= tripwire in test/labels.test.sh goes red if this regresses.
    case "$line" in
      panel=*)
        [ "$panel_seen" = false ] || {
          echo "labels: duplicate panel line in $conf" >&2
          return 1
        }
        panel_seen=true
        read -r -a BOTS <<<"${line#panel=}"
        [ "${#BOTS[@]}" -gt 0 ] || {
          echo "labels: panel must name at least one reviewer in $conf" >&2
          return 1
        }
        ;;
      "panel["*) parse_panel_author_row "$line" "$conf" || return ;;
      triage-actors=*) ;;
      *) parse_label_row "$line" >/dev/null || return ;;
    esac
  done <"$conf"
  [ "$panel_seen" = true ] || {
    echo "labels: missing panel= line in $conf" >&2
    return 1
  }
}

parse_panel_author_row() { # panel[<login>]=<space-separated logins> (#224)
  # Every failure here is a hard one that names the offending line (D3): a
  # conf error takes the whole board down, and the run log is the only place
  # the operator can read why. A malformed bracket is refused AS a bracket
  # (D4) — falling through to parse_label_row would report it as a
  # "malformed label row", the misleading diagnostic #224 was filed over.
  local line="$1" conf="$2" login rest existing
  case "$line" in
    "panel["*"]="*) ;;
    *)
      echo "labels: malformed panel[<login>]= row (expected panel[<login>]=<reviewers>): $line in $conf" >&2
      return 1
      ;;
  esac
  login="${line#panel[}"
  login="${login%%]=*}"
  [ -n "$login" ] || {
    echo "labels: empty login in panel row: $line in $conf" >&2
    return 1
  }
  # The login must be exactly one well-formed bracket pair of login
  # characters. Without this, panel[z]]=b parses: the case above only
  # establishes that SOME ]= occurs, ${login%%]=*} keeps the stray ] inside
  # the login (z]), and set_required_bots for the real z then silently falls
  # back to the base panel — the misroute D4 exists to refuse. GitHub logins
  # are [A-Za-z0-9-], per the #285 spec.
  case "$login" in
    *[!A-Za-z0-9-]*)
      echo "labels: malformed panel[<login>]= row (a login is [A-Za-z0-9-] only): $line in $conf" >&2
      return 1
      ;;
  esac
  for existing in ${PANEL_AUTHORS[@]+"${PANEL_AUTHORS[@]}"}; do
    [ "$existing" != "$login" ] || {
      echo "labels: duplicate panel[$login]= row in $conf: $line" >&2
      return 1
    }
  done
  local -a row=()
  rest="${line#*]=}"
  read -r -a row <<<"$rest"
  [ "${#row[@]}" -gt 0 ] || {
    echo "labels: panel[$login]= must name at least one reviewer in $conf: $line" >&2
    return 1
  }
  PANEL_AUTHORS+=("$login")
  PANEL_ROWS+=("${row[*]}")
}

parse_label_row() { # exact name|color|description; pipes in descriptions are refused
  local line="$1" name color desc extra
  IFS='|' read -r name color desc extra <<<"$line"
  if [ -z "$name" ] || [ -z "$color" ] || [ -z "$desc" ] || [ -n "${extra:-}" ]; then
    echo "labels: malformed label row: $line" >&2
    return 1
  fi
  printf '%s|%s|%s\n' "$name" "$color" "$desc"
}

configured_label_rows() { # validated scope rows, excluding the panel setting
  local conf="$1" line
  [ -f "$conf" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    # "panel["* quoted for the same D7 reason as load_config's case; skipping
    # the bracketed rows (D5) keeps a dispatch bootstrap from trying to
    # create a label named panel[<login>].
    case "$line" in panel=* | "panel["* | triage-actors=*) continue ;; esac
    parse_label_row "$line" || return
  done <"$conf"
}

panel_for_author() { # $1 = author → the effective panel, space-joined (#224 D2)
  # THE resolution point: the author's panel[<login>]= row when the conf
  # defines one, the base panel= otherwise. Everything that computes a
  # required set goes through here, because two places computing the panel
  # is how the engine and the reconciler came to disagree in the first place.
  local author="$1" i
  for i in ${PANEL_AUTHORS[@]+"${!PANEL_AUTHORS[@]}"}; do
    if [ "${PANEL_AUTHORS[i]}" = "$author" ]; then
      printf '%s\n' "${PANEL_ROWS[i]}"
      return
    fi
  done
  printf '%s\n' "${BOTS[*]}"
}

set_required_bots() { # the PR author is recused by construction
  # Minus-the-author applies to WHICHEVER set panel_for_author returns (#224
  # D2's safety net): an author who mistakenly appears inside its own
  # bracketed row is still recused.
  local author="$1" bot
  local -a effective=()
  read -r -a effective <<<"$(panel_for_author "$author")"
  REQUIRED_BOTS=()
  for bot in ${effective[@]+"${effective[@]}"}; do
    [ "$bot" = "$author" ] || REQUIRED_BOTS+=("$bot")
  done
}

# ---------------------------------------------------------------------------
# The state machine. Pure functions over these globals, set per PR:
#   DRAFT        true|false
#   HEAD_SHA     the PR's current head commit
#   BASE_SHA     the PR's base branch head (the release-shape guard's ref)
#   REQUESTED    newline-separated logins with a review currently requested
#   REVIEWS_JSON JSON array of submitted (non-PENDING) reviews
#   MERGEABLE    MERGEABLE | CONFLICTING | UNKNOWN  (GitHub's own verdict)
#   CHECKS       SUCCESS | FAILURE | PENDING | NONE (the check rollup)
#   LABELS       newline-separated labels currently on the PR
#   HEAD_COMMIT_AT  the head commit's own date, ISO-8601; empty when unread
#   NOW          this sweep's epoch seconds (main sets it once per run)
# ---------------------------------------------------------------------------

requested() { grep -qxF "$1" <<<"$REQUESTED"; }

bot_verdict() { # $1 = login → MISSING | BLOCK | APPROVE | STALE | FEEDBACK
  local review state commit
  review="$(jq -c --arg u "$1" \
    '[.[] | select(.user.login == $u)] | sort_by(.submitted_at) | last // empty' \
    <<<"$REVIEWS_JSON")"
  if [ -z "$review" ]; then echo MISSING; return; fi
  state="$(jq -r '.state' <<<"$review")"
  commit="$(jq -r '.commit_id' <<<"$review")"
  case "$state" in
    CHANGES_REQUESTED)
      # blocks at ANY head — GitHub's own semantic: only a newer review
      # from the same reviewer clears it
      echo BLOCK ;;
    APPROVED)
      if [ "$commit" = "$HEAD_SHA" ]; then echo APPROVE; else echo STALE; fi ;;
    *)
      # COMMENTED and anything else: a non-verdict. The machine does not
      # read bodies — if the comment is really an agreement, the AUTHOR
      # says so by requesting the human's review.
      echo FEEDBACK ;;
  esac
}

iso_epoch() { # $1 = ISO-8601 timestamp → epoch seconds; nothing, rc 1, when unreadable
  # An absent field reaches this as the empty string or as jq's literal "null";
  # both are "we did not read a time", and neither may be graded as one.
  local at="${1-}" epoch
  case "$at" in "" | null) return 1 ;; esac
  epoch="$(date -d "$at" +%s 2>/dev/null)" || return 1
  [ -n "$epoch" ] || return 1
  printf '%s\n' "$epoch"
}

unrequested_quiescent() { # 0 when the unrequested facts have stood for the grace (#236 D2)
  # The stall blocker's supporting facts are the head and the round's newest
  # submitted review: the ask it demands is owed only once both have stopped
  # moving. Measured off those timestamps, not off sweep memory — ceremony#235
  # was flagged inside the ~90 seconds between a round-answer push and the
  # author's re-request, because a sweep read the facts before the request
  # landed and wrote after it. That is a round in motion, not a dropped ball.
  #
  # "Newest submitted review" is any submitted review, COMMENTED included: a
  # non-verdict is still evidence the round is live, and counting it can only
  # delay a flag, never invent one.
  #
  # A timestamp we could not read refuses the blocker (the standing rule: an
  # unreadable fact never invents a verdict). This direction is deliberate and
  # asymmetric — a missed flag costs one sweep of the 15-minute cadence, a
  # false one flags a builder for doing exactly what BUILDER.md requires.
  local newest verdict_at verdict_epoch
  newest="$(iso_epoch "${HEAD_COMMIT_AT:-}")" || return 1
  verdict_at="$(jq -r '[.[].submitted_at] | max // empty' <<<"${REVIEWS_JSON:-[]}")"
  if [ -n "$verdict_at" ]; then
    # A round WITH verdicts whose newest one cannot be dated is unreadable, not
    # quiescent; a round with no verdicts at all is simply the head's clock.
    verdict_epoch="$(iso_epoch "$verdict_at")" || return 1
    [ "$verdict_epoch" -gt "$newest" ] && newest="$verdict_epoch"
  fi
  [ $((${NOW:-0} - newest)) -ge "$RECONCILE_UNREQUESTED_GRACE" ]
}

human_request_needed() { # 0 when needs-human requires a FRESH human request
  # already requested → the handoff is live; head-current human approval →
  # nothing left to ask. Anything else (never reviewed, an old comment, an
  # approval of an older head) stalls the handoff unless we request —
  # guarding on "has the human ever reviewed" wedged exactly that way.
  if requested "$HUMAN"; then return 1; fi
  if [ "$(bot_verdict "$HUMAN")" = APPROVE ]; then return 1; fi
  return 0
}

rerun_owed_state() { # → STANDS | CLEARED | ABSENT — what `rerun-owed` says about THIS head
  # The label a builder sets when the head is red on a rerun no identity in the
  # fleet can start (#423). It is not a blocker: every blocker:* names work the
  # BUILDER owes, and here the builder owes nothing and a human owes one API
  # call. So it is hand-set intent this machine reads, like `needs-ruling` and
  # `blocked` — with one difference that is the whole reason it is a label at
  # all: this one the machine CLEARS, because its subject is a head, and a head
  # moves. Set by the builder with its evidence, cleared here at the transition.
  #
  # Two transitions end it, and both are read off facts this sweep already has:
  #
  #   the head's checks left FAILURE — whatever was owed was serviced, or the
  #   run reported something else; nothing is owed at a green head; and
  #
  #   the head MOVED under the label — the evidence named a commit that is no
  #   longer this PR's head. Almost every such push clears by the first test
  #   (a new head's checks are NONE or PENDING before they are anything else);
  #   this second one is for the push that reds again, where the label would
  #   otherwise suppress blocker:ci-red for a failure nobody has evidenced.
  #
  # "The head moved" is a question about IDENTITY and is answered with identity:
  # the evidence names its head, and this asks whether that is still the head.
  # It deliberately does not ask whether the head commit is NEWER than the flag,
  # which an earlier draft of this did: a commit's date is a field its author
  # writes, so that test both discarded a valid label under clock skew and let
  # the label suppress blocker:ci-red after a reset onto an older red commit —
  # neither of which is a fact about which commit the branch points at (#423).
  #
  # A head not named, not read, or named unreadably leaves the question unjudged
  # and the label standing — an unread fact never invents a verdict, and here
  # the error directions are not symmetric: a label wrongly kept asks a human to
  # look at a PR that is fine, a label wrongly cleared tells a builder to fix a
  # tree that is not broken, which is the defect this label exists to end.
  has_label rerun-owed || { echo ABSENT; return; }
  case "${CHECKS:-NONE}" in FAILURE) ;; *) echo CLEARED; return ;; esac
  local named="${RERUN_OWED_HEAD:-}" head="${HEAD_SHA:-}"
  # Prefix, not equality: a marker naming an abbreviated SHA names this head as
  # surely as a full one, and reading it as a moved head would clear a label on
  # a spelling. Both empty-guards are load-bearing — an unread head SHA is not
  # a differing one.
  if [ -n "$named" ] && [ -n "$head" ] &&
    [ "${head:0:${#named}}" != "$named" ]; then
    echo CLEARED
    return
  fi
  echo STANDS
}

rerun_owed_named_head() { # evidence first-lines on stdin → the head the newest names
  # Pure, so the fixtures can drive the parse rather than the API around it, and
  # split off here for the reason lib/attention.sh splits attention_newest_flag
  # off: the read either worked or it did not, and that is the caller's problem,
  # never a shape this function has to infer from an empty line.
  #
  # Newest wins, which is the order the comments API returns: a builder who
  # re-evidences a second unrerunnable head on the same PR has said something
  # newer, and the older marker is history.
  local line rest sha=""
  while IFS= read -r line; do
    case "$line" in "$RERUN_OWED_MARKER"*) ;; *) continue ;; esac
    # Newest wins even when the newest is unreadable, so the candidate dies on
    # the marker and not on the validation: a builder who evidences a second
    # head has superseded the first whether or not the new line spells its SHA,
    # and an older marker outliving it would answer a question the newest
    # evidence declines to answer — clearing a live label from a head nobody
    # currently names, which is the one direction this parse must never take.
    sha=""
    rest="${line#"$RERUN_OWED_MARKER"}"
    rest="${rest#\`}"                # the house style backticks a SHA
    rest="${rest,,}"                 # ...and a pasted one may be upper-case
    rest="${rest%%[!0-9a-f]*}"       # everything after the hex run is prose
    # A marker whose head is not a SHA names no head. Seven is git's own floor
    # for an abbreviation and forty is a whole one; outside that the line is
    # decoration somebody wrote, not a fact to clear a label on.
    if [ "${#rest}" -ge 7 ] && [ "${#rest}" -le 40 ]; then sha="$rest"; fi
  done
  [ -z "$sha" ] || echo "$sha"
}

blockers() { # → the blocker:* labels this PR should carry, one per line
  # The second axis. These are FACTS ABOUT THE BRANCH, and they are mutually
  # independent — a PR can be conflicted and red and unasked at once — so they
  # are a set, not an ordering. That is the whole point of splitting them out
  # of state:*: every precedence bug this machine has had (needs-human
  # surviving a conflict, MISSING swallowing STALE) came from projecting
  # independent facts onto one totally-ordered label. A set has no precedence
  # to get wrong.
  #
  # UNKNOWN mergeability is deliberately NOT a conflict: GitHub reports it for
  # about a minute after every merge while it recomputes, and flapping every
  # open PR on each merge would be worse than the bug. Same for a failed read
  # of either fact — both default to the "do not know" value, which blocks
  # nothing. An unset global (an older fixture, a failed fetch) must never
  # invent a verdict it did not read.
  case "${MERGEABLE:-UNKNOWN}" in CONFLICTING) echo blocker:conflict ;; esac
  # A red head is the builder's by default and stays so. The one exception is a
  # head standing under `rerun-owed` (#423): blocker:ci-red asserts the builder
  # owes a FIX, and on a fork PR whose run only the base repo may restart that
  # sentence is false in every word — the tree is not broken, the fix does not
  # exist, and the actor is not in the fleet. Suppressing the blocker is not a
  # claim the head is green: `blocker:unrequested` still reads FAILURE below,
  # decide_state still refuses state:needs-human on it, and the label itself is
  # what the board says instead. The moment rerun_owed_state stops saying STANDS
  # — the head went green, or moved — this line returns unchanged, in the same
  # sweep that clears the label.
  case "${CHECKS:-NONE}" in
    FAILURE) [ "$(rerun_owed_state)" = STANDS ] || echo blocker:ci-red ;;
  esac

  # Nobody is on the hook for a verdict somebody still owes. Distinct from
  # bots-reviewing, which says a request is live and an answer is coming:
  # here the round is stalled because no one was ever asked, and the board
  # said "waiting on the bots" for the 48h it took `stale` to notice.
  # A draft is exempt (the bots ignore drafts by design), and so is an
  # explicit human request — a maintainer claiming a PR early is deliberate,
  # not a dropped ball.
  #
  # And so is a head whose checks have not answered yet (#236 D1). This is the
  # one blocker that names an act the author must PERFORM, so it is the one
  # that has to know when performing it is permitted: BUILDER.md's review round
  # requires a green check at the head before requesting, so a builder waiting
  # out a pending run is complying, and flagging compliance teaches its readers
  # to ignore the label. Both 2026-08-03 instances were exactly that —
  # crew#318 at ~12:44Z carried state:addressing + blocker:unrequested while
  # the head's run was IN_PROGRESS, and ceremony#235 at 12:30Z caught the
  # ~90-second gap between a round-answer push and the re-request.
  #
  # PENDING and FAILURE each already have an owner, which is why gating loses
  # no coverage: on PENDING the next move is CI's and state:addressing /
  # state:bots-reviewing already say what the PR is doing; on FAILURE
  # blocker:ci-red owns that head, and stacking a second blocker on it
  # double-flags one stall. NONE joins SUCCESS because no checks configured is
  # nothing to wait for — the same reading the request rule gives the builder.
  # UNREADABLE never arrives here: the caller skips the PR before deciding.
  local checks_permit_the_ask=false
  case "${CHECKS:-NONE}" in SUCCESS | NONE) checks_permit_the_ask=true ;; esac
  if [ "$DRAFT" != true ] && [ "$checks_permit_the_ask" = true ] && ! requested "$HUMAN"; then
    local b v owed=false any_requested=false
    for b in "${REQUIRED_BOTS[@]}"; do
      requested "$b" && any_requested=true
      # MISSING and STALE are both verdicts this head does not have: nobody
      # reviewed it, or everybody reviewed something else. The agent owes an
      # ask either way — the stale round is if anything the worse of the two,
      # since it has approvals on the page that no longer describe the tree.
      v="$(bot_verdict "$b")"
      case "$v" in MISSING | STALE) owed=true ;; esac
    done
    # The quiescence grace (#236 D2) is the last question, after the debt is
    # established: it asks whether the debt has stood long enough to be a
    # dropped ball rather than a round still in motion.
    if [ "$owed" = true ] && [ "$any_requested" = false ] && unrequested_quiescent; then
      echo blocker:unrequested
    fi
  fi
}

round_outranks_draft() { # 0 when the round's standing word survives a re-draft (#205)
  # A standing non-approving verdict outranks draft: a PR that took a round,
  # carries CHANGES_REQUESTED (or a comment owed a reply, or approvals a push
  # staled), and is then converted back to draft is a fix round in progress,
  # not a build — and hiding it behind state:building is a dropped ball the
  # staleness sweep reads as work in progress. Approvals do NOT outrank
  # draft: a re-draft after a passed round is deliberately building again,
  # and a draft must never read state:needs-human.
  #
  # A LIVE panel request on a draft also falls through — deliberately
  # surfaced, not absorbed (#205's must-not-paper-over): the bots ignore
  # drafts by design, so a draft wearing state:bots-reviewing on the board
  # is the visible symptom of a real defect (a request nobody cleared at
  # round close, or a hand-requested draft), and reading it as building
  # would hide exactly that.
  local b
  for b in "${REQUIRED_BOTS[@]}"; do
    requested "$b" && return 0
    case "$(bot_verdict "$b")" in BLOCK | FEEDBACK | STALE) return 0 ;; esac
  done
  [ "$(bot_verdict "$HUMAN")" = BLOCK ]
}

decide_state() { # → the one state:* label this PR should carry
  # Draft decides the state only when the round implies nothing else (#205):
  # a draft with no round history reads state:building exactly as it always
  # has, and round_outranks_draft is what "nothing else" means.
  if [ "$DRAFT" = true ] && ! round_outranks_draft; then
    echo state:building
    return
  fi

  local s
  s="$(round_state)"

  # A draft disqualifies needs-human unconditionally (#205, round 1): with
  # the short-circuit above now conditional, a draft carrying a live human
  # request plus a standing bot block or comment fell through to
  # round_state, whose explicit-human-request precedence sits above the
  # BLOCK/FEEDBACK cases — and GitHub cannot merge a draft at all, so
  # "a human could merge this right now" would lie no matter what the
  # round says. state:addressing is the same honest landing the blocker/
  # needs-ruling/blocked clauses below use: the round's word stands, only
  # the mergeable-now claim is off the table while the PR is a draft.
  if [ "$s" = state:needs-human ] && [ "$DRAFT" = true ]; then
    echo state:addressing
    return
  fi

  # The one rule joining the two axes: state:needs-human means a human could
  # merge this RIGHT NOW, so it requires a clear branch. Any blocker at all
  # means the work is the agent's — whatever the review round says — and the
  # blocker label says which work it is. Nothing else in this function reads
  # the branch, which is what keeps the ordering below purely about reviews.
  if [ "$s" = state:needs-human ] && [ -n "$(blockers)" ]; then
    echo state:addressing; return
  fi

  # And the branch fact behind blocker:ci-red, asked directly rather than
  # through the label (#423). Until `rerun-owed` existed these were the same
  # question — FAILURE always produced the blocker, and the clause above always
  # caught it — so on every PR without that label this line changes nothing and
  # a fixture pins that. With it, the clause above can come up empty at a head
  # whose checks are red, and state:needs-human means exactly "a human could
  # merge this RIGHT NOW", which is false at a red head however good the reason
  # for the red is. Deliberately NOT `has_label rerun-owed`: the label never
  # enters a refusal set, because a label that disqualifies needs-human is
  # acting as a blocker and this one is not one. The red head is what refuses;
  # the label only says who is owed the next move.
  if [ "$s" = state:needs-human ] && [ "${CHECKS:-NONE}" = FAILURE ]; then
    echo state:addressing; return
  fi

  # A pending ruling disqualifies needs-human the same way (#51): while
  # `needs-ruling` is up, the human's turn lives in the THREAD — the flag
  # marks it — and "mergeable right now" must not read true beside an open
  # decision. state:addressing is the honest landing because the ball ON THE
  # PR is the builder's: the flag-setter judges when agreement is reached and
  # carries the ruling in (#50 D6). The label is deliberately NOT in BLOCKERS:
  # that array is machine-owned, and the converge loop strips every entry the
  # current facts do not re-derive — `needs-ruling` is hand-set intent the
  # machine reads and never writes (#50 D9), so parking it there would strip
  # a live escalation on the next 15-minute tick.
  if [ "$s" = state:needs-human ] && has_label needs-ruling; then
    echo state:addressing; return
  fi

  # A directed hold disqualifies it the same way (#180): `blocked` is hand-set
  # intent — triage sets it, anyone may correct it — and during the #111
  # freeze rig#126/#128 carried it beside state:needs-human, so the board said
  # "mergeable right now" about PRs a hold said must not merge (rig#126 was
  # merged seven minutes later). Not a BLOCKERS entry, deliberately: that
  # array is machine-owned and the converge loop strips whatever the facts do
  # not re-derive, so emitting the label there would strip a live hold on the
  # next 15-minute tick — the same trap #51 names for `needs-ruling`.
  # state:addressing is the accepted imprecision: under a hold the builder
  # owes nothing, but "a human could merge this now" must not lie.
  if [ "$s" = state:needs-human ] && has_label blocked; then
    echo state:addressing; return
  fi
  echo "$s"
}

# The take-back's episode marker (#377). Not the `ceremony:` family the
# ruling and attention markers use: this one carries its episode IN the
# marker — the blocker set and the head SHA — rather than being scoped by a
# `labeled` event the way those are, so it reads as its own kind.
HANDOFF_TAKEBACK_MARKER_PREFIX='<!-- handoff-taken-back:'

handoff_takeback_set() { # blocker lines on stdin → the canonical comma-joined set
  # Sorted, so one standing set has exactly ONE spelling in the marker: the
  # BLOCKERS order is fixed today, and an episode must not re-fire because a
  # later edit reordered the emitters in blockers().
  local b joined=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    joined="${joined:+$joined,}$b"
  done < <(sort)
  printf '%s\n' "$joined"
}

handoff_takeback_marker() { # $1 = canonical set, $2 = head SHA → the episode marker
  # The episode IS (blocker set, head): a new head or a different set is a new
  # thing to say, the same head with the same set is the sweep repeating
  # itself — and repeating itself hourly is worse than the silence this
  # replaces (#377 D2).
  printf '%s%s:%s -->\n' "$HANDOFF_TAKEBACK_MARKER_PREFIX" "$1" "$2"
}

handoff_taken_back() { # → the blockers that took a handoff back, one per line; nothing otherwise
  # D3: only the hand-set take-back speaks. This is decide_state's :597 clause
  # asked as a question — the PR already carried state:needs-human, the round
  # alone still says needs-human, and a blocker is what moved it — and it is
  # written in that clause's PRECEDENCE, not just its facts: the draft rule
  # sits above it, so a draft is the draft rule's take-back and never this
  # one, and needs-ruling and blocked sit below it, so they are only ever
  # reached with no blocker standing. Those three each already wear a visible
  # label saying why; the blocker case is the one whose "why" lived only in a
  # run log, which is the whole defect (#377).
  #
  # Hand-set is not separately detectable, and deliberately not chased: a
  # needs-human the machine wrote and a later red overtook lands here too, and
  # the comment is right in both cases — the handoff is off, and this is what
  # standing between it and the human.
  #
  # These three conditions ARE that clause — its guard, plus the one rule
  # above it — so the answer is decide_state's own, not a second opinion
  # about it. A test pins the equivalence across the fixture matrix rather
  # than a runtime re-ask that no fixture could ever red.
  # Since #423 the clause has one arm this predicate deliberately does not
  # report: a red head under `rerun-owed` moves needs-human to addressing with
  # NO blocker standing, so `blockers` is empty here and no comment is posted.
  # That is the same treatment `needs-ruling` and `blocked` already get one
  # paragraph up, and for the same reason — each of those take-backs wears a
  # visible label saying why, and this one wears the label whose whole purpose
  # is to say why. The comment exists for the take-back whose cause lived only
  # in a run log; this cause is on the board.
  has_label state:needs-human || return 0
  [ "$DRAFT" != true ] || return 0
  [ "$(round_state)" = state:needs-human ] || return 0
  blockers
}

round_state() { # → the state the REVIEW ROUND alone implies; knows no branch facts
  local b verdicts=""
  for b in "${REQUIRED_BOTS[@]}"; do
    if requested "$b"; then echo state:bots-reviewing; return; fi
  done
  # Collect the WHOLE round before applying any precedence. Deciding inside
  # the loop let BOTS order pick the winner: a MISSING returned immediately,
  # so a STALE belonging to a later bot was never even read, and the mixed
  # round (one approval staled by a push, another bot yet to review) came out
  # needs-human — the #136 headline shape, with zero reviews bound to the head.
  for b in "${REQUIRED_BOTS[@]}"; do
    verdicts="$verdicts $(bot_verdict "$b")"
  done
  case "$verdicts" in
    # STALE = a verdict for an older head. Unlike MISSING, this outranks the
    # human request: every approval it covers was invalidated by a push, so
    # NOBODY has reviewed this tree. Handing that to the human is the #136 case
    # where everything reads green — mergeable, CI passing, "waiting on the
    # human" — over code no reviewer has seen. The agent owes a re-request.
    # Checked before MISSING because "unfinished" must not swallow "and also
    # stale": a round that is both is a push that outran the re-requests, not
    # a maintainer deliberately claiming the PR early.
    *STALE*) echo state:addressing; return ;;
  esac
  case "$verdicts" in
    # No verdict at all from some bot, and nothing staled. An explicit human
    # request still outranks an unfinished round — a maintainer pulling a PR
    # to themselves early is a deliberate act, and the original precedence.
    #
    # Otherwise it is the AGENT's ball, not the bots'. The loop above already
    # returned for every live bot request, so reaching here with a MISSING
    # means somebody owes a verdict and nobody was asked for one — the round
    # is not running. Calling that bots-reviewing was the lie that let a
    # forgotten PR read "waiting on the reviewers" for the 48h it took the
    # stale sweep to notice. blocker:unrequested says why.
    *MISSING*)
      if requested "$HUMAN"; then echo state:needs-human; return; fi
      echo state:addressing; return ;;
  esac
  # an explicit human request outranks the remaining bot outcomes — it is the
  # final gate, and a maintainer pulling a PR to themselves early counts too
  if requested "$HUMAN"; then echo state:needs-human; return; fi
  case "$verdicts" in
    # FEEDBACK = a comment with no verdict → the agent owes the round-reply.
    *BLOCK* | *FEEDBACK*) echo state:addressing; return ;;
  esac
  # the bots all approve — but if the human's standing word is
  # changes-requested (and nobody re-requested them yet), the agent owes
  # fixes, not the human a nag
  if [ "$(bot_verdict "$HUMAN")" = BLOCK ]; then
    echo state:addressing
  else
    echo state:needs-human
  fi
}

# ---------------------------------------------------------------------------
# The sweep: fetch facts, decide, converge. One PR's failure never aborts the
# others — each PR reconciles in a subshell and a failure just logs.
# ---------------------------------------------------------------------------

core_label_rows() {
  cat <<'EOF'
state:building|FBCA04|Pre-round: the builder is still building — draft is evidence for it, not the definition
state:bots-reviewing|1D76DB|Waiting on the bot reviewers to finish the round
state:addressing|D93F0B|All bots reviewed — coding agent owes the single reply + fixes
state:needs-human|8250DF|No blockers, all bots approve — waiting on the human reviewer
blocker:conflict|B60205|Does not merge — the branch conflicts and the agent owes a rebase
blocker:ci-red|B60205|A check is failing — the agent owes a fix (not a rebase)
blocker:unrequested|E99695|Somebody still owes a verdict and nobody was asked for one
merge-next|0E8A16|Head of the merge queue — merge this one next (set by hand/agent, cleared here)
stale|B60205|No activity for 48h — needs a poke (sweep-managed)
blocked|6A737D|Waiting on another PR or issue to land first
offsite|CFD3D7|Issue deliverable is a PR in another repository — claim clock paused
needs-ruling|D4C5F9|A human decision is pending — question, options and a recommendation are in the comment
rerun-owed|D4C5F9|The head is red on a rerun no agent may start — a human owes the button, not the builder a fix
attention|D93F0B|A demand is parked here for the assignee: pick up the thread, ack by removing this label
release|0E8A16|Release flow and version/packaging work
needs-triage|FBCA04|Did not come through triage — owes normalization or conversion to a discussion
ready|0E8A16|Triaged, spec complete, unblocked — a builder can start now and succeed
claimed|1D76DB|A builder owns it: assignee set, draft PR expected shortly
post-merge|006B75|Refs-linked PR merged; post-merge criteria remain and triage owns completion
epic|5319E7|Organizes other issues via a dependency-ordered task list — builders never pick it
EOF
}

retired_label_names() { # the GitHub defaults LABELS.md retires — a `question` is a discussion
  # One registry, kept beside core_label_rows() for the same reason those rows
  # are not in labels.conf: a rule that must hold in every governed repo
  # cannot live in a per-repo file. The six names match LABELS.md exactly.
  cat <<'EOF'
duplicate
invalid
question
wontfix
help wanted
good first issue
EOF
}

bootstrap_labels() { # dispatch-only: ~20 upserts is too chatty for every cron tick
  local rows name
  rows="$(core_label_rows)"
  if [ -f "$LABELS_CONF" ]; then
    rows="$rows
$(configured_label_rows "$LABELS_CONF")"
  fi
  while IFS='|' read -r name color desc; do
    [ -n "$name" ] || continue
    run gh label create "$name" -R "$REPO" --color "$color" --description "$desc" --force
  done <<<"$rows"

  # LABELS.md publishes the defaults as deleted at bootstrap; until #93
  # nothing deleted them — incubator's first dispatch ran green and left
  # `good first issue` standing. Deletion is dispatch-only like the upserts,
  # and never fatal: `gh label delete` exits non-zero on a label that is
  # already gone, the NORMAL case from the second dispatch on, and under
  # set -e an unguarded call aborts the whole run (#91's shape). A 403
  # refusal gets the same tolerance — the bot bootstrap already 403s on
  # blocker:drill-pending, and a token that cannot delete must still get
  # the taxonomy it can create. Either way: log the name, keep going.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    run gh label delete "$name" -R "$REPO" --yes \
      || log "retire: '$name' not deleted (already absent, or refused) — continuing"
  done <<<"$(retired_label_names)"
}

has_label() { grep -qxF "$1" <<<"$LABELS"; }

release_shape_warning() { # $1 = PR, $2 = head version, $3 = base version
  # The #128 incident's guard (#130): a release-shaped PR — bare X.Y.Z at
  # its head where the base says something else — reaching the board with
  # no `release` label is exactly the state whose merge would publish
  # nothing, so the sweep says so instead of letting the merge door
  # discover it. A WARNING, never a write: `release` is declared intent,
  # and the reconciler does not guess intent (LABELS.md's rule for
  # `blocked`/`release`). An unreadable version blocks nothing — the
  # sweep must not nag on facts it did not read.
  local n="$1" head_ver="$2" base_ver="$3"
  [ -n "$head_ver" ] || return 0
  grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$head_ver" || return 0
  [ "$head_ver" != "$base_ver" ] || return 0
  echo "::warning::labels: #$n is release-shaped (version ${base_ver:-unreadable} -> $head_ver at its head) but carries no release label — the merge door reads that label as declared intent and will refuse without it; if this is the ceremony PR, apply release (#130; the #128 incident)"
}

tree_version() { # $1 = ref → that tree's version via the API, or nothing
  # Both backends, no checkout: a VERSION file first, package.json's
  # version field second (jq, not node — a read needs no npm machinery).
  # Every failure path prints nothing: the caller treats "could not read"
  # as "not release-shaped" rather than warning on a guess.
  local ref="$1" ver
  ver="$(gh api "repos/$REPO/contents/VERSION?ref=$ref" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$ver" ]; then
    ver="$(gh api "repos/$REPO/contents/package.json?ref=$ref" --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
  fi
  [ -z "$ver" ] || printf '%s\n' "$ver"
  return 0
}

reconcile_handoff_takeback() { # $1 = PR number, $2 = did the converge edit take it back?; at most one comment per episode (#377)
  # The defect this closes is not the take-back — that rule is correct and
  # unchanged — but its silence: `log` writes to the labels workflow's run
  # log, and a builder driving a PR reads the PR. On incubator#94 a hand-set
  # label vanished 45 seconds later with no comment three times running, and
  # writing it again is the rational answer to a write that disappears
  # without a reason.
  local n="$1" cleared="$2" standing joined marker bodies b pretty=""

  # D1's trigger is the replacement that LANDED, not the one attempted. The
  # caller passes the answer because only it knows: a `gh issue edit` that
  # failed, or one skipped because the repo's taxonomy has no
  # `state:addressing`, leaves `state:needs-human` standing on the PR — and
  # "the state is state:addressing again" would then be false ABOUT A LABEL
  # STILL THERE, which is the loudest way to be wrong here. Worse than the
  # falsehood is its durability: the marker such a comment records suppresses
  # the true one at that (set, head) forever, so the pass where the edit does
  # land would say nothing. Not a comment condition so much as the definition
  # of the event — nothing was taken back until the label came off.
  [ "$cleared" = true ] || return 0

  standing="$(handoff_taken_back)"
  [ -n "$standing" ] || return 0
  joined="$(handoff_takeback_set <<<"$standing")"
  marker="$(handoff_takeback_marker "$joined" "$HEAD_SHA")"

  # The comment read is behind the trigger, so an ordinary PR pays nothing for
  # it. A failed read says nothing: everywhere else in this file an unreadable
  # fact must not invent a verdict, and here it must not invent a REPEAT —
  # duplicate comments are the harm the marker exists to prevent, and the next
  # sweep is 15 minutes away.
  if ! bodies="$(gh api --paginate "repos/$REPO/issues/$n/comments" \
    --jq '.[].body' 2>/dev/null)"; then
    log "#$n: take-back comments unreadable — no comment invented this pass"
    return 0
  fi
  if grep -qF "$marker" <<<"$bodies"; then return 0; fi

  while IFS= read -r b; do
    [ -n "$b" ] || continue
    pretty="${pretty:+$pretty, }\`$b\`"
  done <<<"$standing"

  if run gh issue comment "$n" -R "$REPO" --body "$marker
\`state:needs-human\` was taken back on this PR — the state is
\`state:addressing\` again. That is not a machine error, and re-setting the
label will not stick: the label means a human could merge this **right now**,
so it requires a clear branch, and this head does not have one.

Standing at \`$HEAD_SHA\`: $pretty

The handoff's precondition is every panel verdict approving the current head
**and no \`blocker:*\` standing** — conflicts rebased, CI green, drill
recorded if this is a release PR
([BUILDER.md — Handoff](https://github.com/heavy-duty/ceremony/blob/main/BUILDER.md#handoff)).
Clear what is standing above and the next sweep derives \`state:needs-human\`
by itself; setting it by hand only earns another take-back
(heavy-duty/ceremony#377).

*One comment per episode: a new head, or a different blocker set, says this
again — the same head with the same blockers never does.*" >/dev/null; then
    log "#$n: handoff taken back ($joined at $HEAD_SHA) — commented"
  else
    # A failed post recorded no marker, so the next sweep retries the episode;
    # only this log line would have lied about it.
    log "#$n: WARNING: handoff taken back ($joined at $HEAD_SHA) — the comment failed to post; the next sweep retries"
  fi
}

reconcile_pr() { # $1 = PR number; relies on the globals set from its fetch
  local n="$1" desired remove s args last_activity last_activity_epoch age

  desired="$(decide_state)"

  # encode the runbook's last step for the no-judgment case: every required
  # verdict is a head-current approval → the human is asked, once. The guard
  # asks whether
  # a FRESH human review is needed for THIS head — never "has the human ever
  # reviewed", which wedged the handoff after any earlier human comment.
  # Idempotent (a live request suppresses it); race-free via the shared
  # concurrency group in labels.yml. With a comment-only bot on the panel
  # this path stays cold and the AUTHOR requests the human.
  if [ "$desired" = state:needs-human ] && human_request_needed; then
    run gh api "repos/$REPO/pulls/$n/requested_reviewers" -f "reviewers[]=$HUMAN" --silent
    log "#$n: requested $HUMAN (round passed)"
  fi

  # ---- converge both axes ----
  # state:* is exclusive (everything but $desired comes off); blocker:* is a
  # set (each one on or off on its own); RETIRED always comes off. One edit
  # call for all of it, so a PR never flickers through a half-applied board.
  local want_blockers add=""
  want_blockers="$(blockers)"

  remove=""
  for s in "${STATES[@]}"; do
    if [ "$s" != "$desired" ] && has_label "$s"; then remove="$remove,$s"; fi
  done
  for s in "${RETIRED[@]}"; do
    if has_label "$s"; then remove="$remove,$s"; fi
  done
  # `rerun-owed` is cleared and never written (#423) — the one hand-set label
  # this machine takes off, because its subject is a head and a head moves. It
  # rides the same edit as everything else on purpose: the clear and the
  # blocker:ci-red that returns with it are one transition, and splitting them
  # across two calls would show the board a head with neither for a moment.
  # NOT a BLOCKERS entry, which would be the reverse contract: that array is
  # machine-owned and re-derived every pass, so the converge loop would strip a
  # live evidenced label on the next tick — the trap #51 and #180 name for
  # `needs-ruling` and `blocked`.
  # An `if`, not a `&&` one-liner: this runs under `set -e`, where a trailing
  # false test is a failed command and takes the whole PR's subshell with it.
  if [ "$(rerun_owed_state)" = CLEARED ]; then remove="$remove,rerun-owed"; fi
  for s in "${BLOCKERS[@]}"; do
    if grep -qxF "$s" <<<"$want_blockers"; then
      has_label "$s" || add="$add,$s"
    else
      has_label "$s" && remove="$remove,$s"
    fi
  done
  add="${add#,}"
  remove="${remove#,}"

  # Never NAME a label the repo does not have. `gh issue edit --add-label`
  # rejects the WHOLE call on one unknown name — nothing is applied — so a
  # single missing blocker would take the state convergence down with it, on
  # exactly the PRs this change exists to fix, surfacing only as a log line.
  # Batching state and blockers into one edit for anti-flicker is what widened
  # that blast radius; filtering the add side is what closes it again.
  # Removals need no filter: they are built from has_label, so the label
  # provably exists. REPO_LABELS unreadable means no filtering rather than
  # filtering everything out — a failed read must not silently strip the board.
  local skip_edit=false
  if [ -n "${REPO_LABELS:-}" ]; then
    local kept="" missing="" want
    for want in ${add//,/ }; do
      if grep -qxF "$want" <<<"$REPO_LABELS"; then kept="$kept,$want"
      else missing="$missing $want"; fi
    done
    add="${kept#,}"
    # A missing STATE label skips only the EDIT — never the rest of this
    # function. Everything below is independent of the state:* taxonomy, and
    # returning here stranded it: `merge-next` kept claiming "merge this one
    # next" on a PR the board had moved to the agent, and the stale sweep
    # stopped running. That is the original false-invitation bug, reintroduced
    # in the very fix meant to survive a cold-start repo — and a regression
    # against the old behaviour, which failed the edit and fell through.
    if ! grep -qxF "$desired" <<<"$REPO_LABELS"; then
      log "#$n: WARNING: state label '$desired' does not exist — skipping the label edit; dispatch the workflow to bootstrap"
      skip_edit=true
    elif [ -n "$missing" ]; then
      log "#$n: WARNING: missing label(s)$missing — state still converged; dispatch the workflow to bootstrap"
    fi
  fi

  # Whether THIS pass took a hand-set handoff back — the fact #377's comment
  # speaks for, and knowable only here: it needs the edit to have run, to have
  # succeeded, and to have carried `state:needs-human` on its removal side.
  # "The edit returned 0" is not the same claim and would still be true on a
  # pass that removed something else entirely.
  local handoff_cleared=false
  if [ "$skip_edit" = false ] && { ! has_label "$desired" || [ -n "$remove" ] || [ -n "$add" ]; }; then
    args=(--add-label "$desired${add:+,$add}")
    [ -n "$remove" ] && args+=(--remove-label "$remove")
    if run gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null; then
      log "#$n: state -> $desired${add:+ +$add}${remove:+ (cleared $remove)}"
      case ",$remove," in *,state:needs-human,*) handoff_cleared=true ;; esac
    else
      # a deleted label must not wedge the sweep — dispatch heals the taxonomy
      log "#$n: WARNING: label edit failed (missing label? run the workflow manually to bootstrap)"
    fi
  fi

  # ---- the release-shape guard (#130): a warning, never a write --------
  # Drafts are exempt (the build phase is the builder's); the version
  # reads cost two API calls and only on PRs missing the label.
  if [ "$DRAFT" != true ] && ! has_label release; then
    release_shape_warning "$n" "$(tree_version "$HEAD_SHA")" "$(tree_version "$BASE_SHA")"
  fi

  # ---- merge-next: cleared, never set ----------------------------------
  # Queue order is INTENT — which PR should land first is a judgement about
  # conflicts and dependencies that GitHub knows nothing about, so the
  # reconciler must not guess it (LABELS.md's rule for `blocked`/`release`).
  # What it CAN do is stop the label going stale the way needs-human did:
  # the moment the PR is no longer the thing a human should merge next, the
  # claim is removed. Setting it stays with whoever owns the queue.
  if has_label merge-next && [ "$desired" != state:needs-human ]; then
    run gh issue edit "$n" -R "$REPO" --remove-label merge-next >/dev/null
    log "#$n: cleared merge-next (state is $desired, not mergeable-by-a-human)"
  fi

  # ---- stale: real activity only, and blocked is legitimately quiet ----
  last_activity="$(
    {
      jq -r '.created_at' <<<"$PR_JSON"
      jq -r '.[].submitted_at' <<<"$REVIEWS_JSON"
      gh api --paginate "repos/$REPO/issues/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/commits" --jq '.[].commit.committer.date'
    } | sort | tail -n1
  )"
  last_activity_epoch="$(date -d "$last_activity" +%s)"
  age=$((NOW - last_activity_epoch))
  # needs-ruling joins blocked here: waiting on a human is legitimately quiet
  # (#50 D10). The 7-day nudge is #52's, once for both surfaces.
  if has_label blocked || has_label needs-ruling || [ "$age" -le "$STALE_AFTER" ]; then
    if has_label stale; then
      run gh issue edit "$n" -R "$REPO" --remove-label stale >/dev/null
      log "#$n: unstale"
    fi
  elif ! has_label stale; then
    run gh issue edit "$n" -R "$REPO" --add-label stale >/dev/null
    log "#$n: stale ($((age / 3600))h quiet)"
  fi

  # ---- say why a handoff was taken back (#377) -------------------------
  # Two constraints put it exactly here. After the converge edit, never inside
  # it: state and blockers ride ONE edit call so the board never half-applies,
  # and a comment between them would split exactly that. And after the
  # `last_activity` read, where reconcile_ruling's comments already sit: a
  # machine comment must not count as the PR's own activity in the pass that
  # posts it, or the sweep reads its own noise as a sign of life and holds
  # `stale` off. Bounded by the per-episode guard either way, but the sweep
  # should not have to be saved by a guard from believing itself.
  reconcile_handoff_takeback "$n" "$handoff_cleared"

  # ---- the ruling invariants (#52): the bare-flag check + the 7-day nudge --
  # The stale EXEMPTION above is #51's; these are the sweep halves that ride
  # the same real-activity computation (lib/ruling.sh, shared with the issue
  # side). Behind the flag check so flag-free PRs — all of them, almost
  # always — cost no extra API reads.
  if has_label needs-ruling; then
    reconcile_ruling "$n" "$last_activity_epoch" "$NOW"
  fi

  # `attention` belongs on the assigned issue that owns the claim, never on
  # a pull request (#232). Behind the label gate so ordinary PRs pay no read.
  if has_label attention; then
    reconcile_attention "$n" pr "$(jq '.assignees | length' <<<"$PR_JSON")" ""
  fi
}

main() {
  REPO="${REPO:?set REPO to owner/name}"
  LABELS_CONF="${LABELS_CONF:-.github/labels.conf}"
  load_config "$LABELS_CONF"
  NOW="$(date +%s)"

  if [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]; then
    log "workflow_dispatch: bootstrapping the taxonomy"
    bootstrap_labels
  fi

  # The repo's label set, read ONCE per sweep — reconcile_pr filters every
  # add against it, because one unknown name fails the whole edit call.
  REPO_LABELS="$(gh label list -R "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null || echo "")"
  [ -z "$REPO_LABELS" ] && log "WARNING: could not read the label set — applying labels unfiltered"
  missing_core_labels_warning "$(core_label_rows)" "$REPO_LABELS"

  local n output status total=0 unreadable=0 sampled_reason="" read_failures
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    status=0
    output="$(
      (
      PR_JSON="$(gh api "repos/$REPO/pulls/$n")"
      DRAFT="$(jq -r '.draft' <<<"$PR_JSON")"
      AUTHOR="$(jq -r '.user.login' <<<"$PR_JSON")"
      set_required_bots "$AUTHOR"
      HEAD_SHA="$(jq -r '.head.sha' <<<"$PR_JSON")"
      BASE_SHA="$(jq -r '.base.sha' <<<"$PR_JSON")"
      LABELS="$(jq -r '.labels[].name' <<<"$PR_JSON")"
      REQUESTED="$(jq -r '.requested_reviewers[].login' <<<"$PR_JSON")"
      # PENDING reviews are unsubmitted drafts in someone's browser — not a verdict
      REVIEWS_JSON="$(gh api --paginate "repos/$REPO/pulls/$n/reviews" --jq '.[]' \
        | jq -s '[.[] | select(.state != "PENDING")]')"
      # mergeability + the check rollup, the two facts the state machine was
      # blind to (#136). `gh pr view` rather than the REST PR object: the API's
      # `mergeable` is a tri-state boolean that GitHub computes lazily, while
      # this returns the same MERGEABLE/CONFLICTING/UNKNOWN string the UI shows.
      # Failure to read them is NOT fatal and NOT treated as broken — an API
      # hiccup must never flap every PR into needs-rebase, so both degrade to
      # the "do not know" value that triggers nothing.
      # The WHY goes to gh's stderr, and 2>/dev/null threw it away — a
      # permanent denial and a network hiccup left byte-identical evidence,
      # and #95 had to infer a cause from a control case instead of reading
      # it off a run (wrongly, it turned out). Captured into a file (#101
      # D2), never left to interleave raw into the per-PR output block,
      # where an unlucky line could collide with a matched string.
      GH_VIEW_ERR_FILE="$(mktemp)"
      GH_VIEW="$(gh pr view "$n" -R "$REPO" --json mergeable,statusCheckRollup 2>"$GH_VIEW_ERR_FILE" || echo '{}')"
      GH_VIEW_ERR="$(cat "$GH_VIEW_ERR_FILE")"
      rm -f "$GH_VIEW_ERR_FILE"
      MERGEABLE="$(jq -r '.mergeable // "UNKNOWN"' <<<"$GH_VIEW")"
      CHECKS="$(checks_state <<<"$GH_VIEW")"
      # Read failed: leave this PR exactly as it is. Recomputing on facts we
      # did not read is how an API hiccup turns into a false "merge me" —
      # and the next tick is 15 minutes away, not 15 hours.
      if [ "$CHECKS" = UNREADABLE ]; then
        # Two lines on purpose (#101 D1): the sweep detects a wholly blind
        # pass by whole-line-matching the counted line below, so the reason
        # rides its OWN line — folding it in would silently break the
        # `unreadable` counter and the wholly-blind warning #96 landed.
        log "#$n: could not read mergeability/checks — left alone this pass"
        log "#$n: read failed: $(read_failure_reason "$GH_VIEW_ERR")"
        exit 0
      fi
      # The head's own clock, for the blocker:unrequested grace (#236 D2). One
      # read, pinned to the head SHA — not `gh pr view --json commits`, which
      # asks for the FIRST hundred commits and would date a longer PR by a
      # commit that is not its head. Last of the fetches on purpose: a PR the
      # skip above walked away from must not pay for it, and neither do drafts,
      # which never reach that blocker. Empty (a failed read, or a body without
      # the field) leaves the blocker unjudged, by unrequested_quiescent.
      HEAD_COMMIT_AT=""
      if [ "$DRAFT" != true ]; then
        HEAD_COMMIT_ERR_FILE="$(mktemp)"
        HEAD_COMMIT_AT="$(gh api "repos/$REPO/commits/$HEAD_SHA" \
          --jq '.commit.committer.date' 2>"$HEAD_COMMIT_ERR_FILE" || echo "")"
        HEAD_COMMIT_ERR="$(cat "$HEAD_COMMIT_ERR_FILE")"
        rm -f "$HEAD_COMMIT_ERR_FILE"
        case "$HEAD_COMMIT_AT" in
          "" | null)
            # Say why it degraded (#101 D2/D4), on its own line: this one
            # narrows a blocker rather than skipping the PR, so it must not
            # read as the wholly-blind shape the counted line above matches.
            HEAD_COMMIT_AT=""
            log "#$n: could not read the head commit's date: $(read_failure_reason "$HEAD_COMMIT_ERR") — blocker:unrequested not judged this pass" ;;
        esac
      fi
      # The head `rerun-owed`'s evidence names (#423). Behind the label, so an
      # ordinary PR pays nothing for it, and behind the AUTHOR too: the label is
      # the builder's to set with its evidence, so a marker quoted back by a
      # reviewer is a quotation and not a second flag. Read whole, then filtered
      # — the shape lib/attention.sh uses — so an unreadable list and a label
      # nobody evidenced are told apart by the read's own status and not by
      # whether a pipeline happened to be running under `pipefail`.
      RERUN_OWED_HEAD=""
      if has_label rerun-owed; then
        if ! RERUN_OWED_EVIDENCE="$(RERUN_OWED_AUTHOR="$AUTHOR" gh api --paginate \
          "repos/$REPO/issues/$n/comments" \
          --jq '.[] | select(.user.login == env.RERUN_OWED_AUTHOR)
                | .body | split("\n")[0] | sub("\r$"; "")' 2>/dev/null)"; then
          log "#$n: rerun-owed evidence unreadable — its moved-head test not judged this pass"
        else
          RERUN_OWED_HEAD="$(rerun_owed_named_head <<<"$RERUN_OWED_EVIDENCE")"
          # Told apart from the failed read on purpose: a label whose evidence
          # names no head is a builder to talk to, a list that would not read is
          # an API to look at. Both leave the label standing.
          [ -n "$RERUN_OWED_HEAD" ] ||
            log "#$n: rerun-owed evidence names no head — its moved-head test not judged this pass"
        fi
      fi
      reconcile_pr "$n"
      ) 2>&1
    )" || status=$?
    [ -n "$output" ] && printf '%s\n' "$output"
    if grep -qxF "labels: #$n: could not read mergeability/checks — left alone this pass" <<<"$output"; then
      unreadable=$((unreadable + 1))
      # the first observed reason stands in for the sweep in the blind warning
      if [ -z "$sampled_reason" ]; then
        # No second pipe, and NOT because this site can race today (#411
        # D10): what a second pipe into `head -n1` would carry here is not
        # $output but sed's matched subset, bounded twice over — exactly
        # one `read failed:` emitter exists per PR (:1138, whose branch
        # `exit 0`s on the next line), and read_failure_reason collapses
        # newlines and truncates at 300 characters. ~300 bytes fills no
        # pipe of any capacity, so `head -n1` would never take EPIPE and
        # `pipefail` would never kill the substitution.
        # It is converted anyway, for D2's reason: "bounded" is a property
        # of today's callers that no future reader of this line can check,
        # and the collision hazard named at :1121 — an unlucky raw stderr
        # line matching the counted prefix — is precisely the future in
        # which this writer stops being bounded. sed's writer is a command
        # and takes no herestring, so capture it whole and cut the first
        # line in the shell (#364, #411 D1's instruction, D10's grading).
        read_failures="$(sed -n "s/^labels: #$n: read failed: //p" <<<"$output")"
        sampled_reason="${read_failures%%$'\n'*}"
      fi
    elif [ "$status" -ne 0 ]; then
      log "#$n: reconcile failed — continuing with the remaining PRs"
    fi
  done < <(gh pr list -R "$REPO" --state open --limit 100 --json number --jq '.[].number')
  blind_sweep_warning "$unreadable" "$total" "$sampled_reason"
  log "reconciled."
}

# sourced by test/labels-reconcile.sh for the fixture tests; executed in CI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
