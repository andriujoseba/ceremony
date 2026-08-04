#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=lib/changelog.sh
source "$ROOT/lib/changelog.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/CHANGELOG.md"
cat >"$FIXTURE" <<'EOF'
# Changelog

Preamble prose belongs to no section.

## Unreleased

- Not yet released and never part of a version.

## 0.7.0 — 2026-07-20

### Added

- The seven-oh entry.

## 0.7.0-rc1 — 2026-07-19

- The release-candidate entry.

## 0.6.0 — 2026-07-18

- The six-oh entry.

## 0.5.0 — 2026-07-15

## 0.4.0
- A date-less version heading also parses.
EOF

assert_section() {
  local version="$1" expected="$2" actual
  actual="$(changelog_section "$FIXTURE" "$version")"
  [ "$actual" = "$expected" ] || {
    printf 'wanted:\n%s\ngot:\n%s\n' "$expected" "$actual"
    return 1
  }
}

check "extracts one section body exactly" 0 "" assert_section 0.7.0 $'### Added\n\n- The seven-oh entry.'
check "adjacent older section does not bleed" 0 "" assert_section 0.6.0 '- The six-oh entry.'
check "whole match selects the rc section" 0 "" assert_section 0.7.0-rc1 '- The release-candidate entry.'
check "Unreleased parses as a date-less heading" 0 "" assert_section Unreleased '- Not yet released and never part of a version.'
check "date-less version heading parses" 0 "" assert_section 0.4.0 '- A date-less version heading also parses.'
check "empty stamped section returns empty output" 0 "" assert_section 0.5.0 ""
check "missing section returns empty output" 0 "" assert_section 9.9.9 ""

PROBLEM_FIXTURE="$TMP/CHANGELOG.problems.md"
assert_problem() {
  local version="$1" expected_status="$2" expected="$3"
  check "predicate: $version / $expected" "$expected_status" "$expected" \
    changelog_section_problem "$PROBLEM_FIXTURE" "$version"
}

cat >"$PROBLEM_FIXTURE" <<'EOF'
# Changelog

## Unreleased

### Added

### Changed

### Fixed

## 1.0.0

- Flat dash entry.

## 1.1.0

* Flat star entry.

## 1.2.0

### Fixed

- Fixed entry.

## 1.3.0

### Added

- Added entry.

### Changed

* Changed entry.

### Fixed

- Fixed entry.

## 1.4.0

## 1.5.0

### Added

## 1.6.0

### Added

### Fixed

- Fixed entry.
EOF

assert_problem Unreleased 0 ""
assert_problem 1.0.0 0 ""
assert_problem 1.1.0 0 ""
assert_problem 1.2.0 0 ""
assert_problem 1.3.0 0 ""
assert_problem 1.4.0 1 "section '1.4.0' has no entries — a heading is not an entry"
assert_problem 1.5.0 1 "section '1.5.0' has no entries — a heading is not an entry"
assert_problem 1.6.0 1 "section '1.6.0' has an empty heading: '### Added'"
assert_problem 9.9.9 1 "no section for '9.9.9'"

MISSING_UNRELEASED_FIXTURE="$TMP/CHANGELOG.missing-unreleased.md"
cat >"$MISSING_UNRELEASED_FIXTURE" <<'EOF'
# Changelog

## 1.0.0

- Released entry.
EOF
check "predicate: absent Unreleased still refuses" 1 "no section for 'Unreleased'" \
  changelog_section_problem "$MISSING_UNRELEASED_FIXTURE" Unreleased

WRAPPER="$ROOT/bin/changelog-section"
check "wrapper publishes the requested body" 0 "The seven-oh entry" "$WRAPPER" 0.7.0 "$FIXTURE"
check "wrapper refuses an empty section" 1 "no section for '0.5.0'" "$WRAPPER" 0.5.0 "$FIXTURE"
check "wrapper refuses an absent section" 1 "no section for '9.9.9'" "$WRAPPER" 9.9.9 "$FIXTURE"
check "wrapper explains how the release PR fixes refusal" 1 "assembles the section" "$WRAPPER" 9.9.9 "$FIXTURE"
check "wrapper refuses a heading-only version section" 1 \
  "section '1.5.0' has no entries — a heading is not an entry" \
  "$WRAPPER" 1.5.0 "$PROBLEM_FIXTURE"
check "wrapper names the first dangling heading" 1 \
  "section '1.6.0' has an empty heading: '### Added'" \
  "$WRAPPER" 1.6.0 "$PROBLEM_FIXTURE"
check "wrapper prints seeded empty Unreleased without refusing" 0 "### Added" \
  "$WRAPPER" Unreleased "$PROBLEM_FIXTURE"
check "wrapper requires a version" 2 "usage:" "$WRAPPER"
check "wrapper refuses a missing file" 1 "no such file" "$WRAPPER" 1.0.0 "$TMP/missing.md"

mkdir "$TMP/default-file"
cp "$FIXTURE" "$TMP/default-file/CHANGELOG.md"
# The child shell, not this one, expands its positional parameters.
# shellcheck disable=SC2016
check "version alone reads the default changelog" 0 "The seven-oh entry" \
  bash -c 'cd "$1" && "$2" "$3"' _ "$TMP/default-file" "$WRAPPER" 0.7.0

REALISTIC="$ROOT/test/fixtures/CHANGELOG.realistic.md"
check "realistic changelog keeps its production heading shape" 0 "A mint records its provenance" \
  "$WRAPPER" 0.9.0 "$REALISTIC"
check "realistic adjacent release remains independently extractable" 0 "Merging the release PR" \
  "$WRAPPER" 0.8.0 "$REALISTIC"

# --- the fragment reader (#114) ----------------------------------------------

FRAG="$TMP/frags"
mkdir -p "$FRAG"

check "fragments: absent directory is empty output, not an error" 0 "" \
  changelog_fragments "$TMP/no-such-dir"
check "fragments: fragment-free directory is empty output, not an error" 0 "" \
  changelog_fragments "$FRAG"

printf 'marker\n' >"$FRAG/README.md"
check "fragments: README.md is the directory marker, never a fragment" 0 "" \
  changelog_fragments "$FRAG"

printf -- '- Two (#2).\n' >"$FRAG/2.md"
printf -- '- Nine (#9).\n' >"$FRAG/9.md"
printf -- '- Ten (#10).\n' >"$FRAG/10.md"
printf -- '- Cross (#14).\n' >"$FRAG/ceremony-14.md"
printf -- '- Local fourteen (#14).\n' >"$FRAG/14.md"

assert_fragments_order() {
  local expected="$1" actual
  actual="$(changelog_fragments "$FRAG" | awk -F/ '{ print $NF }' | tr '\n' ' ')"
  actual="${actual% }"
  [ "$actual" = "$expected" ] || {
    printf 'wanted: %s\ngot: %s\n' "$expected" "$actual"
    return 1
  }
}
check "fragments: issue number descending (numeric, 10 before 9), filename tie-break" 0 "" \
  assert_fragments_order "14.md ceremony-14.md 10.md 9.md 2.md"

# --- the fragment predicate (#114) -------------------------------------------

PF="$TMP/frag-problems"
mkdir -p "$PF"

printf -- '- Fine (#7).\n' >"$PF/7.md"
check "fragment predicate: a flat fragment passes" 0 "" \
  changelog_fragment_problem "$PF/7.md"

cat >"$PF/8.md" <<'EOF'
### Added

- Grouped fine (#8).
EOF
check "fragment predicate: a grouped fragment passes" 0 "" \
  changelog_fragment_problem "$PF/8.md"

printf -- '- Cross-repo (#14).\n' >"$PF/ceremony-14.md"
check "fragment predicate: a cross-repo name passes" 0 "" \
  changelog_fragment_problem "$PF/ceremony-14.md"

printf -- '- Bad name.\n' >"$PF/Fix-12.md"
check "fragment predicate: an uppercase prefix is refused, file named" 1 "Fix-12.md" \
  changelog_fragment_problem "$PF/Fix-12.md"
printf -- '- Bad name.\n' >"$PF/notes.txt"
check "fragment predicate: a non-.md file is refused, file named" 1 "notes.txt" \
  changelog_fragment_problem "$PF/notes.txt"
printf -- '- Bad name.\n' >"$PF/12.markdown"
check "fragment predicate: .markdown is refused, file named" 1 "12.markdown" \
  changelog_fragment_problem "$PF/12.markdown"
printf -- '- No number.\n' >"$PF/notes.md"
check "fragment predicate: a name with no trailing issue number is refused" 1 "notes.md" \
  changelog_fragment_problem "$PF/notes.md"

cat >"$PF/20.md" <<'EOF'
## 1.0.0 — 2026-07-24

- Smuggled heading.
EOF
check "fragment predicate: a '## ' line is refused — the heading is the assembler's" 1 \
  "the section heading is the assembler's to write" \
  changelog_fragment_problem "$PF/20.md"

printf '### Added\n' >"$PF/21.md"
check "fragment predicate: no bullet anywhere is refused" 1 \
  "has no entries — a heading is not an entry" \
  changelog_fragment_problem "$PF/21.md"

cat >"$PF/22.md" <<'EOF'
### Added

### Fixed

- Fixed entry.
EOF
check "fragment predicate: a dangling grouped heading is refused, heading named" 1 \
  "has an empty heading: '### Added'" \
  changelog_fragment_problem "$PF/22.md"

# --- the entry length bound (#167) -------------------------------------------

# mkchars <n> — a run of n 'a's, for entries of exact constructed length.
mkchars() {
  awk -v n="$1" 'BEGIN { s = ""; while (length(s) < n) s = s "a"; print s }'
}

printf -- '- %s\n' "$(mkchars 301)" >"$PF/30.md"
check "length bound: a 301-character entry is refused, fragment and length named" 1 \
  "30.md' has a 301-character entry" \
  changelog_fragment_problem "$PF/30.md"
check "length bound: the refusal names the bound and the split fix" 1 \
  "the bound is 300: split it into multiple '- ' entries in this same fragment" \
  changelog_fragment_problem "$PF/30.md"

printf -- '- %s (#31).\n' "$(mkchars 293)" >"$PF/31.md"
check "length bound: an entry of exactly 300 passes" 0 "" \
  changelog_fragment_problem "$PF/31.md"

{
  printf -- '- %s (#32).\n' "$(mkchars 143)"
  printf -- '- %s (#32).\n' "$(mkchars 143)"
  printf -- '- %s (#32).\n' "$(mkchars 143)"
} >"$PF/32.md"
check "length bound: several within-bound entries pass though the file totals over 300" 0 "" \
  changelog_fragment_problem "$PF/32.md"

{
  printf -- '- %s\n' "$(mkchars 50)"
  printf '  %s\n' "$(mkchars 50)"
  printf '  %s\n' "$(mkchars 50)"
  printf '  %s\n' "$(mkchars 50)"
  printf '  %s (#33).\n' "$(mkchars 50)"
} >"$PF/33.md"
check "length bound: a ~250-character entry wrapped over four continuation lines passes" 0 "" \
  changelog_fragment_problem "$PF/33.md"

{
  printf '### Added\n\n'
  printf -- '- %s (#34).\n' "$(mkchars 293)"
} >"$PF/34.md"
check "length bound: a '### ' heading counts toward no entry — 300 under it still passes" 0 "" \
  changelog_fragment_problem "$PF/34.md"

{
  printf '### Added\n\n'
  printf -- '- %s\n' "$(mkchars 301)"
} >"$PF/35.md"
check "length bound: a grouped bullet is bounded the same as a flat one" 1 \
  "35.md' has a 301-character entry" \
  changelog_fragment_problem "$PF/35.md"

{
  printf -- '- %s\n' "$(mkchars 301)"
  printf -- '- Short.\n'
} >"$PF/36.md"
assert_single_diagnosis() {
  local count
  count="$(changelog_fragment_problem "$PF/36.md" | grep -c "301-character")"
  [ "$count" = 1 ] || {
    printf 'wanted one diagnosis, got %s\n' "$count"
    return 1
  }
}
check "length bound: an over-bound entry mid-file is diagnosed exactly once" 0 "" \
  assert_single_diagnosis

check "length bound: published sections stay unvalidated — 0.3.0's over-bound entries red nothing" 0 "" \
  changelog_section_problem "$ROOT/CHANGELOG.md" 0.3.0
check "length bound: published sections stay unvalidated — 0.2.0 reds nothing either" 0 "" \
  changelog_section_problem "$ROOT/CHANGELOG.md" 0.2.0

# --- the terminal issue cite (#262) ------------------------------------------

# cite_case <number> <entry-line...> — a fragment holding exactly the given
# lines, so a case reads as the entry it is about.
cite_case() {
  local num="$1"
  shift
  printf '%s\n' "$@" >"$PF/$num.md"
}

cite_case 40 '- Local (#262).'
check "cite: the canonical '(#N).' passes" 0 "" \
  changelog_fragment_problem "$PF/40.md"
cite_case 41 '- Sibling repo (crew#309).'
check "cite: a sibling-repo reference passes" 0 "" \
  changelog_fragment_problem "$PF/41.md"
cite_case 42 '- Fully qualified (heavy-duty/crew#309).'
check "cite: an owner/repo reference passes" 0 "" \
  changelog_fragment_problem "$PF/42.md"
cite_case 43 '- Two issues, one entry (#236, #250).'
check "cite: one group carrying two references passes" 0 "" \
  changelog_fragment_problem "$PF/43.md"

# The cite is measured on the normalized entry, so a citation that lands on
# a continuation line still closes the entry — the #167 lesson, repeated:
# wrapping alone must never red a compliant entry.
cite_case 44 '- An entry whose prose wraps onto a' '  continuation line, cite and all (#262).'
check "cite: a citation on a continuation line passes — the entry is normalized first" 0 "" \
  changelog_fragment_problem "$PF/44.md"

cite_case 45 '### Added' '' '- Added one (#101).' '- Added two (#102).' '' \
  '### Changed' '' '- Changed one (#103).' '' '### Fixed' '' '- Fixed one (#104).'
check "cite: a grouped fragment, three headings, every entry compliant, passes" 0 "" \
  changelog_fragment_problem "$PF/45.md"

# The two diagnoses are distinct by construction (D5): a builder who reads
# one must not be told the other's fix.
cite_case 50 '- No cite here.'
check "cite: an entry with no reference at all is refused" 1 \
  "50.md' has an entry with no issue citation" \
  changelog_fragment_problem "$PF/50.md"
check "cite: the uncited refusal names the shape to write" 1 \
  "end it with the issue it comes from: '(#N).'" \
  changelog_fragment_problem "$PF/50.md"

cite_case 51 '- Cite before the period. (#262)'
check "cite: a citation trailing the period is refused — the 248.md shape" 1 \
  "51.md' has an entry whose issue citation is not terminal" \
  changelog_fragment_problem "$PF/51.md"
check "cite: the misplaced refusal names the shape to write" 1 \
  "exactly one '(#N)' group ends the entry, the final '.' after it" \
  changelog_fragment_problem "$PF/51.md"

cite_case 52 '- Trailing prose (#262) and then more.'
check "cite: a citation with prose after it is refused" 1 \
  "has an entry whose issue citation is not terminal" \
  changelog_fragment_problem "$PF/52.md"

cite_case 53 '- Two groups (#236) and (#250).'
check "cite: two citation groups are refused — one terminal group, or none (D2)" 1 \
  "has an entry whose issue citation is not terminal" \
  changelog_fragment_problem "$PF/53.md"

cite_case 54 '- Bad token (#abc).'
check "cite: a reference with no digits is no reference" 1 \
  "has an entry with no issue citation" \
  changelog_fragment_problem "$PF/54.md"
cite_case 55 '- Bad token (#).'
check "cite: an empty reference is no reference" 1 \
  "has an entry with no issue citation" \
  changelog_fragment_problem "$PF/55.md"

# The citation need not name the file's own issue (D3): the filename already
# carries the authorizing one, so an entry may cite the incident beside it.
cite_case 56 '- Cites another issue entirely (#101).'
check "cite: the reference need not match the filename" 0 "" \
  changelog_fragment_problem "$PF/56.md"

# Ordering: the bound outranks the cite, so a fragment that reds today draws
# the diagnosis it drew before this rule existed.
{
  printf -- '- %s\n' "$(mkchars 301)"
  printf -- '- Uncited too.\n'
} >"$PF/57.md"
check "cite: an over-bound entry still reports the bound, not the cite" 1 \
  "57.md' has a 301-character entry" \
  changelog_fragment_problem "$PF/57.md"

# Published sections keep their pre-rule prose (D4): reddening history is a
# wall, not a guard. Every shipped section predates the cite.
check "cite: a published section with uncited entries still reds nothing" 0 "" \
  changelog_section_problem "$ROOT/CHANGELOG.md" 0.3.0

# The fragments this repo carries right now are the rule's own first
# constituency — the guard is worth nothing if the tree it ships in fails it.
assert_tree_fragments() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    changelog_fragment_problem "$f" || return 1
  done <<<"$(changelog_fragments "$ROOT/changelog.d")"
}
check "cite: every fragment in this tree passes the rule it ships" 0 "" \
  assert_tree_fragments

# --- the assembler (#114) ----------------------------------------------------

assert_assemble() {
  local dir="$1" expected="$2" actual
  actual="$(changelog_assemble "$dir")"
  [ "$actual" = "$expected" ] || {
    printf 'wanted:\n%s\ngot:\n%s\n' "$expected" "$actual"
    return 1
  }
}

AF="$TMP/assemble-flat"
mkdir -p "$AF"
printf 'marker\n' >"$AF/README.md"
cat >"$AF/3.md" <<'EOF'
- Three — an em dash, and prose that
  wraps onto a continuation line (#3).
EOF
printf -- '- Ten (#10).\n- Ten again (#10).\n' >"$AF/10.md"
check "assemble: flat fragments, newest issue first, prose verbatim" 0 "" \
  assert_assemble "$AF" $'- Ten (#10).\n- Ten again (#10).\n- Three — an em dash, and prose that\n  wraps onto a continuation line (#3).'

check "assemble: an empty directory is empty output — refusing is the caller's stance" 0 "" \
  changelog_assemble "$TMP/no-such-dir"

AG="$TMP/assemble-grouped"
mkdir -p "$AG"
cat >"$AG/21.md" <<'EOF'
### Fixed

- Fixed twenty-one (#21).
EOF
cat >"$AG/20.md" <<'EOF'
### Added

- Added twenty (#20).

### Docs

- Docs twenty (#20).
EOF
cat >"$AG/19.md" <<'EOF'
### Security

- Security nineteen (#19).

### Added

- Added nineteen (#19).
EOF
check "assemble: canonical group order, unnamed group appended, fragment order inside a group" 0 "" \
  assert_assemble "$AG" $'### Added\n\n- Added twenty (#20).\n- Added nineteen (#19).\n\n### Fixed\n\n- Fixed twenty-one (#21).\n\n### Security\n\n- Security nineteen (#19).\n\n### Docs\n\n- Docs twenty (#20).'

AM="$TMP/assemble-mixed"
mkdir -p "$AM"
printf -- '- Flat five (#5).\n' >"$AM/5.md"
cat >"$AM/6.md" <<'EOF'
### Added

- Grouped six (#6).
EOF
check "assemble: mixed shapes refused, grouped side named" 1 "6.md" \
  changelog_assemble "$AM"
check "assemble: mixed shapes refused, flat side named too" 1 "5.md" \
  changelog_assemble "$AM"

AX="$TMP/assemble-selfmixed"
mkdir -p "$AX"
cat >"$AX/7.md" <<'EOF'
- Ungrouped lead (#7).

### Added

- Grouped follow (#7).
EOF
check "assemble: one fragment mixing both shapes is refused, file named" 1 \
  "'$AX/7.md' mixes grouped headings and ungrouped bullets" \
  changelog_assemble "$AX"

# --- the fragment-set shape predicate (#159) ---------------------------------

SHAPE_CHANGELOG="$TMP/CHANGELOG.shape.md"
SHAPE_DIR="$TMP/shape-fragments"
mkdir -p "$SHAPE_DIR"

cat >"$SHAPE_CHANGELOG" <<'EOF'
# Changelog

## 2.0.0 — 2026-07-24

- Newest section is flat.

## 1.0.0 — 2026-07-01

### Fixed

- Older section is grouped.
EOF
printf -- '- Flat fragment (#1).\n' >"$SHAPE_DIR/1.md"
check "shape: flat set matches newest flat published section" 0 "" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

cat >"$SHAPE_DIR/1.md" <<'EOF'
### Fixed

- Grouped fragment (#1).
EOF
check "shape: grouped set names its conflict with newest flat published section" 1 \
  "fragment '$SHAPE_DIR/1.md' is grouped but newest published section '2.0.0' in '$SHAPE_CHANGELOG' is flat" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

cat >"$SHAPE_CHANGELOG" <<'EOF'
# Changelog

## 2.0.0 — 2026-07-24

### Fixed

- Newest section is grouped.
EOF
printf -- '- Flat fragment (#1).\n' >"$SHAPE_DIR/1.md"
check "shape: flat set names its conflict with newest grouped published section" 1 \
  "fragment '$SHAPE_DIR/1.md' is flat but newest published section '2.0.0' in '$SHAPE_CHANGELOG' is grouped" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

cat >"$SHAPE_DIR/1.md" <<'EOF'
### Fixed

- Grouped fragment (#1).
EOF
check "shape: grouped set matches newest grouped published section" 0 "" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
check "shape: consistent set with no published section passes" 0 "" \
  changelog_shape_problem "$TMP/no-such-changelog" "$SHAPE_DIR"
rm "$SHAPE_DIR/1.md"
check "shape: empty fragment set makes the anchor rule vacuous" 0 "" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

# --- the declarable anchor: <dir>/shape (#182) -------------------------------
# The sentinel pins the set's shape and outranks the newest-published-section
# inference — the door a deliberate flip walks through, while the undeclared
# drift rows above stay red, verbatim.

cat >"$SHAPE_CHANGELOG" <<'EOF'
# Changelog

## 2.0.0 — 2026-07-24

- Newest section is flat.
EOF
cat >"$SHAPE_DIR/1.md" <<'EOF'
### Fixed

- Grouped fragment (#1).
EOF
printf 'grouped\n' >"$SHAPE_DIR/shape"
check "shape: 'grouped' sentinel admits a grouped set over a flat published section" 0 "" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
check "shape: the sentinel binds with no changelog at all — the assembler's call" 0 "" \
  changelog_shape_problem "" "$SHAPE_DIR"

printf -- '- Flat fragment (#1).\n' >"$SHAPE_DIR/1.md"
check "shape: flat fragment under a 'grouped' sentinel refused, fragment and sentinel named" 1 \
  "fragment '$SHAPE_DIR/1.md' is flat but '$SHAPE_DIR/shape' declares grouped" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

cat >"$SHAPE_CHANGELOG" <<'EOF'
# Changelog

## 2.0.0 — 2026-07-24

### Fixed

- Newest section is grouped.
EOF
printf 'flat\n' >"$SHAPE_DIR/shape"
check "shape: 'flat' sentinel admits a flat set over a grouped published section" 0 "" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
cat >"$SHAPE_DIR/1.md" <<'EOF'
### Fixed

- Grouped fragment (#1).
EOF
check "shape: grouped fragment under a 'flat' sentinel refused, fragment and sentinel named" 1 \
  "fragment '$SHAPE_DIR/1.md' is grouped but '$SHAPE_DIR/shape' declares flat" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

printf 'grouped\n' >"$SHAPE_DIR/shape"
printf -- '- Flat two (#2).\n' >"$SHAPE_DIR/2.md"
check "shape: a mixed set is refused regardless of the sentinel" 1 \
  "fragment '$SHAPE_DIR/1.md' is grouped but fragment '$SHAPE_DIR/2.md' is not" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
rm "$SHAPE_DIR/1.md" "$SHAPE_DIR/2.md"

check "shape: empty fragment set with a valid sentinel passes" 0 "" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

printf 'Grouped\n' >"$SHAPE_DIR/shape"
check "shape: a capitalized sentinel is refused, file named" 1 \
  "'$SHAPE_DIR/shape' declares neither shape" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
: >"$SHAPE_DIR/shape"
check "shape: an empty sentinel is refused — never a silent fallback" 1 \
  "'$SHAPE_DIR/shape' declares neither shape" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
printf 'grouped\nflat\n' >"$SHAPE_DIR/shape"
check "shape: a two-line sentinel is refused" 1 \
  "'$SHAPE_DIR/shape' declares neither shape" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
# Trailing blank lines are the case command substitution launders away: the
# captured word is a clean 'grouped', only the file's line count still knows.
printf 'grouped\n\n' >"$SHAPE_DIR/shape"
check "shape: 'grouped' with a trailing blank line is refused, file named" 1 \
  "'$SHAPE_DIR/shape' declares neither shape" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"
printf 'flat\n\n' >"$SHAPE_DIR/shape"
check "shape: 'flat' with a trailing blank line is refused, file named" 1 \
  "'$SHAPE_DIR/shape' declares neither shape" \
  changelog_shape_problem "$SHAPE_CHANGELOG" "$SHAPE_DIR"

# The sentinel is not a fragment (#182 D3): the *.md glob is the mechanism,
# but the assertion is on the list itself, so a glob change cannot silently
# start publishing the sentinel.
printf 'grouped\n' >"$SHAPE_DIR/shape"
cat >"$SHAPE_DIR/1.md" <<'EOF'
### Fixed

- Grouped fragment (#1).
EOF
assert_fragments_exclude_sentinel() {
  local out
  out="$(changelog_fragments "$SHAPE_DIR")"
  [ -n "$out" ] || { echo "wanted a non-empty fragment list"; return 1; }
  if printf '%s\n' "$out" | grep -q '/shape$'; then
    printf 'the sentinel leaked into the fragment list:\n%s\n' "$out"
    return 1
  fi
}
check "fragments: the shape sentinel never enters the fragment list" 0 "" \
  assert_fragments_exclude_sentinel
rm "$SHAPE_DIR/1.md" "$SHAPE_DIR/shape"

AS="$TMP/assemble-sentinel"
mkdir -p "$AS"
printf 'grouped\n' >"$AS/shape"
cat >"$AS/30.md" <<'EOF'
### Fixed

- Fixed thirty (#30).
EOF
cat >"$AS/31.md" <<'EOF'
### Added

- Added thirty-one (#31).
EOF
check "assemble: the sentinel never assembles, and canonical order holds under it" 0 "" \
  assert_assemble "$AS" $'### Added\n\n- Added thirty-one (#31).\n\n### Fixed\n\n- Fixed thirty (#30).'
rm "$AS/30.md" "$AS/31.md"
printf -- '- Flat probe (#29).\n' >"$AS/29.md"
check "assemble: a flat set under a 'grouped' sentinel refuses to assemble" 1 \
  "declares grouped" \
  changelog_assemble "$AS"

summary
