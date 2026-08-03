#!/usr/bin/env bash
# Contract tests for .github/scripts/marker-check.sh (issue #238). The guard
# is driven against tracked fixture trees; set -u, not -e, because failures
# are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

CHECK="$ROOT/.github/scripts/marker-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fixture() {
  local name="$1" version="$2"
  mkdir -p "$TMP/$name/docs" "$TMP/$name/changelog.d"
  git -C "$TMP/$name" init -q
  printf '%s\n' "$version" >"$TMP/$name/VERSION"
  printf '# Changelog\n\n## 0.5.0 — 2026-08-03\n\n- Shipped (#221).\n' \
    >"$TMP/$name/CHANGELOG.md"
}

run_check() {
  git -C "$TMP/$1" add .
  bash "$CHECK" "$TMP/$1"
}

fixture wrapped 0.6.0-dev
cat >"$TMP/wrapped/docs/CONSUMERS.md" <<'EOF'
The new guard remains **unreleased**
(#238) until the next tag.
EOF
check "a wrapped local citation is accepted" 0 "agree with the tree" \
  run_check wrapped

fixture uncited 0.6.0-dev
printf 'The new guard remains **unreleased** for now.\n' \
  >"$TMP/uncited/docs/CONSUMERS.md"
check "an uncited marker fails on a dev tree with file and line" 1 \
  "docs/CONSUMERS.md:1" run_check uncited

fixture shipped 0.6.0
printf 'The new guard remains **unreleased** (#224).\n' \
  >"$TMP/shipped/docs/CONSUMERS.md"
cat >"$TMP/shipped/CHANGELOG.md" <<'EOF'
# Changelog

## 0.6.0 — 2026-08-03

- The guard shipped (#224).

## 0.5.0 — 2026-08-02

- Older work (#999).
EOF
check "a release rejects a marker cited by its top section" 1 \
  "docs/CONSUMERS.md:1: **unreleased** (#224)" run_check shipped

fixture not-shipped 0.6.0
printf 'Future work remains **unreleased** (#999).\n' \
  >"$TMP/not-shipped/docs/CONSUMERS.md"
cp "$TMP/shipped/CHANGELOG.md" "$TMP/not-shipped/CHANGELOG.md"
check "a release keeps a marker absent from its top section" 0 \
  "agree with the tree" run_check not-shipped

fixture dev-shipped 0.6.0-dev
printf 'Future work remains **unreleased** (#224).\n' \
  >"$TMP/dev-shipped/docs/CONSUMERS.md"
cp "$TMP/shipped/CHANGELOG.md" "$TMP/dev-shipped/CHANGELOG.md"
check "a dev tree does not compare markers with shipped sections" 0 \
  "agree with the tree" run_check dev-shipped

fixture cross-repo 0.6.0
printf 'Crew work remains **unreleased** (crew#293).\n' \
  >"$TMP/cross-repo/docs/CONSUMERS.md"
cat >"$TMP/cross-repo/CHANGELOG.md" <<'EOF'
# Changelog

## 0.6.0 — 2026-08-03

- Local work shipped (#293).
EOF
check "a cross-repo citation is valid and ignored by release comparison" 0 \
  "agree with the tree" run_check cross-repo

fixture self-qualified 0.6.0
printf 'Ceremony work remains **unreleased** (ceremony#248).\n' \
  >"$TMP/self-qualified/docs/CONSUMERS.md"
cat >"$TMP/self-qualified/CHANGELOG.md" <<'EOF'
# Changelog

## 0.6.0 — 2026-08-03

- Ceremony work shipped (#248).
EOF
check "a self-qualified citation is ignored; local markers must use bare #N" 0 \
  "agree with the tree" run_check self-qualified

fixture exclusions 0.6.0-dev
cat >"$TMP/exclusions/NOTES.md" <<'EOF'
# Notes

## Unreleased

The marker token is `**unreleased**`.
EOF
printf -- '- A fragment may say **unreleased** without being documentation.\n' \
  >"$TMP/exclusions/changelog.d/999.md"
cat >"$TMP/exclusions/CHANGELOG.md" <<'EOF'
# Changelog

## 0.5.0 — 2026-08-03

- Shipped prose may discuss **unreleased** markers without becoming one.
EOF
check "headings, inline mentions, changelog entries, and fragments are excluded" 0 \
  "agree with the tree" run_check exclusions

summary
