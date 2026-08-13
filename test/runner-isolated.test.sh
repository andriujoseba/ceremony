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

# --- #395 round 5: a comment is not content, and it closes nothing --------

# codex-bot's and claude-bot's blocker, the same root from two
# directions: the flow scanner had no `#` at all, so a comment's own text
# was read as collection syntax. Its `}` popped the open mapping, the
# fragment closed on a line YAML has already ended, and every value below
# belonged to no window — this file exited 0 with an EMPTY allowlist.
# PyYAML reads `runner` as the second value of the `with:` mapping.
wf comment-brace-close a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {
      harmless: value, # } closes nothing in YAML
      runner: '["self-hosted","ci-runner"]'
    }
YAML
check "a } inside a comment does not close the collection" 1 \
  "ci-runner" in_tree comment-brace-close
check "…and the value below the comment is one spec's whole label set" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-brace-close
# Its vouched mirror, so the row cannot rot into "a commented file always
# fails": the same shape whose set names a vouched tier passes.
wf comment-brace-vouched a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {
      harmless: value, # } closes nothing in YAML
      runner: '["self-hosted","pr-runner"]'
    }
YAML
check "…and the same shape vouched for its own tier passes" 0 \
  "1 workflow file" in_tree comment-brace-vouched .github/workflows pr-runner

# claude-bot's second file, and the one that says the hole is in the
# SCANNER rather than in the `with:` arm: a plain `runs-on:` list, no
# reusable-workflow call anywhere, whose whole job runner set went
# invisible because a comment on the opening line carries a `}`.
wf comment-brace-runs-on a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: [ # the tiers below are ours (see docs} )
      self-hosted, ci-runner]
    steps:
      - run: make test
YAML
check "a commented runs-on: [ does not lose the job's runner set" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-brace-runs-on

# The converse, fail-CLOSED and needing no vouch to see: `labels_in`
# truncates an accumulated value at its first ` #`, so a comment INSIDE a
# multi-line collection ate the real labels after it and a consumer who
# had vouched correctly was refused. Fixed at the source — the comment
# never enters the value now — so this file passes on its own tier.
wf comment-eats-vouched a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: [self-hosted, # our isolated tier
      pr-runner]
    steps:
      - run: make test
YAML
check "a comment inside a collection does not eat the vouched label" 0 \
  "1 workflow file" in_tree comment-eats-vouched .github/workflows pr-runner
# …and the unvouched mirror, which is what tells that pass from a
# fail-open: were the collection still closing at the comment, this file
# would exit 0 with an empty allowlist too.
check "…and the same file with nothing vouched still fails" 1 \
  "labels: self-hosted, pr-runner —" in_tree comment-eats-vouched

# The third symptom of the same root: with the comment's brackets
# BALANCED the verdict was already right, but the value was truncated at
# the ` #` and the report named no label at all — against the criterion
# that the message names the offending label.
wf comment-empties-labels a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: [self-hosted, # see runner list [above]
      ci-runner]
    steps:
      - run: make test
YAML
check "a balanced-bracket comment still leaves the labels named" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-empties-labels

# The opposite direction, codex-bot's converse: the guard used to read
# the prose of a trailing comment as the line's own runner. `flow_flush`
# tests the accumulated value for self-hosted, so this hosted job filed a
# spec whose labels were `ubuntu-latest` — a false positive on a file
# whose comment says the right thing.
wf comment-prose-hosted a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: ubuntu-latest # do not move this to self-hosted
    steps:
      - run: make test
YAML
check "a self-hosted mention in a trailing comment is not a runner" 0 \
  "1 workflow file" in_tree comment-prose-hosted
# …and the pair that stops that row rotting into "a trailing comment
# passes the file": the same line whose RUNNER is self-hosted still
# fails, comment and all.
wf comment-prose-real a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: [self-hosted, ci-runner] # keep this off the hosted pool
    steps:
      - run: make test
YAML
check "…while a real self-hosted runner beside a comment still fails" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-prose-real

# YAML's own rule, and the reason the fix tests the preceding character:
# a `#` NOT preceded by whitespace is part of the plain scalar it sits
# in. Reading it as a comment would truncate the value here, so the row
# is the message text — a `#`-carrying label reported whole — and a vouch
# for that label, which a truncated value would refuse.
wf hash-in-label a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: [self-hosted, ci#runner]
    steps:
      - run: make test
YAML
check "a # with no space before it is part of the label" 1 \
  "labels: self-hosted, ci#runner —" in_tree hash-in-label
check "…so vouching for that label is honoured" 0 "1 workflow file" \
  in_tree hash-in-label .github/workflows "ci#runner"

# …and inside a quoted scalar a `#` is text whatever precedes it, which
# the quote branch already gave: the value is one spec and its labels
# come out whole.
wf hash-in-quoted a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with: {runner: '["self-hosted","ci #runner"]'}
YAML
check "a quoted # is text, not a comment" 1 \
  "labels: self-hosted, ci #runner —" in_tree hash-in-quoted

# The same converse in the BLOCK-SEQUENCE window, which reads a line at a
# time and probed the raw line for self-hosted: this hosted job filed a
# spec for the word in its own note.
wf seq-comment-prose a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      - ubuntu-latest # do not move this to self-hosted
    steps:
      - run: make test
YAML
check "a sequence item's note is not the item's runner" 0 "1 workflow file" \
  in_tree seq-comment-prose
# …and the item's own label survives its comment: the set is still both
# labels, so a vouch for either covers it and neither is cut away.
wf seq-comment-vouched a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      - self-hosted # the tier below is ours
      - pr-runner
    steps:
      - run: make test
YAML
check "a commented sequence item keeps its own label" 1 \
  "labels: self-hosted, pr-runner —" in_tree seq-comment-vouched
check "…and the set it belongs to is vouched by either label" 0 \
  "1 workflow file" in_tree seq-comment-vouched .github/workflows pr-runner

# The other direction of the same root, found while writing this round's
# fix rather than reported: inside a BLOCK SCALAR a `#` opens no comment,
# the whole block being literal text the callee receives. A label written
# under `runner: |` behind a `#` is passed to the reusable workflow like
# any other, and the file-level comment rule made it invisible — exit 0,
# no vouch needed, the shape-d fail-open one character over.
wf block-scalar-hash-line a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with:
      runner: |
        # ["self-hosted","ci-runner"]
YAML
check "a # line inside a block scalar is text the callee receives" 1 \
  "ci-runner" in_tree block-scalar-hash-line
check "…and vouching for the tier that text names is honoured" 0 \
  "1 workflow file" in_tree block-scalar-hash-line .github/workflows ci-runner
# …and the block still ENDS where it ended: a comment at the key's own
# indentation or further out is a comment again, so a note beside the
# input cannot be read as its value. The note carries a `key:` on
# purpose — without one the line reaches no spec path at all and the row
# would pass whether or not the exception respects the block's own
# indentation, which is a fixture that asserts nothing.
wf block-scalar-hash-outdent a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/r.yml
    with:
      runner: |
        ["ubuntu-latest"]
      # note: self-hosted work lives in deploy.yml
YAML
check "a comment outside the block is a comment again" 0 "1 workflow file" \
  in_tree block-scalar-hash-outdent

# The header's KNOWN LIMITS now says which spelling of the runner-group
# mapping is read and which is not, and the half that IS read is a claim
# this file should carry: `runs-on: {group: …, labels: […]}` inline is a
# flow mapping like any other, so its label list is a value and a spec.
# (The block-mapping spelling is the gap the same bullet discloses —
# pre-existing, out of #395 by decision 9, and not fixtured here.)
wf inline-group-mapping a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: {group: linux, labels: [self-hosted, ci-runner]}
    steps:
      - run: make test
YAML
check "the inline group mapping's label list is read" 1 \
  "labels: self-hosted, ci-runner —" in_tree inline-group-mapping

# --- #395 round 6: WHERE a comment may begin ------------------------------
#
# Round 5 asked whether the character before the `#` was whitespace. YAML
# asks whether the `#` continues a PLAIN SCALAR, and it does so only after
# another character of one — so a `#` right after a flow indicator, or
# after a quoted scalar's own closing quote, opens a comment too. Each
# file below parses under PyYAML with the runner value intact, which is
# what makes them regressions rather than curiosities: a file GitHub
# rejects is no threat, and the first drafts of the bracket and quote
# rows did not parse (#395 round 6, codex-bot blocking).
wf comment-after-brace a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {# } closes nothing in YAML
      runner: '["self-hosted","ci-runner"]'}
YAML
check "a # right after { opens a comment, and its } closes nothing" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-after-brace
# Its vouched mirror, so the row cannot rot into "a `{#` file always fails".
wf comment-after-brace-vouched a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {# } closes nothing in YAML
      runner: '["self-hosted","pr-runner"]'}
YAML
check "…and the same shape vouched for its own tier passes" 0 \
  "1 workflow file" in_tree comment-after-brace-vouched .github/workflows pr-runner

# The comma spelling codex-bot named beside the brace one.
wf comment-after-comma a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {harmless: value,# } closes nothing
      runner: '["self-hosted","ci-runner"]'}
YAML
check "a # right after a , opens a comment" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-after-comma

# …and the two positions the same rule reaches, found while measuring the
# boundary rather than reported: a closing bracket, and a quoted scalar's
# own closing quote. Both are the identical bypass one character over.
wf comment-after-bracket a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {safe: [ok]#}
      , hot: '["self-hosted","ci-runner"]' }
YAML
check "a # right after ] opens a comment" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-after-bracket
wf comment-after-quote a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {safe: 'ok'#}
      , hot: '["self-hosted","ci-runner"]' }
YAML
check "a # right after a quoted scalar's close opens a comment" 1 \
  "labels: self-hosted, ci-runner —" in_tree comment-after-quote

# The exclusion, and the direction it protects: `{a:#b}` is ONE plain
# scalar to YAML, not a key and a comment, so a `#` after a `:` is the
# value's own text. Widening the rule to `:` would drop a value the callee
# really receives — this round's fix becoming this round's fail-open.
wf hash-after-colon a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {runner:#self-hosted, other: v}
YAML
check "a # right after a : is still the scalar's own text" 1 \
  "labels: #self-hosted —" in_tree hash-after-colon

# claude-bot's nit 2, and it is a fail-OPEN of round 5's own making: the
# block-sequence window trimmed at the first whitespace-`#` whatever the
# quotes, so the two spellings of one label set disagreed. The inline form
# kept `pr #runner` whole; the sequence form cut it to `pr` and refused a
# consumer who had vouched for the label the file names.
wf seq-quoted-hash a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      - self-hosted
      - "pr #runner"
    steps:
      - run: make test
YAML
check "a quoted # in a sequence item is part of the label" 1 \
  "labels: self-hosted, pr #runner —" in_tree seq-quoted-hash
check "…so vouching for that label is honoured here too" 0 "1 workflow file" \
  in_tree seq-quoted-hash .github/workflows "pr #runner"
# The converse claude-bot measured, and the one that loses a LABEL rather
# than a vouch: the trim cut the item at the quoted ` #` and took the
# self-hosted after it away with the rest — exit 0, no vouch needed.
wf seq-quoted-hash-eaten a.yml <<'YAML'
name: caller
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner:
        - ['ci # tier', self-hosted]
YAML
check "a quoted # does not eat the self-hosted after it" 1 \
  "labels: ci # tier, self-hosted —" in_tree seq-quoted-hash-eaten
# …and the tripwire that stops the quote half widening into "any
# apostrophe opens a scalar": a plain scalar's apostrophe opens nothing,
# so this item's note is still a note and the file still passes.
wf seq-apostrophe-note a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      - ubuntu-don't # self-hosted here
    steps:
      - run: make test
YAML
check "an apostrophe in a plain item does not quote its note" 0 \
  "1 workflow file" in_tree seq-apostrophe-note

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

# --- #395 round 7: a bare key's value written as a flow collection ---------

# The window a bare `runs-on:` opens is over its VALUE, and that value may
# be a flow collection on the next line as legitimately as a `- …` list.
# It closed recording nothing and the line reached no fragment arm, so
# this file was read by nothing at all — exit 0, empty allowlist
# (claude-bot blocking).
wf next-line-flow a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      [self-hosted, ci-runner]
    steps:
      - run: echo build
YAML
check "a runs-on: value written as a flow list on the next line fails" 1 \
  "self-hosted" in_tree next-line-flow
check "…naming its labels, so a correct vouch is possible" 1 \
  "labels: self-hosted, ci-runner" in_tree next-line-flow
check "…and the vouched form of the same file passes" 0 "1 workflow file" \
  in_tree next-line-flow .github/workflows ci-runner

# The same shape one window in — the `with:`-passed spelling, which is the
# capability #395 adds rather than one it inherited.
wf next-line-flow-with a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  check:
    uses: ./.github/workflows/reusable.yml
    with:
      runner:
        ["self-hosted","ci-runner"]
YAML
check "a with: input's flow value on the next line fails" 1 "ci-runner" \
  in_tree next-line-flow-with
check "…and vouching for its tier passes it" 0 "1 workflow file" \
  in_tree next-line-flow-with .github/workflows ci-runner

# …and `with:`'s OWN value may be that collection. Slicing the line at its
# first `:` threw the mapping away, so `hot:` was read by nothing — and
# the split per value has to survive the fix: `safe:` being vouched for
# says nothing about the runner `hot:` names.
wf next-line-flow-map a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  check:
    uses: ./.github/workflows/reusable.yml
    with:
      {safe: '["self-hosted","pr-runner"]', hot: '["self-hosted","ci-runner"]'}
YAML
check "a with: flow mapping on the next line is read" 1 "ci-runner" \
  in_tree next-line-flow-map
check "…and its values stay split: vouching for one does not vouch the other" 1 \
  "labels: self-hosted, ci-runner" in_tree next-line-flow-map .github/workflows pr-runner
check "…and vouching for the tier that is actually named passes it" 0 \
  "1 workflow file" in_tree next-line-flow-map .github/workflows ci-runner,pr-runner

# The window is over the KEY'S OWN value and nothing else: a flow list
# under a key that is not a runner spec is not a runner spec. Without this
# row, reading every next-line flow collection in the file would pass.
wf next-line-flow-other a.yml <<'YAML'
name: ci
on:
  pull_request:
    branches:
      [self-hosted]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo build
YAML
check "a flow list under a key that is not a runner spec is not read" 0 \
  "1 workflow file" in_tree next-line-flow-other

# --- #395 round 7: an alias is its anchor's value --------------------------

# GitHub Actions accepts anchors and aliases, so this passes
# `["self-hosted","ci-runner"]` to the callee exactly as writing it out
# would. The `with:` window saw only the token `*runner-input` while the
# anchored value sat outside every window: a fail-open on PR-authored code
# against the very criterion decision 5 exists for (codex-bot blocking).
wf alias-with a.yml <<'YAML'
name: pr-checks
on: pull_request
env:
  RUNNER_INPUT: &runner-input '["self-hosted","ci-runner"]'
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: *runner-input
YAML
check "a self-hosted label reaching with: through an alias fails" 1 \
  "ci-runner" in_tree alias-with
check "…naming the anchored labels and not the alias token" 1 \
  "labels: self-hosted, ci-runner" in_tree alias-with
check "…and vouching for that tier passes the same file" 0 "1 workflow file" \
  in_tree alias-with .github/workflows ci-runner

# The same resolution on the other axis, where the anchored value is the
# `runs-on:` itself.
wf alias-runs-on a.yml <<'YAML'
name: ci
on: pull_request
env:
  RUNNER: &runner [self-hosted, ci-runner]
jobs:
  build:
    runs-on: *runner
    steps:
      - run: echo build
YAML
check "a runs-on: written as an alias is resolved and fails" 1 "ci-runner" \
  in_tree alias-runs-on

# Resolution happens where the VALUE is chosen, not where the spec is
# recorded: expanding a whole accumulated collection instead would merge
# these two inputs into one set, and a set is vouched when ANY member is —
# round 2's mis-vouch, bought back by the alias fix.
wf alias-split a.yml <<'YAML'
name: pr-checks
on: pull_request
env:
  SAFE: &safe '["self-hosted","pr-runner"]'
  HOT: &hot '["self-hosted","ci-runner"]'
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {a: *safe, b: *hot}
YAML
check "two aliased inputs on one line stay two specs" 1 \
  "labels: self-hosted, ci-runner" in_tree alias-split .github/workflows pr-runner
check "…and vouching for both tiers passes the file" 0 "1 workflow file" \
  in_tree alias-split .github/workflows pr-runner,ci-runner

# An anchor written where the spec is names no label of its own: `&r` is
# not something a consumer can vouch for, so it does not reach the message
# (#395 acceptance criterion 9).
wf anchor-inline a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: &r [self-hosted, ci-runner]
    steps:
      - run: echo build
YAML
check "an anchor at the spec is not reported as a label" 1 \
  "labels: self-hosted, ci-runner" in_tree anchor-inline

# An anchor is the head of a VALUE. A `&` inside a shell command is not
# one, and reading it there would let a script's words answer to an alias
# — here shadowing a hosted runner with a self-hosted spec.
wf anchor-in-run a.yml <<'YAML'
name: ci
on: pull_request
env:
  TIER: &tier ubuntu-latest
jobs:
  build:
    runs-on: *tier
    steps:
      - run: ./x.sh --flag &tier self-hosted
YAML
check "a & inside a run: command is not an anchor definition" 0 \
  "1 workflow file" in_tree anchor-in-run

# The limit, pinned so it cannot close or widen in silence: an alias whose
# anchor this file never defines stays as written. The guard resolves what
# the document itself defines and claims nothing beyond it.
wf alias-undefined a.yml <<'YAML'
name: pr-checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: *defined-somewhere-else
YAML
check "an alias with no anchor in this file is left as written" 0 \
  "1 workflow file" in_tree alias-undefined

# --- #395 round 7: a flow indicator is only an indicator in flow context ---

# `- a,#self-hosted` is the single plain scalar `a,#self-hosted` to YAML —
# a `,` may sit in a block-context plain scalar where it may not in a flow
# one. Cutting the value there dropped the tail and passed the file, which
# is the fail-open direction (claude-bot's nit).
wf block-comma-hash a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      - a,#self-hosted
    steps:
      - run: echo build
YAML
check "a block-context ,# does not end the value" 1 "self-hosted" \
  in_tree block-comma-hash

# …and the label SET carries it: `a,#self-hosted` is ONE label, so a
# vouch for `a` vouches for nothing here. A comma-joined set cannot hold
# a label containing a comma — it re-splits what labels_in refused to —
# which is why the set is newline-joined from labels_in through this
# window and into spec_vouched (#395 round 8).
check "…and a vouch for its head does not vouch for the whole label" 1 \
  "labels: a,#self-hosted —" in_tree block-comma-hash .github/workflows a

# …and the identical defect one arm over, in the window whose rule the one
# above is supposed to be. Fixing only the reported half would re-open the
# stated-once-implemented-twice split round 6 closed.
wf frag-comma-hash a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: a,#self-hosted
    steps:
      - run: echo build
YAML
check "a fragment's depth-0 ,# does not end the value either" 1 "self-hosted" \
  in_tree frag-comma-hash

# The converse, in both windows: a CLOSING bracket is the collection's own
# indicator even as it returns the depth to zero, so `]#` still opens a
# comment and the note behind it is not a label.
wf close-bracket-hash a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: [ubuntu-latest]#self-hosted
    steps:
      - run: echo build
YAML
check "a ]# still comments, so the note behind it is not a label" 0 \
  "1 workflow file" in_tree close-bracket-hash

wf close-bracket-hash-item a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      - [ubuntu-latest]#self-hosted
    steps:
      - run: echo build
YAML
check "…and in the block-sequence window too" 0 "1 workflow file" \
  in_tree close-bracket-hash-item

# --- #395 round 8: an anchor, an alias and a next-line value are POSITIONS ---

# Round 7 recorded an anchor at "the head of a value" and implemented the
# head of the value the LINE's own key introduces. A flow collection is a
# place values live too, so the anchor inside one was never recorded, the
# alias below it stayed unresolved, and the file passed with an empty
# allowlist — the fail-open direction, on the shape a caller writes when
# it names its runner once and uses it twice (codex-bot, blocking).
wf anchor-in-flow a.yml <<'YAML'
name: inline-anchor
on: pull_request
env: { RUNNER_INPUT: &runner-input '["self-hosted","ci-runner"]' }
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: *runner-input
YAML
check "an anchor at a value head INSIDE a flow mapping is recorded" 1 \
  "labels: self-hosted, ci-runner —" in_tree anchor-in-flow
check "…and vouching for that tier passes the same file" 0 \
  "1 workflow file" in_tree anchor-in-flow .github/workflows ci-runner

# An anchor's value is its OWN NODE and not the rest of the line. Taking
# the tail would resolve `*a` to `["self-hosted","ci"], B: pr-runner` and
# hand a SIBLING's scalar to the vouch test — round 2's mis-vouch,
# re-entered through the alias table — so vouching for the sibling's tier
# must still fail on the aliased one.
wf anchor-node-bound a.yml <<'YAML'
name: pr checks
on: pull_request
env: { A: &a '["self-hosted","ci"]', B: &b pr-runner }
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: { safe: *b, hot: *a }
YAML
check "an anchor's value stops at its own node" 1 \
  "labels: self-hosted, ci —" in_tree anchor-node-bound
check "…so the sibling's tier does not vouch for the anchored one" 1 \
  "labels: self-hosted, ci —" in_tree anchor-node-bound \
  .github/workflows pr-runner
check "…and the tier the anchor really names does" 0 "1 workflow file" \
  in_tree anchor-node-bound .github/workflows ci

# …and the stack that holds them: an anchor nested one collection deeper
# closes before the one holding it, so the two do not read each other's
# text.
wf anchor-nested a.yml <<'YAML'
name: pr checks
on: pull_request
env: { OUTER: &outer [ubuntu-latest, &inner '["self-hosted","ci-runner"]'] }
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: *inner
YAML
check "a nested anchor is its own value, not the collection holding it" 1 \
  "labels: self-hosted, ci-runner —" in_tree anchor-nested

# The converse the widening must not buy: an `&` that is not at a value
# head defines nothing. Whitespace PRESERVES the position rather than
# creating one, so a shell fragment cannot answer to an alias — the rule
# `run: a && b` has always relied on, now stated where a `&name` follows
# real text.
wf anchor-mid-scalar a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: gh api foo &later '["self-hosted","ci-runner"]'
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: *later
YAML
check "an & after real text is not an anchor definition" 0 \
  "1 workflow file" in_tree anchor-mid-scalar

# …and the two characters that would otherwise create a position where
# YAML has none. A `:` and a `[` are indicators only IN FLOW CONTEXT, and
# flow context is entered only where the value's own first character
# enters it — so in a block-context plain scalar both are text and the
# `&tier` after them defines nothing. Each file anchors `tier` FOR REAL
# further up, so a false record would be visible rather than merely
# unresolved: PyYAML 6.0.2 resolves `*tier` to `ubuntu-latest` in both,
# and the guard must agree.
wf anchor-after-colon a.yml <<'YAML'
name: pr checks
on: pull_request
env:
  TIER: &tier ubuntu-latest
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: prom_query up:&tier '["self-hosted","ci-runner"]'
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: *tier
YAML
check "a : inside a plain scalar opens no value head" 0 \
  "1 workflow file" in_tree anchor-after-colon

wf anchor-after-bracket a.yml <<'YAML'
name: pr checks
on: pull_request
env:
  TIER: &tier ubuntu-latest
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo [&tier '["self-hosted","ci-runner"]']
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: *tier
YAML
check "…and a [ inside one opens no collection" 0 \
  "1 workflow file" in_tree anchor-after-bracket

# A `*name` INSIDE A QUOTED SCALAR is text the callee receives verbatim,
# not an alias. Expanding it filed a spec naming a runner the file does
# not name — exit 1 on a correct workflow, and a guard's false positive
# reds a consumer's main with nothing to vouch for (codex-bot, blocking).
wf alias-in-quotes a.yml <<'YAML'
name: pr checks
on: pull_request
env:
  RUNNER_INPUT: &runner-input '["self-hosted","ci-runner"]'
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: { note: "literal *runner-input" }
YAML
check "a *name inside a quoted scalar is text, not an alias" 0 \
  "1 workflow file" in_tree alias-in-quotes

# …and the converse that keeps the fix from being a mute: the same file
# with the same anchor, the alias written where YAML means one.
wf alias-out-of-quotes a.yml <<'YAML'
name: pr checks
on: pull_request
env:
  RUNNER_INPUT: &runner-input '["self-hosted","ci-runner"]'
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: { runner: *runner-input }
YAML
check "…and outside them it is still resolved" 1 \
  "labels: self-hosted, ci-runner —" in_tree alias-out-of-quotes

# The quote a scalar opens is opaque ACROSS ITS PHYSICAL LINES here too,
# because this runs on the continuation lines of an open collection: the
# resolver takes the quote state the scanner is already in rather than
# assuming a fresh line. Round 4's rule, in the last function that lacked
# it.
wf alias-in-wrapped-quotes a.yml <<'YAML'
name: pr checks
on: pull_request
env:
  RUNNER_INPUT: &runner-input '["self-hosted","ci-runner"]'
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with: {
      note: 'a note that wraps the line
        and mentions *runner-input in passing'
    }
YAML
check "a quoted scalar wrapping a line keeps its *name as text" 0 \
  "1 workflow file" in_tree alias-in-wrapped-quotes

# THE NEXT-LINE VALUE MAY BE A SCALAR. Round 7 read the flow-collection
# spelling and named `[` and `{`; a plain or quoted scalar on the line
# below its key reached no arm at all — the sequence window closed
# recording nothing and no fragment matched. `actionlint` accepts both of
# these files and PyYAML resolves the value, so they are runner specs
# GitHub schedules (claude-bot, blocking).
wf next-line-scalar a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      self-hosted
    steps:
      - run: make test
YAML
check "a bare scalar on the line after runs-on: is read" 1 \
  "labels: self-hosted —" in_tree next-line-scalar
check "…and vouching for it passes the same file" 0 "1 workflow file" \
  in_tree next-line-scalar .github/workflows self-hosted

# …and on the surface #395 exists for: a caller wrapping its JSON input
# to the next line, which is the realistic way a long one gets written.
wf next-line-quoted a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner:
        '["self-hosted","ci-runner"]'
YAML
check "a quoted JSON input on the next line is read" 1 \
  "labels: self-hosted, ci-runner —" in_tree next-line-quoted
check "…and vouching for its tier passes it" 0 "1 workflow file" \
  in_tree next-line-quoted .github/workflows ci-runner

# A SEQUENCE MAY SIT AT ITS KEY'S OWN INDENTATION, which YAML permits and
# every other fixture in this file writes one level in. It is caught today
# by the `- …` half of the window's close rule, and it is written down
# BEFORE that rule gains an indentation half (#402 decision 3) so the
# widening has a floor: an indentation-only bound would drop this row, and
# a regression fixture added after the change could not tell a rule that
# still holds from one the change wrote.
wf seq-at-key-indent a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
    - self-hosted
    - ci-runner
    steps:
      - run: make test
YAML
check "a sequence at its key's own indentation is still the key's value" 1 \
  "labels: self-hosted, ci-runner —" in_tree seq-at-key-indent
check "…and vouching for its tier passes the same file" 0 "1 workflow file" \
  in_tree seq-at-key-indent .github/workflows ci-runner

# THE BLOCK-MAPPING FORM OF `runs-on:`, which is the shape #402 closes:
# `group:`/`labels:` keys one level in rather than a value beside the key,
# documented GitHub syntax. The `labels:` key is the runner spec's label
# set and is read; a `pull_request` file naming a self-hosted tier that
# way exited 0 with an empty allowlist, no vouch asked and no finding
# printed, on a line the guard already reads.
wf block-labels-only a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      labels: [self-hosted, ci-runner]
    steps:
      - run: make test
YAML
check "a labels: key one level in is the runner spec" 1 \
  "labels: self-hosted, ci-runner —" in_tree block-labels-only
check "…and the finding names the file" 1 "a.yml" in_tree block-labels-only
check "…and the line it found them on" 1 "6:       labels: [self-hosted, ci-runner]" \
  in_tree block-labels-only
check "…and vouching for one label of the set vouches the set" 0 \
  "1 workflow file" in_tree block-labels-only .github/workflows ci-runner

# THE TWO ROWS THAT PINNED THIS GAP AS A PASS, and their expected status
# is this issue's deliverable arriving: #395 round 8 wrote them to hold
# the boundary its own widening stopped at, one spelling each, so that
# closing the gap could not happen in silence. #402 closes it, so they
# flip together — the fixture text of neither is touched, which is what
# makes the flip the measurement (#402 acceptance criterion 9).
wf block-group-mapping a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      group: linux
      labels: [self-hosted, ci-runner]
    steps:
      - run: make test
YAML
check "a group: key above the labels: does not hide it" 1 \
  "labels: self-hosted, ci-runner —" in_tree block-group-mapping

# …and the spelling that decides it, because the group-first file above
# would have passed under either rule: with `labels:` on the FIRST line,
# a next-line arm reading first lines would have read it and left the
# group-first one open. Both are read now, by the same window, which is
# why the exclusion could only come out with the indentation bound.
wf block-labels-first a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      labels: [self-hosted, ci-runner]
      group: linux
    steps:
      - run: make test
YAML
check "…and neither does one below it, in the labels-first spelling" 1 \
  "labels: self-hosted, ci-runner —" in_tree block-labels-first

# …and the `labels:` value may be a block SEQUENCE under a bare key,
# which is the second of decision 1's two spellings. The `group:` line
# above it proves the other half of the window's rule: a key that is not
# `labels:` contributes nothing AND closes nothing, or the sequence
# beneath the key below it would be outside every window again.
wf block-group-seq-labels a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      group: linux
      labels:
        - self-hosted
        - ci-runner
    steps:
      - run: make test
YAML
check "a block-sequence labels: under a non-labels key is read" 1 \
  "labels: self-hosted, ci-runner —" in_tree block-group-seq-labels
check "…and vouching for its tier passes the same file" 0 "1 workflow file" \
  in_tree block-group-seq-labels .github/workflows ci-runner

# A `labels:` VALUE GOES THROUGH THE SAME VALUE READER as every other
# value: a flow collection spread across lines is one value, so the tier
# on the second line is part of the set the first line opens (#402
# decision 5). Nothing is invented for this key.
wf block-labels-wrapped a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      labels: [self-hosted,
        ci-runner]
    steps:
      - run: make test
YAML
check "a labels: collection written across lines is one value" 1 \
  "labels: self-hosted, ci-runner —" in_tree block-labels-wrapped
check "…so vouching for the tier on its second line passes it" 0 \
  "1 workflow file" in_tree block-labels-wrapped .github/workflows ci-runner

# A RUNNER GROUP IS NOT A LABEL, and this row asserts a KNOWN FALSE
# NEGATIVE so that closing it later is a visible decision and reopening it
# is a red row: a group names its hardware elsewhere, so its name cannot
# be vouched for as a label, and #395 decision 9 kept it out. The group
# here is itself named `self-hosted`, the shape that would pass by
# accident if the rule were the string rather than the key (#402
# decision 2).
wf block-group-only a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      group: self-hosted
    steps:
      - run: make test
YAML
check "a group: named self-hosted with no labels: key still passes" 0 \
  "1 workflow file" in_tree block-group-only

# PARITY IS THE PROPERTY, so it is asserted as one row rather than as two
# that could drift apart: the block mapping and the inline mapping of the
# SAME value get the same verdict under the same allowlist. Two spellings
# of one value cannot disagree, and a suite that grades them separately
# would not notice when they did.
wf parity-block a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on:
      group: linux
      labels: [self-hosted, ci-runner]
    steps:
      - run: make test
YAML
wf parity-inline a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  build:
    runs-on: {group: linux, labels: [self-hosted, ci-runner]}
    steps:
      - run: make test
YAML

# same_verdict [<allowlist>] — the two spellings' exit statuses, reported
# as one string: `agree: <status>` pins that they agree AND which verdict
# they agree on, so a parity row can never be satisfied by both spellings
# going quietly wrong in the same direction.
same_verdict() {
  local labels="${1:-}" block inline
  (cd "$TMP/parity-block" && bash "$SCRIPT" .github/workflows "$labels") >/dev/null 2>&1
  block=$?
  (cd "$TMP/parity-inline" && bash "$SCRIPT" .github/workflows "$labels") >/dev/null 2>&1
  inline=$?
  if [ "$block" -eq "$inline" ]; then
    printf 'agree: %s\n' "$block"
  else
    printf 'disagree: block %s, inline %s\n' "$block" "$inline"
  fi
}
check "block and inline mappings of one value both fail unvouched" 0 \
  "agree: 1" same_verdict
check "…and both pass under the same allowlist" 0 "agree: 0" \
  same_verdict ci-runner

# …and under a `with:` key nothing narrows: the mapping's own lines keep
# being read by the input arm, exactly as they were before the widening.
wf with-block-mapping a.yml <<'YAML'
name: pr checks
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner:
        labels: [self-hosted, ci-runner]
YAML
check "a with: input's block mapping is still read by the input arm" 1 \
  "labels: self-hosted, ci-runner —" in_tree with-block-mapping

# A `,` SEPARATES LABELS ONLY WHERE THE VALUE HAS FLOW STRUCTURE. In
# BLOCK context a plain scalar may contain one, so `pr-runner,#self-hosted`
# is a single label: splitting it named two things the file does not name,
# and — the half that reaches the verdict — let a vouch for `pr-runner`
# pass a label YAML says does not exist (claude-bot's nit).
wf plain-comma-label a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: pr-runner,#self-hosted
    steps:
      - run: echo build
YAML
check "a block plain scalar's comma is its own text, not a separator" 1 \
  "labels: pr-runner,#self-hosted —" in_tree plain-comma-label
check "…so a vouch for pr-runner does not vouch for that label" 1 \
  "labels: pr-runner,#self-hosted —" in_tree plain-comma-label \
  .github/workflows pr-runner

# …and the converse, which is the trade decision 5 already ships: a
# bracket anywhere in the value is flow structure INCLUDING inside a
# quoted scalar, so a JSON list written as one YAML scalar keeps splitting
# into the labels the callee will use.
wf quoted-json-still-splits a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: '["self-hosted","pr-runner"]'
YAML
check "a quoted JSON list still splits into its labels" 0 \
  "1 workflow file" in_tree quoted-json-still-splits \
  .github/workflows pr-runner

# A LEADING DASH IS PUNCTUATION ONLY WHERE IT IS THE INDICATOR, which is
# the same sentence one character over. `-self-hosted` is a label GitHub
# schedules and actionlint accepts (PyYAML reads this file's `runs-on` as
# the scalar `-self-hosted`), and stripping every leading dash rewrote it
# before the vouch test saw it (codex-bot's blocker).
wf dash-flow a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: [-self-hosted]
    steps:
      - run: echo build
YAML
check "a value-leading dash stays part of the label" 1 \
  "labels: -self-hosted —" in_tree dash-flow
check "…and the exact label vouches for it" 0 "1 workflow file" \
  in_tree dash-flow .github/workflows -self-hosted
# The half that reaches the verdict: the erasure did not only refuse a
# correct vouch, it let a vouch for a label the file does not name PASS —
# PR-authored code on a tier nobody vouched for.
check "…while a vouch for the dashless label does not" 1 \
  "labels: -self-hosted —" in_tree dash-flow .github/workflows self-hosted

# The same label in the plain spelling, which is how it would really be
# written, so the fix cannot hold for the flow arm alone.
wf dash-plain a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: -self-hosted
    steps:
      - run: echo build
YAML
check "a plain scalar's leading dash stays too" 1 \
  "labels: -self-hosted —" in_tree dash-plain
check "…vouched by the exact label, and only by it" 0 "1 workflow file" \
  in_tree dash-plain .github/workflows -self-hosted

# codex-bot's reported file, whose two labels differ only by the dash: the
# message names them both whole, and EITHER vouches for the set — a spec
# is vouched when any of its labels is, adding labels only narrowing the
# runners that match (this script's header).
wf dash-pair a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: [self-hosted, -self-hosted]
    steps:
      - run: echo build
YAML
check "two labels differing only by the dash are named apart" 1 \
  "labels: self-hosted, -self-hosted —" in_tree dash-pair
check "…and the dashed one vouches for the set" 0 "1 workflow file" \
  in_tree dash-pair .github/workflows -self-hosted

# …and the indicator itself still goes, which is what the narrowed rule
# must not take back: the item's `- ` is structure, the value's dash is
# text, and both spellings sit in one file's window.
wf dash-item a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      - -self-hosted
    steps:
      - run: echo build
YAML
check "a sequence item's indicator goes, its value's dash stays" 1 \
  "labels: -self-hosted —" in_tree dash-item
check "…so the item is vouched by the label it names" 0 "1 workflow file" \
  in_tree dash-item .github/workflows -self-hosted

wf plain-item a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      - self-hosted
    steps:
      - run: echo build
YAML
check "an ordinary item is still read without its indicator" 1 \
  "labels: self-hosted —" in_tree plain-item
check "…and vouches with no dash in sight" 0 "1 workflow file" \
  in_tree plain-item .github/workflows self-hosted

# The indicator is peeled to a fixed point, so a nested item reduces
# rather than leaving `- self-hosted` as a label no runner carries.
# PyYAML reads this `runs-on` as [['self-hosted']].
wf dash-nested a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      - - self-hosted
    steps:
      - run: echo build
YAML
check "a nested item's indicators both go" 1 \
  "labels: self-hosted —" in_tree dash-nested
check "…leaving a label the consumer can vouch for" 0 "1 workflow file" \
  in_tree dash-nested .github/workflows self-hosted

# …and an item that is only its indicator names nothing, rather than
# filing `-` as a label and putting a character no runner carries in the
# message. The dash-alone rule is the one arm no other row reaches.
wf dash-empty a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      - self-hosted
      -
    steps:
      - run: echo build
YAML
check "a null item is read with the set it sits in" 1 \
  "labels: self-hosted —" in_tree dash-empty
check_absent "…and files no label of its own" 1 "self-hosted, -" \
  in_tree dash-empty

# THE INDICATOR IS PEELED BEFORE THE QUOTES GO, which is round 9's rule at
# the one position YAML permits it. Round 9 peeled after the value had
# been unquoted and split at its commas, so a flow ITEM whose own text
# opens with `- ` was read as structure — codex-bot's and kimi-bot's
# blocker, claude-bot's nit, one shape. PyYAML 6.0.2 reads this file's
# `runs-on` as ['self-hosted', '- pr-runner'], and `[a, - b]` does not
# parse at all, so a dash-plus-whitespace inside a flow collection is
# never an indicator in any spelling.
wf quoted-dash-flow a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: [self-hosted, "- pr-runner"]
    steps:
      - run: echo build
YAML
check "a quoted label's own leading dash-space survives" 1 \
  "labels: self-hosted, - pr-runner —" in_tree quoted-dash-flow
check "…and the exact label the file names vouches for it" 0 \
  "1 workflow file" in_tree quoted-dash-flow .github/workflows '- pr-runner'
# The half that reaches the verdict, as in round 9: the erasure also let a
# label the file does not name vouch for the tier.
check "…while the peeled spelling does not" 1 \
  "labels: self-hosted, - pr-runner —" in_tree quoted-dash-flow \
  .github/workflows pr-runner

# claude-bot's spelling of the same shape, where the dashed label is the
# self-hosted one itself, so the vouch test reads it rather than its
# neighbour. PyYAML: ['- self-hosted', 'linux'].
wf quoted-dash-lone a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: ["- self-hosted", linux]
    steps:
      - run: echo build
YAML
check "a quoted dash-space label is named whole" 1 \
  "labels: - self-hosted, linux —" in_tree quoted-dash-lone
check "…vouched by itself" 0 "1 workflow file" \
  in_tree quoted-dash-lone .github/workflows '- self-hosted'
check "…and not by the label the peel used to leave" 1 \
  "labels: - self-hosted, linux —" in_tree quoted-dash-lone \
  .github/workflows self-hosted

# …and through a `with:` key as a JSON list in a string, where the dash
# was never an indicator in any window: the value is one YAML scalar
# whose text is JSON, and its item's dash is the callee's label.
wf quoted-dash-json a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  call:
    uses: ./.github/workflows/reusable.yml
    with:
      runner: '["- self-hosted","ci-runner"]'
YAML
check "a JSON list's dashed item keeps its dash" 1 \
  "labels: - self-hosted, ci-runner —" in_tree quoted-dash-json
check "…and only that label vouches for it" 0 "1 workflow file" \
  in_tree quoted-dash-json .github/workflows '- self-hosted'
check "…the dashless one does not" 1 \
  "labels: - self-hosted, ci-runner —" in_tree quoted-dash-json \
  .github/workflows self-hosted

# The row where the two rules meet in one value: a block sequence item
# that IS an indicator followed by a quoted label whose text opens with
# another `- `. The peel takes the first, meets the quote and stops.
# PyYAML: ['- self-hosted'] for both quote styles.
wf quoted-dash-item a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on:
      - "- self-hosted"
      - '- ci-runner'
    steps:
      - run: echo build
YAML
check "an item's indicator goes and its quoted dash stays" 1 \
  "labels: - self-hosted, - ci-runner —" in_tree quoted-dash-item
check "…so the set is vouched by the label it really names" 0 \
  "1 workflow file" in_tree quoted-dash-item .github/workflows '- self-hosted'
check "…and not by the one the double peel would have left" 1 \
  "labels: - self-hosted, - ci-runner —" in_tree quoted-dash-item \
  .github/workflows self-hosted

# …and the spelling that is no collection at all, so the rule is pinned in
# every window a value reaches labels_in through rather than in the two
# that were reported. PyYAML reads this `runs-on` as the scalar
# '- self-hosted'.
wf quoted-dash-scalar a.yml <<'YAML'
name: ci
on: pull_request
jobs:
  build:
    runs-on: "- self-hosted"
    steps:
      - run: echo build
YAML
check "a quoted scalar's dash-space is the label's own text" 1 \
  "labels: - self-hosted —" in_tree quoted-dash-scalar
check "…and it is vouched by that text and no other" 0 "1 workflow file" \
  in_tree quoted-dash-scalar .github/workflows '- self-hosted'
check "…the dashless spelling vouching for nothing here" 1 \
  "labels: - self-hosted —" in_tree quoted-dash-scalar \
  .github/workflows self-hosted

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
