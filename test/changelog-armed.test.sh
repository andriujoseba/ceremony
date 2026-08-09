#!/usr/bin/env bash
# Contract tests for actions/changelog-armed (issue #5). Constructed fixture
# trees — a dir with a changelog plus a VERSION file or package.json, not
# git repos — the same discipline as the box suite this guard is ported
# from. set -u, not -e: failing commands are behavior for the harness to
# inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/actions/changelog-armed/changelog-armed.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The guard reads the consumer's tree at its working directory, so every
# case runs from inside a constructed fixture tree.
in_tree() {
  local dir="$1"
  shift
  (cd "$TMP/$dir" && bash "$SCRIPT" "$@")
}

# tree <name> <version> — a fixture tree with a VERSION file; the changelog
# body arrives on stdin.
tree() {
  mkdir -p "$TMP/$1"
  printf '%s\n' "$2" >"$TMP/$1/VERSION"
  cat >"$TMP/$1/CHANGELOG.md"
}

# pkg_tree <name> <version> — the same, package-json backend.
pkg_tree() {
  mkdir -p "$TMP/$1"
  printf '{ "name": "fixture", "version": "%s" }\n' "$2" >"$TMP/$1/package.json"
  cat >"$TMP/$1/CHANGELOG.md"
}

# --- the -dev rows: top section MUST be '## Unreleased' ----------------------

tree dev-armed 1.2.4-dev <<'EOF'
# Changelog

## Unreleased

- Pending entry.

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
check "-dev + Unreleased on top passes" 0 "agrees" in_tree dev-armed

tree dev-seeded 1.2.4-dev <<'EOF'
# Changelog

## Unreleased

### Added

### Changed

### Fixed

## 1.2.3 — 2026-07-20

### Fixed

- The shipped entry.
EOF
check "-dev + seeded empty Unreleased headings passes" 0 "agrees" in_tree dev-seeded

tree dev-stamped 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
check "-dev + stamped top fails" 1 "development tree" in_tree dev-stamped
check "-dev failure names the file" 1 "CHANGELOG.md" in_tree dev-stamped
check "-dev failure teaches the re-arm fix" 1 "re-arm" in_tree dev-stamped

# --- the bare rows: both ceremony shapes legal, half-ceremonies refused -----

tree bare-armed 1.2.3 <<'EOF'
# Changelog

## Unreleased

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
check "bare + re-armed tree passes" 0 "agrees" in_tree bare-armed

tree bare-stamped 1.2.3 <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.

## 1.2.2 — 2026-07-01

- Older entry.
EOF
check "bare + own stamped section on top passes" 0 "agrees" in_tree bare-stamped

tree bare-dangling-heading 1.2.3 <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

### Added
EOF
check "bare + dangling heading fails with the heading diagnosis" 1 \
  "section '1.2.3' has no entries — a heading is not an entry" \
  in_tree bare-dangling-heading
check "bare + dangling heading keeps the half-ceremony remedy" 1 \
  "HALF-DONE ceremony" in_tree bare-dangling-heading

tree bare-partly-dangling 1.2.3 <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

### Added

### Fixed

- Fixed entry.
EOF
check "bare + one empty grouped heading names the first empty heading" 1 \
  "section '1.2.3' has an empty heading: '### Added'" \
  in_tree bare-partly-dangling

tree bare-empty-stamp 1.2.3 <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

## 1.2.2 — 2026-07-01

- Older entry.
EOF
check "bare + own stamped section but EMPTY fails" 1 "no non-empty" \
  in_tree bare-empty-stamp

tree bare-wrong-stamp 1.2.3 <<'EOF'
# Changelog

## 9.9.9 — 2026-07-20

- An entry under the wrong number.
EOF
check "bare + top section naming another version fails" 1 "stamped the wrong number" \
  in_tree bare-wrong-stamp

tree bare-half-ceremony 1.2.3 <<'EOF'
# Changelog

## Unreleased

- Pending entry that was never stamped.

## 1.2.2 — 2026-07-01

- Older entry.
EOF
check "bare + no section for the version anywhere fails" 1 "HALF-DONE ceremony" \
  in_tree bare-half-ceremony

# Whole-version matching: 1.2.3 must not be satisfied by a 1.2.3-rc1 section.
tree bare-rc-only 1.2.3 <<'EOF'
# Changelog

## Unreleased

## 1.2.3-rc1 — 2026-07-15

- The candidate's entry.
EOF
check "bare: an rc section never satisfies the bare version" 1 "HALF-DONE ceremony" \
  in_tree bare-rc-only

# An rc is tag-only: a stamped rc section at the top is always drift.
tree rc-stamped 2.0.0-rc1 <<'EOF'
# Changelog

## 2.0.0-rc1 — 2026-07-20

- The candidate's entry.
EOF
check "heading mode: stamped rc top section fails as tag-only drift" 1 \
  "tag-only (#317 D1)" in_tree rc-stamped

tree rc-heading-mode 2.0.0-rc1 <<'EOF'
# Changelog

## 1.9.0 — 2026-07-20

- The prior release.
EOF
check "rc tree refuses heading mode and teaches fragment adoption" 1 \
  "fragment-mode only (#317 D4); adopt changelog fragments" in_tree rc-heading-mode

# --- degenerate trees --------------------------------------------------------

tree no-sections 1.2.3-dev <<'EOF'
# Changelog

Only preamble prose, no sections.
EOF
check "changelog with no '## ' at all fails" 1 "nothing for a PR entry to land under" \
  in_tree no-sections

mkdir -p "$TMP/no-changelog"
printf '1.2.3\n' >"$TMP/no-changelog/VERSION"
check "missing changelog fails" 1 "no such file" in_tree no-changelog

mkdir -p "$TMP/no-version"
printf '# Changelog\n\n## Unreleased\n' >"$TMP/no-version/CHANGELOG.md"
check "missing version source fails" 1 "cannot read the version" in_tree no-version

check "unknown version-source refused" 1 "unknown backend" \
  in_tree dev-armed CHANGELOG.md carrier-pigeon

# --- the package-json backend ------------------------------------------------

pkg_tree pkg-dev-armed 0.2.0-dev <<'EOF'
# Changelog

## Unreleased

- Pending entry.

## 0.1.0 — 2026-07-20

- The shipped entry.
EOF
check "package-json: -dev + armed passes" 0 "agrees" \
  in_tree pkg-dev-armed CHANGELOG.md package-json

pkg_tree pkg-bare-armed 0.1.0 <<'EOF'
# Changelog

## Unreleased

## 0.1.0 — 2026-07-20

- The shipped entry.
EOF
check "package-json: bare + armed passes" 0 "agrees" \
  in_tree pkg-bare-armed CHANGELOG.md package-json

# --- fragment mode: changelog.d/ is the arming -------------------------------

fragment_tree() {
  local name="$1" version="$2"
  shift 2
  tree "$name" "$version"
  mkdir -p "$TMP/$name/changelog.d"
  printf '%s\n' "# Changelog fragments" >"$TMP/$name/changelog.d/README.md"
}

fragment_tree fragments-dev-empty 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
check "fragment -dev + marker + no fragments passes" 0 "fragment mode" \
  in_tree fragments-dev-empty

fragment_tree fragments-dev-flat 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf '%s\n' "- Added fragment mode (#115)." >"$TMP/fragments-dev-flat/changelog.d/115.md"
check "fragment -dev + well-formed flat fragment passes" 0 "fragment mode" \
  in_tree fragments-dev-flat

fragment_tree fragments-rc-survivor 2.0.0-rc1 <<'EOF'
# Changelog

## 1.9.0 — 2026-07-20

- The prior release.
EOF
printf '%s\n' "- Candidate entry survives (#319)." \
  >"$TMP/fragments-rc-survivor/changelog.d/319.md"
check "fragment rc + surviving publishable fragment passes explicitly as rc" 0 \
  "rc fragment-mode state" in_tree fragments-rc-survivor

fragment_tree fragments-rc-stamped 2.0.0-rc1 <<'EOF'
# Changelog

## 2.0.0-rc1 — 2026-07-20

- Candidate entry that should not have been stamped.
EOF
check "fragment rc refuses a stamped rc top section as tag-only drift" 1 \
  "tag-only (#317 D1)" in_tree fragments-rc-stamped

# The entry length bound (#167) reds the PR that writes the fragment, with
# the shared changelog_fragment_problem diagnosis.
fragment_tree fragments-dev-over-bound 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf -- '- %s\n' \
  "$(awk 'BEGIN { s = ""; while (length(s) < 301) s = s "a"; print s }')" \
  >"$TMP/fragments-dev-over-bound/changelog.d/115.md"
check "fragment mode refuses an over-bound entry, fragment and length named" 1 \
  "115.md' has a 301-character entry" \
  in_tree fragments-dev-over-bound
check "fragment mode over-bound refusal names the bound and the split fix" 1 \
  "the bound is 300: split it into multiple '- ' entries in this same fragment" \
  in_tree fragments-dev-over-bound

# The terminal cite (#262) reds the PR that writes the fragment, through the
# same shared predicate — which is the whole point of the rule living there
# rather than in prose a reviewer has to remember.
fragment_tree fragments-dev-uncited 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf '%s\n' "- An entry that never learned to cite its issue." \
  >"$TMP/fragments-dev-uncited/changelog.d/115.md"
check "fragment mode refuses an uncited entry, fragment named" 1 \
  "115.md' has an entry with no issue citation" \
  in_tree fragments-dev-uncited
check "fragment mode uncited refusal names the shape to write" 1 \
  "end it with the issue it comes from: '(#N).'" \
  in_tree fragments-dev-uncited

fragment_tree fragments-dev-misplaced-cite 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf '%s\n' "- The citation trails the period. (#115)" \
  >"$TMP/fragments-dev-misplaced-cite/changelog.d/115.md"
check "fragment mode refuses a non-terminal citation, fragment named" 1 \
  "115.md' has an entry whose issue citation is not terminal" \
  in_tree fragments-dev-misplaced-cite

fragment_tree fragments-dev-grouped 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

### Fixed

- The shipped entry.
EOF
cat >"$TMP/fragments-dev-grouped/changelog.d/115.md" <<'EOF'
### Changed

- Added fragment mode (#115).
EOF
check "fragment -dev + well-formed grouped fragment passes" 0 "fragment mode" \
  in_tree fragments-dev-grouped

fragment_tree fragments-dev-mixed 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf '%s\n' "- Flat fragment (#115)." >"$TMP/fragments-dev-mixed/changelog.d/114.md"
cat >"$TMP/fragments-dev-mixed/changelog.d/115.md" <<'EOF'
### Fixed

- Grouped fragment (#115).
EOF
check "fragment mode refuses mixed shapes with the shared assembler diagnosis" 1 \
  "fragment 'changelog.d/115.md' is grouped but fragment 'changelog.d/114.md' is not" \
  in_tree fragments-dev-mixed

fragment_tree fragments-dev-all-grouped-over-flat 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
cat >"$TMP/fragments-dev-all-grouped-over-flat/changelog.d/115.md" <<'EOF'
### Fixed

- Grouped fragment (#115).
EOF
check "fragment mode refuses an all-grouped set over a flat published section" 1 \
  "changelog.d/115.md' is grouped but newest published section '1.2.3'" \
  in_tree fragments-dev-all-grouped-over-flat

fragment_tree fragments-dev-flat-over-grouped 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

### Fixed

- The shipped entry.
EOF
printf '%s\n' "- Flat fragment (#115)." >"$TMP/fragments-dev-flat-over-grouped/changelog.d/115.md"
check "fragment mode refuses a flat set over a grouped published section" 1 \
  "changelog.d/115.md' is flat but newest published section '1.2.3'" \
  in_tree fragments-dev-flat-over-grouped

# The declared anchor (#182): the flip tree — a grouped set under a
# 'grouped' sentinel over a flat published section — is green, where the
# same tree minus the sentinel is the all-grouped-over-flat red row above.
fragment_tree fragments-dev-flip 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf '%s\n' "grouped" >"$TMP/fragments-dev-flip/changelog.d/shape"
cat >"$TMP/fragments-dev-flip/changelog.d/115.md" <<'EOF'
### Fixed

- Grouped fragment (#115).
EOF
check "fragment mode: 'grouped' sentinel admits the flip tree over a flat published section" 0 \
  "fragment mode" in_tree fragments-dev-flip

# Post-flip drift is refused on its own PR: a flat probe fragment atop the
# flip tree goes red — beside grouped fragments the mix rule names it first.
printf '%s\n' "- Flat probe (#116)." >"$TMP/fragments-dev-flip/changelog.d/116.md"
check "fragment mode: a flat probe atop the flip tree is refused" 1 \
  "changelog.d/115.md' is grouped but fragment 'changelog.d/116.md' is not" \
  in_tree fragments-dev-flip
rm "$TMP/fragments-dev-flip/changelog.d/116.md"

# And once the grouped fragments are consumed, the sentinel alone still
# holds the shape: an all-flat set under 'grouped' is refused, sentinel
# named — the published-section inference never gets a say.
rm "$TMP/fragments-dev-flip/changelog.d/115.md"
printf '%s\n' "- Flat probe (#116)." >"$TMP/fragments-dev-flip/changelog.d/116.md"
check "fragment mode: a flat set under the 'grouped' sentinel refused, sentinel named" 1 \
  "changelog.d/116.md' is flat but 'changelog.d/shape' declares grouped" \
  in_tree fragments-dev-flip
rm "$TMP/fragments-dev-flip/changelog.d/116.md"

printf '%s\n' "Grouped" >"$TMP/fragments-dev-flip/changelog.d/shape"
check "fragment mode: a malformed sentinel is refused, file named" 1 \
  "'changelog.d/shape' declares neither shape" \
  in_tree fragments-dev-flip

printf 'grouped\n\n' >"$TMP/fragments-dev-flip/changelog.d/shape"
check "fragment mode: a sentinel with a trailing blank line is refused, file named" 1 \
  "'changelog.d/shape' declares neither shape" \
  in_tree fragments-dev-flip

fragment_tree fragments-dev-no-published 1.2.4-dev <<'EOF'
# Changelog

Preamble only.
EOF
cat >"$TMP/fragments-dev-no-published/changelog.d/115.md" <<'EOF'
### Fixed

- Grouped fragment (#115).
EOF
check "fragment mode accepts a consistent set with no published section" 0 \
  "fragment mode" in_tree fragments-dev-no-published

fragment_tree fragments-unreleased 1.2.4-dev <<'EOF'
# Changelog

## Unreleased

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
check "fragment mode refuses even an empty Unreleased section" 1 \
  "Unreleased' section survived the adoption" in_tree fragments-unreleased

fragment_tree fragments-no-marker 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
rm "$TMP/fragments-no-marker/changelog.d/README.md"
check "fragment mode requires the generated marker" 1 "README.md" \
  in_tree fragments-no-marker

fragment_tree fragments-bad-name 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf '%s\n' "- An entry." >"$TMP/fragments-bad-name/changelog.d/notes.md"
check "fragment mode quotes malformed-fragment diagnosis and file" 1 \
  "fragment 'changelog.d/notes.md' is not named for its issue" \
  in_tree fragments-bad-name

fragment_tree fragments-dangling-group 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
printf '%s\n' "### Changed" >"$TMP/fragments-dangling-group/changelog.d/115.md"
check "fragment mode refuses a dangling fragment heading" 1 \
  "fragment 'changelog.d/115.md' has no entries" \
  in_tree fragments-dangling-group

fragment_tree fragments-bare-stamped 1.2.3 <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.

## 1.2.2 — 2026-07-01

- The older entry.
EOF
check "fragment bare + stamped section + consumed directory passes" 0 \
  "fragment mode" in_tree fragments-bare-stamped

cp -R "$TMP/fragments-bare-stamped" "$TMP/fragments-bare-survivor"
printf '%s\n' "- This entry was not consumed (#115)." \
  >"$TMP/fragments-bare-survivor/changelog.d/115.md"
check "fragment bare refuses and lists surviving fragments" 1 \
  "these fragments were not consumed: changelog.d/115.md" \
  in_tree fragments-bare-survivor

fragment_tree fragments-bare-wrong 1.2.3 <<'EOF'
# Changelog

## 9.9.9 — 2026-07-20

- The wrong release.

## 1.2.3 — 2026-07-19

- The right release was not stamped on top.
EOF
check "fragment bare refuses a stamp for another version" 1 \
  "stamped the wrong number" in_tree fragments-bare-wrong

fragment_tree fragments-bare-missing 1.2.3 <<'EOF'
# Changelog

## 1.2.2 — 2026-07-01

- The older entry.
EOF
check "fragment bare refuses a missing stamp via section diagnosis" 1 \
  "no section for '1.2.3'" in_tree fragments-bare-missing

fragment_tree fragments-cross-mode 1.2.4-dev <<'EOF'
# Changelog

## 1.2.3 — 2026-07-20

- The shipped entry.
EOF
check "same changelog passes in fragment mode" 0 "fragment mode" \
  in_tree fragments-cross-mode
rm -rf "$TMP/fragments-cross-mode/changelog.d"
check "same changelog fails in legacy mode" 1 "development tree" \
  in_tree fragments-cross-mode

# --- the action's wiring: inputs arrive as env vars --------------------------

mkdir -p "$TMP/env-tree"
printf '1.2.4-dev\n' >"$TMP/env-tree/VERSION"
printf '# Changelog\n\n## Unreleased\n\n- Pending.\n' >"$TMP/env-tree/NOTES.md"
# A non-default changelog name proves the env var is honored, not the default.
env_tree() {
  (cd "$TMP/env-tree" && CHANGELOG=NOTES.md VERSION_SOURCE=file bash "$SCRIPT")
}
check "env vars drive the script the way action.yml does" 0 "agrees" env_tree

mkdir -p "$TMP/env-fragments/custom.d"
printf '1.2.4-dev\n' >"$TMP/env-fragments/VERSION"
printf '# Changelog\n\n## 1.2.3 — 2026-07-20\n\n- Shipped.\n' \
  >"$TMP/env-fragments/CHANGELOG.md"
printf '%s\n' "# Changelog fragments" >"$TMP/env-fragments/custom.d/README.md"
env_fragments() {
  (cd "$TMP/env-fragments" && FRAGMENTS_DIR=custom.d bash "$SCRIPT")
}
check "fragments-dir env var selects fragment mode" 0 "fragment mode" env_fragments

summary
