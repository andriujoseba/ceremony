# 0.7.6 — drill record

Run 2026-08-24 by `cndgrr` with `drill/rehearsal.sh` against the 0.7.6
candidate, candidate ref `build/499-release-0-7-6`, canonical candidate SHA
`cb7a061e71555f47987859f5d769289780eb514e`.
All eleven probes ran; every row in the table below was written from
its own run by the script that drove it.

**Every probe passed.**

## Where

Attempt **`2`** used disposable **public** repo `cndgrr/ceremony-drill-0.7.6-2`, created
2026-08-24T19:08:07Z. It carries the
`docs/CONSUMERS.md` release caller — that guide's entire `release.yml`
plus the one add-on line it documents under the same `with:` key, so
`version-source: file` and
`non-release-namespace: drill/**`, without which the
tag door's non-release classification is unreachable — over a
fragment-mode fixture armed at `0.7.6-dev`: a preamble-only
`CHANGELOG.md`, `changelog.d/README.md` plus three fragments, and a
non-blank `drills/0.7.6.md`. The `release` label was created there before
the first ceremony PR, per the guide's prerequisite. The fixture was
committed **before** the caller, so the first door run had a real parent
version to inspect — the script refuses to install the caller against a tree
with no fixture in it.

The rc legs run one rung further along the ladder — `0.7.8-dev` →
`0.7.8-rc1` → `0.7.8` — because the probes before them have already
published 0.7.6 and its successor, and a promotion needs a version nothing
has released. An rc that ships carries its own drill record, so the rc cut's
ceremony PR carries **`drills/0.7.8-rc1.md`** and that is the path the rc
version's record lives at.

**Disposal, as this run observed it**: the repository is **archived** — `PATCH /repos/cndgrr/ceremony-drill-0.7.6-2` with `archived: true`, and a fresh read afterwards reported `archived=true private=false`.

It is **pending the operator's delete**, which no builder can perform:
`delete_repo` is absent from fleet tokens by doctrine (#135). No delete was attempted and none is
claimed — the instrument refuses the call rather than retrying the 403 wall.
Cleanup gates nothing.

## Candidate-ref deviation

The pure consumer path cannot resolve this candidate's own
`CEREMONY_SELF_REF`: it names the tag this release has not created yet. No
ref named like that tag was created on `heavy-duty/ceremony`, and the
script refuses to take that path at all.

The scratch caller pins
`cndgrr/ceremony/.github/workflows/release.yml@drill/0.7.6-2`. That fork ref was
created at the canonical candidate SHA `cb7a061e71555f47987859f5d769289780eb514e`, and its one
additional commit (`685c6b4b442b026aceb5ec1e11865878c4ef020b`) rewrites every workflow carrying
`CEREMONY_SELF_REF` to the rewritten pin `cb7a061e71555f47987859f5d769289780eb514e`. The pins were read back
at the ref after the rewrite and all agree; all runtime machinery in every
probe below was therefore fetched from the 0.7.6 candidate tree.

## Probes

One row per probe, in doctrine order, each written from its own run. Runs are
in `cndgrr/ceremony-drill-0.7.6-2`. The two count columns are the measurement every refusal
probe is asserted on: a refusal that leaves a tag or a release behind is a
failed probe, and the assertion is these numbers, not the prose beside them.

| # | probe | run | tags | releases | result |
|---|---|---|---|---|---|
| 1 | merge-door ceremony | [32766515180](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766515180) | 0 → 1 | 0 → 1 | ✅ exactly one `0.7.6` release; main re-armed to `0.7.7-dev` |
| 2 | mislabeled ordinary PR | [32766571867](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766571867) | 1 → 1 | 1 → 1 | ✅ green NOTICE no-op under the label; nothing created |
| 3 | bare-version PR without `release` | [32766626195](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766626195) | 1 → 1 | 1 → 1 | ✅ refused at decide (row 5); no tag, no release |
| 4 | re-run of the completed ceremony | [32766515180](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766515180) (attempt 2) | 1 → 1 | 1 → 1 | ✅ refused at the nothing-exists assert; the release count stayed 1 |
| 5 | tag-door release from a manual tag | [32766754188](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766754188) | 1 → 2 | 1 → 2 | ✅ `0.7.7` published from its own changelog section; main untouched |
| 6 | mismatched tag | [32766805509](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766805509) | 2 → 2 | 2 → 2 | ✅ refused before publication; no `9.9.9` release, and the probe tag was removed afterwards (its own ref is excluded from the after-count) |
| 7 | rc cut, tag-only and marked prerelease | [32766906752](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766906752) | 2 → 3 | 2 → 3 | ✅ `0.7.8-rc1` published as a prerelease; `CHANGELOG.md` byte-identical either side, every fragment still there, main re-armed to `0.7.8-rc2-dev` |
| 8 | promotion of the rc to the final version | [32766965739](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766965739) | 3 → 4 | 3 → 4 | ✅ `0.7.8` published as a full release from the body its fragments assemble to; they are consumed, `0.7.8-rc1` is still a prerelease, and main re-armed to `0.7.9-dev` |
| 9 | rc tag through the tag door | [32767018102](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32767018102) | 4 → 5 | 4 → 5 | ✅ `0.7.9-rc1` published as a prerelease from the fragments in its own tagged tree; main untouched |
| 10 | declared non-release namespace tag | [32767070151](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32767070151) | 5 → 5 | 5 → 5 | ✅ green no-op against the caller's declared `drill/**`; no release, no version assertion, main untouched, and the probe tag was removed afterwards (its own ref is excluded from the after-count) |
| 11 | malformed tag outside every namespace | [32767123148](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32767123148) | 5 → 5 | 5 → 5 | ✅ refused before publication; no `nightly-build` release, and the probe tag was removed afterwards (its own ref is excluded from the after-count) |

## Setup, and the runs that are not probes

- **[32766465193](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766465193)** (success) — the caller's own landing on an armed tree — the green baseline no-op, and the run that proves the door was live before any probe asked it a question
- **[32766671372](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766671372)** (success) — re-arming main to `0.7.7-dev` after probe 3's refusal left a bare version there — decide's row 2, a -dev tree that changed
- **[32766854806](https://github.com/cndgrr/ceremony-drill-0.7.6-2/actions/runs/32766854806)** (success) — arming main at `0.7.8-dev` before the rc legs and seeding a second fragment there — decide's row 2, a -dev tree that changed. `0.7.7` was published by the tag door, which leaves main alone by design, so this is the post-release bump nothing else makes

## What the rehearsal establishes

Both doors ran live against the 0.7.6 candidate's own machinery, driven by
`drill/rehearsal.sh` rather than by hand. Each line below is one probe's,
and it is printed as a claim only where that probe passed: what stands here
is a measurement in the table above, never a sentence written from an
intention.

- ✅ The merge door published exactly one `0.7.6` release from a labeled ceremony PR, tagged the reviewed merge commit, and re-armed main itself.
- ✅ The merge door stayed a green no-op under a `release` label carried by ordinary work.
- ✅ The merge door refused a bare version push without the `release` label.
- ✅ The merge door refused a re-run of its own completed ceremony.
- ✅ The tag door published from a matching manual tag without touching main.
- ✅ The tag door refused a mismatched tag before creating anything.
- ✅ The merge door cut `0.7.8-rc1` as a prerelease from its surviving fragments, left `CHANGELOG.md` byte-identical, and re-armed main to `0.7.8-rc2-dev`.
- ✅ The merge door promoted `0.7.8-rc1` to `0.7.8`, stamping the section its fragments assemble to and consuming them, while the candidate stayed a prerelease.
- ✅ The tag door published an rc tag as a prerelease, from the fragments in its own tagged tree, without touching main.
- ✅ The tag door treated a tag inside the caller's declared non-release namespace as a green no-op, asserting no version and creating nothing.
- ✅ The tag door refused a tag that is neither version-shaped nor inside that namespace, before creating anything.

Every refusal claim above is asserted on the before/after counts in the probe
table, not on the prose beside them.

## Known gaps

None declared: every claim this record makes is a probe row's, and nothing was
declared outside them.
