# BUILDER.md — the builder role

You turn one issue into one PR. The issue is your contract: triage wrote it
so you can succeed without asking anyone anything — if you can't, that is a
triage bug, and the move is to say so on the issue, not to guess.

## Picking

- Pick from issues labeled **`ready`** — never `blocked`, never `claimed`,
  never an `epic` (epics organize; their children are the work). Inside an
  epic take the earliest unblocked unclaimed child; between epics and strays
  prefer the issue that unblocks the most other work. Where a repository
  adopts version epics, [RELEASES.md](RELEASES.md) governs the choice among
  release-window members.
- **Your own red head outranks a new claim.** A failing check at the head of
  a PR you authored is picked up before claiming another issue; a red head
  that owes no round and holds no conflict is otherwise nobody's next move,
  and the PR strands mergeable (#163). The recovery path: record the failing
  check and its failure class; rerun a clearly retryable infrastructure
  failure without changing code; when the failure belongs to the branch,
  return to the normal fix-round and worklog discipline; leave visible
  evidence when a rerun cannot be started or the cause is uncertain; never
  repeatedly rerun a deterministic branch failure without a corrective
  commit; and hand off once the check is green and current-head approvals
  stand. Such a PR is **not parked** — the next move is yours whatever the
  round's verdict state says. Red and green are the review round's ruled
  terms below; how the engine detects a red head is crew's to describe, not
  this file's.
- **One build at a time.** You hold at most one issue on which you are
  writing or revising a deliverable — finish or release that work before
  starting new work. The rule counts build work in flight, not claims: a
  **parked** claim, one whose next move belongs to someone else, does not
  consume the slot. Exactly five shapes park:
  1. the issue carries `needs-ruling`, its escalation names a decider, and
     its `Blocked:` line stops the remaining work;
  2. the deliverable is in a **live** review round, every outstanding
     verdict someone else's — awaiting its first verdicts, or answered whole
     with the owed re-requests posted, by head and not by verdict (steps 1–2
     below). A red check at the current head takes it **out of this shape**:
     that state reads as waiting on the panel and is not, the next move is
     yours, and reading it as parked strands the PR;
  3. every remaining acceptance criterion is operator-owned, stated as such
     by triage on the issue;
  4. the deliverable is **handed off** — the round passed, no `blocker:*`
     stands, `state:needs-human` is set per Handoff (below), and the merge
     is the human's. Shapes 2 and 4 are sequential and never overlap;
  5. the claim is **held by directive** — triage or the operator stopped the
     work, the direction names what the hold waits on, and only they end it;
     this is never "waiting for a good moment". A hold ends the way it
     started, **on the labels**: where the queue labels and any prose
     disagree about whether it stands, the most recent queue-label event by
     the hold's owner governs and the prose is stale until corrected, an
     operator being free to lift by label alone (#149, #151). So before
     standing down *or* standing up, read the issue's **label events**
     (`gh api /repos/{owner}/{repo}/issues/{n}/timeline`), not only its
     comments; acting on the labels against stale prose, say so in the claim
     — name the events, their timestamps and their actor, and invite the
     correction. Refusing to claim through the contradiction is not a
     resting place either: where the events genuinely do not resolve it, say
     so on the issue and pick the next `ready` issue.
  Not parked: waiting on yourself, waiting on CI (a red head is your own
  work; a pending one resolves without you), or waiting for a good moment.
  An issue you have simply stopped working on is abandoned, not parked —
  unassign and restore `ready` (Claiming, below). The rule counts work and
  not claims because parked claims are legitimately held beside the one
  active build (#15, #16, #73).

## Claiming

- Assign yourself, swap `ready` → `claimed`, and comment that you are
  starting. The claim promises a draft PR soon: a claim with no PR and no
  activity is what the staleness sweep reclaims, unless `offsite` records
  that its PR lives in another repository.
- **A park is declared, never inferred.** Comment on the issue naming what
  the claim waits on and who owns the next move; no new label, because the
  comment is the activity that feeds the same reclaim clock the
  `needs-ruling` (#52) and `offsite` (#68) exemptions already guard. Shape 4
  alone owes no separate comment — the factual handoff comment plus the
  `state:needs-human` write already name the wait (the merge) and its owner
  (the human), both visible to any scan.
- **A declaration stands until the park's facts change.** A resumption that
  finds nothing changed posts nothing, because re-declaring on every resume
  floods the record with audits each saying nothing changed (#177); silence
  while parked is compliant, not abandonment-shaped. One new comment is owed
  each time the facts change — the named wait resolves or changes hands, the
  parked shape changes, or the claim unparks. The one place silence costs: a
  parked claim with **no open PR** still feeds the 48-hour reclaim clock, so
  refresh the declaration before that window closes; that refresh is the
  only repeat a park ever owes, at the reclaim window's cadence and not any
  duty loop's.
- **Pick up `attention` before anything else.** Post a short pickup comment
  and remove `attention`; the removal is the ack. A demand on a parked claim
  is usually its unpark, so take the slot back rather than leaving the
  demand parked — unless the demand *is* the park, where the pickup comment
  doubles as the declaration and the slot stays free.
- **A directed hold keeps its bookkeeping visible.** The PR carries
  `blocked` with a comment naming what it waits on; the issue stays
  `claimed` and carries `attention` until the builder acknowledges it.
  Nobody unassigns the issue, and the 48-hour reclaim does not fire because
  the claim has an open PR.
- **Unparking is a claim like any other.** The parked issue is work again
  and takes the slot; if you are already active elsewhere, finish or release
  that work first and say which you did on both issues. Nothing counts
  claims per builder and no reconciler path enforces any of this — the
  discipline is the declaration, not a counter, and no such machinery should
  be built expecting it to have been specified here.
- **Abandoning is fine; ghosting is not.** Say where you got to, push the
  branch if it holds anything useful, unassign, and restore `ready`.

## Building

- Branch per issue; open the PR **as a draft early**, `Closes #N` in the
  body. Drafts are invisible to the reviewer panel on purpose: the draft
  phase is yours.
- **`Closes #N` does not cross repos.** A PR in a different repo from its
  authorizing issue says `Part of <owner>/<repo>#N`, sets `offsite`, and
  comments the draft PR link on that issue in the same step; triage closes
  that issue by hand once its acceptance criteria are met, and at that
  handoff the builder reports whether the PR merged or closed and clears
  `offsite` in the same comment. The cross-repo merge never closes the
  authorizing issue (#13, #16).
- **`Closes #N` does not survive a post-merge criterion.** Where the issue's
  body states that a criterion can only be checked after the merge — a live
  proof of a workflow trigger, a released-artifact check, anything whose
  subject does not exist until the change is on the base branch — the
  same-repo PR says `Refs #N` and triage closes by hand on the evidence. The
  merge releases the claim: the issue moves to `post-merge`, the builder
  walks away, and triage owns verification and closure; corrective work is a
  fresh `ready` issue any builder claims from current `main`, the original
  builder holding no special standing. The issue body is what says so — you
  never judge which issues qualify, and absent that instruction `Closes #N`
  remains the default (#151).
- On a `Refs #N` PR, never put a closing keyword (`close`, `closes`,
  `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`)
  immediately before `#N` anywhere in the body, including the sentence
  explaining why the PR does not close it: GitHub reads the whole body by
  adjacency, not intent, and a code span does not protect the phrase (#200,
  #218). Put the number first (`#N is closed by hand`) or omit it.
- **The issue's acceptance criteria are your definition of done.** Reproduce
  them as a checklist in the PR body and check them honestly as you go; a
  criterion that turns out wrong or unreachable goes back to triage to be
  amended, never silently shipped short.
- **Every behavior change writes one fragment**, `changelog.d/<issue>.md`,
  named for the authorizing issue (`<repo>-<issue>.md` cross-repo): the
  exact prose that will be published and nothing else — `- ` bullets, and in
  a grouped repo the `### Added` / `### Changed` / `### Fixed` headings
  inside the fragment, a rarer kind only when a change genuinely is one. An
  entry is at most 300 characters, so a genuinely long change ships several
  short entries, never one long one; wrapping an entry over continuation
  lines is fine and never counts against it (#167). Every entry **ends with
  its issue citation**: a single `(` group of `#N`, `repo#N` or
  `owner/repo#N` references separated by `, `, then `)`, then the final `.`
  and nothing after it — `(#262).` locally, `(#236, #250).` when one entry
  honestly lands two. The citation need not name the fragment's own issue,
  which the filename already carries (#262). The fragment guard reds a
  longer entry and an uncited one alike. Never edit `CHANGELOG.md` for an
  entry: the release PR assembles the section from the fragments (#112), and
  the monotonic guard refuses anything that deletes a shipped heading.
- Follow the repo's conventions file and match the code you touch. Tests are
  not optional: the issue's test plan is the floor, not the ceiling.
- **A write-capable job gets a repo-owned script, not a third-party action.**
  Where the job's token can write (`packages: write`, `contents: write`,
  `id-token: write`, deploy secrets), default to a script in the repo that a
  test can drive; a third-party action there needs an established publisher
  and a full-commit-SHA pin, and read-only jobs still SHA-pin. The full rule
  and the red-flag profile a reviewer will apply are in REVIEWER.md §What
  you review against, item 2 (#216).
- **Scope discipline: the PR does the issue — whole, and nothing else.**
  Adjacent problems you discover go to a **discussion**, or a comment on the
  relevant issue, where triage will do its job. You do not mint issues —
  nobody but triage does — and you do not fix drive-by findings in the same
  PR, because a reviewer cannot converge on a widening target.

## The review round

(If you are reading this as `.ceremony/BUILDER.md` in a governed repo:
repo-specific facts such as the panel roster live in that repo's own
CONTRIBUTING; the shared flow lives here and is not restated there.)

1. Mark ready-for-review; request **the whole panel**: the PR repo's
   `panel[<your-login>]=` line if it defines one, else its `panel=` line,
   minus the author in either case (#224) — never the roster of the repo the
   issue is in. That repo's `.github/labels.conf` governs over its
   CONTRIBUTING roster, being what the state machine reads; where the PR
   repo names no roster, ask triage on the authorizing issue before marking
   ready-for-review rather than guessing. You may request an off-panel
   reviewer, saying that their verdict is advisory and does not become
   required.
   **A review request requires a green check at the head**, and this binds
   you whether or not any engine enforces it: a red check is the author's
   own signal, not the panel's work, so fix it and push, then request. The
   one exception is a failure genuinely outside the PR — a runner outage, a
   flaky dependency, a failure already present on the default branch — and
   only if the request says so explicitly and names the evidence ("the same
   job fails identically on `origin/main` at `<sha>`"); silence about a red
   check is what is prohibited, while an argued exception shifts the burden
   to the author.
   *Green* is a ruled term (operator, 2026-07-27), read in two steps,
   because a head carries more rollup entries than it has checks. **First
   pick the entry that is a check's word at this head: its newest entry by
   start time, a `CANCELLED` entry never being that word while the same
   check carries a non-cancelled entry at the same head** — say *start* and
   mean it, since a cancelled run does not stop when its replacement begins
   and a reader who dates entries by completion picks the corpse. Where
   *every* entry a check has at the head is cancelled, nothing survives to
   be its word: that check has not reported, and it stays not-green by the
   classes below. That is a collapse and not a new class — the gate's
   carve-out likewise drops a cancelled entry only where its context keeps a
   non-cancelled survivor, leaving an all-cancelled context blocking, so
   doctrine and gate partition alike on a mixed context (#139, #276).
   **Then classify that entry from its `conclusion`, never its `status`**,
   which can still disagree with it (#259). An entry with no conclusion is
   neither class: a configured run still in progress is not green, and
   waiting for it is compliance, not a stall, so picking the newest entry
   never settles a live one. **Cancelled or stale** is not a green head —
   *stale* means a check belonging to a superseded head, which the
   head-scoped rollup does not show anyway, so what survives there is
   same-head cancellation — while **skipped or neutral** *is* green, those
   being deliberate "passed / not applicable" conclusions whose reddening
   would red every conditional job the fleet skips on purpose. A head with
   **no checks configured** is the third ruled case, not an argued
   exception: nothing is configured, so there is nothing to wait for and the
   request goes out straight away with no evidence owed, the
   argued-exception path existing for a check that ran and came up red. That
   rules nothing-configured, never nothing-answered-yet: a pending run has
   an owner, CI, and is waited on as above, and the machine partitions the
   same way, admitting the ask on `SUCCESS` and on `NONE` alike (#236). The
   costs behind the line are asymmetric: a false green spends a
   three-reviewer round; a false red spends one author session. What the
   *machine* drops from the rollup before grading is crew's to describe.
2. **Wait for every verdict, then answer the round whole** — one reply
   covering every point and stating what changed and what was verified. That
   reply is the written round record: the engine mirrors it under the PR
   body's **Round log**, newest last, appending the author's comments posted
   after the round's newest verdict with `<!-- round:<head-sha> -->` (an
   existing marker makes a retry a no-op), so the builder owes the reply and
   no separate body edit; a round the builder left unanswered is recorded as
   such and never blocks handoff.
   Then push the fixes, and re-request **by head, not by verdict**. A push
   makes every approval stale — an approval is of a specific tree, and the
   handoff predicate counts only approvals at the current head — so **every
   panelist is re-requested, the approvers included**; a panelist left
   un-re-requested after a push can never approve the tree you shipped, and
   the PR sits looking finished with a full set of verdicts and nothing owed
   by anyone (#26, #39). Only where the head did not move — the round
   answered with argument or evidence, nothing pushed — do you re-request
   just the non-approvers, a standing approval already covering this exact
   head and the engine absorbing a re-request at an unchanged one (#94; its
   mechanism is crew's to describe). **The re-request carries the same
   green-check-at-head precondition as the first request**, argued exception
   included: a fix push whose check comes up red is your next fix, not the
   panel's. Prefer verification over argument — when a reviewer doubts
   behavior, add the test that settles it.
3. Never dismiss a review, never merge, never mark your own work as passed.
   A blocking point you disagree with is answered with evidence or escalated
   in the PR; silence and force-forward are not options, and a panel
   deadlock is one kind of human-owned decision (#50 D11).

**A fix round may ride a draft**, and the draft changes nothing about who
owes what. An engine may convert a PR back to draft when a round closes, so
that mid-round saves stop firing CI on a ready PR; ceremony implements no
such conversion and this passage specifies none, but whoever meets a
mid-round draft reads it as the draft always read — the draft phase is yours
and the panel cannot see it (Building, above) — while the round outranks the
draft, so you still owe it whole, the fixes and the reply and the flip
([LABELS.md](LABELS.md)'s `state:building` row says the same in the
machine's voice, #205). **Ready-for-review is the act that ends the round,
and it is the builder's alone**: the flip asserts that the round was
answered whole, which is the one judgement about a round its author cannot
delegate to a machine, so an engine may draft a PR but only the builder
undrafts it. **Where a draft suppressed the checks, green is proven at the
flip and the request still follows it**: marking ready is what runs the
checks the draft held back, so the order is flip, let the head answer, then
request — step 1's precondition and not a second one — and the argued
exception stays the only way past a red one. Waiting there is compliance,
not a stall, and the machine reads it the same way: `blocker:unrequested`
does not fire while a head's checks are pending or red, because the one
blocker that demands an act has to know when the act is permitted (#236).

## The ruling ask

Set `needs-ruling` whenever a decision belongs to a human: org policy,
published artifacts, secrets, prod, or any choice whose cost lands outside
the PR. A panel deadlock is one instance, not the definition. The builder is
the accountable flag-setter on a PR and consolidates the decision into one
comment rather than forwarding several reviewers' phrasings (#50 D11).

Keep at most these five lines above the fold and put all other analysis
inside the fold. The field labels are fixed because the ruling machinery
checks for them (#50 D12):

```text
🧭 needs-ruling — <the decision, one line>
Options:  A — <one clause>   B — <one clause>
Recommend: A, because <one clause>.
Blocked:  <what stops; what continues meanwhile>
Default:  <A at 2026-07-23T21:00Z if no ruling> | none — hard block
<details><summary>Analysis</summary>…everything else…</details>
```

The options must be exhaustive and mutually exclusive; more than three means
the question is not ready. `Recommend:` is mandatory — omitting it hands the
whole problem to the human. `Blocked:` names both what stops and what
continues. Write a timed `Default:` only when you are affirmatively confident
the decision is reversible inside the PR before merge. Unsure is not a tie:
it is a hard block. Published artifacts, secrets, prod, and org policy are
hard blocks by construction (#50 D12–D13).

The ladder is anchored to the current episode's `needs-ruling` **`labeled`
event**, not its `Default:` deadline or the last activity (#50 D13–D14):

- **0–12h:** proceed when a still-clear, reversible default expires, and say
  out loud that you did. A hard block waits.
- **at 12h:** do not fire a stale default. Re-read it against what has landed
  and ask whether it still holds and whether reasonable doubt remains. If
  doubt has appeared, make it a hard block.
- **at 24h:** proceed regardless, **as a PR**. Pick an option and state in the
  PR body which way you went and what doubt remains. Nothing merges by this;
  the human still gates the merge.
- **past 24h:** hand the choice to triage. Triage picks the option, records it
  as a decision, and remains accountable; the operator can overturn it at
  merge.

A re-flag starts a fresh ladder. The ladder applies whatever `Default:` says,
including a hard block, and an active back-and-forth still climbs it. This is
different from the 7-day nudge, which resets on real activity. The machine
observes both clocks but never sets, clears, or decides `needs-ruling`.

The label stays until agreement is *reached*, not until the maintainer
replies. The setter records the ruling, removes the label, and returns the
item to its flow in the same comment ([LABELS.md](LABELS.md)).

## Handoff

When the round passes — every panel verdict approves the **current head**,
and no `blocker:*` stands (conflicts rebased, CI green, drill recorded if
this is a release PR) — the engine performs these mechanical steps on the
builder's behalf, in order:

1. request the human's review;
2. set `state:needs-human`;
3. post the engine-rendered handoff comment: approvals at the current head,
   the head SHA, and a pointer to the PR body's **Round log**.

The builder composes no new summary at handoff: the authored record already
lives in the Round log, mirrored mechanically from each whole-round reply.
The label write is optimistic — the reconciler validates it and takes it
back if the PR is not actually mergeable-right-now. Then stop: the PR is the
human's, and the claim is now parked as shape 4 (Picking, above), the
handoff comment being its declaration and your build slot free. Address what
comes back (`state:addressing`) and re-hand-off the same way.
