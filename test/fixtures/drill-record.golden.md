# 0.7.0 — drill record

Run 2026-08-09 by `drill-runner` with `drill/rehearsal.sh` against the 0.7.0
candidate, candidate ref `build/313-drill-rehearsal`, canonical candidate SHA
`c0ffee1234567890c0ffee1234567890c0ffee12`.
All eight probes ran; every row in the table below was written from
its own run by the script that drove it.

**Every probe passed.**

## Where

Attempt **`1`** used disposable **private** repo `drillowner/ceremony-drill-0.7.0-1`, created
2026-08-09T00:00:00Z. It carries the
`docs/CONSUMERS.md` release caller verbatim (`version-source: file`) over a
fragment-mode fixture armed at `0.7.0-dev`: a preamble-only
`CHANGELOG.md`, `changelog.d/README.md` plus three fragments, and a
non-blank `drills/0.7.0.md`. The `release` label was created there before
the first ceremony PR, per the guide's prerequisite. The fixture was
committed **before** the caller, so the first door run had a real parent
version to inspect — the script refuses to install the caller against a tree
with no fixture in it.

The rc legs run one rung further along the ladder — `0.7.2-dev` →
`0.7.2-rc1` → `0.7.2` — because the probes before them have already
published 0.7.0 and its successor, and a promotion needs a version nothing
has released. An rc that ships carries its own drill record, so the rc cut's
ceremony PR carries **`drills/0.7.2-rc1.md`** and that is the path the rc
version's record lives at.

**Disposal, as this run observed it**: the repository is **archived** — a fresh read afterwards reported `archived=true private=true`.

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
`forkowner/ceremony/.github/workflows/release.yml@drill/0.7.0`. That fork ref was
created at the canonical candidate SHA `c0ffee1234567890c0ffee1234567890c0ffee12`, and its one
additional commit (`deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`) rewrites every workflow carrying
`CEREMONY_SELF_REF` to the rewritten pin `c0ffee1234567890c0ffee1234567890c0ffee12`. The pins were read back
at the ref after the rewrite and all agree; all runtime machinery in every
probe below was therefore fetched from the 0.7.0 candidate tree.

## Probes

One row per probe, in doctrine order, each written from its own run. Runs are
in `drillowner/ceremony-drill-0.7.0-1`. The two count columns are the measurement every refusal
probe is asserted on: a refusal that leaves a tag or a release behind is a
failed probe, and the assertion is these numbers, not the prose beside them.

| # | probe | run | tags | releases | result |
|---|---|---|---|---|---|
| 1 | merge-door ceremony | [1001](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1001) | 0 → 1 | 0 → 1 | ✅ exactly one release |
| 2 | mislabeled ordinary PR | [1002](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1002) | 1 → 1 | 1 → 1 | ✅ green NOTICE no-op |
| 3 | bare-version PR without `release` | [1003](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1003) | 1 → 1 | 1 → 1 | ✅ refused at decide |
| 4 | re-run of the completed ceremony | [1001](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1001) (attempt 2) | 1 → 1 | 1 → 1 | ✅ refused at the assert |
| 5 | tag-door release from a manual tag | [1005](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1005) | 1 → 2 | 1 → 2 | ✅ published from its own section |
| 6 | mismatched tag | [1006](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1006) | 2 → 2 | 2 → 2 | ✅ refused before publication |
| 7 | rc cut, tag-only and marked prerelease | [1007](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1007) | 2 → 3 | 2 → 3 | ✅ published as a prerelease, changelog byte-identical |
| 8 | promotion of the rc to the final version | [1008](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1008) | 3 → 4 | 3 → 4 | ✅ the assembled section stamped, the candidate still a prerelease |

## Setup, and the runs that are not probes

- **[1000](https://github.com/drillowner/ceremony-drill-0.7.0-1/actions/runs/1000)** (success) — the caller landing on an armed tree

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
