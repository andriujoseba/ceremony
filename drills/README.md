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

## The rehearsal

1. Create a scratch **private** repo. It is disposable by design — but the
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
   The archived leftover is safe to leave: private, no consumers, and
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
   6. a mismatched tag refuses.

   Every refusal must refuse **creating nothing** — a probe that leaves a
   tag or a release behind on a refusal path is a failed probe.

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
