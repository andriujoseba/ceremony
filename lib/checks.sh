#!/usr/bin/env bash
# lib/checks.sh — the fleet's definition of red at a commit head (#440).
#
# One classifier, two readers. `labels-reconcile` decides `blocker:ci-red`
# with it, and `issueflow-reconcile` grades the head of a stalled blocker
# chain with it. Two callers means one home: the body below carries three
# repairs, each bought by an incident (#136's newest-entry collapse, #139's
# CANCELLED carve-out, #208's self-workflow exclusion), and a copy of it is
# how the fourth incident happens. It moved here unedited.
#
# GraphQL's `commit { statusCheckRollup { state } }` is a DIFFERENT
# classifier — one enum, with none of those three repairs — so a caller
# selects the rollup's contexts array and pipes it here. Selecting the enum
# instead is the cheap read that reintroduces every bug those numbers closed.
#
# SELF_WORKFLOW is the contract this file asks of its callers, and it is the
# caller's own name, not this file's: every sourcing script sets
# `SELF_WORKFLOW="${SELF_WORKFLOW:-${GITHUB_WORKFLOW:-}}"` for itself, so the
# exclusion below drops the runs of the workflow doing the grading and no
# other. It is deliberately not defaulted here — a lib defaulting it would
# make one sweep's ambient name silently filter another's rollup — and an
# empty value filters nothing, because outside Actions no workflow name is
# ambient and the exclusion must never drop entries on a guess (#208).

checks_state() { # rollup JSON on stdin → SUCCESS | FAILURE | PENDING | NONE | UNREADABLE
  # UNREADABLE is the absence of the key itself, which is what a failed fetch
  # leaves behind — distinct from a present-but-empty rollup, which honestly
  # means this PR has no checks. Collapsing the two let an API hiccup present
  # as "nothing is failing", i.e. as mergeable-by-a-human: the same
  # unknown-certified-as-green shape as the bug this machine exists to stop.
  # The caller skips the PR entirely rather than labelling on facts it did not
  # read; blocking on it instead would flap the whole board on one bad call.
  # The rollup mixes two node types with two different closed enums: CheckRun
  # carries `conclusion` (CheckConclusionState), StatusContext carries `state`
  # (StatusState). Rather than list the outcomes that block — the version that
  # shipped in this PR's first round listed four, and ERROR, CANCELLED and
  # STALE fell through its `else` into SUCCESS — this lists the outcomes that
  # DON'T, and treats everything else as blocking.
  #
  # That direction is the point. An outcome we do not recognise is one we
  # cannot certify as mergeable, and certifying the unrecognised as green is
  # the exact shape of #136. The cost of being wrong is symmetric in form and
  # not in consequence: a false FAILURE parks the PR on the agent, who looks;
  # a false SUCCESS invites a human to merge a tree that will not merge.
  #
  # The list-what-passes rule has exactly one carve-out, and it is narrower
  # than an outcome: a CANCELLED entry is discarded when its context holds at
  # least one non-cancelled sibling (#139). The reconcile job queues in one
  # repo-global concurrency group, so any repo event — a sibling PR's push,
  # triage labelling an issue — evicts the queued duplicate AFTER it has
  # attached a check run to this PR's head, and that cancelled entry became
  # the context's newest word: blocker:ci-red on a PR whose real checks were
  # all green (#133/#136, evictable only by an empty commit). A cancelled run
  # said nothing about this head; a non-cancelled sibling is a real verdict
  # about exactly these bytes, whatever order the two arrived in — and for
  # this workflow the evictor performs the duplicate's work anyway, since
  # every sweep covers every open PR. This does not widen unknown-into-green:
  # a context whose entries are ALL cancelled never reported at all (a killed
  # or timed-out required job), so it keeps CANCELLED and still blocks —
  # discard needs a surviving verdict, never an empty context.
  #
  # And one exclusion that comes before every rule above: the label machine
  # never grades its own runs (#208). Every reconcile sweep serializes
  # through one shared concurrency group, and GitHub records a displaced
  # queued run as CANCELLED — there is no "superseded" conclusion for queue
  # displacement. When the displaced run was born from a pull_request_target
  # event, that cancelled entry attaches to the victim PR while its
  # SUCCESSOR — triggered by a different PR or an issues event — attaches
  # elsewhere, so the #139 carve-out's premise (a surviving sibling on the
  # same PR) fails structurally: on the victim the newest self entry stays
  # CANCELLED, the deny-list scores it FAILURE, and the sweep sets
  # blocker:ci-red off its own corpse — then re-affirms it every cadence.
  # Proven on crew#227: every real check green, the only red rollup entry
  # the sweep's own displaced run. So drop every entry belonging to
  # $SELF_WORKFLOW before the newest-per-context collapse. Accepted
  # consequences: a rollup of ONLY self entries scores NONE (honestly: no
  # checks — never SUCCESS), and a genuine reconcile failure surfaces on the
  # Actions tab instead of as blocker:ci-red, which is right because no PR
  # edit can fix the label machinery. An empty $self filters nothing — the
  # exclusion must never widen into dropping entries on a guess.
  jq -r --arg self "$SELF_WORKFLOW" '
    if (has("statusCheckRollup") | not) then "UNREADABLE" else

    # NEUTRAL and SKIPPED satisfy branch protection — a skipped required check
    # is not a failed one, and path-filtered jobs skip constantly here.
    ["SUCCESS", "NEUTRAL", "SKIPPED"] as $passing
    # "" covers a StatusContext still reported with no state at all.
    | ["", "PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "EXPECTED"] as $waiting

    # A re-run does not evict the run it superseded — the rollup keeps both.
    # This PR proved it: its own tip carried a CANCELLED `scope` (15:19:39)
    # beside the SUCCESS `scope` (15:19:45) that replaced it, same workflow.
    # Once CANCELLED blocks, judging every entry would strand this very PR in
    # needs-rebase forever, so collapse each context to its newest entry first.
    # Key on workflow + name because a bare job name is only unique within its
    # workflow.
    #
    # Dating a run is the subtle part, and getting it wrong restores the bug.
    # A run still in flight has no completion, but `gh` does not omit the
    # field: its Go struct marshals the zero time as "0001-01-01T00:00:00Z",
    # which is a string, so `//` will not fall through it. Ordering on
    # completion therefore sorted the LIVE re-run to the bottom and let `last`
    # pick the very run it superseded — reporting the old SUCCESS while a
    # replacement was still running, which is #136 again.
    #
    # So: date a run by when it BEGAN, discarding both spellings of absent
    # (null, and the zero sentinel) and falling back only if it never recorded
    # a beginning. NOT by the newest stamp of any kind: `max` compares the
    # completion of a finished run against the start of a live one, which are
    # different quantities and not an ordering on runs. A run cancelled by the
    # concurrency group does not stop the instant its replacement starts — the
    # runner has to wind down — so predecessor.completedAt > successor.startedAt
    # is the ordinary case, and `max` dated the dead predecessor newer than the
    # live run that replaced it, narrowing both failures above without closing
    # them. The list is already in preference order, so `first` IS that rule.
    #
    # An entry that carries no usable timestamp at all sorts LAST rather than
    # first — something we cannot date is most likely the thing just created,
    # and treating it as newest keeps an undateable in-flight run from being
    # discarded in favour of a stale success. Every ambiguity resolves toward
    # "not settled".
    # The #208 exclusion (header above): self entries leave the rollup here,
    # BEFORE the group_by — a self-only context must vanish entirely, never
    # survive as an all-cancelled context that still classifies FAILURE.
    | [ (.statusCheckRollup // [])[]
        | select($self == "" or (.workflowName // "") != $self)
        | { ctx: [.workflowName // "", .name // .context // ""],
            at:  ([.startedAt, .createdAt, .completedAt]
                  | map(select(type == "string" and . != ""
                               and (startswith("0001-01-01") | not)))
                  | first // ""),
            outcome: ((.conclusion // .state // "") | ascii_upcase) } ]
    # The #139 carve-out (header above): drop CANCELLED entries only when the
    # context keeps a non-cancelled survivor — BEFORE the sort, so a cancelled
    # entry that arrived newest cannot outvote the real verdict it displaced.
    # An all-cancelled context is left intact and still classifies FAILURE.
    | group_by(.ctx)
    | map( map(select(.outcome != "CANCELLED")) as $live
           | (if ($live | length) > 0 then $live else . end)
           | sort_by([(.at == ""), .at]) | last | .outcome ) as $latest

    | if   ($latest | length) == 0                            then "NONE"
      elif (($latest - $passing - $waiting) | length) > 0     then "FAILURE"
      elif (($latest - $passing) | length) > 0                then "PENDING"
      else "SUCCESS" end

    end'
}
