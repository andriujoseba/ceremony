#!/usr/bin/env bash
# Contract tests for .github/scripts/vendored-check.sh (issue #251) — the
# self-guard that makes docs/VENDORED.txt authoritative over ceremony's OWN
# tree. Driven against constructed fixture trees plus the real one; the CI
# step runs the same script against the real tree.
#
# The fixture doc set is deliberately NOT ceremony's real six: a guard that
# hardcodes the vendored list instead of reading the manifest fails these
# rows, which is the failure the whole issue is about.
#
# set -u, not -e: failing commands are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

CHECK="$ROOT/.github/scripts/vendored-check.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixture builders --------------------------------------------------------

# tree <name> <manifest-entry...> — a fixture tree carrying only the manifest.
tree() {
  local dir="$TMP/$1"
  shift
  rm -rf "$dir"
  mkdir -p "$dir/docs"
  printf '%s\n' "$@" >"$dir/docs/VENDORED.txt"
}

# doc <tree> <path> [content] — a regular file in a fixture tree.
doc() {
  local path="$TMP/$1/$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "${3:-# a doc}" >"$path"
}

# real_copy <name> — the real tree reduced to what the guard reads: the
# manifest, every path the manifest names, and every root *.md. Cases mutate
# the copy, so the guard's verdict on ceremony's actual doc set is proven
# without touching the working tree.
real_copy() {
  local dir="$TMP/$1" entry
  rm -rf "$dir"
  mkdir -p "$dir/docs"
  cp "$ROOT/docs/VENDORED.txt" "$dir/docs/VENDORED.txt"
  cp "$ROOT"/*.md "$dir/"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    mkdir -p "$dir/$(dirname "$entry")"
    cp "$ROOT/$entry" "$dir/$entry"
  done <"$ROOT/docs/VENDORED.txt"
}

run_check() {
  bash "$CHECK" "$TMP/$1"
}

# --- the happy tree ----------------------------------------------------------

# One manifest entry lives in a subdirectory: the manifest is PATHS, not
# filenames (docs-sync's fixtures prove the same), and the closed-world rule
# over the root must not regress that to root-only.
tree ok AGENTS.md RULES.md guide/DEEP.md
doc ok AGENTS.md
doc ok RULES.md
doc ok guide/DEEP.md
check "a tree whose root docs are all declared passes" 0 "3 manifest entries resolve" \
  run_check ok

tree blanks AGENTS.md '' RULES.md
doc blanks AGENTS.md
doc blanks RULES.md
check "blank manifest lines are skipped, as docs-sync skips them" 0 "2 manifest entries" \
  run_check blanks

# --- the closed world: a root doc in neither list ----------------------------

# The #248 near-miss, replayed as a test: a new doctrine file lands at the
# root and nobody adds it to the manifest.
tree newdoc AGENTS.md
doc newdoc AGENTS.md
doc newdoc NEWDOC.md
check "a root doc in neither list reds" 1 "'NEWDOC.md' is a root doc in NEITHER list" \
  run_check newdoc
check "...and the refusal names the manifest fix" 1 "add 'NEWDOC.md' to docs/VENDORED.txt" \
  run_check newdoc
check "...and the refusal names the exemption fix" 1 "add 'NEWDOC.md' to the exemption list" \
  run_check newdoc

# The decision the guard forces, taken each way: vendor it…
tree newdoc-vendored AGENTS.md NEWDOC.md
doc newdoc-vendored AGENTS.md
doc newdoc-vendored NEWDOC.md
check "a root doc added to the manifest passes" 0 "2 manifest entries" \
  run_check newdoc-vendored

# …or exempt it. The exemption list is in the script and carries a reason;
# README.md is one of the four ceremony-only root docs it names.
tree exempted AGENTS.md
doc exempted AGENTS.md
doc exempted README.md
check "a root doc on the exemption list passes, with its reason" 0 "exempt:   README.md" \
  run_check exempted

# The exemption list is NEVER read from prose. CONTRIBUTING.md's vendored-set
# sentence is documentation; two declarations of the same set is the drift
# the manifest exists to prevent (#251 D2's second must-fail).
tree prose AGENTS.md
doc prose AGENTS.md
doc prose EXTRA.md
doc prose CONTRIBUTING.md "The vendored set is AGENTS.md and EXTRA.md."
check "a doc declared only in prose still reds" 1 "'EXTRA.md' is a root doc in NEITHER list" \
  run_check prose

# --- the rule is ROOT-level only ---------------------------------------------

# A guard that walked the tree would need an exemption list long enough that
# nobody reads it — the exact failure the root-only rule is shaped against.
# So an undeclared *.md under docs/, actions/ or drills/ must stay GREEN.
tree subdirs AGENTS.md
doc subdirs AGENTS.md
doc subdirs docs/CONSUMERS.md
doc subdirs actions/thing/README.md
doc subdirs drills/2026-07-01.md
check "undeclared *.md below the root stays green (no recursion)" 0 "1 manifest entries" \
  run_check subdirs

# --- manifest → tree: the scan -----------------------------------------------

tree missing AGENTS.md GONE.md
doc missing AGENTS.md
check "a manifest entry with no file reds, naming it" 1 "names 'GONE.md' but the tree has no such file" \
  run_check missing

tree symlinked AGENTS.md LINK.md
doc symlinked AGENTS.md
ln -s AGENTS.md "$TMP/symlinked/LINK.md"
check "a manifest entry pointing at a symlink reds" 1 "names 'LINK.md', which is a SYMLINK" \
  run_check symlinked

tree dir-entry AGENTS.md guide
doc dir-entry AGENTS.md
mkdir -p "$TMP/dir-entry/guide"
check "a manifest entry pointing at a directory reds" 1 "names 'guide', which is a DIRECTORY" \
  run_check dir-entry

tree empty-entry AGENTS.md HOLLOW.md
doc empty-entry AGENTS.md
: >"$TMP/empty-entry/HOLLOW.md"
check "a manifest entry pointing at an empty file reds" 1 "names 'HOLLOW.md', which is EMPTY" \
  run_check empty-entry

# The escape case exists as a docs-sync fixture; ceremony's own manifest must
# not be the one place it goes unchecked.
tree escape AGENTS.md ../outside.md
doc escape AGENTS.md
check "a manifest entry escaping with ../ reds" 1 "names '../outside.md'" \
  run_check escape

tree absolute AGENTS.md /etc/hosts
doc absolute AGENTS.md
check "an absolute manifest entry reds" 1 "names '/etc/hosts'" \
  run_check absolute

# --- the manifest itself -----------------------------------------------------

rm -rf "$TMP/no-manifest"
mkdir -p "$TMP/no-manifest"
check "a tree with no manifest reds" 1 "no docs/VENDORED.txt under" \
  run_check no-manifest

rm -rf "$TMP/empty-manifest"
mkdir -p "$TMP/empty-manifest/docs"
: >"$TMP/empty-manifest/docs/VENDORED.txt"
check "an empty manifest reds" 1 "is empty" run_check empty-manifest

# --- tracked-ness ------------------------------------------------------------

# A file present on this machine but absent from the tag's tree cannot be
# fetched by a consumer syncing at that tag. The assertion binds only where
# it can: when the tree IS a git work tree root.
tree tracked AGENTS.md RULES.md
doc tracked AGENTS.md
doc tracked RULES.md
git init -q "$TMP/tracked"
git -C "$TMP/tracked" add docs/VENDORED.txt AGENTS.md RULES.md
check "a git tree whose manifest entries are all tracked passes" 0 "2 manifest entries" \
  run_check tracked

tree untracked AGENTS.md RULES.md
doc untracked AGENTS.md
doc untracked RULES.md
git init -q "$TMP/untracked"
git -C "$TMP/untracked" add docs/VENDORED.txt AGENTS.md
check "a git tree with an untracked manifest entry reds" 1 "names 'RULES.md', which is not TRACKED" \
  run_check untracked

# ...and where it cannot bind, the skip ANNOUNCES ITSELF rather than being
# inferred from the absence of a refusal (#251 round 1). A guard that quietly
# stops asserting one of its four properties is the silent miss this whole
# script argues against, so the degradation is visible on both output paths.
check "a non-git tree says tracked-ness was not asserted" 0 "tracked-ness NOT asserted" \
  run_check ok
check "...and says it on the red path too, beside the refusals" 1 "tracked-ness NOT asserted" \
  run_check newdoc

# The converse, so the note is not simply always printed: where the tree IS a
# git work tree root the assertion bound, and nothing is announced.
no_skip_note() { ! run_check tracked 2>&1 | grep -qF "tracked-ness NOT asserted"; }
check "a git work tree root announces no skip — the assertion bound" 0 "" \
  no_skip_note

# --- the real tree -----------------------------------------------------------

check "this tree, unmodified, is green" 0 "manifest entries resolve" bash "$CHECK" "$ROOT"

# The #248 near-miss on the REAL doc set: a scratch root doc nobody declared.
real_copy scratch
doc scratch SCRATCHDOC.md
check "a scratch root doc on the real tree reds, naming it" 1 "'SCRATCHDOC.md' is a root doc in NEITHER list" \
  run_check scratch

# RELEASES.md stays listed — the regression criterion #248's review round
# bought, now asserted BY THE GUARD rather than by a hardcoded `grep -Fx` row
# in test/docs-sync.test.sh (#251 D1, D4). The closed world holds in both
# directions: dropping it from the manifest alone reds…
real_copy releases-dropped
grep -v '^RELEASES\.md$' "$ROOT/docs/VENDORED.txt" >"$TMP/releases-dropped/docs/VENDORED.txt"
check "dropping RELEASES.md from the manifest alone reds" 1 "'RELEASES.md' is a root doc in NEITHER list" \
  run_check releases-dropped

# …and it is green only when the file leaves the root in the same breath.
real_copy releases-gone
grep -v '^RELEASES\.md$' "$ROOT/docs/VENDORED.txt" >"$TMP/releases-gone/docs/VENDORED.txt"
rm -f "$TMP/releases-gone/RELEASES.md"
check "dropping RELEASES.md from the manifest AND the root is green" 0 "manifest entries resolve" \
  run_check releases-gone

summary
