#!/usr/bin/env bash
# Contract tests for actions/docs-sync (issue #19). Constructed SOURCE trees
# (a fake ceremony: manifest + docs) and CONSUMER trees (a release.yml
# caller with the pin line), driven offline via --source — the fetch path
# needs the network and is exercised by consumers, not here. The fake
# source's doc set is deliberately NOT the real five: a script that
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

# RELEASES.md's consumer-availability promise is true only when the real
# manifest carries it (#248's review round). The fixture cases below prove
# manifest-driven behavior; this row binds that behavior to the promised file.
check "real manifest includes the release doctrine" 0 "RELEASES.md" \
  grep -Fx RELEASES.md "$ROOT/docs/VENDORED.txt"

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

summary
