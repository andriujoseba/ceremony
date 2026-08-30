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

LADDER_TAGS="0.7.7 0.7.6 0.7.5 0.7.4 0.7.3 0.7.2 0.7.1 0.7.0 0.6.0 0.5.0 0.4.1 0.4.0 0.3.0 0.2.0 0.1.0"
{
  printf '# Changelog\n\n## Unreleased\n\n- nothing yet\n\n'
  for t in $LADDER_TAGS; do
    printf '## %s — 2026-01-01\n\n### Changed\n\n- a release\n\n' "$t"
  done
} >"$SRC/CHANGELOG.md"

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
mkdir -p "$TMP/stub"
cat >"$TMP/stub/curl" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  prev="$arg"
done
case "${CURL_STUB:-none}" in
  ok)
    cp "$CURL_STUB_BODY" "$out"
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
check_absent "--check never claims to have rewritten a ref" 0 "rewrote the ceremony ref" \
  in_consumer happy --source "$SRC" 0.7.7

check "--fix rewrites the refs" 0 "rewrote the ceremony ref in 4 file(s) to @0.7.7" \
  in_consumer happy --fix --source "$SRC" 0.7.7
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

check "a move crossing migrations is refused" 1 "crosses 6 migration(s)" \
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
check_absent "a 5xx does not accuse the tag" 1 "does not exist upstream" \
  run_fetch happyfetch 503 --check 0.7.7
unchanged "a failed fetch writes nothing" "$TMP/happyfetch" \
  run_fetch happyfetch 503 --fix 0.7.7
# The stub's default mode refuses and exits 99, so this row is the proof that
# the assertion behind every --source row above is a real one: take --source
# away and the network is genuinely what the command reaches for.
check "without --source the command really does reach for the network" 1 "" \
  run_fetch happyfetch none --check 0.7.7

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
# Two notes are deliberately not rows, and bin/ceremony-upgrade's table
# comment names both: #501's 0.7.7 (excluded by this window, and by #561's
# happy path moving 0.7.6 -> 0.7.7 and requiring it to succeed), and #559's
# "available at **unreleased** and later", which has no tag to key a row on.
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

summary
