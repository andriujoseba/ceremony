#!/usr/bin/env bash
# Scratch-attempt naming for the release drill (#371). Sourced, never run.
#
# A default name is claimed by creation, not by a read followed by a write:
# another runner cannot take the supposedly free name between those calls.
# Explicit names keep the opposite contract — refuse rather than route around
# them — and use read-only probes only to print the runnable replacement.

DRILL_ATTEMPT_LIMIT=10

# scratch_create_attempt <owner/name> — create, or return 3 for a collision.
scratch_create_attempt() {
  local repo="${1:?scratch_create_attempt: owner/name required}" err rc=0 message
  err="$(mktemp)"
  drill_gh repo create "$repo" --private >/dev/null 2>"$err" || rc=$?
  message="$(cat "$err")"
  rm -f "$err"
  if [ "$rc" -eq 0 ]; then
    printf 'drill: created private scratch repo %s\n' "$repo" >&2
    return 0
  fi
  case "$message" in
    *"Name already exists"* | *"already exists on this account"*) return 3 ;;
  esac
  printf '%s\n' "$message" >&2
  return "$rc"
}

# scratch_repo_exists <owner/name> — 0 exists, 1 absent, 2 unreadable.
scratch_repo_exists() {
  local repo="${1:?scratch_repo_exists: owner/name required}" answer rc=0
  answer="$(drill_gh_soft api "repos/$repo" --jq '.created_at')" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$answer" ]
}

# attempt_create_default <owner> <version> — claim and print the first free n.
attempt_create_default() {
  local owner="${1:?}" version="${2:?}" n repo rc
  n=1
  while [ "$n" -le "$DRILL_ATTEMPT_LIMIT" ]; do
    repo="$owner/ceremony-drill-$version-$n"
    rc=0
    scratch_create_attempt "$repo" || rc=$?
    case "$rc" in
      0)
        if [ "$n" -eq 1 ]; then
          printf 'drill: ceremony-drill-%s-1 is free; using -1\n' "$version" >&2
        else
          printf 'drill: ceremony-drill-%s-1 through -%s exist; using -%s\n' \
            "$version" "$((n - 1))" "$n" >&2
        fi
        printf '%s\n' "$n"
        return 0
        ;;
      3) ;;
      *) return "$rc" ;;
    esac
    n=$((n + 1))
  done
  printf 'drill: no scratch attempt name is free; tried ceremony-drill-%s-1 through ceremony-drill-%s-%s (the bounded %s-candidate probe).\n' \
    "$version" "$version" "$DRILL_ATTEMPT_LIMIT" "$DRILL_ATTEMPT_LIMIT" >&2
  return 1
}

# attempt_first_free <owner> <version> — read-only suggestion for a refusal.
attempt_first_free() {
  local owner="${1:?}" version="${2:?}" n repo rc
  n=1
  while [ "$n" -le "$DRILL_ATTEMPT_LIMIT" ]; do
    repo="$owner/ceremony-drill-$version-$n"
    rc=0
    scratch_repo_exists "$repo" || rc=$?
    case "$rc" in
      0) ;;
      1) printf '%s\n' "$n"; return 0 ;;
      *) return "$rc" ;;
    esac
    n=$((n + 1))
  done
  printf 'drill: no scratch attempt name is free; tried ceremony-drill-%s-1 through ceremony-drill-%s-%s (the bounded %s-candidate probe).\n' \
    "$version" "$version" "$DRILL_ATTEMPT_LIMIT" "$DRILL_ATTEMPT_LIMIT" >&2
  return 1
}
