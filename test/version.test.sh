#!/usr/bin/env bash
# Contract tests for lib/version.sh (issue #3). set -u, not -e: failing
# commands are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"
# shellcheck source=lib/version.sh
. "$ROOT/lib/version.sh"

FIXTURES="$ROOT/test/fixtures/version"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# eq <want> <cmd...> — exit 0 iff the command succeeds AND prints exactly
# <want>; check()'s substring match alone can't prove whitespace was
# stripped ("  1.2.3" contains "1.2.3").
eq() {
  local want="$1" got
  shift
  got="$("$@")" || return 1
  [ "$got" = "$want" ]
}

# file_is <path> <ver> — the file holds exactly "<ver>\n", nothing else.
file_is() {
  printf '%s\n' "$2" | cmp -s - "$1"
}

# lock_carries <dir> <ver> — package-lock.json embeds the version twice
# (top level and packages[""]); both must agree after a write.
lock_carries() {
  node -e '
    const l = require(require("path").resolve(process.argv[1]));
    if (l.version !== process.argv[2] || l.packages[""].version !== process.argv[2]) {
      console.error("lockfile version mismatch: " + JSON.stringify([l.version, l.packages[""].version]));
      process.exit(1);
    }
  ' "$1/package-lock.json" "$2"
}

# --- version_read, file backend ---------------------------------------------

mkdir -p "$TMP/plain"
printf '1.2.3\n' >"$TMP/plain/VERSION"
check "file: read happy path" 0 "" eq "1.2.3" version_read file "$TMP/plain"

mkdir -p "$TMP/padded"
printf '  1.2.3  \n\n' >"$TMP/padded/VERSION"
check "file: surrounding whitespace and trailing newlines stripped" 0 "" \
  eq "1.2.3" version_read file "$TMP/padded"

mkdir -p "$TMP/absent"
check "file: missing VERSION fails" 1 "no such file" version_read file "$TMP/absent"

mkdir -p "$TMP/blank"
printf '\n  \n' >"$TMP/blank/VERSION"
check "file: whitespace-only VERSION fails" 1 "empty" version_read file "$TMP/blank"

# --- version_read, package-json backend -------------------------------------

check "package-json: read happy path from fixture" 0 "" \
  eq "0.1.0" version_read package-json "$FIXTURES/pkg"

mkdir -p "$TMP/nopkg"
check "package-json: missing package.json fails" 1 "no such file" \
  version_read package-json "$TMP/nopkg"

mkdir -p "$TMP/noversion"
printf '{ "name": "no-version-here" }\n' >"$TMP/noversion/package.json"
check "package-json: absent version field fails" 1 "no version field" \
  version_read package-json "$TMP/noversion"

check "read: unknown backend refused" 1 "unknown backend" version_read carrier-pigeon

# --- version_is_dev ----------------------------------------------------------

check "is_dev: 1.2.3-dev yes" 0 "" version_is_dev 1.2.3-dev
check "is_dev: 0.7.0-rc2-dev yes" 0 "" version_is_dev 0.7.0-rc2-dev
check "is_dev: 1.2.3 no" 1 "" version_is_dev 1.2.3
check "is_dev: 1.2.3-rc1 no" 1 "" version_is_dev 1.2.3-rc1

# --- version_is_rc -----------------------------------------------------------

check "is_rc: 1.2.3-rc1 yes" 0 "" version_is_rc 1.2.3-rc1
check "is_rc: 1.2.3-rc10 yes" 0 "" version_is_rc 1.2.3-rc10
check "is_rc: 1.2.3-rc2-dev no" 1 "" version_is_rc 1.2.3-rc2-dev
check "is_rc: 1.2.3-rc no" 1 "" version_is_rc 1.2.3-rc
check "is_rc: 1.2.3 no" 1 "" version_is_rc 1.2.3
check "is_rc: 1.2.3-dev no" 1 "" version_is_rc 1.2.3-dev
check "is_rc: 1.2.3-alpha1 no" 1 "" version_is_rc 1.2.3-alpha1

# --- version_next_dev --------------------------------------------------------

check "next_dev: 1.2.3 -> 1.2.4-dev" 0 "" eq "1.2.4-dev" version_next_dev 1.2.3
check "next_dev: 0.9.0 -> 0.9.1-dev" 0 "" eq "0.9.1-dev" version_next_dev 0.9.0
check "next_dev: 0.9.9 -> 0.9.10-dev (no decimal snapping)" 0 "" \
  eq "0.9.10-dev" version_next_dev 0.9.9
check "next_dev: 1.2.3-rc1 -> 1.2.3-rc2-dev" 0 "" \
  eq "1.2.3-rc2-dev" version_next_dev 1.2.3-rc1
check "next_dev: 1.2.3-rc9 -> 1.2.3-rc10-dev" 0 "" \
  eq "1.2.3-rc10-dev" version_next_dev 1.2.3-rc9
check "next_dev: 1.2.3-rc09 -> 1.2.3-rc10-dev (base 10)" 0 "" \
  eq "1.2.3-rc10-dev" version_next_dev 1.2.3-rc09
check "next_dev: -dev input refused and named" 1 "1.2.3-dev" \
  version_next_dev 1.2.3-dev
check "next_dev: malformed rc input refused and named" 1 "1.2.3-rc" \
  version_next_dev 1.2.3-rc
check "next_dev: non-rc identifier refused and named" 1 "1.2.3-alpha1" \
  version_next_dev 1.2.3-alpha1
check "next_dev: garbage refused and named" 1 "garbage" version_next_dev garbage

# --- version_write, file backend ---------------------------------------------

mkdir -p "$TMP/write-file"
check "write file: succeeds" 0 "" version_write file 2.0.0 "$TMP/write-file"
check "write file: file is exactly ver + newline" 0 "" \
  file_is "$TMP/write-file/VERSION" 2.0.0

check "write: unknown backend refused" 1 "unknown backend" \
  version_write carrier-pigeon 2.0.0

# --- version_write, package-json backend -------------------------------------
# Needs npm. Locally, skip with a notice so the suite stays runnable in
# minimal environments; in CI the skip is a failure — ci.yml sets
# CEREMONY_REQUIRE_NPM so this case can never quietly stop running there.

if command -v npm >/dev/null 2>&1; then
  cp -R "$FIXTURES/pkg" "$TMP/write-pkg"
  check "write package-json: succeeds" 0 "" \
    version_write package-json 0.2.0 "$TMP/write-pkg"
  check "write package-json: package.json carries new version" 0 "" \
    eq "0.2.0" version_read package-json "$TMP/write-pkg"
  check "write package-json: lockfile carries new version in both spots" 0 "" \
    lock_carries "$TMP/write-pkg" 0.2.0
elif [ -n "${CEREMONY_REQUIRE_NPM:-}" ]; then
  echo "FAIL: CEREMONY_REQUIRE_NPM is set but npm is missing — the package-json write case did not run"
  FAIL=$((FAIL + 1))
else
  echo "SKIP: npm not found — version_write package-json cases not exercised"
fi

summary
