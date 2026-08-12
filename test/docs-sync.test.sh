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
case "${CURL_STUB:-none}" in
  ok)
    cp "$CURL_STUB_TARBALL" "$out"
    printf '200'
    ;;
  corrupt)
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
check "the stub's default mode refuses to be called" 97 \
  "curl must not be called" curl -fsSL https://example.invalid

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
check "the archive lands beside the extraction root, not in it" 0 \
  'archive="$fetch_tmp/src.tar.gz"' cat "$SCRIPT"
check "the extraction root is its own directory" 0 'src="$fetch_tmp/src"' \
  cat "$SCRIPT"

summary
