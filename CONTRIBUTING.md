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
- **Builders turn one issue into an ordered chain of PRs**, normally one — a
  round cap cuts a sixth round into a successor PR. [BUILDER.md](BUILDER.md).
- **Reviewers converge on a verdict.** [REVIEWER.md](REVIEWER.md).
- **Humans decide twice**: in the discussion (what is worth doing, and any
  call triage escalates back) and at the merge (whether it ships). Everything
  between those two points is agent work by default.
- **Merging a release PR ships it** — the release ceremony this repo's
  workflows implement (README, issue #1).

Who may set which label is [LABELS.md](LABELS.md)'s contract.

## The PR flow

PRs move through review rounds that builders answer whole, and only a human
merges. [BUILDER.md](BUILDER.md) is the shared flow contract; this file names
only ceremony-specific facts such as the roster and code conventions.

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

## Doctrine conventions

The vendored role files — the set [`docs/VENDORED.txt`](docs/VENDORED.txt)
declares — state each normative rule completely, keep at most one sentence of
why, and cite its record only with a bare parenthetical such as `(#N)`,
`(#N D3)`, or `(#N, #M)`. Incident narrative — timestamps, actors, quoted
comments, measured counts, and links to specific comments — belongs in that
record. If a rule cannot be followed without chasing its cite, the rule is
under-stated: fix the statement, not the citation. (#280)

Normative text in those files does not reference another repository's issues,
pull requests, discussions, or files. Consumers read the vendored bytes
outside this organization's context, and a referenced repository may not be
public. A repo-boundary deferral remains allowed: it names another component
as the owner of a fact rather than referencing a record in that component.
(#280, #408)

This is distinct from the code-comment convention above: a code comment is
read by a maintainer inside the organization while standing in the file,
whereas vendored doctrine is read by any agent in any governed repository on
every session. (#280)

## How the other repos use this

Two consumption modes, split by what has a runtime: **machinery by
reference**, fetched at run time from the ref a caller pins, and **doctrine
as a mirror** — the set [`docs/VENDORED.txt`](docs/VENDORED.txt) declares,
vendored at `.ceremony/` and held to the pin by a guard (issue #19). The
[README](README.md) states both modes in full, and why they differ; what
follows is only what they leave a governed repo to carry.

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
