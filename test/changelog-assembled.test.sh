#!/usr/bin/env bash
# Contract tests for actions/changelog-assembled (issue #116). Like the
# monotonic guard's suite, every applicable case is a constructed git repo —
# "the section matches the fragments it consumed" is a property of a DIFF:
# the fragments are gone from HEAD's tree by construction, so the fixture is
# a history: a base commit holding the fragments and a -dev version, a HEAD
# commit holding the ceremony's edit, and a 'base' branch standing in for
# origin/main. set -u, not -e: failing commands are behavior for the
# harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/actions/changelog-assembled/changelog-assembled.sh"
ARMED="$ROOT/actions/changelog-armed/changelog-armed.sh"
MONOTONIC="$ROOT/actions/changelog-monotonic/changelog-monotonic.sh"
ASSEMBLE="$ROOT/bin/changelog-assemble"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

init_repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email ci@example.invalid
  git -C "$dir" config user.name ci
}

# commit_base <name> — commit the tree as the merge base and pin 'base' there.
commit_base() {
  git -C "$TMP/$1" add -A
  git -C "$TMP/$1" commit -qm base
  git -C "$TMP/$1" branch base
}

commit_head() {
  git -C "$TMP/$1" add -A
  git -C "$TMP/$1" commit -qm head
}

# seed_flat <name> — the shared pre-ceremony tree: an armed changelog, two
# flat fragments (numeric order will put 12 before 9), a -dev version.
seed_flat() {
  local name="$1" dir="$TMP/$1"
  init_repo "$name"
  mkdir -p "$dir/changelog.d"
  printf 'Machine-assembled; see heavy-duty/ceremony#112.\n' >"$dir/changelog.d/README.md"
  cat >"$dir/CHANGELOG.md" <<'EOF'
# Changelog

Preamble prose belongs to no section.

## 0.1.0 — 2026-07-01

- The shipped entry.
EOF
  printf '0.1.1-dev\n' >"$dir/VERSION"
  printf -- '- Twelve landed (#12).\n' >"$dir/changelog.d/12.md"
  printf -- '- Nine landed, and its prose wraps onto a\n  continuation line (#9).\n' >"$dir/changelog.d/9.md"
  commit_base "$name"
}

# ceremony <name> <ver> <date> — the faithful release edit on the working
# tree, exactly as a human runs it: the real assembler in write mode, then
# the bare version stamp. Deliberately does NOT commit, so a case can break
# the tree before committing HEAD.
ceremony() {
  local name="$1" ver="$2" stamp="$3"
  (cd "$TMP/$name" && "$ASSEMBLE" "$ver" "$stamp" >/dev/null 2>&1) || return 1
  printf '%s\n' "$ver" >"$TMP/$name/VERSION"
}

run() { local name="$1"; shift; (cd "$TMP/$name" && bash "$SCRIPT" "$@"); }
run_strict() { local name="$1"; shift; (cd "$TMP/$name" && CHANGELOG_ASSEMBLED_STRICT=1 bash "$SCRIPT" "$@"); }

# --- the documented flow passes ----------------------------------------------

seed_flat faithful-flat
ceremony faithful-flat 0.2.0 2026-07-24
commit_head faithful-flat
check "faithful flat ceremony: the section is byte-for-byte the assembly" 0 \
  "byte-for-byte" run faithful-flat base

seed_flat faithful-grouped
sed -i '/^- The shipped entry/i ### Fixed\\\n' "$TMP/faithful-grouped/CHANGELOG.md"
printf -- '### Fixed\n\n- Fixed twenty-one (#21).\n' >"$TMP/faithful-grouped/changelog.d/21.md"
printf -- '### Added\n\n- Added twenty (#20).\n\n### Docs\n\n- Docs twenty (#20).\n' >"$TMP/faithful-grouped/changelog.d/20.md"
rm "$TMP/faithful-grouped/changelog.d/12.md" "$TMP/faithful-grouped/changelog.d/9.md"
git -C "$TMP/faithful-grouped" add -A
git -C "$TMP/faithful-grouped" commit -qm regroup
git -C "$TMP/faithful-grouped" branch -f base
ceremony faithful-grouped 0.2.0 2026-07-24
commit_head faithful-grouped
check "faithful grouped ceremony passes" 0 "byte-for-byte" run faithful-grouped base

# The date is HEAD's to choose: a stamp nowhere near today must not read as
# a prose difference — the comparison is body against body, headings (and
# so dates) never enter it.
seed_flat old-date
ceremony old-date 0.2.0 2020-01-01
commit_head old-date
check "the stamp's date never enters the comparison" 0 "byte-for-byte" \
  run old-date base

# --- inapplicable trees: green NOTICE, never a silent skip -------------------

seed_flat ordinary-add
printf -- '- Thirteen incoming (#13).\n' >"$TMP/ordinary-add/changelog.d/13.md"
commit_head ordinary-add
check "-dev PR adding a fragment: green NOTICE" 0 "NOTICE" run ordinary-add base

seed_flat ordinary-none
printf 'code\n' >"$TMP/ordinary-none/code.txt"
commit_head ordinary-none
check "-dev PR touching no fragment: green NOTICE" 0 "NOTICE" run ordinary-none base

seed_flat ordinary-del
rm "$TMP/ordinary-del/changelog.d/12.md"
commit_head ordinary-del
check "-dev PR even deleting a fragment: green NOTICE" 0 "NOTICE" run ordinary-del base

# Legacy mode: no changelog.d/ at the merge base — always a NOTICE, even on
# a release tree, because the mid-adoption ceremony edits the changelog by
# hand and there is no fragment set for its section to answer to.
init_repo legacy
printf '# Changelog\n\n## Unreleased\n\n- An entry.\n' >"$TMP/legacy/CHANGELOG.md"
printf '0.1.1-dev\n' >"$TMP/legacy/VERSION"
commit_base legacy
printf '# Changelog\n\n## 0.2.0 — 2026-07-24\n\n- An entry.\n' >"$TMP/legacy/CHANGELOG.md"
printf '0.2.0\n' >"$TMP/legacy/VERSION"
commit_head legacy
check "legacy repo (no changelog.d at base): green NOTICE, even on a release tree" 0 \
  "NOTICE" run legacy base

# The un-rearmed window: a PR branched right after a release merges sits on
# a bare version whose section was stamped at its MERGE BASE — it is not
# the ceremony and must not be asked to answer for one.
seed_flat post-release
ceremony post-release 0.2.0 2026-07-24
git -C "$TMP/post-release" add -A
git -C "$TMP/post-release" commit -qm release
git -C "$TMP/post-release" branch -f base
printf 'code\n' >"$TMP/post-release/code.txt"
commit_head post-release
check "a PR atop the un-rearmed release: green NOTICE (this branch did not stamp)" 0 \
  "NOTICE" run post-release base

# --- the refusals ------------------------------------------------------------

# The issue's headline failure: one fragment kept out of the ceremony — it
# survives at HEAD and its entry is absent from the section. Both refusals
# fire: the diff names the missing entry, the survivor list names the file.
seed_flat dropped
mv "$TMP/dropped/changelog.d/9.md" "$TMP/dropped/9.md.hold"
ceremony dropped 0.2.0 2026-07-24
mv "$TMP/dropped/9.md.hold" "$TMP/dropped/changelog.d/9.md"
commit_head dropped
check "a fragment kept out of the ceremony fails" 1 "" run dropped base
check "the dropped-entry diff names the missing entry" 1 "Nine landed" \
  run dropped base
check "the surviving fragment is listed by path" 1 "changelog.d/9.md" \
  run dropped base

# The same drop, but the fragment was deleted anyway: its prose vanished
# without ever being published. Only the diff can say so.
seed_flat vanished
mv "$TMP/vanished/changelog.d/9.md" "$TMP/vanished/9.md.hold"
ceremony vanished 0.2.0 2026-07-24
rm "$TMP/vanished/9.md.hold"
commit_head vanished
check "a deleted fragment whose entry never landed fails" 1 "Nine landed" \
  run vanished base

seed_flat edited
ceremony edited 0.2.0 2026-07-24
sed -i 's/Twelve landed/Twelve allegedly landed/' "$TMP/edited/CHANGELOG.md"
commit_head edited
check "a hand-edited entry fails with a unified diff" 1 "+++" run edited base
check "the edit is visible in the diff" 1 "allegedly" run edited base
check "the diff failure teaches redo-with-the-tool, never hand-edit" 1 \
  "never to hand-edit" run edited base

# Re-ordering away from the canonical order: the section is hand-built with
# the right entries in the wrong order (the assembler puts 12 before 9).
seed_flat reordered
rm "$TMP/reordered/changelog.d/12.md" "$TMP/reordered/changelog.d/9.md"
cat >"$TMP/reordered/CHANGELOG.md" <<'EOF'
# Changelog

Preamble prose belongs to no section.

## 0.2.0 — 2026-07-24

- Nine landed, and its prose wraps onto a
  continuation line (#9).
- Twelve landed (#12).

## 0.1.0 — 2026-07-01

- The shipped entry.
EOF
printf '0.2.0\n' >"$TMP/reordered/VERSION"
commit_head reordered
check "re-ordered entries fail" 1 "NOT what the fragments" run reordered base

# A faithful assembly that forgot one deletion: the section is right, the
# directory is not — only the survivor refusal fires.
seed_flat survivor
ceremony survivor 0.2.0 2026-07-24
printf -- '- Nine landed, and its prose wraps onto a\n  continuation line (#9).\n' >"$TMP/survivor/changelog.d/9.md"
commit_head survivor
check "a surviving fragment with its entry present fails" 1 "STILL PRESENT" \
  run survivor base
check "the survivor refusal names the file" 1 "changelog.d/9.md" \
  run survivor base

# Fragments consumed, section never stamped: the prose went nowhere.
seed_flat halfdone
rm "$TMP/halfdone/changelog.d/12.md" "$TMP/halfdone/changelog.d/9.md"
printf '0.2.0\n' >"$TMP/halfdone/VERSION"
commit_head halfdone
check "fragments consumed but no section stamped fails" 1 \
  "non-empty section for '0.2.0'" run halfdone base

# A release stamped out of a fragment-free directory: the replay refuses the
# way the real assembler would have — an empty release.
seed_flat empty-release
rm "$TMP/empty-release/changelog.d/12.md" "$TMP/empty-release/changelog.d/9.md"
git -C "$TMP/empty-release" add -A
git -C "$TMP/empty-release" commit -qm consume-early
git -C "$TMP/empty-release" branch -f base
cat >"$TMP/empty-release/CHANGELOG.md" <<'EOF'
# Changelog

Preamble prose belongs to no section.

## 0.2.0 — 2026-07-24

- Prose from nowhere.

## 0.1.0 — 2026-07-01

- The shipped entry.
EOF
printf '0.2.0\n' >"$TMP/empty-release/VERSION"
commit_head empty-release
check "a section stamped from zero fragments fails on the replay's refusal" 1 \
  "zero fragments" run empty-release base

check "missing changelog fails" 1 "no such file" run faithful-flat base NOPE.md

# --- the trio interaction row (the issue's whole argument) -------------------
# On the faithful tree all three guards are green. On the dropped-entry tree
# monotonic is green (no heading was deleted) and, since #115's fragment
# mode, armed is red too — the surviving fragment is unconsumed on a bare
# tree — but only this guard names the entry the release LOST (#116 was
# written before #115 landed and expected armed green there; #117's flip
# recorded the interaction as it now stands). The hand-edited tree is where
# this guard stands alone: armed sees a publishable section, monotonic sees
# no deleted heading, and only the replay knows the prose is not what the
# authors wrote.

run_armed() { (cd "$TMP/$1" && bash "$ARMED"); }
run_monotonic() { local name="$1"; shift; (cd "$TMP/$name" && bash "$MONOTONIC" "$@"); }

check "trio, faithful tree: changelog-armed green" 0 "agrees" run_armed faithful-flat
check "trio, faithful tree: changelog-monotonic green" 0 "still present" \
  run_monotonic faithful-flat base
check "trio, faithful tree: changelog-assembled green" 0 "byte-for-byte" \
  run faithful-flat base
check "trio, dropped-entry tree: changelog-armed red too (unconsumed fragment)" 1 \
  "not consumed" run_armed dropped
check "trio, dropped-entry tree: changelog-monotonic stays green" 0 "still present" \
  run_monotonic dropped base
check "trio, dropped-entry tree: changelog-assembled names the lost entry" 1 \
  "Nine landed" run dropped base
check "trio, hand-edited tree: changelog-armed green" 0 "agrees" run_armed edited
check "trio, hand-edited tree: changelog-monotonic stays green" 0 "still present" \
  run_monotonic edited base
check "trio, hand-edited tree: changelog-assembled is the only red" 1 "allegedly" \
  run edited base

# --- degradation: the loud skip and the STRICT refusal -----------------------

seed_flat no-base
ceremony no-base 0.2.0 2026-07-24
commit_head no-base
check "base ref missing, STRICT=0: loud skip, exit 0" 0 "SKIPPED" \
  run no-base does-not-exist
check "base ref missing, STRICT=1: hard failure" 1 "FAILURE" \
  run_strict no-base does-not-exist
check "the STRICT failure names the checkout fix, not the script" 1 "fetch-depth: 0" \
  run_strict no-base does-not-exist

mkdir -p "$TMP/plain"
printf '# Changelog\n\n## Unreleased\n' >"$TMP/plain/CHANGELOG.md"
check "not a git repo, STRICT=0: loud skip" 0 "not inside a git work tree" \
  run plain
check "not a git repo, STRICT=1: hard failure" 1 "FAILURE" run_strict plain

# --- the honest edges --------------------------------------------------------

# Push-to-main shape: the merge base IS HEAD, nothing was consumed between
# them, and the success line must say so instead of claiming a comparison.
seed_flat vacuous
ceremony vacuous 0.2.0 2026-07-24
commit_head vacuous
check "merge base IS HEAD: vacuous, named honestly" 0 "vacuous" run vacuous HEAD

# --- the action's wiring: inputs arrive as env vars --------------------------

# Non-default names for everything action.yml passes, STRICT included, prove
# the env vars are honored the way the composite sets them.
init_repo env-tree
mkdir -p "$TMP/env-tree/frags"
printf '# Changelog\n\n## 0.1.0 — 2026-07-01\n\n- Shipped.\n' >"$TMP/env-tree/NOTES.md"
printf '0.1.1-dev\n' >"$TMP/env-tree/VERSION"
printf -- '- Flagged entry (#2).\n' >"$TMP/env-tree/frags/2.md"
git -C "$TMP/env-tree" add -A
git -C "$TMP/env-tree" commit -qm base
git -C "$TMP/env-tree" branch fixture-base
(cd "$TMP/env-tree" && "$ASSEMBLE" 0.2.0 2026-07-24 --changelog NOTES.md --dir frags >/dev/null 2>&1)
printf '0.2.0\n' >"$TMP/env-tree/VERSION"
git -C "$TMP/env-tree" add -A
git -C "$TMP/env-tree" commit -qm head
env_tree() {
  (cd "$TMP/env-tree" && \
    CHANGELOG_ASSEMBLED_BASE=fixture-base CHANGELOG=NOTES.md \
    CHANGELOG_ASSEMBLED_DIR=frags VERSION_SOURCE=file \
    CHANGELOG_ASSEMBLED_STRICT=1 bash "$SCRIPT")
}
check "env vars drive the script the way action.yml does" 0 "byte-for-byte" env_tree

summary
