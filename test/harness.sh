#!/usr/bin/env bash
# Sourced assertion helpers. Tests deliberately use set -u, not set -e:
# failing commands are behavior for the harness to inspect.

PASS=0
FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
check() {
  local desc="$1" want="$2" substring="$3"
  shift 3
  local output rc

  output="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$output" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  if [ -n "$substring" ] && ! printf '%s' "$output" | grep -qF -e "$substring"; then
    echo "FAIL: $desc — output missing '$substring'"
    printf '%s\n' "$output" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  echo "ok: $desc"
  PASS=$((PASS + 1))
}

# check_absent <desc> <want_exit> <absent_substr> <cmd...> — check's mirror:
# the row fails when the substring APPEARS. A branch that prints every
# diagnostic on every fault satisfies a positive-only suite, so the claim
# "this text belongs to that fault and not this one" needs an assertion of
# its own (#393).
check_absent() {
  local desc="$1" want="$2" substring="$3"
  shift 3
  local output rc

  # Unlike check, where an empty substring means "assert the exit status
  # only", an empty one here would assert nothing while looking like an
  # assertion — and would pass or fail on whether the output is empty.
  if [ -z "$substring" ]; then
    echo "FAIL: $desc — check_absent needs a substring to look for"
    FAIL=$((FAIL + 1))
    return
  fi

  output="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$output" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  if printf '%s' "$output" | grep -qF -e "$substring"; then
    echo "FAIL: $desc — output contains '$substring'"
    printf '%s\n' "$output" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  echo "ok: $desc"
  PASS=$((PASS + 1))
}

summary() {
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

