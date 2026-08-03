#!/usr/bin/env bash
# lib/attention.sh — the `attention` target invariants (#232, epic #229).
#
# Both reconcilers source this file. Pure decisions sit above the divider;
# the impure orchestrator below reads the current label episode and comments
# through the sourcing script's run()/log(). The machine diagnoses only: it
# never sets, clears, retargets or assigns anything on the strength of these
# checks (#229 D2).

ATTENTION_MARKER_PREFIX='<!-- ceremony:attention-malformed:'

# ---------------------------------------------------------------------------
# Pure decisions. Facts in, verdict out. No gh, no clock.
# ---------------------------------------------------------------------------

attention_target_decision() { # $1 pr|issue, $2 assignee count → MALFORMED_* | KEEP
  case "$1" in
    pr) echo MALFORMED_PR ;;
    issue)
      if [ "$2" -eq 0 ]; then echo MALFORMED_UNASSIGNED; else echo KEEP; fi ;;
    *) return 2 ;;
  esac
}

attention_comment_decision() { # $1 target verdict, $2 suppression → POST | SUPPRESS | KEEP
  case "$1" in
    KEEP) echo KEEP ;;
    MALFORMED_UNASSIGNED)
      if [ -n "$2" ]; then echo SUPPRESS; else echo POST; fi ;;
    MALFORMED_PR) echo POST ;;
    *) return 2 ;;
  esac
}

attention_newest_flag() { # labeled-event ISO-8601 timestamps on stdin → newest
  sort | tail -n1
}

attention_episode_marker() { # $1 current episode's labeled timestamp
  printf '%s%s -->\n' "$ATTENTION_MARKER_PREFIX" "$1"
}

# ---------------------------------------------------------------------------
# The impure orchestrator. Called only behind a has-attention gate.
# Needs REPO; uses the caller's run() and log().
# ---------------------------------------------------------------------------

reconcile_attention() { # $1 item, $2 pr|issue, $3 assignees, $4 suppression
  local n="$1" surface="$2" assignees="$3" suppression="${4:-}"
  local target comment labeled_events labeled_at marker comments body
  : "${REPO:?reconcile_attention: REPO is required}"

  target="$(attention_target_decision "$surface" "$assignees")"
  comment="$(attention_comment_decision "$target" "$suppression")"
  [ "$comment" != KEEP ] || return 0

  if [ "$comment" = SUPPRESS ]; then
    log "#$n: malformed attention detected; comment suppressed by $suppression precedence"
    return 0
  fi

  if ! labeled_events="$(gh api --paginate "repos/$REPO/issues/$n/timeline" \
    --jq '.[] | select(.event == "labeled" and .label.name == "attention")
          | .created_at' 2>/dev/null)"; then
    log "#$n: attention timeline unreadable — no verdict invented this pass"
    return 0
  fi
  if [ -z "$labeled_events" ]; then
    log "#$n: attention flag has no visible labeled event — no verdict invented this pass"
    return 0
  fi
  labeled_at="$(attention_newest_flag <<<"$labeled_events")"
  marker="$(attention_episode_marker "$labeled_at")"

  if ! comments="$(gh api --paginate "repos/$REPO/issues/$n/comments" \
    --jq '.[].body // ""' 2>/dev/null)"; then
    log "#$n: attention comments unreadable — no verdict invented this pass"
    return 0
  fi
  grep -qF "$marker" <<<"$comments" && return 0

  case "$target" in
    MALFORMED_PR)
      body="$marker
This pull request carries \`attention\`, but that label is issue-only. Put
the label on the assigned issue that owns the claim. The sweep cannot infer
which issue that is, so it reports the malformed target without removing or
retargeting the label (heavy-duty/ceremony#232)." ;;
    MALFORMED_UNASSIGNED)
      body="$marker
This issue carries \`attention\` but has no assignee to receive the demand.
Assign the intended builder or remove the flag. The sweep reports the board
bug without assigning anyone or changing the label (heavy-duty/ceremony#232)." ;;
  esac
  run gh issue comment "$n" -R "$REPO" --body "$body" >/dev/null
  log "#$n: malformed attention ($surface) — commented; no label or assignee changed"
}
