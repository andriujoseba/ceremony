# Drills

What a drill means in this repo: an **end-to-end rehearsal of both doors of
the release workflow on a disposable repo**. The contract suite proves every
decision offline — facts → decide → notes against fixtures, the merge door's
step sequence replayed in release-exercise.yml — but the doors themselves
only ever run live: gating on a real push event, the tag create, the
publish, the `-dev` re-arm (release.yml's "what is honestly untested"). The
drill is where they run live *before* a version rests on them.

## The instrument

This directory is the record, not the instrument — the instrument is
[`drill/rehearsal.sh`](../drill/rehearsal.sh). It drives the rehearsal below
end to end against a disposable repo and emits the record, so a release owes
a run rather than an hour of hand-steps: a manual hour loses to a waiver
every time, and a script does not. The procedure that follows stays the
normative text — it is the script's specification and the script implements
it, doctrine first. Two of its refusals are the script's own rather than its
operator's, because both are incidents: it archives and never deletes
(#135), and it refuses to pin the caller stub at a tag-named ref on this
repo (the 0.1.0 shadow-tag rule, step 2 below). A run with failed probes is
still a record — the rehearsal shape simply has one producer now, while the
two judgement shapes below stay hand-written (#313).

A setup abort is evidence too, but it is never a release's record: before any
probe runs, the instrument writes the failure beside `--out` as the first-free
`<out>.aborted-N.md`, after stripping a final `.md`. It names the failed setup
step and message, records only context already known, and archives an existing
scratch repo before stating the disposal it observed. `--out` remains absent,
so partial setup evidence cannot satisfy the release gate.

## The rehearsal

1. Create a scratch repo. It is **public by default**, disposable, archived by
   the instrument, and deleted by the operator; it never carries anything that
   is not already public. A builder who needs private evidence passes
   `--private`, accepts the creation warning, and the record discloses that its
   run links resolve only for the repo owner. With no explicit `--repo-name`, the
   instrument numbers attempts from 1 and claims the first pair whose
   `ceremony-drill-<version>-<n>` repo name and `drill/<version>-<n>` fork ref
   are both free, bounded at ten candidates. An explicit repo name with a
   default fork ref gets the first free numbered ref and records that numeric
   attempt. Burned names are routed around and never reclaimed: an explicit
   repo name still refuses if it exists and prints the complete invocation
   for the next free numbered pair, while an explicit fork ref is always
   honored exactly.

   The repo is disposable by design — but the
   disposal is split, because the builder cannot perform the delete: at the
   end the builder **archives** it (`PATCH /repos/{owner}/{repo}` with
   `archived: true`, inside the `repo` scope every fleet identity holds),
   and **deleting it is the operator's step** — `delete_repo` is
   deliberately absent from bot tokens, fleet doctrine and not a
   misconfiguration, so no builder that will ever run a drill can do it.
   Do not retry the delete and do not wait on it: both 0.2.0 drills ended
   at that wall independently (#135) — one builder held its release draft
   in `state:building` re-trying a 403 that cannot succeed, the other wrote
   a record asserting a delete that had not happened. **Cleanup gates
   nothing** — not ready-for-review, not the review panel, not the merge.
   The archived leftover has no consumers and is
   outside `heavy-duty/ceremony`'s ref namespace — the namespace the
   "never a branch named like the tag" rule below protects.
2. Install the docs/CONSUMERS.md caller stubs, pinned to a fork ref carrying
   the release candidate tree. The candidate's `CEREMONY_SELF_REF` is by
   construction the tag this release has not created yet, so the consumer
   path cannot resolve directly from the candidate. Rewrite that pin to a
   canonical candidate SHA in every carrier on the fork ref, and record the
   fork ref and rewritten pin in the drill record.

   Never create a branch named like the tag on `heavy-duty/ceremony` to
   paper over this deadlock: it would shadow the tag for every consumer
   until someone remembers to delete it. The 0.1.0 drill (#11) is the
   worked example of this standing fork-ref shape.
3. Give it a fixture `VERSION` / `CHANGELOG.md` / `changelog.d/` /
   `drills/` in the armed state (`X.Y.Z-dev`, the fragments directory with
   its `README.md` marker plus at least one fragment for the ceremony to
   consume).
4. Exercise both doors, one probe at a time:

   1. a merge-door ceremony publishes exactly one release and re-arms main
      to `-dev`;
   2. a mislabeled ordinary PR is a green NOTICE no-op;
   3. a bare-version PR without the `release` label refuses;
   4. a re-run of the completed ceremony refuses;
   5. a tag-door release from a manual tag;
   6. a mismatched tag refuses;
   7. an rc cut publishes a prerelease and stamps nothing;
   8. the promotion after it ships the final version.

   Every refusal must refuse **creating nothing** — a probe that leaves a
   tag or a release behind on a refusal path is a failed probe.

   The last two are the rc ladder, and they run one rung further along it
   than the probes above them: a labeled ceremony PR bumping to
   `X.Y.Z-rc1` must publish a release marked prerelease, leave
   `CHANGELOG.md` byte-identical, leave every fragment where it is, and
   re-arm main to `X.Y.Z-rc2-dev`; the ceremony PR to bare `X.Y.Z` after it
   must publish a full release whose `## X.Y.Z` section is the body those
   fragments assemble to, consume them, and leave the candidate's own
   release still marked prerelease — **a promotion never relabels the
   candidate it came from**. An rc that ships carries its own record at
   `drills/X.Y.Z-rcN.md`, and the rc cut's ceremony PR is what carries it.
   The untouched-changelog claim is a byte comparison, never prose, for the
   reason the counts either side of a refusal are numbers.

## The record

One file per version, `drills/X.Y.Z.md` — the shape the siblings use: what
was run, where, the result of each probe, failures written down plainly. The
record is the evidence; the scratch repo is the evidence's scaffolding. The
record names the scratch repo by full `owner/name` and states its disposal
state **as its author observed it when the record was written** — archived
and pending the operator's delete, or deleted only if the author genuinely
performed the delete. Never a disposal the author did not observe: the
record is the only thing that survives the drill, and 0.2.0's record shipped
its first draft asserting a cleanup that had not happened (#135) — false
evidence in the one file whose job is to be evidence.

A record has one of three shapes. A **rehearsal** records the disposable-repo
run above. **Doors unchanged** records the mechanically checked claim below
when a new rehearsal would execute the same bytes as the last one. **WAIVED**
records a maintainer's judgement under the standing paragraph below. If the
doors-unchanged conditions do not all hold, the release owes a rehearsal or a
waiver; the narrower shape is never a substitute for either.

### How a record declares which shape it is

CI reads the shape off the record, because only the rehearsal shape has a
renderer to re-run against it (see the round trip, below). Each shape says
which it is, and a record author needs to know the two markers:

- a **rehearsal** record is `drill/rehearsal.sh`'s emission, and carries the
  run sentence the instrument writes as its third line:

  ```
  Run <date> by `<runner>` with `drill/rehearsal.sh` against the <version>
  ```

  Nothing else writes that sentence, and no hand-written record copies it;
- a **doors unchanged** or **WAIVED** record opens its claim with a
  `## Scope ruling — …` heading. `drills/0.6.3.md` is the worked example.

A record declaring **both**, or **neither**, is treated as a rehearsal and
must round-trip. That direction is deliberate: "could not tell" resolving to
"allowed" is the hazard `actions/drill-recorded` names in its own refusal
text, so the discriminator fails closed. The records predating this
convention — `0.1.0` through `0.4.0` — declare neither and would be graded as
emissions; nothing reads them, because the check reads `drills/<version>.md`
for the version in the tree and no other file (#373).

## Doors unchanged

The builder may assert that no disposable-repo rehearsal is owed only when
all three conditions below hold at the candidate head. The release PR's panel
verifies the claim like any other evidence, and if any reviewer rules a full
drill owed, that verdict wins.

1. `git diff <last-rehearsed-tag>..HEAD -- <release-path>` contains no change
   except the `CEREMONY_SELF_REF` pin line in
   `.github/workflows/release.yml`.
2. The release path is exactly the output of
   `.github/scripts/release-path.sh`: `.github/workflows/release.yml`, `bin/`,
   `lib/version.sh`, `lib/decide.sh`, `lib/facts.sh`, and
   `lib/changelog.sh`. The script is the record author's copy-paste source;
   its contract test keeps this inline list and the workflow's direct and
   transitive dependencies in agreement.
3. The last rehearsed tag's own record is a full rehearsal, its release is
   published, and `main` was re-armed to `-dev` after it.

The baseline is the last **rehearsed** tag, never merely the previous tag. A
previous-tag baseline could chain one doors-unchanged assertion from another
while the doors drift a small diff at a time; the last-rehearsed anchor makes
any accumulated release-path change force a new rehearsal.

The record carries all three measurements as observed at its candidate head,
never copied from an earlier record. `drills/0.4.1.md` and
`drills/0.5.0.md` are the worked examples; the latter's amendment from a
predicted empty `lib/` diff to the observed `lib/ruling.sh` delta is why each
candidate is measured afresh (#233). Re-running its stricter baseline now is
also the path-enumeration proof: `git diff 0.4.0 0.5.0 -- <release-path>` is
only the `CEREMONY_SELF_REF` pin, while adding `lib/ruling.sh` makes the diff
non-empty even though neither release door reads that file (#217, #237).

`actions/drill-recorded` refuses any bare-version tree whose record is
missing or blank. A waived drill is still a record: the file says WAIVED and
why — a maintainer's call, visible and reviewable in the release PR's diff,
never a silent skip.

## The round trip: how a rehearsal record is graded

A **rehearsal** record is `drill/rehearsal.sh`'s emission, not a hand-written
account of it (#313 D2). CI holds that claim by re-rendering the committed
file: `.github/scripts/record-roundtrip.sh` parses the record back into the
three inputs `record_render` consumes, renders them, and requires the bytes
back. It is keyed exactly as `drill-recorded` is — a `-dev` tree skips and
says so, a bare-version tree is graded — and it runs in this repository's
`self-guards` job rather than inside the vendored action, which is ported
into repos that have no `drill/lib` to re-render with (#373 D3).

It **classifies before it grades**, by the markers above, and the round trip
applies to the rehearsal shape alone: a scope ruling is a claim the review
panel verifies from the record itself, and a waiver is a maintainer's
judgement — neither has a renderer, and neither is graded here. The step
prints which branch it took, so a green log distinguishes *passed* from
*decided this was not its business* (#373 D9).

It grades **authorship**, which is a different claim from the shape check
`record_check` runs at emission time. Everything the record *derives* from
its measurements has to follow from them:

- **every sentence of prose.** The preamble's run count, the "every probe
  passed" line, the door sentences, the per-probe claims and the
  not-established tail are all written from the probe rows. Add a sentence,
  soften one, or change a count in the conclusion, and the re-render does not
  write it back.
- **the order of the fields.** The parse finds each field by its own
  sentence and does not care what order they come in; the re-render puts them
  back in the render's order, so a moved field is a difference.
- **each run cell's internal agreement.** `record_run_cell` builds the link
  text and the URL out of one run ID, so a cell where they disagree is
  refused by the parse, by line number.
- **anything a second renderer would write differently**, including this
  repository's own renderer at an older commit: a record emitted before a
  render change is stale, and the guard reds on the PR that makes the change
  rather than at the next cut.

What it does **not** grade, stated so the guarantee is not read wider than it
is:

- **the measurements themselves.** A before/after count, or a run ID
  rewritten consistently on both sides of its link, is *data*: the file is
  then exactly what the renderer emits for that data, and no self-describing
  record can say otherwise. #373 D4 records why the alternative was
  rejected — committing the render inputs beside the record puts an
  unguarded second file in the tree and reintroduces the same bug one level
  down. The run link is what a reader checks a run ID against.
- **whether a probe's verdict is true.** That is what the probe's own
  before/after counts are for, and `record_check` grades that they are there.
- **the other two record shapes.** *Doors unchanged* and *WAIVED* are
  judgement, not automation, and the round trip runs only where a rehearsal
  record is what the tree carries.

A record that cannot be parsed **fails and names the line that defeated it**.
There is no "unparseable therefore fine" path: that would be the silent skip
this guard exists to close (#373 D5).
