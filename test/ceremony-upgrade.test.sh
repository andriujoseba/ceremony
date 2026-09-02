#!/usr/bin/env bash
# Contract tests for bin/ceremony-upgrade (issue #561). Constructed CONSUMER
# trees (ceremony `uses:` lines spread across .github/, plus decoy content
# that names the old version) and a constructed SOURCE tree standing in for
# ceremony at the target tag — a docs-sync manifest, its docs, and a
# CHANGELOG.md whose release headings ARE the ladder the command reads.
#
# Every row that must not write is asserted over a WHOLE-TREE fingerprint
# taken before and after, never over the files the tool would have touched:
# the build this rejects is the one that rewrites the refs, then discovers
# the migration, then refuses (#561's third must-fail build), and a
# per-file assertion is exactly what it passes.
#
# The network is a `curl` stub first on PATH whose DEFAULT MODE REFUSES,
# modelled on test/docs-sync.test.sh's. That default is load-bearing rather
# than decorative: with the stub in place for the whole file, every --source
# row below is a proof that the --source path opens no socket at all.
#
# set -u, not -e: failing commands are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/bin/ceremony-upgrade"
DOCS_SYNC="$ROOT/actions/docs-sync/docs-sync.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ln -s "$ROOT" "$TMP/ceremony tool"
SCRIPT_WITH_SPACE="$TMP/ceremony tool/bin/ceremony-upgrade"

# --- the source tree ----------------------------------------------------------
#
# A fake ceremony: a small manifest (deliberately NOT the real vendored set —
# a command that hardcoded the doc list instead of calling docs-sync would
# pass against the real one) and a CHANGELOG.md carrying the real ladder.
#
# THE LADDER'S VERSIONS ARE THE REAL ONES on purpose, unlike the doc set: the
# migration table in bin/ceremony-upgrade names real tags, so the intervals
# these rows exercise have to be the real intervals. The bodies are stubs;
# only the headings are read.
SRC="$TMP/src"
mkdir -p "$SRC/docs"
printf 'AGENTS.md\nRULES.md\n' >"$SRC/docs/VENDORED.txt"
printf '# router v1\n' >"$SRC/AGENTS.md"
printf '# rules v1\n' >"$SRC/RULES.md"

LADDER_TAGS="0.7.8 0.7.7 0.7.6 0.7.5 0.7.4 0.7.3 0.7.2 0.7.1 0.7.0 0.6.3 0.6.2 0.6.1 0.6.0 0.5.0 0.4.1 0.4.0 0.3.0 0.2.0 0.1.0"
{
  printf '# Changelog\n\n## Unreleased\n\n- nothing yet\n\n'
  for t in $LADDER_TAGS; do
    printf '## %s — 2026-01-01\n\n### Changed\n\n- a release\n\n' "$t"
  done
} >"$SRC/CHANGELOG.md"

# The guide the applied step reads, and the ONE place its caller stub comes
# from. The block is EXTRACTED FROM THIS REPOSITORY'S OWN docs/CONSUMERS.md
# rather than written out here: a fixture carrying its own copy of a published
# block is the second source of truth the step exists to avoid, and it goes
# stale silently the first time the real block moves. So the source tree
# standing in for ceremony at a tag publishes exactly what ceremony publishes.
sweep_stub_from_guide() {
  awk '/^And the complete sweep caller, .labels-sweep\.yml. beside it/ { armed = 1; next }
       armed && /^```yaml$/ { inblock = 1; next }
       inblock && /^```$/ { exit }
       inblock' "$ROOT/docs/CONSUMERS.md"
}
write_src_guide() { # $1 = source dir
  mkdir -p "$1/docs"
  {
    cat <<'MD'
# Consumers

And the complete sweep caller, `labels-sweep.yml` beside it — the hourly
cron lives HERE since #209, not on the labels caller:

```yaml
MD
    sweep_stub_from_guide
    printf '```\n'
  } >"$1/docs/CONSUMERS.md"
}
write_src_guide "$SRC"

# --- fixture builders ---------------------------------------------------------

# consumer <name> <ref> — a consumer tree pinned at <ref> in FIVE places
# across four files, including a nested composite action, so `find`'s
# recursion and the all-together rule are both exercised. It also carries
# three things that must NOT move:
#
#   * a commented-out pin line (docs/CONSUMERS.md snippets get pasted into
#     consumer workflows, and docs-sync excludes comments for the same
#     reason — where the two disagree about what a pin is, the mirror check
#     and the bump disagree about what the tree is pinned to);
#   * third-party `uses:` lines at their own refs;
#   * DECOYS — a README naming the version in prose and a CHANGELOG.md with
#     a `## <ref>` heading of the consumer's own. These are what `sed
#     's/<old>/<new>/g'` corrupts silently, and the byte assertions below
#     are what catch it.
consumer() {
  local dir="$TMP/$1" ref="$2"
  rm -rf "$dir"
  mkdir -p "$dir/.github/workflows" "$dir/.github/actions/vouch"
  cat >"$dir/.github/workflows/release.yml" <<EOF
name: release
on:
  push:
    branches: [main]
jobs:
  release:
    uses: heavy-duty/ceremony/.github/workflows/release.yml@$ref
    secrets: inherit
EOF
  cat >"$dir/.github/workflows/labels.yml" <<EOF
name: labels
on: [pull_request_target]
jobs:
  trigger:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
  # a documentation snippet someone pasted; a comment is not a pin
  #  uses: heavy-duty/ceremony/.github/workflows/labels-sweep.yml@0.0.1
EOF
  cat >"$dir/.github/workflows/ci.yml" <<EOF
name: ci
on: [pull_request]
jobs:
  guards:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: heavy-duty/ceremony/actions/docs-sync@$ref
      - uses: heavy-duty/ceremony/actions/refs-not-closing@$ref  # keep in step with the pin
EOF
  cat >"$dir/.github/actions/vouch/action.yml" <<EOF
name: vouch
runs:
  using: composite
  steps:
    - uses: heavy-duty/ceremony/actions/runner-isolated@$ref
      shell: bash
EOF
  # The decoys.
  printf '# consumer\n\nPinned to ceremony %s. See the %s notes.\n' "$ref" "$ref" >"$dir/README.md"
  printf '# Changelog\n\n## %s — 2026-02-02\n\n- our own release, nothing to do with ceremony\n' "$ref" >"$dir/CHANGELOG.md"
}

# The number of real pins consumer() writes. Named once: a row asserting "5"
# in prose while the builder writes 6 is a fixture that grades itself.
PIN_COUNT=5

# fingerprint <dir> — every regular file's path and content hash, sorted.
# Paths as well as hashes, so an ADDED or DELETED file moves the fingerprint
# too; a content-only digest would call a refusal that created .ceremony/
# byte-identical.
fingerprint() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r p; do
    printf '%s  %s\n' "$(sha256sum <"$p" | cut -d' ' -f1)" "$p"
  done)
}

# unchanged <desc> <dir> <cmd...> — run the command, then assert the tree is
# byte-identical to what it was before. The assertion is the WHOLE tree.
unchanged() {
  local desc="$1" dir="$2"
  shift 2
  local before after
  before="$(fingerprint "$dir")"
  "$@" >/dev/null 2>&1
  after="$(fingerprint "$dir")"
  if [ "$before" = "$after" ]; then
    echo "ok: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — the tree changed:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

# in_consumer <name> <args...> — run the command from inside a consumer tree,
# the way an operator runs it: from the root of the checkout.
in_consumer() {
  local dir="$1"
  shift
  (cd "$TMP/$dir" && bash "$SCRIPT" "$@")
}

in_consumer_with_script() {
  local dir="$1" script="$2"
  shift 2
  (cd "$TMP/$dir" && bash "$script" "$@")
}

in_consumer_docs_sync() {
  local dir="$1"
  shift
  (cd "$TMP/$dir" && bash "$DOCS_SYNC" "$@")
}

# refs <name> — every ceremony ref in the tree, one per line, so a row can
# assert that ALL of them moved (or that none did).
refs() {
  grep -rhoE 'heavy-duty/ceremony[^@[:space:]]*@[A-Za-z0-9._-]+' "$TMP/$1/.github" |
    sed -E 's/^.*@//' | LC_ALL=C sort | uniq -c | sed 's/^ *//'
}

# --- the curl stub ------------------------------------------------------------
#
# Default mode refuses, which is what makes every --source row a proof that
# the --source path opens no socket (test/docs-sync.test.sh, #393).
#
# It also LOGS THE URL of every call, which is the only way to grade one thing
# --source cannot express: with a local source tree standing in for ceremony,
# "the guide at the crossed tag" and "the guide at the target" are the same
# bytes, so a build that read the wrong ref passes every --source row. On the
# fetch path the two are different URLs, and the log is what says which one
# was asked for.
mkdir -p "$TMP/stub"
cat >"$TMP/stub/curl" <<'STUB'
#!/usr/bin/env bash
out=""
url=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  case "$arg" in https://*) url="$arg" ;; esac
  prev="$arg"
done
[ -z "${CURL_STUB_LOG:-}" ] || printf '%s\n' "$url" >>"$CURL_STUB_LOG"
case "${CURL_STUB:-none}" in
  ok)
    case "$url" in
      *docs/CONSUMERS.md) cp "${CURL_STUB_GUIDE:-$CURL_STUB_BODY}" "$out" ;;
      *) cp "$CURL_STUB_BODY" "$out" ;;
    esac
    printf '200'
    ;;
  404)
    printf '404'
    exit 22
    ;;
  503)
    printf '503'
    exit 22
    ;;
  *)
    echo "curl stub: refusing — this code path must not reach the network (curl $*)" >&2
    printf '000'
    exit 99
    ;;
esac
STUB
chmod +x "$TMP/stub/curl"
PATH="$TMP/stub:$PATH"
export PATH

# ============================================================================
# The happy path — one adjacent move
# ============================================================================

consumer happy 0.7.6

check "--check reports the move and every pinned file" 0 "0.7.6 -> 0.7.7, $PIN_COUNT ceremony ref(s)" \
  in_consumer happy --check --source "$SRC" 0.7.7
check "--check names the release caller" 0 ".github/workflows/release.yml  @0.7.6" \
  in_consumer happy --check --source "$SRC" 0.7.7
check "--check names the nested composite action" 0 ".github/actions/vouch/action.yml  @0.7.6" \
  in_consumer happy --check --source "$SRC" 0.7.7
check "--check says it wrote nothing" 0 "--check changes nothing" \
  in_consumer happy --check --source "$SRC" 0.7.7
unchanged "--check leaves the whole tree byte-identical" "$TMP/happy" \
  in_consumer happy --check --source "$SRC" 0.7.7

# check is the DEFAULT, exactly as in docs-sync — a row of its own, because
# "the default is check" is the difference between a preview and a rewrite.
check "no mode flag defaults to --check" 0 "--check changes nothing" \
  in_consumer happy --source "$SRC" 0.7.7
unchanged "the default mode leaves the tree byte-identical" "$TMP/happy" \
  in_consumer happy --source "$SRC" 0.7.7

check "--check refuses to look like it moved anything" 0 "" \
  in_consumer happy --source "$SRC" 0.7.7
check_absent "--check never claims to have rewritten a ref" 0 "rewrote" \
  in_consumer happy --source "$SRC" 0.7.7

# The plan's own file count. It used to be the number of YAML files SCANNED,
# not the number carrying a pin — a plan line that says "N ref(s) in M
# file(s)" where M is neither. This fixture has 5 refs in 4 files under 6
# YAML files, so all three numbers differ and the row can only pass for the
# right reason.
check "--check announces the refs and the files that carry them" 0 \
  "$PIN_COUNT ceremony ref(s) in 4 file(s) under .github/" \
  in_consumer happy --source "$SRC" 0.7.7

check "--fix rewrites the refs" 0 "rewrote $PIN_COUNT ceremony ref(s) in 4 file(s) to @0.7.7" \
  in_consumer happy --fix --source "$SRC" 0.7.7
# Its own fixture: `happy` has already moved by now, so this row would take
# the "already at" branch and pass while asserting nothing about a rewrite.
consumer verified 0.7.6
check "--fix verifies the tree against the plan before it hands off" 0 \
  "verified the tree against the plan" \
  in_consumer verified --fix --source "$SRC" 0.7.7
check "all $PIN_COUNT refs are at the target and none is left behind" 0 "$PIN_COUNT 0.7.7" \
  refs happy
check_absent "no ref is left at the old tag" 0 "0.7.6" \
  refs happy
check "the mirror is current after --fix, so docs-sync --check passes" 0 "is an exact mirror" \
  in_consumer_docs_sync happy --check --source "$SRC"

# The sed build. These two decoys are what a tree-wide substitution destroys,
# and nothing else in the suite would notice.
check "the consumer's README still names its own old version" 0 "Pinned to ceremony 0.7.6" \
  cat "$TMP/happy/README.md"
check "the consumer's own CHANGELOG heading is untouched" 0 "## 0.7.6 — 2026-02-02" \
  cat "$TMP/happy/CHANGELOG.md"
# Third-party refs and the commented-out pin are not this command's business.
check "a third-party uses: keeps its own ref" 0 "actions/checkout@v4" \
  cat "$TMP/happy/.github/workflows/ci.yml"
check "a commented-out pin line is not a pin and does not move" 0 "labels-sweep.yml@0.0.1" \
  cat "$TMP/happy/.github/workflows/labels.yml"
check "a trailing comment on a pin line survives the rewrite" 0 "refs-not-closing@0.7.7  # keep in step with the pin" \
  cat "$TMP/happy/.github/workflows/ci.yml"

# --- idempotence --------------------------------------------------------------

check "a second --fix reports nothing to do" 0 "nothing to do — the pin was already at 0.7.7" \
  in_consumer happy --fix --source "$SRC" 0.7.7
unchanged "a second --fix leaves the tree byte-identical to the first's" "$TMP/happy" \
  in_consumer happy --fix --source "$SRC" 0.7.7
check "--check at the current pin says so and stops" 0 "already at 0.7.7" \
  in_consumer happy --check --source "$SRC" 0.7.7

# ============================================================================
# All or none
# ============================================================================

consumer mixed 0.7.6
# One file dragged forward by hand — the shape a partial bump leaves behind.
sed -i 's|actions/docs-sync@0.7.6|actions/docs-sync@0.7.7|' "$TMP/mixed/.github/workflows/ci.yml"

check "a tree with two ceremony refs is refused" 1 "not all at one ref" \
  in_consumer mixed --check --source "$SRC" 0.7.7
check "the refusal names the differing file" 1 ".github/workflows/ci.yml  @0.7.7" \
  in_consumer mixed --check --source "$SRC" 0.7.7
check "the refusal reports every ref it found" 1 "Every ceremony ref found ($PIN_COUNT" \
  in_consumer mixed --check --source "$SRC" 0.7.7
unchanged "the mixed-ref refusal leaves the tree byte-identical (--check)" "$TMP/mixed" \
  in_consumer mixed --check --source "$SRC" 0.7.7
unchanged "the mixed-ref refusal leaves the tree byte-identical (--fix)" "$TMP/mixed" \
  in_consumer mixed --fix --source "$SRC" 0.7.7

# ============================================================================
# The refusal — the one to get right
# ============================================================================

consumer ancient 0.1.0
runnable_step_lines() {
  local name="$1" target="$2"
  in_consumer "$name" --check --source "$SRC" "$target" 2>&1 |
    sed -n '/^  SHORTER MOVE:/p'
}
in_consumer_with_override() {
  local name="$1"
  (
    cd "$TMP/$name" || return
    CEREMONY_UPGRADE_MIGRATIONS_DONE=1 \
      bash "$SCRIPT" --check --source "$SRC" 0.7.8
  )
}

check "a move crossing migrations is refused" 1 "crosses 6 migration(s)" \
  in_consumer ancient --check --source "$SRC" 0.7.7
check "every migration refusal names the hand-only boundary" 1 "THE CROSSING IS HAND-ONLY" \
  in_consumer ancient --check --source "$SRC" 0.7.7
check "the hand-only boundary says the pin, not the tree, defines the crossed set" 1 \
  "read from the pin on the ladder, never from the tree" \
  in_consumer ancient --check --source "$SRC" 0.7.7
check_absent "the dead then-re-run remedy is absent from migration refusals" 1 "then re-run" \
  in_consumer ancient --check --source "$SRC" 0.7.7
unchanged "the migration refusal leaves the WHOLE tree byte-identical (--check)" "$TMP/ancient" \
  in_consumer ancient --check --source "$SRC" 0.7.7
# The partial-write build: refs rewritten, migration discovered, then refuse.
# It passes every message assertion above and only this row rejects it.
unchanged "the migration refusal leaves the WHOLE tree byte-identical (--fix)" "$TMP/ancient" \
  in_consumer ancient --fix --source "$SRC" 0.7.7
check "not one ref moved under the refusal" 0 "$PIN_COUNT 0.1.0" \
  refs ancient

# Every crossed tag, IN ORDER. The order is the assertion: a reader working
# through a hand migration does them oldest first, and a set printed in hash
# order is a list of things to do in an order that will not work.
crossed_tags() {
  in_consumer ancient --check --source "$SRC" 0.7.7 2>&1 |
    sed -nE 's/^  ([0-9]+\.[0-9]+\.[0-9]+) — docs.*/\1/p' | tr '\n' ' '
}
check "every crossed tag is named, in ladder order" 0 "0.2.0 0.3.0 0.4.1 0.5.0 0.6.0 0.7.0 " \
  crossed_tags
# 0.1.0 is a table row and the consumer is standing ON it: the half-open
# interval is what keeps it out of the list, and this row is what would
# notice if the interval ever closed at the current pin.
check_absent "the tag the consumer already stands on is not listed" 0 "0.1.0" \
  crossed_tags

# Each with its section, so the reader has somewhere to go.
check "0.2.0 carries its CONSUMERS.md section" 1 '0.2.0 — docs/CONSUMERS.md § "Bootstrap a new repo"' \
  in_consumer ancient --check --source "$SRC" 0.7.7
check "0.5.0 carries its CONSUMERS.md section" 1 '0.5.0 — docs/CONSUMERS.md § "Labels automation"' \
  in_consumer ancient --check --source "$SRC" 0.7.7
check "0.6.0 carries its CONSUMERS.md section" 1 '0.6.0 — docs/CONSUMERS.md § "Doctrine mirror"' \
  in_consumer ancient --check --source "$SRC" 0.7.7

# The refusal says what it WOULD have done, so the reader can tell it is
# about the migrations and not about the refs.
check "the refusal reports the ref count it would have rewritten" 1 "rewrite $PIN_COUNT ceremony ref(s) from @0.1.0 to @0.7.7" \
  in_consumer ancient --check --source "$SRC" 0.7.7
check "the refusal lists the files it would have rewritten" 1 ".github/workflows/labels.yml  @0.1.0" \
  in_consumer ancient --check --source "$SRC" 0.7.7
check "the refusal says the tree is unchanged" 1 "THE TREE IS UNCHANGED" \
  in_consumer ancient --check --source "$SRC" 0.7.7
check "the oldest pin has no shorter move before its first crossed tag" 1 \
  "NO SHORTER MOVE: the first crossed tag 0.2.0 is the next tag on the ladder" \
  in_consumer ancient --check --source "$SRC" 0.7.7
check_absent "a no-shorter-move refusal carries no runnable step line" 0 "SHORTER MOVE:" \
  runnable_step_lines ancient 0.7.7

# A real shorter move exists only BELOW the first crossed tag. Extract the
# suggestion from the refusal and execute that exact tag: hard-coding the
# second invocation would test our expectation twice while never proving the
# command's own line is performable (#588).
consumer stepable 0.6.1
suggested_step() {
  suggested_step_line | sed -nE 's/.* ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p'
}
suggested_step_line() {
  in_consumer_with_script stepable "$SCRIPT_WITH_SPACE" \
    --check --source "$SRC" 0.7.8 2>&1 | sed -n 's/^  SHORTER MOVE: //p'
}
run_suggested_step() {
  local suggested_line
  suggested_line="$(suggested_step_line)"
  [ -n "$suggested_line" ] || return 97
  (cd "$TMP/stepable" && bash -c "$suggested_line")
}
check "the first crossed tag is named on a stepable move" 1 "FIRST CROSSED TAG: 0.7.0" \
  in_consumer stepable --check --source "$SRC" 0.7.8
check "the shorter move line names the rung below the first crossing" 0 "0.6.3" \
  suggested_step
check "the extracted shorter move is accepted by the command" 0 \
  "no migration between 0.6.1 and 0.6.3" run_suggested_step
check_absent "a stepable refusal does not claim there is no shorter move" 1 "NO SHORTER MOVE:" \
  in_consumer stepable --check --source "$SRC" 0.7.8
check_absent "the stepable refusal contains no dead then-re-run remedy" 1 "then re-run" \
  in_consumer stepable --check --source "$SRC" 0.7.8
unchanged "the stepable refusal leaves the WHOLE tree byte-identical (--check)" "$TMP/stepable" \
  in_consumer stepable --check --source "$SRC" 0.7.8
unchanged "the stepable refusal leaves the WHOLE tree byte-identical (--fix)" "$TMP/stepable" \
  in_consumer stepable --fix --source "$SRC" 0.7.8

# The first crossed tag is the next rung. Falling back to the current tag
# would emit a command that exits zero while doing nothing, so this branch
# must carry only the explicit wall and never a runnable step line (#588).
consumer atwall 0.7.7
check "the at-wall refusal names its first crossed tag" 1 "FIRST CROSSED TAG: 0.7.8" \
  in_consumer atwall --check --source "$SRC" 0.7.8
check "the at-wall refusal says no shorter move exists" 1 \
  "NO SHORTER MOVE: the first crossed tag 0.7.8 is the next tag on the ladder" \
  in_consumer atwall --check --source "$SRC" 0.7.8
check_absent "the at-wall refusal carries no runnable step line" 0 "SHORTER MOVE:" \
  runnable_step_lines atwall 0.7.8
check_absent "the at-wall refusal contains no dead then-re-run remedy" 1 "then re-run" \
  in_consumer atwall --check --source "$SRC" 0.7.8
unchanged "the at-wall refusal leaves the WHOLE tree byte-identical (--check)" "$TMP/atwall" \
  in_consumer atwall --check --source "$SRC" 0.7.8
unchanged "the at-wall refusal leaves the WHOLE tree byte-identical (--fix)" "$TMP/atwall" \
  in_consumer atwall --fix --source "$SRC" 0.7.8

# --- 0.4.1 in particular ------------------------------------------------------
#
# The destructive one. A generic "a migration is owed" does not discharge it,
# so each of the four acts is its own row: a message that named the split but
# forgot the cron MOVE is how a consumer ends up double-sweeping.
consumer split 0.4.0
check "crossing 0.4.1 names the two-caller split" 1 "TWO-CALLER SPLIT" \
  in_consumer split --check --source "$SRC" 0.5.0
check "crossing 0.4.1 names the labels-sweep.yml addition" 1 "labels-sweep.yml" \
  in_consumer split --check --source "$SRC" 0.5.0
check "crossing 0.4.1 says the cron MOVES, never copies" 1 "move, never copy" \
  in_consumer split --check --source "$SRC" 0.5.0
check "crossing 0.4.1 names double sweeps as the cost of copying" 1 "DOUBLE SWEEPS" \
  in_consumer split --check --source "$SRC" 0.5.0
check "crossing 0.4.1 names the actions: write grant" 1 "grant actions: write" \
  in_consumer split --check --source "$SRC" 0.5.0
check "crossing 0.4.1 names what breaks without it" 1 "RED ON EVERY PR AND ISSUE EVENT" \
  in_consumer split --check --source "$SRC" 0.5.0

# The interval is HALF-OPEN at the current pin: standing ON 0.4.1 and moving
# up must not re-fire the migration this consumer has already done. A closed
# interval passes every row above and refuses every consumer forever.
consumer onsplit 0.4.1
check "the interval is half-open at the current pin" 1 "crosses 1 migration(s)" \
  in_consumer onsplit --check --source "$SRC" 0.5.0
check_absent "0.4.1 is not re-listed when the consumer already stands on it" 1 "TWO-CALLER SPLIT" \
  in_consumer onsplit --check --source "$SRC" 0.5.0

# ...and CLOSED at the target: arriving AT a migration tag is crossing it.
consumer arrive 0.4.0
check "arriving at a migration tag fires it" 1 "TWO-CALLER SPLIT" \
  in_consumer arrive --check --source "$SRC" 0.4.1
check "arriving at the next migration rung has no shorter move" 1 \
  "NO SHORTER MOVE: the first crossed tag 0.4.1 is the next tag on the ladder" \
  in_consumer arrive --check --source "$SRC" 0.4.1
check_absent "the next-rung migration refusal carries no step line" 0 "SHORTER MOVE:" \
  runnable_step_lines arrive 0.4.1

# A move that crosses nothing is not refused, and this is the row that keeps
# the table from being "refuse everything".
consumer clean 0.7.1
check "a move crossing no migration is allowed" 0 "no migration between 0.7.1 and 0.7.6" \
  in_consumer clean --check --source "$SRC" 0.7.6

# ============================================================================
# Four faults, four messages
# ============================================================================
#
# Each row asserts its own text AND the absence of the other three, because a
# branch that prints every diagnostic on every fault satisfies a
# positive-only suite while sending its reader to audit four things for one
# fault (#393).

# --- fault 1: no pin ----------------------------------------------------------
mkdir -p "$TMP/bare/.github/workflows"
printf 'name: ci\non: [push]\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n' \
  >"$TMP/bare/.github/workflows/ci.yml"
check "a tree with no pin is refused" 1 "FAULT — no ceremony pin" \
  in_consumer bare --check --source "$SRC" 0.7.7
check "the no-pin message names bootstrap as a later child of #560" 1 "later child of #560" \
  in_consumer bare --check --source "$SRC" 0.7.7
check "the no-pin message says the tool is not broken" 1 "not a sign that this command is broken" \
  in_consumer bare --check --source "$SRC" 0.7.7
check_absent "the no-pin message is not the not-a-released-tag message" 1 "is not a released tag" \
  in_consumer bare --check --source "$SRC" 0.7.7
check_absent "the no-pin message is not the crossed-migration message" 1 "crosses" \
  in_consumer bare --check --source "$SRC" 0.7.7
unchanged "the no-pin refusal writes nothing" "$TMP/bare" \
  in_consumer bare --fix --source "$SRC" 0.7.7

# --- fault 2: the current ref is not a released tag ---------------------------
consumer onbranch main
check "a branch pin is refused" 1 "FAULT — the current pin 'main' is not a released tag" \
  in_consumer onbranch --check --source "$SRC" 0.7.7
check "the branch-pin message says why it cannot be graded" 1 "cannot be placed on it" \
  in_consumer onbranch --check --source "$SRC" 0.7.7
check_absent "the branch-pin message is not the no-pin message" 1 "no ceremony pin" \
  in_consumer onbranch --check --source "$SRC" 0.7.7
check_absent "the branch-pin message is not the target-missing message" 1 "does not exist upstream" \
  in_consumer onbranch --check --source "$SRC" 0.7.7
unchanged "the branch-pin refusal writes nothing" "$TMP/onbranch" \
  in_consumer onbranch --fix --source "$SRC" 0.7.7

consumer onsha 8f1c2d3e4b5a69708192a3b4c5d6e7f809a1b2c3
check "a commit-SHA pin is refused as unplaceable too" 1 "is not a released tag" \
  in_consumer onsha --check --source "$SRC" 0.7.7

# --- fault 3: the target tag does not exist -----------------------------------
check "an unreleased target tag is refused" 1 "FAULT — the target tag '0.9.9' does not exist upstream" \
  in_consumer happy --check --source "$SRC" 0.9.9
check_absent "the target-missing message is not the current-pin message" 1 "the current pin" \
  in_consumer happy --check --source "$SRC" 0.9.9
unchanged "the target-missing refusal writes nothing" "$TMP/happy" \
  in_consumer happy --fix --source "$SRC" 0.9.9

# A branch is not a target either — same fault, and it must say so rather
# than grading a move onto something with no place on the ladder.
check "a branch as the target is refused" 1 "does not exist upstream" \
  in_consumer happy --check --source "$SRC" main

# --- fault 4: the crossed migration -------------------------------------------
# (asserted in full above; this row is the fourth message's absence check)
check_absent "the crossed-migration message is not the no-pin message" 1 "no ceremony pin" \
  in_consumer ancient --check --source "$SRC" 0.7.7

# ============================================================================
# The fifth refusal — a downgrade (beyond #561's four, disclosed on the PR)
# ============================================================================

check "a backwards move is refused" 1 "FAULT — that is a DOWNGRADE" \
  in_consumer happy --check --source "$SRC" 0.5.0
check "the downgrade message says why there is no hand procedure" 1 "written forwards" \
  in_consumer happy --check --source "$SRC" 0.5.0
unchanged "the downgrade refusal writes nothing" "$TMP/happy" \
  in_consumer happy --fix --source "$SRC" 0.5.0

# ============================================================================
# Argument handling
# ============================================================================

check "no target tag is a usage error" 1 "no target tag" \
  in_consumer happy --check --source "$SRC"
check "two target tags are refused" 1 "two target tags given" \
  in_consumer happy --check --source "$SRC" 0.7.6 0.7.7
check "an unknown flag is refused" 1 "unknown argument" \
  in_consumer happy --check --source "$SRC" --wat 0.7.7
check "--force is not an accepted override" 1 "unknown argument" \
  in_consumer happy --check --source "$SRC" --force 0.7.7
check_absent "the usage text advertises no override" 1 "--force" \
  in_consumer happy --check --source "$SRC"
check "an override-shaped environment variable cannot bypass fault 6" 1 \
  "THE CROSSING IS HAND-ONLY" in_consumer_with_override atwall
check "--source with no directory is refused" 1 "--source needs a directory" \
  in_consumer happy --check --source
check "a missing --source directory is refused" 1 "no such directory" \
  in_consumer happy --check --source "$TMP/nope" 0.7.7
# A ref is bounded to git-ref characters BEFORE it is written into a workflow
# file: the substitution lands in a file, and a metacharacter there is a
# rewrite nobody wrote.
check "a target with shell metacharacters is refused before anything is read" 1 "refusing target" \
  in_consumer happy --check --source "$SRC" '0.7.7 & rm -rf /'
check "a target starting with a hyphen is not read as a flag" 1 "unknown argument" \
  in_consumer happy --check --source "$SRC" -0.7.7

# ============================================================================
# The tree is only touched through docs-sync, and only where it should be
# ============================================================================

# A symlinked workflow carrying a pin is REFUSED, not silently skipped: a
# `find -type f` enumeration walks straight past it, leaving a ref behind and
# turning "all or none" into a claim the tool did not check.
consumer linked 0.7.6
mv "$TMP/linked/.github/workflows/ci.yml" "$TMP/linked/.github/workflows/ci-real.yml"
ln -s ci-real.yml "$TMP/linked/.github/workflows/ci.yml"
check "a symlinked file carrying a pin is refused" 1 "is a symlink and carries a ceremony pin" \
  in_consumer linked --check --source "$SRC" 0.7.7

# ============================================================================
# The fetch path — the ladder without --source
# ============================================================================
#
# Every row above ran with the refusing curl stub first on PATH and passed,
# which is the proof that --source opens no socket. These rows drive the
# other path deliberately.

CURL_STUB_BODY="$SRC/CHANGELOG.md"
export CURL_STUB_BODY

consumer happyfetch 0.7.6
consumer ancientfetch 0.1.0
run_fetch() {
  local dir="$1" stub="$2"
  shift 2
  (cd "$TMP/$dir" && CURL_STUB="$stub" bash "$SCRIPT" "$@")
}

check "the fetched ladder grades an ordinary move" 0 "0.7.6 -> 0.7.7" \
  run_fetch happyfetch ok --check 0.7.7
check "the fetched ladder refuses a crossed migration too" 1 "crosses 6 migration(s)" \
  run_fetch ancientfetch ok --check 0.7.7
unchanged "a refusal on the fetch path writes nothing either" "$TMP/ancientfetch" \
  run_fetch ancientfetch ok --fix 0.7.7
check "a 404 is the target-missing fault, named as such" 1 "does not exist upstream" \
  run_fetch happyfetch 404 --check 0.9.9
check "a 5xx is transient and says the tag is not in doubt" 1 "transient" \
  run_fetch happyfetch 503 --check 0.7.7
check "the transient 5xx remedy still says re-run" 1 "re-run" \
  run_fetch happyfetch 503 --check 0.7.7
check_absent "a 5xx does not accuse the tag" 1 "does not exist upstream" \
  run_fetch happyfetch 503 --check 0.7.7
unchanged "a failed fetch writes nothing" "$TMP/happyfetch" \
  run_fetch happyfetch 503 --fix 0.7.7
# The stub's default mode refuses and exits 99, so this row is the proof that
# the assertion behind every --source row above is a real one: take --source
# away and the network is genuinely what the command reaches for.
check "without --source the command really does reach for the network" 1 "" \
  run_fetch happyfetch none --check 0.7.7

# The guide and executable are one consumer-facing contract. Keep this on
# the single refusal-table row so an unrelated legitimate "then re-run"
# elsewhere in the guide cannot satisfy or fail the repair (#588).
migration_refusal_guide_row() {
  grep -F '| **the move crosses a migration**' "$ROOT/docs/CONSUMERS.md"
}
check "the guide says a migration crossing is hand-only" 0 "crossing is hand-only" \
  migration_refusal_guide_row
check "the guide includes the ref move in the hand crossing" 0 \
  "move the ceremony refs to that tag in the same commit" migration_refusal_guide_row
check "the guide bounds a shorter move below the first crossing" 0 \
  "between the current pin and that first crossing" migration_refusal_guide_row
check_absent "the guide's migration refusal row drops the dead remedy" 0 "then re-run" \
  migration_refusal_guide_row

# ============================================================================
# The migration table tracks docs/CONSUMERS.md
# ============================================================================
#
# A RATCHET, NOT A PROOF. The table is carried by the command (#561 G5), so
# nothing keeps it current except a reader remembering — and the note that
# ships without its row is the silent damage the whole command exists to
# prevent. This row re-derives the tag set from the prose and fails when a
# note names a tag no row carries. It scans UNWRAPPED paragraphs, because a
# note whose version and whose "and later" fall on either side of a line
# break is invisible to a line-local grep, and that is exactly the note that
# would be missed.
#
# It cannot prove the scan complete: a note phrased in a way this regex does
# not match passes silently. It can only ensure that the notes it CAN see are
# all covered, which is one direction of the risk and the cheap one.
# availability_tags — every X.Y.Z that docs/CONSUMERS.md declares something
# AVAILABLE at, in the sense G5 names: the literal "available" within the 100
# characters before the version, and "and later" directly after it.
#
# THE 100-CHARACTER WINDOW IS THE ASSERTION, not a tuning knob. Matching on
# "the paragraph contains 'available'" was the first shape of this scan and
# it was wrong in the one way that matters: `docs/CONSUMERS.md`'s Labels
# automation block runs from the 0.3.0 note past the 0.7.7 one without a
# blank line, so a paragraph test read #501's "At `0.7.7` and later" — which
# says where an existing notice PRINTS — as an availability note, purely
# because an unrelated sentence upstream of it used the word.
#
# The text is unwrapped first: a note whose version and whose "and later"
# fall on either side of a line break is invisible to a line-local grep, and
# `0.7.0`'s and `0.1.0`'s are both exactly that (which is why #561's own body
# counts ten notes where an unwrapped scan finds more).
#
# One note is deliberately not a row, and bin/ceremony-upgrade's table
# comment names it: #501's 0.7.7, excluded by this window, and by #561's
# happy path moving 0.7.6 -> 0.7.7 and requiring it to succeed.
#
# #559's was the other, and the 0.7.8 cut ended that: its "available at
# **unreleased** and later" had no tag to key a row on, the release cleared
# the marker to `0.7.8`, and this scan found the tag before any row carried
# it — which is the ratchet firing as designed, not a regression.
availability_tags() {
  awk '
    /^[[:space:]]*$/ { if (p != "") { print p; p = "" }; next }
    { p = p " " $0 }
    END { if (p != "") print p }
  ' "$ROOT/docs/CONSUMERS.md" |
    awk '
      {
        s = $0
        while (match(s, /[0-9]+\.[0-9]+\.[0-9]+`?[ ]+and later/)) {
          before = substr(s, 1, RSTART - 1)
          if (length(before) > 100) {
            before = substr(before, length(before) - 99)
          }
          if (before ~ /available/) {
            tok = substr(s, RSTART, RLENGTH)
            sub(/`?[ ]+and later/, "", tok)
            print tok
          }
          s = substr(s, RSTART + RLENGTH)
        }
      }
    ' | LC_ALL=C sort -u
}

table_gap() {
  local tag
  while IFS= read -r tag; do
    grep -q "^  \"$tag|" "$ROOT/bin/ceremony-upgrade" ||
      printf 'UNCOVERED %s\n' "$tag"
  done < <(availability_tags)
  echo "scanned"
}
check_absent "every availability tag in docs/CONSUMERS.md carries a migration row" 0 "UNCOVERED" \
  table_gap
check "the table-gap row ran rather than exiting early" 0 "scanned" table_gap

# ...and the scan is NOT VACUOUS. A regex that silently matched nothing
# satisfies the row above forever, which is the shape #525 hit: a weakened
# check passes the suite and proves nothing. The floor is the tags the issue
# itself enumerates, so this row fails if the prose moves out from under the
# scan as well as if the scan breaks.
tags_line() { availability_tags | tr '\n' ' '; }
check "the prose scan finds the tags #561's own table names" 0 "0.2.0 0.3.0 0.4.1 0.5.0 0.6.0" \
  tags_line
check "the prose scan finds every tag the migration table carries" 0 "0.1.0 0.2.0 0.3.0 0.4.1 0.5.0 0.6.0 0.7.0" \
  tags_line

# ============================================================================
# Round 1 — the writes are the plan
#
# Every row below is a defect the panel reproduced at cf3d80b, and none of
# the 88 rows above it would have caught any of them. They share one shape:
# --check announced a plan and --fix did something else, at exit 0.
# ============================================================================

# --- a sibling repository is not this repository (claude-bot §1) -------------
#
# The rewrite used to match `heavy-duty/ceremony([^@ \t]*)?@`, a SUPERSET of
# PIN_RE with the anchoring '/' missing, so any repo whose name merely STARTS
# with `ceremony` was rewritten — never enumerated, never reported, never part
# of the all-or-none comparison. The org has no such sibling today; its own
# naming precedent (rig/rig-templates, bulldozer/bulldozer-examples) is that
# it produces them.
#
# This is the sed build at one line's width: a third-party action pinned to a
# tag that has nothing to do with ceremony, moved to a ceremony tag, in a file
# the operator was told carried one pin.
consumer sibling 0.7.6
cat >>"$TMP/sibling/.github/workflows/ci.yml" <<'YAML'
      - uses: heavy-duty/ceremony-templates/actions/foo@v1
      - uses: heavy-duty/ceremonyzilla@v2
YAML

check "a sibling-named repo is not counted as a pin" 0 \
  "0.7.6 -> 0.7.7, $PIN_COUNT ceremony ref(s) in 4 file(s)" \
  in_consumer sibling --check --source "$SRC" 0.7.7
check "--fix moves the real pins in the sibling fixture" 0 \
  "rewrote $PIN_COUNT ceremony ref(s)" \
  in_consumer sibling --fix --source "$SRC" 0.7.7
sibling_refs() { grep -oE 'heavy-duty/ceremony[A-Za-z-]*[^ ]*@[A-Za-z0-9._-]+' "$TMP/sibling/.github/workflows/ci.yml"; }
check "the sibling repo keeps its own ref through --fix" 0 \
  "heavy-duty/ceremony-templates/actions/foo@v1" sibling_refs
check "a sibling repo with no path keeps its ref too" 0 \
  "heavy-duty/ceremonyzilla@v2" sibling_refs
check_absent "no sibling ref was moved to the ceremony tag" 0 \
  "ceremony-templates/actions/foo@0.7.7" sibling_refs
check "the real pin in that same file did move" 0 \
  "heavy-duty/ceremony/actions/docs-sync@0.7.7" sibling_refs

# --- the dedup key that collided (claude-bot §2) -----------------------------
#
# `tr '/' '_'` is not injective: 'a/b.yml' and 'a_b.yml' keyed to the same
# stamp, so the second file was skipped, the run wrote one of the two files it
# had just announced, and said `done` at exit 0. That is all-or-none broken in
# the direction that is not a refusal — a half-applied move the operator is
# told is complete, and one the NEXT run then refuses as a mixed tree.
consumer collide 0.7.6
mkdir -p "$TMP/collide/.github/workflows/a"
printf 'jobs:\n  x:\n    uses: heavy-duty/ceremony/.github/workflows/one.yml@0.7.6\n' \
  >"$TMP/collide/.github/workflows/a/b.yml"
printf 'jobs:\n  y:\n    uses: heavy-duty/ceremony/.github/workflows/two.yml@0.7.6\n' \
  >"$TMP/collide/.github/workflows/a_b.yml"

check "--check counts both halves of the colliding path pair" 0 \
  "0.7.6 -> 0.7.7, $((PIN_COUNT + 2)) ceremony ref(s) in 6 file(s)" \
  in_consumer collide --check --source "$SRC" 0.7.7
check "--fix moves both halves of the colliding path pair" 0 \
  "rewrote $((PIN_COUNT + 2)) ceremony ref(s) in 6 file(s) to @0.7.7" \
  in_consumer collide --fix --source "$SRC" 0.7.7
check_absent "no ref is left behind under a colliding key" 0 "0.7.6" refs collide
check "every ref in the colliding fixture is at the target" 0 \
  "$((PIN_COUNT + 2)) 0.7.7" refs collide

# --- the byte outside the pin line (claude-bot §4) ---------------------------
#
# awk's `print` terminates every record, so a workflow file that ended without
# a newline came back one byte longer. #561 G8 says this command touches
# nothing outside the `uses:` line, and that byte is outside it.
consumer nonewline 0.7.6
printf 'jobs:\n  z:\n    uses: heavy-duty/ceremony/.github/workflows/three.yml@0.7.6' \
  >"$TMP/nonewline/.github/workflows/tail.yml"
final_byte_is_newline() {
  if [ "$(tail -c 1 "$TMP/nonewline/.github/workflows/tail.yml" | wc -l)" -eq 0 ]; then
    echo "no-final-newline"
  else
    echo "final-newline"
  fi
}
check "the fixture really does lack a final newline before the run" 0 \
  "no-final-newline" final_byte_is_newline
check "--fix moves the pin in the file that has no final newline" 0 \
  "rewrote $((PIN_COUNT + 1)) ceremony ref(s)" \
  in_consumer nonewline --fix --source "$SRC" 0.7.7
check "the missing final newline is still missing after --fix" 0 \
  "no-final-newline" final_byte_is_newline
check "the pin in that file moved all the same" 0 \
  "three.yml@0.7.7" \
  cat "$TMP/nonewline/.github/workflows/tail.yml"

# --- the transaction across the docs-sync call (codex-bot, blocking) ---------
#
# `every check runs before any write` was true of this command and false of
# the pair. docs-sync's scaffold refusal — `markers are duplicated|unbalanced`
# — fires INSIDE its fix loop, after the mirror and the root AGENTS.md stub
# are written. Sequence a pin rewrite in front of it and an otherwise-valid
# adjacent move leaves the consumer pinned forward at the target with a
# half-written mirror and none of the hand edits a pin implies: exactly the
# half-upgraded tree this command exists to make unrepresentable.
#
# A source tree of its own, because naming a guarded scaffold changes what
# docs-sync demands of EVERY consumer above.
SRC_SCAF="$TMP/src-scaffold"
cp -pPR "$SRC" "$SRC_SCAF"
mkdir -p "$SRC_SCAF/.github"
printf '.github/pull_request_template.md\n' >"$SRC_SCAF/docs/SCAFFOLDED.txt"
printf '## Checklist\n\n- [ ] a thing\n' >"$SRC_SCAF/.github/pull_request_template.md"

# One start marker and no end: `unbalanced`, which docs-sync refuses rather
# than guessing where the consumer's own bytes resume.
consumer broken-marker 0.7.6
printf 'Our own template.\n\n<!-- ceremony:pr-template:start -->\n\nnever closed\n' \
  >"$TMP/broken-marker/.github/pull_request_template.md"

check "the docs-sync refusal reaches the operator" 1 \
  "cannot fix .github/pull_request_template.md" \
  in_consumer broken-marker --fix --source "$SRC_SCAF" 0.7.7
check "a refused move says the tree was rolled back" 1 \
  "rolled back" \
  in_consumer broken-marker --fix --source "$SRC_SCAF" 0.7.7

# A FRESH FIXTURE FOR THE FINGERPRINT ROW, and it is the difference between a
# measurement and a coincidence. `unchanged` takes its `before` from whatever
# the rows above left behind — so against a build that does not roll back, the
# two rows above have ALREADY moved the pins and written the mirror, and this
# row would compare a half-upgraded tree with itself and pass. Rebuilding puts
# the run that must write nothing on a tree that has never been written to.
consumer broken-marker 0.7.6
printf 'Our own template.\n\n<!-- ceremony:pr-template:start -->\n\nnever closed\n' \
  >"$TMP/broken-marker/.github/pull_request_template.md"
unchanged "a docs-sync refusal mid-fix leaves the WHOLE tree byte-identical" \
  "$TMP/broken-marker" \
  in_consumer broken-marker --fix --source "$SRC_SCAF" 0.7.7
check "the pins did not move under a rolled-back run" 0 "$PIN_COUNT 0.7.6" \
  refs broken-marker
check_absent "the rolled-back run left no ref at the target" 0 "0.7.7" \
  refs broken-marker
# The mirror is the other half of what a partial write leaves: docs-sync had
# already added .ceremony/ and the root AGENTS.md stub by the time it refused.
mirror_state() {
  if [ -e "$TMP/broken-marker/.ceremony" ] || [ -e "$TMP/broken-marker/AGENTS.md" ]; then
    echo "mirror-partially-written"
  else
    echo "no-mirror"
  fi
}
check "the rolled-back run left no half-written mirror either" 0 "no-mirror" \
  mirror_state

# RESTORE, NOT DELETE. The row above only proves the rollback removes what the
# run created — a rollback that simply `rm -rf`'d the territory would pass it,
# and would destroy the mirror of every consumer that already had one. This
# fixture arrives with a STALE .ceremony/ and a root AGENTS.md the repo has
# since edited, both of which docs-sync would have rewritten before it refused,
# and both of which must come back byte for byte.
consumer had-mirror 0.7.6
printf 'Our own template.\n\n<!-- ceremony:pr-template:start -->\n\nnever closed\n' \
  >"$TMP/had-mirror/.github/pull_request_template.md"
mkdir -p "$TMP/had-mirror/.ceremony"
printf '# router, as of the OLD pin\n' >"$TMP/had-mirror/.ceremony/AGENTS.md"
printf '# rules, as of the OLD pin\n' >"$TMP/had-mirror/.ceremony/RULES.md"
printf 'stale, and not in the manifest\n' >"$TMP/had-mirror/.ceremony/GONE.md"
printf '# our own router stub, edited by us\n' >"$TMP/had-mirror/AGENTS.md"

unchanged "a rollback restores a mirror that was already there" \
  "$TMP/had-mirror" \
  in_consumer had-mirror --fix --source "$SRC_SCAF" 0.7.7
check "the pre-existing mirror came back with its old bytes" 0 \
  "as of the OLD pin" cat "$TMP/had-mirror/.ceremony/AGENTS.md"
check "the orphan docs-sync would have deleted came back too" 0 \
  "not in the manifest" cat "$TMP/had-mirror/.ceremony/GONE.md"
check "the consumer's own root AGENTS.md came back untouched" 0 \
  "edited by us" cat "$TMP/had-mirror/AGENTS.md"

# The fixture is not vacuous: with the marker closed, the SAME move over the
# SAME source tree succeeds and writes the scaffold. Without this row the one
# above passes for a tree that could never have been upgraded at all.
consumer good-marker 0.7.6
printf 'Our own template.\n\n<!-- ceremony:pr-template:start -->\nold\n<!-- ceremony:pr-template:end -->\n' \
  >"$TMP/good-marker/.github/pull_request_template.md"
check "the same move over the same source succeeds with the marker closed" 0 \
  "0.7.6 -> 0.7.7 done" \
  in_consumer good-marker --fix --source "$SRC_SCAF" 0.7.7
check "the guarded scaffold really was written on the successful run" 0 \
  "a thing" cat "$TMP/good-marker/.github/pull_request_template.md"
check "a successful run does not claim a rollback" 0 "$PIN_COUNT 0.7.7" \
  refs good-marker

# --- the write territory is a declaration, so it gets a ratchet --------------
#
# bin/ceremony-upgrade snapshots .github/, .ceremony/ and the root's regular
# files, and restores exactly those on a failure. That set is DECLARED rather
# than derived from docs/VENDORED.txt and docs/SCAFFOLDED.txt, because a
# second reader of docs-sync's manifests is the two-readers-disagree bug this
# round is about. So the declaration is ratcheted here instead: the day a
# scaffold path lands outside those roots, ceremony's own CI says so, before
# any consumer runs a --fix whose rollback would silently miss it.
#
# The mirror needs no row — docs-sync writes every manifest path under
# .ceremony/ by construction — but the root AGENTS.md stub and every
# SCAFFOLDED.txt path are real paths in a consumer tree.
outside_territory() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      .github/* | .ceremony/*) ;;
      */*) printf 'OUTSIDE %s\n' "$f" ;;
      *) ;; # a bare name is a regular file at the root, which is snapshotted
    esac
  done <"$ROOT/docs/SCAFFOLDED.txt"
  echo "scanned"
}
check_absent "every guarded scaffold path is inside the snapshotted territory" 0 \
  "OUTSIDE" outside_territory
check "the territory scan ran rather than exiting early" 0 "scanned" outside_territory
# Not vacuous: the manifest is non-empty, so the loop above had something to
# grade. A SCAFFOLDED.txt that emptied out would satisfy the row forever.
check "docs/SCAFFOLDED.txt names at least one path to grade" 0 \
  ".github/pull_request_template.md" cat "$ROOT/docs/SCAFFOLDED.txt"

# ============================================================================
# The applied step — 0.4.1's two-caller split (#597)
# ============================================================================
#
# THE INPUTS ARE THE REAL CONSUMERS, measured 2026-09-02 from each board's live
# `.github/workflows/labels.yml`, and they are the whole reason this step is
# not a `sed`: neither file resembles the published stub. Both carry
# repo-specific prose comments, different trigger type lists, different
# permission blocks, and a `*/15` cadence that is not the stub's hourly one. A
# step written against the stub's bytes fails on both of them, and a step that
# substitutes text corrupts whichever one it does not fail on.

# barbershop_caller <ref> — heavy-duty/martin-reyes-barbershop's own labels
# caller, verbatim but for the pin: a schedule and a bare workflow_dispatch
# each carrying a trailing hand comment, six permissions including
# `actions: read` with inline comments of its own, and an `issues:` trigger.
barbershop_caller() {
  cat <<EOF
# The ceremony's labels automation: additive path-based \`scope:*\` labels, plus
# reconciliation of PR state, blockers, handoff and stale status.
#
# Run its \`workflow_dispatch\` ONCE after this merges — that bootstraps the whole
# taxonomy on a fresh repo, \`release\` included.
name: labels
on:
  schedule: [{cron: "*/15 * * * *"}] # advisory; the handoff label is the real wake
  workflow_dispatch:                 # bootstraps missing labels on a fresh repo
  pull_request_target:
    types: [opened, reopened, ready_for_review, converted_to_draft, synchronize, labeled, unlabeled, review_requested, review_request_removed]
  issues:
    types: [opened, edited, assigned, unassigned, labeled, unlabeled, closed, reopened]
permissions:
  contents: read
  issues: write
  pull-requests: write
  # This repo is PRIVATE, so none of these three reads are implied — without
  # them the failure appears as an empty \`state:*\` axis on the board rather than
  # a red run, which is the harder symptom to notice.
  checks: read     # statusCheckRollup read for PR state
  statuses: read   # mergeability/commit-status rollup read
  actions: read    # checkSuite.workflowRun read
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
EOF
}

# cast_caller <ref> — heavy-duty/cast's own labels caller, verbatim but for the
# pin. Three permissions and NO \`actions:\` key at all, no \`issues:\` trigger,
# and the same */15 cadence.
cast_caller() {
  cat <<EOF
name: labels
# The automation LABELS.md promises, now implemented upstream: scope labeling
# and the state reconciler live in the reusable workflow this caller pins. Cast
# keeps the triggers and permissions (a called workflow cannot define them),
# its path map in .github/labeler.yml, and its panel + scope taxonomy in
# .github/labels.conf.
on:
  schedule: [{cron: "*/15 * * * *"}] # advisory; the handoff label is the real wake
  workflow_dispatch:                 # bootstraps missing labels on a fresh repo
  pull_request_target:
    types: [opened, reopened, ready_for_review, converted_to_draft, synchronize, labeled, unlabeled]
permissions:
  contents: read
  issues: write
  pull-requests: write
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
EOF
}

# split_consumer <name> <ref> <caller-fn> — consumer() with its labels caller
# replaced by a real one, plus a SIBLING workflow of the consumer's own that
# carries its own schedule and its own bare workflow_dispatch. That sibling is
# the fixture for the file-wide-substitution build: a step that removes a cron
# by pattern rather than by the line it enumerated takes this file's with it.
split_consumer() {
  local name="$1" ref="$2" fn="$3"
  consumer "$name" "$ref"
  "$fn" "$ref" >"$TMP/$name/.github/workflows/labels.yml"
  cat >"$TMP/$name/.github/workflows/nightly.yml" <<'EOF'
name: nightly
on:
  schedule: [{cron: "0 3 * * *"}]
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: make nightly
EOF
}

sweep_of() { cat "$TMP/$1/.github/workflows/labels-sweep.yml"; }
caller_of() { cat "$TMP/$1/.github/workflows/labels.yml"; }
# The files carrying a top-level-ish `schedule:` key, bracketed so a superset
# cannot satisfy the row: this is the double-sweep assertion, and it is only
# an assertion if it can fail by finding one file too many.
schedule_sites() {
  printf '[%s]\n' "$(
    grep -rlE '^[[:space:]]*schedule:' "$TMP/$1/.github/workflows" |
      sed "s|$TMP/$1/||" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
  )"
}
occurrences() { grep -cF -e "$2" "$TMP/$1"; }

# --- A1, A2, A5, A6: the happy path -----------------------------------------

split_consumer bshop 0.3.0 barbershop_caller

# A5 first, on the untouched tree: --check prints the whole plan and writes
# nothing. Running it after the --fix below would grade the wrong tree.
check "--check names the applied step and the tag it stops at" 0 \
  "0.4.1 is an APPLIED STEP, so this run performs 0.3.0 -> 0.4.1 and stops there" \
  in_consumer bshop --check --source "$SRC" 0.4.1
check "--check names the file the step would create" 0 \
  "create .github/workflows/labels-sweep.yml" \
  in_consumer bshop --check --source "$SRC" 0.4.1
check "--check names the cron relocation and the cadence it preserves" 0 \
  'the cron RELOCATED from .github/workflows/labels.yml line 8, cadence unchanged: [{cron: "*/15 * * * *"}]' \
  in_consumer bshop --check --source "$SRC" 0.4.1
check "--check names the bare workflow_dispatch deletion" 0 \
  "the bare workflow_dispatch: key, which the sweep caller declares" \
  in_consumer bshop --check --source "$SRC" 0.4.1
check "--check names the actions: write grant as a line rewrite" 0 \
  "actions: write, the trigger job's dispatch being a write" \
  in_consumer bshop --check --source "$SRC" 0.4.1
check "--check names the mirror re-sync" 0 "then re-sync the doctrine mirror" \
  in_consumer bshop --check --source "$SRC" 0.4.1
check "--check names the pin the run would leave behind" 0 \
  "THIS RUN LEAVES THE PIN AT 0.4.1" \
  in_consumer bshop --check --source "$SRC" 0.4.1
unchanged "--check over an applied step leaves the whole tree byte-identical" \
  "$TMP/bshop" in_consumer bshop --check --source "$SRC" 0.4.1

# A6's baseline, taken before the run that must not move these files.
NIGHTLY_BEFORE="$(sha256sum <"$TMP/bshop/.github/workflows/nightly.yml")"

check "the applied step completes a move that ends at the crossed tag" 0 \
  "0.3.0 -> 0.4.1 done, including the applied step for 0.4.1" \
  in_consumer bshop --fix --source "$SRC" 0.4.1
check "every ref moved to the crossed tag, the created caller included" 0 \
  "$((PIN_COUNT + 1)) 0.4.1" refs bshop
check_absent "no ref is left at the old pin" 0 "0.3.0" refs bshop

# A1 — the sweep caller is the guide's stub at the crossed tag.
check "the sweep caller exists and carries the pin substituted" 0 \
  "uses: heavy-duty/ceremony/.github/workflows/labels-sweep.yml@0.4.1" \
  sweep_of bshop
check "the sweep caller declares the bootstrap choice input" 0 \
  "        type: choice" sweep_of bshop
check "the bootstrap input keeps its yes default" 0 \
  '        default: "yes"' sweep_of bshop
check "the sweep caller carries the consumer's OWN cadence, relocated" 0 \
  '  schedule: [{cron: "*/15 * * * *"}]' sweep_of bshop
check_absent "the stub's own hourly cadence was not written over it" 0 \
  '0 * * * *' sweep_of bshop
check "the sweep caller keeps the stub's actions: read" 0 \
  "  actions: read " sweep_of bshop

# A1 — the labels caller. The cron and the bare dispatch are GONE, not
# commented out and not emptied.
check_absent "the labels caller no longer declares a schedule" 0 "schedule:" \
  caller_of bshop
check_absent "the labels caller no longer declares a bare workflow_dispatch" 0 \
  "workflow_dispatch:" caller_of bshop
check "the labels caller now grants actions: write" 0 "  actions: write" \
  caller_of bshop
# The blind-append build ends with BOTH keys — YAML GitHub rejects at parse
# time, and a board that stops. The key appears once, with one value.
check "the actions key appears exactly once" 0 "1" occurrences bshop/.github/workflows/labels.yml "actions:"
check_absent "the old actions: read grant is gone" 0 "actions: read" caller_of bshop
check "the labels caller keeps its own trigger list untouched" 0 \
  "types: [opened, edited, assigned, unassigned, labeled, unlabeled, closed, reopened]" \
  caller_of bshop
check "the labels caller keeps its own permission comments" 0 \
  "# This repo is PRIVATE" caller_of bshop

# A2 — THE DOUBLE-SWEEP CASE, ASSERTED AS AN ABSENCE. Every other row here
# passes against a build that COPIES the cron instead of moving it: the sweep
# caller exists, carries the right cadence, the pin moved, actions: write
# landed. Only this one fails, and what it catches is the damage the guide
# capitalises — every tick firing both callers into one labels-reconcile
# group, displacement going UP, the fix reading as the bug getting worse.
#
# The sibling below is A6's, and it is why this row names the files rather
# than counting to one: the consumer's own nightly workflow has a schedule of
# its own that nothing in this plan may touch, so "exactly once in the tree"
# and "the sibling survives" cannot both be literally true. Naming the sites
# keeps both must-fail builds rejected — a copied cron adds the labels caller
# to this list, and a file-wide substitution removes the sibling from it.
check "the cron MOVED: the only ceremony caller carrying a schedule is the sweep one" 0 \
  "[.github/workflows/labels-sweep.yml .github/workflows/nightly.yml]" \
  schedule_sites bshop

# A6 — nothing outside the plan moved.
nightly_now() { sha256sum <"$TMP/bshop/.github/workflows/nightly.yml"; }
check "the consumer's own scheduled workflow is byte-identical" 0 \
  "$NIGHTLY_BEFORE" nightly_now
check "the consumer's README still names its own old version" 0 \
  "Pinned to ceremony 0.3.0" cat "$TMP/bshop/README.md"
check "the consumer's own CHANGELOG heading is untouched" 0 \
  "## 0.3.0 — 2026-02-02" cat "$TMP/bshop/CHANGELOG.md"
check "the mirror is current after the step, so docs-sync --check passes" 0 \
  "is an exact mirror" in_consumer_docs_sync bshop --check --source "$SRC"

# --- A4: the step stops at the first crossed tag ----------------------------
#
# The build this rejects applies 0.4.1 and KEEPS GOING, refusing at 0.5.0 with
# the refs already past 0.4.1 — the half-upgraded consumer the whole command
# exists to make unrepresentable.
split_consumer bshoplong 0.3.0 barbershop_caller
# The plan rows run BEFORE the --fix below: afterwards this tree stands at
# 0.4.1 and the same command grades a different move, so a row placed after it
# would assert nothing about a partial one.
check "the run says which pin it will leave the tree at" 1 \
  "THIS RUN LEAVES THE PIN AT 0.4.1" \
  in_consumer bshoplong --check --source "$SRC" 0.7.8
check "the run says what remains beyond it" 1 \
  "REMAINING: 0.4.1 -> 0.7.8 is not performed by this run" \
  in_consumer bshoplong --check --source "$SRC" 0.7.8
check "the run names the next migration between them" 1 \
  "The next migration between them is 0.5.0" \
  in_consumer bshoplong --check --source "$SRC" 0.7.8
check_absent "a partial move never reports the requested move as done" 1 \
  "0.3.0 -> 0.7.8 done" in_consumer bshoplong --check --source "$SRC" 0.7.8
unchanged "the partial-move plan writes nothing either" "$TMP/bshoplong" \
  in_consumer bshoplong --check --source "$SRC" 0.7.8
check "a move past the crossed tag performs only the first step" 1 \
  "0.3.0 -> 0.4.1 done, including the applied step for 0.4.1" \
  in_consumer bshoplong --fix --source "$SRC" 0.7.8
check "every ref stops at the first crossed tag" 0 "$((PIN_COUNT + 1)) 0.4.1" \
  refs bshoplong
check_absent "no ref ran on to the requested target" 0 "0.7.8" refs bshoplong
# The next run is the ladder's next rung, and it must be a real refusal at
# 0.5.0 rather than a second step: this is the row that proves the command
# stopped rather than merely paused.
check "the next run from the new pin refuses at the next unmechanised tag" 1 \
  "FIRST CROSSED TAG: 0.5.0" in_consumer bshoplong --check --source "$SRC" 0.7.8

# --- A3: an unmechanised first crossed tag still refuses, unchanged ---------
#
# cast at 0.1.0 is the honest measurement of what this issue does NOT buy: its
# first crossed tag is 0.2.0, which has no step, so the tag mechanised here is
# not reached and the refusal is the one that shipped before it existed.
split_consumer castold 0.1.0 cast_caller
check "an unmechanised first crossed tag refuses the whole move" 1 \
  "crosses 3 migration(s)" in_consumer castold --check --source "$SRC" 0.4.1
check "the refusal names the unmechanised tag it stops at" 1 \
  "FIRST CROSSED TAG: 0.2.0" in_consumer castold --check --source "$SRC" 0.4.1
check "the refusal still says the crossing is hand-only" 1 \
  "THE CROSSING IS HAND-ONLY" in_consumer castold --check --source "$SRC" 0.4.1
check_absent "no applied step is announced for an unmechanised tag" 1 \
  "APPLIED STEP" in_consumer castold --check --source "$SRC" 0.4.1
check_absent "no anchoring complaint is made about a tree never analysed" 1 \
  "CANNOT RUN ON THIS TREE" in_consumer castold --check --source "$SRC" 0.4.1
check_absent "a mechanised tag deeper in the interval does not leak a step" 1 \
  "THE PLAN" in_consumer castold --check --source "$SRC" 0.4.1
unchanged "the unmechanised refusal leaves the WHOLE tree byte-identical (--check)" \
  "$TMP/castold" in_consumer castold --check --source "$SRC" 0.4.1
unchanged "the unmechanised refusal leaves the WHOLE tree byte-identical (--fix)" \
  "$TMP/castold" in_consumer castold --fix --source "$SRC" 0.4.1

# --- D5: the consumer's own routing rides onto the new caller ---------------

named_caller() {
  cat <<EOF
name: board
on:
  schedule: [{cron: "17 * * * *"}]
  workflow_dispatch:
  pull_request_target:
    types: [opened]
permissions:
  contents: read
  issues: write
  actions: read
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
    with: { runner: '["self-hosted","ci-runner"]' }
EOF
}
split_consumer named 0.3.0 named_caller
check "a caller not named labels carries its name onto the sweep caller" 0 \
  "0.3.0 -> 0.4.1 done" in_consumer named --fix --source "$SRC" 0.4.1
# Both keys on ONE flow mapping: the guide says not to repeat `with:`, and a
# routing value that is itself a quoted JSON list is why the reader splitting
# that mapping has to know about quotes and brackets.
check "the sweep caller carries the name and the runner in one with: mapping" 0 \
  "    with: { pr_workflow_name: board, runner: '[\"self-hosted\",\"ci-runner\"]' }" \
  sweep_of named
check "the routed sweep caller keeps the consumer's own cadence" 0 \
  '  schedule: [{cron: "17 * * * *"}]' sweep_of named

# The insert path: cast's permission block has no `actions:` key at all, so
# the grant is an insertion rather than a rewrite. A step that only knows how
# to rewrite silently leaves that board's trigger job red on every event.
split_consumer noactions 0.3.0 cast_caller
check "--check calls the missing grant an insertion, not a rewrite" 0 \
  "insert after line" in_consumer noactions --check --source "$SRC" 0.4.1
check "a permissions block with no actions key gains one" 0 \
  "0.3.0 -> 0.4.1 done" in_consumer noactions --fix --source "$SRC" 0.4.1
check "the inserted grant is actions: write" 0 "  actions: write" caller_of noactions
check "the actions key appears exactly once after an insert" 0 "1" \
  occurrences noactions/.github/workflows/labels.yml "actions:"
check "the keys the block already had are still there" 0 "  pull-requests: write" \
  caller_of noactions

# The routing read looks at the whole job, not the line after the pin. A
# caller writing `secrets: inherit` between its `uses:` and its `with:` is
# ordinary, and the failure a reader that stopped early produces is the silent
# one: no routing carried, and nothing said about it.
secrets_caller() {
  cat <<EOF
name: board
on:
  schedule: [{cron: "*/15 * * * *"}]
  workflow_dispatch:
  pull_request_target:
    types: [opened]
permissions:
  contents: read
  actions: read
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
    secrets: inherit
    with: { runner: '"ubuntu-22.04"' }
EOF
}
split_consumer secretsfirst 0.3.0 secrets_caller
check "routing is carried past an intervening job key" 0 "0.3.0 -> 0.4.1 done" \
  in_consumer secretsfirst --fix --source "$SRC" 0.4.1
check "the runner behind secrets: inherit still reached the sweep caller" 0 \
  "    with: { pr_workflow_name: board, runner: '\"ubuntu-22.04\"' }" \
  sweep_of secretsfirst

# ...and a comment at the on: block's own indent does not end the scan that
# looks for a dispatch's inputs. This tree must still refuse.
commented_inputs_caller() {
  cat <<EOF
name: labels
on:
  schedule: [{cron: "*/15 * * * *"}]
  workflow_dispatch:
  # why this board keeps a dispatch of its own
    inputs:
      why:
        type: string
  pull_request_target:
    types: [opened]
permissions:
  contents: read
  actions: read
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
EOF
}
split_consumer commentedinputs 0.3.0 commented_inputs_caller
check "a comment does not hide a dispatch's inputs from the refusal" 1 \
  "dispatch inputs with it" in_consumer commentedinputs --check --source "$SRC" 0.4.1
unchanged "the commented-inputs refusal writes nothing" "$TMP/commentedinputs" \
  in_consumer commentedinputs --fix --source "$SRC" 0.4.1

# --- A7: every shape the step cannot anchor is a refusal --------------------
#
# Each of these is a tree where a best guess is available and wrong. The
# refusal is the ORDINARY crossed-migration refusal — the hand procedure is
# still the answer for this tree — plus a section naming what could not be
# anchored, so the reader is not sent to audit the whole file for it.

split_consumer sweeppresent 0.3.0 barbershop_caller
# No ceremony pin in it: the fixture is about the file EXISTING, and a pin
# here would make the row pass on the mixed-refs fault instead.
printf 'name: labels-sweep\non: {workflow_dispatch: {}}\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
  >"$TMP/sweeppresent/.github/workflows/labels-sweep.yml"
check "an existing sweep caller is a refusal, not a merge" 1 \
  "already exists. This step creates the sweep" \
  in_consumer sweeppresent --check --source "$SRC" 0.4.1
check "that refusal is still the crossed-migration refusal" 1 \
  "THE CROSSING IS HAND-ONLY" in_consumer sweeppresent --check --source "$SRC" 0.4.1
unchanged "the existing-sweep-caller refusal writes nothing" "$TMP/sweeppresent" \
  in_consumer sweeppresent --fix --source "$SRC" 0.4.1

twoschedule_caller() {
  cat <<EOF
name: labels
on:
  schedule: [{cron: "*/15 * * * *"}]
  schedule: [{cron: "0 * * * *"}]
  pull_request_target:
    types: [opened]
permissions:
  contents: read
  actions: read
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
EOF
}
split_consumer twoschedules 0.3.0 twoschedule_caller
check "two schedule keys are a refusal rather than a pick" 1 \
  "declares 'schedule:' 2 times" \
  in_consumer twoschedules --check --source "$SRC" 0.4.1
unchanged "the two-schedule refusal writes nothing" "$TMP/twoschedules" \
  in_consumer twoschedules --fix --source "$SRC" 0.4.1

inputs_caller() {
  cat <<EOF
name: labels
on:
  schedule: [{cron: "*/15 * * * *"}]
  workflow_dispatch:
    inputs:
      why:
        description: why this board is being swept by hand
        type: string
  pull_request_target:
    types: [opened]
permissions:
  contents: read
  actions: read
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
EOF
}
split_consumer dispatchinputs 0.3.0 inputs_caller
check "a workflow_dispatch carrying inputs is not silently deleted" 1 \
  "would delete the" in_consumer dispatchinputs --check --source "$SRC" 0.4.1
check "that refusal names the consumer's own dispatch inputs" 1 \
  "dispatch inputs with it" in_consumer dispatchinputs --check --source "$SRC" 0.4.1
unchanged "the dispatch-inputs refusal writes nothing" "$TMP/dispatchinputs" \
  in_consumer dispatchinputs --fix --source "$SRC" 0.4.1
check "the consumer's dispatch input is still there afterwards" 0 \
  "      why:" caller_of dispatchinputs

noperms_caller() {
  cat <<EOF
name: labels
on:
  schedule: [{cron: "*/15 * * * *"}]
  workflow_dispatch:
  pull_request_target:
    types: [opened]
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
EOF
}
split_consumer noperms 0.3.0 noperms_caller
check "a caller with no permissions block is a refusal" 1 \
  "has no top-level 'permissions:' block" \
  in_consumer noperms --check --source "$SRC" 0.4.1
check "that refusal says why the block is not created" 1 \
  "sets every unnamed one to none" \
  in_consumer noperms --check --source "$SRC" 0.4.1
unchanged "the no-permissions refusal writes nothing" "$TMP/noperms" \
  in_consumer noperms --fix --source "$SRC" 0.4.1

blockwith_caller() {
  cat <<EOF
name: labels
on:
  schedule: [{cron: "*/15 * * * *"}]
  workflow_dispatch:
  pull_request_target:
    types: [opened]
permissions:
  contents: read
  actions: read
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@$ref
    with:
      runner: '"ubuntu-22.04"'
EOF
}
split_consumer badwith 0.3.0 blockwith_caller
check "a with: block the step cannot read is a refusal" 1 \
  "writes 'with:' as a block" in_consumer badwith --check --source "$SRC" 0.4.1
check "that refusal says it will not carry routing it did not understand" 1 \
  "single-line flow mapping" in_consumer badwith --check --source "$SRC" 0.4.1
unchanged "the unreadable-with refusal writes nothing" "$TMP/badwith" \
  in_consumer badwith --fix --source "$SRC" 0.4.1

# --- A8: the stub has one source, and the step really reads it --------------
#
# The grep is the structural half — no copy of the block under bin/, and the
# occurrences are the ones this repository already had. The altered-source row
# is the behavioural half: point the step at a guide whose block has been
# changed and the changed bytes must land in the consumer, which no embedded
# default and no cached copy can produce.
sweep_stub_sites() {
  printf '[%s]\n' "$(git -C "$ROOT" grep -lF 'name: labels-sweep' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
}
check "the caller stub is declared in the guide, the reusable, the dogfood caller and the fixtures" 0 \
  "[.github/workflows/labels-sweep.yml .github/workflows/self-labels-sweep.yml docs/CONSUMERS.md test/ceremony-upgrade.test.sh test/fixtures/incubator-callers/.github/workflows/labels-sweep.yml]" \
  sweep_stub_sites
bin_stub_copies() {
  printf '[%s]\n' "$(git -C "$ROOT" grep -lF 'name: labels-sweep' -- bin | tr '\n' ' ' | sed 's/ $//')"
}
check "no copy of the caller stub ships under bin/" 0 "[]" bin_stub_copies

SRC_ALTERED="$TMP/src-altered"
cp -pPR "$SRC" "$SRC_ALTERED"
sed -i 's|^  # A manual full-board sweep\..*$|  # ALTERED IN THE SOURCE GUIDE, and only there.|' \
  "$SRC_ALTERED/docs/CONSUMERS.md"
split_consumer altered 0.3.0 barbershop_caller
check "the step writes the guide it was pointed at" 0 "0.3.0 -> 0.4.1 done" \
  in_consumer altered --fix --source "$SRC_ALTERED" 0.4.1
check "the altered guide's bytes are the ones that landed" 0 \
  "  # ALTERED IN THE SOURCE GUIDE, and only there." sweep_of altered
check_absent "the unaltered comment did not come from anywhere else" 0 \
  "A manual full-board sweep" sweep_of altered

# ...and a source tree whose guide has no such block fails loudly rather than
# falling back to a default. This is the row that would catch an embedded copy
# added later "just in case the read fails".
SRC_NOSTUB="$TMP/src-nostub"
cp -pPR "$SRC" "$SRC_NOSTUB"
printf '# Consumers\n\nnothing published here.\n' >"$SRC_NOSTUB/docs/CONSUMERS.md"
split_consumer nostub 0.3.0 barbershop_caller
check "a guide with no sweep-caller stub is a loud failure" 1 \
  "carries no sweep-caller stub" \
  in_consumer nostub --check --source "$SRC_NOSTUB" 0.4.1
check "that failure says there is no copy to fall back to" 1 \
  "will not write one it did not read" \
  in_consumer nostub --check --source "$SRC_NOSTUB" 0.4.1
unchanged "a missing stub writes nothing" "$TMP/nostub" \
  in_consumer nostub --fix --source "$SRC_NOSTUB" 0.4.1

# The tag the guide is read AT, graded where it is observable. The move asked
# for is 0.3.0 -> 0.7.8 and the crossed tag is 0.4.1, so the ladder is fetched
# at the target and the caller stub at the crossing — two different refs in
# one run. A build that read the stub at the target, or at a default branch,
# writes a consumer the bytes of a tag the crossing is not about.
split_consumer fetchguide 0.3.0 barbershop_caller
CURL_STUB_GUIDE="$SRC/docs/CONSUMERS.md"
export CURL_STUB_GUIDE
guide_urls() {
  local log="$TMP/curl-urls"
  : >"$log"
  (
    cd "$TMP/fetchguide" || return
    CURL_STUB=ok CURL_STUB_LOG="$log" bash "$SCRIPT" --check 0.7.8
  ) >/dev/null 2>&1
  grep 'CONSUMERS.md' "$log" || echo "no-guide-fetch"
}
check "the caller stub is fetched at the CROSSED tag" 0 \
  "https://raw.githubusercontent.com/heavy-duty/ceremony/0.4.1/docs/CONSUMERS.md" \
  guide_urls
check_absent "it is not fetched at the target that was asked for" 0 \
  "/0.7.8/docs/CONSUMERS.md" guide_urls
check_absent "and never from a branch" 0 "/main/docs/CONSUMERS.md" guide_urls

# --- A9: the rollback holds over the enlarged territory ---------------------
#
# The step writes two files the ref rewrite never touched, and docs-sync runs
# AFTER both. A rollback that only restores what the ref pass wrote leaves the
# sweep caller behind — a consumer whose board now has two callers, one of
# them pinned to a ref its own labels caller is not at.
write_src_guide "$SRC_SCAF"
split_consumer rollback 0.3.0 barbershop_caller
printf 'Our own template.\n\n<!-- ceremony:pr-template:start -->\n\nnever closed\n' \
  >"$TMP/rollback/.github/pull_request_template.md"
unchanged "a docs-sync refusal after an applied step rolls the WHOLE tree back" \
  "$TMP/rollback" in_consumer rollback --fix --source "$SRC_SCAF" 0.4.1
sweep_state() {
  if [ -e "$TMP/rollback/.github/workflows/labels-sweep.yml" ]; then
    echo "sweep-caller-left-behind"
  else
    echo "no-sweep-caller"
  fi
}
check "the rolled-back run left no sweep caller behind" 0 "no-sweep-caller" sweep_state
check "the rolled-back run left the cron where it was" 0 \
  '  schedule: [{cron: "*/15 * * * *"}] # advisory; the handoff label is the real wake' \
  caller_of rollback
check "the rolled-back run left the old permission grant alone" 0 \
  "  actions: read    # checkSuite.workflowRun read" caller_of rollback
check "the pins did not move under the rolled-back step" 0 "$PIN_COUNT 0.3.0" \
  refs rollback
check "the run said it rolled back" 1 "rolled back" \
  in_consumer rollback --fix --source "$SRC_SCAF" 0.4.1
# Not vacuous: with the marker closed the SAME move over the SAME source tree
# succeeds, so the row above is measuring a rollback and not an impossibility.
split_consumer rollback-ok 0.3.0 barbershop_caller
printf 'Our own template.\n\n<!-- ceremony:pr-template:start -->\nold\n<!-- ceremony:pr-template:end -->\n' \
  >"$TMP/rollback-ok/.github/pull_request_template.md"
check "the same move over the same source succeeds with the marker closed" 0 \
  "0.3.0 -> 0.4.1 done" in_consumer rollback-ok --fix --source "$SRC_SCAF" 0.4.1
check "and that run really did write the sweep caller" 0 \
  "labels-sweep.yml@0.4.1" sweep_of rollback-ok

summary
