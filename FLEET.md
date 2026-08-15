# FLEET.md — the fleet shape, and how it actually runs

> **Status:** descriptive snapshot, not doctrine. This file records how the
> heavy-duty operator fleet is wired *today*. It is **not** part of the
> vendored doctrine set (`.ceremony/`) and is never mirrored to consumer
> repos. [Crew](https://github.com/heavy-duty/crew) is a general tool: its
> repository ships the engine, while the fleet definition belongs to the
> operator; heavy-duty is one operator of it. Membership, repository scope,
> agent-profile overrides and doctrine paths belong to that definition;
> membership itself lives outside every checkout. Crew's shipped defaults
> name heavy-duty's AGENTS.md, TRIAGE.md, BUILDER.md and REVIEWER.md, but
> those are compatibility defaults, not vocabulary compiled into the engine
> — operator `doctrine.conf` values can replace them.
> The *mechanism* lives with crew and this file points at it. Last reconciled
> against the merged engine at
> [`heavy-duty/crew@eaeb302`](https://github.com/heavy-duty/crew/tree/eaeb3022aa47d90e797f2b9e007b831df7ca8406),
> 2026-07-28 — a descriptive file with no reconciliation stamp gives the next
> reader nothing to diff, which is exactly how the #149 drift went unnoticed.

## Fleet shape

One box (an isolated, disposable VM) per GitHub identity. Boxes are credential
boundaries; sessions inside a box are role boundaries. No box has an inbound
network path — GitHub is the only queue. Fleet membership is the operator's
definition and lives outside every checkout; this file deliberately carries
no second roster.

Review panel per PR = the governed repo's `.github/labels.conf` `panel=` line
minus the PR's author, as [REVIEWER.md](REVIEWER.md) specifies (recusal by
construction). Only humans merge — enforced as permissions (the agents team
holds the triage role, not write), not as convention.

## Anatomy of a duty loop

The mechanism is no longer described here. The five hand-rolled duty scripts
converged into crew's shared engine, and a prose mirror of running code in a
second repo is a second thing to keep true — this one drifted (it said cron
ran `duty.sh` directly and gave the hygiene sweep its own cron line; crew's
`duty.sh` records that separate line as the bug it fixed, sharing
`~/duty/work` unlocked). How a tick actually works — cron fires
[`bin/tick.sh`](https://github.com/heavy-duty/crew/blob/eaeb3022aa47d90e797f2b9e007b831df7ca8406/shared/bin/tick.sh),
the only cron target, which wraps
[`bin/duty.sh`](https://github.com/heavy-duty/crew/blob/eaeb3022aa47d90e797f2b9e007b831df7ca8406/shared/bin/duty.sh)
in a non-blocking `flock` with one evidence line per boundary; the boot gate
and crash recovery; the session runner; backlog hygiene self-scheduling
inside the duty tick under the same lock — lives with the code:
[`shared/README.md`](https://github.com/heavy-duty/crew/blob/eaeb3022aa47d90e797f2b9e007b831df7ca8406/shared/README.md)
is the map, provenance table included. Sessions stay disposable: durable work
state lives on the board (issues, PRs, labels) and in git branches, while the
engine keeps only operational evidence and deduplication state under
`~/duty`; detection is the engine's, judgment is the session's.

What belongs here is what a wake *means*:

- **The registry is the scope.** A box acts only on repos its operator
  listed. Work it finds outside that scope is reported and never acted on;
  the report is part of the boundary, because a bounded wake that goes quiet
  is indistinguishable from a broken one. Adding a repo is an **operator
  decision**, never something a sweep makes by writing where nobody listed.
  The 2026-07-25 scope ruling (crew#16) closed the org-wide review and
  author-side write surface; the crew#66 attention ruling closed the last
  exemption. Crew's
  [`examples/repos.txt` header](https://github.com/heavy-duty/crew/blob/eaeb3022aa47d90e797f2b9e007b831df7ca8406/examples/repos.txt)
  is the pinned source for how that rule is implemented and reported.

### Wake conditions

One wake is shared by all three roles, so it is stated once instead of pasted
into each list: **an open issue assigned to me carrying `attention`.** Anyone
can be an assignee, which is why the trigger is role-independent — triage,
builders and reviewers all carry it, and the pickup session is the same shape
in each. It runs **first, ahead of everything in the per-role lists below** —
for builders, ahead of resume: a demand parked by triage, the operator or a
sibling agent outranks self-directed continuation, and it is frequently the
very thing that unparks the work resume would otherwise pick up. The query is
the authenticated-user endpoint —
`gh api "/issues?filter=assigned&state=open&labels=attention"` — one call, no
search index (the review queue below already records that the index lags) —
and it **sees** repos outside the operator's registry, because that endpoint
takes no repo filter.

**Seeing is not acting, and that is a ruling** (crew#66, danmt, 2026-07-27).
The wake used to work every row it saw, which for a builder meant a clone and
the full worktree and round rule set against a repo no operator had listed —
write authority outside the registry, and the one hole left in the
containment story. Rows are now partitioned against the registry: inside it,
a session as before; outside it, reported and never acted on, exactly like an
out-of-scope review request or authored PR.
[`lib/duty-attention.sh`](https://github.com/heavy-duty/crew/blob/eaeb3022aa47d90e797f2b9e007b831df7ca8406/shared/lib/duty-attention.sh)
implements the partition and states the ruling in its header.

The cost was argued before the ruling rather than discovered after it: an
assignment plus a label **is** a targeted authorization, so a cross-repo
handoff now waits on an operator adding the repo, and the box most likely to
be handed work outside its beat is the one that goes quiet. That is why an
out-of-scope demand does not only reach `duty.log` — it pings the operator
over the same channel the boot gate uses. A bounded wake that failed silently
would trade an unbounded write surface for a broken channel to the human.

Each demand gets **exactly one session, and the ack bounds it**: the
session's first act, before any of the demanded work, is the pickup comment
plus removing the label — [the `attention`
contract's](https://github.com/heavy-duty/ceremony/blob/bce09aa7648dbd74b8e91b1d4fbc2fa8d145f705/LABELS.md#L143-L149)
ack (#85), which here becomes the session's ack-then-act ordering.
Then it acts on the thread and exits — short by construction. Until the label
is removed the flag is still up, so a session that **dies** before acking is
simply relaunched at the next tick — the same crash-only shape as resume
below. A session that **completes** without acking is a different fact: that
is a decline, and a seen-ledger stops it re-firing until the issue moves.
Dying and declining used to look identical to the engine, which meant a
demand a session had considered and correctly left alone woke a new one every
tick forever.

The design this replaces was built and rejected: polling notifications for
`reason: mention` re-arms a thread on every comment, so ordinary round
traffic — verdicts naming the builder, the builder's own replies echoing back
— burns a full agent session per tick on nothing actionable; a mention
answers *"was I named?"*, not *"am I needed?"*. The incident that bought the
wake: [#16's 16:49Z
ruling](https://github.com/heavy-duty/ceremony/issues/16#issuecomment-5061051198)
authorized the last open acceptance criterion on a `claimed` issue and sat
unowned for over an hour — the box answered every state signal that day and
never saw the comment, and the eventual pickup ran on a manual bridge. The
wake is no longer on paper: `duty-attention.sh` is deployed engine, and
`duty.sh` runs it first on every box, whatever its roles.

The engine's duty order is fleet-standard
([`bin/duty.sh`](https://github.com/heavy-duty/crew/blob/eaeb3022aa47d90e797f2b9e007b831df7ca8406/shared/bin/duty.sh)):
**attention → triage signals → review queue → resume → ci-red → build →
handoff → rebase → worktree hygiene → backlog hygiene (hourly)** — attention
role-independent and first, then each duty family the box's roles enable.
Every position in that order is deployed engine at the stamped SHA:
[crew#64](https://github.com/heavy-duty/crew/pull/64) merged ci-red between
resume and build, and `duty.sh`'s own header carries the same order.
The earlier form of this file folded handoff and rebase into the other
builder wakes; they are duties of their own.

- **Triage signals**, per registry repo: `needs-triage` issues,
  queue-unlabeled strays, discussions without triage's voice, unread
  `@`-mentions (their own session), and `blocked` issues whose named blockers
  have all landed — a lead the session verifies, never a label the engine
  flips. Backlog hygiene (stale claims, label invariants) runs hourly,
  self-scheduled inside the duty tick. A `needs-ruling` standing **past
  24h** is still triage's to pick up — the ladder's last rung makes the
  option triage's to choose — but, like the notifier queue below, that
  detection row is on paper only today.
- **Review queue**: one candidate set, enumerated from the pulls pages of
  every registry repo — object endpoints, never the search index for the
  queue itself, whose lag left cast#143, incubator#25 and box#164 sitting
  unreviewed — filtered to PRs listing me in `requested_reviewers`, deduped
  by (repo, PR) before acting (the sequential shape double-announced on
  ceremony#32), and worked oldest-first. One search-backed **awareness pass**
  per tick reports requests outside the registry and never acts on them —
  the scope rule above. One verdict per head, deduplicated against my own
  latest review's SHA; a re-request at an unchanged head is answered with an
  auto-approve through the verdict gate rather than left as a stale blocker
  (operator ruling 2026-07-23, ceremony#94).
- **Resume** (builders, checked before build): an open draft PR of mine, or
  a `claimed` issue whose `build/*` branch exists on my fork with no open PR
  — a session died between first push and PR creation. A branch whose PR
  already **merged** is a post-merge wait, never resumed (#172,
  incubator#55/#64).
- **ci-red** (builders): a non-draft PR of mine whose check at the current
  head is failing. Evaluated before the build wake, so a red PR of mine
  outranks a new claim — repairing my own red head comes ahead of new work
  (ceremony#163: full-panel approvals at the head, mergeable, stranded on
  a transient failure no wake covered). A round owed at a red head is
  excluded from the build wake below but reported rather than silent, and
  an unchanged red head goes quiet after one attempt, through the
  `report_suppressed` path — suppressed, still said. A check that has not
  finished is **not** a red head and wakes nothing here: nothing has failed
  yet, so there is no investigation to launch. A head carrying `rerun-owed`
  is **skipped**: the evidence is already posted and starting the rerun is a
  right no fleet identity holds, so waking a session there is the stall in
  miniature, and the skip is what lets the build wake below reach a new claim
  — the claim on that PR's issue is parked ([BUILDER.md](BUILDER.md), shape
  6). Only this row skips: the build wake's hold on a red head is unchanged,
  so the round at that head still waits. The label is what a **servicing**
  actor wakes on, and that wake belongs to no row here — it is crew's to build
  ([crew#295](https://github.com/heavy-duty/crew/issues/295)), and until it
  exists the operator services the label by hand, which is today's cost minus
  the silence. How a red head is detected and kept quiet is the engine's
  mechanism, described in crew's `shared/README.md`, not here.
- **Build**: a `ready` **unclaimed** issue (an assignee means mid-claim, not
  pickable), or a completed review round on my PR — a changes-request with
  no panel review request still outstanding; whole rounds, never single
  verdicts, and never a round the check at its head does not support. The
  wake admits a **green** head, and a head with **no checks configured** —
  terminal, not transient, so holding there would retire the round rather
  than delay it. It holds a **red** head (already woken ci-red above) and a
  head whose check has **not finished** (opening the round there spends the
  panel on a head that may go red — crew#45's measured cost — and it admits
  itself a tick later once the check settles). Both holds are reported, not
  swallowed, and they are reported *differently*: only one of them is the
  author's own work to do.
- **Handoff**: a round of mine that converged — every panelist's latest
  opinionated review approves the current head, no panel request
  outstanding, mergeable right now, `state:needs-human` not already set.
  Convergence is computed from `latestOpinionatedReviews`, never
  `reviewDecision`, which stays empty without branch protection and silently
  stalled rounds for a day (ceremony#26, #39).
- **Rebase**: my PR `CONFLICTING` — and only `CONFLICTING`; `UNKNOWN` is
  GitHub's post-merge recompute flap and waits. A conflicting draft belongs
  to resume.
- **Worktree hygiene**: a `build/*` worktree is removed only when its branch
  has PR history and no PR on it remains open; a branch with no PR at all is
  an in-flight claim and stays.

#### The operator notifier — the `needs-ruling` queue

The operator notifier (`notify.sh`, a fleet singleton on the triage box; its
mechanism is crew's too) watches open PRs carrying `state:needs-human`. That
poll never reads `needs-ruling`, which lives mostly on *issues* — so an
escalation waits invisibly on the very human it names. Not hypothetical: on
2026-07-23 alone, three escalations spent their whole lives outside the
operator's view — [#16's fork-PR-workflows
question](https://github.com/heavy-duty/ceremony/issues/16#issuecomment-5053302689)
(raised 01:23Z, [ruled 09:24Z](https://github.com/heavy-duty/ceremony/issues/16#issuecomment-5056705884)
— eight hours in which the board showed a `claimed` issue indistinguishable
from a builder mid-build), [#56's R1–R3
escalation](https://github.com/heavy-duty/ceremony/issues/56#issuecomment-5057506832),
and [epic #50's own 13:04Z
flag](https://github.com/heavy-duty/ceremony/issues/50#issuecomment-5058713181),
which surfaced only because a human happened to look. This file records how
the fleet actually runs; that is why this wiring changed (#50 D16). The spec
for the engine-side update:

- **The second query.** Alongside the `state:needs-human` PR poll, `notify.sh`
  polls **open issues and PRs labelled `needs-ruling`** across every repo in
  `notify-repos.txt`, which is deliberately wider than the duty registry:
  a cross-repo handoff is precisely what the operator cannot discover alone.
- **One tracked message per item, edited in place** — the same
  one-message-per-item discipline the PR poll already uses, so an aging
  ruling reads as a **live queue**, not a feed. The message is removed when
  the flag comes off. Never one notification per rung: a rung crossing
  changes the text of the existing message and does not page again.
- **The message carries what makes the ruling decidable at a glance:** the
  item, the decision line (the escalation comment's first line), the flag's
  age, and the current rung.
- **Rungs are the message's content, never its trigger.** The four rungs are
  [the ladder's](https://github.com/heavy-duty/ceremony/blob/cb3d482b8be5c6563374a8c52159287fad43644d/LABELS.md#L94-L112)
  — **0–12h**, **at 12h**, **at 24h**, **past 24h** — with the age measured
  from the current episode's `needs-ruling` `labeled` event, the same anchor
  the board-side sweep reads. Division of labor: #73's sweep comments put the
  rungs on the board for the fleet; the notifier puts them in the operator's
  queue. Neither decides.
- **What is worth alerting on:** a `needs-ruling` past its stated `Default:`
  deadline, or standing past 24h, is the fleet-health signal — not the
  flag's existence. An escalation resolved inside its window is working as
  designed and deserves a quiet queue entry, not an alarm.

Nothing box-side ever sets, clears, or decides `needs-ruling` (#50 D9, D15):
the notifier and triage's past-24h wake above *report and pick up* what the
board already shows; the label itself moves only by the doctrine's hands.

The duty engine is crew's shared tree, one source deployed to every box.
Specs written in this file have a record of becoming engine: the attention
wake and the reviewers' request sweep both started here as paper (the sweep's
org-wide form was then retired by the 2026-07-25 scope ruling), and the
builders' ci-red wake above is the latest: written here as paper while
crew#64 was open, engine at the stamped SHA. Two rows are still on paper, and
both are `needs-ruling`: the notifier's queue — at that SHA, `notify.sh`'s
only label filter is `state:needs-human` — and triage's **past 24h**
detection row above, which the triage-signals bullet already marks. Earlier
counts here said "two" while silently excluding the second; naming them is
cheaper than a number that has to be recounted every time a wake lands.

### Conventions on the board

- `🔎 reviewing head <sha>` — a reviewer announces work before starting, so
  liveness is visible instead of hoped for.
- `⟲ resuming from <sha>` — a builder announces recovery after interruption;
  there is no session state to restore, so the recovery path *is* the normal
  path: read the board, continue from the worklog. Rebooting a box never
  loses work that was pushed.
- Checkpoint discipline (builders): open the PR as draft at the first commit
  with a `## Worklog` checkbox list; check off and push after every step.
  The board and the branch are the only memory.
- Claim ritual: comment on the issue + self-assign + label flip, before any
  branch exists.
- Handoff: the author closes an approved PR's round with a summary comment,
  flips `state:needs-human`, and requests the human — merging is never the
  fleet's job.
- Worktree isolation: builders build each PR in its own `git worktree`;
  reviewers check out PR heads in throwaway detached worktrees and remove
  them after the verdict. Main clones stay parked on the default branch,
  always clean.

## Where this is going

This wiring proved itself on day one (seven merged PRs, unanimous three-model
review convergence on #39, and a full-fleet crash recovery), and the plan it
carried has become **heavy-duty/crew** — a shared engine, CLI, operator
configuration model, real-host rehearsal and fixture tests — so standing up
a fleet is a bootstrap, not an archaeology dig. What remains is adoption:
crew#85 tracks the road to a `0.1.0` another operator can use without a fork.
Membership stays in the operator definition; this file remains the map of
what a wake means, and crew is the map of how it runs.
