# Contributing

This repo defines how the heavy-duty repos work — the release ceremony, the
label state machine, and the agent team flow — and it runs entirely on its own
rules. If something here contradicts how this repo actually operates, one of
the two is a bug.

## The line

Work moves through one pipeline, and every stage has an owner:

```
discussion ──▶ triage ──▶ issue ──▶ build ──▶ review ──▶ human merge ──▶ release
 (anyone)     (agent)   (queue)    (agent)   (agents)     (human)      (ceremony)
```

- **Discussions are where intent lives.** Anyone — human or agent — who has an
  idea, a bug, a question, or a "we should…" opens a **discussion**, not an
  issue. Discussions are allowed to be vague; that is what they are for.
- **Issues are minted only by triage.** Nobody else writes issues — not
  humans, not builders, not reviewers. An issue is a work order with a quality
  bar (the issue contract in [TRIAGE.md](TRIAGE.md)), and the bar holds
  because exactly one role is accountable for it. An issue that appears
  through any other door gets `needs-triage` and is normalized or converted
  back into a discussion.
- **Builders turn one issue into one PR.** [BUILDER.md](BUILDER.md).
- **Reviewers converge on a verdict.** [REVIEWER.md](REVIEWER.md).
- **Humans decide twice**: in the discussion (what is worth doing, and any
  call triage escalates back) and at the merge (whether it ships). Everything
  between those two points is agent work by default.
- **Merging a release PR ships it** — the release ceremony this repo's
  workflows implement (README, issue #1).

Who may set which label is [LABELS.md](LABELS.md)'s contract.

## The PR flow

The same flow the sibling repos run, and the part of this pipeline that is
already proven:

1. **One issue, one PR**, opened as a **draft** while building, with
   `Closes #N` in the body — its exceptions (cross-repo work, a post-merge
   criterion) live in [BUILDER.md](BUILDER.md). Drafts are invisible to the
   reviewer panel on purpose. Every behavior change writes one fragment,
   `changelog.d/<issue>.md` — the exact prose to publish, nothing else
   (cross-repo work names it `<repo>-<issue>.md`; a grouped repo puts its
   `### Added` / `### Changed` / `### Fixed` headings inside the fragment).
   Never edit `CHANGELOG.md` for an entry — the release PR assembles the
   section from the fragments (#112).

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
2. **When it's ready**: mark ready-for-review and request the whole panel.
3. **Rounds are answered whole.** Wait until every reviewer has a verdict in,
   then answer the entire round in a **single reply**, push the fixes, and
   re-request the reviewers that didn't approve. Prefer verification over
   argument: a test settles what a comment thread can't.
4. **Reviews end in a verdict** — approve or request-changes, never a bare
   comment. The verdict carries blockingness only; the body carries the
   feedback. ([REVIEWER.md](REVIEWER.md) for why a comment-only review stalls
   the machine.)
5. **Handoff**: when the round passes — every panel verdict is an approval of
   the current head and no `blocker:*` label stands — the engine requests the
   human's review, sets `state:needs-human`, and posts the handoff facts
   (approvals at the current head, head SHA, and Round-log pointer) on the
   author's behalf. The label write is optimistic; the reconciler validates
   it within seconds.
6. **A human merges.** Nothing else merges.

### Roster

Five identities share the work (org team `agents`), each living in its own
[box](https://github.com/heavy-duty/box) — one box per credential, because
the box is the blast-radius boundary; roles are what a session is told, and
[AGENTS.md](AGENTS.md) routes from there:

| identity | box (rig tenant) | standing work |
|---|---|---|
| `dan-claude-bot` | `triage` (claude-box) | **triage** — the only door issues come through; this identity mints issues and nothing else writes them (#18's `triage-actors`) |
| `claude-bot-andresmgsl` | claude-box | build (release-flow and guards machinery) + review |
| `codex-bot-andresmgsl` | codex-box | build (scaffolding, conversions) + review |
| `grok-bot-andresmgsl` | grok-box | review |
| `kimi-bot-andresmgsl` | kimi-box | review — builder trial on a small mechanical issue once its verdicts have a track record |

**The review panel for any PR is every bench identity except its author** —
recusal by construction, enforced by the reconciler (#10): the required
verdicts are the panel minus the PR's author, so convergence always means
three cross-vendor approvals of the current head. Builders and triage
default to different models so the issue contract is honestly exercised —
a spec gap should surface as a question on the issue, not be silently filled
by shared priors. Humans (`danmt`) decide in discussions and merge; the
roster is config, not doctrine — swapping a vendor is an edit to this table
(and to `panel=` in `.github/labels.conf` once #10 lands), nothing more.

Each governed repo names its own roster in its CONTRIBUTING; this one is
ceremony's. Its `scope:*` set is the same kind of repo-specific fact:
ceremony's scopes are defined in [`.github/labels.conf`](.github/labels.conf)
— one `name|color|description` row each, with PR path mapping in
[`.github/labeler.yml`](.github/labeler.yml). The conf is the set; no prose
table repeats it (#104).

## Code conventions

- Bash: `set -euo pipefail` in executables, `set -u` in test files (the test
  harness asserts on failing commands, so no `-e` there).
- **mawk-compatible awk** — CI runners ship mawk, not gawk; no `\x` escapes.
- **Every piece of logic is a file of its own so a test can drive it.**
  Workflows and actions gather facts; scripts decide. If a decision lives
  inline in YAML, it is in the wrong place.
- Comments carry the *why* — the incident that bought the rule, with its
  issue number (`box#108`, `rig#66`, …). When porting from a sibling repo,
  the war stories come along; they are the documentation.
- Whole-version matching everywhere: `0.7.0` never matches `0.7.0-rc1`.
- Shellcheck- and actionlint-clean is a CI gate, not a suggestion.

## How the other repos use this

Two consumption modes, split by what has a runtime:

- **Machinery is consumed by reference.** Workflows and actions are fetched
  by GitHub at run time from the ref the caller pins — no copy exists in the
  consumer.
- **Doctrine is consumed as a machine-verified mirror.** A document's only
  "runtime" is an agent reading the working tree of the repo it stands in —
  a doc that requires a cross-repo fetch before it governs is a doc that
  sometimes goes unread. So the agent-facing set — **AGENTS.md, TRIAGE.md,
  BUILDER.md, REVIEWER.md, LABELS.md** — is vendored into each governed
  repo at **`.ceremony/`**, byte-identical to this repo at the pinned ref,
  by the sync tool (issue #19). A CI guard diffs the mirror against the pin
  on every PR: hand-editing a vendored file, or bumping the pin without
  re-syncing, goes red. It is a copy that cannot drift — which is the only
  kind of copy this org allows.

A governed repo (box, rig, cast, incubator, …) therefore carries:

- `.ceremony/` — the vendored doctrine (machine-written; never edited by
  hand; agents read it from the checkout, no network, no other repo);
- a thin root **`AGENTS.md` stub** — a few lines: "governed by
  heavy-duty/ceremony; read `.ceremony/AGENTS.md` first; repo specifics in
  CONTRIBUTING". The stub is what makes "you are a reviewer here" a
  sufficient launch prompt: agent harnesses auto-load root AGENTS.md (the
  cross-agent convention), and the vendored router takes it from there.
  Tool-specific files (`CLAUDE.md`, …) reduce to one pointer line at it;
- the thin workflow callers (release, labels) pinned to a ceremony tag, plus
  the `docs-sync --check` guard step in CI;
- a short header in its own CONTRIBUTING pointing agents at `.ceremony/`,
  followed by only what is genuinely per-repo:
  - the **review panel roster**,
  - the **`scope:*` label set** (`.github/labels.conf` + `.github/labeler.yml`),
  - the **drill meaning** (`drills/README.md`),
  - the repo's own code conventions;
- **Discussions enabled**, so the triage door exists.

One pin governs both the machinery and the doctrine: the ref a repo's
workflows call is the ref its `.ceremony/` mirror is verified against.
Bumping the pin is one PR — the pin line plus the re-synced mirror, checked
by the same guard — and is how a process change rolls out: deliberately, per
repo, reviewed. The full adoption checklist lives in
[docs/CONSUMERS.md](docs/CONSUMERS.md) (issue #12).
