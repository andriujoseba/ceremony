#!/usr/bin/env bash
# Contract tests for actions/runner-isolated (issue #58). Constructed
# fixture trees — a dir holding a workflows directory, not git repos —
# the same discipline as the guards beside it. set -u, not -e: failing
# commands are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/actions/runner-isolated/runner-isolated.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The guard reads the consumer's tree at its working directory, so every
# case runs from inside a constructed fixture tree.
in_tree() {
  local dir="$1"
  shift
  (cd "$TMP/$dir" && bash "$SCRIPT" "$@")
}

# wf <tree> <file> — write .github/workflows/<file> in the tree from stdin.
wf() {
  mkdir -p "$TMP/$1/.github/workflows"
  cat >"$TMP/$1/.github/workflows/$2"
}

# --- the rows that must FAIL: they are the point of this file ----------------

# 1: block-form trigger + inline-list runner — incubator's deploy.yml
# shape with the one edit that would make it the bug.
wf block-list a.yml <<'YAML'
name: deploy checks
on:
  pull_request:
    types: [opened]
jobs:
  deploy:
    runs-on: [self-hosted, ci-runner]
    steps:
      - run: echo deploy
YAML
check "on: block + runs-on inline list fails" 1 "self-hosted" \
  in_tree block-list
check "failure names the offending file" 1 "a.yml" in_tree block-list
check "failure names the offending runs-on line" 1 "runs-on: [self-hosted, ci-runner]" \
  in_tree block-list

# 2: inline-list trigger + scalar runner.
wf inline-trigger a.yml <<'YAML'
name: ci
on: [push, pull_request]
jobs:
  build:
    runs-on: self-hosted
    steps:
      - run: echo build
YAML
check "on: inline list + runs-on scalar fails" 1 "self-hosted" \
  in_tree inline-trigger

# 3: scalar trigger + self-hosted — and a .yaml extension, so the second
# glob leg is load-bearing in at least one case.
wf scalar-trigger a.yaml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: self-hosted
    steps:
      - run: echo build
YAML
check "on: scalar + self-hosted fails, .yaml extension scanned" 1 "a.yaml" \
  in_tree scalar-trigger

# 4: the quoted key — YAML 1.1 parses bare `on` as a boolean, so some
# repos quote it; a guard that missed this form would silently pass the
# file it most needs to read.
wf quoted-on a.yml <<'YAML'
name: ci
"on":
  pull_request:
jobs:
  build:
    runs-on: self-hosted
    steps:
      - run: echo build
YAML
check "quoted \"on\": key + self-hosted fails" 1 "self-hosted" \
  in_tree quoted-on

# 5: pull_request_target that CHECKS OUT THE PR HEAD — base-branch
# privileges running PR-authored code, the most dangerous shape in the
# trigger surface and the row the guard could not see before #395. Until
# then this fixture had no checkout and failed for naming a label; the
# axis change moved that shape to a pass (the row below), so the failing
# row is now the one that earns it.
wf target a.yml <<'YAML'
name: ci
on:
  pull_request_target:
jobs:
  build:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - run: echo build
YAML
check "pull_request_target + a checkout of head.sha + self-hosted fails" 1 \
  "self-hosted" in_tree target
check "that failure says the checkout is why it derived as PR code" 1 \
  "checks out a PR ref" in_tree target

# 6: two jobs in one file — a PR-triggered hosted check AND a self-hosted
# job. Pins the file-level decision (#58 §3): a later "fix" to job
# granularity must be a deliberate change, not a silent one.
wf mixed-jobs a.yml <<'YAML'
name: ci
on:
  pull_request:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo check
  deploy:
    runs-on: [self-hosted, ci-runner]
    steps:
      - run: echo deploy
YAML
check "file-level rule: hosted PR check + self-hosted job in one file fails" 1 \
  "self-hosted" in_tree mixed-jobs

# The block-sequence runner — the same-line rule alone would pass this
# file, and a false negative is the one defect this guard is not allowed
# to have (the script header's why).
wf block-seq a.yml <<'YAML'
name: ci
on:
  pull_request:
jobs:
  deploy:
    runs-on:
      - self-hosted
      - ci-runner
    steps:
      - run: echo deploy
YAML
check "block-sequence runs-on: - self-hosted fails" 1 "self-hosted" \
  in_tree block-seq

# 11: multiple offenders across two files — BOTH named, not just the first.
wf two-files a.yml <<'YAML'
name: one
on: pull_request
jobs:
  a:
    runs-on: self-hosted
    steps:
      - run: echo a
YAML
wf two-files b.yml <<'YAML'
name: two
on: pull_request
jobs:
  b:
    runs-on: [self-hosted, other]
    steps:
      - run: echo b
YAML
check "two offending files: the first is named" 1 "a.yml" in_tree two-files
check "two offending files: the second is named too" 1 "b.yml" in_tree two-files

# --- the rows that must PASS: the legal shapes stay legal --------------------

# 7: push-only + self-hosted — incubator's deploy.yml, which must stay
# legal.
wf push-deploy deploy.yml <<'YAML'
name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: [self-hosted, ci-runner]
    steps:
      - run: echo deploy
YAML
check "push-only + self-hosted passes (deploy.yml's shape)" 0 "1 workflow file" \
  in_tree push-deploy

# The block-sequence window with no PR trigger: the window logic must not
# widen the rule past its two conditions.
wf push-block-seq deploy.yml <<'YAML'
name: deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on:
      - self-hosted
    steps:
      - run: echo deploy
YAML
check "push-only + block-sequence self-hosted passes" 0 "1 workflow file" \
  in_tree push-block-seq

# 8: PR trigger on a hosted runner — incubator's pr-checks.yml.
wf pr-hosted checks.yml <<'YAML'
name: checks
on:
  pull_request:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo check
YAML
check "pull_request + ubuntu-latest passes (pr-checks.yml's shape)" 0 \
  "1 workflow file" in_tree pr-hosted

# 9: self-hosted in a comment only — prose is not the bug; incubator's
# pr-checks.yml header is exactly this prose.
wf comment-only checks.yml <<'YAML'
name: checks
# Unreviewed branch code must never reach the self-hosted deploy runner.
on:
  pull_request:
jobs:
  check:
    # not: runs-on: self-hosted
    runs-on: ubuntu-latest
    steps:
      - run: echo check
YAML
check "self-hosted in comments only passes" 0 "1 workflow file" \
  in_tree comment-only

# 10: an empty workflows dir, and no workflows dir at all — both pass; a
# guard that fails on absence is a guard nobody adopts.
mkdir -p "$TMP/empty-dir/.github/workflows"
check "empty workflows dir passes" 0 "0 workflow files" in_tree empty-dir
mkdir -p "$TMP/no-dir"
check "missing workflows dir passes" 0 "no workflows directory" in_tree no-dir

# 12: a schedule trigger with self-hosted and no PR trigger — the runner
# half alone is not the offence.
wf scheduled nightly.yml <<'YAML'
name: nightly
on:
  schedule:
    - cron: '0 3 * * *'
jobs:
  sweep:
    runs-on: [self-hosted, ci-runner]
    steps:
      - run: echo sweep
YAML
check "schedule + self-hosted, no PR trigger, passes" 0 "1 workflow file" \
  in_tree scheduled

# The trigger-block span: pull_request below the on: block (here, a step
# name in jobs:) is not a trigger. Guards the block-end detection.
wf pr-elsewhere build.yml <<'YAML'
name: build
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: [self-hosted, ci-runner]
    steps:
      - name: mention pull_request in a step name
        run: echo build
YAML
check "pull_request outside the on: block is not a trigger" 0 \
  "1 workflow file" in_tree pr-elsewhere

# --- a non-default workflows dir, as arg and as the action's env var ---------

mkdir -p "$TMP/alt-dir/ci-flows"
cat >"$TMP/alt-dir/ci-flows/a.yml" <<'YAML'
name: ci
on: pull_request
jobs:
  a:
    runs-on: self-hosted
    steps:
      - run: echo a
YAML
check "a non-default workflows dir is honored as an argument" 1 "ci-flows/a.yml" \
  in_tree alt-dir ci-flows

# A non-default dir proves the env var is honored, not the default —
# the same wiring proof drill-recorded's suite carries.
env_tree() {
  (cd "$TMP/alt-dir" && WORKFLOWS_DIR=ci-flows bash "$SCRIPT")
}
check "the env var drives the script the way action.yml does" 1 \
  "ci-flows/a.yml" env_tree

# --- ceremony's own tree — the same tree self-guards runs against ------------

# A future workflow change that breaks this guard's parsing should show
# up as a unit-test failure, not only as a red CI job.
own_tree() {
  (cd "$ROOT" && bash "$SCRIPT")
}
check "ceremony's own .github/workflows passes" 0 \
  "no PR-authored code on an unvouched self-hosted runner" own_tree

# --- #395: the axis is "executes PR-authored code", not "is PR-triggered" ----

# The row the first version got backwards, and the reason the fixture
# above had to change: a pull_request_target caller that checks out
# nothing executes no PR-authored code. It passes with NO allowlist entry
# — this is incubator's labels.yml shape, and requiring an opt-in here is
# what sank #389 (decisions 4 and 6).
wf target-no-checkout a.yml <<'YAML'
name: labels
on:
  pull_request_target:
    types: [opened, labeled]
jobs:
  labels:
    runs-on: [self-hosted, ci-runner]
    steps:
      - run: echo labels
YAML
check "pull_request_target + self-hosted + no PR checkout passes, no input" 0 \
  "1 workflow file" in_tree target-no-checkout

# …and it passes because it was READ, not because the scan skipped it: the
# same tree fails the moment the trigger is the one that implies PR code.
wf target-flipped a.yml <<'YAML'
name: labels
on:
  pull_request:
    types: [opened, labeled]
jobs:
  labels:
    runs-on: [self-hosted, ci-runner]
    steps:
      - run: echo labels
YAML
check "the same file under pull_request fails — the trigger is the axis" 1 \
  "ci-runner" in_tree target-flipped

# A ref: that is not a PR ref does not make a pull_request_target file
# execute PR code. Without this row "any ref: line" would pass the suite.
wf target-plain-ref a.yml <<'YAML'
name: labels
on:
  pull_request_target:
jobs:
  labels:
    runs-on: [self-hosted, ci-runner]
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main
      - run: echo labels
YAML
check "pull_request_target + a checkout of main is not a PR checkout" 0 \
  "1 workflow file" in_tree target-plain-ref

# The other two spellings of the same checkout. head.ref is named by the
# ruling; github.head_ref is the same shape in GitHub's own docs and is
# read the same way — over-reading a ref: line can only make a file derive
# as executing PR code, never permit one.
wf target-head-ref a.yml <<'YAML'
name: ci
on:
  pull_request_target:
jobs:
  build:
    runs-on: [self-hosted, ci-runner]
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.ref }}
      - run: echo build
YAML
check "pull_request_target + a checkout of head.ref fails" 1 "ci-runner" \
  in_tree target-head-ref

wf target-github-head-ref a.yml <<'YAML'
name: ci
on:
  pull_request_target:
jobs:
  build:
    runs-on: [self-hosted, ci-runner]
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.head_ref }}
      - run: echo build
YAML
check "pull_request_target + a checkout of github.head_ref fails" 1 "ci-runner" \
  in_tree target-github-head-ref

# The fourth spelling, and the one that names neither expression above:
# `refs/pull/N/merge` built from github.event.number. It is the same
# checkout of the same PR-authored code, so the ref: match reads the path
# as well as the two expressions (#395 round 1, claude-bot's first nit).
wf target-refs-pull a.yml <<'YAML'
name: ci
on:
  pull_request_target:
jobs:
  build:
    runs-on: [self-hosted, ci-runner]
    steps:
      - uses: actions/checkout@v4
        with:
          ref: refs/pull/${{ github.event.number }}/merge
      - run: echo build
YAML
check "pull_request_target + a checkout of refs/pull/N/merge fails" 1 "ci-runner" \
  in_tree target-refs-pull

# …and the path match is a PR-ref match, not a "any refs/ string" one.
# Without this row, widening the pattern to `refs/` would pass the suite.
wf target-refs-heads a.yml <<'YAML'
name: labels
on:
  pull_request_target:
jobs:
  labels:
    runs-on: [self-hosted, ci-runner]
    steps:
      - uses: actions/checkout@v4
        with:
          ref: refs/heads/main
      - run: echo labels
YAML
check "pull_request_target + a checkout of refs/heads/main is not a PR checkout" 0 \
  "1 workflow file" in_tree target-refs-heads

# One line, one report. A callee input literally named `runs-on` inside an
# open `with:` window is both halves of shape a and shape c, and the same
# line was reported twice — same verdict, same labels, duplicated message
# (#395 round 1, claude-bot's second nit).
wf runs-on-in-with a.yml <<'YAML'
name: pr-checks
on:
  pull_request:
jobs:
  check:
    uses: ./.github/workflows/reusable.yml
    with:
      runs-on: '["self-hosted","ci-runner"]'
YAML
check "a runs-on: passed as a with: input is reported once" 1 \
  "ci-runner" in_tree runs-on-in-with
report_count() {
  local n
  n="$(in_tree runs-on-in-with 2>&1 | grep -c 'runs-on:.*self-hosted')"
  echo "offending lines reported: $n"
}
check "…exactly once, not once per matching half" 0 \
  "offending lines reported: 1" report_count

# The same collision in the inline flow-mapping form: `with: {runs-on: …}`
# is one line matching shape a and shape b at once, and it is the arm the
# window row above cannot reach.
wf runs-on-in-inline-with a.yml <<'YAML'
name: pr-checks
on:
  pull_request:
jobs:
  check:
    uses: ./.github/workflows/reusable.yml
    with: {runs-on: '["self-hosted","ci-runner"]'}
YAML
check "an inline with: {runs-on: …} is reported once too" 1 \
  "ci-runner" in_tree runs-on-in-inline-with
inline_report_count() {
  local n
  n="$(in_tree runs-on-in-inline-with 2>&1 | grep -c 'runs-on:.*self-hosted')"
  echo "offending lines reported: $n"
}
check "…exactly once, in the inline arm as in the window arm" 0 \
  "offending lines reported: 1" inline_report_count

# --- #395 round 2: one VALUE is one spec, not one line ---------------------

# specs_reported <tree> [args…] — how many offending specs the guard
# reported, counted on the labels line each one carries. The rows below
# are about which VALUES become specs, so counting reports is the
# assertion; a row that only checked the exit status would pass whether
# the line was judged once, twice or as one flattened set.
specs_reported() {
  local n
  n="$(in_tree "$@" 2>&1 | grep -c 'none of them is named')"
  echo "offending specs reported: $n"
}

# codex-bot's blocker. Two reusable-workflow inputs on one line are two
# different runners; flattening the mapping into one label set made the
# vouched one vouch for the unvouched one, because a set is vouched when
# ANY of its labels is. Fail-open, on exactly the axis this change is
# for.
wf inline-two-inputs a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {safe-runner: '["self-hosted","pr-runner"]', privileged-runner: '["self-hosted","ci-runner"]'}
YAML
check "a vouched inline input does not vouch for the one beside it" 1 \
  "ci-runner" in_tree inline-two-inputs .github/workflows pr-runner
check "…and the offending spec's labels are its own, not the line's" 1 \
  "labels: self-hosted, ci-runner —" in_tree inline-two-inputs \
  .github/workflows pr-runner
check "…and only the unvouched value is reported" 0 \
  "offending specs reported: 1" specs_reported inline-two-inputs \
  .github/workflows pr-runner

# The mirror, so the fix cannot rot into "an inline mapping always
# fails": the same two-input line with both values vouched passes.
wf inline-two-vouched a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {safe-runner: '["self-hosted","pr-runner"]', other-runner: '["self-hosted","pr-runner"]'}
YAML
check "both inline values vouched is still a pass" 0 "1 workflow file" \
  in_tree inline-two-vouched .github/workflows pr-runner

# The split is at the MAPPING's commas, and the two things that decide
# which commas those are — quote state and `[`/`{` nesting — each need a
# row of their own, or a split that ignores either passes the suite. Both
# shapes below are vouched conjunctions that must survive the split: an
# unquoted flow list inside the mapping, and a quoted comma-separated
# scalar with no brackets at all. Blind to nesting, the first breaks into
# `self-hosted` alone and fails; blind to quotes, so does the second.
wf inline-nested-list a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {runner: [self-hosted, ci-runner], note: nothing}
YAML
check "an unquoted list inside the mapping stays one conjunction" 0 \
  "1 workflow file" in_tree inline-nested-list .github/workflows ci-runner
check "…and the unquoted list still fails when it is unvouched" 1 \
  "labels: self-hosted, ci-runner —" in_tree inline-nested-list

wf inline-quoted-commas a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {runner: 'self-hosted,ci-runner', note: nothing}
YAML
check "a quoted comma-separated value stays one conjunction" 0 \
  "1 workflow file" in_tree inline-quoted-commas .github/workflows ci-runner
check "…and the quoted value still fails when it is unvouched" 1 \
  "labels: self-hosted, ci-runner —" in_tree inline-quoted-commas

# claude-bot's first nit, the same defect reached through the `runs-on:`
# arm: slicing the line at `runs-on:` swallowed the sibling key, and
# labels_in strips a `key:` prefix, so `note: pr-runner` joined the set
# and vouched for a spec it is no part of.
wf inline-sibling-key a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {runs-on: '["self-hosted","ci-runner"]', note: pr-runner}
YAML
check "a sibling key's value cannot vouch for the runs-on value" 1 \
  "ci-runner" in_tree inline-sibling-key .github/workflows pr-runner
check "…and it is not read as one of that spec's labels" 1 \
  "labels: self-hosted, ci-runner —" in_tree inline-sibling-key \
  .github/workflows pr-runner

# claude-bot's second nit, half a: a `with:`-passed label set written as
# a block sequence is one spec, exactly as a `runs-on:` one is — the
# header's "judged identically" has to cover this shape. Read item by
# item, `- self-hosted` was a one-label spec and failed a consumer who
# had vouched correctly.
wf with-seq a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner:
        - self-hosted
        - pr-runner
YAML
check "a with:-passed block sequence is accumulated as one spec" 0 \
  "1 workflow file" in_tree with-seq .github/workflows pr-runner
check "…and it still fails when nothing in the set is vouched" 1 \
  "labels: self-hosted, pr-runner —" in_tree with-seq .github/workflows other
check "…reported once, not once per sequence item" 0 \
  "offending specs reported: 1" specs_reported with-seq .github/workflows other

# …and half b: the same sequence under a callee input literally named
# `runs-on` was appended twice — once by the with:-window arm, once by
# the sequence flush, which the round-1 line-number guard never reached.
wf with-seq-runs-on a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runs-on:
        - self-hosted
        - ci-runner
YAML
check "a runs-on: sequence inside with: carries the whole set" 1 \
  "labels: self-hosted, ci-runner —" in_tree with-seq-runs-on
check "…and is reported once, not once per matching path" 0 \
  "offending specs reported: 1" specs_reported with-seq-runs-on

# --- #395 round 3: the fragment is a flow collection, not a line ----------

# claude-bot's blocker, shape 1: a whole JOB written as a flow mapping.
# The `runs-on:` here is not the line's own key, so the loose arm read
# it — and read `${stripped#*runs-on:}`, the rest of the LINE, so
# `environment:`'s vouched scalar joined the runs-on value's label set
# and vouched for a tier it is no part of. The block form of the same
# job fails; the flow form passed. Both files are valid YAML.
wf flow-job-mapping a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build: {runs-on: [self-hosted, ci-runner], environment: pr-runner, steps: [{run: make test}]}
YAML
check "a sibling key in a flow JOB cannot vouch for its runs-on value" 1 \
  "ci-runner" in_tree flow-job-mapping .github/workflows pr-runner
check "…and the spec's labels are the runs-on value's own" 1 \
  "labels: self-hosted, ci-runner —" in_tree flow-job-mapping \
  .github/workflows pr-runner
check "…once, not once per key the line carries" 0 \
  "offending specs reported: 1" specs_reported flow-job-mapping \
  .github/workflows pr-runner
# The mirror: vouching for the runner the job actually names still
# passes, so the fix cannot rot into "a flow job always fails".
check "…and vouching for the value's own tier still passes" 0 \
  "1 workflow file" in_tree flow-job-mapping .github/workflows ci-runner

# claude-bot's blocker, shape 2: the same mapping as a matrix entry,
# where `- {runs-on: …, tier: …}` is the routine spelling.
wf flow-matrix-include a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    strategy:
      matrix:
        include:
          - {runs-on: [self-hosted, ci-runner], tier: pr-runner}
    runs-on: ${{ matrix.runs-on }}
    steps:
      - run: make test
YAML
check "a matrix entry's sibling key cannot vouch either" 1 \
  "labels: self-hosted, ci-runner —" in_tree flow-matrix-include \
  .github/workflows pr-runner
check "…and the expression that reads it is not a second spec" 0 \
  "offending specs reported: 1" specs_reported flow-matrix-include \
  .github/workflows pr-runner

# …and the shape that pins WHERE the fragment starts rather than where it
# ends. Both files above name a bracketed runner list, and a fragment
# ends at its collection's own close, so slicing at `runs-on:` and
# stopping at the `]` reaches the same verdict by luck. Write the runner
# as the bare scalar it is allowed to be and only the mapping-level split
# saves it: the slice runs on to `environment:`'s vouched value and there
# is no bracket to stop it. Found by mutation — the two rows above red
# nothing when the arm is reverted.
wf flow-job-scalar a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build: {runs-on: self-hosted, environment: pr-runner, steps: [{run: make test}]}
YAML
check "a bare scalar runner in a flow job is judged alone too" 1 \
  "labels: self-hosted —" in_tree flow-job-scalar .github/workflows pr-runner
check "…and its own tier vouched still passes" 0 "1 workflow file" \
  in_tree flow-job-scalar .github/workflows self-hosted

wf flow-matrix-scalar a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    strategy:
      matrix:
        include:
          - {runs-on: self-hosted, tier: pr-runner}
    runs-on: ${{ matrix.runs-on }}
    steps:
      - run: make test
YAML
check "a bare scalar runner in a matrix entry, the same" 1 \
  "labels: self-hosted —" in_tree flow-matrix-scalar .github/workflows pr-runner

# codex-bot's blocker: a flow mapping that does not close on the line
# that opens it. `with: {` handed the splitter one character and the
# value lines below belonged to no open window at all — both specs
# vanished, which is a silent loss rather than a mis-vouch.
wf flow-multiline a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {
      safe-runner: '["self-hosted","pr-runner"]',
      privileged-runner: '["self-hosted","ci-runner"]'
    }
YAML
check "a flow mapping spanning lines is scanned, not lost" 1 \
  "labels: self-hosted, ci-runner —" in_tree flow-multiline \
  .github/workflows pr-runner
# …and each value is still judged alone across the line break: the
# vouched sibling neither rescues the unvouched one nor is reported.
check "…each of its values judged alone, so only one is reported" 0 \
  "offending specs reported: 1" specs_reported flow-multiline \
  .github/workflows pr-runner
check_absent "…and the vouched value is not the one reported" 1 \
  "safe-runner" in_tree flow-multiline .github/workflows pr-runner
# The offence is reported at the line the value sits on, not at the
# bracket three lines above it.
check "…reported at the value's own line, not the line that opened it" 1 \
  "8:       privileged-runner:" in_tree flow-multiline \
  .github/workflows pr-runner

wf flow-multiline-vouched a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {
      safe-runner: '["self-hosted","pr-runner"]',
      other-runner: '["self-hosted","pr-runner"]'
    }
YAML
check "both values of a multiline mapping vouched is still a pass" 0 \
  "1 workflow file" in_tree flow-multiline-vouched .github/workflows pr-runner

# codex-bot's second half, the same parser boundary: a flow SEQUENCE
# under a block `with:` key, spanning lines. A list is one value however
# many lines it spans — so this is one conjunction, not two one-label
# specs, and one vouched label covers it.
wf flow-multiline-seq a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: [
        self-hosted,
        ci-runner
      ]
YAML
check "a flow sequence spanning lines stays one conjunction" 0 \
  "1 workflow file" in_tree flow-multiline-seq .github/workflows ci-runner
check "…and it still fails, as one spec, when nothing is vouched" 1 \
  "labels: self-hosted, ci-runner —" in_tree flow-multiline-seq
check "…as one spec, not one per line it spans" 0 \
  "offending specs reported: 1" specs_reported flow-multiline-seq

# The bound on the accumulation, which nobody asked for and a guard
# needs: a collection whose brackets never balance stops at the next
# top-level key. Unbounded, this file's `on:` block would be swallowed
# as collection text, the file would derive as executing no PR code, and
# a malformed workflow would be a silent PASS — the one defect this
# guard is not allowed to have.
wf flow-unterminated a.yml <<'YAML'
name: pr checks
jobs:
  build:
    runs-on: { self-hosted,
      ci-runner
on: pull_request
YAML
check "an unterminated collection does not swallow the trigger block" 1 \
  "self-hosted" in_tree flow-unterminated

# claude-bot's nit: "one line, one report" was a sentence broader than
# the code. A `- runs-on: …` item inside an open `with:` sequence window
# was consumed by the window AND recorded again by the loose arm.
wf seq-item-runs-on a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner:
        - runs-on: '["self-hosted","ci-runner"]'
YAML
check "a sequence item that also matches an arm is reported once" 0 \
  "offending specs reported: 1" specs_reported seq-item-runs-on
check "…and it is the window's spec, carrying the whole set" 1 \
  "labels: self-hosted, ci-runner —" in_tree seq-item-runs-on

# --- #395 round 4: the collection's KIND, and a quoted scalar's opacity ----

# claude-bot's blocker 1: the round-3 rule ("a collection's values are
# ITS OWN") was written as a depth-1 test, so it held for the OUTERMOST
# mapping only. Put a second bracket before the key — a whole `jobs:`
# map inline, which is one of the two routine spellings — and the nested
# mapping is one value again: `environment:`'s vouched scalar rejoins the
# runs-on value's label set and vouches for a tier it is no part of. Same
# arrival path and direction as round 3's blocker, one level in.
wf nested-flow-job a.yml <<'YAML'
name: pr checks
on: pull_request
jobs: {build: {runs-on: [self-hosted, ci-runner], environment: pr-runner, steps: [{run: make test}]}}
YAML
check "a sibling key in a NESTED flow mapping cannot vouch either" 1 \
  "labels: self-hosted, ci-runner —" in_tree nested-flow-job \
  .github/workflows pr-runner
check "…and it is one spec, not one per key the nesting carries" 0 \
  "offending specs reported: 1" specs_reported nested-flow-job \
  .github/workflows pr-runner
# The mirror: the value's own tier vouched still passes, so the fix
# cannot rot into "a nested mapping always fails".
check "…and vouching for the nested value's own tier passes" 0 \
  "1 workflow file" in_tree nested-flow-job .github/workflows ci-runner

# The same defect at the nesting depth `matrix.include` reaches, where a
# flow SEQUENCE sits between the two mappings (`{[{`). The block-sequence
# spelling of this very file is already a row above; the only difference
# between them is where the author put a line break, which is not
# something the verdict may depend on.
wf nested-matrix-include a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    strategy:
      matrix: {include: [{runs-on: [self-hosted, ci-runner], tier: pr-runner}]}
    runs-on: ${{ matrix.runs-on }}
    steps:
      - run: make test
YAML
check "a mapping nested through a list is split at its own commas" 1 \
  "labels: self-hosted, ci-runner —" in_tree nested-matrix-include \
  .github/workflows pr-runner
check "…and the line-break spelling of it reaches the same verdict" 1 \
  "labels: self-hosted, ci-runner —" in_tree flow-matrix-include \
  .github/workflows pr-runner

# …and the shape with no bracket to stop a slice, which is what tells
# "split by the innermost collection's kind" apart from "stop at the
# runner list's own `]`".
wf nested-flow-scalar a.yml <<'YAML'
name: pr checks
on: pull_request
jobs: {build: {runs-on: self-hosted, environment: pr-runner, steps: [{run: make test}]}}
YAML
check "a bare scalar runner nested in a flow job is judged alone" 1 \
  "labels: self-hosted —" in_tree nested-flow-scalar \
  .github/workflows pr-runner

# The conjunction, which the kind-aware split must NOT break: the comma
# inside `[self-hosted, pr-runner]` sits in a LIST however deeply that
# list is nested, so the set stays one value and one vouched label covers
# it — while the mapping's own comma still keeps `ci-runner` out of it.
wf nested-flow-conjunction a.yml <<'YAML'
name: pr checks
on: pull_request
jobs: {build: {runs-on: [self-hosted, pr-runner], environment: ci-runner, steps: [{run: make test}]}}
YAML
check "a nested label set is still one conjunction, not two specs" 0 \
  "1 workflow file" in_tree nested-flow-conjunction .github/workflows pr-runner

# labels_in strips a `key:` prefix per nesting level, so one strip left
# the message naming `runs-on: self-hosted`, which is not a label the
# consumer could ever vouch for. It failed safe and read as a typo
# (claude-bot's nit 2).
check_absent "the message names labels, not the keys they were nested under" 1 \
  "labels: runs-on:" in_tree nested-flow-job .github/workflows pr-runner

# codex-bot's and kimi-bot's blocker, claude-bot's blocker 2: quote state
# was cleared at every physical newline, so a quoted label wrapping a
# line stopped being quoted and the first `]` in its continuation counted
# as the collection's own close. Everything after it belonged to no
# window: this file exited 0 with an EMPTY allowlist — a fail-open
# needing no vouch at all. PyYAML reads the value as the three labels
# `linux ]tier`, `self-hosted` and `ci-runner`.
wf quoted-wrap-close a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {
      runner: '["linux
        ]tier","self-hosted","ci-runner"]'
    }
YAML
check "a ] inside a wrapped quoted label does not close the collection" 1 \
  "ci-runner" in_tree quoted-wrap-close
check "…and the whole wrapped value is one spec's label set" 1 \
  "labels: linux tier, self-hosted, ci-runner —" in_tree quoted-wrap-close

# Its vouched mirror, so the row cannot rot into "a wrapped quoted value
# always fails": the same shape whose set names a vouched tier passes.
wf quoted-wrap-vouched a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {
      runner: '["linux
        ]tier","self-hosted","pr-runner"]'
    }
YAML
check "…and the same shape vouched for its own tier passes" 0 \
  "1 workflow file" in_tree quoted-wrap-vouched .github/workflows pr-runner

# claude-bot's blocker 2 as it arrives in prose rather than in a label: a
# wrapped `note:` closed the mapping early and the `hot:` runner below it
# was never a spec at all. No vouch needed, so no consumer opt-in gates
# it.
wf quoted-wrap-note a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with: {
      note: 'a long note that wraps
        onto a second line]',
      hot: '["self-hosted","ci-runner"]' }
YAML
check "a wrapped quoted note does not lose the values after it" 1 \
  "labels: self-hosted, ci-runner —" in_tree quoted-wrap-note
check "…and the offence is reported at the runner value's own line" 1 \
  "9:       hot:" in_tree quoted-wrap-note

# The nearer variant, where the RUNNER value is the one that wraps: it is
# one value across both its lines, and the unvouched sibling beside it is
# still its own spec.
wf quoted-wrap-runner a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with: {
      safe: '["self-hosted",
        "pr-runner"]',
      hot: '["self-hosted","ci-runner"]' }
YAML
check "a runner value wrapping a line is one value, judged whole" 1 \
  "labels: self-hosted, ci-runner —" in_tree quoted-wrap-runner \
  .github/workflows pr-runner
check "…so only the unvouched sibling is reported" 0 \
  "offending specs reported: 1" specs_reported quoted-wrap-runner \
  .github/workflows pr-runner

# What the line-scoped reset was defending, kept: an apostrophe inside a
# PLAIN scalar must not make the rest of the file read as quoted text. A
# quote opens only where a scalar can start, so `it's` stays plain and
# the runner value two lines down is still read.
wf plain-apostrophe a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with: {
      note: it's a plain scalar,
      hot: '["self-hosted","ci-runner"]' }
YAML
check "an apostrophe in a plain scalar does not swallow the file" 1 \
  "labels: self-hosted, ci-runner —" in_tree plain-apostrophe

# YAML's own escapes, both spellings. `\"` inside a double-quoted scalar
# is a quote the scalar CONTAINS — the JSON-in-a-string form a caller
# writes by hand — and carrying the backslashes into the labels refused a
# consumer who had vouched correctly: fail-CLOSED, the converse defect
# (codex-bot, kimi-bot's blocker 2).
wf escaped-double-quotes a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {runner: "[\"self-hosted\",\"ci-runner\"]"}
YAML
check "an escaped-quote value's labels come out as labels" 1 \
  "labels: self-hosted, ci-runner —" in_tree escaped-double-quotes
check "…so vouching for the tier it names is honoured" 0 "1 workflow file" \
  in_tree escaped-double-quotes .github/workflows ci-runner

# …and `''`, which is a single-quoted scalar's own escape: it does not
# end the scalar, so the `]` after it is still inside the quote and the
# runner value below is still read.
wf escaped-single-quote a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with: {
      note: 'it''s wrapped in one scalar]',
      hot: '["self-hosted","ci-runner"]' }
YAML
check "a '' escape does not end the scalar it sits in" 1 \
  "labels: self-hosted, ci-runner —" in_tree escaped-single-quote

# claude-bot's nit 1: the accumulation is bounded at a top-level key, so
# the trigger block survives an unterminated collection (the row above
# proves it) — but the file's own `ref:` line sits at indent > 0 and was
# eaten, so a pull_request_target file checking out the PR head derived
# as executing NO PR code and exited 0. GitHub would reject this file,
# which is why it is a nit; a guard reaching a silent pass by accident is
# why it is fixed rather than reworded.
wf unterminated-eats-ref a.yml <<'YAML'
name: pr checks
on: pull_request_target
jobs:
  build:
    runs-on: [self-hosted, ci-runner
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
YAML
check "an unterminated collection cannot eat the file's own ref:" 1 \
  "checks out a PR ref at line 9" in_tree unterminated-eats-ref

# Shape d, found while re-reading this round's own fix rather than
# reported: a BLOCK SCALAR input value. `runner: |` hands the callee the
# same string `runner: '…'` does, and the guard read none of it — a
# fail-open on decision 5's own criterion, needing no vouch at all. The
# block is one spec however many lines it spans.
wf block-scalar-input a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with:
      runner: |
        ["self-hosted","ci-runner"]
YAML
check "a block-scalar input value is read like a quoted one" 1 \
  "labels: self-hosted, ci-runner —" in_tree block-scalar-input
check "…and vouching for the tier it names is honoured" 0 "1 workflow file" \
  in_tree block-scalar-input .github/workflows ci-runner

# The folded form, spanning lines: one spec, so one vouched label covers
# the whole set exactly as it does for a flow sequence.
wf folded-scalar-input a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with:
      runner: >-
        ["self-hosted",
        "pr-runner"]
YAML
check "a folded scalar spanning lines is one spec, not one per line" 0 \
  "offending specs reported: 1" specs_reported folded-scalar-input
check "…and its whole set is vouched by one of its labels" 0 \
  "1 workflow file" in_tree folded-scalar-input .github/workflows pr-runner

# The same set with the vouched label FIRST. One order cannot tell "the
# block's lines are accumulated" from "the last line wins": with the
# vouched label last, a last-line-wins bug passes the row above and the
# suite stays green — the gap the mutation found, and the same one the
# block-sequence rows were given two orders for.
wf folded-scalar-reversed a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with:
      runner: >-
        ["pr-runner",
        "self-hosted"]
YAML
check "the block is accumulated, whichever line carries the vouched label" 0 \
  "1 workflow file" in_tree folded-scalar-reversed .github/workflows pr-runner
check "…and that order still names the whole set when nothing is vouched" 1 \
  "labels: pr-runner, self-hosted —" in_tree folded-scalar-reversed

# …and the window CLOSES at the key's own indentation: the sibling input
# below the block is its own spec, so a label named inside the block's
# text cannot vouch for it. Without the close, `hot:` would be block text
# and the file would pass on `pr-runner` alone.
wf block-scalar-sibling a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with:
      note: |
        this tier is pr-runner and this text is not a runner spec
      hot: '["self-hosted","ci-runner"]'
YAML
check "the block window closes at the key's own indentation" 1 \
  "labels: self-hosted, ci-runner —" in_tree block-scalar-sibling \
  .github/workflows pr-runner

# --- #395: pr-code-runner-labels, the one assertion the guard accepts -------

# in_tree passes the allowlist as the second argument, the way action.yml
# passes it as an env var (both wirings are proved below).
wf vouched a.yml <<'YAML'
name: pr-checks
on:
  pull_request:
jobs:
  check:
    runs-on: [self-hosted, pr-runner]
    steps:
      - run: echo check
YAML
check "pull_request + an unvouched self-hosted label fails" 1 "pr-runner" \
  in_tree vouched
check "pull_request + the label vouched for passes" 0 "1 workflow file" \
  in_tree vouched .github/workflows pr-runner

# The worst outcome of the whole change would be a silent pass on a typo,
# so the typo is a fixture.
check "an allowlist entry that misspells the label still fails" 1 "pr-runner" \
  in_tree vouched .github/workflows pr-runer
check "a vouched OTHER tier does not vouch for this one" 1 "pr-runner" \
  in_tree vouched .github/workflows ci-runner

# The allowlist reaches the script through the env var too — action.yml's
# wiring, not the argument's.
env_allow_tree() {
  (cd "$TMP/vouched" && PR_CODE_RUNNER_LABELS="$1" bash "$SCRIPT")
}
check "the allowlist env var drives the script the way action.yml does" 0 \
  "1 workflow file" env_allow_tree pr-runner
check "the env var is honored, not ignored into a pass" 1 "pr-runner" \
  env_allow_tree ci-runner
# Comma-separated, with the spacing a human writes.
check "a comma-separated list vouches for each label in it" 0 "1 workflow file" \
  env_allow_tree "ci-runner, pr-runner"

# A label set is a conjunction — every runner matching [self-hosted,
# pr-runner] is in the pr-runner tier — so one vouched label covers the
# set, including when the set is a block sequence spanning lines.
wf vouched-seq a.yml <<'YAML'
name: pr-checks
on:
  pull_request:
jobs:
  check:
    runs-on:
      - self-hosted
      - pr-runner
    steps:
      - run: echo check
YAML
check "a block-sequence label set is judged as one set" 0 "1 workflow file" \
  in_tree vouched-seq .github/workflows pr-runner
check "…and still fails when nothing in that set is vouched" 1 "self-hosted" \
  in_tree vouched-seq

# The same set with the items the other way round. One fixture cannot tell
# "the sequence is accumulated" from "the last item wins" — with the
# vouched label last, a last-item-wins bug passes it and the suite stays
# green. Two orders pin the accumulation itself.
wf vouched-seq-reversed a.yml <<'YAML'
name: pr-checks
on:
  pull_request:
jobs:
  check:
    runs-on:
      - pr-runner
      - self-hosted
    steps:
      - run: echo check
YAML
check "the set is accumulated, whichever item carries the vouched label" 0 \
  "1 workflow file" in_tree vouched-seq-reversed .github/workflows pr-runner
check "…and that order still fails when nothing is vouched" 1 "self-hosted" \
  in_tree vouched-seq-reversed

# Vouching for one job does not vouch for the file: the second job's tier
# is still unvouched, and only that job's line is reported.
wf two-tiers a.yml <<'YAML'
name: pr-checks
on:
  pull_request:
jobs:
  check:
    runs-on: [self-hosted, pr-runner]
    steps:
      - run: echo check
  publish:
    runs-on: [self-hosted, ci-runner]
    steps:
      - run: echo publish
YAML
check "a vouched job does not vouch for the unvouched job beside it" 1 \
  "runs-on: [self-hosted, ci-runner]" in_tree two-tiers .github/workflows pr-runner
check_absent "the vouched job's own line is not reported as an offence" 1 \
  "runs-on: [self-hosted, pr-runner]" in_tree two-tiers .github/workflows pr-runner

# --- #395 decision 5: a label passed through an input --------------------

# The shape #383 introduced and heavy-duty/incubator#144 shipped: the
# label never appears in a runs-on: block in this file at all.
wf with-input a.yml <<'YAML'
name: pr-checks
on:
  pull_request:
jobs:
  check:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@0.7.1
    with:
      runner: '["self-hosted","ci-runner"]'
YAML
check "a with:-passed self-hosted label is seen on a PR-code file" 1 \
  "ci-runner" in_tree with-input
check "…and the vouched form of the same file passes" 0 "1 workflow file" \
  in_tree with-input .github/workflows ci-runner

# The same input on a pull_request_target caller with no PR checkout —
# incubator's three callers exactly — needs no entry at all (decision 6).
wf with-input-target a.yml <<'YAML'
name: labels
on:
  pull_request_target:
    types: [opened]
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@0.7.1
    with:
      runner: '["self-hosted","ci-runner"]'
YAML
check "a with:-passed label on a no-PR-code file needs no entry" 0 \
  "1 workflow file" in_tree with-input-target

# …and the dangerous version of it is caught: same caller, plus a PR-head
# checkout in a job beside it.
wf with-input-target-checkout a.yml <<'YAML'
name: labels
on:
  pull_request_target:
    types: [opened]
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@0.7.1
    with:
      runner: '["self-hosted","ci-runner"]'
  probe:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
YAML
check "the same caller plus a PR-head checkout fails" 1 "ci-runner" \
  in_tree with-input-target-checkout

# The inline flow-mapping form of with:.
wf with-inline a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  check:
    uses: ./.github/workflows/inner.yml
    with: {runner: '["self-hosted","ci-runner"]'}
YAML
check "the inline with: {…} form is scanned too" 1 "ci-runner" in_tree with-inline
# …and its labels come out as labels: the flow mapping carries a `key:`
# INSIDE the value, and a label read as `runner: self-hosted` matches no
# allowlist entry — failing safe, but refusing a consumer who vouched
# correctly.
check "the inline form's labels parse as labels, so vouching works" 0 \
  "1 workflow file" in_tree with-inline .github/workflows ci-runner
check "the inline form names the label cleanly" 1 \
  "labels: self-hosted, ci-runner" in_tree with-inline

# The with: window must close: a self-hosted mention indented BACK OUT to
# a sibling key is not an input value. Without the indentation check this
# would still fail, and the window would be unbounded.
wf with-window a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  check:
    uses: ./.github/workflows/inner.yml
    with:
      quiet: true
  note:
    name: not self-hosted, just prose in a job name
    runs-on: ubuntu-latest
    steps:
      - run: echo note
YAML
check "the with: window closes at the next sibling key" 0 "1 workflow file" \
  in_tree with-window

# --- #395: the failure message has to be actionable ------------------------

check "the failure names the offending label" 1 "labels: self-hosted, ci-runner" \
  in_tree with-input
check "the failure names why the file derived as executing PR code" 1 \
  "its trigger block names pull_request" in_tree with-input
check "the failure names the input that would permit it" 1 \
  "pr-code-runner-labels" in_tree with-input
check "the failure says the allowlist is empty when it is" 1 \
  "empty — no label is vouched for" in_tree with-input
check "the failure shows the allowlist it was given" 1 "(pr-runner)" \
  in_tree with-input .github/workflows pr-runner

# --- #395 decision 6: incubator's callers, verbatim, as a regression -------

# Four files copied byte for byte from heavy-duty/incubator@main —
# provenance and blob SHAs in the fixture's README. #389 asserted these
# would need an opt-in in the same PR as the pin bump; the ruling says
# they need nothing, and that claim is worth a fixture rather than a
# sentence, because it is the exact claim that was wrong last time.
incubator_tree() {
  (cd "$ROOT/test/fixtures/incubator-callers" && bash "$SCRIPT" "$@")
}
check "incubator's real callers pass with no input set" 0 \
  "4 workflow file(s) scanned" incubator_tree

# That pass has to come from the AXIS, not from the guard failing to read
# their `runner:` input. Take their real labels.yml, change the trigger
# and nothing else, and the same file must fail naming the label it
# passes — the one mutation that separates "derives as no PR code" from
# "never saw it".
mkdir -p "$TMP/incubator-flipped/.github/workflows"
sed 's/pull_request_target:/pull_request:/' \
  "$ROOT/test/fixtures/incubator-callers/.github/workflows/labels.yml" \
  >"$TMP/incubator-flipped/.github/workflows/labels.yml"
check "…and their with:-passed label IS seen: flip the trigger and it fails" 1 \
  "ci-runner" in_tree incubator-flipped

summary
