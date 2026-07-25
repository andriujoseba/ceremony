# Consumer setup

How a repo adopts the ceremony — bootstrap for a greenfield repo, a
conversion checklist for a repo carrying its own copy of the machinery,
and the policies that keep either honest afterwards. The doctrine (what a
release *is*, the doors, the guards, the drill) lives in
[../README.md](../README.md); this guide is the how-to. It is meant to be
sufficient on its own: a conversion executed from this guide should need
zero out-of-band knowledge, and gaps found while converting are filed as
edits to this guide (#12).

## Prerequisites

- **Repo shape**: work lands on a `main` default branch by PR; fork PRs
  are fine — the merge door rides `push` to `main`, never `pull_request`
  ([release.yml](../.github/workflows/release.yml#L70-L74), box#97), and
  the label read goes through the API
  ([lib/facts.sh](../lib/facts.sh#L88-L101)), so the ceremony never needs
  the PR's own context. No PAT, no secrets: every permission the flow uses
  is the caller-declared `GITHUB_TOKEN` grant.
- **Pick the version backend**: `file` (a `VERSION` file — box, rig,
  incubator) or `package-json` (the `version` field, lockfile kept in sync
  on the post-release bump — cast). This is the workflow's one input; the
  full configuration surface of the ceremony is enumerated in
  [#1](https://github.com/heavy-duty/ceremony/issues/1) ("The
  configuration axes").
- **The `release` label must exist** before the first ceremony PR — it is
  the merge door's declared-intent read
  ([lib/facts.sh](../lib/facts.sh#L88-L101)). Bootstrap it via the labels
  workflow's `workflow_dispatch`
  ([Labels automation](#labels-automation)), or create it by hand,
  matching the core table
  ([actions/labels-reconcile/labels-reconcile.sh](../actions/labels-reconcile/labels-reconcile.sh#L369)):

  ```sh
  gh label create release --color 0E8A16 \
    --description "Release flow and version/packaging work"
  ```

## Bootstrap a new repo

The greenfield path (incubator's, #16) — the repo never owns a copy of
the machinery at all:

1. **`VERSION` at `X.Y.Z-dev` — never bare.** A first version that never
   carried `-dev` hits the decide table's refuse row and has to ship by
   the tag door (the known first-release edge, cast#111;
   [lib/decide.sh](../lib/decide.sh#L70-L74)). Bootstrapping at `-dev`
   keeps the repo clear of it entirely. (`package-json` backend: the
   `version` field, same rule.)
2. **An armed changelog: a `CHANGELOG.md` preamble plus `changelog.d/`.**
   The changelog file starts as preamble only — no section; the first
   release writes the first one. The fragments directory beside it is the
   arming (#112): it carries a `README.md` marker naming the assembler and
   the doctrine — take ceremony's own
   [changelog.d/README.md](../changelog.d/README.md) at the pin — which is
   what keeps the directory tracked while it holds no fragments and what
   `changelog-armed` asserts. Every behavior-change PR then writes
   `changelog.d/<issue>.md` ([The changelog rule](#the-changelog-rule));
   the release PR assembles the section
   ([Assembling a release section](#assembling-a-release-section)).

   Fragment mode is **unreleased** and not in `0.1.0`. A consumer pinned
   to `0.1.0` bootstraps the legacy shape instead — the preamble plus an
   empty `## Unreleased` section for entries to land under — and converts
   on the pin bump to the first tag carrying fragment mode; never mix
   refs to adopt it early.
3. **`drills/README.md`** defining what a drill *means* in this repo —
   each repo names its own
   ([the drill doctrine](../README.md#the-drill-doctrine)). Plain
   `drills`, not a dot-directory
   ([drill-recorded.sh](../actions/drill-recorded/drill-recorded.sh#L49-L52)).
4. **`.github/workflows/release.yml`** — the caller, verbatim from
   [Release workflow](#release-workflow) below.
5. **CI guard steps** in the repo's `ci.yml`:

   ```yaml
       - uses: actions/checkout@v4
         with:
           # changelog-monotonic and changelog-assembled compare HEAD
           # against the merge base; a checkout that cannot resolve it is
           # a hard failure in CI, not a skip (a guard that can quietly
           # stop guarding is the failure shape these checks exist to
           # refuse).
           fetch-depth: 0
       - uses: heavy-duty/ceremony/actions/changelog-armed@<pinned-tag>
       - uses: heavy-duty/ceremony/actions/changelog-monotonic@<pinned-tag>
       # Unreleased: changelog-assembled is not in 0.1.0. Adopt this step
       # with the pin bump to the first tag that carries it; never mix
       # refs. Green NOTICE on every non-release PR; on a release PR it
       # asserts the stamped section is exactly the fragments it consumed.
       - uses: heavy-duty/ceremony/actions/changelog-assembled@<pinned-tag>
       - uses: heavy-duty/ceremony/actions/drill-recorded@<pinned-tag>
       # Unreleased: runner-isolated is not in 0.1.0. Adopt this step with
       # the pin bump to the first tag that carries it; never mix refs.
       - uses: heavy-duty/ceremony/actions/runner-isolated@<pinned-tag>
   ```

   `changelog-armed` and `drill-recorded` take
   `version-source: package-json` where that is the backend; every guard's
   inputs and defaults are in its `action.yml`
   ([actions/](../actions/)). Adopting the agent team flow adds the
   `docs-sync` step ([below](#adopting-the-agent-team-flow)).

   `runner-isolated` asserts that no `pull_request`-triggered workflow
   names a self-hosted runner — a PR workflow runs the branch's code, and
   unreviewed fork code must never execute on your own hardware
   ([#58](https://github.com/heavy-duty/ceremony/issues/58)). It fires on
   the PR that first mixes a PR trigger and a self-hosted `runs-on` in
   one file; the unblock is splitting the workflow. A repo with **no**
   self-hosted runner still wants it: the guard's value is the day
   somebody adds one.

   This guide documents `main`. New machinery is marked **unreleased**
   here until a release tag ships it. If an action does not exist at the
   consumer's pinned tag, adopt it with the pin bump to the first tag that
   carries it; never mix a moving or newer ref into an otherwise exact-pin
   consumer. In particular, `0.1.0` carries `changelog-armed`,
   `changelog-monotonic` and `drill-recorded` plus `docs-sync`, but not
   `changelog-assembled` or `runner-isolated`.
6. **Labels automation** (optional but recommended): the caller from
   [Labels automation](#labels-automation), plus `.github/labels.conf`
   (panel + the repo's `scope:*` rows) and `.github/labeler.yml` (the
   path→scope globs). Run `workflow_dispatch` once — **this bootstraps
   the taxonomy, `release` label included**.
7. **The artifact hook** (optional): `.github/actions/release-artifact/`
   per [The artifact hook](#the-artifact-hook). No hook → the source
   tarball is the package.

From there the flow is the doctrine: ordinary PRs write their fragment,
the ceremony PR makes
[the three stamps](../README.md#what-a-release-is), a human merges, the
machine transcribes.

## Convert an existing repo

The box/rig/cast path — the repo carries its own copy of the machinery
and hands it over. The conversion PR is release-flow work: label it
`release` if the repo's conventions ask for that, and either way it lands
as a green `NOTICE` no-op on main — the decide table's green rows exist
precisely so the machinery is safe to work on
([lib/decide.sh](../lib/decide.sh#L6-L12)).

- [ ] Replace `.github/workflows/release.yml` with the caller from
      [Release workflow](#release-workflow) — **whole file**, keeping its
      load-bearing comments. Check the result has **one** `push:` key
      carrying both filters: YAML maps are last-key-wins, and a second
      sibling `push:` silently kills a door (rig's review catch).
- [ ] Swap the guard *script* steps in `ci.yml` for the `uses:` steps in
      the bootstrap list above (with `fetch-depth: 0` on the checkout).
- [ ] Replace `labels.yml` with the caller from
      [Labels automation](#labels-automation); extract
      `.github/labels.conf` from the old reconciler's embedded config —
      the `panel=` roster line and the repo's `scope:*` rows
      ([the format](#labels-automation)). `.github/labeler.yml` stays as
      it is (path globs are inherently repo-specific).
- [ ] Convert the changelog to fragments (requires a pin at the first tag
      carrying fragment mode — not `0.1.0`): move every entry under
      `## Unreleased` to `changelog.d/<issue>.md`, verbatim — the filename
      is derivable from the entry's own `(#N)`; an entry citing several
      issues goes to the file for the first cited — delete the
      `## Unreleased` heading, and add the `changelog.d/README.md` marker
      ([bootstrap step 2](#bootstrap-a-new-repo)). Published sections stay
      byte-identical; `changelog-monotonic` proves that on the conversion
      PR, and `changelog-armed` refuses a surviving `## Unreleased` the
      moment the directory exists. Rewrite the repo's own contributor
      docs that say "add a line under `## Unreleased`" in the same PR —
      split either way, main lies for as long as the split lasts.
- [ ] Delete the now-shadowed copies — zero shared scripts remain:
      `.github/scripts/release-notes.sh` (box, cast) or
      `release-lib.sh` (rig), `changelog-armed.sh` (box),
      `changelog-monotonic.sh`, `drill-recorded.sh`,
      `labels-reconcile.sh`.
- [ ] Trim the repo's test suite to repo-specific tests: the machinery
      tests go — they live in this repo's `test/` now, run by its CI —
      while the repo's own surfaces stay (box/rig's install-channel halves
      of `test/release.sh`, cast's `install-sh` tests). A machinery test
      *file* goes whole when its subject moved (rig's
      `test/labels-reconcile.sh` sourced the deleted reconciler), and so
      do tests that pin the old workflow's shape — a grep or awk against
      `release.yml`/`ci.yml` internals fails against the caller stub, not
      because the stub is wrong (rig #13's conversion).
- [ ] Sweep the repo's other docs for pointers at the deleted paths —
      `drills/README.md` and any labels doc typically cite the old
      `.github/scripts/*.sh` by path; repoint them at the pinned actions.
      A repo carrying its own copy of a doc the mirror vendors (rig's
      root `LABELS.md`) retires it in the same PR: a hand-maintained
      copy beside a machine-verified mirror is the drift the mirror
      exists to end.
- [ ] Shrink CONTRIBUTING's release section to a pointer at
      [this repo's README](../README.md) plus what is genuinely per-repo:
      the drill meaning (`drills/README.md`), artifact notes, the
      changelog house style if it differs from
      [the portable rule](#the-changelog-rule).
- [ ] What stays, per repo, forever: `VERSION` (or the `package.json`
      version), `CHANGELOG.md`, `changelog.d/`, `drills/`, `.github/labeler.yml`,
      `.github/labels.conf`, the optional
      `.github/actions/release-artifact/` — the full kept-vs-moved table
      is in [#1](https://github.com/heavy-duty/ceremony/issues/1).

## Release workflow

The reusable release workflow implements both doors of the ceremony — the
merge door (merging the `release`-labeled ceremony PR ships it) and the tag
door (a bare `X.Y.Z` tag push as the manual fallback and backfill). The
design essay lives in the workflow's own header comment; the doctrine in
issue #1.

The consumer's **entire** `release.yml`:

```yaml
name: release
# Triggers and permissions MUST live here (a called workflow cannot define them):
on:
  # ONE push key, both filters — YAML maps are last-key-wins; a second sibling
  # `push:` silently replaces the first and kills a door (rig's review catch).
  push:
    tags: ["**"]      # every tag — a wrong tag must FAIL the assert loudly,
                      # never be skipped by a shape filter that didn't match
    branches: [main]
permissions:
  contents: write       # tag ref create + release create + the bump push
  pull-requests: write  # decide's label read; the bump-fallback `gh pr create`
  issues: write         # --label on that fallback PR rides the issues API
jobs:
  release:
    uses: heavy-duty/ceremony/.github/workflows/release.yml@<pinned-tag>
    with:
      version-source: file   # or: package-json
```

`version-source` is the only input: `file` (a `VERSION` file — box, rig,
incubator) or `package-json` (the version field, lockfile kept in sync on
the post-release bump — cast). Everything else a repo might vary is a change
to the ceremony itself, made in this repo, once.

Keep the merge door on `push` to `main` — never `pull_request`: a
`pull_request` run from a public fork gets a read-only `GITHUB_TOKEN` that
`permissions:` cannot raise (box#97), and every ceremony PR in this org is
cross-repo from a bot fork.

Bootstrap the version at `X.Y.Z-dev`, not bare: a first version that never
carried `-dev` hits the decide table's refuse row and has to ship by the
tag door instead (the known first-release edge, cast#111).

### The artifact hook

If the repository contains `.github/actions/release-artifact/action.yml`,
both doors invoke it — after the tag exists, before `gh release create` —
with the release `version` as input and `RELEASE_ASSETS_DIR` exported.
Contract for hook authors:

- Drop finished files into `$RELEASE_ASSETS_DIR`; every file there is
  uploaded as a release asset.
- Exit non-zero to abort the release.
- The hook owns its own toolchain (checkout is done; install node, docker,
  whatever it needs, itself).

A failed hook leaves the tag created but no release published. Recovery is
the tag door's semantics: fix the cause, then delete and re-push the same
tag (the tag door publishes for it), or run `gh release create` by hand from
a fixed tree. The merge door's nothing-exists assert will refuse a re-run of
the completed merge, by design.

No hook → no assets: for a pure-bash tree, GitHub's source tarball for the
tag IS the package. Worked examples land with the conversions: cast's tgz
build (#15) and incubator's GHCR image push (#16).

## Labels automation

The reusable labels workflow owns two independent jobs: additive path-based
`scope:*` labels and reconciliation of PR state, blockers, handoff, stale
status, and the `needs-ruling` invariants on both surfaces — the bare-flag
check and the 7-day comment-only nudge (#52; the sweep reads that flag and
never writes it). The consumer keeps its path mapping in
`.github/labeler.yml` and its review panel plus scope taxonomy in
`.github/labels.conf`.

**Additive means additive** (unreleased — #130): the scope job's only label
write is `POST /issues/{n}/labels`, which adds the derived scopes and removes
nothing, so a label applied while the job runs survives it. Earlier tags used
`actions/labeler@v5`, which — even under `sync-labels: false` — replaces the
whole label set and silently drops a label written mid-job (ceremony#128 lost
its `release` that way). With the same pin bump, `.github/labeler.yml` keeps
its format but the accepted shape becomes exactly the one this guide has
always shown: label → `changed-files` → `any-glob-to-any-file`, block or flow
style, globs over `**`, `*` and `?` (`**` crosses `/`, the others do not; the
whole path must match). Any other labeler key — `all-globs-to-all-files`,
branch matchers, negations — fails the run loudly instead of being
half-honoured. The reconcile sweep also warns (never sets) when a non-draft
PR carries a bare `X.Y.Z` version differing from its base but no `release`
label — the merge door would refuse that merge, and the sweep says so first.

The complete caller is:

```yaml
name: labels
on:
  schedule: [{cron: "*/15 * * * *"}] # advisory; the handoff label is the real wake
  workflow_dispatch:                 # bootstraps missing labels on a fresh repo
  pull_request_target:
    # review_requested/review_request_removed are unreleased — not in 0.2.0;
    # add them with the pin bump to the first tag carrying ceremony#137. They
    # wake the sweep that clears blocker:unrequested when the panel is asked.
    types: [opened, reopened, ready_for_review, converted_to_draft, synchronize, labeled, unlabeled, review_requested, review_request_removed]
  # Available at 0.2.0 and later (the first tag carrying ceremony#32); a
  # consumer pinned to 0.1.0 omits this block.
  issues:
    # edited/reopened are unreleased — not in 0.2.0; add them with the pin
    # bump to the first tag carrying ceremony#144, the same bump as the
    # pull_request_target additions above.
    types: [opened, edited, assigned, unassigned, labeled, unlabeled, closed, reopened]
permissions:
  contents: read
  checks: read          # mergeability/check-rollup read for PR state
  statuses: read        # commit-status rollup read for PR state
  actions: read         # workflow-run nodes inside the check rollup — private repos do not imply it (incubator#60)
  issues: write
  pull-requests: write
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@<pinned-tag>
```

Naming any permission sets every unnamed permission to `none`. Public
repositories allow check data to be read regardless, but a private consumer
needs all three explicit reads above; without them the failure appears as an empty
`state:*` axis on the board rather than a red workflow run.

The `issues:` trigger is available at `0.2.0` and later — `0.2.0` is the
first tag carrying ceremony#32. A consumer pinned to `0.1.0` omits it. Adopt
it only by bumping every ceremony reference to `0.2.0` or later; never mix
refs to adopt it early. At `0.2.0` the type list stops at `closed`: `edited`
and `reopened` are newer, part of the pending stub edit below.

`pull_request_target` is intentional: fork PRs need the base repository's
token to write labels. The reusable workflow executes no PR code. It checks
out only the consumer's base branch and the pinned ceremony implementation.
The #52 ruling invariants ride exactly these triggers — but the caller above
is no longer the #18 shape, so adopting current triggers is a stub edit, not
a bare pin bump. The pending edits are `review_requested` and
`review_request_removed` on `pull_request_target:` (#137) — the wake that
clears `blocker:unrequested` the moment the panel is asked, without which a
quiet repo wears that flag until the advisory cron — and `edited` and
`reopened` on `issues:` (#144): the wakes for a body edit rewriting the
`Blocked by #N` declaration the reconcile sweep parses, and for a closed
issue re-entering the queue wearing labels derived when it closed. Make both
edits together, with the pin bump to the first tag carrying ceremony#137 and
ceremony#144 — never before it and never through mixed refs.

`.github/labels.conf` has one mandatory panel setting, one mandatory
`triage-actors` setting, and then zero or more scope rows:

```text
panel=claude-bot example-codex-bot example-grok-bot
triage-actors=example-triage-bot
scope:cli|C5DEF5|The command-line surface
scope:docs|C5DEF5|Documentation
```

The mandatory `triage-actors=` setting is likewise accepted at `0.2.0` and
later, and not by `0.1.0`. At that tag the file contains `panel=` plus scope
rows only; adding `triage-actors=` is a parse failure, not an ignored setting.
Add it at the same pin bump as the `issues:` trigger — `0.2.0` or later —
never before it and never through mixed refs.

Both actor lists are whitespace-separated. `triage-actors` names the identities
allowed to mint issues without the sweep applying `needs-triage`. Label rows use exactly
`name|color|description`; blank lines are ignored and extra pipes are refused.
There are no comment lines: every non-blank line must be the `panel=`
setting, the `triage-actors=` setting, or a label row, so `#`-prefixed prose
is a parse failure, not a comment (rig #13's conversion found this the hard
way — keep the file data only).
Core state, blocker, work-queue, and release labels come from ceremony. Scope
rows remain consumer-owned because paths and surfaces differ by repository.

After adding the caller and configuration, run `workflow_dispatch` once to
bootstrap labels on a fresh repository. Scheduled and PR-triggered runs only
reconcile; they do not repeatedly upsert the taxonomy. When a ceremony pin
bump adds a core label, bump the pin first and then re-dispatch
`workflow_dispatch`; the scheduled sweep warns when the pinned taxonomy
declares a core label the repository lacks.

## Doctrine mirror

Machinery is consumed by reference — GitHub fetches the workflows and
actions above from the pin at run time — but documents have no runtime: an
agent reads the working tree it stands in. So the agent-facing doc set
(ceremony's `docs/VENDORED.txt`: AGENTS.md, TRIAGE.md, BUILDER.md,
REVIEWER.md, LABELS.md) is vendored into each consumer at **`.ceremony/`**,
byte-identical to ceremony at the pin, plus a generated `.ceremony/README.md`
marking the directory machine-managed. `actions/docs-sync` owns the copy:
`--fix` writes it (and deletes what the manifest dropped — mirror means
mirror), `--check` re-diffs it in CI on every PR, so a hand edit or a stale
pin goes red instead of quietly governing.

The consumer's ci.yml gains the guard alongside the others:

```yaml
      - uses: actions/checkout@v4
      - uses: heavy-duty/ceremony/actions/docs-sync@<pinned-tag>
```

`mode` defaults to `check`. There is no ref input: the action reads the pin
from the consumer's own `.github/workflows/release.yml` — the same single
`uses: …/release.yml@<ref>` line that pins the machinery, so one pin governs
machinery and doctrine alike, and a second pin cannot fall out of sync.

**Bootstrap on adoption**: add the release and labels callers first (the pin
must exist — the mirror is verified against it), then run `--fix` once from
the repo root and commit `.ceremony/` together with the callers:

```sh
curl -fsSL "https://raw.githubusercontent.com/heavy-duty/ceremony/<pinned-tag>/actions/docs-sync/docs-sync.sh" \
  | bash -s -- --fix
```

If the repo has no root `AGENTS.md`, `--fix` also scaffolds the thin stub
that routes agents to `.ceremony/AGENTS.md` — created once, never
overwritten; it is per-repo content the moment you edit it, so `--check`
asserts only that it exists.

Bumping the pin re-syncs the mirror in the same PR —
[the pin-bump procedure](#the-pin-bump-procedure).

## Version pinning

- **Pin an exact ceremony release tag** — `@0.1.0`, never a branch and
  never a moving major pointer: the family pins things and reviews
  updates ([#1 D2](https://github.com/heavy-duty/ceremony/issues/1)).
  Every `uses:` of this repo in the consumer — the two workflow callers
  and the guard steps — names the same tag.
- **Bump by PR, every reference together.** Before bumping, read the
  ceremony's own `CHANGELOG.md` section for the new version (the release
  body on its
  [releases page](https://github.com/heavy-duty/ceremony/releases) is
  that section, verbatim). One bump PR updates **every** ceremony `uses:`
  reference in the repo to the new tag — the workflow callers *and* each
  guard step. The exact count is tag-dependent: it is the workflow caller
  or callers plus the guards that the pinned tag carries. Changing only
  one line leaves the consumer split across ceremony versions, which the
  same-tag rule above forbids. A repo that has adopted the agent team flow
  additionally bumps the mirror in the same PR —
  [the pin-bump procedure](#the-pin-bump-procedure).
- **One pin governs machinery and doctrine.** The ref in the consumer's
  `release.yml` `uses:` line is the single pin: `docs-sync` reads it from
  exactly there and verifies the `.ceremony/` mirror against it — there
  is no second pin to fall out of sync (#19).

## The changelog rule

The portable version of the family's contributor rule — the repo's own
CONTRIBUTING may sharpen it, but this is the floor the guards assume:

- **Every PR that changes behavior writes one fragment**:
  `changelog.d/<issue>.md`, named for the authorizing issue —
  `<repo>-<issue>.md` for cross-repo work carrying `Part of <repo>#N` —
  so the name is known at claim time and two builders can only collide by
  working the same issue (#112 D2). Never an edit to `CHANGELOG.md`: the
  release PR assembles the section
  ([below](#assembling-a-release-section)).

  The sole exception is the release PR: it writes no fragment. It consumes
  the directory and stamps the section, so a fragment it created would be
  absent from
  [`changelog-assembled`](https://github.com/heavy-duty/ceremony/blob/a602fd0/actions/changelog-assembled/changelog-assembled.sh)'s
  merge-base replay if consumed, or refused by
  [`changelog-armed`](https://github.com/heavy-duty/ceremony/blob/a602fd0/actions/changelog-armed/changelog-armed.sh)
  if left to survive into the next release. A change that must ship inside
  the release PR therefore ships without an entry. If it can wait and wants
  an entry, land it as an ordinary PR before the release PR, then rebase and
  re-assemble the release.
- **The fragment is the prose, not a description of it** (#112 D3): the
  exact lines that will be published — no front-matter, no `## ` heading
  (that one is the assembler's to write). `changelog-armed` refuses a
  malformed fragment on the PR that wrote it.
- **Grouped repos group inside the fragment**: `### Added`, `### Changed`,
  `### Fixed` headings with bullets under them; create `Deprecated`,
  `Removed`, or `Security` only when a change genuinely needs that rarer
  kind. A repo is grouped or flat, never both (#112 D4). The assembler
  merges groups in canonical order — Added, Changed, Fixed, Removed,
  Deprecated, Security, then anything else first-seen — and inside a
  group entries read newest issue first (#112 D5). Which shape binds is
  inferred from the newest published section, unless an optional sentinel
  `changelog.d/shape` — one line, exactly `flat` or `grouped` — declares
  it and outranks the inference (#182). To flip a repo's shape, land one
  PR that adds the sentinel and converts every pending fragment to the
  declared shape, bullets byte-identical; the sentinel stays after the
  release, as the declaration a reader in the directory finds.
- **One line: say what changed, and stop.** Lead with the surface, not
  the mechanism — "`state:needs-human` is set at handoff" beats "the
  labels workflow now also wakes on `labeled`". The why and the how
  belong in the PR body, where anyone chasing the reasoning already goes.
- **Cite the issue or PR** — `(#141)`.
- **Mark a breaking change** with a leading `BREAKING:`.
- A repo not yet on fragment mode — no `changelog.d/` — keeps the legacy
  floor until its conversion: one line under `## Unreleased`, inserted
  **above** the heading below it, never over it (replacing a shipped
  heading deletes that release's section silently — box#122, why the
  [monotonic guard](../README.md#changelog-monotonic--shipped-headings-are-append-only)
  exists), appended under a standing `### ` heading where the repo groups.

## Assembling a release section

The ceremony PR's changelog stamp is one command, run **by hand, never in
CI** — the assembled section must land in the release PR's diff, where
the panel reads it (#112 D12). A consumer runs the tool from a ceremony
checkout at its own pin:

```sh
git clone --depth 1 --branch <pinned-tag> https://github.com/heavy-duty/ceremony /tmp/ceremony
/tmp/ceremony/bin/changelog-assemble <X.Y.Z>
```

Run it at the repo root. It folds every `changelog.d/` fragment into a
new `## X.Y.Z — DATE` section on top of `CHANGELOG.md` (DATE is today's
UTC date; pass one as a second argument to choose it) and deletes the
fragments it consumed — commit both halves together. `--check` prints the
would-be section body without touching anything; read it before running
the real thing. In CI, `changelog-assembled` replays the run from the
merge base and refuses a stamp that is not byte-for-byte what the
fragments assemble to — a mis-run hand step fails the PR, not the
published release.

## Adopting the agent team flow

The team flow (discussion → triage → issue → build → review → human
merge) is **optional per repo and separable from the release ceremony**:
a repo can adopt release-only and take the team flow later — incubator's
initial posture (#16). The model is this repo's own
[CONTRIBUTING](../CONTRIBUTING.md) ("How the other repos use this");
this is the checklist:

- [ ] **Enable Discussions** — the triage door exists or the pipeline
      has no intake.
- [ ] **Vendor the doctrine**: run `docs-sync --fix` (#19) to materialize
      `.ceremony/{AGENTS,TRIAGE,BUILDER,REVIEWER,LABELS}.md` —
      byte-identical to this repo at the pinned ref — plus the generated
      `.ceremony/README.md` (machine-managed marker) and, if the repo has
      none, the thin root `AGENTS.md` stub ("governed by
      heavy-duty/ceremony; read `.ceremony/AGENTS.md` first; repo
      specifics in CONTRIBUTING"). The stub is scaffolded once and never
      overwritten; the mirror is machine-written and never hand-edited.
      Commit `.ceremony/` together with the workflow callers.
- [ ] **Guard the mirror in CI**: add the `docs-sync` check step
      alongside the other guards —

      ```yaml
          - uses: heavy-duty/ceremony/actions/docs-sync@<pinned-tag>
      ```

      (`mode: check` is the default.) Hand-editing a vendored file, or
      bumping the pin without re-syncing, goes red (#19).
- [ ] **Reduce tool-specific files** (`CLAUDE.md`, …) to one pointer line
      at the root `AGENTS.md`, so every harness converges on the same
      router.
- [ ] **Point CONTRIBUTING at the mirror**: a short header telling agents
      to read `.ceremony/` first — agents never leave the working tree to
      read the rules — followed by only what is genuinely per-repo: the
      review panel roster, the `scope:*` set, the drill meaning, the
      repo's code conventions.
- [ ] **Name the review panel**: the roster table in CONTRIBUTING and the
      `panel=` line in `.github/labels.conf` — the required verdicts for
      any PR are the panel minus its author (#10).
- [ ] **Bootstrap the issue-flow labels**: the labels
      `workflow_dispatch` once ([above](#labels-automation)), or the hand
      commands in [LABELS.md](../LABELS.md).
- [ ] **State the single-writer rule** in the repo's own docs: only
      triage mints issues; everyone else opens discussions.

### The pin-bump procedure

Bumping the ceremony pin is **one PR carrying both halves**: every
ceremony `uses:` reference — the workflow callers *and* each guard step,
[all to the same new tag](#version-pinning) — and the re-synced
`.ceremony/` mirror —
run `docs-sync --fix` locally, or let the red `--check` on the bump PR
tell you what is stale. The CI guard is what makes a half-done bump —
pin without mirror, or mirror without pin — unmergeable (#19). This is
how a process change rolls out to a governed repo: deliberately, per
repo, reviewed.
