#!/usr/bin/env bash
# lib/ruling.sh — the `needs-ruling` sweep invariants (issues #52 and #73,
# epic #50).
#
# Both reconcilers source this file: the bare-flag check, the escalation
# shape check, the ladder's rung comments and the 7-day nudge are ONE
# implementation serving both surfaces — two copies of a 7-day rule is how
# the family got here in the first place (#50). Pure decisions sit above
# the divider (facts in, verdict out); the one impure orchestrator below
# talks to gh and posts through the sourcing script's run()/log().
#
# Standing rules this file lives under:
#   - The machine never sets or clears `needs-ruling` (#50 D9). Nothing here
#     mutates a label; the only writes are comments. Pinned by a sweep-probe
#     test and a grep-level check over the mutation calls.
#   - The machine never judges prose (#50 D4). "Did the escalation contract
#     accompany the flag" is decided by a mechanical proxy: the actor who
#     applied the label has a comment timestamped no earlier than 15 minutes
#     before the `labeled` event. The back-window exists because the natural
#     ordering is post-the-escalation-then-set-the-label, seconds apart; a
#     strictly-after rule would flag every correctly-formed escalation.
#   - The 7-day nudge carries NO idempotency marker, and a build that gives
#     it one is a regression, not a tidy-up (#50 D10). It self-rate-limits
#     because its own comment is activity on the clock it reads. That now
#     rests on a second fact as well: the clock stops counting the
#     flag-setter's comments (#534 D1), and the property holds only because the
#     setter can never be the identity the sweep posts as — neither
#     reconciler writes this label, every mention of it in both files being a
#     read, and LABELS.md carries the same rule as doctrine. The two
#     identities cannot collide by configuration either, which is the stronger
#     half of the same argument: every reconcile step in
#     .github/workflows/labels-sweep.yml runs under
#     `GH_TOKEN: ${{ github.token }}`, so the sweep posts as
#     `github-actions[bot]`, while this label is applied by a builder or a
#     human. The code-level grep bounds what this repo's files do; that line
#     bounds who the poster is. Exempting a
#     machine comment instead would mean exempting the nudge itself, which is
#     the per-pass repeat the missing marker exists to prevent (#534 D3, D8).
#   - The failure direction is always *flag*, never *act*: a bare flag is
#     commented on, never removed (removing would delete somebody's
#     escalation on the strength of a timestamp heuristic), and an
#     unreadable timeline does nothing at all — an unreadable fact must
#     never invent a verdict (the reconciler's standing rule).

# One constant, both surfaces — the whole reason this file exists. 7 days
# (#50 D10): long enough that an active back-and-forth is never nudged,
# short enough that a forgotten ruling surfaces within the week.
RULING_NUDGE_AFTER=$((7 * 24 * 3600))
# The escalation back-window: a comment this many seconds before the
# `labeled` event still accompanies it.
RULING_BARE_WINDOW=$((15 * 60))
# The ladder's rungs (#50 D13, via #72's doctrine): moments past the current
# episode's `labeled` event. Two timers only — the 24h rung's comment names
# triage's past-24h authority too, so there is no third timer to keep honest.
RULING_RUNG12_AT=$((12 * 3600))
RULING_RUNG24_AT=$((24 * 3600))
# The escalation contract's four field labels (#50 D12). Literal strings —
# the template in BUILDER.md ("the ruling ask") fixes them so this machinery
# can check for them; presence is all that is ever checked (#50 D4).
RULING_SHAPE_FIELDS=(Options: Recommend: Blocked: Default:)
# The idempotency markers, one per comment kind, each scoped to the current
# `labeled` episode by ruling_bare_comment_needed. The nudge deliberately
# has NO marker — see ruling_nudge_decision.
RULING_BARE_MARKER='<!-- ceremony:needs-ruling-bare -->'
RULING_SHAPE_MARKER='<!-- ceremony:needs-ruling-shape -->'
RULING_RUNG12_MARKER='<!-- ceremony:needs-ruling-rung12 -->'
RULING_RUNG24_MARKER='<!-- ceremony:needs-ruling-rung24 -->'

# ---------------------------------------------------------------------------
# Pure decisions. Facts in (args/stdin), verdict out. No gh, no clock.
# ---------------------------------------------------------------------------

ruling_stale_exempt() { # labels on stdin → EXEMPT | SWEEP
  # Waiting on a human is legitimately quiet (#50 D10): under a pending
  # ruling the staleness clock does not run, the same treatment `blocked`
  # gets. The PR-side skip is #51's and lives in labels-reconcile.sh; this
  # verdict drives the ISSUE side (the claim-reclaim clock), so the rule has
  # one spelling even though the two surfaces consult it in different places.
  if grep -qxF needs-ruling; then echo EXEMPT; else echo SWEEP; fi
}

ruling_accompanies() { # $1 comment epoch, $2 labeled epoch → 0 iff in-window
  # One spelling of the window rule, shared by the bare verdict and the
  # escalation-comment lookup the nudge links — two comparisons drifting
  # apart would let the nudge link a comment the bare check rejected.
  [ "$1" -ge "$(($2 - RULING_BARE_WINDOW))" ]
}

ruling_bare_decision() { # $1 setter, $2 labeled epoch; "login epoch" lines on stdin
  # → ACCOMPANIED | BARE. Only the flag-setter's own comments count: the
  # escalation contract (question, options, recommendation — #50 D4) is the
  # flag-setter's to post, and somebody else's chatter must not satisfy it.
  local setter="$1" labeled="$2" login epoch
  while read -r login epoch; do
    [ -n "$login" ] || continue
    [ "$login" = "$setter" ] || continue
    if ruling_accompanies "$epoch" "$labeled"; then
      echo ACCOMPANIED
      return 0
    fi
  done
  echo BARE
}

ruling_bare_comment_needed() { # $1 labeled epoch, $2 newest marked-comment epoch ("" = none)
  # → POST | SKIP. Scoped to the CURRENT labeled event: a marked comment
  # older than the event belongs to an earlier flag episode, so a genuine
  # re-flag is re-checked while a 15-minute cron never repeats itself.
  # Marker-agnostic — the caller tracks a newest epoch PER marker (#73), so
  # this one comparison scopes every marked write (bare, shape, both rungs).
  local labeled="$1" marked="${2:-}"
  if [ -n "$marked" ] && [ "$marked" -gt "$labeled" ]; then
    echo SKIP
  else
    echo POST
  fi
}

ruling_shape_field_present() { # $1 field label; escalation body on stdin → 0 iff present
  # THE one spelling of the field-presence test — the escalation selector
  # scores by it and the shape check grades by it, on purpose in one place:
  # a selector scoring by one grep while the check grades by another is how
  # the crew#293 misgrade would come back from the other side (#226).
  # Line-anchored, allowing leading whitespace and Markdown bold
  # (`**Options:**` is how the live escalations write them): the labels
  # appearing only mid-sentence is not the template.
  local field="$1"
  grep -Eq "^[[:space:]]*(\*\*)?$field"
}

ruling_shape_score() { # escalation body on stdin → 0–4, one point per field present
  # The selection rule's metric (#226). An empty body scores 0 through the
  # same loop — no special case, and never an error.
  local body field score=0
  body="$(cat)"
  for field in "${RULING_SHAPE_FIELDS[@]}"; do
    if ruling_shape_field_present "$field" <<<"$body"; then score=$((score + 1)); fi
  done
  echo "$score"
}

ruling_shape_decision() { # escalation body on stdin → SHAPED | MALFORMED <missing labels>
  # Presence only (#50 D4): that `Recommend:` exists is checkable, that the
  # recommendation is any good is not — no counting options, no parsing the
  # prose. The per-field test is ruling_shape_field_present, shared with the
  # selector (#226). The `🧭 needs-ruling` header line is deliberately
  # unchecked — it is prose, and an emoji grep on an LC_ALL=C runner is a
  # portability trap for zero enforcement value.
  local body field missing=""
  body="$(cat)"
  for field in "${RULING_SHAPE_FIELDS[@]}"; do
    ruling_shape_field_present "$field" <<<"$body" || missing="$missing $field"
  done
  if [ -z "$missing" ]; then echo SHAPED; else echo "MALFORMED$missing"; fi
}

ruling_deadline_decision() { # $1 now, $2 the current episode's labeled epoch → RUNG0 | RUNG12 | RUNG24
  # The ladder anchors to the `labeled` event, never to activity (#50 D14:
  # an active back-and-forth still climbs it; only the separate 7-day nudge
  # resets). "At 12h" means AT: the boundary starts the rung — the rung is a
  # moment whose duty exists the moment it strikes, unlike the strictly-past
  # nudge horizon. RUNG24 covers "past 24h" too: the 24h comment names both
  # the builder's rung and triage's past-24h authority, so there is no
  # fourth timer to keep honest.
  local age=$(($1 - $2))
  if [ "$age" -ge "$RULING_RUNG24_AT" ]; then
    echo RUNG24
  elif [ "$age" -ge "$RULING_RUNG12_AT" ]; then
    echo RUNG12
  else
    echo RUNG0
  fi
}

ruling_default_decision() { # escalation body on stdin → DEADLINE <ts> | HARDBLOCK | UNPARSEABLE
  # Parsed only to *describe* the item in the rung comments, never to gate a
  # rung (#50 D14: the rungs apply whatever `Default:` says). Mechanical or
  # nothing: an ISO-8601 UTC timestamp anywhere on the `Default:` line is
  # the deadline, the literal word `none` is a hard block, anything else is
  # reported as unparseable rather than guessed at. Only the `Default:` line
  # is read — a timestamp elsewhere in the body is somebody's prose.
  local line ts
  line="$(grep -E '^[[:space:]]*(\*\*)?Default:' | head -n1)"
  ts="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z' <<<"$line" | head -n1)"
  if [ -n "$ts" ]; then
    echo "DEADLINE $ts"
  elif grep -qE '(^|[^[:alnum:]])none([^[:alnum:]]|$)' <<<"$line"; then
    echo HARDBLOCK
  else
    echo UNPARSEABLE
  fi
}

ruling_rung24_body() { # $1 surface, $2 parsed default, $3 description, $4 setter
  # The surface and parsed default select doctrine; the description and setter
  # are interpolation only. Keeping the whole comment pure lets the fixture
  # pin the unchanged PR body without driving gh (#537 D1–D4).
  [ "$#" -eq 4 ] || {
    echo "ruling_rung24_body: surface, parsed default, description and setter are required" >&2
    return 2
  }
  local surface="$1" state="$2" described="$3" setter="$4"
  case "$surface" in issue|pr) ;; *)
    echo "ruling_rung24_body: surface must be issue or pr, got: $surface" >&2
    return 2 ;;
  esac

  if [ "$surface" = issue ] \
    && { [ "$state" = HARDBLOCK ] || [ "$state" = UNPARSEABLE ]; }; then
    cat <<EOF
$RULING_RUNG24_MARKER
@$setter — this ruling is 24 hours past its \`labeled\` event: the ladder's
24h rung ([BUILDER.md — the ruling ask](https://github.com/heavy-duty/ceremony/blob/main/BUILDER.md#the-ruling-ask),
heavy-duty/ceremony#50 D13). Mechanically read, the escalation carries
$described.

The ladder's late rungs do not fire on this issue-borne flag
([heavy-duty/ceremony#526](https://github.com/heavy-duty/ceremony/issues/526)):
the flag waits for the human. At this moment the flag-setter, @$setter, owes
a published re-read of the default against what has landed and of any doubt
that still stands. The remaining machine event is the decider's 7-day nudge.
The rungs run on the \`labeled\` clock and do not reset on activity; this
comment fires once per flag episode.
EOF
  else
    cat <<EOF
$RULING_RUNG24_MARKER
@$setter — this ruling is 24 hours past its \`labeled\` event: the ladder's
24h rung ([BUILDER.md — the ruling ask](https://github.com/heavy-duty/ceremony/blob/main/BUILDER.md#the-ruling-ask),
heavy-duty/ceremony#50 D13). Mechanically read, the escalation carries
$described.

At 24h the builder proceeds regardless, **as a PR**: pick an option and
state in the PR body which way you went and what doubt remains. Nothing
merges by this — the human still gates the merge. Past 24h the choice is
triage's to make: triage picks the option, records it as a decision, and
remains accountable; the operator may overturn it at merge. The rungs run on
the \`labeled\` clock and do not reset on activity; this comment fires once
per flag episode and covers everything past 24h — there is no further
timer.
EOF
  fi
}

ruling_nudge_decision() { # $1 now, $2 last real-activity epoch → NUDGE | KEEP
  # Real activity only, as the caller's surface defines it: the PR sweep
  # supplies comments, reviews and commits; the issue sweeps supply comments
  # alone — an `assigned` event is the claim clock's fact, and counting it
  # let a claim silence a pending ruling (#284). Never label churn, or the
  # sweep would reset its own clock. Neither surface counts the flag-setter's
  # own comments, and both floor the clock at the current `labeled` event —
  # that is ruling_clock_at below, and it is why this decision's epoch is the
  # caller's to compute (#534 D1, D2, D4). The nudge needs NO marker: the
  # nudge comment is itself activity, so posting it resets this window and
  # the rule self-rate-limits to at most one nudge per 7 quiet days. That is
  # deliberate — a later refactor that "fixes" it by adding a marker breaks
  # exactly the property that makes it safe on a 15-minute cron.
  if [ "$(($1 - $2))" -gt "$RULING_NUDGE_AFTER" ]; then echo NUDGE; else echo KEEP; fi
}

ruling_clock_at() { # $1 setter, $2 the episode's labeled ISO;
                    # "login<TAB>iso8601" rows on stdin → the clock's ISO
  # THE one spelling of the ruling nudge's clock, both surfaces (#534 D1, D2,
  # D4). Two rules, and the second exists only because of the first:
  #
  #   - A comment by the flag-setter of the CURRENT episode is not activity.
  #     Under #526 the setter OWES a published re-read at the 24h and past-24h
  #     rungs, so the party owing the re-read was silencing the clock that
  #     pages the party owing the decision — by design, not by accident.
  #     crew#207 carried the flag 7d 1h on one episode with twelve
  #     hand-published re-reads and no nudge, and was closed undecided.
  #   - The clock floors at that `labeled` event. With the setter's escalation
  #     dropped, and on most flagged items that is the only comment, a clock
  #     falling back to the item's `created_at` would read an issue opened
  #     months ago as quiet for months and nudge on the first pass after the
  #     flag went up, reporting a `days` count predating the ruling. Before
  #     the labeled event no ruling was pending, so there is nothing to
  #     measure there. This also repairs that misreport in the shipped nudge.
  #
  # Keyed to the episode's identity and never to a role, a login list or a
  # config knob: a re-flag by a different actor changes who is excluded, from
  # that event onward, because ruling_newest_flag re-derives the setter.
  #
  # A row with an EMPTY login always counts — that is how the PR surface feeds
  # reviews and commits through unfiltered (#534 D5): the exclusion is
  # comment-shaped, and a setter who pushes a commit has done something
  # anybody would call real activity. An empty setter drops nothing, because
  # an unreadable actor must never widen the exclusion to the whole board.
  #
  # ISO-8601 UTC sorts lexically, so no date parsing happens here — the caller
  # converts the one answer, exactly as issue_activity_at does.
  local setter="$1" labeled="$2"
  {
    printf '%s\n' "$labeled"
    awk -F'\t' -v s="$setter" \
      'NF && $2 != "" && !(s != "" && $1 == s) { print $2 }'
  } | sort | tail -n1
}

ruling_newest_flag() { # "login<TAB>iso8601" lines on stdin → the newest line
  # A re-flag after a removal is judged on its own escalation, never on the
  # last one's — so every fact anchors to the MOST RECENT labeled event.
  # ISO-8601 UTC sorts lexically, so no date parsing is needed here.
  sort -t $'\t' -k2 | tail -n1
}

ruling_escalation_row() { # $1 setter, $2 labeled epoch; "login epoch url [b64]" lines on stdin
  # → "url b64" of the BEST-SHAPED in-window comment by the setter, or
  # nothing: highest ruling_shape_score wins, equal scores break to the
  # earliest epoch. Earliest-wins outright was the rule until crew#293
  # (2026-08-02): a builder answered its round whole and escalated 33
  # seconds later — both in one window, the reply earlier — and the sweep
  # graded the round reply, told a correct escalation it was malformed, and
  # the setter re-posted a shape it had already met. Score resolves both
  # orderings; the earliest tiebreak keeps escalation-then-follow-ups
  # wherever the scores cannot tell candidates apart, including all-zero.
  # An undecodable or absent body scores 0 and stays a legal candidate —
  # an unreadable fact never invents a verdict, and never errors the sweep.
  # The window and the setter gate candidacy before any score is taken.
  local setter="$1" labeled="$2" login epoch url b64 body score
  local best_score=-1 best_epoch="" best=""
  while read -r login epoch url b64; do
    [ -n "$login" ] || continue
    [ "$login" = "$setter" ] || continue
    ruling_accompanies "$epoch" "$labeled" || continue
    if body="$(base64 -d <<<"${b64:-}" 2>/dev/null)"; then
      score="$(ruling_shape_score <<<"$body")"
    else
      score=0
    fi
    if [ "$score" -gt "$best_score" ] \
      || { [ "$score" -eq "$best_score" ] && [ "$epoch" -lt "$best_epoch" ]; }; then
      best_score="$score"
      best_epoch="$epoch"
      best="$url ${b64:-}"
    fi
  done
  [ -z "$best" ] || printf '%s\n' "$best"
}

ruling_escalation_url() { # same contract, url column only — the nudge's link
  local row
  row="$(ruling_escalation_row "$@")"
  [ -z "$row" ] || printf '%s\n' "${row%% *}"
}

# ---------------------------------------------------------------------------
# The impure orchestrator: fetch the facts, call the decisions, post through
# the caller's run(). Called by both reconcilers for every open item that
# carries the flag. Needs REPO; uses the caller's run() and log().
# ---------------------------------------------------------------------------

ruling_flag_row() { # $1 item number → "setter<TAB>labeled_at"
  # The current episode's two facts, read from the `labeled` events. Exit 1
  # is an unreadable timeline, exit 2 a readable one with no visible event
  # (a hiccup, or an import) — distinguished because the sweep says which,
  # and identical in consequence: an unreadable fact never invents a verdict.
  #
  # One spelling, three readers (#534 D4). reconcile_ruling needs it to
  # address its comments; both callers need it BEFORE the pass posts
  # anything, to floor the ruling clock and name whose comments do not count.
  # Those callers pay one timeline read on flagged items only — the same read
  # this function makes below, on the handful of items carrying the flag.
  local flags
  flags="$(gh api --paginate "repos/$REPO/issues/$1/timeline" \
    --jq '.[] | select(.event == "labeled" and .label.name == "needs-ruling")
          | [.actor.login, .created_at] | @tsv' 2>/dev/null)" || return 1
  [ -n "$flags" ] || return 2
  ruling_newest_flag <<<"$flags"
}

reconcile_ruling() { # $1 item number, $2 last real-activity epoch, $3 now, $4 issue | pr
  if [ "$#" -ne 4 ]; then
    echo "reconcile_ruling: item, activity epoch, now and surface are required" >&2
    return 2
  fi
  local n="$1" last_activity="$2" now="$3" surface="$4"
  case "$surface" in issue|pr) ;; *)
    echo "reconcile_ruling: surface must be issue or pr, got: $surface" >&2
    return 2 ;;
  esac
  : "${REPO:?reconcile_ruling: REPO is required}"

  # The newest `labeled` event for the flag: actor + timestamp. A failed read
  # skips BOTH checks — the nudge's specified content links the escalation
  # comment, which only these facts identify, and half-verdicts on half-read
  # facts is the exact shape the reconciler's standing rule forbids.
  local newest rc=0 setter labeled_at labeled_epoch
  newest="$(ruling_flag_row "$n")" || rc=$?
  if [ "$rc" = 1 ]; then
    log "#$n: ruling timeline unreadable — no verdict invented this pass"
    return 0
  fi
  if [ "$rc" != 0 ]; then
    # The label is on the item but no labeled event is visible (a timeline
    # hiccup, or an import). Same treatment as unreadable: do nothing.
    log "#$n: ruling flag has no visible labeled event — no verdict invented this pass"
    return 0
  fi
  setter="${newest%%$'\t'*}"
  labeled_at="${newest##*$'\t'}"
  labeled_epoch="$(date -d "$labeled_at" +%s)"

  # The body travels as jq's @base64 — bodies carry newlines and tabs, and
  # the whole file is line-oriented, so the row format stays TSV and the
  # body is decoded at its points of use (#73). Do not switch rows to JSON.
  local comments
  if ! comments="$(gh api --paginate "repos/$REPO/issues/$n/comments" \
    --jq '.[] | [.user.login, .created_at, .html_url,
          ((.body // "") | @base64)] | @tsv' 2>/dev/null)"; then
    log "#$n: ruling comments unreadable — no verdict invented this pass"
    return 0
  fi

  # One pass over the comments builds every fact the decisions consume: who
  # commented when (for the bare verdict), the newest marked comment PER
  # MARKER (each write is idempotent per episode — one pass, not one pass
  # per marker), and the "login epoch url b64" rows the escalation lookup
  # reads. A body that fails to decode counts as unmarked — for idempotency
  # that risks a repeat, never an invented verdict.
  local login at url b64 body epoch authored="" rows=""
  local marked_bare="" marked_shape="" marked_rung12="" marked_rung24=""
  while IFS=$'\t' read -r login at url b64; do
    [ -n "$login" ] || continue
    epoch="$(date -d "$at" +%s)"
    authored="$authored$login $epoch"$'\n'
    rows="$rows$login $epoch $url ${b64:-}"$'\n'
    body="$(base64 -d <<<"${b64:-}" 2>/dev/null)" || body=""
    case "$body" in *"$RULING_BARE_MARKER"*)
      if [ -z "$marked_bare" ] || [ "$epoch" -gt "$marked_bare" ]; then marked_bare="$epoch"; fi ;;
    esac
    case "$body" in *"$RULING_SHAPE_MARKER"*)
      if [ -z "$marked_shape" ] || [ "$epoch" -gt "$marked_shape" ]; then marked_shape="$epoch"; fi ;;
    esac
    case "$body" in *"$RULING_RUNG12_MARKER"*)
      if [ -z "$marked_rung12" ] || [ "$epoch" -gt "$marked_rung12" ]; then marked_rung12="$epoch"; fi ;;
    esac
    case "$body" in *"$RULING_RUNG24_MARKER"*)
      if [ -z "$marked_rung24" ] || [ "$epoch" -gt "$marked_rung24" ]; then marked_rung24="$epoch"; fi ;;
    esac
  done <<<"$comments"

  # ---- the bare-flag check (#50 D4, mechanical proxy) ----
  if [ "$(ruling_bare_decision "$setter" "$labeled_epoch" <<<"$authored")" = BARE ]; then
    if [ "$(ruling_bare_comment_needed "$labeled_epoch" "$marked_bare")" = POST ]; then
      run gh issue comment "$n" -R "$REPO" --body "$RULING_BARE_MARKER
The ruling flag on this item was set by @$setter with no accompanying
escalation comment. Setting it requires the escalation contract — the
**question**, the **options**, and a **recommendation** — posted by the
flag-setter no more than 15 minutes before applying the label, or any time
after ([LABELS.md](https://github.com/heavy-duty/ceremony/blob/main/LABELS.md)
carries the flag-setter's obligations; heavy-duty/ceremony#50 D4). The label stays — this machine never removes an
escalation on the strength of a timestamp heuristic — but the contract is
still owed." >/dev/null
      log "#$n: ruling flag is bare — commented (the label is never removed)"
    fi
    # Bare stops here (#73): there is no shape to check when there is no
    # escalation comment, and a rung comment beside the bare comment would be
    # two comments about the same omission — noise. The 7-day nudge below is
    # deliberately untouched by this exclusion; it predates the ladder and
    # already words the bare case itself.
  else
    # ---- the shape check (#50 D12): the contract's four field labels ----
    local esc_row esc_url esc_body shape
    esc_row="$(ruling_escalation_row "$setter" "$labeled_epoch" <<<"$rows")"
    esc_url="${esc_row%% *}"
    if ! esc_body="$(base64 -d <<<"${esc_row#* }" 2>/dev/null)"; then
      # An undecodable body must not become "malformed" — an unreadable fact
      # never invents a verdict. The rungs read the same body, so they wait
      # for a readable pass too.
      log "#$n: escalation body unreadable — no verdict invented this pass"
    else
      shape="$(ruling_shape_decision <<<"$esc_body")"
      if [ "$shape" != SHAPED ] \
        && [ "$(ruling_bare_comment_needed "$labeled_epoch" "$marked_shape")" = POST ]; then
        local missing="${shape#MALFORMED }"
        run gh issue comment "$n" -R "$REPO" --body "$RULING_SHAPE_MARKER
@$setter — the [escalation comment]($esc_url) accompanying this ruling flag
is missing required field labels: **$missing**. The contract's shape is
fixed because this machinery checks for it (heavy-duty/ceremony#50 D12):
four line-anchored field labels — \`Options:\`, \`Recommend:\`, \`Blocked:\`,
\`Default:\` — per the canonical template in
[BUILDER.md — the ruling ask](https://github.com/heavy-duty/ceremony/blob/main/BUILDER.md#the-ruling-ask).
Presence is all that is checked; the machine never judges the prose
(heavy-duty/ceremony#50 D4). The label stays — the shape is owed, not
enforced." >/dev/null
        log "#$n: escalation malformed (missing:$missing) — commented (the shape is owed, not enforced)"
      fi

      # ---- the ladder's rungs (#50 D13–D14), observed never decided ----
      # Each rung's comment fires once per episode, AT its moment: a rung
      # whose moment passed unobserved (the sweep was down through 12h–24h)
      # is not paged after the fact — the later rung's comment carries the
      # whole remaining duty.
      local rung state described
      rung="$(ruling_deadline_decision "$now" "$labeled_epoch")"
      state="$(ruling_default_decision <<<"$esc_body")"
      case "$state" in
        DEADLINE\ *) described="a stated default deadline of \`${state#DEADLINE }\`" ;;
        HARDBLOCK)   described="\`Default: none\` — a hard block; no default ever fires" ;;
        *)           described="a missing or unparseable \`Default:\` line — reported as-is, never guessed at (and the contract's own rule is that unsure is a hard block)" ;;
      esac
      if [ "$rung" = RUNG12 ] \
        && [ "$(ruling_bare_comment_needed "$labeled_epoch" "$marked_rung12")" = POST ]; then
        run gh issue comment "$n" -R "$REPO" --body "$RULING_RUNG12_MARKER
@$setter — this ruling is 12 hours past its \`labeled\` event: the ladder's
12h rung ([BUILDER.md — the ruling ask](https://github.com/heavy-duty/ceremony/blob/main/BUILDER.md#the-ruling-ask),
heavy-duty/ceremony#50 D13). Mechanically read, the escalation carries
$described.

The rung's duty is the flag-setter's: re-read the \`Default:\` against
everything that has landed since the flag went up — does it still hold, and
has reasonable doubt appeared? A stale default does not fire, and new doubt
makes it a hard block. The rungs run on the \`labeled\` clock and do not
reset on activity; this comment fires once per flag episode." >/dev/null
        log "#$n: ruling at the 12h rung — commented (the setter re-reads the default)"
      fi
      if [ "$rung" = RUNG24 ] \
        && [ "$(ruling_bare_comment_needed "$labeled_epoch" "$marked_rung24")" = POST ]; then
        run gh issue comment "$n" -R "$REPO" \
          --body "$(ruling_rung24_body "$surface" "$state" "$described" "$setter")" >/dev/null
        if [ "$surface" = issue ] \
          && { [ "$state" = HARDBLOCK ] || [ "$state" = UNPARSEABLE ]; }; then
          log "#$n: ruling at the 24h rung — commented (late rungs do not fire; the setter re-reads)"
        else
          log "#$n: ruling at the 24h rung — commented (the builder proceeds as a PR; past 24h is triage's)"
        fi
      fi
    fi
  fi

  # ---- the 7-day nudge (#50 D10) ----
  if [ "$(ruling_nudge_decision "$now" "$last_activity")" = NUDGE ]; then
    # The decider is the repo's human reviewer — the same knob the PR
    # reconciler trusts for the merge gate, defaulted the same way. The
    # flag-setter is named but deliberately not tagged: address the decider,
    # never the whole thread's cast (#50 D10).
    #
    # `$last_activity` is the caller's ruling clock (ruling_clock_at, #534
    # D4), so `days` counts from the newest comment that is not the
    # setter's, and from the `labeled` event where there is none. It is
    # never a count of total silence on the thread, and the body says so.
    local decider="${HUMAN_REVIEWER:-danmt}" days esc_url esc_line
    days=$(((now - last_activity) / 86400))
    esc_url="$(ruling_escalation_url "$setter" "$labeled_epoch" <<<"$rows")"
    if [ -n "$esc_url" ]; then
      esc_line="The escalation is here: $esc_url"
    else
      esc_line="No escalation comment accompanies the flag — the contract (question, options, recommendation) is still owed by the flag-setter."
    fi
    run gh issue comment "$n" -R "$REPO" --body "@$decider — a ruling on this item has been pending with no activity for ${days} days. $esc_line

Per heavy-duty/ceremony#50 D6/D7 the flag-setter ($setter) owns closing this out: judge when agreement is reached, record the ruling as a decision in one comment, remove the label, and return the item to its flow in that same comment.

*The clock this counts does not read the flag-setter's own comments, and it runs from the \`labeled\` event rather than from the item's creation (heavy-duty/ceremony#534): the party owing a published re-read must not be able to silence the reminder addressed to the party owing the decision. Reviews and commits still count in full.*

*This nudge is comment-only and carries no idempotency marker on purpose: the comment itself is activity, so posting it resets the 7-day window and the rule self-rate-limits. Do not add a marker.*" >/dev/null
    log "#$n: ruling nudge (${days}d quiet — the decider owes an answer)"
  fi
}
