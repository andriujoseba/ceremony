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

stub_reset
green_scenario "$TMP/green.scenario"
green_out="$(run_rehearsal "$TMP/green.scenario" --out "$TMP/emitted.md" 2>&1)"
green_rc=$?
check "the rehearsal runs end to end and exits 0" 0 "" test "$green_rc" -eq 0
check "the run reports eight probes passed" 0 "probes passed 8/8, failed 0" \
  printf '%s\n' "$green_out"
check "the emitted record passes the shape check" 0 "eight probe rows" \
  record_check "$TMP/emitted.md"
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
  "archived=true private=true" cat "$TMP/emitted.md"
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
with_stub scratch_create "$BOOTSTRAP" >/dev/null 2>&1
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
archive_never() { DRILL_STUB_ARCHIVE_LAG=99 with_stub scratch_archive "$FORK"; }
check "an archive whose flag never reads back true is a failed read, not a disposal" 1 \
  "the archived flag on $FORK did not read back after 10 attempts" archive_never
check "and it never reports an unarchived repo as the disposal it observed" 1 "" \
  archive_never
stub_reset
faults "0	2	GET repos/$FORK	500	Internal Server Error"
check "a disposal read that 500s twice still reports the flag" 0 \
  "archived=true private=true" with_stub scratch_archive "$FORK"

# ---------------------------------------------------------------------------
# Argument refusals: the CLI is a door too.
# ---------------------------------------------------------------------------
rehearsal_args() { (cd "$ROOT" && ./drill/rehearsal.sh "$@"); }
check "no arguments prints usage" 2 "usage: drill/rehearsal.sh" rehearsal_args
check "an rc version is never the candidate version" 1 "not a bare X.Y.Z" \
  rehearsal_args --owner o --version 0.7.0-rc1 --fork-ref "$FORK@$FORK_REF" \
  --candidate-sha "$CAND_SHA"
check "a fork-ref with no ref is refused" 1 "is not 'owner/repo@ref'" \
  rehearsal_args --owner o --version 0.7.0 --fork-ref forkowner/ceremony \
  --candidate-sha "$CAND_SHA"

summary
