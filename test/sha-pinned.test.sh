#!/usr/bin/env bash
# Contract tests for actions/sha-pinned (#399). set -u, not -e: failures are
# the behavior this harness inspects.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/actions/sha-pinned/sha-pinned.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

tree() {
  mkdir -p "$TMP/$1/.github/workflows" "$TMP/$1/.github/actions"
}

run_guard() {
  local name="$1"
  shift
  (cd "$TMP/$name" && env -u GITHUB_REPOSITORY -u FIRST_PARTY_OWNER \
    bash "$SCRIPT" "$@")
}

run_guard_repo() {
  local name="$1" repository="$2"
  (cd "$TMP/$name" && GITHUB_REPOSITORY="$repository" bash "$SCRIPT")
}

tree unpinned
cat >"$TMP/unpinned/.github/workflows/ci.yml" <<'EOF'
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
EOF
check "an unpinned workflow action fails" 1 "ci.yml:4" run_guard unpinned
check "failure names the reference" 1 "actions/checkout@v4" run_guard unpinned
check "failure teaches the full-SHA fix" 1 \
  "@<40-lowercase-hex-commit-sha> # <version>" run_guard unpinned

tree five
for number in 1 2 3 4 5; do
  printf -- '- uses: vendor/action@v%s\n' "$number" \
    >"$TMP/five/.github/workflows/$number.yml"
done
check "all five findings are reported" 1 \
  "sha-pinned: 5 unpinned third-party reference(s)" run_guard five

tree comments
cat >"$TMP/comments/.github/workflows/ci.yml" <<'EOF'
steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
EOF
check "a full SHA without a comment fails" 1 "ci.yml:2" run_guard comments
cat >"$TMP/comments/.github/workflows/ci.yml" <<'EOF'
steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
EOF
check "a full SHA with a version comment passes" 0 "every third-party reference is pinned" \
  run_guard comments

for shape in \
  11d5960a326750d5838078e36cf38b85af67726 \
  11D5960A326750D5838078E36CF38B85AF677262; do
  printf 'steps:\n  - uses: actions/checkout@%s # nearly\n' "$shape" \
    >"$TMP/comments/.github/workflows/ci.yml"
  check "near pin $shape fails" 1 "ci.yml:2" run_guard comments
done

tree exemptions
cat >"$TMP/exemptions/.github/workflows/ci.yml" <<'EOF'
permissions:
  statuses: read
steps:
  - uses: ./actions/local
  - uses: heavy-duty/ceremony/actions/runner-isolated@0.7.1
EOF
check "local and repository-owner references pass" 0 "every third-party reference is pinned" \
  run_guard_repo exemptions heavy-duty/ceremony
check "first-party owner input overrides repository ownership" 0 \
  "every third-party reference is pinned" run_guard exemptions \
  .github/workflows .github/actions heavy-duty
check "a first-party tag fails closed without owner context" 1 \
  "heavy-duty/ceremony/actions/runner-isolated@0.7.1" run_guard exemptions

tree reusable
cat >"$TMP/reusable/.github/workflows/call.yml" <<'EOF'
jobs:
  call:
    uses: vendor/project/.github/workflows/ci.yml@v2
EOF
check "a tagged reusable workflow fails" 1 "workflows/ci.yml@v2" run_guard reusable
cat >"$TMP/reusable/.github/workflows/call.yml" <<'EOF'
jobs:
  call:
    uses: vendor/project/.github/workflows/ci.yml@0123456789abcdef0123456789abcdef01234567 # v2
EOF
check "a pinned reusable workflow passes" 0 "every third-party reference is pinned" \
  run_guard reusable

tree composite
mkdir -p "$TMP/composite/.github/actions/one"
cat >"$TMP/composite/.github/actions/one/action.yml" <<'EOF'
runs:
  using: composite
  steps:
    - uses: vendor/action@v1
EOF
check "a one-level composite action is scanned" 1 "action.yml:4" run_guard composite

mkdir -p "$TMP/missing"
check "both missing default directories pass" 0 "0 file(s) checked" run_guard missing

tree nested
mkdir -p "$TMP/nested/.github/workflows/fixtures/x"
cat >"$TMP/nested/.github/workflows/fixtures/x/bad.yml" <<'EOF'
steps:
  - uses: vendor/action@v1
EOF
check "nested workflow fixture trees are not scanned" 0 "every third-party reference is pinned" \
  run_guard nested

tree docker
cat >"$TMP/docker/.github/workflows/ci.yml" <<'EOF'
steps:
  - uses: docker://alpine:3.22
EOF
check "docker references are an explicit gap and pass" 0 \
  "every third-party reference is pinned" run_guard docker

summary
