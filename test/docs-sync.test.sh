#!/usr/bin/env bash
# Contract tests for actions/docs-sync (issue #19). Constructed SOURCE trees
# (a fake ceremony: manifest + docs) and CONSUMER trees (a release.yml
# caller with the pin line). Both source paths run offline: --source
# directly, and the tarball fetch through a `curl` stub first on PATH whose
# default mode refuses — which is also what proves the --source rows open no
# socket at all (#393). The fake source's doc set is deliberately NOT the
# real five: a script that
# hardcodes the vendored list instead of reading the manifest fails these
# rows. set -u, not -e: failing commands are behavior for the harness to
# inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/actions/docs-sync/docs-sync.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The real manifest is asserted by test/vendored.test.sh, not here (#251 D4).
# A `grep -Fx RELEASES.md` row lived at this spot from #248's review round,
# binding the promise to the one file that had nearly been missed. It was the
# hardcoded list the manifest exists to abolish, one layer down: two spellings
# of "the manifest is right" is exactly the drift it prevents. Its intent —
# every root doctrine file is declared, RELEASES.md included — is now a
# closed-world guard case, which the next file inherits for free.

# --- fixture builders --------------------------------------------------------

# The main fake ceremony tree: three manifest entries, one in a subdirectory
# (the manifest is paths, not filenames — the mirror must carry structure).
SRC="$TMP/src"
mkdir -p "$SRC/docs" "$SRC/guide"
printf 'AGENTS.md\nRULES.md\nguide/DEEP.md\n' >"$SRC/docs/VENDORED.txt"
printf '# router v1\n' >"$SRC/AGENTS.md"
printf '# rules v1\n' >"$SRC/RULES.md"
printf '# deep v1\n' >"$SRC/guide/DEEP.md"

# The same tree after a manifest removal: RULES.md is no longer vendored
# (the file itself may even still exist at the source — the MANIFEST is
# what defines the set).
SRC_DROPPED="$TMP/src-dropped"
cp -r "$SRC" "$SRC_DROPPED"
printf 'AGENTS.md\nguide/DEEP.md\n' >"$SRC_DROPPED/docs/VENDORED.txt"

# consumer <name> [pin-ref...] — a consumer tree whose release.yml carries
# one pin line per ref given (none → a caller with no pin at all).
consumer() {
  local dir="$TMP/$1" ref
  shift
  rm -rf "$dir"
  mkdir -p "$dir/.github/workflows"
  {
    printf 'name: release\non:\n  push:\n    branches: [main]\njobs:\n  release:\n'
    for ref in "$@"; do
      printf '    uses: heavy-duty/ceremony/.github/workflows/release.yml@%s\n' "$ref"
    done
  } >"$dir/.github/workflows/release.yml"
}

# in_consumer <name> <args...> — run the script from inside a consumer tree.
in_consumer() {
  local dir="$1"
  shift
  (cd "$TMP/$dir" && bash "$SCRIPT" "$@")
}

# --- the curl stub -------------------------------------------------------------
# The fetch path's stand-in for the network, selected per call site by
# CURL_STUB and modelled on facts.test.sh's gh stub. It parses `-o <path>`
# out of its arguments and prints the status code on stdout, exactly as
# -w '%{http_code}' makes real curl do. The default mode REFUSES, which is
# not decoration: with the stub first on PATH for the whole file, every
# pre-existing --source row below becomes a proof that the --source path
# calls no curl at all (#393).

# The tarball the `ok` mode serves: $SRC packed under ONE leading path
# component, the way codeload's archives are, so --strip-components=1 is
# genuinely exercised instead of assumed.
FIXTURE_TARBALL="$TMP/ceremony-fixture.tar.gz"
mkdir -p "$TMP/pack"
cp -r "$SRC" "$TMP/pack/ceremony-0.3.0"
tar -czf "$FIXTURE_TARBALL" -C "$TMP/pack" ceremony-0.3.0

mkdir -p "$TMP/stub"
cat >"$TMP/stub/curl" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  prev="$arg"
done

# A body only has somewhere to go if the caller downloads to a file: an
# implementation that piped curl into tar would reach here with no -o, and
# it should say so rather than fail somewhere downstream.
need_out() {
  [ -n "$out" ] && return 0
  echo "curl stub: no -o <path> — the fetch must download to a file (curl $*)" >&2
  exit 98
}

case "${CURL_STUB:-none}" in
  ok)
    need_out "$@"
    cp "$CURL_STUB_TARBALL" "$out"
    printf '200'
    ;;
  corrupt)
    need_out "$@"
    printf 'this is not a gzip stream\n' >"$out"
    printf '200'
    ;;
  503)
    printf '503'
    exit 22
    ;;
  404)
    printf '404'
    exit 22
    ;;
  netfail)
    printf '000'
    exit 7
    ;;
  *)
    # The tripwire, not just the exit status: a caller that swallowed the
    # failure (`curl … || true`) would otherwise slip past a refusal that
    # only speaks through $?, and the --source rows' proof would be worth
    # less than it looks.
    printf '%s\n' "curl $*" >>"$CURL_STUB_TRIPWIRE"
    echo "curl stub: curl must not be called (curl $*)" >&2
    exit 97
    ;;
esac
EOF
chmod +x "$TMP/stub/curl"

# Exported at file scope: in_consumer's `bash "$SCRIPT"` is a child process,
# so a plain assignment would never reach it.
export PATH="$TMP/stub:$PATH"
export CURL_STUB=none
export CURL_STUB_TARBALL="$FIXTURE_TARBALL"
export CURL_STUB_TRIPWIRE="$TMP/curl-was-called"

# fetched <mode> <consumer> <args...> — in_consumer on the FETCH path (no
# --source) with the stub in one mode, restoring the refusing default after.
fetched() {
  local mode="$1"
  shift
  CURL_STUB="$mode"
  in_consumer "$@"
  local rc=$?
  CURL_STUB=none
  return "$rc"
}

# --- the pin: never guessed --------------------------------------------------

consumer no-pin
check "pin line absent → refuse, naming the workflow file" 1 \
  ".github/workflows/release.yml" in_consumer no-pin --check --source "$SRC"
check "pin refusal says it never guesses" 1 "never guesses a ref" \
  in_consumer no-pin --check --source "$SRC"

consumer two-pins 0.3.0 0.4.0
check "two pin lines → refuse (ambiguous)" 1 "exactly one" \
  in_consumer two-pins --check --source "$SRC"

# Ceremony's own release.yml carries the pin SHAPE inside a header comment;
# a consumer pasting documentation into a comment must not double its pin.
consumer commented-pin 0.3.0
printf '  # docs say: uses: heavy-duty/ceremony/.github/workflows/release.yml@<tag>\n' \
  >>"$TMP/commented-pin/.github/workflows/release.yml"
check "a commented-out pin line does not count as a second pin" 0 "" \
  in_consumer commented-pin --fix --source "$SRC"
check "commented pin: the mirror checks clean" 0 "exact mirror" \
  in_consumer commented-pin --check --source "$SRC"

rm -rf "$TMP/no-workflow"
mkdir -p "$TMP/no-workflow"
check "missing release.yml entirely → refuse, naming it" 1 \
  "no .github/workflows/release.yml" in_consumer no-workflow --check --source "$SRC"
check "missing release.yml explains the no-artifact caller" 1 \
  "publishes no artifact still carries this caller" \
  in_consumer no-workflow --check --source "$SRC"

# --- the manifest: single source of the set -----------------------------------

consumer fresh 0.3.0
mkdir -p "$TMP/empty-src"
check "source without a manifest → refuse" 1 "docs/VENDORED.txt" \
  in_consumer fresh --check --source "$TMP/empty-src"

mkdir -p "$TMP/blank-src/docs"
printf '\n  \n' >"$TMP/blank-src/docs/VENDORED.txt"
check "empty manifest → refuse (a ceremony bug, not an empty set)" 1 "empty" \
  in_consumer fresh --check --source "$TMP/blank-src"

mkdir -p "$TMP/ghost-src/docs"
printf 'GHOST.md\n' >"$TMP/ghost-src/docs/VENDORED.txt"
check "manifest naming a file the source lacks → refuse" 1 "GHOST.md" \
  in_consumer fresh --check --source "$TMP/ghost-src"

mkdir -p "$TMP/escape-src/docs"
printf '../evil.md\n' >"$TMP/escape-src/docs/VENDORED.txt"
check "manifest path escaping the mirror → refuse" 1 "refusing manifest path" \
  in_consumer fresh --fix --source "$TMP/escape-src"

# --- fix: from empty to exact mirror -------------------------------------------

check "check before any fix → .ceremony/ missing entirely" 1 \
  "missing entirely" in_consumer fresh --check --source "$SRC"

check "--fix from empty writes the manifest set" 0 "added .ceremony/RULES.md" \
  in_consumer fresh --fix --source "$SRC"
check "vendored file is byte-identical to its source" 0 "" \
  cmp "$SRC/RULES.md" "$TMP/fresh/.ceremony/RULES.md"
check "a subdirectory manifest path mirrors with its directory" 0 "" \
  cmp "$SRC/guide/DEEP.md" "$TMP/fresh/.ceremony/guide/DEEP.md"

check "--fix generated the README" 0 "" test -f "$TMP/fresh/.ceremony/README.md"
check "README marks the dir machine-managed" 0 "achine-managed" \
  cat "$TMP/fresh/.ceremony/README.md"
check "README names where the pin lives" 0 ".github/workflows/release.yml" \
  cat "$TMP/fresh/.ceremony/README.md"

check "--fix scaffolded the root AGENTS.md stub" 0 ".ceremony/AGENTS.md" \
  cat "$TMP/fresh/AGENTS.md"

check "in-sync mirror → check passes" 0 "exact mirror" \
  in_consumer fresh --check --source "$SRC"
check "--fix is idempotent (second run changes nothing, exits 0)" 0 \
  "nothing to do" in_consumer fresh --fix --source "$SRC"

# --- check: every kind of drift fails, naming the offender ---------------------

printf 'edited in place\n' >>"$TMP/fresh/.ceremony/RULES.md"
check "one byte changed in a vendored file → check fails naming it" 1 \
  ".ceremony/RULES.md" in_consumer fresh --check --source "$SRC"
check "drift message teaches the fix" 1 "run docs-sync --fix" \
  in_consumer fresh --check --source "$SRC"
check "--fix repairs the drift" 0 "updated .ceremony/RULES.md" \
  in_consumer fresh --fix --source "$SRC"

rm "$TMP/fresh/.ceremony/RULES.md"
check "vendored file missing → check fails naming it" 1 \
  ".ceremony/RULES.md is missing" in_consumer fresh --check --source "$SRC"
in_consumer fresh --fix --source "$SRC" >/dev/null

printf 'stray\n' >"$TMP/fresh/.ceremony/STRAY.md"
check "extra file under .ceremony/ → check fails naming it" 1 \
  ".ceremony/STRAY.md" in_consumer fresh --check --source "$SRC"
check "--fix deletes the extra (mirror means mirror)" 0 \
  "deleted .ceremony/STRAY.md" in_consumer fresh --fix --source "$SRC"
check "the extra is gone from disk" 1 "" test -f "$TMP/fresh/.ceremony/STRAY.md"

# A manifest removal at the source: the orphaned vendored copy goes too.
check "--fix after manifest removal deletes the orphan" 0 \
  "deleted .ceremony/RULES.md" in_consumer fresh --fix --source "$SRC_DROPPED"
check "post-removal mirror is exact (and counts 2 files)" 0 "(2 files)" \
  in_consumer fresh --check --source "$SRC_DROPPED"
in_consumer fresh --fix --source "$SRC" >/dev/null

# --- the root AGENTS.md stub: created once, never owned -------------------------

printf '# my own router, heavily edited\n' >"$TMP/fresh/AGENTS.md"
check "edited root AGENTS.md → check passes (content is per-repo)" 0 \
  "exact mirror" in_consumer fresh --check --source "$SRC"
check "--fix never overwrites an existing root AGENTS.md" 0 "nothing to do" \
  in_consumer fresh --fix --source "$SRC"
check "the edit survived --fix" 0 "my own router" cat "$TMP/fresh/AGENTS.md"

rm "$TMP/fresh/AGENTS.md"
check "root AGENTS.md missing → check fails, teaching --fix" 1 \
  "run docs-sync --fix" in_consumer fresh --check --source "$SRC"
in_consumer fresh --fix --source "$SRC" >/dev/null

# --- the README is machine-verified, not just machine-written -------------------
# The marker that says "a hand edit goes red" must itself go red when
# hand-edited (kimi-bot, PR #43's review round).

printf 'hand edit\n' >>"$TMP/fresh/.ceremony/README.md"
check "hand-edited README → check fails naming it" 1 ".ceremony/README.md" \
  in_consumer fresh --check --source "$SRC"
check "--fix rewrites the drifted README" 0 "wrote .ceremony/README.md" \
  in_consumer fresh --fix --source "$SRC"

rm "$TMP/fresh/.ceremony/README.md"
check "missing README → check fails naming it" 1 \
  ".ceremony/README.md is missing" in_consumer fresh --check --source "$SRC"
in_consumer fresh --fix --source "$SRC" >/dev/null
check "README repaired → check green again" 0 "exact mirror" \
  in_consumer fresh --check --source "$SRC"

# --- the mirror is plain files: symlinks and friends refused ---------------------
# PR #43's review round (codex-bot + kimi-bot, independent repros): cp
# writes THROUGH a committed link, cmp reads through it, and a `find
# -type f` scan cannot even see it. Both modes refuse; every row with a
# victim asserts the victim untouched.

consumer sneaky 0.3.0
in_consumer sneaky --fix --source "$SRC" >/dev/null
printf 'victim v1\n' >"$TMP/sneaky/victim.md"

rm "$TMP/sneaky/.ceremony/RULES.md"
ln -s ../victim.md "$TMP/sneaky/.ceremony/RULES.md"
check "vendored path as symlink → check refuses naming it" 1 \
  ".ceremony/RULES.md" in_consumer sneaky --check --source "$SRC"
check "vendored path as symlink → fix refuses (never writes through)" 1 \
  "non-regular" in_consumer sneaky --fix --source "$SRC"
check "the link's target is untouched" 0 "victim v1" cat "$TMP/sneaky/victim.md"
rm "$TMP/sneaky/.ceremony/RULES.md"
in_consumer sneaky --fix --source "$SRC" >/dev/null

# A stray link is exactly what the -type f extra-file scan was blind to:
# unlisted doctrine, previously invisible.
ln -s ../victim.md "$TMP/sneaky/.ceremony/STRAYLINK.md"
check "stray symlink (invisible to -type f) → check refuses" 1 \
  "STRAYLINK.md" in_consumer sneaky --check --source "$SRC"
check "stray symlink → fix refuses too (no silent deletion of a link)" 1 \
  "STRAYLINK.md" in_consumer sneaky --fix --source "$SRC"
rm "$TMP/sneaky/.ceremony/STRAYLINK.md"

mkfifo "$TMP/sneaky/.ceremony/PIPE"
check "a fifo in the mirror → refused, not read" 1 "non-regular" \
  in_consumer sneaky --check --source "$SRC"
rm "$TMP/sneaky/.ceremony/PIPE"

rm -rf "$TMP/sneaky/.ceremony/guide"
mkdir -p "$TMP/sneaky/elsewhere"
ln -s ../elsewhere "$TMP/sneaky/.ceremony/guide"
check "vendored subdirectory as symlink → fix refuses" 1 \
  ".ceremony/guide" in_consumer sneaky --fix --source "$SRC"
check "nothing was written into the linked directory's target" 1 "" \
  test -e "$TMP/sneaky/elsewhere/DEEP.md"
rm "$TMP/sneaky/.ceremony/guide"
in_consumer sneaky --fix --source "$SRC" >/dev/null
check "sneaky consumer repaired → check green" 0 "exact mirror" \
  in_consumer sneaky --check --source "$SRC"

consumer linked-mirror 0.3.0
mkdir -p "$TMP/linked-mirror-target"
ln -s ../linked-mirror-target "$TMP/linked-mirror/.ceremony"
check ".ceremony/ itself a symlink → check refuses" 1 "symlink" \
  in_consumer linked-mirror --check --source "$SRC"
check ".ceremony/ itself a symlink → fix refuses" 1 "symlink" \
  in_consumer linked-mirror --fix --source "$SRC"
check "the link's target directory stayed empty" 0 "" \
  test -z "$(ls -A "$TMP/linked-mirror-target")"

consumer linked-stub 0.3.0
printf 'stub victim\n' >"$TMP/linked-stub/other.md"
ln -s other.md "$TMP/linked-stub/AGENTS.md"
check "root AGENTS.md as symlink → check refuses" 1 \
  "AGENTS.md is a symlink" in_consumer linked-stub --check --source "$SRC"
check "root AGENTS.md as symlink → fix refuses" 1 \
  "AGENTS.md is a symlink" in_consumer linked-stub --fix --source "$SRC"
check "the scaffold did not write through the link" 0 "stub victim" \
  cat "$TMP/linked-stub/other.md"

# Dangling is the sharpest case: -e is false through a dangling link, so a
# naive `[ ! -e ] && scaffold` writes the stub through it.
rm "$TMP/linked-stub/AGENTS.md"
ln -s does-not-exist.md "$TMP/linked-stub/AGENTS.md"
check "dangling AGENTS.md symlink → fix refuses (would write through)" 1 \
  "symlink" in_consumer linked-stub --fix --source "$SRC"
check "nothing appeared at the dangling target" 1 "" \
  test -e "$TMP/linked-stub/does-not-exist.md"

rm "$TMP/linked-stub/AGENTS.md"
mkdir "$TMP/linked-stub/AGENTS.md"
check "root AGENTS.md as a directory → refused, named" 1 \
  "not a regular file" in_consumer linked-stub --fix --source "$SRC"

# --- the action's wiring: inputs arrive as env vars -----------------------------

consumer env-wired 0.3.0
env_sync() {
  (cd "$TMP/env-wired" && MODE=fix SOURCE="$SRC" bash "$SCRIPT")
}
check "env vars drive the script the way action.yml does" 0 \
  "added .ceremony/RULES.md" env_sync

env_bad_mode() {
  (cd "$TMP/env-wired" && MODE=frobnicate SOURCE="$SRC" bash "$SCRIPT")
}
check "unknown MODE env refused" 1 "unknown mode" env_bad_mode
check "unknown flag refused" 1 "unknown argument" \
  in_consumer env-wired --check --source "$SRC" --frobnicate
check "--source without a directory refused" 1 "no such directory" \
  in_consumer env-wired --check --source "$TMP/does-not-exist"

# --- the fetch path: driven offline by the stub ---------------------------------
# Two pr-checks failures on heavy-duty/incubator#147 at the same head, 38
# minutes apart, both an upstream 503 from codeload, both reported as "does
# the pinned ref exist?" — sending a reader to audit a tag that was healthy
# throughout. The fetch had never had a test (#393).

# The refusing default is only a proof if the stub is genuinely the curl
# every row above would have reached; assert that rather than assume it.
check "the stub is the curl on PATH (else every row above proves nothing)" 0 \
  "$TMP/stub/curl" command -v curl
# Read before the deliberate refusal below trips it: every --source row in
# this file has now run, and none of them reached curl. The exit status
# alone would not prove that — a caller could swallow it — so the stub
# leaves a mark that no `|| true` can erase.
check "no --source row ever reached curl" 1 "" test -e "$CURL_STUB_TRIPWIRE"
check "the stub's default mode refuses to be called" 97 \
  "curl must not be called" curl -fsSL https://example.invalid
check "the refusal leaves its mark, not just an exit status" 0 "" \
  test -s "$CURL_STUB_TRIPWIRE"

consumer fetch-ok 0.3.0
check "fetch --fix (no --source) materializes the mirror" 0 \
  "added .ceremony/RULES.md" fetched ok fetch-ok --fix
# Byte-identity with the --source mirror is what forces the two-step fetch:
# the stub writes the archive to -o and prints 200 on stdout, so a
# `curl | tar` implementation feeds tar the four bytes `200` and dies here.
# It also forces --strip-components=1, the fixture carrying a leading
# component.
check "the fetched mirror is byte-identical to the --source one" 0 "" \
  diff -r "$TMP/fresh/.ceremony" "$TMP/fetch-ok/.ceremony"
check "fetch --check on the fetched mirror → exact mirror, named by pin" 0 \
  "exact mirror of heavy-duty/ceremony@0.3.0" fetched ok fetch-ok --check

# --- one diagnostic per fault class ---------------------------------------------
# Each text is proven present in its own branch AND absent from a sibling:
# an implementation that prints all four on every fault would satisfy a
# positive-only suite, which is exactly the escape hatch today's single
# message left open.

consumer fetch-503 0.3.0
check "a 5xx says the pin is fine" 1 "The pin is fine" \
  fetched 503 fetch-503 --check
check "a 5xx says the fault is transient and names the cure" 1 \
  "This is transient: re-run the job." fetched 503 fetch-503 --check
check_absent "a 5xx never says the ref does not exist" 1 "does not exist" \
  fetched 503 fetch-503 --check
check_absent "a 5xx never asks the reader to audit the pin" 1 \
  "Check the tag, or bump the pin" fetched 503 fetch-503 --check

consumer fetch-404 0.3.0
check "a 404 names the ref and says it does not exist" 1 \
  "heavy-duty/ceremony@0.3.0 does not exist" fetched 404 fetch-404 --check
check "a 404 sends the reader to the pin" 1 "Check the tag, or bump the pin" \
  fetched 404 fetch-404 --check
check_absent "a 404 never calls the fault transient" 1 "transient" \
  fetched 404 fetch-404 --check

consumer fetch-netfail 0.3.0
check "a connection failure reports curl's exit and the missing status" 1 \
  "curl exit 7, HTTP status 000" fetched netfail fetch-netfail --check
check_absent "a connection failure claims nothing about the ref" 1 \
  "does not exist" fetched netfail fetch-netfail --check
check_absent "a connection failure claims nothing about transience either" 1 \
  "transient" fetched netfail fetch-netfail --check

consumer fetch-corrupt 0.3.0
check "a body that will not unpack is its own fault class" 1 \
  "downloaded but did not extract" fetched corrupt fetch-corrupt --check
check_absent "an unpack failure is not reported as a fetch failure" 1 \
  "could not fetch" fetched corrupt fetch-corrupt --check

# --- the flags, where they are the deliverable ----------------------------------
# D1–D3 of #393 are partly structural: the archive and the extraction root
# cannot be told apart from outside, since the mirror walk only ever reads
# manifest paths. So they are asserted where they are visible — in the
# script's own text, alongside the behavioral rows above.

check "the fetch carries the retry flags" 0 \
  "--retry 3 --retry-delay 5 --retry-connrefused" cat "$SCRIPT"
check "the fetch captures the status rather than inferring it" 0 \
  "-w '%{http_code}'" cat "$SCRIPT"
check_absent "the all-errors retry flag is passed nowhere" 0 \
  "--retry-all-errors" cat "$SCRIPT"
check "the file records the version floor that rejected it" 0 "7.71.0" \
  cat "$SCRIPT"
# Anchored before any '#': the war story above the fetch quotes the hazard
# it forbids, and an unanchored pattern would red on the comment that
# explains the rule.
check "no curl-into-tar pipe survives outside the comments" 1 "" \
  grep -qE '^[^#]*curl[^|]*\|[^|]*tar' "$SCRIPT"
# shellcheck disable=SC2016 # the '$' is part of the literal being asserted
check "the archive lands beside the extraction root, not in it" 0 \
  'archive="$fetch_tmp/src.tar.gz"' cat "$SCRIPT"
# shellcheck disable=SC2016 # the '$' is part of the literal being asserted
check "the extraction root is its own directory" 0 'src="$fetch_tmp/src"' \
  cat "$SCRIPT"

# --- the guarded scaffold (#559) ------------------------------------------------
# The third file class: ceremony owns a delimited region of a file that
# otherwise belongs to the consumer. Its source tree is SEPARATE from $SRC on
# purpose. $SRC carries no docs/SCAFFOLDED.txt, so every row above is
# simultaneously the proof that a ref predating this feature still syncs — a
# missing scaffold manifest is "no scaffolds", not a refusal, and making it
# fatal would be a flag day for every consumer pinned behind this release.

MARK_START='<!-- ceremony:pr-template:start -->'
MARK_END='<!-- ceremony:pr-template:end -->'
TEMPLATE='.github/pull_request_template.md'

# Deliberately not the real template, for the reason the fake doc set is not
# the real five: a script that hardcodes ceremony's own bytes passes a suite
# built from them and fails a consumer.
SRC_SCAF="$TMP/src-scaffold"
mkdir -p "$SRC_SCAF/docs" "$SRC_SCAF/.github"
printf 'AGENTS.md\n' >"$SRC_SCAF/docs/VENDORED.txt"
printf '# router v1\n' >"$SRC_SCAF/AGENTS.md"
printf '%s\n' "$TEMPLATE" >"$SRC_SCAF/docs/SCAFFOLDED.txt"
printf 'Closes #\n\n## Acceptance criteria\n' >"$SRC_SCAF/$TEMPLATE"

# The same source one character later — the drift a --check must catch.
SRC_SCAF2="$TMP/src-scaffold-v2"
cp -r "$SRC_SCAF" "$SRC_SCAF2"
printf 'Closes #\n\n## Acceptance criteriaX\n' >"$SRC_SCAF2/$TEMPLATE"

# scaf <name> — a consumer pinned at 0.3.0 whose doctrine mirror is already
# current and whose guarded scaffold is ABSENT, so every row below fails on
# the scaffold state it authors itself and never on the mirror. The template
# is removed after the sync rather than never written: that way the helper
# also proves --fix wrote one, and a regression that stops writing it turns
# the rm into a visible error instead of a silently identical fixture.
scaf() {
  consumer "$1" 0.3.0
  in_consumer "$1" --fix --source "$SRC_SCAF" >/dev/null 2>&1
  rm "$TMP/$1/$TEMPLATE"
}

# The two halves of the file that are the CONSUMER's, extracted by the same
# whole-line rule the tool uses. These are what the byte comparisons below
# compare — the criterion asks for a byte comparison of the outside regions,
# not a look at the diff.
above_block() {
  local f="$1" s
  s="$(grep -n -x -F -e "$MARK_START" "$f" | cut -d: -f1)"
  head -n "$((s - 1))" "$f"
}
below_block() {
  local f="$1" e
  e="$(grep -n -x -F -e "$MARK_END" "$f" | cut -d: -f1)"
  tail -n +"$((e + 1))" "$f"
}
# The block's own bytes, marker lines excluded.
inner_block() {
  local f="$1" s e
  s="$(grep -n -x -F -e "$MARK_START" "$f" | cut -d: -f1)"
  e="$(grep -n -x -F -e "$MARK_END" "$f" | cut -d: -f1)"
  head -n "$((e - 1))" "$f" | tail -n +"$((s + 1))"
}
extract() { "$1" "$2" >"$3"; }

# --- E3: the set comes from the SOURCE tree ------------------------------------

scaf manifest-source
# A consumer-side manifest naming a different file: read from the consumer,
# the tool would guard OTHER.md and never the template.
printf 'OTHER.md\n' >"$TMP/manifest-source/docs/SCAFFOLDED.txt"
check "the scaffold set is read from the source, not the consumer" 1 \
  "$TEMPLATE is missing" in_consumer manifest-source --check --source "$SRC_SCAF"
check_absent "a consumer-side scaffold manifest names nothing the tool obeys" 1 \
  "OTHER.md" in_consumer manifest-source --check --source "$SRC_SCAF"

consumer no-scaffold-manifest 0.3.0
in_consumer no-scaffold-manifest --fix --source "$SRC" >/dev/null 2>&1
check "a source with no scaffold manifest syncs clean (every ref before #559)" 0 \
  "exact mirror" in_consumer no-scaffold-manifest --check --source "$SRC"
check_absent "and says nothing about guarded scaffolds at all" 0 \
  "guarded scaffold" in_consumer no-scaffold-manifest --check --source "$SRC"

# --- E4: absent file ------------------------------------------------------------

scaf absent
check "--check fails when the guarded scaffold is absent" 1 \
  "$TEMPLATE is missing" in_consumer absent --check --source "$SRC_SCAF"
check "the absent diagnostic names the pin" 1 \
  "pin is heavy-duty/ceremony@0.3.0" in_consumer absent --check --source "$SRC_SCAF"
check "the absent diagnostic names --fix as the repair" 1 \
  "run docs-sync --fix" in_consumer absent --check --source "$SRC_SCAF"

check "--fix creates the file carrying the block" 0 \
  "created $TEMPLATE" in_consumer absent --fix --source "$SRC_SCAF"
extract inner_block "$TMP/absent/$TEMPLATE" "$TMP/absent-inner"
check "the created block is byte-identical to the source file" 0 "" \
  cmp "$TMP/absent-inner" "$SRC_SCAF/$TEMPLATE"
check "a second --check on the created file exits 0" 0 \
  "1 guarded scaffold(s) carry a current ceremony-owned block" \
  in_consumer absent --check --source "$SRC_SCAF"

# --- E5: repo-specific text above AND below a drifted block ---------------------

printf '# Our template\n\nRead CONTRIBUTING first.\n' >"$TMP/above.txt"
printf '\n## Deployment notes\n\nStaging first, always.\n' >"$TMP/below.txt"

scaf surround
{
  cat "$TMP/above.txt"
  printf '%s\n' "$MARK_START"
  printf 'an old block from 0.4.0\n'
  printf '%s\n' "$MARK_END"
  cat "$TMP/below.txt"
} >"$TMP/surround/$TEMPLATE"

check "--check fails on a drifted block" 1 \
  "has drifted" in_consumer surround --check --source "$SRC_SCAF"
check "--fix updates the drifted block" 0 \
  "updated the ceremony-owned block" in_consumer surround --fix --source "$SRC_SCAF"

extract above_block "$TMP/surround/$TEMPLATE" "$TMP/surround-above"
extract below_block "$TMP/surround/$TEMPLATE" "$TMP/surround-below"
extract inner_block "$TMP/surround/$TEMPLATE" "$TMP/surround-inner"
check "every byte ABOVE the markers survives --fix" 0 "" \
  cmp "$TMP/surround-above" "$TMP/above.txt"
check "every byte BELOW the markers survives --fix" 0 "" \
  cmp "$TMP/surround-below" "$TMP/below.txt"
check "and the block itself is now the source's bytes" 0 "" \
  cmp "$TMP/surround-inner" "$SRC_SCAF/$TEMPLATE"
check "--check passes after the repair" 0 "guarded scaffold(s)" \
  in_consumer surround --check --source "$SRC_SCAF"

# --- E5: an existing hand-maintained template with no block ---------------------

scaf noblock
cat "$TMP/above.txt" >"$TMP/noblock/$TEMPLATE"
check "--check fails when the file carries no ceremony block" 1 \
  "carries no ceremony-owned block" in_consumer noblock --check --source "$SRC_SCAF"
check "--fix APPENDS rather than overwriting" 0 \
  "appended the ceremony-owned block" in_consumer noblock --fix --source "$SRC_SCAF"
extract above_block "$TMP/noblock/$TEMPLATE" "$TMP/noblock-above"
check "the pre-existing content survives byte-for-byte" 0 "" \
  cmp "$TMP/noblock-above" "$TMP/above.txt"
extract inner_block "$TMP/noblock/$TEMPLATE" "$TMP/noblock-inner"
check "the appended block is the source's bytes" 0 "" \
  cmp "$TMP/noblock-inner" "$SRC_SCAF/$TEMPLATE"

# A file with no final newline is the case that splices the start marker onto
# the consumer's last line, losing that line's content to a comment.
scaf noblock-nonl
printf 'no trailing newline here' >"$TMP/noblock-nonl/$TEMPLATE"
check "--fix appends to a file with no final newline" 0 \
  "appended the ceremony-owned block" in_consumer noblock-nonl --fix --source "$SRC_SCAF"
check "and that last line is still its own line" 0 "" \
  grep -qxF 'no trailing newline here' "$TMP/noblock-nonl/$TEMPLATE"
check "--check passes on the appended result" 0 "guarded scaffold(s)" \
  in_consumer noblock-nonl --check --source "$SRC_SCAF"

# --- E4: three broken shapes, three non-zero exits ------------------------------

# 1. unbalanced — a start with no end. The build this rejects is a sed range,
#    which matches to end-of-file and lets --fix delete everything below.
scaf unbalanced
{
  cat "$TMP/above.txt"
  printf '%s\n' "$MARK_START"
  printf 'a block that never closes\n'
  cat "$TMP/below.txt"
} >"$TMP/unbalanced/$TEMPLATE"
check "--check fails on unbalanced markers" 1 \
  "unbalanced ceremony markers" in_consumer unbalanced --check --source "$SRC_SCAF"
check "--fix REFUSES unbalanced markers rather than guessing" 1 \
  "its ceremony markers are unbalanced" in_consumer unbalanced --fix --source "$SRC_SCAF"
check "and says why it refuses instead of repairing" 1 \
  "guess at which of your bytes are ours" in_consumer unbalanced --fix --source "$SRC_SCAF"
check "and the refusal left the consumer's content below the marker intact" 0 "" \
  grep -qxF 'Staging first, always.' "$TMP/unbalanced/$TEMPLATE"

# 2. duplicated — a second start marker.
scaf duplicated
{
  printf '%s\n' "$MARK_START"
  printf 'first\n'
  printf '%s\n' "$MARK_START"
  printf 'second\n'
  printf '%s\n' "$MARK_END"
} >"$TMP/duplicated/$TEMPLATE"
check "--check fails on a second start marker" 1 \
  "more than one ceremony marker line" in_consumer duplicated --check --source "$SRC_SCAF"
check "--fix refuses a duplicated marker too" 1 \
  "its ceremony markers are duplicated" in_consumer duplicated --fix --source "$SRC_SCAF"

# 3. drift by exactly one character — the stub build's failure mode, which is
#    what a scaffold-once-never-again implementation looks like after a bump.
scaf onechar
in_consumer onechar --fix --source "$SRC_SCAF" >/dev/null 2>&1
check "--check fails on a block one character behind the source" 1 \
  "has drifted" in_consumer onechar --check --source "$SRC_SCAF2"
check "--fix brings it forward" 0 "updated the ceremony-owned block" \
  in_consumer onechar --fix --source "$SRC_SCAF2"
extract inner_block "$TMP/onechar/$TEMPLATE" "$TMP/onechar-inner"
check "and the block is now the newer source's bytes" 0 "" \
  cmp "$TMP/onechar-inner" "$SRC_SCAF2/$TEMPLATE"

# --- E5: idempotence ------------------------------------------------------------

scaf idem
cat "$TMP/above.txt" >"$TMP/idem/$TEMPLATE"
in_consumer idem --fix --source "$SRC_SCAF" >/dev/null 2>&1
cp -r "$TMP/idem" "$TMP/idem-first"
check "a second --fix reports nothing to do" 0 "nothing to do" \
  in_consumer idem --fix --source "$SRC_SCAF"
check "and leaves the tree byte-identical to the first run's" 0 "" \
  diff -r "$TMP/idem-first" "$TMP/idem"

# --- the plain-file refusal reaches the scaffold too -----------------------------

scaf link
rm -f "$TMP/link/$TEMPLATE"
ln -s /tmp/somewhere-else "$TMP/link/$TEMPLATE"
check "a symlinked scaffold is refused, not written through" 1 \
  "is a symlink" in_consumer link --check --source "$SRC_SCAF"
check "and --fix refuses it as well" 1 "is a symlink" \
  in_consumer link --fix --source "$SRC_SCAF"

# --- structural: the boundary is never a sed pattern range ----------------------
# The unterminated-marker build is the one the criteria reject behaviorally
# above; this row is what stops it being reintroduced as an "equivalent"
# refactor. Anchored before any '#' so the header essay naming the hazard
# does not red its own rule.

check "no sed pattern range walks the markers" 1 "" \
  grep -qE "^[^#]*sed .*/$MARK_START" "$SCRIPT"
check "the marker literals are #559's, byte for byte" 0 \
  "SCAFFOLD_START=\"$MARK_START\"" cat "$SCRIPT"
check "the end marker literal too" 0 "SCAFFOLD_END=\"$MARK_END\"" cat "$SCRIPT"
# E2: the markers are written at install time and the source never carries
# them, so the block's bytes and the source's bytes stay one thing to compare.
check "ceremony's own template carries no marker" 1 "" \
  grep -qF "$MARK_START" "$ROOT/$TEMPLATE"
check "the real manifest names the template" 0 "" \
  grep -qxF "$TEMPLATE" "$ROOT/docs/SCAFFOLDED.txt"
check "and the mirror manifest still does not" 1 "" \
  grep -qF "pull_request_template" "$ROOT/docs/VENDORED.txt"

summary
