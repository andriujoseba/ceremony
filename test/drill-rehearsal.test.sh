#!/usr/bin/env bash
# The drill instrument's contract suite (#313). The split the repo already
# uses holds here too: this suite proves every decision offline against a
# recording `gh` stub, and the live shakedown run proves the doors.
#
# File-wide, because both idioms are load-bearing here rather than incidental:
# shellcheck disable=SC2016 # a `bash -c` body's $1 belongs to that process
# shellcheck disable=SC2030,SC2031 # each stub probe runs in its own subshell
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=drill/lib/scratch.sh
source "$ROOT/drill/lib/scratch.sh"
# shellcheck source=drill/lib/candidate.sh
source "$ROOT/drill/lib/candidate.sh"
# shellcheck source=drill/lib/fixture.sh
source "$ROOT/drill/lib/fixture.sh"
# shellcheck source=drill/lib/probes.sh
source "$ROOT/drill/lib/probes.sh"
# shellcheck source=drill/lib/record.sh
source "$ROOT/drill/lib/record.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CAND_SHA=c0ffee1234567890c0ffee1234567890c0ffee12
FORK=forkowner/ceremony
FORK_REF=drill/0.7.0
SCRATCH_OWNER=drillowner
SCRATCH="$SCRATCH_OWNER/ceremony-drill-0.7.0"

san() { printf '%s' "$1" | tr '/' '_'; }

# ---------------------------------------------------------------------------
# D4, refusal one — the instrument archives and never deletes (#135). The
# guard is on the call, not on the operator remembering: `delete_repo` is
# absent from fleet tokens by doctrine, so retrying the 403 wall is the
# failure mode, and both 0.2.0 drills reached it independently.
# ---------------------------------------------------------------------------
check "gh repo delete is refused" 1 "archives and never deletes" \
  drill_guard_delete repo delete some/repo
check "DELETE on the repo root is refused" 1 "the delete is the operator's own step" \
  drill_guard_delete api repos/o/n --method DELETE
check "DELETE on the repo root with -X is refused" 1 "archives and never deletes" \
  drill_guard_delete api -X DELETE repos/o/n
check "a trailing slash does not smuggle the repo delete past the guard" 1 \
  "archives and never deletes" drill_guard_delete api --method DELETE repos/o/n/
check "a leading slash does not smuggle it either" 1 "archives and never deletes" \
  drill_guard_delete api --method=DELETE /repos/o/n
# Probe 6's own cleanup: the mismatched tag's ref is the operator's artefact
# and deleting it is the probe, not the disposal wall.
check "deleting a tag ref is allowed" 0 "" \
  drill_guard_delete api repos/o/n/git/refs/tags/9.9.9 --method DELETE
check "reading the repo is allowed" 0 "" drill_guard_delete api repos/o/n
check "a non-api gh subcommand passes through" 0 "" drill_guard_delete repo create o/n

# ---------------------------------------------------------------------------
# D4, refusal two — the 0.1.0 shadow-tag rule. A ref named like the tag on the
# canonical repo shadows that tag for every consumer until someone deletes it,
# so the fork-ref rewrite is the only pin path this instrument takes.
# ---------------------------------------------------------------------------
check "a bare version is tag-named" 0 "" pin_is_tag_named 0.7.0
check "a v-prefixed version is tag-named" 0 "" pin_is_tag_named v0.7.0
check "an rc is tag-named too" 0 "" pin_is_tag_named 0.7.0-rc1
check "a fully-qualified tag ref is tag-named" 0 "" pin_is_tag_named refs/tags/0.7.0
check "the drill's own ref shape is not tag-named" 1 "" pin_is_tag_named drill/0.7.0
check "a candidate branch is not tag-named" 1 "" pin_is_tag_named build/313-drill
check "the canonical repo at a tag-named ref is a hard error" 1 \
  "shadows that tag for every consumer" \
  pin_assert_fork_ref heavy-duty/ceremony 0.7.0
check "the canonical repo at an rc-named ref is a hard error too" 1 \
  "0.1.0 shadow-tag rule" pin_assert_fork_ref heavy-duty/ceremony 0.7.0-rc1
check "a fork at a tag-named ref is allowed — it shadows nothing consumers read" 0 "" \
  pin_assert_fork_ref forkowner/ceremony 0.7.0
check "the canonical repo at a drill ref is allowed" 0 "" \
  pin_assert_fork_ref heavy-duty/ceremony drill/0.7.0

# The rewrite itself: every carrier line, indentation preserved.
printf '%s\n' 'name: release' 'env:' '  CEREMONY_SELF_REF: "0.6.3"' 'jobs: {}' \
  >"$TMP/pin.yml"
check "the pin is read out of a carrier" 0 "0.6.3" pin_read "$TMP/pin.yml"
pin_rewrite "$TMP/pin.yml" "$CAND_SHA"
check "the pin is rewritten to the candidate SHA" 0 "$CAND_SHA" pin_read "$TMP/pin.yml"
check "the rewrite preserves the carrier's indentation" 0 "  CEREMONY_SELF_REF: \"$CAND_SHA\"" \
  cat "$TMP/pin.yml"
check "the rewrite touches nothing else" 0 "4" \
  bash -c 'wc -l < "$1" | tr -d " "' _ "$TMP/pin.yml"

# ---------------------------------------------------------------------------
# The refusal assertion itself (D3): a probe's nothing-created claim is these
# two measurements, never the prose beside them.
# ---------------------------------------------------------------------------
check "a refusal that created nothing holds" 0 "" \
  test -z "$(probe_verdict failure failure 2 2 1 1 0 0)"
check "a refusal that left a tag behind reds its probe" 0 "tags moved 2→3" \
  probe_verdict failure failure 2 3 1 1 0 0
check "a refusal that left a release behind reds its probe" 0 "releases moved 1→2" \
  probe_verdict failure failure 2 2 1 2 0 0
check "a refusal that came up green reds its probe" 0 "concluded 'success', expected 'failure'" \
  probe_verdict failure success 2 2 1 1 0 0
check "a ceremony that published nothing reds its probe" 0 "releases moved 0→0, expected a delta of 1" \
  probe_verdict success success 0 1 0 0 1 1
check "a ceremony that published exactly one holds" 0 "" \
  test -z "$(probe_verdict success success 0 1 0 1 1 1)"
check "the probe names are the doctrine's six" 0 "" \
  test "$(probe_name 4)" = "re-run of the completed ceremony"

# ---------------------------------------------------------------------------
# The record's shape check — the script runs it on its own emission, because
# the script is now the record's only author and nothing else will notice.
# ---------------------------------------------------------------------------
record_fixture() { # <run-cell-for-probe-3>
  local three="$1"
  cat <<EOF
# 0.7.0 — drill record

| # | probe | run | tags | releases | result |
|---|---|---|---|---|---|
| 1 | merge-door ceremony | [1001](https://github.com/o/n/actions/runs/1001) | 0 → 1 | 0 → 1 | ✅ ok |
| 2 | mislabeled ordinary PR | [1002](https://github.com/o/n/actions/runs/1002) | 1 → 1 | 1 → 1 | ✅ ok |
| 3 | bare-version PR | $three | 1 → 1 | 1 → 1 | ✅ ok |
| 4 | re-run of the completed ceremony | [1004](https://github.com/o/n/actions/runs/1004) | 1 → 1 | 1 → 1 | ✅ ok |
| 5 | tag-door release from a manual tag | [1005](https://github.com/o/n/actions/runs/1005) | 1 → 2 | 1 → 2 | ✅ ok |
| 6 | mismatched tag | [1006](https://github.com/o/n/actions/runs/1006) | 2 → 2 | 2 → 2 | ✅ ok |

## What the rehearsal establishes

- ✅ one
- ✅ two
- ✅ three
- ✅ four
- ✅ five
- ✅ six

It is **pending the operator's delete**.
EOF
}
record_fixture "[1003](https://github.com/o/n/actions/runs/1003)" >"$TMP/record-good.md"
record_fixture "run 3, by hand" >"$TMP/record-no-run.md"
check "a whole record passes the shape check" 0 "six probe rows" \
  record_check "$TMP/record-good.md"
check "a probe row with no run ID reds the shape check" 1 "probe 3 has no run ID" \
  record_check "$TMP/record-no-run.md"
# The diagnostic's own opening: `${problems#; }` strips the separator the
# accumulator starts with, and the old `${problems# ; }` matched nothing.
check "the diagnostic opens on the problem, not on its separator" 1 \
  "record_check: probe 3 has no run ID" record_check "$TMP/record-no-run.md"
# The dash exemption is for a probe that aborted before any run existed, and
# for nothing else: a row that merely lost its run ID still reds, however it
# is marked.
sed 's#| \[1003\](https://github.com/o/n/actions/runs/1003) |#| — |#' \
  "$TMP/record-good.md" >"$TMP/record-dash-pass.md"
check "a dash run cell on a passing row still reds the shape check" 1 \
  "probe 3 has no run ID" record_check "$TMP/record-dash-pass.md"
sed -e 's#| \[1003\](https://github.com/o/n/actions/runs/1003) |#| — |#' \
  -e '/| — |/ s/| ✅ ok |/| ❌ aborted before it reached a verdict |/' \
  "$TMP/record-good.md" >"$TMP/record-aborted.md"
check "a probe that aborted before any run is the one row exempt" 0 \
  "six probe rows" record_check "$TMP/record-aborted.md"
head -n 8 "$TMP/record-good.md" >"$TMP/record-short.md"
printf 'It is **pending the operator'"'"'s delete**.\n' >>"$TMP/record-short.md"
check "a record missing probes reds the shape check" 1 "probe 5 has no row" \
  record_check "$TMP/record-short.md"
grep -v 'pending the operator' "$TMP/record-good.md" >"$TMP/record-no-disposal.md"
check "a record that does not state the disposal reds the shape check" 1 \
  "does not state the disposal" record_check "$TMP/record-no-disposal.md"
sed 's/| 1 → 2 | 1 → 2 |/| many | more |/' "$TMP/record-good.md" >"$TMP/record-prose.md"
check "a probe row whose counts are prose reds the shape check" 1 \
  "probe 5 has no before/after counts" record_check "$TMP/record-prose.md"

# ---------------------------------------------------------------------------
# The record's golden shape (D2): candidate refs and SHAs, the fork ref and
# the rewritten pin, the scratch repo by full owner/name, a probe table with
# run IDs, and the disposal as observed.
# ---------------------------------------------------------------------------
{
  printf 'version\t0.7.0\n'
  printf 'scratch\t%s\n' "$SCRATCH"
  printf 'created\t2026-08-09T00:00:00Z\n'
  printf 'candidate_sha\t%s\n' "$CAND_SHA"
  printf 'candidate_ref\tbuild/313-drill-rehearsal\n'
  printf 'fork_repo\t%s\n' "$FORK"
  printf 'fork_ref\t%s\n' "$FORK_REF"
  printf 'fork_head\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
  printf 'pin\t%s\n' "$CAND_SHA"
  printf 'disposal\tthe repository is **archived** — a fresh read afterwards reported `archived=true private=true`\n'
  printf 'runner\tdrill-runner\n'
  printf 'stamp\t2026-08-09\n'
} >"$TMP/ctx.tsv"
{
  printf '1\tmerge-door ceremony\t1001\t1\tPASS\t0\t1\t0\t1\texactly one release\n'
  printf '2\tmislabeled ordinary PR\t1002\t1\tPASS\t1\t1\t1\t1\tgreen NOTICE no-op\n'
  printf '3\tbare-version PR without `release`\t1003\t1\tPASS\t1\t1\t1\t1\trefused at decide\n'
  printf '4\tre-run of the completed ceremony\t1001\t2\tPASS\t1\t1\t1\t1\trefused at the assert\n'
  printf '5\ttag-door release from a manual tag\t1005\t1\tPASS\t1\t2\t1\t2\tpublished from its own section\n'
  printf '6\tmismatched tag\t1006\t1\tPASS\t2\t2\t2\t2\trefused before publication\n'
} >"$TMP/probes.tsv"
printf '1000\tsuccess\tthe caller landing on an armed tree\n' >"$TMP/setup.tsv"
record_render "$TMP/ctx.tsv" "$TMP/probes.tsv" "$TMP/setup.tsv" >"$TMP/rendered.md"
check "the rendered record matches its golden shape" 0 "" \
  diff -u "$ROOT/test/fixtures/drill-record.golden.md" "$TMP/rendered.md"
check "the rendered record passes its own shape check" 0 "six probe rows" \
  record_check "$TMP/rendered.md"
check "probe 4's re-run is recorded as a later attempt of the same run" 0 \
  "actions/runs/1001) (attempt 2)" cat "$TMP/rendered.md"
check "a failed probe is recorded as failed, not smoothed over" 0 "1 probe(s) failed" \
  bash -c 'sed "s/\tPASS\t1\t1\t1\t1\trefused at decide/\tFAIL\t1\t2\t1\t1\ttags moved 1→2/" "$2" >"$4/failed.tsv"
    source "$1/drill/lib/record.sh"; record_render "$3" "$4/failed.tsv" "$4/setup.tsv"' \
  _ "$ROOT" "$TMP/probes.tsv" "$TMP/ctx.tsv" "$TMP"

# ---------------------------------------------------------------------------
# The conclusion is evidence exactly as the table is, and round 1 caught it
# not being: `## What the rehearsal establishes` was one unconditional
# heredoc, so a record whose probes 3 and 6 failed emitted the honest banner
# and the ❌ rows and then closed by asserting the two refusals that had just
# failed. These cases sit here because that is precisely where the row
# assertions above stopped.
# ---------------------------------------------------------------------------
sed -e 's/\tPASS\t1\t1\t1\t1\trefused at decide/\tFAIL\t1\t2\t1\t1\ttags moved 1→2, expected a delta of 0/' \
  -e 's/\tPASS\t2\t2\t2\t2\trefused before publication/\tFAIL\t2\t2\t2\t3\treleases moved 2→3, expected a delta of 0/' \
  "$TMP/probes.tsv" >"$TMP/two-failed.tsv"
record_render "$TMP/ctx.tsv" "$TMP/two-failed.tsv" "$TMP/setup.tsv" >"$TMP/two-failed.md"
check "a failed probe's claim does not survive into the conclusion" 1 "" \
  grep -qF 'refused a bare version push' "$TMP/two-failed.md"
check "the second failed probe's claim does not survive either" 1 "" \
  grep -qF 'refused a mismatched tag before creating anything' "$TMP/two-failed.md"
check "the failure takes the withdrawn claim's place" 0 \
  "probe 3 (bare-version PR without \`release\`) failed: tags moved 1→2" \
  cat "$TMP/two-failed.md"
check "a passing probe's claim still stands beside the failures" 0 \
  "✅ The merge door refused a re-run of its own completed ceremony." \
  cat "$TMP/two-failed.md"
check "the conclusion counts what the run did not establish" 0 \
  "Not established: 2 of the six" cat "$TMP/two-failed.md"
check "the clean-run closing sentence is not on a failed record" 1 "" \
  grep -qF 'Every refusal claim above is asserted' "$TMP/two-failed.md"
check "a two-failure record still passes the shape check" 0 "six probe rows" \
  record_check "$TMP/two-failed.md"
# A probe that never wrote a row establishes nothing either, and the
# conclusion counts it with the failures rather than passing over it.
grep -v '^6	' "$TMP/probes.tsv" >"$TMP/five.tsv"
check "a probe that never ran is named, not skipped" 0 \
  "probe 6 did not run, so this record makes no claim for it" \
  record_render "$TMP/ctx.tsv" "$TMP/five.tsv" "$TMP/setup.tsv"
# The shape check grades the conclusion too: a record whose claims were
# trimmed is as unreadable as one whose rows were.
grep -v '^- ✅ The tag door' "$TMP/rendered.md" >"$TMP/record-short-claims.md"
check "a conclusion missing a probe line reds the shape check" 1 \
  "the conclusion has 4 probe lines, expected 6" \
  record_check "$TMP/record-short-claims.md"

# ---------------------------------------------------------------------------
# `probe_counts` refuses a count that did not read (round 1). An API error
# prints nothing, and `$((after - before))` over an empty string is 0 — the
# very delta a refusal probe is looking for, so the swallowed read would have
# recorded a PASS on measurements nobody took.
# ---------------------------------------------------------------------------
check "a tag count that did not read is refused, never taken for zero" 1 \
  "the tag count at some/repo did not read as a number" \
  bash -c 'source "$1/drill/lib/scratch.sh"; source "$1/drill/lib/probes.sh"
    scratch_tag_count() { printf ""; }; scratch_release_count() { printf "3\n"; }
    probe_counts some/repo' _ "$ROOT"
check "a release count that came back as prose is refused too" 1 \
  "the release count at some/repo did not read as a number" \
  bash -c 'source "$1/drill/lib/scratch.sh"; source "$1/drill/lib/probes.sh"
    scratch_tag_count() { printf "2\n"; }; scratch_release_count() { printf "not found\n"; }
    probe_counts some/repo' _ "$ROOT"
check "two counts that did read are what probe_counts prints" 0 "2	3" \
  bash -c 'source "$1/drill/lib/scratch.sh"; source "$1/drill/lib/probes.sh"
    scratch_tag_count() { printf "2\n"; }; scratch_release_count() { printf "3\n"; }
    probe_counts some/repo' _ "$ROOT"

# ---------------------------------------------------------------------------
# The stub, and the fixture-before-caller ordering it lets us drive.
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cp "$ROOT/test/fixtures/drill-gh-stub" "$STUB_BIN/gh"
chmod +x "$STUB_BIN/gh"

stub_reset() {
  rm -rf "$TMP/state"
  mkdir -p "$TMP/state"
  printf '1000\n' >"$TMP/state/counter"
  : >"$TMP/state/calls"
  local R
  R="$TMP/state/$(san "$FORK")"
  mkdir -p "$R/refs" "$R/commit" "$R/tree" "$R/blob" "$R/pulls" "$R/labels"
  printf '2026-08-09T00:00:00Z\n' >"$R/created_at"
  printf 'false\n' >"$R/archived"
  : >"$R/tags"
  : >"$R/releases"
  : >"$R/runs"
  printf 'name: release\nenv:\n  CEREMONY_SELF_REF: "0.6.3"\n' >"$R/blob/b1"
  printf 'name: labels\nenv:\n  CEREMONY_SELF_REF: "0.6.3"\n' >"$R/blob/b2"
  printf 'name: ci\non: [push]\n' >"$R/blob/b3"
  printf '%s\n' \
    ".github/workflows/ci.yml	b3" \
    ".github/workflows/labels.yml	b2" \
    ".github/workflows/release.yml	b1" >"$R/tree/t1"
  printf 't1\n' >"$R/commit/$CAND_SHA"
}

# A scratch repo carrying a caller but no fixture — the state the 0.4.0
# lesson is about, and the one the instrument must refuse to reach.
stub_reset
UNSEEDED="$SCRATCH_OWNER/unseeded"
U="$TMP/state/$(san "$UNSEEDED")"
mkdir -p "$U/refs" "$U/commit" "$U/tree" "$U/blob" "$U/pulls" "$U/labels"
printf '2026-08-09T00:00:00Z\n' >"$U/created_at"
printf 'false\n' >"$U/archived"
: >"$U/tags"
: >"$U/releases"
: >"$U/runs"
printf 'placeholder\n' >"$U/blob/b9"
printf 'README.md\tb9\n' >"$U/tree/t9"
printf 't9\n' >"$U/commit/s9"
printf 's9\n' >"$U/refs/heads_main"

ordering_probe() {
  ( # shellcheck disable=SC2030 # each probe is a subshell on purpose
    export PATH="$STUB_BIN:$PATH" DRILL_STUB_STATE="$TMP/state"
    export DRILL_STUB_SCENARIO="$TMP/scenario"
    : >"$TMP/scenario"
    caller_install "$1" main "$TMP/caller-stage" "$FORK" "$FORK_REF" "$TMP"
  )
}
mkdir -p "$TMP/caller-stage"
# ---------------------------------------------------------------------------
# "Verbatim but for the pin" is the caller stub's whole claim, so it is
# measured against docs/CONSUMERS.md rather than asserted in a comment: the
# doc's fenced block with its `uses:` line swapped for the fork pin is
# byte-for-byte what the drill installs. Round 1 caught the stub quietly
# dropping the block's trailing `# or: package-json`, found by diffing the two
# by hand — which is the work this case exists to stop repeating.
# ---------------------------------------------------------------------------
caller_write "$TMP/stub" "$FORK" "$FORK_REF"
awk '/^```yaml$/ { inblock = 1; next } /^```$/ { if (inblock) exit } inblock' \
  "$ROOT/docs/CONSUMERS.md" |
  sed "s#^    uses: heavy-duty/ceremony/.github/workflows/release.yml@<pinned-tag>\$#    uses: $FORK/.github/workflows/release.yml@$FORK_REF#" \
    >"$TMP/caller.expected"
check "the caller stub is CONSUMERS.md's block, verbatim but for the pin" 0 "" \
  diff -u "$TMP/caller.expected" "$TMP/stub/.github/workflows/release.yml"

check "the caller refuses to land on a tree with no armed fixture" 1 \
  "is missing the armed fixture: VERSION" ordering_probe "$UNSEEDED"
check "the refusal names the lesson it enforces" 1 "the 0.4.0 setup lesson" \
  ordering_probe "$UNSEEDED"

# ---------------------------------------------------------------------------
# End to end: the six probes in doctrine order against the stub, a full green
# sequence, and the record it emits.
# ---------------------------------------------------------------------------
run_rehearsal() { # <scenario-file> [extra args…]
  local scenario="$1"
  shift
  (
    # shellcheck disable=SC2031 # the ordering probe's subshell is unrelated
    export PATH="$STUB_BIN:$PATH" DRILL_STUB_STATE="$TMP/state"
    export DRILL_STUB_SCENARIO="$scenario" DRILL_RUN_POLL_SECONDS=0 DRILL_RUN_TRIES=3
    cd "$ROOT" || exit 1
    ./drill/rehearsal.sh --owner "$SCRATCH_OWNER" --version 0.7.0 \
      --fork-ref "$FORK@$FORK_REF" --candidate-sha "$CAND_SHA" \
      --candidate-ref build/313-drill-rehearsal --date 2026-08-09 "$@"
  )
}

green_scenario() {
  printf '%s\n' \
    "success	none" \
    "success	release:0.7.0,rearm:0.7.1-dev" \
    "success	none" \
    "failure	none" \
    "success	none" \
    "failure	none" \
    "success	release:0.7.1" \
    "failure	none" >"$1"
}

stub_reset
green_scenario "$TMP/green.scenario"
green_out="$(run_rehearsal "$TMP/green.scenario" --out "$TMP/emitted.md" 2>&1)"
green_rc=$?
check "the rehearsal runs end to end and exits 0" 0 "" test "$green_rc" -eq 0
check "the run reports six probes passed" 0 "probes passed 6/6, failed 0" \
  printf '%s\n' "$green_out"
check "the emitted record passes the shape check" 0 "six probe rows" \
  record_check "$TMP/emitted.md"
check "every probe row is a pass" 0 "6" \
  bash -c 'grep -cE "^\| [1-6] \|.*✅" "$1"' _ "$TMP/emitted.md"
check "no probe row is a failure" 1 "" grep -qE '^\| [1-6] \|.*❌' "$TMP/emitted.md"
check "the record names the scratch repo by full owner/name" 0 "$SCRATCH" \
  cat "$TMP/emitted.md"
check "the record names the fork ref and the rewritten pin" 0 \
  "$FORK/.github/workflows/release.yml@$FORK_REF" cat "$TMP/emitted.md"
check "the record names the canonical candidate SHA as the rewritten pin" 0 \
  "the rewritten pin \`$CAND_SHA\`" cat "$TMP/emitted.md"
check "the record states the disposal as observed, archived and pending" 0 \
  "archived=true private=true" cat "$TMP/emitted.md"
check "the probes ran in doctrine order" 0 $'1\n2\n3\n4\n5\n6' \
  bash -c 'awk -F"|" "/^\\| [1-6] \\|/ { gsub(/ /, \"\", \$2); print \$2 }" "$1"' \
  _ "$TMP/emitted.md"
check "the baseline caller run is recorded as setup, not as a probe" 0 \
  "the green baseline no-op" cat "$TMP/emitted.md"
check "probe 3's re-arm is recorded as setup too" 0 \
  "re-arming main to" cat "$TMP/emitted.md"

# The empty-repo bootstrap: a freshly created repository refuses the git data
# API with a 409, so the first file goes through the contents endpoint and
# every later commit rides a tree. The live shakedown found this the hard way.
check "the first file lands through the contents endpoint" 0 "" \
  grep -qF "api repos/$SCRATCH/contents/VERSION --method PUT --input -" "$TMP/state/calls"
check "the bootstrap precedes the first tree write" 0 "" bash -c '
  seed=$(grep -n "contents/VERSION --method PUT" "$1" | head -n1 | cut -d: -f1)
  tree=$(grep -n "git/trees --input" "$1" | head -n1 | cut -d: -f1)
  [ -n "$seed" ] && [ -n "$tree" ] && [ "$seed" -lt "$tree" ]' _ "$TMP/state/calls"

# The delete endpoint is never in the call log — the assertion D4 exists for.
check "the drill archived the scratch repo" 0 "" \
  grep -qF "api repos/$SCRATCH --method PATCH --input -" "$TMP/state/calls"
check "the drill never called repo delete" 1 "" \
  grep -qE "repo delete|DELETE repos/$SCRATCH\$" "$TMP/state/calls"
check "the drill never deleted any repository" 1 "" \
  grep -qE "^api (-X|--method) DELETE repos/[^/]+/[^/]+$" "$TMP/state/calls"
check "the operator's delete step is printed, not run" 0 \
  "gh api -X DELETE repos/$SCRATCH" printf '%s\n' "$green_out"
check "the caller landed after the fixture, never before" 0 "" bash -c '
  fixture=$(grep -n "the armed fixture at" "$1" | head -n1 | cut -d: -f1)
  caller=$(grep -n "install the docs/CONSUMERS.md release caller" "$1" | head -n1 | cut -d: -f1)
  [ -n "$fixture" ] && [ -n "$caller" ] && [ "$fixture" -lt "$caller" ]' \
  _ "$TMP/state/$(san "$SCRATCH")/messages"

# ---------------------------------------------------------------------------
# A refusal probe whose after-count grew: the probe reds and the record says
# so, and the run still ends with a record rather than half a table.
# ---------------------------------------------------------------------------
stub_reset
green_scenario "$TMP/leaky.scenario"
# Probe 3's refusal leaves a tag behind — exactly the shape drills/README
# calls a failed probe.
awk 'NR == 4 { print "failure\ttag:0.7.1-leak"; next } { print }' \
  "$TMP/leaky.scenario" >"$TMP/leaky.tmp" && mv "$TMP/leaky.tmp" "$TMP/leaky.scenario"
leaky_out="$(run_rehearsal "$TMP/leaky.scenario" --out "$TMP/leaky.md" 2>&1)"
check "a refusal that created a tag reds its probe" 0 "probes passed 5/6, failed 1" \
  printf '%s\n' "$leaky_out"
check "the record says which probe failed and how" 0 "tags moved 1→2, expected a delta of 0" \
  bash -c 'awk -F"|" "/^\\| 3 \\|/ { print }" "$1"' _ "$TMP/leaky.md"
check "the failed probe's row carries the failure mark" 0 "❌" \
  bash -c 'awk "/^\\| 3 \\|/" "$1"' _ "$TMP/leaky.md"
check "a failed drill is still a record" 0 "six probe rows" record_check "$TMP/leaky.md"
check "a failed drill still says so at the top" 0 "1 probe(s) failed" cat "$TMP/leaky.md"
check "a failed drill still archives the scratch repo" 0 "" \
  grep -qF "api repos/$SCRATCH --method PATCH --input -" "$TMP/state/calls"

# ---------------------------------------------------------------------------
# A probe that aborts on infrastructure rather than on a door verdict. The
# realistic shape is `scratch_run_for` exhausting its polls on a run that
# never completes, which the stub reaches by running out of scenario: no run
# is fired at that head at all. Called bare under `set -e` this aborted the
# script before the archive and the record, and the EXIT trap took
# `probes.tsv` with it — an unarchived scratch repo and no record, under a
# header comment promising the record either way (round 1).
# ---------------------------------------------------------------------------
stub_reset
green_scenario "$TMP/aborted.scenario"
head -n 7 "$TMP/aborted.scenario" >"$TMP/aborted.tmp" &&
  mv "$TMP/aborted.tmp" "$TMP/aborted.scenario"
aborted_out="$(run_rehearsal "$TMP/aborted.scenario" --out "$TMP/aborted.md" 2>&1)"
aborted_rc=$?
check "an aborted probe does not abort the rehearsal" 0 "" test "$aborted_rc" -eq 0
check "the aborted probe is reported as the one failure" 0 "probes passed 5/6, failed 1" \
  printf '%s\n' "$aborted_out"
check "the record exists at all after an abort" 0 "" test -s "$TMP/aborted.md"
check "the aborted probe's row says it aborted" 0 "❌ aborted before it reached a verdict" \
  bash -c 'awk "/^\\| 6 \\|/" "$1"' _ "$TMP/aborted.md"
check "the aborted probe's row links no run it never had" 0 "| — |" \
  bash -c 'awk "/^\\| 6 \\|/" "$1"' _ "$TMP/aborted.md"
check "the record after an abort still passes the shape check" 0 "six probe rows" \
  record_check "$TMP/aborted.md"
check "the aborted probe establishes nothing in the conclusion" 1 "" \
  grep -qF 'refused a mismatched tag before creating anything' "$TMP/aborted.md"
check "the probes before the abort still stand" 0 \
  "✅ The tag door published from a matching manual tag without touching main." \
  cat "$TMP/aborted.md"
check "an aborted probe still archives the scratch repo" 0 "" \
  grep -qF "api repos/$SCRATCH --method PATCH --input -" "$TMP/state/calls"

# ---------------------------------------------------------------------------
# The canonical-repo guard reds before anything is created anywhere.
# ---------------------------------------------------------------------------
stub_reset
: >"$TMP/empty.scenario"
canonical_out="$( (
  export PATH="$STUB_BIN:$PATH" DRILL_STUB_STATE="$TMP/state"
  export DRILL_STUB_SCENARIO="$TMP/empty.scenario"
  cd "$ROOT" || exit 1
  ./drill/rehearsal.sh --owner "$SCRATCH_OWNER" --version 0.7.0 \
    --fork-ref heavy-duty/ceremony@0.7.0 --candidate-sha "$CAND_SHA" 2>&1
) )"
canonical_rc=$?
check "pointing the stub source at the canonical repo for a tag-named ref reds" 0 "" \
  test "$canonical_rc" -eq 1
check "the canonical-repo refusal names the shadow-tag rule" 0 "0.1.0 shadow-tag rule" \
  printf '%s\n' "$canonical_out"
check "the canonical-repo refusal creates no scratch repo" 1 "" \
  grep -q "repo create" "$TMP/state/calls"

# ---------------------------------------------------------------------------
# Argument refusals: the CLI is a door too.
# ---------------------------------------------------------------------------
rehearsal_args() { (cd "$ROOT" && ./drill/rehearsal.sh "$@"); }
check "no arguments prints usage" 2 "usage: drill/rehearsal.sh" rehearsal_args
check "an rc version is refused — that is #321's leg" 1 "not a bare X.Y.Z" \
  rehearsal_args --owner o --version 0.7.0-rc1 --fork-ref "$FORK@$FORK_REF" \
  --candidate-sha "$CAND_SHA"
check "a fork-ref with no ref is refused" 1 "is not 'owner/repo@ref'" \
  rehearsal_args --owner o --version 0.7.0 --fork-ref forkowner/ceremony \
  --candidate-sha "$CAND_SHA"

summary
