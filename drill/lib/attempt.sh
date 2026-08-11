#!/usr/bin/env bash
# Scratch-attempt naming for the release drill (#371). Sourced, never run.
#
# A default repo name is claimed by creation, not by a read followed by a
# write: another runner cannot take the supposedly free name between those
# calls. Its paired fork ref has to be absent before that claim, because one
# attempt number names both artifacts and either one can outlive the other.
# Explicit names keep the opposite contract — refuse rather than route around
# them — and use read-only probes only to print the runnable replacement.

DRILL_ATTEMPT_LIMIT=10

# scratch_create_attempt <owner/name> [private] — create, or return 3 for a collision.
scratch_create_attempt() {
  local repo="${1:?scratch_create_attempt: owner/name required}" private="${2:-0}"
  local err rc=0 message
  local -a create_args=(repo create "$repo")
  [ "$private" -eq 0 ] || create_args+=(--private)
  err="$(mktemp)"
  drill_gh "${create_args[@]}" >/dev/null 2>"$err" || rc=$?
  message="$(cat "$err")"
  rm -f "$err"
  if [ "$rc" -eq 0 ]; then
    if [ "$private" -eq 0 ]; then
      printf 'drill: created public scratch repo %s\n' "$repo" >&2
    else
      printf 'drill: warning: created private scratch repo %s; its record links resolve only for the repo owner.\n' \
        "$repo" >&2
    fi
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

# attempt_ref_exists <fork-repo> <version> <n> — 0 exists, 1 absent, 2 unreadable.
attempt_ref_exists() {
  local fork_repo="${1:?}" version="${2:?}" n="${3:?}" answer
  answer="$(scratch_ref_sha "$fork_repo" "drill/$version-$n")" || return 2
  [ -n "$answer" ]
}

# attempt_ref_absent <fork-repo> <version> <n> — setup assertion for a pick.
attempt_ref_absent() {
  local fork_repo="${1:?}" version="${2:?}" n="${3:?}" rc=0
  attempt_ref_exists "$fork_repo" "$version" "$n" || rc=$?
  case "$rc" in
    0)
      printf 'drill: numbered default fork ref %s@drill/%s-%s is already taken.\n' \
        "$fork_repo" "$version" "$n" >&2
      return 1
      ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
}

# attempt_first_free_ref <fork-repo> <version> — first free numbered default ref.
attempt_first_free_ref() {
  local fork_repo="${1:?}" version="${2:?}" n rc
  n=1
  while [ "$n" -le "$DRILL_ATTEMPT_LIMIT" ]; do
    rc=0
    attempt_ref_exists "$fork_repo" "$version" "$n" || rc=$?
    case "$rc" in
      0) ;;
      1) printf '%s\n' "$n"; return 0 ;;
      *) return "$rc" ;;
    esac
    n=$((n + 1))
  done
  printf 'drill: no numbered default fork ref is free; tried drill/%s-1 through drill/%s-%s (the bounded %s-candidate probe).\n' \
    "$version" "$version" "$DRILL_ATTEMPT_LIMIT" "$DRILL_ATTEMPT_LIMIT" >&2
  return 1
}

# attempt_create_default <owner> <version> [fork-repo] [private] — claim the first pair.
# The fork repo is omitted when the invocation supplied an explicit ref.
attempt_create_default() {
  local owner="${1:?}" version="${2:?}" fork_repo="${3:-}" private="${4:-0}"
  local n repo rc
  n=1
  while [ "$n" -le "$DRILL_ATTEMPT_LIMIT" ]; do
    if [ -n "$fork_repo" ]; then
      rc=0
      attempt_ref_exists "$fork_repo" "$version" "$n" || rc=$?
      case "$rc" in
        0) n=$((n + 1)); continue ;;
        1) ;;
        *) return "$rc" ;;
      esac
    fi
    repo="$owner/ceremony-drill-$version-$n"
    rc=0
    scratch_create_attempt "$repo" "$private" || rc=$?
    case "$rc" in
      0)
        if [ "$n" -eq 1 ]; then
          if [ -n "$fork_repo" ]; then
            printf 'drill: attempt -1 repo and fork ref are free; using -1\n' >&2
          else
            printf 'drill: attempt -1 repo name is free; using -1\n' >&2
          fi
        elif [ "$n" -eq 2 ]; then
          printf 'drill: attempt -1 is unavailable; using -2\n' >&2
        else
          printf 'drill: attempts -1 through -%s are unavailable; using -%s\n' \
            "$((n - 1))" "$n" >&2
        fi
        printf '%s\n' "$n"
        return 0
        ;;
      3) ;;
      *) return "$rc" ;;
    esac
    n=$((n + 1))
  done
  printf 'drill: no scratch attempt pair is free; tried ceremony-drill-%s-1 through ceremony-drill-%s-%s and their paired fork refs (the bounded %s-candidate probe).\n' \
    "$version" "$version" "$DRILL_ATTEMPT_LIMIT" "$DRILL_ATTEMPT_LIMIT" >&2
  return 1
}

# attempt_first_free <owner> <version> [fork-repo] — read-only paired suggestion.
# The fork repo is omitted when the invocation supplied an explicit ref.
attempt_first_free() {
  local owner="${1:?}" version="${2:?}" fork_repo="${3:-}" n repo rc
  n=1
  while [ "$n" -le "$DRILL_ATTEMPT_LIMIT" ]; do
    repo="$owner/ceremony-drill-$version-$n"
    rc=0
    scratch_repo_exists "$repo" || rc=$?
    case "$rc" in
      0) ;;
      1)
        [ -n "$fork_repo" ] || { printf '%s\n' "$n"; return 0; }
        rc=0
        attempt_ref_exists "$fork_repo" "$version" "$n" || rc=$?
        case "$rc" in
          0) ;;
          1) printf '%s\n' "$n"; return 0 ;;
          *) return "$rc" ;;
        esac
        ;;
      *) return "$rc" ;;
    esac
    n=$((n + 1))
  done
  printf 'drill: no scratch attempt pair is free; tried ceremony-drill-%s-1 through ceremony-drill-%s-%s and their paired fork refs (the bounded %s-candidate probe).\n' \
    "$version" "$version" "$DRILL_ATTEMPT_LIMIT" "$DRILL_ATTEMPT_LIMIT" >&2
  return 1
}
