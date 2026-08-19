#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=actions/labels-scope/labels-scope.sh
source "$ROOT/actions/labels-scope/labels-scope.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TAB="$(printf '\t')"

# --- glob_to_regex: the minimatch subset the family actually uses ------------

check "glob: ** crosses slashes" 0 '^lib/.*$' glob_to_regex 'lib/**'
check "glob: * stays inside a segment" 0 '^[^/]*\.md$' glob_to_regex '*.md'
check "glob: ? is one non-slash char" 0 '^doc[^/]/x$' glob_to_regex 'doc?/x'
check "glob: literal path is anchored whole" 0 '^README$' glob_to_regex 'README'
check "glob: dots are escaped, not wildcards" 0 \
  '^commands/users-[^/]*\.sh$' glob_to_regex 'commands/users-*.sh'
check "glob: regex specials are literal" 0 '^a\+b\{c\}\(d\)$' glob_to_regex 'a+b{c}(d)'

# --- derive_labels: pure matching over parsed rows ---------------------------

cfg="scope:release-flow${TAB}lib/**
scope:release-flow${TAB}VERSION
scope:docs${TAB}docs/**
scope:docs${TAB}README"

check "derive: ** matches nested paths" 0 "scope:release-flow" \
  derive_labels "$cfg" 'lib/deep/facts.sh'
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "derive: ** does not match the bare directory" 1 "" \
  bash -c 'source "$1"; [ -n "$(derive_labels "$2" lib)" ]' _ \
  "$ROOT/actions/labels-scope/labels-scope.sh" "$cfg"
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "derive: literal glob does not match a nested twin" 1 "" \
  bash -c 'source "$1"; [ -n "$(derive_labels "$2" docs2/README)" ]' _ \
  "$ROOT/actions/labels-scope/labels-scope.sh" "$cfg"
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "derive: one label per line, config order, deduped" 0 "" \
  bash -c 'source "$1"; got="$(derive_labels "$2" "$(printf "%s\n" README VERSION lib/x docs/a.md)")"
    [ "$got" = "$(printf "%s\n" scope:release-flow scope:docs)" ] || { printf "%s\n" "$got"; exit 1; }' _ \
  "$ROOT/actions/labels-scope/labels-scope.sh" "$cfg"
check "derive: no files derives nothing" 0 "" derive_labels "$cfg" ""
check "derive: unmatched files derive nothing" 0 "" derive_labels "$cfg" 'src/other.c'

# --- the pipe-capacity race: the file list is fed from a variable ------------
#
# `grep -qE` exits at the first matching path, so a piped file list leaves
# printf writing the rest, EPIPE, and `pipefail` fails the pipeline although
# grep MATCHED — inside this per-glob loop, a scope label silently not
# applied (#364, #411).
#
# The case is built so both directions are visible at once: `lib/**` matches
# the FIRST path, which is what makes the reader exit early with a MiB still
# unwritten, while `docs/**` matches the LAST, where grep consumes the whole
# list and no race is possible. Pre-#411 the derived set is the second label
# alone — the first is the one the race eats.
#
# Two properties keep it from being vacuous: `set -euo pipefail`, which is
# what labels-scope.sh arms when it is EXECUTED (sourcing takes the `set -u`
# branch, so a fixture that did not arm it could not fail for the reason the
# bug exists); and the size, since whether a pipe fills is a property of the
# pipe's capacity and not of the data — a MiB clears any capacity a pipe can
# be given (#411 D3).
# shellcheck disable=SC2016 # expansion belongs to the nested bash
check "derive: a MiB-long file list keeps the label whose glob matches its first path" 0 "" \
  bash -c 'source "$1"
    set -euo pipefail
    want="$2" cfg="$3"
    filler="src/vendor/generated/nothing-here-matches-a-glob/module.c
"
    while [ "${#filler}" -lt "$want" ]; do filler="$filler$filler"; done
    files="lib/early.sh
${filler}docs/late.md"
    got="$(derive_labels "$cfg" "$files")"
    [ "$got" = "$(printf "%s\n" scope:release-flow scope:docs)" ] || {
      printf "input %s bytes; derived set was:\n%s\n" "${#files}" "$got"
      exit 1
    }' _ "$ROOT/actions/labels-scope/labels-scope.sh" "$((1024 * 1024))" "$cfg"

# --- parse_labeler_config: every spelling the governed repos use -------------
# Needs yq (preinstalled on ubuntu-latest). Locally, skip with a notice so
# the suite stays runnable in minimal environments; in CI the skip is a
# failure — ci.yml sets CEREMONY_REQUIRE_YQ so these cases can never
# quietly stop running there.

if command -v yq >/dev/null 2>&1; then
  parses() { parse_labeler_config <"$1"; }

  # block sequences + block glob list (ceremony's own spelling)
  cat >"$TMP/block.yml" <<'EOF'
# a comment, as ceremony's own file carries
scope:labels:
  - changed-files:
      - any-glob-to-any-file:
          - .github/workflows/labels.yml
          - actions/labels-reconcile/**
EOF
  check "parse: block style" 0 \
    "scope:labels${TAB}actions/labels-reconcile/**" parses "$TMP/block.yml"

  # quoted keys + flow glob list (box/rig's spelling)
  cat >"$TMP/flow.yml" <<'EOF'
"scope:cli":
  - changed-files:
      - any-glob-to-any-file: ["bin/**", "test/cli.sh"]
EOF
  check "parse: quoted key, flow list" 0 \
    "scope:cli${TAB}bin/**" parses "$TMP/flow.yml"

  # flow map inside changed-files (incubator's spelling)
  cat >"$TMP/flowmap.yml" <<'EOF'
"scope:core":
  - changed-files: [{any-glob-to-any-file: ["apps/core/**"]}]
EOF
  check "parse: flow map entry" 0 \
    "scope:core${TAB}apps/core/**" parses "$TMP/flowmap.yml"

  # a single glob as a bare string
  cat >"$TMP/single.yml" <<'EOF'
scope:docs:
  - changed-files:
      - any-glob-to-any-file: docs/**
EOF
  check "parse: bare-string glob" 0 \
    "scope:docs${TAB}docs/**" parses "$TMP/single.yml"

  # the repo's real mapping parses, and rows keep config order
  check "parse: ceremony's own labeler.yml" 0 \
    "scope:labels${TAB}.github/labeler.yml" parses "$ROOT/.github/labeler.yml"

  # the real mapping covers this implementation's own surface (#133 round):
  # a PR touching only labels-scope must still derive scope:labels, like
  # the neighboring labels-reconcile rows already did
  real_rows="$(parses "$ROOT/.github/labeler.yml")"
  check "derive: the real mapping labels a labels-scope-only change" 0 \
    "scope:labels" derive_labels "$real_rows" 'actions/labels-scope/labels-scope.sh'
  check "derive: the real mapping labels this test file" 0 \
    "scope:labels" derive_labels "$real_rows" 'test/labels-scope.test.sh'

  # --- the real mapping locates: one file set in, the whole label set out ---
  # #267 measured the old map at 100% recall / 15% precision — 20 of the last
  # 20 PRs wore scope:release-flow and 3 touched a release surface — so these
  # cases assert the DERIVED SET WHOLE, brackets and all. A substring check
  # cannot tell scope:labels from scope:labels plus a wrong second label, and
  # a wrong second label is the whole defect.
  derives() { # <newline-separated paths> → "[label,label]" for the real map
    printf '[%s]\n' "$(derive_labels "$real_rows" "$1" | paste -sd, -)"
  }
  files() { printf '%s\n' "$@"; }

  # D1: a fragment is written by every behavior change (BUILDER.md), so it
  # carries no locating information. Asserted as an empty set on its own, not
  # as an absence inside a longer list: this is the case that fails first if
  # the glob is ever restored.
  check "derive: a fragment-only path derives nothing at all" 0 \
    "[]" derives 'changelog.d/999.md'

  # D2: the issue-flow sweep is a reconciler of the label taxonomy
  check "derive: the issueflow reconciler is scope:labels" 0 \
    "[scope:labels]" derives 'actions/issueflow-reconcile/issueflow-reconcile.sh'
  check "derive: the issueflow reconciler's test is scope:labels" 0 \
    "[scope:labels]" derives 'test/issueflow-reconcile.test.sh'

  # the reported bug, replayed: #261's exact file set wore scope:release-flow,
  # inherited from its fragment, pointing at the one surface it does not touch
  check "derive: #261's file set is scope:labels alone" 0 "[scope:labels]" \
    derives "$(files actions/issueflow-reconcile/issueflow-reconcile.sh \
      changelog.d/252.md test/issueflow-reconcile.test.sh)"

  # D1's cost, checked rather than assumed: dropping the fragment glob must
  # not cost the release surface its label
  check "derive: a release PR is still scope:release-flow" 0 \
    "[scope:release-flow]" \
    derives "$(files VERSION CHANGELOG.md drills/0.6.0.md changelog.d/236.md)"

  # D3: the docs block matched a literal README this tree does not have
  check "derive: README.md is scope:docs" 0 "[scope:docs]" derives 'README.md'
  check "derive: FLEET.md is scope:docs" 0 "[scope:docs]" derives 'FLEET.md'
  check "derive: RELEASES.md is scope:docs" 0 "[scope:docs]" derives 'RELEASES.md'
  check "derive: TRIAGE.md is scope:docs" 0 "[scope:docs]" derives 'TRIAGE.md'

  # D3: three guard actions and their tests were in no block at all. Each of
  # the six paths is asserted ALONE, never bundled with its sibling: a set
  # holding both the action and its test derives scope:guards when either row
  # matches, so one row could be deleted with the case still green — the six
  # rows have to be six assertions to be six protections (#300 round).
  for guard in changelog-assembled docs-sync runner-isolated; do
    check "derive: actions/$guard is scope:guards" 0 "[scope:guards]" \
      derives "actions/$guard/$guard.sh"
    check "derive: $guard's test is scope:guards" 0 "[scope:guards]" \
      derives "test/$guard.test.sh"
  done

  # #399 adds a guard and its contract test as two independent surfaces.
  # Keep whole-set assertions so either a missing row or a wrong extra scope
  # is red, and keep the paths separate so one row cannot mask the other.
  check "derive: actions/sha-pinned is scope:guards" 0 "[scope:guards]" \
    derives 'actions/sha-pinned/sha-pinned.sh'
  check "derive: sha-pinned's test is scope:guards" 0 "[scope:guards]" \
    derives 'test/sha-pinned.test.sh'

  # D4: lib/ is genuinely mixed, so the shared files wear both labels rather
  # than lib/** being re-carved into a row per file
  check "derive: lib/ruling.sh is release-flow AND labels" 0 \
    "[scope:release-flow,scope:labels]" derives 'lib/ruling.sh'
  check "derive: lib/read.sh is release-flow AND labels" 0 \
    "[scope:release-flow,scope:labels]" derives 'lib/read.sh'
  check "derive: lib/version.sh is release-flow only" 0 \
    "[scope:release-flow]" derives 'lib/version.sh'

  # D6: the map stays advisory. An unmapped path derives an empty set and
  # exits 0 — a guard that redded here would fail every PR touching ci.yml,
  # which this map does not claim.
  check "derive: an unmapped path is silence, not an error" 0 "[]" \
    derives '.github/workflows/ci.yml'

  # --- #302: one wrong answer and the surfaces the map never learned ------
  # Every path asserted ALONE, per #300 round 1: a set holding a script and
  # its test derives the scope when either row matches, so bundling would
  # let a row be deleted with the case still green.

  # D1, the reported bug replayed: both reconcilers source lib/attention.sh,
  # nothing release-side does — [scope:release-flow] alone was a wrong
  # answer, and the honest set is both, same as its two shelf-mates
  check "derive: lib/attention.sh is release-flow AND labels" 0 \
    "[scope:release-flow,scope:labels]" derives 'lib/attention.sh'

  # D2: the sweep half of the automation, detached from the trigger half in
  # #209 — cadence, permissions and job wiring must locate
  check "derive: the labels sweep workflow is scope:labels" 0 \
    "[scope:labels]" derives '.github/workflows/labels-sweep.yml'
  check "derive: the self sweep workflow is scope:labels" 0 \
    "[scope:labels]" derives '.github/workflows/self-labels-sweep.yml'

  # #424 D8: the rerun servicing. `.github/labeler.yml` enumerates every
  # action by name and has no `actions/**` catch-all, so an unmapped action
  # means a PR touching only it derives NO scope at all — the board lying by
  # omission, which is the gap #399 hit. Four paths, four assertions, each
  # ALONE in bracket form for #300 round 1's reason: a set holding several
  # would let a row be deleted with the case still green.
  check "derive: the rerun servicing action is scope:labels" 0 \
    "[scope:labels]" derives 'actions/ci-rerun/ci-rerun.sh'
  check "derive: the rerun servicing reusable workflow is scope:labels" 0 \
    "[scope:labels]" derives '.github/workflows/ci-rerun.yml'
  check "derive: the rerun servicing caller is scope:labels" 0 \
    "[scope:labels]" derives '.github/workflows/self-ci-rerun.yml'
  check "derive: the rerun servicing test is scope:labels" 0 \
    "[scope:labels]" derives 'test/ci-rerun.test.sh'

  # D3, the deliberate asymmetry with D1: a test file inherits no lib/**
  # glob, so its row is the one scope its subject actually locates
  check "derive: attention's test is scope:labels alone" 0 \
    "[scope:labels]" derives 'test/attention.test.sh'
  check "derive: ruling's test is scope:labels alone" 0 \
    "[scope:labels]" derives 'test/ruling.test.sh'

  # D4: the same read's remaining gaps, one row each
  check "derive: the trigger-surface pins are scope:labels" 0 \
    "[scope:labels]" derives 'test/labels-triggers.test.sh'
  check "derive: the assemble test is scope:release-flow" 0 \
    "[scope:release-flow]" derives 'test/changelog-assemble.test.sh'
  check "derive: the release-path manifest is scope:release-flow" 0 \
    "[scope:release-flow]" derives '.github/scripts/release-path.sh'
  check "derive: the release-path test is scope:release-flow" 0 \
    "[scope:release-flow]" derives 'test/release-path.test.sh'
  check "derive: the marker-check guard is scope:guards" 0 \
    "[scope:guards]" derives '.github/scripts/marker-check.sh'
  check "derive: the marker-check test is scope:guards" 0 \
    "[scope:guards]" derives 'test/marker-check.test.sh'
  check "derive: the vendored-check guard is scope:guards" 0 \
    "[scope:guards]" derives '.github/scripts/vendored-check.sh'
  check "derive: the vendored test is scope:guards" 0 \
    "[scope:guards]" derives 'test/vendored.test.sh'

  # #484 D10: the drill instrument. `drills/**` — the record — was mapped from
  # the start while `drill/` — what writes it — was named nowhere, so the
  # instrument and its guard derived NO scope at all: a wrong answer, the class
  # #476 is the precedent for, not a gap. One case per file, because a single
  # bundled case would pass on any one row matching.
  check "derive: the drill instrument is scope:release-flow" 0 \
    "[scope:release-flow]" derives 'drill/rehearsal.sh'
  check "derive: the drill libs are scope:release-flow too" 0 \
    "[scope:release-flow]" derives 'drill/lib/record.sh'
  check "derive: the drill suite is scope:release-flow" 0 \
    "[scope:release-flow]" derives 'test/drill-rehearsal.test.sh'
  check "derive: the round-trip guard is scope:release-flow" 0 \
    "[scope:release-flow]" derives '.github/scripts/record-roundtrip.sh'

  # D7: no test/** or .github/scripts/** catch-all — both directories span
  # all four scopes, so this pair reds under any catch-all row: each file
  # would gain the other's scope beside its own
  check "derive: test/version.test.sh is release-flow alone" 0 \
    "[scope:release-flow]" derives 'test/version.test.sh'
  check "derive: this test file is scope:labels alone" 0 \
    "[scope:labels]" derives 'test/labels-scope.test.sh'

  # refusals: unsupported shapes fail loudly, naming the label
  cat >"$TMP/allglobs.yml" <<'EOF'
scope:x:
  - changed-files:
      - all-globs-to-all-files: ["a/**"]
EOF
  check "parse: all-globs-to-all-files is refused" 5 \
    "scope:x: unsupported matcher(s) all-globs-to-all-files" parses "$TMP/allglobs.yml"

  cat >"$TMP/branch.yml" <<'EOF'
scope:x:
  - head-branch: ["^feature/"]
EOF
  check "parse: branch matchers are refused" 5 \
    "scope:x: unsupported key(s) head-branch" parses "$TMP/branch.yml"

  cat >"$TMP/toplist.yml" <<'EOF'
- scope:x
EOF
  check "parse: non-map top level is refused" 5 \
    "top level must be a map" parses "$TMP/toplist.yml"

  cat >"$TMP/backslash.yml" <<'EOF'
scope:x:
  - changed-files:
      - any-glob-to-any-file: ["a\\b/**"]
EOF
  check "parse: backslash escapes are refused" 5 \
    "backslash in glob" parses "$TMP/backslash.yml"
elif [ -n "${CEREMONY_REQUIRE_YQ:-}" ]; then
  echo "FAIL: CEREMONY_REQUIRE_YQ is set but yq is missing — the config parse cases did not run"
  FAIL=$((FAIL + 1))
else
  echo "SKIP: yq not found — parse_labeler_config cases not exercised"
fi

summary
