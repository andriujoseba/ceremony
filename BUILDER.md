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
- **Your own red head outranks a new claim.** Pick up a failing check at the
  head of a PR you authored before claiming another issue, or it strands
  mergeable and unattended (#163). Record the failing check and its failure
  class; rerun a clearly retryable infrastructure failure without changing
  code; return to the normal fix-round and worklog discipline where the
  failure belongs to the branch; leave visible evidence where a rerun cannot
  be started or the cause is uncertain; never repeatedly rerun a
  deterministic branch failure without a corrective commit; hand off once
  the check is green and current-head approvals stand. Such a PR is **not
  parked**, whatever the round's verdict state says. Red and green are the
  ruled terms of the review round below; how the engine detects a red head
  is crew's to describe, not this file's.
- **One build at a time**: at most one issue on which you are writing or
  revising a deliverable, finished or released before you start new work.
  The rule counts build work in flight, not claims — a **parked** claim,
  whose next move belongs to someone else, does not consume the slot.
  Exactly five shapes park:
  1. `needs-ruling` is set, the escalation names a decider, and its
     `Blocked:` line stops the remaining work;
  2. a **live** review round holds the deliverable, every outstanding
     verdict someone else's — awaiting its first verdicts, or answered whole
     with the owed re-requests posted, by head and not by verdict (steps 1–2
     below). A red check at the current head takes it out of this shape: the
     next move is yours, and reading that as parked strands the PR;
  3. every remaining acceptance criterion is operator-owned, stated as such
     by triage on the issue;
  4. the deliverable is **handed off** — the round passed, no `blocker:*`
     stands, `state:needs-human` is set per Handoff, and the merge is the
     human's. Shapes 2 and 4 are sequential and never overlap;
  5. the claim is **held by directive** — triage or the operator stopped the
     work, the direction names what the hold waits on, and only they end it.
     A hold ends the way it started, **on the labels**: where labels and
     prose disagree, the most recent queue-label event by the hold's owner
     governs, an operator being free to lift by label alone (#149, #151). So
     read the label events (`gh api /repos/{owner}/{repo}/issues/{n}/timeline`),
     not only the comments, before standing down *or* standing up, and where
     you act against stale prose say so in the claim, naming the events,
     their timestamps and their actor. Refusing to claim through the
     contradiction is no resting place: where the events do not resolve it,
     say so on the issue and take the next `ready` issue.
  Not parked: waiting on yourself, on CI (a red head is your own work; a
  pending one resolves without you), or for a good moment. An issue you have
  simply stopped working on is abandoned, not parked — unassign and restore
  `ready`. The rule counts work because parked claims are legitimately held
  beside the one active build (#15, #16, #73).

## Claiming

- Assign yourself, swap `ready` → `claimed`, and comment that you are
  starting. The claim promises a draft PR soon: a claim with no PR and no
  activity is what the staleness sweep reclaims, unless `offsite` records
  that its PR lives in another repository.
- **A park is declared, never inferred.** Comment on the issue naming what
  the claim waits on and who owns the next move; no new label, the comment
  being the activity that feeds the same reclaim clock the `needs-ruling`
  (#52) and `offsite` (#68) exemptions guard. Shape 4 owes no separate
  comment: the handoff comment plus the `state:needs-human` write already
  name the wait (the merge) and its owner (the human).
- **A declaration stands until the park's facts change.** A resumption that
  finds nothing changed posts nothing, because re-declaring on every resume
  floods the record with audits each saying nothing changed (#177). One new
  comment is owed each time the facts change — the named wait resolves or
  changes hands, the parked shape changes, or the claim unparks. A parked
  claim with **no open PR** still feeds the 48-hour reclaim clock, so
  refresh the declaration before that window closes; that refresh is the
  only repeat a park owes, at the reclaim window's cadence.
- **Pick up `attention` before anything else.** Post a short pickup comment
  and remove `attention`; the removal is the ack. A demand on a parked claim
  is usually its unpark, so take the slot back — unless the demand *is* the
  park, where the pickup comment doubles as the declaration and the slot
  stays free.
- **A directed hold keeps its bookkeeping visible.** The PR carries
  `blocked` with a comment naming what it waits on; the issue stays
  `claimed` and carries `attention` until the builder acknowledges it.
  Nobody unassigns the issue, and the 48-hour reclaim does not fire because
  the claim has an open PR.
- **Unparking is a claim like any other** and takes the slot: if you are
  active elsewhere, finish or release that work first and say which you did
  on both issues. Nothing counts claims per builder and no reconciler path
  enforces this — the discipline is the declaration, not a counter, and no
  such machinery should be built expecting it to have been specified here.
- **Abandoning is fine; ghosting is not.** Say where you got to, push the
  branch if it holds anything useful, unassign, and restore `ready`.

## Building

- Branch per issue; open the PR **as a draft early**, `Closes #N` in the
  body. Drafts are invisible to the reviewer panel on purpose: the draft
  phase is yours.
- **`Closes #N` does not cross repos.** A PR in a different repo from its
  authorizing issue says `Part of <owner>/<repo>#N`, sets `offsite`, and
  comments the draft PR link on that issue in the same step. Triage closes
  that issue by hand once its acceptance criteria are met, and at that
  handoff the builder reports whether the PR merged or closed and clears
  `offsite` in the same comment (#13, #16).
- **`Closes #N` does not survive a post-merge criterion.** Where the issue's
  body states that a criterion can only be checked after the merge — a live
  proof of a workflow trigger, a released-artifact check, anything whose
  subject does not exist until the change is on the base branch — the
  same-repo PR says `Refs #N` and triage closes by hand on the evidence. The
  merge releases the claim: the issue moves to `post-merge`, the builder
  walks away, and triage owns verification and closure, returning it to
  `ready` or minting a fresh issue for corrective work that any builder
  claims from current `main`. The issue body is what says so — you never
  judge which issues qualify, and absent that instruction `Closes #N` is the
  default (#151).
- On a `Refs #N` PR, never put a closing keyword (`close`, `closes`,
  `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`)
  immediately before `#N` anywhere in the body, including the sentence
  explaining why the PR does not close it: GitHub reads the body by
  adjacency, not intent, and a code span does not protect the phrase (#200,
  #218). Put the number first (`#N is closed by hand`) or omit it.
- **The issue's acceptance criteria are your definition of done.** Reproduce
  them as a checklist in the PR body and check them honestly as you go; a
  criterion that turns out wrong or unreachable goes back to triage to be
  amended, never silently shipped short.
- **Every behavior change writes one fragment**, `changelog.d/<issue>.md`
  named for the authorizing issue (`<repo>-<issue>.md` cross-repo): the
  exact prose to be published and nothing else — `- ` bullets, plus in a
  grouped repo the `### Added` / `### Changed` / `### Fixed` headings inside
  the fragment, a rarer kind only where a change genuinely is one. An entry
  is at most 300 characters, so a genuinely long change ships several short
  entries; wrapping one over continuation lines never counts against it. It
  **ends with its issue citation**: one `(` group of `#N`, `repo#N` or
  `owner/repo#N` separated by `, `, then `)`, then the final `.` and nothing
  after it — `(#262).`, or `(#236, #250).` where an entry honestly lands two
  — and it need not name the fragment's own issue, which the filename
  carries. The guard reds a longer entry (#167) and an uncited one (#262)
  alike. Never edit `CHANGELOG.md` for an entry: the release PR assembles
  the section from the fragments (#112), and the monotonic guard refuses
  anything that deletes a shipped heading.
- Follow the repo's conventions file and match the code you touch. Tests are
  not optional: the issue's test plan is the floor, not the ceiling.
- **A write-capable job gets a repo-owned script, not a third-party action.**
  Where the job's token can write (`packages: write`, `contents: write`,
  `id-token: write`, deploy secrets), default to a script in the repo that a
  test can drive; a third-party action there needs an established publisher
  and a full-commit-SHA pin, and read-only jobs still SHA-pin. The full rule
  and the red-flag profile a reviewer applies are in REVIEWER.md §What you
  review against, item 2 (#216).
- **Scope discipline: the PR does the issue — whole, and nothing else.**
  Adjacent problems go to a **discussion**, or a comment on the relevant
  issue, where triage does its job. You do not mint issues — nobody but
  triage does — and you do not fix drive-by findings in the same PR, because
  a reviewer cannot converge on a widening target.

## The review round

1. Mark ready-for-review; request **the whole panel**: the PR repo's
   `panel[<your-login>]=` line if it defines one, else its `panel=` line,
   minus the author in either case (#224) — never the roster of the repo the
   issue is in. That repo's `.github/labels.conf` governs over its
   CONTRIBUTING roster, being what the state machine reads; where the PR
   repo names no roster, ask triage on the authorizing issue rather than
   guessing. An off-panel reviewer may be requested, saying that their
   verdict is advisory and does not become required.
   **A review request requires a green check at the head**, and that binds
   you whether or not any engine enforces it: a red check is the author's
   own signal, not the panel's work, so fix it and push, then request. The
   one exception is a failure genuinely outside the PR — a runner outage, a
   flaky dependency, a failure already present on the default branch — and
   only where the request says so explicitly and names the evidence ("the
   same job fails identically on `origin/main` at `<sha>`"); silence about a
   red check is what is prohibited.
   *Green* is a ruled term (operator, 2026-07-27), read in two steps,
   because a head carries more rollup entries than it has checks. **First
   find the check's word at this head**: its newest entry by start time,
   except that a `CANCELLED` entry is never the word while the same check
   has a non-cancelled entry at that head. Date entries by start, not by
   completion — a cancelled run outlives its replacement's start, so the
   other reading picks the corpse. A check whose every entry at the head is
   cancelled has not reported and stays not-green by the classes below; that
   is a collapse and not a new class, the gate likewise dropping a cancelled
   entry only where its context keeps a non-cancelled survivor (#139, #276).
   **Then classify that entry from its `conclusion`, never its `status`**,
   which can still disagree with it (#259). No conclusion at all is neither
   class: a configured run still in progress is not green, and waiting on it
   is compliance, not a stall. **Cancelled or stale** is not green — *stale*
   means a superseded head's check, which a head-scoped rollup never shows,
   so what survives there is same-head cancellation. **Skipped or neutral**
   *is* green: those are deliberate "passed / not applicable" conclusions,
   and reddening them would red every conditional job the fleet skips on
   purpose. **No checks configured** is the third ruled case, not an argued
   exception: nothing is configured, so nothing is waited for and the
   request goes out at once, no evidence owed. That rules
   nothing-configured, never nothing-answered-yet — a pending run has an
   owner, CI — and the machine partitions alike, admitting the ask on
   `SUCCESS` and on `NONE` (#236). The costs behind the line are asymmetric:
   a false green spends a three-reviewer round, a false red one author
   session. What the *machine* drops from the rollup before grading is
   crew's to describe.
2. **Wait for every verdict, then answer the round whole** — one reply
   covering every point and stating what changed and what was verified. That
   reply is the written round record: the engine mirrors it under the PR
   body's **Round log**, newest last, so the builder owes the reply and no
   separate body edit, and a round answered without one is recorded as such
   and never blocks handoff.
   Then push the fixes and re-request **by head, not by verdict**. A push
   makes every approval stale — an approval is of a specific tree, and the
   handoff predicate counts only approvals at the current head — so **every
   panelist is re-requested, the approvers included**; one left
   un-re-requested can never approve the tree you shipped, and the PR sits
   looking finished with nothing owed by anyone (#26, #39). Only where the
   head did not move — the round answered with argument or evidence, nothing
   pushed — do you re-request just the non-approvers, a standing approval
   already covering this exact head (#94). **The re-request carries the same
   green-check-at-head precondition**, argued exception included: a fix push
   whose check comes up red is your next fix, not the panel's. Prefer
   verification over argument — where a reviewer doubts behavior, add the
   test that settles it.
3. Never dismiss a review, never merge, never mark your own work as passed.
   A blocking point you disagree with is answered with evidence or escalated
   in the PR; silence and force-forward are not options, and a panel
   deadlock is one kind of human-owned decision (#50 D11).

**A fix round may ride a draft**, and the draft changes nothing about who
owes what. An engine may convert a PR back to draft when a round closes, so
that mid-round saves stop firing CI on a ready PR; ceremony implements no
such conversion, but whoever meets a mid-round draft reads it as a draft
always read — the draft phase is yours and the panel cannot see it — while
the round outranks the draft, so you still owe it whole, the fixes and the
reply and the flip ([LABELS.md](LABELS.md)'s `state:building` row, #205).
**Ready-for-review is the act that ends the round, and it is the builder's
alone**: the flip asserts that the round was answered whole, the one
judgement about a round its author cannot delegate, so an engine may draft a
PR but only the builder undrafts it. **Where a draft suppressed the checks,
green is proven at the flip and the request still follows it**: marking
ready is what runs the checks the draft held back, so the order is flip, let
the head answer, then request — step 1's precondition, not a second one —
and waiting there is compliance, not a stall, which is why
`blocker:unrequested` does not fire while a head's checks are pending or red
(#236).

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
  out loud that you did; a hard block waits.
- **at 12h:** do not fire a stale default — re-read it against what has
  landed, and where doubt has appeared, make it a hard block.
- **at 24h:** proceed regardless, **as a PR**: pick an option and state in
  the PR body which way you went and what doubt remains. Nothing merges by
  this; the human still gates the merge.
- **past 24h:** hand the choice to triage, which picks the option, records
  it as a decision, and remains accountable; the operator can overturn it at
  merge.

A re-flag starts a fresh ladder. The ladder applies whatever `Default:` says,
including a hard block, and an active back-and-forth still climbs it — unlike
the 7-day nudge, which resets on real activity. The machine observes both
clocks but never sets, clears, or decides `needs-ruling`.

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
lives in the Round log, mirrored from each whole-round reply. The label write
is optimistic — the reconciler validates it and takes it back if the PR is
not actually mergeable-right-now. Then stop: the PR is the human's, and the
claim is parked as shape 4 (Picking, above), that handoff comment being its
declaration and your build slot free. Address what comes back
(`state:addressing`) and re-hand-off the same way.
