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
# shellcheck source=drill/lib/attempt.sh
source "$ROOT/drill/lib/attempt.sh"
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
SCRATCH="$SCRATCH_OWNER/ceremony-drill-0.7.0-1"

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
# D2, and #313 D7's discipline behind it: the procedure text in
# drills/README.md IS the script's specification, so "byte-faithful" is a
# diff here rather than a claim anybody has to eyeball (#321).
awk '/^4\. Exercise both doors, one probe at a time:$/ { on = 1; next }
     on && /^   Every refusal must refuse/ { exit }
     on && NF { print }' "$ROOT/drills/README.md" >"$TMP/doctrine.list"
awk '/^# The list is drills\/README\.md/ { on = 1; next }
     on && /^# Every probe reads/ { exit }
     on && /^#[[:space:]]/ { sub(/^#/, ""); print }' \
  "$ROOT/drill/lib/probes.sh" >"$TMP/probes.list"
check "the instrument's probe list is the doctrine's, byte-faithful" 0 "" \
  diff -u "$TMP/doctrine.list" "$TMP/probes.list"
check "and it is not an empty comparison" 0 "8" \
  bash -c 'grep -c "^   [1-8]\." "$1"' _ "$TMP/doctrine.list"

check "the probe names are the doctrine's eight" 0 "" \
  test "$(probe_name 4)" = "re-run of the completed ceremony"
check "the rc cut is the seventh probe, in doctrine order" 0 "" \
  test "$(probe_name 7)" = "rc cut, tag-only and marked prerelease"
check "the promotion is the eighth" 0 "" \
  test "$(probe_name 8)" = "promotion of the rc to the final version"
check "the doctrine list is what the record counts" 0 "8" \
  printf '%s\n' "$DRILL_PROBE_COUNT"

# The rc legs' second measurement: a release's prerelease flag. A tag nobody
# published answers with a refusal rather than an empty string, for the reason
# `probe_counts` refuses a count that did not read.
check "a published prerelease reads as true" 0 "true" \
  bash -c 'source "$1/drill/lib/scratch.sh"
    drill_gh() { printf "%s\t%s\n" 0.7.2-rc1 true; }
    scratch_release_prerelease some/repo 0.7.2-rc1' _ "$ROOT"
check "a full release reads as false" 0 "false" \
  bash -c 'source "$1/drill/lib/scratch.sh"
    drill_gh() { printf "%s\t%s\n" 0.7.2 false; }
    scratch_release_prerelease some/repo 0.7.2' _ "$ROOT"
check "a flag nobody published is refused, never taken for false" 1 \
  "no release tagged '0.7.2-rc1' at some/repo answered with a prerelease flag" \
  bash -c 'source "$1/drill/lib/scratch.sh"
    drill_gh() { printf "%s\t%s\n" 0.7.2 false; }
    scratch_release_prerelease some/repo 0.7.2-rc1' _ "$ROOT"

# The promotion compares the stamped section against the assembled body, and
# only the separator between a section and the next heading differs by shape.
printf '%s\n' '- one' '' '- two' '' '' >"$TMP/trim.in"
check "trailing blanks are dropped, inner ones are content" 0 $'- one\n\n- two' \
  probe_trim_blank "$TMP/trim.in"

# ---------------------------------------------------------------------------
# The record's shape check — the script runs it on its own emission, because
# the script is now the record's only author and nothing else will notice.
# ---------------------------------------------------------------------------
record_fixture() { # <run-cell-for-probe-3> [preamble] [result-cell-for-probe-3]
  local three="$1"
  local preamble="${2:-All eight probes ran; every row was written from its own run.}"
  local three_result="${3:-✅ ok}"
  cat <<EOF
# 0.7.0 — drill record

$preamble

Both doors ran live against the 0.7.0 candidate's own machinery.

| # | probe | run | tags | releases | result |
|---|---|---|---|---|---|
| 1 | merge-door ceremony | [1001](https://github.com/o/n/actions/runs/1001) | 0 → 1 | 0 → 1 | ✅ ok |
| 2 | mislabeled ordinary PR | [1002](https://github.com/o/n/actions/runs/1002) | 1 → 1 | 1 → 1 | ✅ ok |
| 3 | bare-version PR | $three | 1 → 1 | 1 → 1 | $three_result |
| 4 | re-run of the completed ceremony | [1004](https://github.com/o/n/actions/runs/1004) | 1 → 1 | 1 → 1 | ✅ ok |
| 5 | tag-door release from a manual tag | [1005](https://github.com/o/n/actions/runs/1005) | 1 → 2 | 1 → 2 | ✅ ok |
| 6 | mismatched tag | [1006](https://github.com/o/n/actions/runs/1006) | 2 → 2 | 2 → 2 | ✅ ok |
| 7 | rc cut, tag-only and marked prerelease | [1007](https://github.com/o/n/actions/runs/1007) | 2 → 3 | 2 → 3 | ✅ ok |
| 8 | promotion of the rc to the final version | [1008](https://github.com/o/n/actions/runs/1008) | 3 → 4 | 3 → 4 | ✅ ok |

The rc cut's ceremony PR carries \`drills/0.7.2-rc1.md\`.

## What the rehearsal establishes

- ✅ one
- ✅ two
- ✅ three
- ✅ four
- ✅ five
- ✅ six
- ✅ seven
- ✅ eight

It is **pending the operator's delete**.

## Known gaps

None declared: every claim this record makes is a probe row's, and nothing was
declared outside them.
EOF
}
record_fixture "[1003](https://github.com/o/n/actions/runs/1003)" >"$TMP/record-good.md"
record_fixture "run 3, by hand" >"$TMP/record-no-run.md"
check "a whole record passes the shape check" 0 "eight probe rows" \
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
ABORTED_PREAMBLE='**1 of the eight probes never reached a run** (probe 3): that row is written
from the abort itself.'
record_fixture "—" "$ABORTED_PREAMBLE" "❌ aborted before it reached a verdict" \
  >"$TMP/record-aborted.md"
check "a probe that aborted before any run is the one row exempt" 0 \
  "eight probe rows" record_check "$TMP/record-aborted.md"
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
  printf 'rc_version\t0.7.2\n'
  printf 'scratch\t%s\n' "$SCRATCH"
  printf 'attempt\t1\n'
  printf 'created\t2026-08-09T00:00:00Z\n'
  printf 'private\tfalse\n'
  printf 'candidate_sha\t%s\n' "$CAND_SHA"
  printf 'candidate_ref\tbuild/313-drill-rehearsal\n'
  printf 'fork_repo\t%s\n' "$FORK"
  printf 'fork_ref\t%s\n' "$FORK_REF"
  printf 'fork_head\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
  printf 'pin\t%s\n' "$CAND_SHA"
  printf 'disposal\tthe repository is **archived** — a fresh read afterwards reported `archived=true private=false`\n'
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
  printf '7\trc cut, tag-only and marked prerelease\t1007\t1\tPASS\t2\t3\t2\t3\tpublished as a prerelease, changelog byte-identical\n'
  printf '8\tpromotion of the rc to the final version\t1008\t1\tPASS\t3\t4\t3\t4\tthe assembled section stamped, the candidate still a prerelease\n'
} >"$TMP/probes.tsv"
printf '1000\tsuccess\tthe caller landing on an armed tree\n' >"$TMP/setup.tsv"
record_render "$TMP/ctx.tsv" "$TMP/probes.tsv" "$TMP/setup.tsv" >"$TMP/rendered.md"
check "the rendered record matches its golden shape" 0 "" \
  diff -u "$ROOT/test/fixtures/drill-record.golden.md" "$TMP/rendered.md"
check "the rendered record passes its own shape check" 0 "eight probe rows" \
  record_check "$TMP/rendered.md"
# "Removing either probe reds the golden-shape check" — both halves of it:
# the emission stops matching the golden, and the shape check names the row
# that went missing rather than passing a seven-row table.
for leg in 7 8; do
  grep -v "^$leg	" "$TMP/probes.tsv" >"$TMP/without-$leg.tsv"
  record_render "$TMP/ctx.tsv" "$TMP/without-$leg.tsv" "$TMP/setup.tsv" >"$TMP/without-$leg.md"
  check "a record missing probe $leg no longer matches the golden shape" 1 "" \
    diff -q "$ROOT/test/fixtures/drill-record.golden.md" "$TMP/without-$leg.md"
  check "a record missing probe $leg reds the shape check" 1 "probe $leg has no row" \
    record_check "$TMP/without-$leg.md"
done
check "the rendered record names the rc version's own record path" 0 \
  "drills/0.7.2-rc1.md" cat "$TMP/rendered.md"
grep -vF 'drills/0.7.2-rc1.md' "$TMP/rendered.md" >"$TMP/record-no-rc-path.md"
check "a record that never names it reds the shape check" 1 \
  "does not name the rc version's own record path" \
  record_check "$TMP/record-no-rc-path.md"

check "probe 4's re-run is recorded as a later attempt of the same run" 0 \
  "actions/runs/1001) (attempt 2)" cat "$TMP/rendered.md"
check "a failed probe is recorded as failed, not smoothed over" 0 "1 probe(s) failed" \
  bash -c 'sed "s/\tPASS\t1\t1\t1\t1\trefused at decide/\tFAIL\t1\t2\t1\t1\ttags moved 1→2/" "$2" >"$4/failed.tsv"
    source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_render "$3" "$4/failed.tsv" "$4/setup.tsv"' \
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
  "Not established: 2 of the eight" cat "$TMP/two-failed.md"
check "the clean-run closing sentence is not on a failed record" 1 "" \
  grep -qF 'Every refusal claim above is asserted' "$TMP/two-failed.md"
check "a two-failure record still passes the shape check" 0 "eight probe rows" \
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
  "the conclusion has 6 probe lines, expected 8" \
  record_check "$TMP/record-short-claims.md"

# ---------------------------------------------------------------------------
# The preamble is a claim about the runs, so it is measured like one (round
# 2). `All six probes ran; every row … was written from its own run` was
# unconditional, and the abort guard from round 1 is what made it false: an
# aborted row carries `—` for its run and says so, under a header asserting
# otherwise. The record's own success line had the same shape — it announced
# six run IDs one line after excusing a row that had none.
# ---------------------------------------------------------------------------
check "a clean run's preamble still claims all six ran" 0 "" \
  grep -qF 'All eight probes ran' "$TMP/rendered.md"
sed 's/\t1006\t1\tPASS\t2\t2\t2\t2\trefused before publication/\t—\t1\tFAIL\t2\t2\t2\t2\taborted before it reached a verdict (exit 1)/' \
  "$TMP/probes.tsv" >"$TMP/one-aborted.tsv"
record_render "$TMP/ctx.tsv" "$TMP/one-aborted.tsv" "$TMP/setup.tsv" >"$TMP/one-aborted.md"
check "an aborted probe withdraws the preamble's claim that all six ran" 1 "" \
  grep -qF 'All eight probes ran' "$TMP/one-aborted.md"
check "the preamble counts the probes that never reached a run" 0 \
  "**1 of the eight probes never reached a run** (probe 6)" \
  cat "$TMP/one-aborted.md"
check "the preamble still stands behind the rows that did run" 0 \
  "Every other row in the table was written" cat "$TMP/one-aborted.md"
check "an aborted record still passes the shape check" 0 "eight probe rows" \
  record_check "$TMP/one-aborted.md"
record_check "$TMP/one-aborted.md" >"$TMP/one-aborted.check"
check "the shape check stops claiming a run ID for the row it excused" 1 "" \
  grep -qF 'each with a run ID' "$TMP/one-aborted.check"
check "the shape check says how many rows it excused" 0 \
  "1 aborted before reaching a run" record_check "$TMP/one-aborted.md"
check "a clean record's shape check does claim a run ID for every row" 0 \
  "each with a run ID and its before/after counts" record_check "$TMP/rendered.md"
# Two aborts are named individually: a reader who has to go and look wants
# the numbers, not the count.
sed -e 's/\t1003\t1\tPASS\t1\t1\t1\t1\trefused at decide/\t—\t1\tFAIL\t1\t1\t1\t1\taborted before it reached a verdict (exit 1)/' \
  -e 's/\t1006\t1\tPASS\t2\t2\t2\t2\trefused before publication/\t—\t1\tFAIL\t2\t2\t2\t2\taborted before it reached a verdict (exit 1)/' \
  "$TMP/probes.tsv" >"$TMP/two-aborted.tsv"
check "two aborted probes are both named in the preamble" 0 \
  "**2 of the eight probes never reached a run** (probe 3, 6)" \
  record_render "$TMP/ctx.tsv" "$TMP/two-aborted.tsv" "$TMP/setup.tsv"
# `unestablished` is a subtraction, and a duplicated row would have rendered
# it negative. The shape check's row count catches that before the emission
# ships; the arithmetic does not lean on it.
{
  cat "$TMP/probes.tsv"
  head -n 1 "$TMP/probes.tsv"
} >"$TMP/nine.tsv"
record_render "$TMP/ctx.tsv" "$TMP/nine.tsv" "$TMP/setup.tsv" >"$TMP/nine.md"
check "a duplicated probe row never renders a negative count" 1 "" \
  grep -qE 'Not established: -' "$TMP/nine.md"
check "the duplicated row is still what reds the shape check" 1 \
  "the probe table has 9 rows, expected 8" record_check "$TMP/nine.md"

# ---------------------------------------------------------------------------
# Round 2 measured the top preamble and stopped there, and two sentences below
# it went on asserting the same execution in different words: the probe
# table's `each written from its own run`, and the conclusion's `Both doors
# ran live` (@codex-bot-andresmgsl, round 3). The first was already false in
# the fixture right above — an aborted row sat dashed under it. The second is
# false whenever every probe of one door misses its run. Both are measured
# now, and both are graded by the shape check so they cannot come back.
# ---------------------------------------------------------------------------
abort_probes() { # <merge|tag|all> — that door's probes never reached a run
  # The rc legs are the merge door's: 5 and 6 are the tag door's, and every
  # other probe is a labeled ceremony PR merging to main (#321).
  awk -F'\t' -v OFS='\t' -v door="$1" \
    '(door == "all") || (door == "tag" && ($1 == 5 || $1 == 6)) ||
     (door == "merge" && ($1 <= 4 || $1 >= 7)) {
       $3 = "—"; $4 = 1; $5 = "FAIL"
       $10 = "aborted before it reached a verdict (exit 1)"
     } { print }' "$TMP/probes.tsv"
}

# The probe table's own preamble.
check "a clean run's probe table says every row came from its own run" 0 \
  "in doctrine order, each written from its own run" cat "$TMP/rendered.md"
check "an aborted row withdraws the probe table's every-row claim" 1 "" \
  grep -qF 'in doctrine order, each written from its own run' "$TMP/one-aborted.md"
check "the probe table names the rows written from the abort instead" 0 \
  "1 of them (probe 6) never reached a" cat "$TMP/one-aborted.md"
check "the probe table still stands behind the rows that did run" 0 \
  "every other row was written from its own run" cat "$TMP/one-aborted.md"
check "two aborted rows are both named in the probe table" 0 \
  "2 of them (probe 3, 6) never reached a" \
  record_render "$TMP/ctx.tsv" "$TMP/two-aborted.tsv" "$TMP/setup.tsv"

# The conclusion's door sentence, in all four states the rows can measure.
# 1–4 are the merge door, 5–6 the tag door, and a door ran iff one of its
# probes reached a run.
abort_probes tag >"$TMP/tag-aborted.tsv"
abort_probes merge >"$TMP/merge-aborted.tsv"
abort_probes all >"$TMP/all-aborted.tsv"
record_render "$TMP/ctx.tsv" "$TMP/tag-aborted.tsv" "$TMP/setup.tsv" >"$TMP/tag-aborted.md"
record_render "$TMP/ctx.tsv" "$TMP/merge-aborted.tsv" "$TMP/setup.tsv" >"$TMP/merge-aborted.md"
record_render "$TMP/ctx.tsv" "$TMP/all-aborted.tsv" "$TMP/setup.tsv" >"$TMP/all-aborted.md"
check "both doors ran is still what a clean record says" 0 \
  "Both doors ran live against the 0.7.0 candidate's own machinery" cat "$TMP/rendered.md"
check "one aborted probe does not cost its door the claim" 0 \
  "Both doors ran live against the 0.7.0 candidate's own machinery" \
  cat "$TMP/one-aborted.md"
check "a door whose every probe aborted is not said to have run" 1 "" \
  grep -qF 'Both doors ran live' "$TMP/tag-aborted.md"
check "the door that did run is still claimed" 0 \
  "The merge door ran live against the 0.7.0 candidate's own machinery" \
  cat "$TMP/tag-aborted.md"
check "the door that did not run is stated as no evidence" 0 \
  "this record is no evidence about that door either way" cat "$TMP/tag-aborted.md"
check "the unrun door names the probes that never got a run" 0 \
  "(probes 5, 6 never got one)" cat "$TMP/tag-aborted.md"
check "the same holds with the doors the other way round" 0 \
  "The tag door ran live against the 0.7.0 candidate's own machinery" \
  cat "$TMP/merge-aborted.md"
check "the unrun merge door names all six of its probes" 0 \
  "(probes 1, 2, 3, 4, 7, 8 never got one)" cat "$TMP/merge-aborted.md"
check "a record where nothing ran claims neither door" 0 \
  "**Neither door reached a run at all**" cat "$TMP/all-aborted.md"
check "a record where nothing ran claims no door ran live" 1 "" \
  grep -qF 'ran live against the' "$TMP/all-aborted.md"
check "a record where nothing ran establishes nothing" 0 \
  "Not established: 8 of the eight" cat "$TMP/all-aborted.md"

# The shape check grades both sentences, so a renderer that stopped measuring
# them — or a hand-touched record — reds rather than shipping.
check "a record with a whole door unrun still passes the shape check" 0 \
  "2 aborted before reaching a run and carry the aborted mark" \
  record_check "$TMP/tag-aborted.md"
check "a record where nothing ran at all is still a valid record" 0 \
  "8 aborted before reaching a run and carry the aborted mark" \
  record_check "$TMP/all-aborted.md"
check "the excused-row count agrees in number at one row" 0 \
  "1 aborted before reaching a run and carries the aborted mark" \
  record_check "$TMP/one-aborted.md"
record_fixture "[1003](https://github.com/o/n/actions/runs/1003)" \
  '**2 of the eight probes never reached a run** (probe 5, 6): those rows are
written from the abort itself.' |
  sed -e 's#\[1005\](https://github.com/o/n/actions/runs/1005)#—#' \
    -e 's#\[1006\](https://github.com/o/n/actions/runs/1006)#—#' \
    -e '/| — |/ s/| ✅ ok |/| ❌ aborted before it reached a verdict |/' \
    >"$TMP/record-door-lie.md"
check "a record claiming both doors ran when a whole door aborted reds" 1 \
  "the rows measure merge-door-ran=1 tag-door-ran=0, but the conclusion does not say so" \
  record_check "$TMP/record-door-lie.md"
record_fixture "—" "All eight probes ran; every row was written from its own run." \
  "❌ aborted before it reached a verdict" >"$TMP/record-preamble-lie.md"
check "a preamble that undercounts the rows that never ran reds" 1 \
  "the preamble says 0 probe(s) never reached a run, the table shows 1" \
  record_check "$TMP/record-preamble-lie.md"
grep -vF 'All eight probes ran' "$TMP/record-good.md" >"$TMP/record-no-preamble.md"
check "a record with no preamble at all reds" 1 \
  "record's preamble does not say how many probes reached a run" \
  record_check "$TMP/record-no-preamble.md"
record_fixture "—" "$ABORTED_PREAMBLE" "❌ aborted before it reached a verdict" |
  sed 's/^Both doors ran live.*/One row per probe, in doctrine order, each written from its own run. Both doors ran live against the 0.7.0 candidate./' \
    >"$TMP/record-table-lie.md"
check "an aborted record keeping the every-row claim reds" 1 \
  "1 row(s) reached no run, but the probe table says every row was written from its own run" \
  record_check "$TMP/record-table-lie.md"

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

# The stub's fault rules (#369), cleared by every reset so no case inherits
# another's. One rule per line: `skip<TAB>times<TAB>glob<TAB>status<TAB>msg`.
FAULTS="$TMP/faults"
faults() {
  local rule
  : >"$FAULTS"
  for rule in "$@"; do printf '%s\n' "$rule" >>"$FAULTS"; done
}

stub_reset() {
  faults
  rm -rf "$TMP/state"
  mkdir -p "$TMP/state"
  printf '1000\n' >"$TMP/state/counter"
  : >"$TMP/state/calls"
  local R
  R="$TMP/state/$(san "$FORK")"
  mkdir -p "$R/refs" "$R/commit" "$R/tree" "$R/blob" "$R/pulls" "$R/labels"
  printf '2026-08-09T00:00:00Z\n' >"$R/created_at"
  printf 'false\n' >"$R/archived"
  printf 'true\n' >"$R/private"
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
printf 'true\n' >"$U/private"
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
    export DRILL_STUB_SCENARIO="$TMP/scenario" DRILL_STUB_FAULTS="$FAULTS"
    export DRILL_READ_NAP_SECONDS=0
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
#
# The block is found by its OWN heading sentence, not by being the first
# unindented ```yaml fence in the file: #395 added a fenced example earlier
# in the doc and this case started diffing the release caller against a
# guard's `with:` block. An oracle that moves when an unrelated paragraph
# lands is not measuring what its comment says it measures.
# ---------------------------------------------------------------------------
caller_write "$TMP/stub" "$FORK" "$FORK_REF"
awk '/^The consumer.s \*\*entire\*\* `release\.yml`:$/ { armed = 1; next }
     armed && /^```yaml$/ { inblock = 1; next }
     /^```$/ { if (inblock) exit }
     inblock' \
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
# End to end: the eight probes in doctrine order against the stub, a full green
# sequence, and the record it emits.
# ---------------------------------------------------------------------------
run_rehearsal() { # <scenario-file> [extra args…]
  local scenario="$1"
  shift
  (
    # shellcheck disable=SC2031 # the ordering probe's subshell is unrelated
    export PATH="$STUB_BIN:$PATH" DRILL_STUB_STATE="$TMP/state"
    export DRILL_STUB_SCENARIO="$scenario" DRILL_RUN_POLL_SECONDS=0 DRILL_RUN_TRIES=3
    # The read retry runs at its default try count and no nap: the suite
    # exercises the retries themselves, and only the sleeping is skipped.
    export DRILL_STUB_FAULTS="$FAULTS" DRILL_READ_NAP_SECONDS=0
    cd "$ROOT" || exit 1
    ./drill/rehearsal.sh --owner "$SCRATCH_OWNER" --version 0.7.0 \
      --fork-ref "$FORK@$FORK_REF" --candidate-sha "$CAND_SHA" \
      --candidate-ref build/313-drill-rehearsal --date 2026-08-09 "$@"
  )
}

# One line per door event, in the order the rehearsal fires them: the caller
# landing, probes 1–3, probe 3's re-arm, probe 4's re-run, probes 5–6, then
# the rc legs — probe 7's arming commit, its rc cut, and probe 8's promotion.
green_scenario() {
  printf '%s\n' \
    "success	none" \
    "success	release:0.7.0,rearm:0.7.1-dev" \
    "success	none" \
    "failure	none" \
    "success	none" \
    "failure	none" \
    "success	release:0.7.1" \
    "failure	none" \
    "success	none" \
    "success	prerelease:0.7.2-rc1,rearm:0.7.2-rc2-dev" \
    "success	release:0.7.2,rearm:0.7.3-dev" >"$1"
}

seed_taken_repo() { # <owner/name> — enough state for createRepository to collide
  local repo="$1" R
  R="$TMP/state/$(san "$repo")"
  mkdir -p "$R/refs" "$R/commit" "$R/tree" "$R/blob" "$R/pulls" "$R/labels"
  printf '2026-08-08T00:00:00Z\n' >"$R/created_at"
  printf 'true\n' >"$R/archived"
  printf 'true\n' >"$R/private"
  : >"$R/tags"
  : >"$R/releases"
  : >"$R/runs"
}

seed_taken_ref() { # <ref> — a burned ref on the shared fork
  printf '%s\n' "$CAND_SHA" >"$TMP/state/$(san "$FORK")/refs/$(san "heads/$1")"
}

# ---------------------------------------------------------------------------
# Attempt names (#371): creation itself claims a default name, explicit names
# never route around themselves, and one discriminator names both artifacts.
# ---------------------------------------------------------------------------
stub_reset
check "the gh stub rejects repo creation without explicit visibility" 1 \
  "required when not running interactively" \
  env DRILL_STUB_STATE="$TMP/state" "$STUB_BIN/gh" repo create "$SCRATCH"

stub_reset
green_scenario "$TMP/attempt-one.scenario"
attempt_one_out="$(run_rehearsal "$TMP/attempt-one.scenario" \
  --fork-ref "$FORK" --out "$TMP/attempt-one.md" 2>&1)"
attempt_one_rc=$?
check "the first default attempt completes" 0 "" test "$attempt_one_rc" -eq 0
check "the first default attempt creates -1" 0 "" \
  test -d "$TMP/state/$(san "$SCRATCH")"
check "the first default attempt says what it picked" 0 \
  "attempt -1 repo and fork ref are free; using -1" printf '%s\n' "$attempt_one_out"
check "the first default attempt is recorded in Where" 0 \
  'Attempt **`1`**' cat "$TMP/attempt-one.md"
check "the default creation argv omits --private" 0 "" \
  grep -qxF "repo create $SCRATCH --public" "$TMP/state/calls"
check "the default creation reports public success" 0 \
  "created public scratch repo $SCRATCH" printf '%s\n' "$attempt_one_out"
check "the default record says public" 0 \
  "disposable **public** repo" cat "$TMP/attempt-one.md"
check "the public record carries no owner-only warning" 1 "" \
  grep -qF "links resolve only for the repo owner" "$TMP/attempt-one.md"

stub_reset
green_scenario "$TMP/private.scenario"
private_out="$(run_rehearsal "$TMP/private.scenario" --private \
  --out "$TMP/private.md" 2>&1)"
private_rc=$?
check "the private opt-in completes" 0 "" test "$private_rc" -eq 0
check "the private creation argv carries --private" 0 "" \
  grep -qxF "repo create $SCRATCH --private" "$TMP/state/calls"
check "the private creation warns about unreadable links" 0 \
  "warning: created private scratch repo $SCRATCH; its record links resolve only for the repo owner" \
  printf '%s\n' "$private_out"
check "the private record says private" 0 \
  "disposable **private** repo" cat "$TMP/private.md"
check "the private record carries the owner-only sentence" 0 \
  "Because this repo is private, its run links resolve only for the repo owner." \
  cat "$TMP/private.md"
check "a free explicit fork ref costs exactly one pre-check read" 0 "" \
  bash -c 'test "$(grep -cF "git/ref/heads/$2" "$1")" -eq 3' \
  _ "$TMP/state/calls" "$FORK_REF"

stub_reset
green_scenario "$TMP/opposite-public.scenario"
DRILL_STUB_PRIVATE_OVERRIDE=true \
  run_rehearsal "$TMP/opposite-public.scenario" \
    --out "$TMP/opposite-public.md" >/dev/null 2>&1
opposite_public_rc=$?
check "an observed private repo overrides public intent" 0 "" \
  test "$opposite_public_rc" -eq 0
check "the public-intent record follows the private read-back" 0 \
  "disposable **private** repo" cat "$TMP/opposite-public.md"

stub_reset
green_scenario "$TMP/opposite-private.scenario"
DRILL_STUB_PRIVATE_OVERRIDE=false \
  run_rehearsal "$TMP/opposite-private.scenario" --private \
    --out "$TMP/opposite-private.md" >/dev/null 2>&1
opposite_private_rc=$?
check "an observed public repo overrides private intent" 0 "" \
  test "$opposite_private_rc" -eq 0
check "the private-intent record follows the public read-back" 0 \
  "disposable **public** repo" cat "$TMP/opposite-private.md"
check "the owner-only record sentence follows observation, not private intent" 1 "" \
  grep -qF "Because this repo is private" "$TMP/opposite-private.md"

stub_reset
seed_taken_repo "$SCRATCH_OWNER/ceremony-drill-0.7.0-1"
seed_taken_repo "$SCRATCH_OWNER/ceremony-drill-0.7.0-2"
green_scenario "$TMP/attempt-three.scenario"
attempt_three_out="$(run_rehearsal "$TMP/attempt-three.scenario" \
  --fork-ref "$FORK" --out "$TMP/attempt-three.md" 2>&1)"
attempt_three_rc=$?
check "two burned names route the run to -3" 0 "" test "$attempt_three_rc" -eq 0
check "the creation calls try exactly -1, -2, then -3" 0 "3" \
  bash -c 'grep -c "^repo create drillowner/ceremony-drill-0.7.0-[123] --public$" "$1"' \
  _ "$TMP/state/calls"
check "the picked repo and default fork ref share -3" 0 \
  "$FORK/.github/workflows/release.yml@drill/0.7.0-3" cat "$TMP/attempt-three.md"
check "the routed attempt is recorded as 3" 0 'Attempt **`3`**' \
  cat "$TMP/attempt-three.md"
check "the routed choice says which names were burned" 0 \
  "attempts -1 through -2 are unavailable; using -3" \
  printf '%s\n' "$attempt_three_out"

stub_reset
seed_taken_ref "drill/0.7.0-1"
green_scenario "$TMP/ref-routed.scenario"
ref_routed_out="$(run_rehearsal "$TMP/ref-routed.scenario" \
  --fork-ref "$FORK" --out "$TMP/ref-routed.md" 2>&1)"
ref_routed_rc=$?
check "a burned paired ref routes a free repo name to -2" 0 "" \
  test "$ref_routed_rc" -eq 0
check "the ref-only collision never burns the -1 repo" 1 "" \
  grep -qF "repo create $SCRATCH_OWNER/ceremony-drill-0.7.0-1" "$TMP/state/calls"
check "the ref-only collision creates the paired -2 repo" 0 "" \
  grep -qF "repo create $SCRATCH_OWNER/ceremony-drill-0.7.0-2" "$TMP/state/calls"
check "a single unavailable pair gets singular wording" 0 \
  "attempt -1 is unavailable; using -2" printf '%s\n' "$ref_routed_out"
check "the ref-routed repo and fork ref share -2" 0 \
  "$FORK/.github/workflows/release.yml@drill/0.7.0-2" \
  cat "$TMP/ref-routed.md"
check "the default path does no early extra read of its selected ref" 0 "" \
  bash -c 'test "$(grep -cF "git/ref/heads/drill/0.7.0-2" "$1")" -eq 3' \
  _ "$TMP/state/calls"

stub_reset
for taken in $(seq 1 10); do
  seed_taken_repo "$SCRATCH_OWNER/ceremony-drill-0.7.0-$taken"
done
: >"$TMP/attempt-exhausted.scenario"
attempt_exhausted_out="$(run_rehearsal "$TMP/attempt-exhausted.scenario" \
  --fork-ref "$FORK" --out "$TMP/attempt-exhausted.md" 2>&1)"
attempt_exhausted_rc=$?
check "ten burned names refuse" 0 "" test "$attempt_exhausted_rc" -ne 0
check "the bounded refusal names the whole range" 0 \
  "tried ceremony-drill-0.7.0-1 through ceremony-drill-0.7.0-10" \
  printf '%s\n' "$attempt_exhausted_out"
check "exhaustion attempts exactly ten creates" 0 "10" \
  bash -c 'grep -c "^repo create drillowner/ceremony-drill-0.7.0-[0-9][0-9]* --public$" "$1"' \
  _ "$TMP/state/calls"
check "exhaustion creates no eleventh repository" 1 "" \
  test -d "$TMP/state/$(san "$SCRATCH_OWNER/ceremony-drill-0.7.0-11")"

stub_reset
EXPLICIT="$SCRATCH_OWNER/chosen-by-hand"
seed_taken_repo "$EXPLICIT"
seed_taken_repo "$SCRATCH_OWNER/ceremony-drill-0.7.0-1"
seed_taken_ref "drill/0.7.0-2"
: >"$TMP/explicit-taken.scenario"
explicit_taken_out="$(run_rehearsal "$TMP/explicit-taken.scenario" \
  --fork-ref "$FORK" --repo-name chosen-by-hand --private \
  --candidate-ref 'build/ref with space;still-one-arg' \
  --out "$TMP/explicit taken.md" 2>&1)"
explicit_taken_rc=$?
check "an explicit taken name still refuses" 0 "" test "$explicit_taken_rc" -ne 0
check "the refusal substitutes the free repo name" 0 \
  "--repo-name ceremony-drill-0.7.0-3" printf '%s\n' "$explicit_taken_out"
check "the refusal substitutes the matching fork ref" 0 \
  "--fork-ref $FORK@drill/0.7.0-3" printf '%s\n' "$explicit_taken_out"
retry_command="$(sed -n 's/^drill: .*Retry with: //p' <<<"$explicit_taken_out")"
retry_argv="$TMP/retry.argv"
bash -c 'record_args() { printf "%s\n" "$@"; }; '"${retry_command/drill\/rehearsal.sh/record_args}" \
  >"$retry_argv"
{
  printf '%s\n' \
    --owner "$SCRATCH_OWNER" \
    --version 0.7.0 \
    --fork-ref "$FORK@drill/0.7.0-3" \
    --candidate-sha "$CAND_SHA" \
    --repo-name ceremony-drill-0.7.0-3 \
    --candidate-ref 'build/ref with space;still-one-arg' \
    --private \
    --out "$TMP/explicit taken.md" \
    --date 2026-08-09
} >"$TMP/retry.expected"
check "the printed retry invocation round-trips every argument and value" 0 "" \
  diff -u "$TMP/retry.expected" "$retry_argv"
check "the explicit-name refusal creates no suggested repo" 1 "" \
  test -d "$TMP/state/$(san "$SCRATCH_OWNER/ceremony-drill-0.7.0-3")"

stub_reset
seed_taken_repo "$EXPLICIT"
: >"$TMP/explicit-both-taken.scenario"
explicit_both_taken_out="$(run_rehearsal "$TMP/explicit-both-taken.scenario" \
  --repo-name chosen-by-hand --out "$TMP/explicit-both-taken.md" 2>&1)"
check "an explicit repo-name collision keeps its free explicit fork ref" 0 \
  "--fork-ref $FORK@$FORK_REF" printf '%s\n' "$explicit_both_taken_out"

stub_reset
green_scenario "$TMP/explicit-free.scenario"
run_rehearsal "$TMP/explicit-free.scenario" \
  --fork-ref "$FORK" --repo-name chosen-by-hand \
  --out "$TMP/explicit-free.md" >/dev/null 2>&1
explicit_free_rc=$?
check "a free explicit name is used verbatim" 0 "" test "$explicit_free_rc" -eq 0
check "an explicit free name does no numbered-name read probe" 1 "" \
  grep -q "^api repos/$SCRATCH_OWNER/ceremony-drill-0.7.0-" "$TMP/state/calls"
check "an explicit free name is created only once" 0 "1" \
  bash -c 'grep -c "^repo create drillowner/chosen-by-hand --public$" "$1"' \
  _ "$TMP/state/calls"
check "an arbitrary explicit name records a numeric attempt" 0 \
  'Attempt **`1`**' cat "$TMP/explicit-free.md"
check "an arbitrary explicit name gets the numeric default fork ref" 0 \
  "$FORK/.github/workflows/release.yml@drill/0.7.0-1" \
  cat "$TMP/explicit-free.md"

stub_reset
: >"$TMP/explicit-create-failure.scenario"
DRILL_STUB_REPO_CREATE_ERROR="GraphQL: service unavailable" \
  run_rehearsal "$TMP/explicit-create-failure.scenario" \
    --fork-ref "$FORK" --repo-name chosen-by-hand \
    --out "$TMP/explicit-create-failure.md" \
    >"$TMP/explicit-create-failure.out" 2>&1
explicit_create_failure_rc=$?
check "a non-collision explicit create failure stays non-zero" 0 "" \
  test "$explicit_create_failure_rc" -ne 0
check "an explicit create failure leaves abort evidence" 0 \
  '- **Step:** `scratch_create`' cat "$TMP/explicit-create-failure.aborted-1.md"
check "the explicit create abort records the service failure" 0 \
  "service unavailable" cat "$TMP/explicit-create-failure.aborted-1.md"
check "an explicit create abort claims no repo that was not created" 1 "" \
  grep -qF 'Scratch repo:' "$TMP/explicit-create-failure.aborted-1.md"

stub_reset
printf '%s\n' "$CAND_SHA" >"$TMP/state/$(san "$FORK")/refs/$(san "heads/$FORK_REF")"
existing_ref_out="$(
  export PATH="$STUB_BIN:$PATH" DRILL_STUB_STATE="$TMP/state"
  export DRILL_STUB_SCENARIO="$TMP/empty.scenario" DRILL_STUB_FAULTS="$FAULTS"
  export DRILL_READ_NAP_SECONDS=0
  fork_ref_prepare "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/existing-ref-work" 2>&1
)"
existing_ref_rc=$?
check "an explicit existing fork ref still refuses" 0 "" test "$existing_ref_rc" -eq 1
check "the existing-ref refusal stays byte-identical" 0 \
  "drill: refusing to prepare '$FORK@$FORK_REF' — the ref already exists at $CAND_SHA. Delete it or name another --fork-ref; the drill will not rewrite a ref it did not create." \
  printf '%s\n' "$existing_ref_out"

stub_reset
seed_taken_ref "$FORK_REF"
seed_taken_repo "$SCRATCH_OWNER/ceremony-drill-0.7.0-1"
seed_taken_ref "drill/0.7.0-2"
: >"$TMP/explicit-ref-taken.scenario"
explicit_ref_taken_out="$(run_rehearsal "$TMP/explicit-ref-taken.scenario" \
  --private --candidate-ref 'build/ref with space;still-one-arg' \
  --out "$TMP/explicit ref taken.md" 2>&1)"
explicit_ref_taken_rc=$?
check "a taken explicit fork ref refuses before setup" 0 "" \
  test "$explicit_ref_taken_rc" -ne 0
check "the early refusal uses fork_ref_prepare's byte-identical sentence" 0 \
  "drill: refusing to prepare '$FORK@$FORK_REF' — the ref already exists at $CAND_SHA. Delete it or name another --fork-ref; the drill will not rewrite a ref it did not create." \
  printf '%s\n' "$explicit_ref_taken_out"
explicit_ref_retry="$(sed -n 's/^drill: Retry with: //p' <<<"$explicit_ref_taken_out")"
bash -c 'record_args() { printf "%s\n" "$@"; }; '"${explicit_ref_retry/drill\/rehearsal.sh/record_args}" \
  >"$TMP/explicit-ref-retry.argv"
{
  printf '%s\n' \
    --owner "$SCRATCH_OWNER" \
    --version 0.7.0 \
    --fork-ref "$FORK@drill/0.7.0-3" \
    --candidate-sha "$CAND_SHA" \
    --repo-name ceremony-drill-0.7.0-3 \
    --candidate-ref 'build/ref with space;still-one-arg' \
    --private \
    --out "$TMP/explicit ref taken.md" \
    --date 2026-08-09
} >"$TMP/explicit-ref-retry.expected"
check "the explicit-ref retry round-trips every argument with both paired names" 0 "" \
  diff -u "$TMP/explicit-ref-retry.expected" "$TMP/explicit-ref-retry.argv"
check "the explicit-ref refusal creates no repository" 1 "" \
  grep -q '^repo create ' "$TMP/state/calls"
check "the explicit-ref refusal makes no fixture commit" 1 "" \
  grep -q '/contents/VERSION ' "$TMP/state/calls"
check "the explicit-ref refusal sends no archive PATCH" 1 "" \
  grep -q -- '--method PATCH --input -' "$TMP/state/calls"
check "the explicit-ref refusal writes no release record" 1 "" \
  test -e "$TMP/explicit ref taken.md"
check "the explicit-ref refusal writes no abort sibling" 1 "" \
  bash -c 'compgen -G "$1/explicit ref taken.aborted-*.md" >/dev/null' _ "$TMP"

stub_reset
: >"$TMP/explicit-ref-unreadable.scenario"
faults "0	99	GET repos/$FORK/git/ref/heads/$FORK_REF	500	fork ref read unavailable"
explicit_ref_unreadable_out="$(run_rehearsal "$TMP/explicit-ref-unreadable.scenario" \
  --out "$TMP/explicit-ref-unreadable.md" 2>&1)"
explicit_ref_unreadable_rc=$?
check "an unreadable explicit fork-ref probe refuses" 0 "" \
  test "$explicit_ref_unreadable_rc" -ne 0
check "the unreadable refusal names the read that did not answer" 0 \
  "refs/heads/$FORK_REF on $FORK did not read back after 10 attempts" \
  printf '%s\n' "$explicit_ref_unreadable_out"
check "the unreadable explicit-ref probe creates no repository" 1 "" \
  grep -q '^repo create ' "$TMP/state/calls"
check "the unreadable explicit-ref probe sends no archive PATCH" 1 "" \
  grep -q -- '--method PATCH --input -' "$TMP/state/calls"
check "the unreadable explicit-ref probe writes no abort sibling" 1 "" \
  bash -c 'compgen -G "$1/explicit-ref-unreadable.aborted-*.md" >/dev/null' _ "$TMP"

# ---------------------------------------------------------------------------
# Setup aborts are evidence, but never the release record (#370). Each case
# drives the real rehearsal against the recording stub: the wrapper must keep
# the failing command's status and message, archive only a scratch repo known
# to exist, and reserve a sibling path without overwriting an earlier attempt.
# ---------------------------------------------------------------------------
stub_reset
: >"$TMP/setup-fixture.scenario"
faults "0	99	PUT repos/$SCRATCH/contents/VERSION	500	fixture commit refused"
fixture_abort_out="$(run_rehearsal "$TMP/setup-fixture.scenario" \
  --out "$TMP/setup-fixture.md" 2>&1)"
fixture_abort_rc=$?
check "a fixture-commit abort stays non-zero" 0 "" \
  test "$fixture_abort_rc" -ne 0
check "a fixture-commit abort never writes the release record path" 1 "" \
  test -e "$TMP/setup-fixture.md"
check "the first abort takes the first-free sibling path" 0 "" \
  test -s "$TMP/setup-fixture.aborted-1.md"
check "the abort marker is the artifact's first line" 0 \
  "**Aborted in setup — no probe ran.**" \
  head -n 1 "$TMP/setup-fixture.aborted-1.md"
check "the fixture abort names its setup step" 0 "scratch_commit" \
  cat "$TMP/setup-fixture.aborted-1.md"
check "the fixture abort keeps the command's message" 0 "fixture commit refused" \
  cat "$TMP/setup-fixture.aborted-1.md"
check "the fixture abort records its scratch attempt" 0 '- Attempt: `1`' \
  cat "$TMP/setup-fixture.aborted-1.md"
check "a setup abort contains no probe verdict row" 1 "" \
  grep -qE '^\| [0-9]+ \|' "$TMP/setup-fixture.aborted-1.md"
check "an abort record cannot pass the rehearsal shape check" 1 \
  "probe table has 0 rows" record_check "$TMP/setup-fixture.aborted-1.md"
check "a fixture abort archives the scratch repo" 0 "" \
  grep -qF "api repos/$SCRATCH --method PATCH --input -" "$TMP/state/calls"
check "the abort record states the disposal it observed" 0 \
  "archived=true private=false" cat "$TMP/setup-fixture.aborted-1.md"
check "the abort output prints the operator's delete step" 0 \
  "gh api -X DELETE repos/$SCRATCH" printf '%s\n' "$fixture_abort_out"
cp "$TMP/setup-fixture.aborted-1.md" "$TMP/setup-fixture.first"

stub_reset
: >"$TMP/setup-fixture.scenario"
faults "0	99	PUT repos/$SCRATCH/contents/VERSION	500	fixture commit refused again"
second_abort_out="$(run_rehearsal "$TMP/setup-fixture.scenario" \
  --out "$TMP/setup-fixture.md" 2>&1)"
second_abort_rc=$?
check "a repeated setup abort stays non-zero" 0 "" test "$second_abort_rc" -ne 0
check "a repeated abort takes the second-free sibling path" 0 "" \
  test -s "$TMP/setup-fixture.aborted-2.md"
check "a repeated abort leaves the first artifact byte-unchanged" 0 "" \
  diff -u "$TMP/setup-fixture.first" "$TMP/setup-fixture.aborted-1.md"
check "the second artifact carries its own message" 0 "fixture commit refused again" \
  cat "$TMP/setup-fixture.aborted-2.md"
check "the second abort still prints the delete step" 0 \
  "gh api -X DELETE repos/$SCRATCH" printf '%s\n' "$second_abort_out"

stub_reset
: >"$TMP/setup-verify.scenario"
# fork_ref_prepare performs the first carrier-tree read; the second is the
# verification step whose exhausted retry this case targets.
faults "1	99	GET repos/$FORK/git/trees/*	500	fork carriers unreadable"
verify_abort_out="$(run_rehearsal "$TMP/setup-verify.scenario" \
  --out "$TMP/setup-verify.md" 2>&1)"
verify_abort_rc=$?
check "a fork-ref verification abort stays non-zero" 0 "" \
  test "$verify_abort_rc" -ne 0
check "the verification abort names its setup step" 0 "fork_ref_verify" \
  cat "$TMP/setup-verify.aborted-1.md"
check "the verification abort keeps the failed read's message" 0 \
  "fork carriers unreadable" cat "$TMP/setup-verify.aborted-1.md"
check "the verification abort archives before exiting" 0 "" \
  grep -qF "api repos/$SCRATCH --method PATCH --input -" "$TMP/state/calls"
check "the verification abort still prints the delete step" 0 \
  "gh api -X DELETE repos/$SCRATCH" printf '%s\n' "$verify_abort_out"

stub_reset
: >"$TMP/setup-baseline.scenario"
faults
baseline_abort_out="$(run_rehearsal "$TMP/setup-baseline.scenario" \
  --out "$TMP/setup-baseline.md" 2>&1)"
baseline_abort_rc=$?
check "a baseline-wait abort stays non-zero" 0 "" test "$baseline_abort_rc" -ne 0
check "the baseline abort names its setup step" 0 "baseline_run_wait" \
  cat "$TMP/setup-baseline.aborted-1.md"
check "the baseline abort keeps the wait's message" 0 \
  "scratch_run_for: no completed run" cat "$TMP/setup-baseline.aborted-1.md"
check "the baseline abort archives the scratch repo" 0 "" \
  grep -qF "api repos/$SCRATCH --method PATCH --input -" "$TMP/state/calls"
check "the baseline abort still prints the delete step" 0 \
  "gh api -X DELETE repos/$SCRATCH" printf '%s\n' "$baseline_abort_out"

stub_reset
: >"$TMP/setup-pre-scratch.scenario"
faults "0	99	GET user	500	authentication read failed"
pre_scratch_out="$(run_rehearsal "$TMP/setup-pre-scratch.scenario" \
  --out "$TMP/setup-pre-scratch.md" 2>&1)"
pre_scratch_rc=$?
check "an abort before scratch_create stays non-zero" 0 "" \
  test "$pre_scratch_rc" -ne 0
check "the pre-scratch abort names the step and message" 0 \
  "authentication read failed" cat "$TMP/setup-pre-scratch.aborted-1.md"
check "the pre-scratch abort claims no scratch repo" 1 "" \
  grep -qF 'Scratch repo:' "$TMP/setup-pre-scratch.aborted-1.md"
check "the pre-scratch abort claims no attempt that was never picked" 1 "" \
  grep -qF 'Attempt:' "$TMP/setup-pre-scratch.aborted-1.md"
check "the pre-scratch abort claims no disposal" 1 "" \
  grep -qF 'Disposal' "$TMP/setup-pre-scratch.aborted-1.md"
check "the pre-scratch abort never calls archive" 1 "" \
  grep -qF -- '--method PATCH --input -' "$TMP/state/calls"
check "the pre-scratch abort prints no delete command" 1 "" \
  grep -qF 'gh api -X DELETE' <<<"$pre_scratch_out"

stub_reset
: >"$TMP/setup-missing-parent.scenario"
faults "0\t99\tGET user\t500\tauthentication read failed"
missing_parent="$TMP/missing-parent/setup.md"
missing_parent_out="$(run_rehearsal "$TMP/setup-missing-parent.scenario" \
  --out "$missing_parent" 2>&1)"
missing_parent_rc=$?
check "an abort whose evidence parent is missing stays non-zero" 0 "" \
  test "$missing_parent_rc" -ne 0
check "an abort whose evidence cannot be reserved names the requested path" 0 \
  "drill: setup aborted in baseline_run_wait; could not reserve abort evidence beside $missing_parent" \
  printf '%s\n' "$missing_parent_out"
check "an abort never creates its missing evidence parent" 1 "" \
  test -d "${missing_parent%/*}"

stub_reset
green_scenario "$TMP/green.scenario"
green_out="$(run_rehearsal "$TMP/green.scenario" --out "$TMP/emitted.md" 2>&1)"
green_rc=$?
check "the rehearsal runs end to end and exits 0" 0 "" test "$green_rc" -eq 0
check "the run reports eight probes passed" 0 "probes passed 8/8, failed 0" \
  printf '%s\n' "$green_out"
check "the emitted record passes the shape check" 0 "eight probe rows" \
  record_check "$TMP/emitted.md"
check "a completed rehearsal creates no sibling abort artifact" 1 "" \
  bash -c 'compgen -G "$1" >/dev/null' _ "$TMP/emitted.aborted-*.md"
check "every probe row is a pass" 0 "8" \
  bash -c 'grep -cE "^\| [1-8] \|.*✅" "$1"' _ "$TMP/emitted.md"
check "no probe row is a failure" 1 "" grep -qE '^\| [1-8] \|.*❌' "$TMP/emitted.md"
check "the record names the scratch repo by full owner/name" 0 "$SCRATCH" \
  cat "$TMP/emitted.md"
check "the record names the fork ref and the rewritten pin" 0 \
  "$FORK/.github/workflows/release.yml@$FORK_REF" cat "$TMP/emitted.md"
check "the record names the canonical candidate SHA as the rewritten pin" 0 \
  "the rewritten pin \`$CAND_SHA\`" cat "$TMP/emitted.md"
check "the record states the disposal as observed, archived and pending" 0 \
  "archived=true private=false" cat "$TMP/emitted.md"
check "the probes ran in doctrine order" 0 $'1\n2\n3\n4\n5\n6\n7\n8' \
  bash -c 'awk -F"|" "/^\\| [1-8] \\|/ { gsub(/ /, \"\", \$2); print \$2 }" "$1"' \
  _ "$TMP/emitted.md"
check "the rc cut's row links the run it was written from" 0 "" \
  bash -c 'awk -F"|" "/^\\| 7 \\|/" "$1" | grep -qE "/actions/runs/[0-9]+"' \
  _ "$TMP/emitted.md"
check "the promotion's row links its own run too" 0 "" \
  bash -c 'awk -F"|" "/^\\| 8 \\|/" "$1" | grep -qE "/actions/runs/[0-9]+"' \
  _ "$TMP/emitted.md"
check "the emitted record names the rc version's record path" 0 \
  "drills/0.7.2-rc1.md" cat "$TMP/emitted.md"
check "the rc ladder's arming run is recorded as setup, not as a probe" 0 \
  "arming main at \`0.7.2-dev\` before the rc legs" cat "$TMP/emitted.md"
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
check "the emitted record keeps exactly eleven run links" 0 "11" \
  bash -c 'grep -oE "/actions/runs/[0-9]+" "$1" | wc -l | tr -d " "' \
  _ "$TMP/emitted.md"
check "the drill contains no post-create visibility flip" 1 "" \
  grep -R -n -E 'archived: false|--visibility' "$ROOT/drill"
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
check "a refusal that created a tag reds its probe" 0 "probes passed 7/8, failed 1" \
  printf '%s\n' "$leaky_out"
check "the record says which probe failed and how" 0 "tags moved 1→2, expected a delta of 0" \
  bash -c 'awk -F"|" "/^\\| 3 \\|/ { print }" "$1"' _ "$TMP/leaky.md"
check "the failed probe's row carries the failure mark" 0 "❌" \
  bash -c 'awk "/^\\| 3 \\|/" "$1"' _ "$TMP/leaky.md"
check "a failed drill is still a record" 0 "eight probe rows" record_check "$TMP/leaky.md"
check "a failed drill still says so at the top" 0 "1 probe(s) failed" cat "$TMP/leaky.md"
check "a failed drill still archives the scratch repo" 0 "" \
  grep -qF "api repos/$SCRATCH --method PATCH --input -" "$TMP/state/calls"

# ---------------------------------------------------------------------------
# The rc legs' own must-fail cases. Each assertion in probes 7 and 8 is worth
# only what it reds on, so the stub is asked to produce the states a door
# must never reach: a changelog edited by one byte across a tag-only cut, a
# fragment consumed by it, a candidate published as a full release, a tag left
# behind, and a promotion reaching back to clear its candidate's prerelease
# flag. None of these is a door behavior — that is the point of driving them
# from the scenario rather than hoping for them.
# ---------------------------------------------------------------------------
rc_scenario() { # <file> <awk-line-number> <replacement-line>
  green_scenario "$1"
  awk -v n="$2" -v line="$3" 'NR == n { print line; next } { print }' "$1" \
    >"$1.tmp" && mv "$1.tmp" "$1"
}
probe_row() { awk -F'|' -v n=" $2 " '$2 == n { print; exit }' "$1"; }
row_has() { probe_row "$1" "$2" | grep -qF -- "$3"; }
row_lacks() { ! row_has "$1" "$2" "$3"; }

stub_reset
rc_scenario "$TMP/rc-stamped.scenario" 10 \
  "success	prerelease:0.7.2-rc1,rearm:0.7.2-rc2-dev,edit:CHANGELOG.md"
rc_stamped_out="$(run_rehearsal "$TMP/rc-stamped.scenario" --out "$TMP/rc-stamped.md" 2>&1)"
check "a one-byte edit to CHANGELOG.md reds the rc cut" 0 \
  "CHANGELOG.md is not byte-identical across the rc cut" \
  probe_row "$TMP/rc-stamped.md" 7
check "the changelog claim is the comparison, not the prose beside it" 0 \
  "an rc is tag-only and stamps no section" probe_row "$TMP/rc-stamped.md" 7
check "the run reports the rc cut as the one failure" 0 "probes passed 7/8, failed 1" \
  printf '%s\n' "$rc_stamped_out"
check "the record still emits, and says which leg failed" 0 \
  "probe 7 (rc cut, tag-only and marked prerelease) failed" cat "$TMP/rc-stamped.md"
check "a failed rc cut withdraws its claim from the conclusion" 1 "" \
  grep -qF 'left `CHANGELOG.md` byte-identical' "$TMP/rc-stamped.md"

stub_reset
rc_scenario "$TMP/rc-final.scenario" 10 \
  "success	release:0.7.2-rc1,rearm:0.7.2-rc2-dev,drop:changelog.d/9.md,tag:0.7.2-leak"
rc_final_out="$(run_rehearsal "$TMP/rc-final.scenario" --out "$TMP/rc-final.md" 2>&1)"
check "a candidate published as a full release reds the rc cut" 0 \
  "reports isPrerelease: false, expected true" probe_row "$TMP/rc-final.md" 7
check "a fragment consumed by the rc cut reds it too" 0 \
  "the fragment set changed across the rc cut" probe_row "$TMP/rc-final.md" 7
check "an rc cut that left a tag behind reds on the count" 0 \
  "tags moved 2→4, expected a delta of 1" probe_row "$TMP/rc-final.md" 7
# A candidate published as a full release is still a full release when the
# promotion looks at it, so this run reds two legs rather than one. The
# cascade is real and the record states it where it happened, which is the
# shape a failed drill is supposed to have.
check "the two legs it broke are both reported failed" 0 "probes passed 6/8, failed 2" \
  printf '%s\n' "$rc_final_out"
check "the promotion reds on a candidate that was never a prerelease" 0 \
  "the '0.7.2-rc1' release reports isPrerelease: false after the promotion" \
  probe_row "$TMP/rc-final.md" 8

stub_reset
rc_scenario "$TMP/promotion-relabel.scenario" 11 \
  "success	release:0.7.2,rearm:0.7.3-dev,relabel:0.7.2-rc1"
relabel_out="$(run_rehearsal "$TMP/promotion-relabel.scenario" --out "$TMP/relabel.md" 2>&1)"
check "a promotion that relabels its candidate reds the promotion" 0 \
  "promoting must not retroactively relabel the candidate" \
  probe_row "$TMP/relabel.md" 8
check "the rc cut before it still passed" 0 "✅" probe_row "$TMP/relabel.md" 7
check "the run reports the promotion as the one failure" 0 "probes passed 7/8, failed 1" \
  printf '%s\n' "$relabel_out"
check "a failed promotion withdraws its claim from the conclusion" 1 "" \
  grep -qF 'while the candidate stayed a prerelease' "$TMP/relabel.md"
check "a failed rc leg is still a whole record" 0 "eight probe rows" \
  record_check "$TMP/relabel.md"

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
head -n 10 "$TMP/aborted.scenario" >"$TMP/aborted.tmp" &&
  mv "$TMP/aborted.tmp" "$TMP/aborted.scenario"
aborted_out="$(run_rehearsal "$TMP/aborted.scenario" --out "$TMP/aborted.md" 2>&1)"
aborted_rc=$?
check "an aborted probe does not abort the rehearsal" 0 "" test "$aborted_rc" -eq 0
check "the aborted probe is reported as the one failure" 0 "probes passed 7/8, failed 1" \
  printf '%s\n' "$aborted_out"
check "the record exists at all after an abort" 0 "" test -s "$TMP/aborted.md"
check "the aborted probe's row says it aborted" 0 "❌ aborted before it reached a verdict" \
  bash -c 'awk "/^\\| 8 \\|/" "$1"' _ "$TMP/aborted.md"
check "the aborted probe's row links no run it never had" 0 "| — |" \
  bash -c 'awk "/^\\| 8 \\|/" "$1"' _ "$TMP/aborted.md"
check "the record after an abort still passes the shape check" 0 "eight probe rows" \
  record_check "$TMP/aborted.md"
check "the end-to-end aborted record's preamble names the probe that never ran" 0 \
  "**1 of the eight probes never reached a run** (probe 8)" cat "$TMP/aborted.md"
check "the aborted probe establishes nothing in the conclusion" 1 "" \
  grep -qF 'promoted `0.7.2-rc1` to `0.7.2`' "$TMP/aborted.md"
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
# The read-after-write path retries, and a soft read means one thing (#369).
#
# The 0.7.0 cut aborted four times in setup before a probe ran; three were one
# defect — every read here follows a write, GitHub answered stale or
# transiently, and nothing retried — and two of those three reported the
# opposite of what had happened, saying a write had failed when it had landed.
# So the messages are asserted on as hard as the exit statuses: the wrong
# message IS the defect, and a test that only checked the status would have
# passed on 0.7.0's behavior.
#
# The stub's fault rules are what make this driveable offline: the same
# request has to answer differently on the second call than on the first, and
# no amount of stub *state* produces that.
# ---------------------------------------------------------------------------
# A subshell, so the exports land on the call and nothing else. `check` already
# runs its command in a command substitution, but the handful of direct
# `with_stub …` calls in this file do not — and an exported PATH and a zeroed
# nap leaking into whatever gets appended after them is a trap rather than a
# feature. Every caller's side effects are stub state on disk, so nothing here
# needs shell state to survive the call; `DRILL_READ_TRIES=0 with_stub …` still
# works, since a subshell inherits shell variables.
with_stub() { # <cmd…> — one library call against the stub, nap-free
  (
    export PATH="$STUB_BIN:$PATH" DRILL_STUB_STATE="$TMP/state"
    export DRILL_STUB_SCENARIO="$TMP/empty.scenario" DRILL_STUB_FAULTS="$FAULTS"
    export DRILL_READ_NAP_SECONDS=0
    "$@"
  )
}
empty_stdout() { # <cmd…> — the command printed nothing on stdout
  local out
  out="$("$@" 2>/dev/null)"
  [ -z "$out" ]
}
calls_are() { # <n> <literal> — the call log holds exactly n matching lines
  test "$(grep -cF -- "$2" "$TMP/state/calls")" -eq "$1"
}
calls_at_least() { # <n> <literal> — at least n, for "it spent the budget"
  test "$(grep -cF -- "$2" "$TMP/state/calls")" -ge "$1"
}

# D2 — absent and failed, told apart. Both branches carry a test, because the
# whole defect is that they were one branch.
stub_reset
: >"$TMP/empty.scenario"
check "a 404 answers absent: the call succeeded in saying 'not there'" 0 "" \
  with_stub drill_gh_soft api "repos/$FORK/git/ref/heads/nosuch" --jq '.object.sha'
check "and absent prints nothing, so the filtered error body never reads as data" 0 "" \
  empty_stdout with_stub drill_gh_soft api "repos/$FORK/git/ref/heads/nosuch" --jq '.object.sha'
faults "0	1	GET repos/*/git/ref/heads/main	500	Internal Server Error"
check "a non-404 failure is a failed read, not an absence" 1 "Internal Server Error" \
  with_stub drill_gh_soft api "repos/$FORK/git/ref/heads/main" --jq '.object.sha'

# The genuine 404 does not spend the retry budget waiting for a thing nobody
# ever wrote — asserted on the call count, since a budget spent silently is
# exactly what a passing test would otherwise hide.
stub_reset
: >"$TMP/state/calls"
check "a ref that truly does not exist answers absent" 0 "" \
  empty_stdout with_stub scratch_ref_sha "$FORK" nosuch
check "and it spent exactly one call doing it" 0 "" calls_are 1 "git/ref/heads/nosuch"

# D1 — a read that fails K < tries times and then succeeds. This is the 0.7.0
# failure mode itself, replayed.
stub_reset
with_stub scratch_ref_create "$FORK" refs/heads/main "$CAND_SHA" >/dev/null 2>&1
faults "0	2	GET repos/*/git/ref/heads/main	500	Internal Server Error"
: >"$TMP/state/calls"
check "a read that fails twice and then answers is a read that answered" 0 "$CAND_SHA" \
  with_stub scratch_ref_sha "$FORK" main
check "and it took exactly the three calls that took" 0 "" calls_are 3 "git/ref/heads/main"

# D3 — `409 Git Repository is empty` on a repo the instrument has just
# created is the same "not there *yet*" as a 404: retried where the write is
# known to have happened, and the bootstrap's own door where it is not.
stub_reset
with_stub scratch_ref_create "$FORK" refs/heads/main "$CAND_SHA" >/dev/null 2>&1
faults "0	2	GET repos/*/git/ref/heads/main	409	Git Repository is empty."
: >"$TMP/state/calls"
check "a 409 on a just-created repo retries rather than aborting" 0 "$CAND_SHA" \
  with_stub scratch_ref_sha "$FORK" main nonempty
check "and the 409 was retried, not reported" 0 "" calls_are 3 "git/ref/heads/main"
faults "0	1	GET repos/*/git/ref/heads/main	409	Git Repository is empty."
check "the same 409 still answers absent where absence is the question" 0 "" \
  empty_stdout with_stub scratch_ref_sha "$FORK" main

# A mode nobody defined is refused rather than read as the weaker one: a
# misspelled `nonempty` degrading silently to `any` is 0.7.0's defect back
# with nothing to notice it.
faults
check "an unknown read mode is refused, never taken for 'any'" 2 \
  "unknown mode 'nonemty'" with_stub scratch_ref_sha "$FORK" main nonemty

# The try count is a bound, and a bound of none is one attempt.
faults "0	99	GET repos/*/git/ref/heads/main	500	Internal Server Error"
tries_zero() { DRILL_READ_TRIES=0 with_stub scratch_ref_sha "$FORK" main nonempty; }
check "DRILL_READ_TRIES=0 is one attempt, and says so in the singular" 1 \
  "did not read back after 1 attempt" tries_zero

# Must-pass, end to end: the bootstrap re-read answers stale twice and the
# rehearsal proceeds, emitting the record the clean run emitted.
#
# The fault is a 404 on a ref that exists, and it is a 404 on purpose. That is
# the shape of the read this defect is about — GitHub answering "not there"
# about a commit it is holding — and a 500 here would prove nothing, because
# a failed read is retried in either mode. Only a stale one tells the two
# apart, and the `skip` is what aims it past the pre-bootstrap read, whose
# empty answer is a true one.
stub_reset
green_scenario "$TMP/retried.scenario"
faults "1	2	GET repos/$SCRATCH/git/ref/heads/main	404	Not Found"
retried_out="$(run_rehearsal "$TMP/retried.scenario" --out "$TMP/retried.md" 2>&1)"
retried_rc=$?
check "a bootstrap re-read that answers stale twice does not stop the rehearsal" 0 "" \
  test "$retried_rc" -eq 0
check "and all eight probes still ran" 0 "probes passed 8/8, failed 0" \
  printf '%s\n' "$retried_out"
check "the record it emits is the clean run's, unchanged" 0 "" \
  diff -u "$TMP/emitted.md" "$TMP/retried.md"

# Must-fail: the same read never answers. The message is the assertion — it
# names the read, the target and the attempt count, and says nothing about
# whether the write landed. "left … with no head" was the 0.7.0 wording, and
# `…-rehearsal-2@main` held the commit it said had not landed.
stub_reset
BOOTSTRAP="$SCRATCH_OWNER/bootstrap-probe"
with_stub scratch_create_attempt "$BOOTSTRAP" >/dev/null 2>&1
printf '0.7.0-dev\n' >"$TMP/seed-version"
printf 'A\tVERSION\t%s\n' "$TMP/seed-version" >"$TMP/boot.manifest"
faults "1	99	GET repos/$BOOTSTRAP/git/ref/heads/main	404	Not Found"
: >"$TMP/state/calls"
with_stub scratch_commit "$BOOTSTRAP" main "the armed fixture at 0.7.0-dev" \
  "$TMP/boot.manifest" >"$TMP/boot.out" 2>&1
boot_rc=$?
check "a bootstrap re-read that never answers aborts" 0 "" test "$boot_rc" -eq 1
check "and names the read, its target and its attempt count" 0 \
  "refs/heads/main on $BOOTSTRAP did not read back after 10 attempts" cat "$TMP/boot.out"
check "the abort never claims the commit left the branch with no head" 1 "" \
  grep -qF 'no head' "$TMP/boot.out"
check "it says a failed read is not a failed write" 0 \
  "a failed read, not a failed write" cat "$TMP/boot.out"
# D5, first half: the read retried ten times and the write beneath it once.
check "the bootstrap write was not retried while its read was" 0 "" \
  calls_are 1 "contents/VERSION --method PUT"

# fork_ref_verify: one 500 and the pin still verifies; a budget of them is a
# failed read and never the pin's fault.
stub_reset
mkdir -p "$TMP/verify-work"
with_stub fork_ref_prepare "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/verify-work" >/dev/null 2>&1
faults "0	1	GET repos/*/contents/*	500	Internal Server Error"
check "a pin read that 500s once still verifies" 0 "$CAND_SHA" \
  with_stub fork_ref_verify "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/verify-work"
faults "0	99	GET repos/*/contents/*	500	Internal Server Error"
with_stub fork_ref_verify "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/verify-work" \
  >"$TMP/verify.out" 2>&1
verify_rc=$?
check "a pin read that never answers aborts" 0 "" test "$verify_rc" -eq 1
check "and names the read that failed, with its attempt count" 0 \
  "did not read back after 10 attempts" cat "$TMP/verify.out"
check "the abort never asserts the pin does not read the candidate SHA" 1 "" \
  grep -qF 'does not read the candidate SHA' "$TMP/verify.out"
faults "0	99	GET repos/*/git/trees/*	500	Internal Server Error"
check "a carrier list that never reads back is a failed read too" 1 \
  "the tree of $FORK_REF on $FORK did not read back" \
  with_stub fork_ref_verify "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/verify-work"
# The stale answers, which is the half a 500 cannot prove: a read that keeps
# saying "not there" about a tree and a pin this instrument just wrote is not
# an absence to pass over — a verify that read no bytes verifies nothing, and
# passing there would be the same claim-without-a-measurement in a new place.
faults "0	2	GET repos/*/contents/*	404	Not Found"
check "a pin read that answers stale twice still verifies" 0 "$CAND_SHA" \
  with_stub fork_ref_verify "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/verify-work"
faults "0	99	GET repos/*/contents/*	404	Not Found"
check "a pin that never reads back is a failed read, not a verified pin" 1 \
  "did not read back after 10 attempts" \
  with_stub fork_ref_verify "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/verify-work"
faults "0	99	GET repos/*/git/trees/*	404	Not Found"
check "a carrier list that never reads back is one too" 1 \
  "the tree of $FORK_REF on $FORK did not read back" \
  with_stub fork_ref_verify "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/verify-work"
# And the refusal the retry must not have swallowed: a pin that genuinely
# disagrees keeps its own wording, which is the message the retry replaced
# only for the case where nothing was read at all.
faults
check "a pin that genuinely disagrees still says so, in its own words" 1 \
  "the rewritten pin does not read the candidate SHA" \
  with_stub fork_ref_verify "$FORK" "$FORK_REF" \
  deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$TMP/verify-work"
# The third answer this read can give, and the one no fault can produce: the
# tree answered, and what it answered carries no `.github/workflows/*.yml`.
# Nothing above reaches it — a 404 or a 500 on the tree is a failed read, and
# an empty carrier list is a successful read of a ref with nothing to verify.
# Without this the loop runs zero times, `wrong` stays empty, and the function
# prints the candidate SHA as though it had checked something: the
# claim-without-a-measurement it exists to refuse.
CARRIERLESS="$SCRATCH_OWNER/carrierless-fork"
K="$TMP/state/$(san "$CARRIERLESS")"
mkdir -p "$K/refs" "$K/commit" "$K/tree" "$K/blob"
printf 'placeholder\n' >"$K/blob/bk1"
printf 'README.md\tbk1\n' >"$K/tree/tk1"
printf 'tk1\n' >"$K/commit/sk1"
printf 'sk1\n' >"$K/refs/heads_main"
with_stub fork_ref_verify "$CARRIERLESS" refs/heads/main "$CAND_SHA" \
  "$TMP/verify-work" >"$TMP/carrierless.out" 2>"$TMP/carrierless.err"
carrierless_rc=$?
check "a verify that read no carrier refuses instead of verifying nothing" 0 "" \
  test "$carrierless_rc" -eq 1
check "and it says what it read, not what it could not verify" 0 \
  "read back no .github/workflows/*.yml" cat "$TMP/carrierless.err"
check "and it never prints the candidate SHA it did not check" 1 "" \
  grep -qF "$CAND_SHA" "$TMP/carrierless.out"

# D5 — no write path gains a retry. A retried write against the git data API
# risks a second commit, so a failed write is an abort and stays one.
stub_reset
printf 'A\tVERSION\t%s\n' "$TMP/seed-version" >"$TMP/write.manifest"
faults "0	1	POST repos/*/git/commits	500	Internal Server Error"
: >"$TMP/state/calls"
with_stub scratch_commit "$FORK" main "a commit whose write fails once" \
  "$TMP/write.manifest" >"$TMP/write.out" 2>&1
write_rc=$?
check "a write that fails once aborts rather than retrying" 0 "" test "$write_rc" -eq 1
check "exactly one commit was attempted" 0 "" calls_are 1 "git/commits --input -"
check "and exactly one tree was written under it" 0 "" calls_are 1 "git/trees --input -"

# The other two writes in the same function, each failing in its own case,
# because a write only proves it was not retried by failing: the tree count
# above and the bootstrap count further up are both taken on writes that
# *succeeded*, so a retry added to either would have left them green. The
# sweep found exactly that — mutations giving the tree write and the bootstrap
# PUT a retry loop red nothing without these two.
faults "0	1	POST repos/*/git/trees	500	Internal Server Error"
: >"$TMP/state/calls"
with_stub scratch_commit "$FORK" main "a commit whose tree write fails once" \
  "$TMP/write.manifest" >"$TMP/treewrite.out" 2>&1
tree_write_rc=$?
check "a tree write that fails once aborts rather than retrying" 0 "" \
  test "$tree_write_rc" -eq 1
check "exactly one tree was attempted" 0 "" calls_are 1 "git/trees --input -"
check "and no commit was built on a tree that never landed" 0 "" \
  calls_are 0 "git/commits --input -"

# The bootstrap's own write, on the one door an empty repository opens: the
# contents PUT. A fresh repo, so the path is reached at all.
stub_reset
PUTPROBE="$SCRATCH_OWNER/put-probe"
with_stub scratch_create_attempt "$PUTPROBE" >/dev/null 2>&1
faults "0	1	PUT repos/*/contents/*	500	Internal Server Error"
: >"$TMP/state/calls"
with_stub scratch_commit "$PUTPROBE" main "the armed fixture at 0.7.0-dev" \
  "$TMP/boot.manifest" >"$TMP/putwrite.out" 2>&1
put_write_rc=$?
check "a bootstrap write that fails once aborts rather than retrying" 0 "" \
  test "$put_write_rc" -eq 1
check "exactly one bootstrap PUT was attempted" 0 "" \
  calls_are 1 "contents/VERSION --method PUT"
# One ref read: the does-it-exist read that sent us down the bootstrap path.
# A second would mean the re-read ran under a write that never landed.
check "and the re-read never ran under a write that failed" 0 "" \
  calls_are 1 "git/ref/heads/main"

# The base-tree read, which is the call the 0.7.0 cut's third abort came from
# — `409 Git Repository is empty.` from the git data API about a repo
# `gh repo create` had just returned — and the one routing in this change that
# round 1 found pinned by nothing. Both mutations were green without this:
# reverting the routing, and flipping only its mode to `any`.
#
# The mode is the half that matters, and the assertion is the tree rather than
# the message. In `any` mode a 409 or 404 there answers *absent*, `base_tree`
# comes back empty, and the tree POST is built without it while the parent
# stays — so the commit's tree is the manifest and nothing else, and every file
# the repo already had is deleted by the drill's own write. Silent corruption:
# nothing aborts, nothing prints, and the paths are the only witness.
stub_reset
with_stub scratch_ref_create "$FORK" refs/heads/main "$CAND_SHA" >/dev/null 2>&1
printf 'A\tVERSION\t%s\n' "$TMP/seed-version" >"$TMP/basetree.manifest"
faults "0	2	GET repos/*/git/commits/*	409	Git Repository is empty."
: >"$TMP/state/calls"
check "a base-tree read answering 409 twice still lands the commit" 0 "" \
  with_stub scratch_commit "$FORK" main "a commit over a stale base tree" \
  "$TMP/basetree.manifest"
check "and it retried that read rather than reporting it, three calls in" 0 "" \
  calls_are 3 "git/commits/$CAND_SHA"
check "the write under it still went once" 0 "" calls_are 1 "git/trees --input -"
with_stub scratch_paths "$FORK" main | sort >"$TMP/basetree.paths"
printf '%s\n' .github/workflows/ci.yml .github/workflows/labels.yml \
  .github/workflows/release.yml VERSION | sort >"$TMP/basetree.expected"
# Compared as a whole list, not searched for a substring: the failure this
# pins is files *missing*, and a containment check cannot see that.
check "and every file the repo already had survived it — the base tree was read, not skipped" 0 "" \
  diff -u "$TMP/basetree.expected" "$TMP/basetree.paths"
# Named off the head as it stands, because the commit above moved it: the
# message has to name the commit whose tree was actually asked for.
BASETREE_HEAD="$(with_stub scratch_ref_sha "$FORK" main)"
faults "0	99	GET repos/*/git/commits/*	409	Git Repository is empty."
: >"$TMP/state/calls"
check "a base-tree read that never answers aborts, naming the read" 1 \
  "the tree of commit $BASETREE_HEAD on $FORK did not read back after 10 attempts" \
  with_stub scratch_commit "$FORK" main "a commit whose base tree never reads" \
  "$TMP/basetree.manifest"
check "and no tree was written under a base it never read" 0 "" \
  calls_are 0 "git/trees --input -"

# The other read in the same function, and the one round 2 found: the
# does-it-exist read at the top. It is `any` on purpose — a branch nobody
# created is a real answer, and the bootstrap below is what that answer means
# — but `any` distinguishes absent from failed only if the caller keeps the
# status. Without the `|| return 1` on that assignment, ten exhausted 500s
# leave `base_sha` empty and are read as "this repo has no commits": the
# bootstrap's contents PUT carries `branch`, so it commits to a branch that
# already has a head, built from the manifest's first `A` line alone, and only
# the guarded re-read afterwards aborts. The write is the assertion here. An
# rc check alone stays green under the bug, because the function does return 1
# — twenty reads and one write later.
stub_reset
with_stub scratch_ref_create "$FORK" refs/heads/main "$CAND_SHA" >/dev/null 2>&1
faults "0	99	GET repos/*/git/ref/heads/main	500	Internal Server Error"
: >"$TMP/state/calls"
# Called the way every probe calls it — through a substitution, which is what
# suppresses errexit inside the function and made the swallowed status matter.
baseread_caller() {
  local sha
  sha="$(with_stub scratch_commit "$FORK" main "a commit whose base read never answers" \
    "$TMP/basetree.manifest")" || return 1
  printf '%s\n' "$sha"
}
baseread_caller >"$TMP/baseread.out" 2>"$TMP/baseread.err"
baseread_rc=$?
check "a base read that never answers aborts" 0 "" test "$baseread_rc" -eq 1
check "and names the read, its target and its attempt count" 0 \
  "refs/heads/main on $FORK did not read back after 10 attempts" cat "$TMP/baseread.err"
check "and it stopped at its budget rather than reading twice over" 0 "" \
  calls_are 10 "git/ref/heads/main"
# The four writes the function can make, each asserted absent by name: a
# failed existence read must not reach any of them.
check "no bootstrap PUT went out on a read that never answered" 0 "" \
  calls_are 0 "contents/VERSION --method PUT"
check "no tree was written under it" 0 "" calls_are 0 "git/trees --input -"
check "no commit was built under it" 0 "" calls_are 0 "git/commits --input -"
check "and the branch it could not read was never created" 0 "" \
  calls_are 0 "git/refs --input -"
check "nor moved" 0 "" calls_are 0 "git/refs/heads/main --method PATCH"
# And the absence this read is `any` for is unchanged: a branch nobody created
# still answers in one call and still routes to the bootstrap, rather than
# spending ten calls on a thing that was never written.
stub_reset
faults
: >"$TMP/state/calls"
check "a branch nobody created still bootstraps, in one read" 0 "" \
  with_stub scratch_commit "$FORK" main "the first commit on an empty repo" \
  "$TMP/basetree.manifest"
# Two, and only two: the pre-read that answered absent in one call, and the
# guarded re-read after the bootstrap write. A budget spent here would mean
# `any` had started treating a true absence as something to wait for.
check "and that read cost one call, not the budget" 0 "" \
  calls_are 2 "git/ref/heads/main"

# The sites round 1 found still outside the helper: reads that follow a write
# this instrument made, where a stale 404 escaped drill_gh_soft as exit 0 and
# empty and the caller took it for an answer.
stub_reset
with_stub scratch_ref_create "$FORK" refs/heads/main "$CAND_SHA" >/dev/null 2>&1
printf 'A\tVERSION\t%s\n' "$TMP/seed-version" >"$TMP/read.manifest"
with_stub scratch_commit "$FORK" main "a file to read back" "$TMP/read.manifest" \
  >/dev/null 2>&1
faults "0	2	GET repos/*/contents/VERSION*	404	Not Found"
check "a VERSION read that answers stale twice reads the version, not an absence" 0 "0.7.0-dev" \
  with_stub scratch_version "$FORK" main nonempty
faults "0	99	GET repos/*/contents/VERSION*	404	Not Found"
with_stub scratch_version "$FORK" main nonempty >"$TMP/version.out" 2>&1
version_rc=$?
check "a VERSION read that never answers is a failed read, not a version" 0 "" \
  test "$version_rc" -eq 1
check "and it names the read and its attempt count" 0 \
  "VERSION at $FORK@main did not read back after 10 attempts" cat "$TMP/version.out"
# The escape this replaces exited 0 with empty stdout, and the probe then
# recorded a claim about main from that emptiness. The exit status above is
# what stops it; this is the other half — nothing reaches stdout to be read as
# a version.
version_stdout="$(with_stub scratch_version "$FORK" main nonempty 2>/dev/null)"
check "and prints no version at all, so nothing downstream can assert on one" 0 "" \
  test -z "$version_stdout"

# `any` is still the mode for the question it answers: a ref that genuinely
# carries no VERSION is not a stale read to spend ten calls on.
faults
: >"$TMP/state/calls"
check "a VERSION nobody wrote still answers absent" 0 "" \
  empty_stdout with_stub scratch_version "$FORK" nosuchbranch
check "and spent exactly one call doing it" 0 "" calls_are 1 "contents/VERSION"

# scratch_file, the same two ways. Its false absence had a message of its own
# — "has no 'VERSION' to read" — and that message is the thing D4 forbids: a
# statement about the repo derived from a read that never happened.
faults "0	2	GET repos/*/contents/VERSION*	404	Not Found"
check "a file read that answers stale twice still lands the bytes" 0 "" \
  with_stub scratch_file "$FORK" main VERSION "$TMP/read.out" nonempty
check "and the bytes it landed are the file's" 0 "0.7.0-dev" cat "$TMP/read.out"
faults "0	99	GET repos/*/contents/VERSION*	404	Not Found"
with_stub scratch_file "$FORK" main VERSION "$TMP/read.out" nonempty \
  >"$TMP/file.out" 2>&1
file_rc=$?
check "a file read that never answers aborts" 0 "" test "$file_rc" -eq 1
check "and names the read rather than the file" 0 \
  "VERSION at $FORK@main did not read back after 10 attempts" cat "$TMP/file.out"
check "and never says the ref has no such path, which was the false absence" 1 "" \
  grep -qF "has no 'VERSION' to read" "$TMP/file.out"
# And the genuine absence keeps its own wording, as the pin refusal does.
faults
check "a path that truly is not there still says so, in its own words" 1 \
  "has no 'nosuch.md' to read" \
  with_stub scratch_file "$FORK" main nosuch.md "$TMP/read.out"

# The label verify: 0.6.0's probe 2 merged unlabeled because a label write
# failed and the failure was read after the merge, so this read is the one the
# probe refuses to merge on. An empty answer from it, one write later, is a
# stale index — and refusing there would abort a probe over the read.
stub_reset
LABELPR="$(with_stub scratch_pr_create "$FORK" topic main "a labelled PR" 2>/dev/null)"
with_stub scratch_pr_label "$FORK" "$LABELPR" release >/dev/null 2>&1
faults "0	2	GET repos/*/issues/*/labels	404	Not Found"
: >"$TMP/state/calls"
check "a label read that answers stale twice reads the label back" 0 "release" \
  with_stub scratch_pr_labels "$FORK" "$LABELPR" nonempty
check "and took the three calls it took" 0 "" calls_are 3 "issues/$LABELPR/labels"
faults "0	99	GET repos/*/issues/*/labels	404	Not Found"
check "a label read that never answers is a failed read" 1 \
  "the labels on $FORK#$LABELPR did not read back after 10 attempts" \
  with_stub scratch_pr_labels "$FORK" "$LABELPR" nonempty

# And the caller that turns that read into a claim (#369 D6). The verify used
# to sit left of a `grep`, which owns the pipeline's exit status, so an
# exhausted read reached the refusal and reported a PR as unlabeled on a list
# nobody had read. Both refusals are exercised, because the point is that they
# are two facts: one says the read did not answer, the other says the label is
# not there, and only the second may speak about the PR.
merge_unread_label() {
  (
    DRILL_REPO="$FORK"
    with_stub probe_merge_and_wait probe-label "a labelled PR" release
  )
}
stub_reset
faults "0	99	GET repos/*/issues/*/labels	404	Not Found"
merge_unread_label >"$TMP/mergelabel.out" 2>&1
merge_label_rc=$?
check "a merge whose label verify never reads back refuses to merge" 0 "" \
  test "$merge_label_rc" -eq 1
check "and refuses on the read, naming it" 0 \
  "did not read back after the write, so the 'release' label was never checked" \
  cat "$TMP/mergelabel.out"
check "it never reports the PR as unlabeled on a read that did not answer" 1 "" \
  grep -qF "did not carry the 'release' label" "$TMP/mergelabel.out"
check "and it never reached the merge" 0 "" calls_are 0 "/merge"
# The other side: a list that was read, and genuinely does not carry it. This
# is 0.6.0's probe 2 — a PR carrying labels, none of them the one the probe is
# about — and the refusal that must still fire, in its own words.
merge_lost_label() {
  (
    export DRILL_STUB_LABEL_INSTEAD='scope:release-flow'
    DRILL_REPO="$FORK"
    with_stub probe_merge_and_wait probe-label "a labelled PR" release
  )
}
stub_reset
merge_lost_label >"$TMP/lostlabel.out" 2>&1
lost_label_rc=$?
check "a merge whose PR reads back without the label refuses too" 0 "" \
  test "$lost_label_rc" -eq 1
check "and this one does speak about the PR, because the list was read" 0 \
  "did not carry the 'release' label after the write" cat "$TMP/lostlabel.out"
check "it never blames the read that answered perfectly well" 1 "" \
  grep -qF 'did not read back after the write' "$TMP/lostlabel.out"

# The disposal read. This one is different in kind: it answers a formatted
# string on a 200 either way, so `nonempty` buys nothing over `any` unless the
# read selects on the value just written — a stale `archived=false` about a
# repo the PATCH above archived is non-empty, and a retry that accepts it ends
# on the wrong answer and puts 0.2.0's record-a-cleanup-that-did-not-happen
# straight back. The stub's lag knob is what makes that shape reachable; the
# fault rules inject failures and cannot express it.
stub_reset
check "an archive whose flag reads back true reports what it observed" 0 \
  "archived=true private=true" with_stub scratch_archive "$FORK"
stub_reset
archive_lagged() { DRILL_STUB_ARCHIVE_LAG=2 with_stub scratch_archive "$FORK"; }
check "an archive whose flag reads stale twice waits for the value it wrote" 0 \
  "archived=true private=true" archive_lagged
stub_reset
faults "0	2	GET repos/$FORK	500	Internal Server Error"
check "a disposal read that 500s twice still reports the flag" 0 \
  "archived=true private=true" with_stub scratch_archive "$FORK"

# D7 — an answer is not an absence. This read is the one site in the family
# where the WRONG answer is representable, so its two failures are two
# dispositions: a flag that reads `false` to the end of the budget is a repo
# this run knows is not archived, and collapsing it into "the read never
# answered" throws away what #135 installed the read-back for after 0.2.0
# shipped a record claiming a cleanup that had not happened.
stub_reset
archive_false() { DRILL_STUB_ARCHIVE_LAG=99 with_stub scratch_archive "$FORK"; }
archive_false >"$TMP/archive-false.out" 2>&1
archive_false_rc=$?
check "a flag that reads false to the end of the budget is its own disposition" 0 "" \
  test "$archive_false_rc" -eq 3
check "and the answer it kept reading is what it reports" 3 \
  "archived=false private=true" archive_false
check "it never claims the archive it did not observe" 1 "" \
  grep -qF 'archived=true' "$TMP/archive-false.out"
check "and it spent the whole budget before saying so" 0 "" \
  calls_at_least 10 '--jq "archived='
# The other disposition, on the same call: a read that answers nothing at all.
stub_reset
faults "0	99	GET repos/$FORK	500	Internal Server Error"
with_stub scratch_archive "$FORK" >"$TMP/archive-unread.out" 2>&1
archive_unread_rc=$?
check "a flag read that never answers is the unread disposition, not the false one" 0 "" \
  test "$archive_unread_rc" -eq 1
check "and it names the read and its attempt count" 0 \
  "the archived flag on $FORK did not read back after 10 attempts" \
  cat "$TMP/archive-unread.out"
check "it reports no flag at all, since it read none" 0 "" \
  empty_stdout with_stub scratch_archive "$FORK"

# The cases above pin the helpers' modes. What they cannot see is whether the
# *callers* pass the mode — a probe that reverts to the default reads `any`
# again and the helper is blameless. So the three probe-side read-after-writes
# are pinned end to end, in one run carrying one fault each: probe 1's re-arm
# read of VERSION, probe 7's CHANGELOG.md read off main, and probe 1's label
# verify between the write and the merge.
#
# Every one of them is a 404 answering about a file or a label this instrument
# has just written, and every one of them is silent in `any` mode: the re-arm
# records "main reads ''", the changelog read reports the file missing, the
# label verify refuses to merge. All three surface here as a probe row that is
# not PASS, which is why the assertion is 8/8 and the emitted record rather
# than any one message. One run rather than three because each fault names its
# own endpoint, so a regression at any single site reds it.
stub_reset
green_scenario "$TMP/probesites.scenario"
faults \
  "0	2	GET repos/$SCRATCH/contents/VERSION*	404	Not Found" \
  "0	2	GET repos/$SCRATCH/contents/CHANGELOG.md*	404	Not Found" \
  "0	2	GET repos/$SCRATCH/issues/*/labels	404	Not Found"
sites_out="$(run_rehearsal "$TMP/probesites.scenario" --out "$TMP/probesites.md" 2>&1)"
sites_rc=$?
check "stale answers at the probes' own read-after-writes do not stop the rehearsal" 0 "" \
  test "$sites_rc" -eq 0
check "and every probe still reached its verdict" 0 "probes passed 8/8, failed 0" \
  printf '%s\n' "$sites_out"
check "the record it emits is the clean run's, unchanged" 0 "" \
  diff -u "$TMP/emitted.md" "$TMP/probesites.md"

# The two changelog reads *after* a door has run — probe 7's across the rc cut
# and probe 8's across the promotion. They need their own run, because the
# fault above is spent on probe 7's before-read, and they need the call log
# rather than the record to tell the modes apart: in `any` mode `scratch_file`
# returns 1 on the stale answer just as an exhausted read does, so both modes
# record the same "did not read back" row. What differs is that one of them
# asked ten times and the other gave up on the first stale 404 — so the budget
# it spent is the assertion, and a `skip` of one aims the rule past the
# before-read whose empty answer would be a true one.
stub_reset
green_scenario "$TMP/changelog.scenario"
faults "1	99	GET repos/$SCRATCH/contents/CHANGELOG.md*	404	Not Found"
changelog_out="$(run_rehearsal "$TMP/changelog.scenario" --out "$TMP/changelog.md" 2>&1)"
check "a changelog read that never answers fails its probe and no more" 0 \
  "probes passed 6/8, failed 2" printf '%s\n' "$changelog_out"
check "probe 7 says the comparison was never taken" 0 \
  "CHANGELOG.md did not read back after the rc cut" cat "$TMP/changelog.md"
check "probe 8 says the same of the stamped section" 0 \
  "CHANGELOG.md did not read back after the promotion" cat "$TMP/changelog.md"
check "and both of them spent the budget rather than believing the first 404" 0 "" \
  calls_at_least 20 "contents/CHANGELOG.md"

# Setup's own read-after-writes, which cannot ride a rehearsal because a fault
# there aborts before a probe runs: the fixture's seeding assertion, and
# fork_ref_prepare's two reads of the ref it has just created. Each `any`-mode
# escape has a message of its own that reads as a fact about the repo — "is
# missing the armed fixture", "carries no .github/workflows/*.yml", "no
# workflow … carries CEREMONY_SELF_REF" — which is the shape D4 forbids, so
# each is asserted absent as well as the honest one asserted present.
stub_reset
SEEDED="$SCRATCH_OWNER/seeded-probe"
with_stub scratch_create_attempt "$SEEDED" >/dev/null 2>&1
printf '# Changelog\n' >"$TMP/seed-changelog"
printf 'Fragments live here.\n' >"$TMP/seed-readme"
{
  printf 'A\tVERSION\t%s\n' "$TMP/seed-version"
  printf 'A\tCHANGELOG.md\t%s\n' "$TMP/seed-changelog"
  printf 'A\tchangelog.d/README.md\t%s\n' "$TMP/seed-readme"
} >"$TMP/seeded.manifest"
with_stub scratch_commit "$SEEDED" main "the armed fixture at 0.7.0-dev" \
  "$TMP/seeded.manifest" >/dev/null 2>&1
check "the fixture this case is about is genuinely seeded" 0 "" \
  with_stub fixture_assert_seeded "$SEEDED" main
faults "0	2	GET repos/*/git/trees/*	404	Not Found"
check "a seeding check whose tree read answers stale twice still passes" 0 "" \
  with_stub fixture_assert_seeded "$SEEDED" main
faults "0	99	GET repos/*/git/trees/*	404	Not Found"
with_stub fixture_assert_seeded "$SEEDED" main >"$TMP/seeded.out" 2>&1
seeded_rc=$?
check "a seeding check whose tree never reads back aborts" 0 "" test "$seeded_rc" -eq 1
check "and names the read rather than the fixture" 0 \
  "the tree of main on $SEEDED did not read back after 10 attempts" cat "$TMP/seeded.out"
check "it never reports an armed fixture as missing on a read that failed" 1 "" \
  grep -qF 'is missing the armed fixture' "$TMP/seeded.out"
# The genuine absence keeps its own words, as every refusal the retry sits in
# front of does.
faults
with_stub scratch_ref_create "$FORK" refs/heads/main "$CAND_SHA" >/dev/null 2>&1
check "a tree that genuinely lacks the fixture still says which files" 1 \
  "is missing the armed fixture: VERSION CHANGELOG.md changelog.d/README.md" \
  with_stub fixture_assert_seeded "$FORK" main

# A fragment filter is allowed to find nothing, but only after its tree read
# answered. The old pipeline collapsed that distinction and let two failed
# reads compare equal (#375 D1).
fragment_paths_of() { # <repo> <ref> — list on stdout
  with_stub probe_fragment_paths "$1" "$2" "$TMP/frags.read" || return 1
  cat "$TMP/frags.read"
}
faults
FRAGS="$SCRATCH_OWNER/fragments-probe"
with_stub scratch_create_attempt "$FRAGS" >/dev/null 2>&1
printf '# A fragment.\n' >"$TMP/seed-fragment"
{
  printf 'A\tVERSION\t%s\n' "$TMP/seed-version"
  printf 'A\tCHANGELOG.md\t%s\n' "$TMP/seed-changelog"
  printf 'A\tchangelog.d/README.md\t%s\n' "$TMP/seed-readme"
  printf 'A\tchangelog.d/10.md\t%s\n' "$TMP/seed-fragment"
} >"$TMP/frags.manifest"
with_stub scratch_commit "$FRAGS" main "a tree with fragments on it" \
  "$TMP/frags.manifest" >/dev/null 2>&1
check "the fragment list this case is about is genuinely there" 0 \
  "changelog.d/10.md" fragment_paths_of "$FRAGS" main
faults $'0\t2\tGET repos/*/git/trees/*\t404\tNot Found'
check "a fragment list that answers stale twice still reads back" 0 \
  "changelog.d/10.md" fragment_paths_of "$FRAGS" main
faults $'0\t99\tGET repos/*/git/trees/*\t404\tNot Found'
: >"$TMP/frags.out"
with_stub probe_fragment_paths "$FRAGS" main "$TMP/frags.out" \
  >"$TMP/frags.err" 2>&1
frags_rc=$?
check "a fragment list that never answers is a failed read, not an empty set" 0 "" \
  test "$frags_rc" -eq 1
check "the failed fragment read names its target" 0 \
  "the tree of main on $FRAGS did not read back after 10 attempts" \
  cat "$TMP/frags.err"
check "the failed fragment read leaves no comparable list" 0 "" \
  test ! -s "$TMP/frags.out"
faults
NOFRAGS="$SCRATCH_OWNER/nofragments-probe"
with_stub scratch_create_attempt "$NOFRAGS" >/dev/null 2>&1
printf 'A\tVERSION\t%s\n' "$TMP/seed-version" >"$TMP/nofrags.manifest"
with_stub scratch_commit "$NOFRAGS" main "a tree with no fragments on it" \
  "$TMP/nofrags.manifest" >/dev/null 2>&1
: >"$TMP/nofrags.out"
check "a read tree with no fragments is a successful empty list" 0 "" \
  with_stub probe_fragment_paths "$NOFRAGS" main "$TMP/nofrags.out"
check "the successful no-match creates an empty out-file" 0 "" \
  test -f "$TMP/nofrags.out"
check "the successful no-match out-file contains nothing" 0 "" \
  test ! -s "$TMP/nofrags.out"

stub_reset
mkdir -p "$TMP/prepare-work"
faults "0	2	GET repos/*/contents/*	404	Not Found"
check "a carrier read that answers stale twice still prepares the pin" 0 "" \
  with_stub fork_ref_prepare "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/prepare-work"
stub_reset
faults "0	99	GET repos/*/contents/*	404	Not Found"
with_stub fork_ref_prepare "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/prepare-work" \
  >"$TMP/prepare.out" 2>&1
prepare_rc=$?
check "a carrier read that never answers aborts the preparation" 0 "" \
  test "$prepare_rc" -eq 1
check "and names the read, not a pin the workflow supposedly lacks" 0 \
  "did not read back after 10 attempts" cat "$TMP/prepare.out"
check "it never claims no workflow carries CEREMONY_SELF_REF" 1 "" \
  grep -qF 'carries CEREMONY_SELF_REF' "$TMP/prepare.out"
stub_reset
faults "0	99	GET repos/*/git/trees/*	404	Not Found"
with_stub fork_ref_prepare "$FORK" "$FORK_REF" "$CAND_SHA" "$TMP/prepare-work" \
  >"$TMP/prepare-tree.out" 2>&1
prepare_tree_rc=$?
check "a carrier list that never reads back aborts the preparation too" 0 "" \
  test "$prepare_tree_rc" -eq 1
check "and says so as a failed read" 0 \
  "the tree of $FORK_REF on $FORK did not read back after 10 attempts" \
  cat "$TMP/prepare-tree.out"
check "never as a ref that carries no workflows" 1 "" \
  grep -qF 'carries no .github/workflows' "$TMP/prepare-tree.out"

# And the other half of that site, which the mode alone does not fix: what the
# probe RECORDS when the read is exhausted rather than merely slow. `probe_run`
# calls each probe as `"$fn" || status=$?`, which suppresses `set -e` inside
# it, so an unbranched `armed="$(scratch_version …)"` left `armed` empty and the
# row read "main reads '' after the ceremony" — a claim about main derived from
# a read that never happened, with drill_read's honest message on stderr where
# the record cannot see it. The row is the assertion here, and the old wording
# is asserted absent: it is the defect, not a detail of it.
stub_reset
green_scenario "$TMP/rearm.scenario"
faults "0	99	GET repos/$SCRATCH/contents/VERSION*	404	Not Found"
run_rehearsal "$TMP/rearm.scenario" --out "$TMP/rearm.md" >"$TMP/rearm.out" 2>&1
check "a re-arm read that never answers still leaves a record behind" 0 "" \
  test -s "$TMP/rearm.md"
# One assertion per re-arm site, because each is a separate call site and a
# family fixed at three of four is the same defect (#369 D6). The four rows
# differ by the door their probe drove, so a single faulted run grades all
# four independently: reverting any one branch to `armed="$(scratch_version
# …)"` reds the line that names it and leaves the other three green.
check "probe 1's row says the ceremony's re-arm read did not answer" 0 \
  "VERSION did not read back off main after the ceremony" cat "$TMP/rearm.md"
check "probe 5's row says the tag door's read did not answer" 0 \
  "VERSION did not read back off main after the tag door" cat "$TMP/rearm.md"
check "probe 7's row says the rc cut's re-arm read did not answer" 0 \
  "VERSION did not read back off main after the rc cut" cat "$TMP/rearm.md"
check "probe 8's row says the promotion's re-arm read did not answer" 0 \
  "VERSION did not read back off main after the promotion" cat "$TMP/rearm.md"
check "and not one of the four records a version it never read" 1 "" \
  grep -qF "main reads ''" "$TMP/rearm.md"
# The honest message is still emitted — on stderr, which is exactly where the
# old shape left it while the record kept the false claim.
check "the read names itself on stderr, where the record could not see it" 0 \
  "VERSION at $SCRATCH@main did not read back after 10 attempts" \
  cat "$TMP/rearm.out"

# A scored read must have happened. Each fault is aimed at one exact call in
# the green rehearsal, and each row is checked in isolation so restoring any
# one swallowed-status form restores its old wrong answer (#375 D2-D8).
faulted_probe_run() { # <name> <fault-rule> [unconsumed-scenario-line]
  local name="$1" rule="$2" unconsumed="${3:-}"
  stub_reset
  green_scenario "$TMP/$name.scenario"
  if [ -n "$unconsumed" ]; then
    awk -v n="$unconsumed" 'NR != n' "$TMP/$name.scenario" \
      >"$TMP/$name.scenario.tmp"
    mv "$TMP/$name.scenario.tmp" "$TMP/$name.scenario"
  fi
  faults "$rule"
  run_rehearsal "$TMP/$name.scenario" --out "$TMP/$name.md" \
    >"$TMP/$name.out" 2>&1
}

# Tree reads in the green call order: fixture check, probe 7 before, probe 7
# after, probe 8 after. Ten failures exhaust exactly one retrying read.
printf -v fragment_fault '1\t10\tGET repos/%s/git/trees/main*\t500\tInternal Server Error' "$SCRATCH"
faulted_probe_run fragment-before "$fragment_fault"
check "probe 7 reds when its before-fragment list never reads" 0 \
  "the fragment list did not read back at $SCRATCH@main before the rc cut" \
  probe_row "$TMP/fragment-before.md" 7
check "the before-read failure never claims the fragment set changed" 0 "" \
  row_lacks "$TMP/fragment-before.md" 7 'the fragment set changed'

printf -v fragment_fault '2\t10\tGET repos/%s/git/trees/main*\t500\tInternal Server Error' "$SCRATCH"
faulted_probe_run fragment-after "$fragment_fault"
check "probe 7 reds when its after-fragment list never reads" 0 \
  "the fragment list did not read back at $SCRATCH@main after the rc cut" \
  probe_row "$TMP/fragment-after.md" 7
check "the after-read failure never claims the fragment set changed" 0 "" \
  row_lacks "$TMP/fragment-after.md" 7 'the fragment set changed'

printf -v fragment_fault '3\t10\tGET repos/%s/git/trees/main*\t500\tInternal Server Error' "$SCRATCH"
faulted_probe_run fragment-promotion "$fragment_fault"
check "probe 8 reds when its fragment list never reads" 0 \
  "the fragment list did not read back at $SCRATCH@main after the promotion" \
  probe_row "$TMP/fragment-promotion.md" 8
check "the unread promotion list produces exactly one row problem" 0 "" \
  row_lacks "$TMP/fragment-promotion.md" 8 ';'
check "the unread promotion list never accuses the marker" 0 "" \
  row_lacks "$TMP/fragment-promotion.md" 8 \
    'changelog.d/README.md is gone after the promotion'
check "the unread promotion list never accuses leftovers" 0 "" \
  row_lacks "$TMP/fragment-promotion.md" 8 'fragments survived the promotion'

# Release endpoint call indices that search a completed list rather than count
# it: probes 1, 5, 6, 7 and 8. These are hard reads, so one failure is enough.
while IFS=$'\t' read -r release_name release_skip release_probe release_when release_old; do
  printf -v release_fault '%s\t1\tGET repos/%s/releases*\t500\tInternal Server Error' \
    "$release_skip" "$SCRATCH"
  faulted_probe_run "$release_name" "$release_fault"
  check "probe $release_probe reds when its release list fails" 0 \
    "the release list did not read back at $SCRATCH $release_when" \
    probe_row "$TMP/$release_name.md" "$release_probe"
  check "probe $release_probe does not restore its old release verdict" 0 "" \
    row_lacks "$TMP/$release_name.md" "$release_probe" "$release_old"
done <<'RELEASE_CASES'
release-1	3	1	after the ceremony	no '0.7.0' release exists
release-5	16	5	after the tag door ran	no '0.7.1' release exists
release-6	20	6	after the mismatched tag	a '9.9.9' release exists
release-7	24	7	after the rc cut	no '0.7.2-rc1' release exists
release-8	29	8	after the promotion	no '0.7.2' release exists
RELEASE_CASES

# The other side of the release-list split: a list that answered and genuinely
# lacks the release keeps the existing verdict byte-for-byte (#375 D6).
stub_reset
green_scenario "$TMP/release-absent.scenario"
awk 'NR == 2 { print "success\tnone"; next } { print }' \
  "$TMP/release-absent.scenario" >"$TMP/release-absent.scenario.tmp"
mv "$TMP/release-absent.scenario.tmp" "$TMP/release-absent.scenario"
faults
run_rehearsal "$TMP/release-absent.scenario" --out "$TMP/release-absent.md" \
  >"$TMP/release-absent.out" 2>&1
check "a read release list that lacks the tag keeps the existing accusation" 0 \
  "no '0.7.0' release exists after the ceremony" \
  probe_row "$TMP/release-absent.md" 1
check "a read release list is never reported as unread" 0 "" \
  row_lacks "$TMP/release-absent.md" 1 'release list did not read back'

# The fifth matching ref read is probe 2's setup read. Exhaust it, then prove
# the row, every later probe, disposal and the final record all survive. Probe
# 1 remains available for probe 4's deliberate re-run, keeping that later
# probe's own setup independent of the fault under test.
printf -v branch_fault '4\t10\tGET repos/%s/git/ref/heads/main\t500\tInternal Server Error' "$SCRATCH"
# Probe 2's branch read fails before its merge-door run, so its third queued
# scenario event is deliberately unconsumed and omitted from this fixture.
faulted_probe_run branch-sha "$branch_fault" 3
check "a branch-SHA failure becomes probe 2's read-named row" 0 \
  "the branch SHA did not read back at $SCRATCH@main before probe 2" \
  probe_row "$TMP/branch-sha.md" 2
check "a branch-SHA failure still leaves all eight rows" 0 "8" \
  bash -c 'grep -cE "^\| [1-8] \|" "$1"' _ "$TMP/branch-sha.md"
check "the last probe still runs after a branch-SHA failure" 0 "" \
  row_has "$TMP/branch-sha.md" 8 '| 8 |'
check "the branch-SHA failure still archives the scratch repo" 0 \
  "archived=true" cat "$TMP/branch-sha.md"
check "the branch-SHA failure still emits a valid record" 0 \
  "eight probe rows" record_check "$TMP/branch-sha.md"

# The disposal is the last thing the instrument does, and it sits after eight
# probes under `set -euo pipefail`. An exhausted read there used to be the end
# of the run — the record those probes filled, lost to a read. It is now a
# sentence in the record instead, and this is what says so.
stub_reset
green_scenario "$TMP/disposal.scenario"
faults "2	99	GET repos/$SCRATCH	500	Internal Server Error"
disposal_out="$(run_rehearsal "$TMP/disposal.scenario" --out "$TMP/disposal.md" 2>&1)"
disposal_rc=$?
check "a disposal read that never answers still emits the record" 0 "" \
  test "$disposal_rc" -eq 0
check "with all eight probe rows in it" 0 "probes passed 8/8, failed 0" \
  printf '%s\n' "$disposal_out"
check "and the record says the archive is unobserved rather than claiming it" 0 \
  "the read afterwards never answered" cat "$TMP/disposal.md"
check "it never reports an archive it did not observe" 1 "" \
  grep -qF 'a fresh read afterwards reported' "$TMP/disposal.md"
check "and it never says the archive did not land, which it did not measure" 1 "" \
  grep -qF 'the archive did not land' "$TMP/disposal.md"

# The other disposition, in the record this time (#369 D7). Same exhausted
# read, a different fact behind it: the flag answered, and what it said is
# that the repository is not archived. The two sentences are different
# strings, and the softer one may not be reached from the harder fact.
stub_reset
green_scenario "$TMP/unarchived.scenario"
export DRILL_STUB_ARCHIVE_LAG=99
unarchived_out="$(run_rehearsal "$TMP/unarchived.scenario" --out "$TMP/unarchived.md" 2>&1)"
unarchived_rc=$?
unset DRILL_STUB_ARCHIVE_LAG
check "a disposal that reads back false still emits the record" 0 "" \
  test "$unarchived_rc" -eq 0
check "with all eight probe rows in it too" 0 "probes passed 8/8, failed 0" \
  printf '%s\n' "$unarchived_out"
check "and the record says the archive did not land" 0 \
  "the archive did not land, and the repository is still live" \
  cat "$TMP/unarchived.md"
check "quoting the flag it actually read" 0 "archived=false private=false" \
  cat "$TMP/unarchived.md"
check "it never files an answered read as one that never answered" 1 "" \
  grep -qF 'never answered' "$TMP/unarchived.md"

# ---------------------------------------------------------------------------
# The round trip (#373): the record graded by RE-RENDER rather than by shape.
#
# The measurement this section exists to invert is @claude-bot-andresmgsl's,
# from the 0.7.0 panel round: a copy of the committed record with one
# hand-added sentence in its preamble passes `record_check`, exit 0. Every
# must-fail case below is therefore asserted twice — that the shape check
# still passes it, and that the round trip does not — because a check which
# passes everything would pass these too, and only the pair measures the gap.
#
# Every mutation is taken from the 0.7.0 FIXTURE and never from
# `drills/0.7.0.md` (D6, D7). The shipped record fails before any mutation is
# applied — it is an emission at a superseded render shape — so a mutation of
# it would pass for the wrong reason and prove nothing. That is why the
# unmutated fixture is asserted to pass in this same suite, immediately below.
# ---------------------------------------------------------------------------
FIX="$ROOT/test/fixtures/drill-record-0.7.0.golden.md"
SHIPPED="$ROOT/drills/0.7.0.md"

# -- must pass --------------------------------------------------------------
check "the 0.7.0 fixture round-trips byte-identically — the base of every mutation" 0 \
  "byte-identical to record_render's output" record_roundtrip "$FIX"
# The fixture's provenance, which is what makes it a re-render of a real
# ceremony's measurements rather than an authoring (D7). The diff against the
# shipped record must be the renderer's moves and nothing else. NOTE: D6 named
# three renderer changes and this diff showed two hunks — `eb15988`'s
# `$visibility` substitution renders the word `private` here, which is the
# same word the literal it replaced wrote, so it is present and invisible. The
# assertion is on the diff's exact contents for exactly that reason: a hunk
# count would be measuring the coincidence.
#
# #484 is the THIRD renderer move this block records, and it adds the third
# hunk: `## Known gaps`, rendered on every emission and empty here. Two
# details of the want-block below are measured at this head rather than
# reasoned about. First, the count is 10 rather than 5. Second, the blank line
# and the `Because this repo is private` line swapped places inside the second
# hunk — the FIXTURE did not move (its diff against the pre-#484 fixture is
# the new section and nothing else), `diff` simply chose the other of two
# equally minimal alignments once the file grew. Re-measure both if a fourth
# renderer move lands; neither is derivable from the change that caused it.
diff "$SHIPPED" "$FIX" | grep '^[<>]' >"$TMP/fixture-provenance.txt"
cat >"$TMP/fixture-provenance.want" <<'PROV'
< Disposable **private** repo `cndgrr/ceremony-drill-0.7.0-a3`, created 2026-08-10T16:18:50Z. It carries the
> Attempt **`3`** used disposable **private** repo `cndgrr/ceremony-drill-0.7.0-a3`, created
> 2026-08-10T16:18:50Z. It carries the
> Because this repo is private, its run links resolve only for the repo owner.
> 
> 
> ## Known gaps
> 
> None declared: every claim this record makes is a probe row's, and nothing was
> declared outside them.
PROV
check "the fixture differs from the shipped record by the renderer's moves alone" 0 "" \
  diff -u "$TMP/fixture-provenance.want" "$TMP/fixture-provenance.txt"
check "every other line of the fixture is the shipped record's own measurement" 0 "" \
  bash -c 'diff "$1" "$2" | grep -c "^[<>]" | grep -qx 10' _ "$SHIPPED" "$FIX"

check "a freshly rendered record from the stubbed rehearsal round-trips" 0 \
  "byte-identical to record_render's output" record_roundtrip "$TMP/emitted.md"
# The private leg renders a paragraph the public one does not, so it is its
# own round trip and not a rerun of the previous case.
check "the private emission round-trips too" 0 \
  "byte-identical to record_render's output" record_roundtrip "$TMP/private.md"
check "an aborted probe's record round-trips, dash and all" 0 \
  "byte-identical to record_render's output" record_roundtrip "$TMP/one-aborted.md"

# A failed drill is a valid record, and its conclusion carries the counts the
# mutation below edits. Derived from the FIXTURE's own inputs — parsed back
# out of it, one verdict flipped, re-rendered — so the count case is a
# mutation of the fixture's data and not of a record from somewhere else.
record_parse "$FIX" "$TMP/fx-ctx.tsv" "$TMP/fx-probes.tsv" "$TMP/fx-setup.tsv" \
  "$TMP/fx-gaps.tsv"
check "the fixture's own inputs parse back out of it" 0 "" \
  test -s "$TMP/fx-probes.tsv"
sed 's/\tPASS\t1\t1\t1\t1\trefused at decide/\tFAIL\t1\t2\t1\t1\ttags moved 1→2, expected a delta of 0/' \
  "$TMP/fx-probes.tsv" >"$TMP/fx-failed.tsv"
record_render "$TMP/fx-ctx.tsv" "$TMP/fx-failed.tsv" "$TMP/fx-setup.tsv" \
  "$TMP/fx-gaps.tsv" >"$TMP/rt-failed.md"
check "a failed drill's record round-trips — a valid record is still an emission" 0 \
  "byte-identical to record_render's output" record_roundtrip "$TMP/rt-failed.md"

# -- the mutation floor -----------------------------------------------------
# One sentence added to the preamble. The prose there is computed from the
# probe rows, so the render will not write this line back and the round trip
# reports it — while the shape check, which greps that prose rather than
# deriving it, sees nothing wrong at all.
sed '7a A reviewer added this sentence by hand.' "$FIX" >"$TMP/rt-preamble.md"
check "the mutation floor: the shape check passes a hand-added sentence" 0 \
  "eight probe rows" record_check "$TMP/rt-preamble.md"
check "the round trip fails it" 1 "A reviewer added this sentence by hand." \
  record_roundtrip "$TMP/rt-preamble.md"
check "and names the line it is on" 1 "first difference at line 8" \
  record_roundtrip "$TMP/rt-preamble.md"

# A reordered context field: the disposal sentence moved above the rc-ladder
# paragraph. The parse finds each field by its own sentence and does not care
# what order they come in, so this is caught by the RE-RENDER putting them
# back — which is the point. The file must be what the renderer writes, not
# merely something the parse can read.
{
  sed -n '1,25p' "$FIX"
  sed -n '33p' "$FIX"
  sed -n '26,32p' "$FIX"
  sed -n '34,$p' "$FIX"
} >"$TMP/rt-reordered.md"
check "a reordered context field still passes the shape check" 0 \
  "eight probe rows" record_check "$TMP/rt-reordered.md"
check "the round trip fails a reordered context field" 1 \
  "first difference at line 26" record_roundtrip "$TMP/rt-reordered.md"

# The same, one field deeper: the candidate ref and the candidate SHA swapped
# in the run sentence. Nothing local catches it — both are free-form strings —
# but the render writes the SHA twice, and the second copy no longer follows
# from the first.
sed -e '4s/`build\/367-cut-0-7-0`/`e6caf31d2c102532efa897ea52903b8a79dd6a65`/' \
  -e '5s/`e6caf31d2c102532efa897ea52903b8a79dd6a65`/`build\/367-cut-0-7-0`/' \
  "$FIX" >"$TMP/rt-swapped.md"
check "the round trip fails a ref and a SHA swapped in the run sentence" 1 \
  "first difference at line" record_roundtrip "$TMP/rt-swapped.md"

# An edited run ID, INCONSISTENTLY (D8): `record_run_cell` builds the link
# text and the URL out of one variable, so a record where they disagree is not
# its output — and that is what a hand edit to a run ID leaves behind. Each
# side is asserted alone, because "an edited run ID fails" would otherwise be
# read as more than it proved. It is caught in the PARSE, which is a better
# diagnostic than the same edit surfacing as a diff.
sed '66s/\[31408496126\]/[31409999999]/' "$FIX" >"$TMP/rt-runid-text.md"
check "an edited run ID passes the shape check, which only greps for one" 0 \
  "eight probe rows" record_check "$TMP/rt-runid-text.md"
check "the round trip fails a run ID edited in the link text alone" 1 \
  "link text (31409999999) and its URL's run ID (31408496126) disagree" \
  record_roundtrip "$TMP/rt-runid-text.md"
check "and names the line that defeated the parse" 1 \
  "rt-runid-text.md:66" record_roundtrip "$TMP/rt-runid-text.md"
sed '66s|runs/31408496126|runs/31409999999|' "$FIX" >"$TMP/rt-runid-url.md"
check "the round trip fails a run ID edited in the URL alone" 1 \
  "link text (31408496126) and its URL's run ID (31409999999) disagree" \
  record_roundtrip "$TMP/rt-runid-url.md"
check "and names that line too" 1 \
  "rt-runid-url.md:66" record_roundtrip "$TMP/rt-runid-url.md"
# The boundary, pinned rather than left to be discovered (D8): a run ID
# rewritten on BOTH sides is data, not authorship. The file is then exactly
# what the renderer emits for that data, and no self-describing record can say
# otherwise — D4 rejects the committed-inputs design that could. The run link
# is what a reader checks that against, and drills/README.md says so.
sed '66s/31408496126/31409999999/g' "$FIX" >"$TMP/rt-runid-both.md"
check "a run ID rewritten on both sides is data, and the round trip says so" 0 \
  "byte-identical to record_render's output" record_roundtrip "$TMP/rt-runid-both.md"

# A changed count in the conclusion. The conclusion is derived from the probe
# rows, so the render writes the count the rows imply and the edit cannot
# survive being regenerated.
check "the fixture's failed variant states the count that is about to be edited" 0 \
  "Not established: 1 of the eight" cat "$TMP/rt-failed.md"
sed 's/Not established: 1 of the eight/Not established: 3 of the eight/' \
  "$TMP/rt-failed.md" >"$TMP/rt-count.md"
check "a changed conclusion count still passes the shape check" 0 \
  "eight probe rows" record_check "$TMP/rt-count.md"
check "the round trip fails a changed conclusion count" 1 \
  "Not established: 3 of the eight" record_roundtrip "$TMP/rt-count.md"

# A truncated record: the probe table cut in half. The rows that remain still
# parse, and the render then writes the conclusion those four rows imply —
# four claims and four "nothing established" lines — which is not this file.
grep -vE '^\| [5678] \|' "$FIX" >"$TMP/rt-halved.md"
check "a halved probe table reds the shape check as it always did" 1 \
  "the probe table has 4 rows, expected 8" record_check "$TMP/rt-halved.md"
check "the round trip fails a halved probe table" 1 \
  "first difference at line" record_roundtrip "$TMP/rt-halved.md"

# -- D5: a valid shape whose parse fails ------------------------------------
# The failure mode that would quietly re-open the hole is "unparseable
# therefore fine". Both cases below pass `record_check` — they are shaped like
# records — and both are refused by the parse, by line number.
check "a pipe in a probe row's note passes the shape check" 0 "eight probe rows" \
  bash -c 'sed "66s/refused at decide/refused at decide | by the door/" "$1" >"$2"
    source "$3/drill/lib/probes.sh"; source "$3/drill/lib/record.sh"
    record_check "$2"' _ "$FIX" "$TMP/rt-pipe.md" "$ROOT"
check "the parse refuses it, naming the line and the cell count" 1 \
  "the probe row has 7 cells, expected 6" record_roundtrip "$TMP/rt-pipe.md"
check "an unparseable record is a failure and never a skip" 1 \
  "cannot be parsed back into the inputs that would render it" \
  record_roundtrip "$TMP/rt-pipe.md"
# A count column turned into prose: shaped like a table, not a measurement.
sed '68s/| 1 → 2 | 1 → 2 |/| many | more |/' "$FIX" >"$TMP/rt-prose-counts.md"
check "the parse refuses a count cell that is prose, naming the line" 1 \
  "rt-prose-counts.md:68: the tags cell is not a before/after pair" \
  record_roundtrip "$TMP/rt-prose-counts.md"
# A record whose sections are gone entirely is refused before any line number
# can be meaningful, and says which heading it wanted.
head -n 62 "$FIX" >"$TMP/rt-decapitated.md"
check "a record missing a whole section names the heading it wanted" 1 \
  "no '## Setup, and the runs that are not probes' heading" \
  record_roundtrip "$TMP/rt-decapitated.md"
check "a record that is not one at all is refused, not skipped" 1 \
  "too short to be a rendered record" \
  bash -c 'printf "hello\n" >"$1"
    source "$2/drill/lib/probes.sh"; source "$2/drill/lib/record.sh"
    record_roundtrip "$1"' _ "$TMP/rt-notarecord.md" "$ROOT"

# -- D6: no grandfathering --------------------------------------------------
# The shipped 0.7.0 record is an emission at a SUPERSEDED render shape: three
# commits moved `## Where` after it was committed, and #484 added a section
# after that. It is not re-rendered to match (a guard never rewrites the
# evidence it grades) and it is not excused either — `record_roundtrip`
# carries no version gate and no shape exemption, so this failure IS the
# criterion. The fixture above is what carries this record's measurements
# forward.
#
# What the failure SAYS moved with #484, and the assertions moved with it: the
# parse locates every section heading before it reads a single field, so a
# record predating `## Known gaps` is now refused one step earlier than the
# `## Where` line it also disagrees about. The diagnosis names the heading it
# wanted, which is the same class of answer and no less precise — and #373's
# own "a record missing a whole section names the heading it wanted" case,
# below, is what pinned that shape in the first place.
check "the shipped 0.7.0 record is classified an emission, not excused as prose" 0 \
  "" bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_class "$2"; [ "$RECORD_CLASS" = emission ]' _ "$ROOT" "$SHIPPED"
check "and it FAILS the round trip — a superseded render shape is not grandfathered" 1 \
  "no '## Known gaps' heading" record_roundtrip "$SHIPPED"
check "the failure says it is not a rendered record, never that it is fine" 1 \
  "not a rendered record" record_roundtrip "$SHIPPED"
check "an unparseable shipped record is a failure and never a skip" 1 \
  "cannot be parsed back into the inputs that would render it" \
  record_roundtrip "$SHIPPED"

# -- D9: the class is read from the record, and it fails closed -------------
# Two of drills/README.md's three record shapes are hand-written by design, so
# the step classifies before it grades. The discriminator is the record's own
# declaration — never a path list or a version list someone must maintain.
check "a doors-unchanged record declares a scope ruling and is out of scope" 0 "" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_class "$2"; [ "$RECORD_CLASS" = scope-ruling ]' _ "$ROOT" "$ROOT/drills/0.6.3.md"
check "the emission class is declared by the instrument's own run sentence" 0 "" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_class "$2"; [ "$RECORD_CLASS" = emission ]' _ "$ROOT" "$FIX"
# Fails closed, both directions of ambiguity. A record declaring NEITHER shape
# is graded as an emission — `drills/0.1.0.md` is the standing instance, from
# before either convention existed — and so is one declaring BOTH.
check "a record declaring neither shape is graded as an emission" 0 \
  "declares NEITHER shape" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_class "$2"; printf "%s: %s\n" "$RECORD_CLASS" "$RECORD_CLASS_WHY"
    [ "$RECORD_CLASS" = emission ]' _ "$ROOT" "$ROOT/drills/0.1.0.md"
# Appended rather than inserted, so the case isolates what it is about: the
# heading lands past every section the record has, rather than displacing a
# line some field lookup depends on. A record that declared both AND broke a
# field's parse would fail for two reasons and measure neither.
#
# #484 moved WHERE the appended heading lands: the conclusion is no longer
# last, so it falls inside `## Known gaps` and the parse refuses it by line
# number instead of the re-render reporting it as a difference. The assertion
# is unchanged and so is what it measures — a record declaring both shapes is
# graded as an emission and fails.
{
  cat "$FIX"
  printf '\n## Scope ruling — doors unchanged, no disposable-repo rehearsal\n'
} >"$TMP/rt-both-classes.md"
check "a record declaring both shapes is graded as an emission too" 0 \
  "declares BOTH shapes" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_class "$2"; printf "%s: %s\n" "$RECORD_CLASS" "$RECORD_CLASS_WHY"
    [ "$RECORD_CLASS" = emission ]' _ "$ROOT" "$TMP/rt-both-classes.md"
check "and being graded as an emission, it fails the round trip" 1 \
  "## Scope ruling" record_roundtrip "$TMP/rt-both-classes.md"

# -- the CI guard, keyed on the tree's version (#373 D3, D9) ----------------
# The step decides in a file a test can drive, so every branch is asserted
# here rather than only in a workflow run nobody can rehearse.
GUARD="$ROOT/.github/scripts/record-roundtrip.sh"
guard_tree() { # <name> <version> [record-source]
  mkdir -p "$TMP/guard-$1/drills"
  printf '%s\n' "$2" >"$TMP/guard-$1/VERSION"
  [ -z "${3-}" ] || cp "$3" "$TMP/guard-$1/drills/$2.md"
}
guard_tree dev 0.7.1-dev
check "a -dev tree skips the round trip" 0 \
  "version '0.7.1-dev' is a development tree" bash "$GUARD" "$TMP/guard-dev"
# The skip is visible in the step's output rather than silent: an operator
# reading a green log must be able to tell a guard that passed from one that
# decided the tree was not its business.
check "and says out loud that it decided the tree was not its business" 0 \
  "nothing to grade; only ceremony trees ship a record" bash "$GUARD" "$TMP/guard-dev"
guard_tree bare 9.9.9 "$FIX"
check "a bare-version tree runs the round trip and passes a real emission" 0 \
  "graded as an emission" bash "$GUARD" "$TMP/guard-bare"
guard_tree edited 9.9.9 "$TMP/rt-preamble.md"
check "a bare-version tree fails the job when the round trip fails" 1 \
  "A reviewer added this sentence by hand." bash "$GUARD" "$TMP/guard-edited"
check "and says the unblock is to re-run the instrument, not to edit harder" 1 \
  "The unblock is not to edit the record until it passes" \
  bash "$GUARD" "$TMP/guard-edited"
# D9's standing instance: the release immediately before 0.7.0 is a
# doors-unchanged record, and as this guard was first specced it would have
# red a legitimate release.
guard_tree ruling 0.6.3 "$ROOT/drills/0.6.3.md"
check "a doors-unchanged release passes the step without being graded" 0 \
  "is NOT" bash "$GUARD" "$TMP/guard-ruling"
check "and the step says which branch it took" 0 \
  "it declares a scope ruling" bash "$GUARD" "$TMP/guard-ruling"
check "and says why the round trip does not apply to it" 0 \
  "the only shape with a renderer to re-run" bash "$GUARD" "$TMP/guard-ruling"
guard_tree unclassifiable 9.9.9 "$ROOT/drills/0.1.0.md"
check "an unclassifiable record is graded as an emission, not skipped" 1 \
  "declares NEITHER shape" bash "$GUARD" "$TMP/guard-unclassifiable"
guard_tree missing 9.9.9
check "a bare-version tree with no record at all fails" 1 \
  "there is no drill" bash "$GUARD" "$TMP/guard-missing"
check "a tree with no version source is an error, never a silent pass" 1 \
  "cannot read the version" bash "$GUARD" "$TMP/guard-nonesuch"

# ---------------------------------------------------------------------------
# `## Known gaps` (#484) — the sixth section, and the first thing in the
# record that is DECLARED rather than measured.
#
# The distinction the section exists to hold is D3's: a gap is coverage no
# probe drives at all, never a probe that ran and failed. The failed probe
# already has a row, a preamble sentence and the not-established tail, and all
# three are asserted elsewhere in this suite; nothing below softens any of them.
# ---------------------------------------------------------------------------
# The empty state first, on the green public emission the suite already has.
check "a fresh emission carries the section" 0 "## Known gaps" cat "$TMP/emitted.md"
check "with the none-declared sentence when nothing was declared" 0 \
  "None declared: every claim this record makes is a probe row's" cat "$TMP/emitted.md"
check "and the section is the record's LAST" 0 "## Known gaps" \
  bash -c 'grep "^## " "$1" | tail -n 1' _ "$TMP/emitted.md"
check "an emission with no gaps declares none rather than omitting the section" 1 "" \
  grep -qE '^- \*\*' <(sed -n '/^## Known gaps$/,$p' "$TMP/emitted.md")

# Two gaps, through the CLI and the stub — the whole path, not record_render
# alone: `--gap` has to survive argument parsing, the TSV and the render.
stub_reset
green_scenario "$TMP/gaps.scenario"
gaps_out="$(run_rehearsal "$TMP/gaps.scenario" --out "$TMP/gaps.md" \
  --gap 'the dispatch entrance|no probe drives release.yml at its workflow_dispatch entrance, so the push half is what this rehearsal establishes' \
  --gap 'consumer callers|nothing here drives a consumer repository running the reusable workflow from its own tree' 2>&1)"
gaps_rc=$?
check "a rehearsal with two declared gaps completes" 0 "" test "$gaps_rc" -eq 0
check "and still runs every probe" 0 "probes passed 8/8, failed 0" \
  printf '%s\n' "$gaps_out"
sed -n '/^## Known gaps$/,$p' "$TMP/gaps.md" | grep '^- ' >"$TMP/gaps.lines"
cat >"$TMP/gaps.want" <<'GAPS'
- **the dispatch entrance** — no probe drives release.yml at its workflow_dispatch entrance, so the push half is what this rehearsal establishes
- **consumer callers** — nothing here drives a consumer repository running the reusable workflow from its own tree
GAPS
check "both gaps render, one line each, verbatim and in declaration order" 0 "" \
  diff -u "$TMP/gaps.want" "$TMP/gaps.lines"
check "a declared gap never re-wraps, however long the body" 0 "2" \
  bash -c 'wc -l < "$1" | tr -d " "' _ "$TMP/gaps.lines"
check "the declared record carries the preamble, not the none sentence" 1 "" \
  grep -qF 'None declared' "$TMP/gaps.md"
check "a record with declared gaps round-trips" 0 \
  "byte-identical to record_render's output" record_roundtrip "$TMP/gaps.md"
check "and passes the shape check" 0 "eight probe rows" record_check "$TMP/gaps.md"

# The fourth TSV: the parse hands back exactly the pairs that were declared,
# in order. That is what makes the amend below a re-render rather than an edit.
record_parse "$TMP/gaps.md" "$TMP/g-ctx.tsv" "$TMP/g-probes.tsv" "$TMP/g-setup.tsv" \
  "$TMP/g-gaps.tsv"
printf '%s\t%s\n%s\t%s\n' \
  'the dispatch entrance' 'no probe drives release.yml at its workflow_dispatch entrance, so the push half is what this rehearsal establishes' \
  'consumer callers' 'nothing here drives a consumer repository running the reusable workflow from its own tree' \
  >"$TMP/g-gaps.want"
check "record_parse writes the gaps back out as its fourth TSV, in order" 0 "" \
  diff -u "$TMP/g-gaps.want" "$TMP/g-gaps.tsv"
check "an emission with no gaps parses to an empty fourth TSV" 0 "" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_parse "$2" "$3/e-ctx.tsv" "$3/e-probes.tsv" "$3/e-setup.tsv" "$3/e-gaps.tsv"
    [ ! -s "$3/e-gaps.tsv" ]' _ "$ROOT" "$TMP/emitted.md" "$TMP"

# Nothing else moves. The gaps are their own section and change no other, so
# the two emissions above are byte-identical everywhere above the heading — a
# renderer change that quietly re-flowed an existing section would red every
# consumer's stale record for the wrong reason.
check "declaring a gap moves no other section of the record" 0 "" \
  bash -c 'diff <(sed "/^## Known gaps$/,\$d" "$1") <(sed "/^## Known gaps$/,\$d" "$2")' \
  _ "$TMP/emitted.md" "$TMP/gaps.md"

# -- D6's refusals, every one of them, each before the scratch repo exists ---
# The refusal is at argument-parse time on purpose: a typo rejected after the
# repo existed would have burned a scratch name to say so.
gap_refusal() { # <spec…> — a rehearsal that must die on its --gap
  stub_reset
  green_scenario "$TMP/gap-refusal.scenario"
  local -a args=()
  local spec
  for spec in "$@"; do args+=(--gap "$spec"); done
  run_rehearsal "$TMP/gap-refusal.scenario" --out "$TMP/gap-refusal.md" "${args[@]}"
}
check "a gap with no separator is refused" 1 "has no '|'" gap_refusal 'just a title'
check "an empty title is refused" 1 "has an empty title" gap_refusal '|a body'
check "an empty body is refused" 1 "has an empty body" gap_refusal 'a title|'
check "a TAB anywhere in a gap is refused" 1 "carries a TAB" \
  gap_refusal "$(printf 'a\ttitle|a body')"
check "a newline in a gap is refused" 1 "carries a newline" \
  gap_refusal "$(printf 'a title|a\nbody')"
check "leading whitespace in a title is refused" 1 "leading or trailing whitespace in its title" \
  gap_refusal ' a title|a body'
check "trailing whitespace in a title is refused" 1 "leading or trailing whitespace in its title" \
  gap_refusal 'a title |a body'
check "leading whitespace in a body is refused" 1 "leading or trailing whitespace in its body" \
  gap_refusal 'a title| a body'
check "trailing whitespace in a body is refused" 1 "leading or trailing whitespace in its body" \
  gap_refusal 'a title|a body '
check "two gaps sharing a title are refused" 1 "which an earlier --gap already declared" \
  gap_refusal 'same title|one' 'same title|two'
# Each refusal names WHICH gap defeated it, so a run declaring several does not
# leave its author grepping. Three gaps here and the duplicate is the THIRD:
# the offender is the second `same`, not the first, because the first is what
# it collides with. A refusal naming #2 would be pointing at the innocent one.
check "the refusal names which gap defeated it" 1 "--gap #3" \
  gap_refusal 'first|one' 'same|two' 'same|three'
check "a body may carry the separator; the split is at the FIRST one" 1 "--gap #2" \
  gap_refusal 'a title|a body | with a pipe in it' 'a title|and a duplicate'
# The record's OWN separator in a title, which is the refusal round 1 found
# missing (@codex-bot-andresmgsl, @claude-bot-andresmgsl). `record_parse` cuts
# at the first `** — `, so this title would come back as `alpha` and the round
# trip could not tell: re-rendering the re-cut pair recreates the same bytes.
# The asymmetry is the point and both halves are pinned — the title is refused,
# the identical sequence in a BODY is not, and the second case proves the
# refusal is not just matching the substring anywhere in the argument.
check "a title carrying the record's own separator is refused" 1 \
  "carries '** — ' in its TITLE" gap_refusal 'alpha** — beta|gamma'
check "and the refusal names which gap defeated it" 1 "--gap #2" \
  gap_refusal 'fine|one' 'alpha** — beta|gamma'
check "a BODY carrying the same separator is accepted" 0 "" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    printf "a title\ta body ** — with the separator in it\n" >"$2"
    record_gap_rows "$2" | grep -qxF -- "- **a title** — a body ** — with the separator in it"' \
  _ "$ROOT" "$TMP/gap-body-sep.tsv"
# And the LIBRARY refuses it too, driven straight through `record_render` with
# no CLI in the way. The CLI refusal is where an author wants to hear it; this
# is where the invariant lives, because `record_gap_rows` is the only thing
# that ever writes a gap line and `record_parse` cuts at the first separator.
# A guard in `gap_add` alone would make render/parse inversion a property of
# one argument parser rather than of the pair.
printf 'alpha** — beta\tgamma\n' >"$TMP/gap-ambiguous.tsv"
check "record_gap_rows refuses such a title with no CLI in the way" 1 \
  "carries the title/body separator" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_gap_rows "$2"' _ "$ROOT" "$TMP/gap-ambiguous.tsv"
check "and record_render propagates it instead of returning the record" 1 "" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_render "$2" "$3" "$4" "$5" >/dev/null 2>&1' \
  _ "$ROOT" "$TMP/g-ctx.tsv" "$TMP/g-probes.tsv" "$TMP/g-setup.tsv" "$TMP/gap-ambiguous.tsv"
# The measurement behind "before the scratch repo is created": the last
# refusal above ran under the stub, and the stub records every call it is
# asked to make.
#
# It is asserted for the last refusal only, and that is enough because the
# property is STRUCTURAL rather than per-case: `gap_add` runs inside the
# argument-parsing loop at the top of `drill/rehearsal.sh`, which completes
# before the first remote read — so no ordering of `--gap` arguments can put a
# refusal after a call. Each case above additionally calls `stub_reset`, so
# the log read here is the last case's alone
# (@claude-bot-andresmgsl, round 1).
check "no gh call was made before the refusal" 0 "0" \
  bash -c 'wc -l < "$1" | tr -d " "' _ "$TMP/state/calls"
check "and no scratch repo was created" 1 "" test -d "$TMP/state/$(san "$SCRATCH")"

# -- D8: record_check grades the section at emission time --------------------
# A malformed section reds where it is WRITTEN rather than at the next cut.
sed 's/^- \*\*the dispatch entrance\*\* — .*$/- **the dispatch entrance** — /' \
  "$TMP/gaps.md" >"$TMP/gap-nobody.md"
check "record_check reds a gap line with no body" 1 "carry no title or no body" \
  record_check "$TMP/gap-nobody.md"
sed 's/^- \*\*the dispatch entrance\*\* — /- ** — /' "$TMP/gaps.md" >"$TMP/gap-notitle.md"
check "record_check reds a gap line with no title" 1 "carry no title or no body" \
  record_check "$TMP/gap-notitle.md"
# Neither sentence nor line: the section is there and says nothing at all.
awk '/^## Known gaps$/ { print; print ""; exit } { print }' "$TMP/gaps.md" \
  >"$TMP/gap-silent.md"
check "record_check reds a section carrying neither the sentence nor a gap" 1 \
  "carries neither the none-declared sentence nor a gap line" \
  record_check "$TMP/gap-silent.md"
check "and reds a record with no such section at all" 1 "has no '## Known gaps' section" \
  bash -c 'sed "/^## Known gaps$/,\$d" "$1" >"$2"
    source "$3/drill/lib/probes.sh"; source "$3/drill/lib/record.sh"
    record_check "$2"' _ "$TMP/gaps.md" "$TMP/gap-none-at-all.md" "$ROOT"

# The empty-state sentence is graded WHOLE, and it is hard-wrapped across two
# lines. Grading its first line alone greened a section carrying half a
# sentence and no gap line — the exact shape D8 exists to red
# (@codex-bot-andresmgsl, round 2). All three mutilations below leave the
# first line intact, so each one passed before the fix.
#
# `$TMP/emitted.md` is the no-gap emission, so its section is the sentence and
# nothing else; the failure has nowhere else to hide.
sed '/^declared outside them\.$/d' "$TMP/emitted.md" >"$TMP/gap-half-sentence.md"
check "record_check reds a TRUNCATED empty-state sentence" 1 \
  "carries neither the none-declared sentence nor a gap line" \
  record_check "$TMP/gap-half-sentence.md"
# The other end of the same sentence: the tail alone is not the claim either.
sed "/^None declared: every claim this record makes is a probe row's, and nothing was$/d" \
  "$TMP/emitted.md" >"$TMP/gap-tail-only.md"
check "and reds one whose FIRST line is the missing half" 1 \
  "carries neither the none-declared sentence nor a gap line" \
  record_check "$TMP/gap-tail-only.md"
# Both lines present, no longer contiguous. This is what the newline-bracketed
# match buys over two independent searches: the sentence is a wrapped whole,
# not two lines that happen to be in the section.
awk '/^declared outside them\.$/ { print ""; print; next } { print }' \
  "$TMP/emitted.md" >"$TMP/gap-split-sentence.md"
check "and reds one whose two lines are no longer contiguous" 1 \
  "carries neither the none-declared sentence nor a gap line" \
  record_check "$TMP/gap-split-sentence.md"
# A line CONTAINING the sentence is not the sentence. The old check was a
# substring grep, so quoting the first line inside a longer one satisfied it;
# the bracketed match is line-exact, which is the second thing it buys.
sed "s/^None declared: /> quoting the record: None declared: /" \
  "$TMP/emitted.md" >"$TMP/gap-quoted-sentence.md"
check "and reds one where the sentence is only CONTAINED in a longer line" 1 \
  "carries neither the none-declared sentence nor a gap line" \
  record_check "$TMP/gap-quoted-sentence.md"
# The must-NOT-fire half, so the four above cannot be satisfied by a check
# that reds everything: the untouched emission still passes.
check "while the untouched emission still passes the shape check" 0 \
  "eight probe rows" record_check "$TMP/emitted.md"

# -- must-fail: the section list stays CLOSED --------------------------------
# #484 adds one member to it and does not open it. A seventh heading the
# renderer never wrote lands inside the last section, where the parse refuses
# it by line number.
{
  cat "$TMP/gaps.md"
  printf '\n## Something\n\nA section no renderer writes.\n'
} >"$TMP/rt-seventh.md"
check "a section the renderer did not write is refused, by line" 1 \
  "not a gap line, and not one of the section's own sentences" \
  record_roundtrip "$TMP/rt-seventh.md"
# Measured off the mutated file rather than hard-coded: the line moves with
# every earlier section, and a stale literal here would pass on the wrong line.
seventh_line="$(grep -n '^## Something' "$TMP/rt-seventh.md" | cut -d: -f1)"
check "and the refusal names the line it is on" 1 "rt-seventh.md:$seventh_line" \
  record_roundtrip "$TMP/rt-seventh.md"

# -- must-fail: a mangled gap line ------------------------------------------
# The separator dropped. The parse must RED by line number rather than
# silently read an empty body and re-render a record it invented.
sed 's/^- \*\*consumer callers\*\* — /- **consumer callers** /' "$TMP/gaps.md" \
  >"$TMP/rt-mangled.md"
check "a gap line with no separator is a parse failure, not an empty body" 1 \
  'the gap line has no `** — ` between its title and its body' \
  record_roundtrip "$TMP/rt-mangled.md"
mangled_line="$(grep -n '^- \*\*consumer callers\*\* ' "$TMP/rt-mangled.md" | cut -d: -f1)"
check "and it names the line rather than the section" 1 "rt-mangled.md:$mangled_line" \
  record_roundtrip "$TMP/rt-mangled.md"

# -- must-fail: a re-wrapped gap --------------------------------------------
# D5's decision, held by a case, so the next reader who wants pretty output
# finds out here why it was refused: a wrap is a transformation the parse
# would have to invert exactly, and one disagreeing by a single space would
# red the round trip on a record nobody edited.
awk '/^- \*\*consumer callers\*\* — / {
       print "- **consumer callers** — nothing here drives a consumer"
       print "repository running the reusable workflow from its own tree"
       next
     } { print }' "$TMP/gaps.md" >"$TMP/rt-wrapped.md"
check "a hard-wrapped gap body is refused" 1 \
  "not a gap line, and not one of the section's own sentences" \
  record_roundtrip "$TMP/rt-wrapped.md"

# -- D4's honest cost, PINNED rather than left unstated ----------------------
# The round trip cannot tell a declared gap from a typed one: the parse reads
# gap lines back out and the render writes them again verbatim. That is not a
# hole nobody noticed — it is accepted, with its reason, in drills/README.md,
# and this case is what stops a later reader mistaking it for one. #373 D4
# already priced the only cure, committing the render inputs beside the
# record, and rejected it. The reason it is safe is monotonicity: a gap entry
# only ever subtracts from what the record claims, and no wording of one can
# manufacture a probe that passed.
{
  sed '/^## Known gaps$/,$d' "$TMP/emitted.md"
  printf '## Known gaps\n\n'
  printf 'Declared before the run and rendered here as given. Each names something no\n'
  printf 'probe drives, so the rehearsal establishes nothing about it; a probe that ran\n'
  printf 'and failed is not a gap and is written in its own row above.\n\n'
  printf -- '- **typed by hand** — nobody passed --gap for this one\n'
} >"$TMP/rt-typed-gap.md"
check "a HAND-ADDED gap entry passes the round trip — the accepted cost, pinned" 0 \
  "byte-identical to record_render's output" record_roundtrip "$TMP/rt-typed-gap.md"
check "and drills/README.md states that cost rather than leaving it to be found" 0 \
  "a hand-added gap entry survives the round trip" cat "$ROOT/drills/README.md"
check "with the monotonicity reason it is accepted for" 0 \
  "monotone in the safe direction" cat "$ROOT/drills/README.md"

# -- D7: --amend-record ------------------------------------------------------
# Without this mode the section is nearly unusable: a reviewer asking for a
# disclosure mid-panel would cost a full eight-probe rehearsal against a fresh
# scratch repo, which is the cost that made the second-document option
# unacceptable on #482.
amend() { (cd "$ROOT" && ./drill/rehearsal.sh --amend-record "$@"); }
cp "$TMP/emitted.md" "$TMP/amend-target.md"
sed '/^## Known gaps$/,$d' "$TMP/amend-target.md" >"$TMP/amend-before.txt"
check "--amend-record adds a gap to a round-tripping emission" 0 "amended" \
  amend "$TMP/amend-target.md" --gap 'the dispatch entrance|no probe drives it'
check "the amended record round-trips" 0 "byte-identical to record_render's output" \
  record_roundtrip "$TMP/amend-target.md"
check "the amended record carries the gap" 0 \
  '- **the dispatch entrance** — no probe drives it' cat "$TMP/amend-target.md"
check "and no longer claims none were declared" 1 "" \
  grep -qF 'None declared' "$TMP/amend-target.md"
sed '/^## Known gaps$/,$d' "$TMP/amend-target.md" >"$TMP/amend-after.txt"
check "the record's five other sections are byte-unchanged by the amend" 0 "" \
  diff -u "$TMP/amend-before.txt" "$TMP/amend-after.txt"
check "a second amend appends beside the first, in order" 0 "amended" \
  amend "$TMP/amend-target.md" --gap 'consumer callers|nothing drives one'
sed -n '/^## Known gaps$/,$p' "$TMP/amend-target.md" | grep '^- ' >"$TMP/amend.lines"
cat >"$TMP/amend.want" <<'AMEND'
- **the dispatch entrance** — no probe drives it
- **consumer callers** — nothing drives one
AMEND
check "both amended gaps stand, in the order they were added" 0 "" \
  diff -u "$TMP/amend.want" "$TMP/amend.lines"
check "a title the record already declares is refused" 1 "already declares" \
  amend "$TMP/amend-target.md" --gap 'consumer callers|a second time'
check "--amend-record with no --gap refuses rather than rewriting for nothing" 1 \
  "needs at least one --gap" amend "$TMP/amend-target.md"

# ROUND 1's reachable state, pinned step by step. @claude-bot-andresmgsl drove
# this exact sequence against a copy of the golden record and it went all the
# way through: `alpha** — beta` was accepted and written, `alpha` — a title
# NOBODY had declared — was then refused as a duplicate because the parse had
# cut the stored title down to it, and a second `alpha** — beta` was accepted,
# leaving a record with two gap lines whose parsed titles were both `alpha`.
# The round trip greened all of it. D6 says in as many words that two gaps may
# not share a title, so the tool was writing a record that broke a stated
# invariant. It now stops at step 1, and the two steps that followed from it
# are asserted as no longer reachable rather than merely unlikely.
cp "$TMP/emitted.md" "$TMP/amend-round1.md"
check "step 1: the ambiguous title is refused, and not written" 1 \
  "carries '** — ' in its TITLE" \
  amend "$TMP/amend-round1.md" --gap 'alpha** — beta|gamma'
check "and the record is byte-unchanged by the refusal" 0 "" \
  cmp "$TMP/emitted.md" "$TMP/amend-round1.md"
check "step 2: 'alpha' is therefore still a title anybody may declare" 0 "amended" \
  amend "$TMP/amend-round1.md" --gap 'alpha|a title nothing stole'
check "step 3: and a SECOND 'alpha' is refused, as D6 requires" 1 "already declares" \
  amend "$TMP/amend-round1.md" --gap 'alpha|a second body'
# The invariant the sequence used to defeat, measured on the record itself:
# every gap line's parsed title is distinct. Read through `record_parse`, not
# by eye, because the parsed title is exactly what the old bug disagreed with
# the rendered line about.
check "no two gap lines in the amended record share a parsed title" 0 "" \
  bash -c 'source "$1/drill/lib/probes.sh"; source "$1/drill/lib/record.sh"
    record_parse "$2" "$3/r1-ctx.tsv" "$3/r1-probes.tsv" "$3/r1-setup.tsv" "$3/r1-gaps.tsv"
    all=$(cut -f1 "$3/r1-gaps.tsv" | wc -l)
    uniq=$(cut -f1 "$3/r1-gaps.tsv" | sort -u | wc -l)
    [ "$all" -gt 0 ] && [ "$all" = "$uniq" ]' _ "$ROOT" "$TMP/amend-round1.md" "$TMP"

# It refuses to LAUNDER, which is the point of the mode's preconditions. Both
# refusals must leave the file byte-identical: the unblock for a record that
# does not round-trip is to re-run the instrument, never to amend it green.
cp "$SHIPPED" "$TMP/amend-stale.md"
check "--amend-record refuses a record that does not already round-trip" 1 \
  "does not round-trip as committed" amend "$TMP/amend-stale.md" --gap 'a|b'
check "and says the unblock is to re-run the instrument" 1 \
  "RE-RUN the instrument and commit what it writes" \
  amend "$TMP/amend-stale.md" --gap 'a|b'
check "the stale record is left byte-unchanged" 0 "" cmp "$SHIPPED" "$TMP/amend-stale.md"
cp "$ROOT/drills/0.6.3.md" "$TMP/amend-ruling.md"
check "--amend-record refuses a scope ruling" 1 "is not the instrument's emission" \
  amend "$TMP/amend-ruling.md" --gap 'a|b'
check "naming the class it read off the record" 1 "it declares a scope ruling" \
  amend "$TMP/amend-ruling.md" --gap 'a|b'
check "the scope ruling is left byte-unchanged" 0 "" \
  cmp "$ROOT/drills/0.6.3.md" "$TMP/amend-ruling.md"

# No network, no repository — ASSERTED, not asserted by inspection. The stub
# records every call it is asked to make, and the amend must make none.
stub_reset
cp "$TMP/emitted.md" "$TMP/amend-offline.md"
(
  export PATH="$STUB_BIN:$PATH" DRILL_STUB_STATE="$TMP/state"
  cd "$ROOT" && ./drill/rehearsal.sh --amend-record "$TMP/amend-offline.md" \
    --gap 'offline|no call was made'
) >"$TMP/amend-offline.out" 2>&1
check "the amend under the gh stub succeeds" 0 "amended" cat "$TMP/amend-offline.out"
check "and made no gh call whatsoever" 0 "0" \
  bash -c 'wc -l < "$1" | tr -d " "' _ "$TMP/state/calls"
check "and created no repository" 1 "" test -d "$TMP/state/$(san "$SCRATCH")"

# ---------------------------------------------------------------------------
# Argument refusals: the CLI is a door too.
# ---------------------------------------------------------------------------
rehearsal_args() { (cd "$ROOT" && ./drill/rehearsal.sh "$@"); }
check "no arguments prints usage" 2 "usage: drill/rehearsal.sh" rehearsal_args
check "an rc version is never the candidate version" 1 "not a bare X.Y.Z" \
  rehearsal_args --owner o --version 0.7.0-rc1 --fork-ref "$FORK@$FORK_REF" \
  --candidate-sha "$CAND_SHA"
check "a fork-ref with no repository is refused" 1 "is not 'owner/repo[@ref]'" \
  rehearsal_args --owner o --version 0.7.0 --fork-ref forkowner \
  --candidate-sha "$CAND_SHA"

summary
