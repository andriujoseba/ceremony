# Changelog

The curated history of the ceremony itself. Each release's section is
published verbatim as that release's body (lib/changelog.sh extracts it),
so entries say what changed, cite the issue, and stop — at most 300
characters each, guard-enforced on the PR that writes the fragment (#167);
a genuinely long change ships several short entries, never one long one.
The citation is guard-enforced too, and it closes the entry: one `(#N)`
group, then the final `.` and nothing after it (#262). Sections published
before that rule keep their prose; the guard reads fragments only.
Entries arrive as fragments — one `changelog.d/<issue>.md` per PR, never
an edit to this file — and the release PR assembles them into the next
section here (`bin/changelog-assemble`, #112).

## 0.6.2 — 2026-08-07

### Fixed

- `BUILDER.md` gives the parked-claim shapes the ordering they were missing:
  an operator-owned remainder parks the claim and never the handoff, so the
  state finishing the work puts you in cannot excuse the handoff it should
  follow (#336).
- A session does not block on a producer it cannot prove alive — where a job
  signals its own completion, that signal is the wake and the finished
  output is read afterwards (#336).

## 0.6.1 — 2026-08-06

### Changed

- `CONTRIBUTING.md` no longer enumerates the vendored set: both the doctrine
  convention's scope and the consumption section name and link
  `docs/VENDORED.txt`, so a seventh vendored doc is one edit to the manifest
  and the convention reaches it (#316).
- The two-consumption-modes framing in "How the other repos use this" is
  compressed to a lead that routes to the README, which now states it in
  full; the governed-repo list and the one-pin paragraph stay (#316, #311).

### Fixed

- `BUILDER.md` scopes the green-check precondition to the act it governs:
  where an engine mediates the request, declaring a round answered is not
  requesting the panel, so the declaration goes out as soon as the round's
  fixes are pushed (#330).
- The reason is stated where a builder reads it: the engine already holds
  the request while a head is pending or red, so an early declaration
  cannot produce an early request, while a withheld one is priced as
  silence (#330).
- `RELEASES.md` states what happens when a gate member lands `post-merge`
  with successors declaring on it: triage splits the remainder onto a fresh
  issue and closes the original on what it delivered (#329).
- The release edge is named — the original's close, never the remainder's,
  since each successor's declaration keys to the original's number (#329).
- The trigger is a check rather than a judgement, the blocker parse over
  open `blocked` bodies, and the picked-up exception keeps a claimed issue
  from being closed out from under its builder (#329).
- The rejected alternative is recorded with its three reasons, so teaching
  the blocker parse to count `post-merge` as landed is not re-proposed as an
  obvious simplification (#329).

## 0.6.0 — 2026-08-05

### Added

- The issue-flow sweep's `claimed`-branch ruling pre-read is pinned: an
  unassigned claim under `needs-ruling` must draw its board diagnostic and
  its ruling nudge in one sweep, so a read that drifts below the diagnostic
  reds instead of silently costing the escalation 7 days (#284, #307).
- The issue-flow sweep now flags a collision the board never declared: two
  open, unblocked issues whose titles name one deliverable draw a comment
  naming the newer's owed `Blocked by` edge. Keys normalize, so
  `actions/x` and `x` are one deliverable (#288).
- The sweep now flags an unblocked non-member during a standing release
  window, naming the window's invariant. `claimed` counts, PR in flight or
  not. The gate is read from the release issue's own `Blocked by`
  declarations, and an emptied gate leaves it dormant (#292).
- Both flags are advisory: comments only, no label write and no state
  change, deduped against each family's last word on the thread so a
  standing state re-sweeps silently (#293).
- The fragment guard now requires each entry to end with its issue
  citation: one `(#N)` group — local, `repo#N` or `owner/repo#N`
  references separated by `, ` — then the final `.` and nothing after it
  (#262).
- The refusal distinguishes an entry carrying no reference at all from one
  whose reference is present but not terminal, and names the shape to
  write in both (#262).
- The 300-character bound still outranks the citation across the whole
  fragment, and the outranked problem stays out of the message it lost
  to: one fragment, one diagnosis, wherever in the file it sits (#262).
- BUILDER.md now describes a fix round that rides a draft: the draft phase
  stays the builder's, ready-for-review is the builder's own act, and where a
  draft suppressed the checks green is proven at the flip (#258).
- REVIEWER.md now reads a draft carrying `state:addressing` as a fix round in
  progress rather than abandonment (#258).
- A `post-merge` item with no comment for 7 days now draws one nudge from the
  issue sweep: the wake evidence is owed. A starving criterion used to be
  found only when someone happened to run the right read (#254).
- Label churn does not reset that clock, and neither does an assignment: on
  `post-merge` an assignee is an invalid composition, not activity, and it
  must not buy the item another 7 days of silence (#254).
- The nudge names the triage actor from `triage-actors=`, not the human
  reviewer: `post-merge` is triage's completion queue, so the starved wake
  condition is triage's to answer (#254).
- It links the item and parses nothing from the body — which criterion
  starved is prose, and the machine never judges prose (#254).
- Like the ruling nudge it carries no idempotency marker on purpose: the
  comment is itself activity, so the rule self-rate-limits to one nudge per 7
  quiet days. Comment-only — no path here writes a label (#254).
- Release epics now announce release initialization when their declared dependency gates clear (#253).
- The issue sweep now echoes an issue's parsed `Blocked by` set as a comment
  whenever that set changes, so a readable-but-wrong declaration is visible in
  one sweep instead of days later, when a human happens to run the parser by
  hand (#252).
- The echo's marker carries the parsed set itself: an unchanged parse never
  re-posts on a 15-minute cron, and a changed one always speaks. Comment-only
  — no path here writes a label (#252).
- CI now refuses a root `*.md` declared in neither `docs/VENDORED.txt` nor the
  guard's short exemption list, so a new doctrine file can no longer reach a
  tag undeclared and stay invisible to every consumer's `docs-sync` (#251).
- The same guard reads the manifest the other way: every entry must resolve to
  a regular, non-empty, tracked file — no symlink, no directory, no `../`
  escape (#251).
- Document the optional, operator-ruled release-epic flow for governed repositories. (#248).
- Guard documentation availability markers against missing issue citations
  and release candidates that already ship the cited work (#238).
- The label and issue-flow sweeps now comment once per episode when
  `attention` targets a pull request or an unassigned issue, without
  retargeting the demand or changing labels or assignees (#232).
- Pull requests that promise `Refs #N` now fail a read-only, body-edit-aware
  guard if GitHub would close N through a keyword or sidebar link (#218).

### Changed

- `README.md` is rewritten whole from the current tree: the front page names
  the governance repo ceremony now is, routes to `docs/CONSUMERS.md`,
  `AGENTS.md`, `LABELS.md` and `RELEASES.md` rather than restating them, and
  keeps the operator's release runbook as its core, re-measured (#311).
- Standing release windows are dependency DAGs: every mint is placed in the window or behind it, and only current sources are `ready` (#292).
- TRIAGE.md now requires unconditional collision-edge chains when open issues
  carry the same deliverable, keeping the ready queue concurrently claimable
  (#288).
- TRIAGE.md now states its rules with bare record cites: the label-race and
  lifted-hold incident narratives leave the normative text while their
  operational rules remain complete (#282).
- `BUILDER.md` states its rules and cites their record bare: the incident
  narratives, the links into issue comments and the cross-repo issue cites
  leave the normative text, which no rule leaves with them (#281).
- CONTRIBUTING.md now keeps vendored doctrine self-contained: state the rule,
  retain at most one sentence of why, cite the local record bare, and leave the
  incident narrative in that record (#280).
- BUILDER.md's green ruled term now says which entry to read before it says
  what an entry means: a check's word at a head is its newest entry by start
  time, and a cancelled entry is not that word while the same check carries a
  non-cancelled one at that head (#276).
- A check whose every entry at the head is cancelled is unchanged — nothing
  survived to be its word, so it never reported and is not green — and the
  collapse mirrors `checks_state`'s carve-out rather than adding a class
  (#276).
- BUILDER.md's step 1 now rules the checkless head: no checks configured is
  nothing to wait for, and the request goes out straight away — stated once,
  in the ruled-term paragraph, with the draft-round restatement removed
  (#272).
- `README.md` and `RELEASES.md` derive `scope:docs`, and the
  `changelog-assembled`, `docs-sync` and `runner-isolated` actions and tests
  derive `scope:guards`; all five were mapped nowhere. The docs block matched
  a literal `README`, which this tree does not carry (#267).
- `lib/read.sh` and `lib/ruling.sh` derive `scope:labels` beside
  `scope:release-flow`. Both reconcilers share them, and a mixed file wears
  both labels rather than `lib/**` being re-carved into a row per file (#267).
- TRIAGE.md now tells every epic author to put its progress checklist under
  the literal `## Task list` heading, because any other heading is silently
  invisible to the completion sweep (#266).
- TRIAGE.md now scopes the no-assignee board bug to flagging an unassigned
  issue, while still directing triage to repair ownership instead (#264).
- `BUILDER.md` and `CHANGELOG.md` state the citation as guard-enforced
  rather than as house style, beside the 300-character bound it now sits
  next to (#262).
- Four fragments in flight gained a terminal citation; published sections
  are untouched, so no shipped prose is re-opened (#262).
- BUILDER.md's green ruled term now names its field: greenness is read from
  each check's `conclusion`, never its `status`, and *stale* means a check
  of a superseded head — not a same-head node whose `status` lags its own
  conclusion (#260).
- Consumer guidance: re-vendor tooling reads the pin's `docs/VENDORED.txt`,
  never a hardcoded list, so a new doctrine file propagates at the next
  ordinary pin bump with zero list edits (#251).
- Define the doors-unchanged drill record and an executable release-path list,
  so a release may reuse live evidence only when its door bytes are unchanged
  since the last rehearsed tag (#237).

### Fixed

- A roster edit no longer reds the whole suite: the labels-reconcile
  state-machine fixtures name their own panel instead of binding
  `.github/labels.conf` by slot (#304).
- Shrinking `panel=` to three had left that binding's third slot unbound, and
  `set -u` aborted the file before its first assertion — 217 assertions
  became 0, on `main` and on every branch cut from it (#304).
- The one case still reading the shipped roster asserts a property, not a
  size: it parses, and each member is recused from its own panel. Any
  `panel=` of one or more members leaves `test/run.sh` green (#304).
- `lib/attention.sh` locates as label machinery beside its two shelf-mates —
  `[scope:release-flow]` alone was a wrong answer of the class #267 measured
  — and the map learns the sweep workflow pair, the shared-lib tests, and
  seven enumerated test/guard surfaces (#302).
- Claiming a `needs-ruling` issue no longer buys its escalation another 7
  quiet days: the issue-side ruling clock reads comments alone — an
  assignment is the claim clock's fact — and LABELS.md now names what each
  surface's clock reads (#284).
- `scope:release-flow` no longer rides every pull request: `changelog.d/**`
  is out of its path map. Doctrine makes every behavior change write a
  fragment, so the glob labelled 20 of the last 20 PRs while 3 touched a
  release surface. `CHANGELOG.md` stays, as only the release PR edits it
  (#267).
- The issue-flow reconciler and its test now derive `scope:labels`, the scope
  that already names the taxonomy they reconcile (#267).
- Abort issue-flow reconciliation when the board read fails instead of reporting a complete pass over an empty or partial result (#257).
- The issue sweep no longer derives label writes from a read that failed. An
  HTTP 504 whose body is GitHub's JSON error object passed every guard and
  emptied the label set, so a healthy epic was written `needs-triage` and the
  pass reported success (#247).
- A failed comments read no longer reclaims a live claim. Swallowed, it dated
  the issue by `created_at` and unassigned the builder under a comment
  asserting 48 hours of silence about an issue commented on seconds earlier
  (#247).
- A failed comments read no longer reads as "no marker", which re-posted the
  comment the marker exists to suppress (#247).
- Every read inside the per-issue subshell is checked explicitly, on its
  status and on its payload shape; the issue is left exactly as it is and the
  sweep continues. A partial pass names its skipped issues after
  `reconciled.` (#247).
- A per-issue pass is now atomic: its writes and its log lines commit only
  once the pass completes. A skip could previously land after an earlier
  mutation, reporting an issue as untouched when a label had already been
  written or removed (#247).
- The issue-flow sweep now reads an issue's deliverable as the `Refs` PR that
  merged last, not the one numbered highest — merge order is not number order,
  and the old rule spent the transition marker on the wrong PR (#242).
- Preserve active claims when an open local pull request links them with `Refs #N`. (#241).
- `blocker:unrequested` no longer fires while a head's checks are pending or
  red: the review round forbids requesting there, so the one blocker that
  demanded an act flagged builders for complying. Pending is CI's move, red is
  `blocker:ci-red`'s (#236).
- `blocker:unrequested` now waits for the round to settle — the head and the
  newest verdict must have stood for `RECONCILE_UNREQUESTED_GRACE` (default
  300s) — so a sweep landing between a push and its re-request no longer flags
  a round in motion (#236).
- LABELS.md no longer claims nothing in `actions/` clears or reads
  `attention`: the reconciler has done both since the derived `claimed` →
  `post-merge` transition shipped. The amended text keeps the hand-set rule
  and admits the one clear and the diagnostic read (#231).
- Triage now puts `attention` on the assigned issue that owns a claim, never
  on its pull request, and treats an unassigned issue as a board bug rather
  than a demand (#230).

## 0.5.0 — 2026-08-03

### Added

- `labels.conf` accepts optional `panel[<login>]=` rows: the required set for
  a PR authored by that login is the row minus the author; other authors keep
  `panel=`. Consumers gain the row at their next pin bump — adding it before
  that bump is a parse failure that takes the label board down (#224).

### Changed

- Doctrine: third-party actions never hold a write-capable token by default —
  repo-owned scripts in write-capable jobs, established publisher plus
  full-SHA pin for the exception, SHA pins everywhere. Canonical in
  REVIEWER.md, short form in BUILDER.md; consumers adopt at the pin bump
  (#216).

### Fixed

- `ruling_escalation_row` selects the setter's best-shaped in-window comment,
  ties broken to the earliest, instead of the earliest outright — a whole-round
  reply landing seconds before the escalation is no longer graded in its place
  (crew#293).
- The escalation selector and `ruling_shape_decision` share one field-presence
  matcher, and an undecodable body column scores 0 instead of erroring the
  sweep.
- Five stale **unreleased** markers in `docs/CONSUMERS.md` now name their
  tags: fragment mode, `changelog-assembled` and `runner-isolated` at
  `0.2.0`; the additive labeler at `0.3.0`; the two-caller split at `0.4.1`
  (#221).
- The marker convention now names its clearing owner: the release PR that
  ships machinery clears, in that same PR, every marker its assembled
  section makes false (#221).
- A standing non-approving verdict now outranks draft in `decide_state`: a
  re-drafted PR mid-round reads `state:addressing`, a live panel request on a
  draft surfaces as `state:bots-reviewing`, and a draft with no round history
  still reads `state:building` (#205).

## 0.4.1 — 2026-08-01

### Changed

- The reconcile sweep is detached from PR-triggered runs: a new reusable
  `labels-sweep.yml` carries it, woken by `labels.yml`'s new `trigger` job, so
  a queue-displaced sweep cancels on the Actions tab instead of landing a
  cancelled `reconcile` check on a PR (#209).
- Labels consumers add a sweep caller (`labels-sweep.yml`, stub in
  docs/CONSUMERS.md), relocate the hourly cron and manual bootstrap dispatch
  to it, and grant the labels caller `actions: write`; a pin bump without the
  sweep caller goes loudly red at the trigger job (#209).

### Fixed

- `checks_state` drops rollup entries belonging to the workflow it runs
  inside — `SELF_WORKFLOW`, defaulting to the ambient `GITHUB_WORKFLOW` —
  before the newest-per-context collapse: the label machine never grades
  its own runs, and an empty name filters nothing (#208).
- A sweep displaced from the shared concurrency queue attaches CANCELLED to
  its PR while its successor attaches elsewhere, so the sweep set
  `blocker:ci-red` off its own displaced run and re-affirmed it every
  cadence (crew#227). A rollup of only self entries now honestly scores
  NONE (#208).

## 0.4.0 — 2026-07-29

### Added

- `changelog.d/shape` — an optional one-line sentinel, `flat` or `grouped`,
  that pins the fragment set's shape and outranks the newest-published-section
  inference; absent, the inference binds unchanged (#182).
- Add `post-merge` issue state for merged `Refs` work awaiting triage-owned verification.
- `changelog_fragment_problem` bounds every entry at 300 normalized
  characters, red on the PR that writes the fragment; the armed guard and
  the assembler inherit the one definition (#167).
- BUILDER.md and CHANGELOG.md state the bound and the split rule: a long
  change ships several short entries, never one long one (#167).

### Changed

- Labels automation docs now make sweep cadence a consumer-owned tradeoff,
  retain hourly as the engine-less default, and document manual dispatch as
  the operator's immediate full-board sweep (#203).
- `labels` — the reconcile cron relaxes from `*/15` to hourly (#199), cutting a
  private consumer's schedule-triggered full-board sweeps ~4× at GitHub's
  1-minute billing floor.
- `labels` — the hourly cron is the sweep's only wake for transitions no
  subscribed event carries — a verdict landing, blocker:ci-red, a
  blocker:conflict when another PR merges, the time-based stale/reclaim — so it
  bounds their latency to ≤1h, delaying no event-carried transition (#199).
- `labels` — the caller's `issues:` trigger narrows to
  `[opened, closed, edited, reopened]` (#199), the actions that carry a
  queue-state change the cron cannot wait a cadence for. The churn/validation
  actions — labeled/unlabeled/assigned/unassigned — come off; the PR handoff
  wake is unaffected.
- `labels` — each caller trigger now carries a comment saying why it is
  subscribed, and reconcile keeps `cancel-in-progress: false` (#199) —
  cancelling a sweep mid-board is the race that guard exists to prevent.
- `CONTRIBUTING.md` now points to `BUILDER.md` for the shared PR flow instead
  of restating doctrine that can drift, while retaining ceremony's roster and
  other repo-specific facts (#198).
- Builder doctrine makes each whole-round reply the durable Round log record
  mirrored by the engine, leaving handoff as a mechanical facts-only step
  instead of a newly composed summary (#196).
- `FLEET.md` removes its duplicate bench roster, records crew as a general
  operator-configured tool, and advances its whole-file audit stamp to
  `crew@eaeb302` with every surviving crew link re-pinned (#193).
- `FLEET.md` keeps the registry's authorization rule and its crew#16/crew#66
  provenance, while replacing duplicated mechanism and path claims with a
  pinned pointer to crew's registry header (#192).
- `BUILDER.md` gates both review-request points on a green check at the
  head, carries crew#45's argued exception for failures outside the PR,
  and states the ruled classification: cancelled and stale are not a
  green head; skipped and neutral are (#189).
- `BUILDER.md` documents CI-red recovery in pickup precedence: a red head
  of your own PR is picked up before claiming another issue, is never a
  parked claim, and follows crew#17's recovery path (#189).
- `FLEET.md` writes the ci-red wake into the duty order between resume
  and build, now as deployed engine rather than on paper: the
  reconciliation stamp advances to the crew SHA carrying crew#64 (#189).
- `FLEET.md` describes the build wake's check gate as the engine
  implements it: a green head, or one with no checks configured, opens a
  round; a red head and an unfinished one are held and reported
  separately (#189).
- `FLEET.md` corrects the attention wake to the crew#66 ruling: the query
  is cross-repo, the action is registry-bounded, and an out-of-scope
  demand is reported and escalated to the operator rather than worked. It
  no longer claims attention is exempt from the registry (#189).
- `FLEET.md` distinguishes an attention session that dies before acking,
  which relaunches, from one that completes without acking, which is a
  decline a ledger keeps from re-firing (#189).
- `BUILDER.md` re-requests by head, not by verdict: a push while
  answering a round stales every approval, so every panelist is
  re-requested; only an unchanged head re-requests the non-approvers
  alone (#190).
- FLEET.md's duty-loop mechanism is a pointer to crew's shared engine; the
  wake lists follow the engine's duty order, the roster keeps the as-built
  bench beside `fleet.roster`'s target, and the reconciliation stamp names
  crew@`01fb49c` (#187).
- Ceremony's changelog is grouped from this release forward: the pending
  fragments carry `### ` headings under a `grouped` sentinel (#182).
- BUILDER.md: a park declaration stands until its facts change — a
  nothing-changed resumption posts nothing; only a no-open-PR park owes a
  refresh, inside the 48-hour reclaim window (#178).
- Private-repository label callers document `actions: read` alongside checks and statuses for workflow-run check-rollup nodes (#173).

### Fixed

- FLEET.md no longer says a review request outside the registry is
  authorization: `repos.txt` is the scope for the review queue, out-of-scope
  requests are logged and never acted on, and the attention wake is stated
  as the one registry-independent exception, by design (#187).
- `blocked_reference_records` unions every `Blocked by` clause in the body
  instead of binding to the first marker occurrence — a repeated declaration
  no longer promotes on its first sentence alone, and earlier prose that
  merely mentions being blocked no longer hijacks the parse (#184).
- `decide_state()` refuses `state:needs-human` while the hand-set `blocked`
  label stands — the PR falls to `state:addressing`, exactly parallel to the
  `needs-ruling` exclusion; never emitted by `blockers()` (#180).

## 0.3.0 — 2026-07-24

- Make `changelog-armed` reject fragment shape drift on the PR that introduces it.
- A directive hold now has a written ending, not just a beginning: BUILDER.md's shape 5 says the hold ends where it began — on the labels — with the hold owner's most recent queue-label event governing over any stale prose, the timeline read (`gh api .../issues/{n}/timeline`) named as the move before standing down or up on a hold, a claim against stale prose required to cite the events it read, and a refused claim given its two exits. TRIAGE.md now requires re-reading label events before asserting label-borne state in prose, and makes correcting a lifted hold's stale body header triage's move in the same tick. On 2026-07-24 the unranked signals split two builders reading one board (#149, #151); both acted defensibly — the doctrine, not the builders, lacked the rule (#154).
- Doctrine names the second `Closes #N` exception: a same-repo PR whose
  authorizing issue marks an acceptance criterion post-merge uses `Refs #N`,
  and triage closes the issue by hand on the evidence — merging #143
  auto-closed #137 with exactly such a criterion unmet, and no role had been
  told otherwise. TRIAGE.md now requires a post-merge criterion to carry its
  own mechanism (post-merge, triage closes, `Refs #N`), REVIEWER.md lists
  `Refs #N` beside `Closes #N` and `Part of <owner>/<repo>#N` and stops
  treating the reference-only PR as a defect, and CONTRIBUTING.md points at
  BUILDER.md as the rule's one home (#151).
- FLEET.md — the Reviewers wake describes the deployed sweep, not the `gh search` trigger the bench replaced: the pulls-API `requested_reviewers` sweep across the org plus the named bot forks is source 1, the `repos.txt`/search poll an adds-only backstop, and the two are merged and deduplicated by (repo, PR) before acting. Only the notifier's `needs-ruling` queue remains on paper; `repos.txt` is the registry only on the triage box; and the Status block now stamps the crew ref the file was last reconciled against (#149).
- REVIEWER.md now carries the review mechanics every box had been re-deriving from an incident: the queue comes from the API and not the search index, every write is one-shot per (reviewer, PR, head), heads are reviewed in throwaway checkouts, a pinned consumer's config is verified at its pin, and a verdict names the checks its box could not run (#145).
- The `docs/CONSUMERS.md` labels-caller stub lists the same `issues:` types
  as ceremony's own caller — `edited` and `reopened` included — so a consumer
  adopting the stub wakes when an issue body's `Blocked by #N` declaration is
  edited, and when a closed issue re-enters the queue wearing labels derived
  at close. The two lists drifted apart inside PR #32; a parity test now pins
  them together, red if either file drops a type or the lists diverge.
  Adopting the widened list is a stub edit riding the pin bump to the first
  tag carrying this change (#144).
- `labels-reconcile` — a queue-cancelled duplicate check is discarded when its context holds a real verdict, so a sibling PR's eviction no longer reds a green PR; an all-cancelled context still blocks (#139).
- `blocker:unrequested` now clears the moment the panel is asked: the labels
  caller (and the `docs/CONSUMERS.md` stub) listens on `review_requested` and
  `review_request_removed`, so the one event that falsifies the label — or
  makes it true again — wakes the reconcile sweep instead of waiting for an
  unrelated push or the advisory cron. The `scope` job skips both events:
  they change no paths, and running the labeler on them widens the #130
  clobber window. Adopting the new triggers is a stub edit riding the pin
  bump to the first tag carrying this change (#137).
- `drills/README.md` no longer tells the builder to delete the scratch repo —
  a step no fleet identity can perform, because `delete_repo` is deliberately
  absent from bot tokens. The builder's end state is **archive**
  (`archived: true`, inside the `repo` scope); the delete is the operator's,
  and cleanup gates nothing — not ready-for-review, not the panel, not the
  merge. The drill record now names the scratch repo by `owner/name` and
  states the disposal its author actually observed, never one that has not
  happened: both 0.2.0 drills hit the missing-scope wall independently, one
  stalling a release draft on an impossible 403, the other shipping a record
  asserting a delete that never ran (#135).
- `lib/facts.sh` — a repository's first push to `main` (a root commit with no first parent) now reads `base_ver=(none)` and lets decide's table govern, instead of dying at exit 128 before establishing a fact; the no-base path skips the base fetch and `git show`, and an unresolvable head still fails loudly (#134).
- The changelog rule now explains why release PRs write no fragment and how entry-worthy changes land instead (#131).
- `actions/labels-scope` replaces `actions/labeler@v5` in the labels workflow's scope job: labeler wrote the whole label set (`PUT`) even under `sync-labels: false`, silently removing any label applied while it ran — #128 lost its `release` that way — so the scope job now derives from the same `.github/labeler.yml` mapping (the `changed-files`/`any-glob-to-any-file` shape, block or flow; anything else refuses loudly) and its only write is an additive `POST`. The reconcile sweep also warns — never sets — when a non-draft PR is release-shaped (bare version differing from its base) but carries no `release` label (#130).

## 0.2.0 — 2026-07-24

- `test/changelog-assembled.test.sh` — keep the trio interaction aligned with fragment mode: a dropped entry makes armed red too, while a hand-edited section leaves assembled as the sole red (#126).
- `actions/changelog-assembled` — a release PR's stamped section must be byte-for-byte what the fragments it consumed assemble to, replayed from the merge base; inapplicable trees pass with a NOTICE (#116).
- `changelog-armed` — treat `changelog.d/` as the arming, validate every development fragment, and require bare releases to consume the directory into their exact publishable section (#115).
- `lib/changelog.sh` + `bin/changelog-assemble` — read the `changelog.d/` fragments, assemble one release section (canonical group order, one shape per repo), and consume exactly what was published (#114).
- BUILDER.md — the directed hold is the parked claim's fifth shape, its attention demand is acknowledged in the declaration comment, and its board bookkeeping covers in-flight work; TRIAGE.md no longer excludes it (#113).
- Ceremony adopts `changelog.d/` — a PR writes one fragment per issue instead of editing `CHANGELOG.md`, the release PR assembles the section, and `## Unreleased` is gone (#112).
- BUILDER.md — the handed-off PR is the parked claim's fourth shape, its handoff is its declaration, and shape 2 covers the round awaiting its first verdicts (#109).
- `labels-reconcile` — warn once per sweep when a repository lacks labels declared by the pinned core taxonomy (#105).
- `LABELS.md` — drop the vendored scope-table enumeration; the per-repo set lives in `.github/labels.conf` and the repo's own CONTRIBUTING (#104).
- `labels-reconcile` — a degraded mergeability/checks read now logs gh's actual stderr (collapsed, bounded) beside the byte-identical counted line, and the blind-sweep warning leads with the observed reason instead of asserting the permissions cause (#101).
- Changelog publication — count entries instead of bytes, refuse dangling grouped headings, and seed grouped re-arms with Added/Changed/Fixed (#98).
- `labels-reconcile` — grant callers private-repo check reads and warn when an entire PR sweep is blind (#95).
- `labels-reconcile` — the bootstrap now retires the six GitHub defaults `LABELS.md` publishes as deleted, tolerating both an already-absent label and a refused delete (#93).
- `issueflow-reconcile` — a triage-authored issue arrival stands down with exit 0 instead of killing the run before the sweep (#91).
- FLEET.md — the assignee's `attention` wake: one role-independent trigger ahead of every per-role list, one acked session per demand; a spec on paper until `duty.sh` polls it (#86).
- `attention` doctrine — define its assignee-owned pickup, ack, queue and clock semantics across labels, triage, and builder roles (#85).
- `attention` — add the issue-only, hand-set assignee-demand flag to the core label taxonomy (#84).
- One issue at a time counts build work in flight: the parked claim's three shapes, its declared-never-inferred comment, and triage's duty to name a directed hold as a park (#77).
- FLEET.md — the operator notifier's `needs-ruling` queue (one tracked message per item, edited in place across the rungs) and triage's past-24h wake condition; a spec on paper until an operator updates the box (#74).
- The sweep observes the escalation contract: a malformed escalation is named field-by-field, and the ladder's 12h/24h rungs each draw one comment to the flag-setter — comment-only, per-episode, both surfaces (#73).
- Ruling doctrine — define every human-owned trigger, the fixed escalation shape, and the 0–24h builder-to-triage ladder (#72).
- `issueflow-reconcile` — nudge once when an `offsite` flag outlives every visible cross-referenced PR (#69).
- `offsite` — protect claimed issues whose PR lives in another repository from the claim-reclaim clock (#68).
- `issueflow-reconcile` — keep cross-repo references out of local dependency decisions and require triage to resolve cross-repo blockers by hand (#61).
- `actions/runner-isolated` — a `pull_request`-triggered job may never run on a self-hosted runner (#58).
- Cross-repo doctrine: the panel is the PR's repo's roster, a review request is authorization but not panel membership, and `Part of <repo>#N` replaces the `Closes #N` that cannot cross repos (#57).
- The sweep's `needs-ruling` invariants, one implementation for both surfaces: the issue-side staleness exemption, the bare-flag check (comment-only, the label is never removed), and the 7-day nudge to the decider (#52).
- `needs-ruling` — the cross-cutting flag for a pending human decision, excluded from `state:needs-human` and from the staleness sweep (#51).

## 0.1.0 — 2026-07-22

- `lib/version.sh` — one version abstraction, `file` and `package-json` backends (#3).
- `lib/changelog.sh` + `bin/changelog-section` — the one canonical changelog-section extractor (#4).
- `actions/changelog-armed` — the version-keyed arming guard (#5).
- `actions/changelog-monotonic` — shipped release headings are append-only: no deletion, no duplication (#6).
- `actions/drill-recorded` — a release tree must carry its drill record (#7).
- `lib/decide.sh` — the merge door's five-state decision, pure and exhaustively tested (#8).
- `.github/workflows/release.yml` + `lib/facts.sh` — the reusable two-door release workflow (#9).
- `.github/workflows/labels.yml` + `actions/labels-reconcile` — label taxonomy bootstrap and PR-state reconciliation (#10).
- Ceremony adopts its own ceremony: `VERSION`, this changelog, the drill doctrine, the self-callers, and the self-guards in CI (#11).
