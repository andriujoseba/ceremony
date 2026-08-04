# ceremony

The heavy-duty family's **governance repo**: the machinery every repo in the
family runs, and the doctrine every agent in the family reads. Implemented
once here, tested once here, consumed everywhere else — the machinery never
copied at all, the doctrine only as a mirror a guard keeps byte-identical to
the pin.

Two kinds of thing live in this tree, and they are consumed in two different
ways because they have two different runtimes.

**Machinery is consumed by reference, at a pin.** The reusable workflows in
[`.github/workflows/`](.github/workflows/) and the composite actions in
[`actions/`](actions/) are fetched by GitHub at run time from the ref the
caller pins; no copy exists in the consumer. That machinery is two systems.
The **release ceremony** — [`release.yml`](.github/workflows/release.yml),
the decision and fact libraries under [`lib/`](lib/), and the guard actions
that keep a release honest — is the operator-facing half, and the runbook
below is its documentation. The **label and issue-flow machine** —
[`labels.yml`](.github/workflows/labels.yml) and its detached sweep half
[`labels-sweep.yml`](.github/workflows/labels-sweep.yml) (split in #209),
driving [`labels-scope`](actions/labels-scope/),
[`labels-reconcile`](actions/labels-reconcile/) and
[`issueflow-reconcile`](actions/issueflow-reconcile/) — converges PR state
and the issue work queue. What its labels *mean* is
[LABELS.md](LABELS.md)'s contract, not this page's.

**Doctrine is consumed as a machine-verified mirror.** A document's only
runtime is an agent reading the working tree it stands in, and a doc that
needs a cross-repo fetch before it governs is a doc that sometimes goes
unread. So the agent-facing set — the files named in
[`docs/VENDORED.txt`](docs/VENDORED.txt) — is vendored into each governed
repo at `.ceremony/`, byte-identical to this repo at the pinned ref, by
[`actions/docs-sync`](actions/docs-sync/). A CI guard diffs the mirror
against the pin on every PR: hand-editing a vendored file, or bumping the
pin without re-syncing, goes red. It is a copy that cannot drift, which is
the only kind of copy this org allows. This README is deliberately *not* in
that set — a consumer's router is its `AGENTS.md`, not this repo's front
page — and [`.github/scripts/vendored-check.sh`](.github/scripts/vendored-check.sh)
records that reason beside the three other ceremony-only root docs.

**One pin governs both halves.** The ref a repo's workflow callers name is
the ref its `.ceremony/` mirror is verified against, so a process change
rolls out as one reviewed PR per repo: the pin line plus the re-synced
mirror, checked by the same guard.

## Where to go

- **Adopting ceremony, or converting a repo that carries its own copy** →
  [docs/CONSUMERS.md](docs/CONSUMERS.md) — the bootstrap and conversion
  checklists, the caller stubs, the pin-bump procedure.
- **Working in this repo as an agent** → [AGENTS.md](AGENTS.md) routes you
  to your role file ([TRIAGE.md](TRIAGE.md), [BUILDER.md](BUILDER.md),
  [REVIEWER.md](REVIEWER.md)); [CONTRIBUTING.md](CONTRIBUTING.md) carries
  this repo's own specifics — the review panel roster, the `scope:*` set,
  the code and doctrine conventions.
- **The board: what a label means, and who may set it** →
  [LABELS.md](LABELS.md). It is the shared state machine; misusing one label
  lies to every other agent on the board.
- **Family release windows — what ships together, and when** →
  [RELEASES.md](RELEASES.md).
- **How the operator fleet is actually wired** → [FLEET.md](FLEET.md), a
  descriptive snapshot rather than doctrine.
- **Operating a release, or staring at a red run on main** → read on.

## What a release is

**A release is a PR, and merging it ships it** (box#96, building on box#83;
rig#47, cast#111 converged on the same doctrine). The ceremony PR —
`release: X.Y.Z`, carrying the hand-set `release` label — makes three
stamps:

1. **The version goes bare**: `X.Y.Z-dev` → `X.Y.Z`
   ([lib/version.sh](lib/version.sh)).
2. **The changelog section is assembled — one edit, produced by the tool**
   (#112). Entries never accumulate in `CHANGELOG.md`: each PR wrote one
   fragment file, `changelog.d/<issue>.md`
   ([the directory's marker](changelog.d/README.md) names the doctrine), and
   the ceremony PR runs [bin/changelog-assemble](bin/changelog-assemble) —
   by hand, on purpose, so the section lands in the PR's diff where the
   panel reads it (#112 D12; a consumer's exact invocation is in
   [docs/CONSUMERS.md](docs/CONSUMERS.md#assembling-a-release-section)). The
   tool folds every fragment into a new `## X.Y.Z — DATE` section on top and
   deletes the fragments it consumed; the
   [assembled guard](#changelog-assembled--the-stamp-is-exactly-the-fragments)
   replays that run and refuses a stamp that is not byte-for-byte the
   fragments' assembly.

   There is no second edit: the old stamp *re-armed* — put an empty
   `## Unreleased` back on top — because every PR inserted at that one
   shared anchor, and between the stamp and the re-arm a PR authored
   *before* the release landed its entry under whatever now occupied the
   position — **the section that just shipped** — cleanly, no conflict, no
   signal (box#108; confirmed cross-repo as rig#66). Fragments make that
   failure structurally impossible rather than guarded-against: a fragment
   merged after the release simply sits in the directory and is assembled
   into the *next* section. There is no anchor left to misplace, and nothing
   to re-arm — the directory is always armed.

3. **The drill record is present**: `drills/X.Y.Z.md`, non-blank — the
   evidence the release rests on ([the drill doctrine](#the-drill-doctrine)).

(This repo's own ceremony adds a fourth stamp: `CEREMONY_SELF_REF` — the ref
consumers' runs fetch this repo at — moves to the version being released, in
[release.yml](.github/workflows/release.yml#L123-L132) and every other
workflow that carries it.
[self-ref-check.sh](.github/scripts/self-ref-check.sh) fails CI here, not a
consumer's release, when it is stale.)

**The merge is the ship decision; the tag is transcription.** After the
merge, [release.yml](.github/workflows/release.yml#L136-L301) asserts its
way to certainty, tags the merge commit, publishes the GitHub release with
the version's own changelog section as the body — the curated prose, never
the generated PR list ([lib/changelog.sh](lib/changelog.sh) is the one
canonical extractor, and [bin/changelog-section](bin/changelog-section) is
its command-line face) — and, on the bare-`X.Y.Z` path, re-arms main by
bumping to `X.Y.(Z+1)-dev`; the version is the only re-arm left, the
changelog needs none (#112). An rc ships too, and its next version is a human
decision rather than arithmetic, so the re-arm stops for you to make it
([The re-arm refused](#the-re-arm-refused-releaseyml)). The machine does the
transcription because humans err silently and machines fail loudly:
**everything asserts its way to certainty and fails loudly, creating
nothing** — a wrong release is worse than a missing one, so every assert in
this file fires *before its door creates anything*, and one that fails leaves
zero artifacts of the run's own: no tag it made, no release, no bump. Three
steps run past the tag, and what a failure at each leaves behind is what
sorts them. Two fail before the release exists: the consumer's
[artifact hook](docs/CONSUMERS.md#the-artifact-hook) sits between the tag and
the publish, so its non-zero exit aborts, and the publish itself
([`gh release create --verify-tag`](.github/workflows/release.yml#L246-L258))
can fail on the API call or the assets. Either leaves the same state — a tag
standing and no release — which the
[nothing-exists assert](#the-merge-door-refused-releaseyml) names and the tag
door recovers. The third is the re-arm, which runs after the publish, and its
refusal is the single failure in this file that leaves a real release behind.

## The two doors

- **The merge door — the paved road.** A push to main runs the
  [decide table](#what-happens-when-my-pr-lands-on-main); a merged,
  `release`-labeled PR whose version transitioned to bare is the ceremony,
  everything legitimate that isn't one is a green no-op, and every
  half-ceremony dies loudly
  ([release.yml](.github/workflows/release.yml#L136-L301)). Use it for every
  normal release.

- **The tag door — the fallback and the backfill.** A bare `X.Y.Z` tag push
  — **no `v` prefix**, box's 0.6.0 set the scheme
  ([release.yml](.github/workflows/release.yml#L303-L371)) — publishes the
  same way. The tag is the operator's explicit act, so there is no decide
  and no label check — what is left is two asserts: **the tag names the
  tree's own version**
  ([L328–L339](.github/workflows/release.yml#L328-L339)) and **the tagged
  tree carries a publishable `## X.Y.Z` section**
  ([L340–L352](.github/workflows/release.yml#L340-L352)); either failing
  refuses, creating nothing. No `-dev` bump either
  — the fallback does not rewrite main (cast's precedent). Use it when the
  merge path is red, for backfills, and for the
  [first-release edge](#what-happens-when-my-pr-lands-on-main) (row 4).

Tag + publish (+ the consumer's artifact hook) happen **in the same job, on
purpose**: a `GITHUB_TOKEN`-created tag fires no workflows (GitHub's
anti-recursion), so the merge door's tag can never re-enter the tag door and
double-publish — and that job is the release's only chance to publish (#1
constraint 2).

## What happens when my PR lands on main

The merge door runs on **every** push to main, and the `release` label
legitimately means two things (release ceremonies, and ordinary work *on*
the release machinery), so the door's first act is a decision: the six-row
table in [lib/decide.sh](lib/decide.sh#L29-L61) (issue #8 — the comment
block *is* the spec, and the table is contract-tested offline by
[test/decide.test.sh](test/decide.test.sh)). Rendered for operators:

| # | the tree your merge produced | the run | what it means — and your move |
|---|---|---|---|
| 1 | version `-dev`, unchanged | green `NOTICE`, no-op | Almost every PR — including release-flow work under the `release` label. Nothing to publish, nothing to do. |
| 2 | version changed, still `-dev` | green `NOTICE`, no-op | The post-release bump, or a renumber. "A dev tree is by definition not a release." Nothing to do. |
| 3 | version bare, unchanged, already released | green `NOTICE`, no-op | The post-release window: the ceremony landed, the `-dev` bump hasn't. Nothing to do. |
| 4 | version bare, unchanged, **never released** | **red, nothing created** | The label says ship but this PR did not mint the version. Mislabeled → drop the label. Meant to release → it forgot the bump; re-do the ceremony PR. A repo whose first version never carried `-dev` ships its first release by the **tag door** — the known first-release edge (cast#111; [lib/decide.sh](lib/decide.sh#L70-L74)). |
| 5 | version transitioned to bare, **no merged `release`-labeled PR** behind the commit | **red, nothing created** | A transition nobody declared — a release is a labeled ceremony PR, not a bare push. Label a proper ceremony PR and re-do it, or publish by the tag door if the tree is genuinely right. |
| 6 | version transitioned to bare, merged `release`-labeled PR behind the commit | **the ceremony** | Tag → notes → publish → `-dev` re-arm. Your move afterwards: verify the release exists and main reads `X.Y.(Z+1)-dev`. **Read *bare* as decide reads it** — anything not `-dev` ([lib/decide.sh](lib/decide.sh#L108-L110)) — so an rc transition is a shippable ceremony here too, and the release lands but the re-arm stops for you to pick the next version ([The re-arm refused](#the-re-arm-refused-releaseyml)). |

The green rows are the point as much as the red ones: the machinery must be
safe to work on, so every legitimate non-ceremony is a green `NOTICE` no-op,
never a red run on main per infra PR
([lib/decide.sh](lib/decide.sh#L6-L12)). The label is hand-set intent and
automation never guesses; the version transition is the interlock, and
label-without-transition (row 4) and transition-without-label (row 5) both
refuse (#1 constraint 8).

## The guards

[`actions/`](actions/) holds ten composite actions. Three belong to the
label machine named above and are not the operator's business here. Of the
remaining seven, a consumer's own `ci.yml` carries **five** guard steps —
`changelog-armed`, `changelog-monotonic`, `changelog-assembled`,
`drill-recorded` and [`runner-isolated`](actions/runner-isolated/), the last
asserting that no `pull_request`-triggered workflow names a self-hosted
runner (#58) — plus [`refs-not-closing`](actions/refs-not-closing/) in its
own [`refs-guard.yml`](.github/workflows/refs-guard.yml) caller, because
body edits are load-bearing there (#200, #218), and
[`docs-sync`](actions/docs-sync/) once the repo adopts the agent team flow.
The exact steps and their pin-availability rules are in
[docs/CONSUMERS.md](docs/CONSUMERS.md).

The four below are the release's own, and this is the operator's cut of
them. Shared shape: version-keyed where the tree's state matters, loud where
it fails, and **a file of its own so a test can drive it**. The full war
stories are in the scripts' header comments — authoritative and longer than
this.

This repo eats what it serves: [`ci.yml`](.github/workflows/ci.yml) runs the
guard actions against its own real tree, and
[`release-exercise.yml`](.github/workflows/release-exercise.yml) replays the
merge door's step sequence on every PR.

### changelog-armed — main never sits disarmed

**The rule** ([actions/changelog-armed/changelog-armed.sh](actions/changelog-armed/changelog-armed.sh)),
keyed on the tree's shape, then its version. In **fragment mode** —
`changelog.d/` exists, the arming property moved onto the directory (#112
D7):

- always → the marker `changelog.d/README.md` must exist (what keeps the
  directory tracked when it holds no fragments), no `## Unreleased` section
  may survive in `CHANGELOG.md` (a second anchor with no owner), and every
  fragment must be publishable on its own — named `<issue>.md` or
  `<repo>-<issue>.md`, no `## ` heading, at least one bullet, no `### `
  heading without an entry. A malformed fragment fails the PR that wrote it,
  not the release that consumes it (#112 D9).
- `-dev` tree → nothing more. The directory **is** the arming: the next PR's
  entry is a new file, and a new file always has somewhere to land.
- bare tree (the ceremony PR and its merge) → every fragment must be
  consumed, and the top section must be the stamped, publishable section for
  exactly that version. Fragment mode has no re-armed shape — there is
  nothing left to re-arm.

In **legacy mode** — no `changelog.d/` — the version-keyed rules stand
verbatim; both shapes stay supported so a consumer adopts fragments on a pin
bump, on its own schedule (#112 D8):

- `-dev` tree → the top section **must** be `## Unreleased`.
- bare tree (the ceremony PR and its merge) → the top section may be
  `## Unreleased` (re-armed) *or* the stamped section for exactly that
  version — **and** that version's section must exist, carry at least one
  `-` or `*` entry, and have no `### ` heading without an entry before the
  next heading or section end. A heading is not an entry. These publication
  rules do not apply to `Unreleased`: the empty three-heading template is
  deliberately valid there (the half-ceremony refusal, rig#67: version
  bumped, stamp missing — asserted through the very extractor the publisher
  uses, so the two cannot disagree about what a section is).

**The incident**: box#108 / rig#66 — the silent mislanding described
[above](#what-a-release-is). Fragment mode retires the incident's mechanism
outright; legacy mode guards it. **Red means** a PR entry has nowhere safe
to land — a missing marker, a surviving `## Unreleased`, a malformed
fragment — or a stamped version would publish no entries, a dangling grouped
heading, or a bare tree still carrying fragments the stamp did not consume
(`not consumed` — re-run the assembler); the message names the fix in every
case. What this guard cannot see is a fragment that *was* consumed but whose
entry the stamp omits — the fragment is gone from HEAD, so only
[changelog-assembled](#changelog-assembled--the-stamp-is-exactly-the-fragments)'s
merge-base replay catches that loss.

**Do not "simplify" this to "always require `## Unreleased`".** The
unconditional form is false by construction on the ceremony PR's own tree —
it makes every release unshippable — and rig#44 and cast#108 both had to
revert exactly that. The version-keyed form is what rig and cast get back by
adopting this repo.

One consequence worth knowing before it happens, legacy mode only: a
ceremony PR that stamps and forgets to re-arm still passes this guard — a
bare tree is allowed to be stamped. It goes red **the moment the automatic
`-dev` bump lands on main**. The guard does not block the release; it
refuses to let main *sit* disarmed, which is the window a late PR falls
into. Fragment mode has no such window: with no re-arm step there is nothing
to forget.

### changelog-assembled — the stamp is exactly the fragments

**The rule**
([actions/changelog-assembled/changelog-assembled.sh](actions/changelog-assembled/changelog-assembled.sh)):
on a release PR in fragment mode, the stamped `## X.Y.Z` section must be
**byte-for-byte** what the fragments it consumed assemble to. The guard
reads the fragments as of the merge base (they are gone from HEAD — that is
the point of the ceremony), replays `changelog-assemble --check` over that
set, and diffs the result against HEAD's section body. Every tree it does
not apply to — a `-dev` tree, legacy mode, no consumed fragments — passes
with a green `NOTICE`, so a non-ceremony PR is never red here.

**The failure it catches** (#116): assembly is a hand-run step by design —
the section must land in the PR's diff where the panel reads it (#112 D12) —
and a mis-run hand step can leave no trace. The two failure shapes differ,
and the guards split them exactly as
[test/changelog-assembled.test.sh](test/changelog-assembled.test.sh)'s trio
rows record: leave a fragment **out of the deletion** and it survives on
HEAD, where [changelog-armed](#changelog-armed--main-never-sits-disarmed)
already refuses the bare tree (`not consumed`) — this guard goes red too,
naming the entry the section lost. But **delete** a fragment while omitting
its entry from the stamp, or hand-edit one word of the assembled prose, and
nothing on HEAD is out of place: armed is green, monotonic is green, and the
publisher would happily publish history that is not what the authors wrote.
Only the merge-base replay catches those. The replay is what makes a
hand-run step safe. **This guard needs history** — same stance as the
monotonic guard: `fetch-depth: 0`, and in CI an unresolvable base is a hard
failure, not a skip.

### changelog-monotonic — shipped headings are append-only

**The rule**
([actions/changelog-monotonic/changelog-monotonic.sh](actions/changelog-monotonic/changelog-monotonic.sh)):
the set of `## X.Y.Z` headings on your branch must be a **superset** of the
set at the merge base, and no heading may appear twice on HEAD. The rule
needs no tuning because release headings are append-only by doctrine: the
ceremony adds one and nothing ever legitimately removes one — so superset
has no exception to carve. The ceremony's own stamp passes by construction:
the assembler writes a new `## X.Y.Z — DATE` heading and removes none.
Fragment mode changes nothing here (#112 D10): fragments add no `## `
heading, and `Unreleased` was never in the guard's set — it is not a version
heading; it is
[changelog-armed](#changelog-armed--main-never-sits-disarmed)'s business —
which is why a repo's adoption PR can delete it and stay green.

**The incidents**: box#122 (caught in review of box#118) — an author adding
an entry under `## Unreleased` **replaced** the heading below it instead of
inserting above it; git merges that cleanly, and the shipped section's body
is silently absorbed into `## Unreleased`. And box#118 itself — a bad rebase
*duplicated* a shipped heading, which containment is blind to, which is why
uniqueness-on-HEAD is a separate assert.

**Red means** a shipped section was deleted (put the heading back and insert
**above** it) or duplicated (collapse to one heading; the failure message
walks through both fixes with the diff to run). **This guard needs
history**: the consumer's checkout must use `fetch-depth: 0`, and in CI an
unresolvable base is a hard failure, not a skip — a guard that can quietly
stop guarding is the failure shape this family of checks exists to refuse.

### drill-recorded — a release carries its evidence

**The rule**
([actions/drill-recorded/drill-recorded.sh](actions/drill-recorded/drill-recorded.sh)),
keyed on the tree's version: a `-dev` tree passes with nothing to assert (a
development tree ships nothing); a bare tree — the ceremony PR and its merge
— must carry `drills/<version>.md` with at least one non-whitespace
character. One file per version, so `0.9.0.md` and `0.9.0-rc1.md` are simply
different files and prefix confusion is unrepresentable (#1 constraint 7).

**The incident**: box's CONTRIBUTING said since box#96 that the release
ritual must be run and recorded. No release ever did it — box#95, box#114
and box#148 all shipped as a version bump plus a changelog stamp, because
the gate was a sentence in a document and the only thing standing on it was
a reviewer remembering to ask. The rule moved into CI, where it fires
whether or not anyone is paying attention.

**Red means** the release is asserting a ritual it left no evidence of.
**The fix is to run the drill** and record it — or to waive it *in writing*
at the same path: the guard demands a **record, not a passing result**
([below](#the-drill-doctrine)).

## The drill doctrine

**Evidence, not success.** The guard asserts a record exists — a failed
drill honestly written down satisfies it, and so does a maintainer waiver
that says plainly the drill was waived and why. What it refuses is silence:
a skip must cost a deliberate, reviewable file in the diff, which is
precisely what box's three silent skips never produced. CI cannot run a
consumer's drill (box's wants real hardware and the better part of an hour);
it can only refuse a release that never ran one.

**Each repo defines what its drill *means*** — the gate only reads the
record. box asserts the **isolation contract**; rig asserts **convergence**
(a machine reaches its role, idempotently); cast asserts **promotion** (A→B
reproduces, the diff is idempotent); ceremony's own drill is a **door
rehearsal** — both doors exercised end-to-end on a disposable repo, written
out step by step in [drills/README.md](drills/README.md), with the records
themselves in [drills/](drills/); incubator asserts the **staging verify** —
the canonical candidate deployed, its smoke probe run *inside* the staging
container on the deployed environment's credentials, the record pinning the
commit SHA and image digest that were exercised
([heavy-duty/incubator `drills/README.md`](https://github.com/heavy-duty/incubator/blob/main/drills/README.md)).
Each repo states its meaning in its own `drills/README.md`. Five different
exercises sharing a substrate is why the records are per-repo — they are not
phases of one script.

**Drills exercise candidate refs, not released artifacts.** A ref is a
static identifier that exists as soon as the release branch does, so no repo
has to be released — or drilled — before another can be drilled: what looks
like a box↔rig recursion at runtime dissolves into two independent tests
against one fixed pair of refs. And drilling the candidate *is* drilling the
release: a ceremony PR's diff is the stamps and nothing else, so no
executable byte differs between the tree that was drilled and the tree that
ships.

**A cross-repo release set shares one run ID.** Each repo records its own
legs in its own `drills/X.Y.Z.md`, citing that run ID and the sibling SHAs,
so the records reconcile afterwards — but the guard only ever reads the repo
it runs in. If a defect shows up only in the combination: patch, re-drill,
re-record. The set converges; it is not required to be right in one pass.

## Troubleshooting red main

Every refusal the release flow can emit, verbatim, with cause and remedy.
The catalog is generated from the sources, not paraphrased — regenerate it
with:

```sh
grep -n -A2 'refuse \|>&2' \
  lib/decide.sh lib/facts.sh lib/version.sh .github/workflows/release.yml
```

`$VER`-style variables appear as the run interpolates them. One refusal is
outside that command by construction: `version_read: $path: no version field`
is a `console.error` inside the node one-liner at
[lib/version.sh#L55](lib/version.sh#L55) — no `>&2`, no `refuse `, so the grep
cannot see it. It is quoted below as it reaches the log at run time, which is
the convention this catalog is written to.

### The decision refused ([lib/decide.sh](lib/decide.sh))

> the version '$VER' is bare, unchanged by this PR, and never released — the label says ship but this PR did not mint the version. Refusing to guess — creating nothing.
> (If this PR was mislabeled, drop the label; if it was meant to release, it forgot the bump. A first release whose version never carried -dev ships by the tag door — the known first-release edge.)

Row 4 ([L129–L133](lib/decide.sh#L129-L133)). The message is the remedy:
drop the label, or re-do the ceremony with the bump, or take the tag door.

> the version transitioned ('$BASE_VER' -> '$VER') but no merged, release-labeled PR is behind this commit — a release is a labeled ceremony PR, not a bare push — creating nothing.

Row 5 ([L147–L149](lib/decide.sh#L147-L149)). Someone pushed or merged a
version transition without the `release` label. Label a proper ceremony PR,
or — if the tree is genuinely the release — publish by the tag door.

> VER is empty — the caller failed to establish the version at the pushed head. Refusing to decide — creating nothing.
> BASE_VER is empty — the caller failed to establish the version at the base. Refusing to decide — creating nothing.
> RELEASED='${RELEASED}' — expected yes, no, or empty. Refusing to decide — creating nothing.
> LABELED='${LABELED}' — expected yes, no, or empty. Refusing to decide — creating nothing.
> the version '$VER' is bare and unchanged, but RELEASED is empty — this state is decided by whether '$VER' is already released, and the caller did not establish that fact. Refusing to guess — creating nothing.
> the version transitioned ('$BASE_VER' -> '$VER') but LABELED is empty — a transition ships only behind a merged, release-labeled PR, and the caller did not establish that fact. Refusing to guess — creating nothing.

The fact-gathering guards ([L92–L105](lib/decide.sh#L92-L105),
[L135](lib/decide.sh#L135), [L151](lib/decide.sh#L151)): a missing fact must
never fall through to "no". These indicate a bug upstream in
[lib/facts.sh](lib/facts.sh) or the workflow plumbing, not an operator
mistake — read the run's `facts:` stderr line and file what you find.

### The facts could not be established ([lib/facts.sh](lib/facts.sh), [lib/version.sh](lib/version.sh))

> facts: unknown VERSION_SOURCE '$VERSION_SOURCE' — expected file or package-json

[L37](lib/facts.sh#L37): the caller's `version-source:` input is neither
`file` nor `package-json`. Fix the caller.

> version_read: $path: no such file
> version_read: $path is empty
> version_read: $path: no version field
> version_read: node is required for version-source: package-json

[lib/version.sh](lib/version.sh#L16-L66): the tree's version source is
missing, empty, or unreadable. A wrong release is worse than a missing one,
so an unreadable state is never an empty print — restore the `VERSION` file
(or `package.json` version field) on main.

> version_read: unknown backend: $backend

[L62](lib/version.sh#L62): not an operator mistake and not reachable through
the release flow — [lib/facts.sh](lib/facts.sh#L33-L40) rejects a bad
`VERSION_SOURCE` with the message above before `version_read` is ever called,
so this line can only appear when some *other* caller invokes `version_read`
directly with a backend that is neither `file` nor `package-json`. Fix that
caller.

### The merge door refused ([release.yml](.github/workflows/release.yml#L136-L301))

> CHANGELOG.md has no '## $VER' section at the merge commit — the ceremony PR must stamp it; refusing to publish an empty release

[L202–L205](.github/workflows/release.yml#L202-L205): the ceremony merged
without its stamp (a state the
[armed guard](#changelog-armed--main-never-sits-disarmed) already refuses on
the PR — red main here means it was overridden). Stamp the section on main,
then publish by the tag door.

> tag '$VER' already exists — this release already happened, or a manual tag won the race; refusing to re-release, creating nothing.
> release '$VER' already exists — refusing to re-release, creating nothing.

[L208–L223](.github/workflows/release.yml#L208-L223), the nothing-exists
assert — what makes a re-run of a completed ceremony refuse instead of
clobber, and what catches a manual tag racing the merge. If the release
truly exists, there is nothing to do: this red is the system declining to do
the thing twice. If the tag exists but the release does not (a manual tag
won the race, or
[a failed artifact hook](docs/CONSUMERS.md#the-artifact-hook), or the publish
step itself failing after the tag), recover by the tag door: delete and
re-push the tag, or `gh release create` by hand from a fixed tree.

> direct push refused (branch protection?) — opening the bump PR instead

[L293–L301](.github/workflows/release.yml#L293-L301) — loud, but not a
refusal: the post-release `-dev` bump could not push directly, so the run
opened a `release`-labeled bump PR itself. Your move: merge it promptly —
until it lands, main is sitting bare, where a dev install impersonates the
release and the
[armed guard's window](#changelog-armed--main-never-sits-disarmed) stays
open.

### The tag door refused ([release.yml](.github/workflows/release.yml#L303-L371))

> tag '$GITHUB_REF_NAME' does not match the tree's version '$ver' — creating nothing.
> A release is a PR, then a tag: the release PR bumps the version and stamps the changelog; the tag goes on its MERGE commit. Delete this tag and re-tag the right commit.

[L333–L337](.github/workflows/release.yml#L333-L337). The message is the
remedy.

> CHANGELOG.md has no '## $VER' section — run changelog-assemble in the release PR before tagging; refusing to publish an empty release

[L346–L349](.github/workflows/release.yml#L346-L349). The tagged tree was
never stamped. Assemble the section
([docs/CONSUMERS.md](docs/CONSUMERS.md#assembling-a-release-section)), then
delete and re-push the tag.

### The re-arm refused ([release.yml](.github/workflows/release.yml#L267-L301))

The bump belongs to the merge door alone — the tag door deliberately does not
rewrite main ([L303–L307](.github/workflows/release.yml#L303-L307)) — and it
runs *after* the tag, the notes and the publish. So a refusal here leaves a
real release standing behind a main that never re-armed — the release exists,
and main is left *armed to impersonate* it, still reading the version it just
shipped ([L266](.github/workflows/release.yml#L266)). That is the one failure
in this catalog whose remedy is a manual bump, not a re-run.

> version_next_dev: refusing '$ver' — expected bare X.Y.Z

[L86](lib/version.sh#L86): the version reaching the bump is not bare `X.Y.Z`.
Two senses of *bare* meet here, and the gap between them is the **rc release
path** — the way this refusal is actually reached, and designed behaviour
rather than a decide bug. decide calls a version bare when it is not `-dev`
([version_is_dev](lib/version.sh#L68-L76) matches that suffix and nothing
else), so row 6 admits a transition to `1.2.3-rc1`, and a labeled rc ceremony
is designed to ship ([lib/decide.sh](lib/decide.sh#L108-L110)).
`version_next_dev` means `^[0-9]+\.[0-9]+\.[0-9]+$`. An rc sits between the
two, and nothing filters it out on the way: the step's only gate is
`ceremony == 'yes'` and its `VER` is the tree's version verbatim. So an rc
ceremony tags, writes the notes, publishes — and *then* the re-arm refuses.
That is the machine correctly declining to guess rather than a bug: an rc's
next version "is a human decision, not arithmetic"
([L78–L82](lib/version.sh#L78-L82)), so make the decision and bump main by
hand to it. A `-dev` version reaching this line is the same refusal's other
half, and *that* half is unreachable as the doors stand — rows 1–2 send `-dev`
to a no-op, and the tag door never bumps. A malformed version is not: nothing
upstream checks the shape ([version_read](lib/version.sh#L22-L33) checks only
that a version is present and non-empty), so `banana` rides row 6 exactly as
an rc does, and the same manual bump is the remedy. One note on work that has
not landed: #317 would make rc cuts native and their re-arm deterministic, and
if it lands only the malformed half still reaches this refusal.

> version_write: npm is required for version-source: package-json

[L106](lib/version.sh#L106): the package-json backend needs npm to write —
`npm pkg set version=` plus a lockfile-only `npm install`
([L114–L115](lib/version.sh#L114-L115)), never `npm version`, which would tag
— and the runner has none. The read path fails the same way one step earlier
(`node is required…`, above), so a run reaching *this* message got past the
read — set up node/npm in the caller.

> version_write: unknown backend: $backend

[L118](lib/version.sh#L118): the write-side twin of `version_read: unknown
backend`, and unreachable for the same reason — `VERSION_SOURCE` was validated
before either was called. Fix the caller.

In every case the remedy has the same shape — bump `VERSION` (or the
`package.json` version field) by hand and push: `X.Y.(Z+1)-dev` where the
shipped version was bare, and where it was an rc, whatever you have decided
comes next. Note that a *push* refusal is not one of these — branch
protection is expected, and the step opens the bump PR itself rather than
failing ([L293–L301](.github/workflows/release.yml#L293-L301)).

### Red main that is not the release workflow

Consumer CI runs its guard steps on pushes to main too (this repo's
[ci.yml](.github/workflows/ci.yml) does the same). The one guard red an
operator will actually meet on main is **changelog-armed after a re-arm was
forgotten — legacy mode only**: the ceremony stamped without putting
`## Unreleased` back, the release's own `-dev` bump landed, and the guard now
says (first line):

> changelog-armed: the version is '$ver' (a development tree) but the top
>   section of $changelog is: …

The fix is a one-line PR: add an empty `## Unreleased` above the stamped
section. The full message carries the same instruction. Fragment mode has no
re-arm to forget, so it has no equivalent red on main — its refusals (a
missing marker, a surviving `## Unreleased`, a malformed or unconsumed
fragment) all fire on the PR that caused them, where the author is still
holding it.

## Design lineage

The ceremony converged across box#83 → box#96, rig#32 → rig#47 and cast#96 →
cast#111; this repo is those three implementations folded into one, and the
drift that motivated it is measured in
[#1](https://github.com/heavy-duty/ceremony/issues/1), which also lists the
load-bearing constraints — each bought with an incident, none of them safe
to "simplify" away. The label machine's own record is #10, #11 and #130; the
issue-flow queue's is #15, #16 and #73; the fragment changelog's is #112 and
#116; the sweep/trigger split is #209.

The narrative lives in those issues, by design: the war stories are carried
in the headers of the scripts they bind —
[release.yml](.github/workflows/release.yml),
[lib/decide.sh](lib/decide.sh), [lib/facts.sh](lib/facts.sh) and the
[guard scripts](actions/) — and those comments are the documentation of
record. This README is their operator-facing cut.
