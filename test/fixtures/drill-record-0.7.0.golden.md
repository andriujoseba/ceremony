# 0.7.0 — drill record

Run 2026-08-10 by `cndgrr` with `drill/rehearsal.sh` against the 0.7.0
candidate, candidate ref `build/367-cut-0-7-0`, canonical candidate SHA
`e6caf31d2c102532efa897ea52903b8a79dd6a65`.
All eight probes ran; every row in the table below was written from
its own run by the script that drove it.

**Every probe passed.**

## Where

Attempt **`3`** used disposable **private** repo `cndgrr/ceremony-drill-0.7.0-a3`, created
2026-08-10T16:18:50Z. It carries the
`docs/CONSUMERS.md` release caller verbatim (`version-source: file`) over a
fragment-mode fixture armed at `0.7.0-dev`: a preamble-only
`CHANGELOG.md`, `changelog.d/README.md` plus three fragments, and a
non-blank `drills/0.7.0.md`. The `release` label was created there before
the first ceremony PR, per the guide's prerequisite. The fixture was
committed **before** the caller, so the first door run had a real parent
version to inspect — the script refuses to install the caller against a tree
with no fixture in it.

Because this repo is private, its run links resolve only for the repo owner.

The rc legs run one rung further along the ladder — `0.7.2-dev` →
`0.7.2-rc1` → `0.7.2` — because the probes before them have already
published 0.7.0 and its successor, and a promotion needs a version nothing
has released. An rc that ships carries its own drill record, so the rc cut's
ceremony PR carries **`drills/0.7.2-rc1.md`** and that is the path the rc
version's record lives at.

**Disposal, as this run observed it**: the repository is **archived** — `PATCH /repos/cndgrr/ceremony-drill-0.7.0-a3` with `archived: true`, and a fresh read afterwards reported `archived=true private=true`.

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
`cndgrr/ceremony/.github/workflows/release.yml@drill/0.7.0-a3`. That fork ref was
created at the canonical candidate SHA `e6caf31d2c102532efa897ea52903b8a79dd6a65`, and its one
additional commit (`97b7bb994d2a94571f19b4bfd1de8b5f7978678b`) rewrites every workflow carrying
`CEREMONY_SELF_REF` to the rewritten pin `e6caf31d2c102532efa897ea52903b8a79dd6a65`. The pins were read back
at the ref after the rewrite and all agree; all runtime machinery in every
probe below was therefore fetched from the 0.7.0 candidate tree.

## Probes

One row per probe, in doctrine order, each written from its own run. Runs are
in `cndgrr/ceremony-drill-0.7.0-a3`. The two count columns are the measurement every refusal
probe is asserted on: a refusal that leaves a tag or a release behind is a
failed probe, and the assertion is these numbers, not the prose beside them.

| # | probe | run | tags | releases | result |
|---|---|---|---|---|---|
| 1 | merge-door ceremony | [31408395683](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408395683) | 0 → 1 | 0 → 1 | ✅ exactly one `0.7.0` release; main re-armed to `0.7.1-dev` |
| 2 | mislabeled ordinary PR | [31408449800](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408449800) | 1 → 1 | 1 → 1 | ✅ green NOTICE no-op under the label; nothing created |
| 3 | bare-version PR without `release` | [31408496126](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408496126) | 1 → 1 | 1 → 1 | ✅ refused at decide (row 5); no tag, no release |
| 4 | re-run of the completed ceremony | [31408395683](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408395683) (attempt 2) | 1 → 1 | 1 → 1 | ✅ refused at the nothing-exists assert; the release count stayed 1 |
| 5 | tag-door release from a manual tag | [31408615122](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408615122) | 1 → 2 | 1 → 2 | ✅ `0.7.1` published from its own changelog section; main untouched |
| 6 | mismatched tag | [31408660850](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408660850) | 2 → 2 | 2 → 2 | ✅ refused before publication; no `9.9.9` release, and the probe tag was removed afterwards (its own ref is excluded from the after-count) |
| 7 | rc cut, tag-only and marked prerelease | [31408777183](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408777183) | 2 → 3 | 2 → 3 | ✅ `0.7.2-rc1` published as a prerelease; `CHANGELOG.md` byte-identical either side, every fragment still there, main re-armed to `0.7.2-rc2-dev` |
| 8 | promotion of the rc to the final version | [31408846106](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408846106) | 3 → 4 | 3 → 4 | ✅ `0.7.2` published as a full release from the body its fragments assemble to; they are consumed, `0.7.2-rc1` is still a prerelease, and main re-armed to `0.7.3-dev` |

## Setup, and the runs that are not probes

- **[31408333324](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408333324)** (success) — the caller's own landing on an armed tree — the green baseline no-op, and the run that proves the door was live before any probe asked it a question
- **[31408533234](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408533234)** (success) — re-arming main to `0.7.1-dev` after probe 3's refusal left a bare version there — decide's row 2, a -dev tree that changed
- **[31408707804](https://github.com/cndgrr/ceremony-drill-0.7.0-a3/actions/runs/31408707804)** (success) — arming main at `0.7.2-dev` before the rc legs and seeding a second fragment there — decide's row 2, a -dev tree that changed. `0.7.1` was published by the tag door, which leaves main alone by design, so this is the post-release bump nothing else makes

## What the rehearsal establishes

Both doors ran live against the 0.7.0 candidate's own machinery, driven by
`drill/rehearsal.sh` rather than by hand. Each line below is one probe's,
and it is printed as a claim only where that probe passed: what stands here
is a measurement in the table above, never a sentence written from an
intention.

- ✅ The merge door published exactly one `0.7.0` release from a labeled ceremony PR, tagged the reviewed merge commit, and re-armed main itself.
- ✅ The merge door stayed a green no-op under a `release` label carried by ordinary work.
- ✅ The merge door refused a bare version push without the `release` label.
- ✅ The merge door refused a re-run of its own completed ceremony.
- ✅ The tag door published from a matching manual tag without touching main.
- ✅ The tag door refused a mismatched tag before creating anything.
- ✅ The merge door cut `0.7.2-rc1` as a prerelease from its surviving fragments, left `CHANGELOG.md` byte-identical, and re-armed main to `0.7.2-rc2-dev`.
- ✅ The merge door promoted `0.7.2-rc1` to `0.7.2`, stamping the section its fragments assemble to and consuming them, while the candidate stayed a prerelease.

Every refusal claim above is asserted on the before/after counts in the probe
table, not on the prose beside them.

## Known gaps

None declared: every claim this record makes is a probe row's, and nothing was
declared outside them.
