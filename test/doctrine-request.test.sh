#!/usr/bin/env bash
# Contract tests for the doctrine-change return path (issue #492).
#
# The subject is prose, which is unusual here and is the point: the defect
# #492 fixes was that a route existed nowhere, and the generated
# `.ceremony/README.md` promised a flow — "through its own flow" — that was
# never named. Prose is what a consumer's agent reads, so prose is what has
# to be asserted.
#
# Every reader below takes a TREE ROOT rather than reading this repo
# directly, so no row can pass vacuously: the rows run against the real tree,
# and beside each one the same reader runs against a COPY carrying the
# failure the issue's test plan names — the route stripped out, a sixth
# outcome, an added template, a consumer register. That is vendored.test.sh's
# real_copy pattern: a verdict on the actual doc set, proven by mutation,
# without touching the working tree.
#
# Nothing here is wired into CI as a guard: #492 D8 keeps the machine-read
# surface unchanged, so the logic lives in this file and runs with the suite.
#
# The README rows drive the SHIPPED docs-sync.sh into a fixture consumer
# rather than re-deriving its text: what a consumer receives is the
# assertion, not what this file thinks the script generates. --source keeps
# it offline.
#
# set -u, not -e: failing commands are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- readers, each taking a tree root ------------------------------------------

# section <tree> <file> <heading> — the named '## ' section's body, up to the
# next '## ' heading or EOF. Bounding every prose assertion to the section it
# is about is what stops a row passing on an unrelated part of the file.
section() {
  awk -v want="$3" '
    /^## / { inside = ($0 == want); next }
    inside { print }
  ' "$1/$2"
}

# prose <tree> <file> <heading> — a section with its line wrapping removed.
# Every phrase assertion below reads through this: doctrine here is hard
# wrapped, so a grep for a sentence fragment fails on where the line broke
# rather than on what the text says, which is a false red waiting to happen
# the next time somebody reflows a paragraph (#492).
prose() {
  section "$1" "$2" "$3" | tr '\n' ' ' | tr -s ' '
}

# outcomes <tree> — TRIAGE.md's numbered outcome names, on one line, prefixed
# with the count and bracketed. The harness matches substrings, so the five
# names alone would still be found inside a list of six; the count and the
# brackets are what make "unchanged in number and wording" checkable (#492).
outcomes() {
  local heading names count
  heading='## For each discussion, converge on exactly one outcome'
  names="$(
    section "$1" TRIAGE.md "$heading" |
      grep -oE '^[0-9]+\. \*\*[A-Za-z]+\.\*\*' | tr -d '*.' | tr '\n' ' '
  )"
  # Items, not words: the names below are one word each today, and a count
  # derived from that would go quietly wrong the day one is two words.
  count="$(section "$1" TRIAGE.md "$heading" | grep -cE '^[0-9]+\. \*\*[A-Za-z]+\.\*\*')"
  printf '[%s|%s]\n' "$count" "${names% }"
}

# routing_rule <tree> — TRIAGE.md's text after the numbered outcomes and
# before the issue contract: where D4's routing rule lives, and the only part
# of that file this issue adds to.
routing_rule() {
  awk '
    /^## The issue contract/ { exit }
    /^5\. \*\*Accept\.\*\*/ { after = 1; next }
    after { print }
  ' "$1/TRIAGE.md" | tr '\n' ' ' | tr -s ' '
}

# ask_shape <tree> — how many numbered parts the ask has, and how many of
# them justify themselves rather than being asserted. A part is justified
# when its own text says "because"; continuation lines belong to the part
# above them, and the first unindented non-item line ends the list (D2).
ask_shape() {
  section "$1" docs/CONSUMERS.md '## Requesting a doctrine change' | awk '
    /^[0-9]+\. \*\*/ { n++; cur = n }
    /^[^ \t]/ && !/^[0-9]+\. \*\*/ { cur = 0 }
    cur && /because/ { justified[cur] = 1 }
    END {
      for (i = 1; i <= n; i++) if (justified[i]) j++
      printf "[%d parts %d justified]\n", n, j + 0
    }
  '
}

# generated_readme <tree> — the .ceremony/README.md a consumer actually
# receives, produced by running that tree's docs-sync against that tree.
generated_readme() {
  local dir="$TMP/consumer"
  rm -rf "$dir"
  mkdir -p "$dir/.github/workflows"
  printf 'name: release\non:\n  push:\n    branches: [main]\njobs:\n  release:\n    uses: heavy-duty/ceremony/.github/workflows/release.yml@0.7.5\n' \
    >"$dir/.github/workflows/release.yml"
  (cd "$dir" && bash "$1/actions/docs-sync/docs-sync.sh" --fix --source "$1" >/dev/null 2>&1)
  # Wrap-collapsed for the same reason `prose` is: every row below asserts a
  # phrase, and the generated text is hard wrapped.
  tr '\n' ' ' <"$dir/.ceremony/README.md" | tr -s ' '
}

# templates <tree> — the discussion form set, bracketed for the reason the
# outcome list is: an ADDED template must not pass as a superset (D6).
templates() {
  local names
  names="$(
    find "$1/.github/DISCUSSION_TEMPLATE" -maxdepth 1 -type f -exec basename {} \; |
      LC_ALL=C sort | tr '\n' ' '
  )"
  printf '[%s]\n' "${names% }"
}

# foreign_repos <tree> — every heavy-duty repository named in the two regions
# this issue adds to. "Learns nothing about its consumers" is checkable
# exactly here: the only name that may appear is this repository's own.
foreign_repos() {
  local names
  names="$(
    {
      section "$1" docs/CONSUMERS.md '## Requesting a doctrine change'
      routing_rule "$1"
    } | grep -oE 'heavy-duty/[a-z][a-z0-9-]*' | LC_ALL=C sort -u | tr '\n' ' '
  )"
  printf '[%s]\n' "${names% }"
}

# cross_repo_cites <tree> — 'repo#N' and 'owner/repo#N' forms inside the
# routing rule. #280 forbids them in vendored normative text and TRIAGE.md is
# vendored; the rest of that file is not this issue's to police. A bare '(#N)'
# cannot match: the pattern needs a name character immediately before the '#'.
cross_repo_cites() {
  local hits
  hits="$(routing_rule "$1" | grep -oE '[A-Za-z0-9_.-]+#[0-9]+' | tr '\n' ' ')"
  printf '[%s]\n' "${hits% }"
}

# --- mutated copies: each carries one failure the test plan names -------------

# copy <name> — the doc surface these readers touch, mutable. Echoes the path.
copy() {
  local dir="$TMP/$1"
  rm -rf "$dir"
  mkdir -p "$dir/docs" "$dir/actions/docs-sync" "$dir/.github/DISCUSSION_TEMPLATE"
  cp "$ROOT"/*.md "$dir/"
  cp "$ROOT/docs/VENDORED.txt" "$ROOT/docs/CONSUMERS.md" "$dir/docs/"
  cp "$ROOT/actions/docs-sync/docs-sync.sh" "$dir/actions/docs-sync/"
  cp "$ROOT/.github/DISCUSSION_TEMPLATE"/* "$dir/.github/DISCUSSION_TEMPLATE/"
  printf '%s\n' "$dir"
}

# The defect this issue closes: the route absent from all three surfaces, the
# marker left promising a flow it does not name.
STRIPPED="$(copy stripped)"
awk '
  /^## Requesting a doctrine change/ { skip = 1 }
  /^## Version pinning/ { skip = 0 }
  !skip
' "$ROOT/docs/CONSUMERS.md" >"$STRIPPED/docs/CONSUMERS.md"
awk '
  /^\*\*Where the vendored set is what blocks you/ { skip = 1 }
  /^## The issue contract/ { skip = 0 }
  !skip
' "$ROOT/TRIAGE.md" >"$STRIPPED/TRIAGE.md"
sed -e '/Requesting a doctrine change/d' \
  -e '\|github\.com/heavy-duty/ceremony/discussions|d' \
  "$ROOT/actions/docs-sync/docs-sync.sh" >"$STRIPPED/actions/docs-sync/docs-sync.sh"

# A sixth outcome, rather than a routing rule beside the five.
SIXTH="$(copy sixth)"
awk '
  { print }
  /^5\. \*\*Accept\.\*\* It justifies work/ && !added {
    print "6. **Route.** The vendored set is what blocks you \xe2\x86\x92 raise it upstream."
    added = 1
  }
' "$ROOT/TRIAGE.md" >"$SIXTH/TRIAGE.md"

# A template at the door, overturning #24 D4 by accident.
TEMPLATED="$(copy templated)"
printf 'body:\n  - type: input\n' >"$TEMPLATED/.github/DISCUSSION_TEMPLATE/doctrine-change.yml"

# A consumer register: the added text naming a consumer repository.
REGISTER="$(copy register)"
sed 's|^\*\*The address is a discussion here\*\*|**The address is a discussion here**, as heavy-duty/box does|' \
  "$ROOT/docs/CONSUMERS.md" >"$REGISTER/docs/CONSUMERS.md"

# --- D7: the flow is reachable from where the reader is standing ---------------
# A route documented only in docs/CONSUMERS.md is the same failure one level
# up: a consumer's agent reads .ceremony/, not this repository's docs/.

check "generated README names the flow" 0 "Requesting a doctrine change" \
  generated_readme "$ROOT"
check "generated README links the flow absolutely — one hop, no layout knowledge" 0 \
  "https://github.com/heavy-duty/ceremony/blob/main/docs/CONSUMERS.md#requesting-a-doctrine-change" \
  generated_readme "$ROOT"
check "generated README names the door that flow enters by" 0 \
  "https://github.com/heavy-duty/ceremony/discussions" \
  generated_readme "$ROOT"
check "generated README says a rule here can itself be the blocker" 0 \
  "is what is blocking you" generated_readme "$ROOT"
check "generated README still marks the mirror machine-managed" 0 "achine-managed" \
  generated_readme "$ROOT"
check "generated README still names where the pin lives" 0 \
  ".github/workflows/release.yml" generated_readme "$ROOT"

check_absent "without #492 the marker names no flow" 0 \
  "Requesting a doctrine change" generated_readme "$STRIPPED"
check_absent "without #492 the marker names no door" 0 \
  "https://github.com/heavy-duty/ceremony/discussions" generated_readme "$STRIPPED"

# --- D1/D2/D3/D5/D6: the section answers the outbound question -----------------

check "the address is one door, and it is discussions (D1)" 0 \
  "https://github.com/heavy-duty/ceremony/discussions" \
  prose "$ROOT" docs/CONSUMERS.md '## Requesting a doctrine change'
check "the ask has four parts, each justified rather than asserted (D2)" 0 \
  "[4 parts 4 justified]" ask_shape "$ROOT"
check "the citation obligation lands in the consumer's own body (D3)" 0 \
  "names the upstream discussion or issue" \
  prose "$ROOT" docs/CONSUMERS.md '## Requesting a doctrine change'
check "the return path is the pin bump, and neither side polls (D5)" 0 \
  "neither side polls" \
  prose "$ROOT" docs/CONSUMERS.md '## Requesting a doctrine change'
check "a partial ask is still triaged (D6)" 0 "three of the four" \
  prose "$ROOT" docs/CONSUMERS.md '## Requesting a doctrine change'

check_absent "without #492 CONSUMERS.md answers nothing outbound" 0 \
  "neither side polls" \
  prose "$STRIPPED" docs/CONSUMERS.md '## Requesting a doctrine change'
check "without #492 the ask has no parts at all" 0 "[0 parts 0 justified]" \
  ask_shape "$STRIPPED"

# --- D4: a routing rule beside the five outcomes, never a sixth ----------------

check "TRIAGE.md's five outcomes are unchanged in number and wording" 0 \
  "[5|1 Answer 2 Ask 3 Escalate 4 Decline 5 Accept]" outcomes "$ROOT"
check_absent "a sixth outcome does not pass as the five" 0 \
  "[5|1 Answer 2 Ask 3 Escalate 4 Decline 5 Accept]" outcomes "$SIXTH"
check "the sixth-outcome tree is the failure it claims to be" 0 "6 Route" \
  outcomes "$SIXTH"

check "the routing rule says it is not a sixth outcome" 0 "not a sixth outcome" \
  routing_rule "$ROOT"
check "the routing rule routes the vendored-set half upstream" 0 \
  "the repository the vendored set is mirrored from" routing_rule "$ROOT"
check "the routing rule points at the marker carrying the address" 0 \
  ".ceremony/README.md" routing_rule "$ROOT"
check "the routing rule keeps the local half local — decidable both ways" 0 \
  "is one of the five above" routing_rule "$ROOT"
check "the routing rule carries the consumer-side citation (D3)" 0 \
  "cite that discussion" routing_rule "$ROOT"

check_absent "without #492 TRIAGE.md routes nothing upstream" 0 \
  "not a sixth outcome" routing_rule "$STRIPPED"

# --- D6: no template is added -------------------------------------------------

check "the discussion forms are exactly the two that already existed" 0 \
  "[ideas.yml q-a.yml]" templates "$ROOT"
check_absent "an added template does not pass as those two" 0 \
  "[ideas.yml q-a.yml]" templates "$TEMPLATED"

# --- D8 and the #486 constraint: this repo learns nothing about consumers ------

check "the added text names no repository but this one" 0 \
  "[heavy-duty/ceremony]" foreign_repos "$ROOT"
check_absent "a consumer register does not pass that row" 0 \
  "[heavy-duty/ceremony]" foreign_repos "$REGISTER"
check "the register tree is the failure it claims to be" 0 "heavy-duty/box" \
  foreign_repos "$REGISTER"

# --- #280: vendored normative text cites bare and same-repo -------------------

check "the routing rule carries no cross-repo citation" 0 "[]" \
  cross_repo_cites "$ROOT"
check "the routing rule cites its record" 0 "(#492)" routing_rule "$ROOT"

summary
