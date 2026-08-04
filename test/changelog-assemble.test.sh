#!/usr/bin/env bash
# Contract tests for bin/changelog-assemble (issue #114). Constructed
# fixture trees, no git repos — the same discipline as
# test/changelog-armed.test.sh. set -u, not -e: failing commands are
# behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/changelog.sh
. "$ROOT/lib/changelog.sh"

TOOL="$ROOT/bin/changelog-assemble"
SECTION="$ROOT/bin/changelog-section"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# tree <name> — a fixture tree with changelog.d/ and its README marker;
# the changelog body arrives on stdin.
tree() {
  mkdir -p "$TMP/$1/changelog.d"
  printf 'Machine-assembled; see heavy-duty/ceremony#112.\n' >"$TMP/$1/changelog.d/README.md"
  cat >"$TMP/$1/CHANGELOG.md"
}

# frag <tree> <name> — a fragment; body on stdin.
frag() {
  cat >"$TMP/$1/changelog.d/$2"
}

# The tool reads the consumer's tree at its working directory, so every
# case runs from inside a constructed fixture tree.
in_tree() {
  local dir="$1"
  shift
  (cd "$TMP/$dir" && "$TOOL" "$@")
}

assert_file() {
  local file="$1" expected="$2" actual
  actual="$(cat "$file")"
  [ "$actual" = "$expected" ] || {
    printf 'wanted:\n%s\ngot:\n%s\n' "$expected" "$actual"
    return 1
  }
}

BASE_CHANGELOG=$'# Changelog\n\nPreamble prose belongs to no section.\n\n## 0.1.0 — 2026-07-01\n\n- The shipped entry.'

# --- flat write: exact bytes, exact deletions --------------------------------

tree flat-one <<EOF
$BASE_CHANGELOG
EOF
frag flat-one 12.md <<'EOF'
- Twelve landed (#12).
EOF
check "flat: one fragment assembles and stamps" 0 "consumed 1 fragment" \
  in_tree flat-one 0.2.0 2026-07-24
check "flat: preamble and shipped section stay byte-identical around the insert" 0 "" \
  assert_file "$TMP/flat-one/CHANGELOG.md" \
  $'# Changelog\n\nPreamble prose belongs to no section.\n\n## 0.2.0 — 2026-07-24\n\n- Twelve landed (#12).\n\n## 0.1.0 — 2026-07-01\n\n- The shipped entry.'
check "flat: the consumed fragment is deleted" 1 "" \
  test -e "$TMP/flat-one/changelog.d/12.md"
check "flat: README.md survives consumption" 0 "" \
  test -e "$TMP/flat-one/changelog.d/README.md"

# --- publication order: numeric, newest first, cross-repo beside local -------

tree flat-many <<EOF
$BASE_CHANGELOG
EOF
frag flat-many 2.md <<'EOF'
- Two (#2).
EOF
frag flat-many 9.md <<'EOF'
- Nine (#9).
EOF
frag flat-many 10.md <<'EOF'
- Ten (#10).
EOF
frag flat-many ceremony-14.md <<'EOF'
- Fourteen crossed over — naïve reflows would mangle this café's
  continuation line, so it must survive verbatim (#14).
EOF

assert_check() {
  local dir="$1" expected="$2" actual
  actual="$(in_tree "$dir" 0.2.0 2026-07-24 --check)"
  [ "$actual" = "$expected" ] || {
    printf 'wanted:\n%s\ngot:\n%s\n' "$expected" "$actual"
    return 1
  }
}
check "flat: numeric-descending order (10.md before 9.md), cross-repo name beside local" 0 "" \
  assert_check flat-many $'- Fourteen crossed over — naïve reflows would mangle this café'"'"$'s\n  continuation line, so it must survive verbatim (#14).\n- Ten (#10).\n- Nine (#9).\n- Two (#2).'

# --- grouped write: canonical order, unnamed group appended ------------------

tree grouped <<'EOF'
# Changelog

Preamble prose belongs to no section.

## 0.1.0 — 2026-07-01

### Fixed

- The shipped entry.
EOF
frag grouped 21.md <<'EOF'
### Fixed

- Fixed twenty-one (#21).
EOF
frag grouped 20.md <<'EOF'
### Added

- Added twenty (#20).
- Added twenty, second bullet (#20).

### Docs

- Docs twenty (#20).
EOF
frag grouped 19.md <<'EOF'
### Security

- Security nineteen (#19).

### Added

- Added nineteen (#19).
EOF
GROUPED_BODY=$'### Added\n\n- Added twenty (#20).\n- Added twenty, second bullet (#20).\n- Added nineteen (#19).\n\n### Fixed\n\n- Fixed twenty-one (#21).\n\n### Security\n\n- Security nineteen (#19).\n\n### Docs\n\n- Docs twenty (#20).'
check "grouped: --check shows canonical order, multi-bullet group, unnamed group last" 0 "" \
  assert_check grouped "$GROUPED_BODY"
check "grouped: write mode assembles the same section" 0 "consumed 3 fragment" \
  in_tree grouped 0.2.0 2026-07-24
check "grouped: the written file is exact" 0 "" \
  assert_file "$TMP/grouped/CHANGELOG.md" \
  $'# Changelog\n\nPreamble prose belongs to no section.\n\n## 0.2.0 — 2026-07-24\n\n'"$GROUPED_BODY"$'\n\n## 0.1.0 — 2026-07-01\n\n### Fixed\n\n- The shipped entry.'

# --- the declared anchor: the first grouped release over a flat history ------
# The flip ceremony (#182): a 'grouped' sentinel admits grouped fragments
# over a flat newest published section, the sentinel is never a stray file,
# and it survives the consumption (D5) — the next -dev tree still declares
# its shape.

tree flip <<EOF
$BASE_CHANGELOG
EOF
printf 'grouped\n' >"$TMP/flip/changelog.d/shape"
frag flip 40.md <<'EOF'
### Added

- Forty landed (#40).
EOF
check "sentinel: the flip release assembles grouped over a flat published section" 0 \
  "consumed 1 fragment" in_tree flip 0.2.0 2026-07-24
check "sentinel: the written flip section is exact" 0 "" \
  assert_file "$TMP/flip/CHANGELOG.md" \
  $'# Changelog\n\nPreamble prose belongs to no section.\n\n## 0.2.0 — 2026-07-24\n\n### Added\n\n- Forty landed (#40).\n\n## 0.1.0 — 2026-07-01\n\n- The shipped entry.'
check "sentinel: changelog.d/shape survives consumption" 0 "" \
  test -e "$TMP/flip/changelog.d/shape"

tree flip-flat-frag <<EOF
$BASE_CHANGELOG
EOF
printf 'grouped\n' >"$TMP/flip-flat-frag/changelog.d/shape"
frag flip-flat-frag 41.md <<'EOF'
- Flat forty-one (#41).
EOF
check "sentinel: a flat fragment under 'grouped' refuses, sentinel named" 1 \
  "changelog.d/shape' declares grouped" in_tree flip-flat-frag 0.2.0 2026-07-24

tree flip-malformed <<EOF
$BASE_CHANGELOG
EOF
printf 'Grouped\n' >"$TMP/flip-malformed/changelog.d/shape"
frag flip-malformed 42.md <<'EOF'
### Added

- Forty-two (#42).
EOF
check "sentinel: a malformed sentinel refuses, file named" 1 \
  "changelog.d/shape' declares neither shape" in_tree flip-malformed 0.2.0 2026-07-24

# --- a changelog holding only its preamble -----------------------------------

tree preamble-only <<'EOF'
# Changelog

Only preamble so far.
EOF
frag preamble-only 1.md <<'EOF'
- The first entry ever (#1).
EOF
check "a changelog with no section yet gets the section after the preamble" 0 "" \
  in_tree preamble-only 0.1.0 2026-07-24
check "preamble-only write is exact" 0 "" \
  assert_file "$TMP/preamble-only/CHANGELOG.md" \
  $'# Changelog\n\nOnly preamble so far.\n\n## 0.1.0 — 2026-07-24\n\n- The first entry ever (#1).'

# --- the fragment predicate at release time (#262) ---------------------------

# The cite rule joins changelog_fragment_problem, so it binds both callers:
# the arming guard at PR time and this assembler at release time. Asserted
# rather than assumed — a release that publishes an uncited entry is the
# failure the PR-time guard exists to have already caught.

tree uncited-release <<EOF
$BASE_CHANGELOG
EOF
frag uncited-release 60.md <<'EOF'
- An entry that never learned to cite its issue.
EOF
check "release time: an uncited fragment refuses the release, fragment named" 1 \
  "changelog.d/60.md' has an entry with no issue citation" \
  in_tree uncited-release 0.2.0 2026-07-24
check "release time: the uncited refusal survives --check too" 1 \
  "has an entry with no issue citation" \
  in_tree uncited-release 0.2.0 2026-07-24 --check
check "release time: the refused release wrote nothing" 0 "" \
  test -e "$TMP/uncited-release/changelog.d/60.md"

tree misplaced-release <<EOF
$BASE_CHANGELOG
EOF
frag misplaced-release 61.md <<'EOF'
- The citation trails the period. (#61)
EOF
check "release time: a non-terminal citation refuses the release" 1 \
  "changelog.d/61.md' has an entry whose issue citation is not terminal" \
  in_tree misplaced-release 0.2.0 2026-07-24

# --- --check is provably read-only -------------------------------------------

tree check-readonly <<EOF
$BASE_CHANGELOG
EOF
frag check-readonly 5.md <<'EOF'
- Five (#5).
EOF
cp -R "$TMP/check-readonly" "$TMP/check-readonly.before"
check "--check prints the assembled body" 0 "Five (#5)." \
  in_tree check-readonly 0.2.0 2026-07-24 --check
check "--check is read-only: the tree is byte-identical before and after" 0 "" \
  diff -r "$TMP/check-readonly.before" "$TMP/check-readonly"

# --- the date defaults to today (UTC) ----------------------------------------

check "date defaults without an argument" 0 "consumed 1 fragment" \
  in_tree check-readonly 0.2.0
check "the defaulted stamp is a UTC date" 0 "" \
  grep -qE '^## 0\.2\.0 — [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$TMP/check-readonly/CHANGELOG.md"

# --- --changelog and --dir override the defaults -----------------------------

mkdir -p "$TMP/flagged/frags"
printf '# Changelog\n\n## 0.1.0 — 2026-07-01\n\n- Shipped.\n' >"$TMP/flagged/NOTES.md"
printf -- '- Flagged entry (#2).\n' >"$TMP/flagged/frags/2.md"
check "--changelog and --dir override the defaults" 0 "" \
  "$TOOL" 0.2.0 2026-07-24 --changelog "$TMP/flagged/NOTES.md" --dir "$TMP/flagged/frags"
check "the flag-driven write landed in the named changelog" 0 "" \
  grep -qF -- "- Flagged entry (#2)." "$TMP/flagged/NOTES.md"

# --- refusals: each names the file responsible -------------------------------

tree empty-frags <<EOF
$BASE_CHANGELOG
EOF
rm "$TMP/empty-frags/changelog.d/README.md"
check "an empty directory refuses — a release publishes prose" 1 "zero fragments" \
  in_tree empty-frags 0.2.0
check "the empty-directory refusal names the directory" 1 "changelog.d" \
  in_tree empty-frags 0.2.0

tree only-readme <<EOF
$BASE_CHANGELOG
EOF
check "a README-only directory refuses with zero fragments" 1 "zero fragments" \
  in_tree only-readme 0.2.0

tree no-bullet <<EOF
$BASE_CHANGELOG
EOF
frag no-bullet 3.md <<'EOF'
Prose without a bullet is a heading in spirit.
EOF
check "a fragment with no bullet refuses, file named" 1 \
  "fragment 'changelog.d/3.md' has no entries" \
  in_tree no-bullet 0.2.0

tree dangling <<EOF
$BASE_CHANGELOG
EOF
frag dangling 4.md <<'EOF'
### Added

### Fixed

- Fixed entry.
EOF
check "a dangling grouped heading refuses, file and heading named" 1 \
  "fragment 'changelog.d/4.md' has an empty heading: '### Added'" \
  in_tree dangling 0.2.0

tree smuggled <<EOF
$BASE_CHANGELOG
EOF
frag smuggled 6.md <<'EOF'
## 0.2.0 — 2026-07-24

- An entry under a smuggled heading.
EOF
check "a fragment carrying a '## ' line refuses, file named" 1 \
  "fragment 'changelog.d/6.md' carries a '## ' heading" \
  in_tree smuggled 0.2.0

tree stray-txt <<EOF
$BASE_CHANGELOG
EOF
frag stray-txt 7.md <<'EOF'
- Seven (#7).
EOF
frag stray-txt notes.txt <<'EOF'
A stray scratchpad.
EOF
check "a stray notes.txt refuses, file named" 1 "notes.txt" \
  in_tree stray-txt 0.2.0

tree stray-markdown <<EOF
$BASE_CHANGELOG
EOF
frag stray-markdown 12.markdown <<'EOF'
- Wrong extension.
EOF
check "12.markdown refuses on the name pattern" 1 "12.markdown" \
  in_tree stray-markdown 0.2.0

tree stray-case <<EOF
$BASE_CHANGELOG
EOF
frag stray-case Fix-12.md <<'EOF'
- Uppercase prefix.
EOF
check "Fix-12.md refuses on the name pattern" 1 "Fix-12.md" \
  in_tree stray-case 0.2.0

tree mixed <<EOF
$BASE_CHANGELOG
EOF
frag mixed 5.md <<'EOF'
- Flat five (#5).
EOF
frag mixed 6.md <<'EOF'
### Added

- Grouped six (#6).
EOF
check "grouped + flat mixed refuses, both files named" 1 "6.md" \
  in_tree mixed 0.2.0
check "the mixed refusal names the flat side too" 1 "5.md" \
  in_tree mixed 0.2.0

tree grouped-over-flat <<EOF
$BASE_CHANGELOG
EOF
frag grouped-over-flat 6.md <<'EOF'
### Added

- Grouped six (#6).
EOF
check "an all-grouped set over a flat published section refuses before assembly" 1 \
  "fragment 'changelog.d/6.md' is grouped but newest published section '0.1.0'" \
  in_tree grouped-over-flat 0.2.0

tree already <<'EOF'
# Changelog

## 0.2.0 — 2026-07-20

- Already shipped.
EOF
frag already 4.md <<'EOF'
- A late fragment (#4).
EOF
check "an already-present section refuses — the ceremony was already run" 1 \
  "already has a section for '0.2.0'" \
  in_tree already 0.2.0

# Whole-version matching, as everywhere in this family: an rc section never
# blocks the bare version.
tree rc-present <<'EOF'
# Changelog

## 0.2.0-rc1 — 2026-07-15

- The candidate's entry.
EOF
frag rc-present 8.md <<'EOF'
- The real release entry (#8).
EOF
check "an rc section does not block assembling the bare version" 0 "" \
  in_tree rc-present 0.2.0 2026-07-24

mkdir -p "$TMP/no-changelog/changelog.d"
printf -- '- Entry (#2).\n' >"$TMP/no-changelog/changelog.d/2.md"
check "a missing changelog refuses" 1 "no such file" \
  in_tree no-changelog 0.2.0

# --- usage errors exit 2 -----------------------------------------------------

check "no arguments is a usage error" 2 "usage:" in_tree flat-one
check "an unknown flag is a usage error" 2 "usage:" in_tree flat-one 0.2.0 --frobnicate
check "a third positional is a usage error" 2 "usage:" in_tree flat-one 0.2.0 2026-07-24 extra
check "--dir without a value is a usage error" 2 "usage:" in_tree flat-one 0.2.0 --dir

# --- round trip: the publisher and the assembler agree by test ---------------

tree round-trip <<'EOF'
# Changelog

Preamble prose belongs to no section.

## 0.1.0 — 2026-07-01

### Fixed

- The shipped entry.
EOF
frag round-trip 30.md <<'EOF'
### Added

- Thirty — wraps onto a
  continuation line with a naïve café (#30).
EOF
frag round-trip 29.md <<'EOF'
### Fixed

- Fixed twenty-nine (#29).
EOF
CHECKED="$(in_tree round-trip 0.2.0 2026-07-24 --check)"
check "round trip: write mode succeeds after --check" 0 "" \
  in_tree round-trip 0.2.0 2026-07-24

assert_round_trip() {
  local published
  published="$( (cd "$TMP/round-trip" && "$SECTION" 0.2.0) )"
  [ "$published" = "$CHECKED" ] || {
    printf -- '--check said:\n%s\nthe publisher said:\n%s\n' "$CHECKED" "$published"
    return 1
  }
}
check "round trip: bin/changelog-section returns exactly the body --check printed" 0 "" \
  assert_round_trip
check "round trip: the assembled section reports no problem" 0 "" \
  changelog_section_problem "$TMP/round-trip/CHANGELOG.md" 0.2.0

# --- idempotence: the ceremony cannot run twice ------------------------------

check "a second write over the consumed directory refuses with zero fragments" 1 \
  "zero fragments" \
  in_tree round-trip 0.2.0 2026-07-24

summary
