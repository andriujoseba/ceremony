#!/usr/bin/env bash
# Scratch-repo primitives for the release drill (#313). Sourced, never run.
#
# Every GitHub call the rehearsal makes goes through drill_gh, and that is
# deliberate: it is the one chokepoint where the archives-never-deletes
# refusal can be wired into the instrument rather than left to a comment.
# Both 0.2.0 drills ended at the delete wall independently (#135) — one
# builder retried a 403 that cannot succeed, the other wrote a record
# asserting a delete that had not happened — so the script refuses to reach
# for `delete_repo` at all and prints the operator's step instead.

# drill_guard_delete <gh-args...> — exit 1 iff the call would delete a repo.
#
# Scoped to repository deletion on purpose: probe 6 deletes the mismatched
# tag's ref (`DELETE /repos/{o}/{n}/git/refs/tags/9.9.9`) and that is the
# probe's own cleanup, not the disposal wall.
drill_guard_delete() {
  local method="" endpoint=""
  if [ "${1:-}" = repo ] && [ "${2:-}" = delete ]; then
    echo "drill: refusing 'gh repo delete' — the drill archives and never deletes; delete_repo is absent from fleet tokens by doctrine and the delete is the operator's own step (#135)." >&2
    return 1
  fi
  [ "${1:-}" = api ] || return 0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -X | --method)
        method="${2:-}"
        shift
        ;;
      --method=*) method="${1#--method=}" ;;
      -X*) method="${1#-X}" ;;
      -*) ;;
      *) [ -n "$endpoint" ] || endpoint="$1" ;;
    esac
    shift
  done
  [ "$method" = DELETE ] || return 0
  endpoint="${endpoint#/}"
  endpoint="${endpoint%/}"
  case "$endpoint" in
    repos/*/*/*) return 0 ;;
    repos/*/*)
      echo "drill: refusing 'DELETE /$endpoint' — the drill archives and never deletes; the delete is the operator's own step (#135)." >&2
      return 1
      ;;
  esac
  return 0
}

# drill_gh <gh-args...> — every call the instrument makes.
drill_gh() {
  drill_guard_delete "$@" || return 1
  gh "$@"
}

# scratch_create <owner/name> — a private, disposable repo.
scratch_create() {
  local repo="${1:?scratch_create: owner/name required}"
  drill_gh repo create "$repo" --private >/dev/null || return 1
  printf 'drill: created private scratch repo %s\n' "$repo" >&2
}

# scratch_created_at <owner/name> — the repo's creation stamp, for the record.
scratch_created_at() {
  drill_gh api "repos/${1:?scratch_created_at: repo required}" --jq '.created_at'
}

# scratch_ref_sha <repo> <branch> — the branch head, empty when it has none.
scratch_ref_sha() {
  drill_gh api "repos/${1:?}/git/ref/heads/${2:?}" --jq '.object.sha' 2>/dev/null || true
}

# scratch_paths <repo> <ref> — every path in the ref's tree, one per line.
scratch_paths() {
  drill_gh api "repos/${1:?}/git/trees/${2:?}?recursive=1" \
    --jq '.tree[] | select(.type == "blob") | .path' 2>/dev/null || true
}

# scratch_blob <repo> <local-file> — create a blob, print its SHA.
#
# base64 rather than a raw string: a fixture carries newlines and a workflow
# carries every quoting shape YAML allows, and `gh api -f` would have to
# survive both.
scratch_blob() {
  local repo="${1:?}" file="${2:?}" content
  content="$(base64 <"$file" | tr -d '\n')"
  jq -n --arg c "$content" '{content: $c, encoding: "base64"}' |
    drill_gh api "repos/$repo/git/blobs" --input - --jq '.sha'
}

# scratch_commit <repo> <branch> <message> <manifest-file>
#
# One commit through the git data API, printing its SHA. Manifest lines are
# `A<TAB>path<TAB>local-file` or `D<TAB>path`; a delete rides the tree as a
# null-SHA entry, which is how the API spells removal. The whole rehearsal
# writes through this one function so no probe can leave a half-pushed tree.
scratch_commit() {
  local repo="${1:?}" branch="${2:?}" message="${3:?}" manifest="${4:?}"
  local base_sha base_tree="" entries="[]" op path file blob tree_sha commit_sha
  base_sha="$(scratch_ref_sha "$repo" "$branch")"
  if [ -n "$base_sha" ]; then
    base_tree="$(drill_gh api "repos/$repo/git/commits/$base_sha" --jq '.tree.sha')" || return 1
  fi
  while IFS=$'\t' read -r op path file; do
    [ -n "${op:-}" ] || continue
    case "$op" in
      A)
        blob="$(scratch_blob "$repo" "$file")" || return 1
        entries="$(jq --arg p "$path" --arg s "$blob" \
          '. + [{path: $p, mode: "100644", type: "blob", sha: $s}]' <<<"$entries")"
        ;;
      D)
        entries="$(jq --arg p "$path" \
          '. + [{path: $p, mode: "100644", type: "blob", sha: null}]' <<<"$entries")"
        ;;
      *)
        echo "scratch_commit: unknown manifest op '$op'" >&2
        return 1
        ;;
    esac
  done <"$manifest"
  tree_sha="$(jq -n --argjson tree "$entries" --arg base "$base_tree" \
    '{tree: $tree} + (if $base == "" then {} else {base_tree: $base} end)' |
    drill_gh api "repos/$repo/git/trees" --input - --jq '.sha')" || return 1
  commit_sha="$(jq -n --arg m "$message" --arg t "$tree_sha" --arg p "$base_sha" \
    '{message: $m, tree: $t, parents: (if $p == "" then [] else [$p] end)}' |
    drill_gh api "repos/$repo/git/commits" --input - --jq '.sha')" || return 1
  if [ -n "$base_sha" ]; then
    jq -n --arg s "$commit_sha" '{sha: $s, force: false}' |
      drill_gh api "repos/$repo/git/refs/heads/$branch" --method PATCH --input - >/dev/null || return 1
  else
    jq -n --arg r "refs/heads/$branch" --arg s "$commit_sha" '{ref: $r, sha: $s}' |
      drill_gh api "repos/$repo/git/refs" --input - >/dev/null || return 1
  fi
  printf '%s\n' "$commit_sha"
}

# scratch_ref_create <repo> <ref> <sha> — refs/heads/… or refs/tags/….
scratch_ref_create() {
  jq -n --arg r "${2:?}" --arg s "${3:?}" '{ref: $r, sha: $s}' |
    drill_gh api "repos/${1:?}/git/refs" --input - >/dev/null
}

# scratch_ref_delete <repo> <ref-path> — e.g. tags/9.9.9. Probe 6's cleanup.
scratch_ref_delete() {
  drill_gh api "repos/${1:?}/git/refs/${2:?}" --method DELETE >/dev/null
}

# scratch_label_create <repo> <name> — the guide's prerequisite: the release
# label must exist in the scratch repo before the first ceremony PR.
scratch_label_create() {
  jq -n --arg n "${2:?}" '{name: $n, color: "0E8A16"}' |
    drill_gh api "repos/${1:?}/labels" --input - >/dev/null
}

# scratch_pr_create <repo> <head> <base> <title> — prints the PR number.
scratch_pr_create() {
  jq -n --arg t "${4:?}" --arg h "${2:?}" --arg b "${3:?}" \
    '{title: $t, head: $h, base: $b, body: "Drill probe."}' |
    drill_gh api "repos/${1:?}/pulls" --input - --jq '.number'
}

# scratch_pr_label <repo> <number> <label> — through the issues REST endpoint,
# never `gh pr edit`: that path failed against a projects-classic surface
# mid-drill and the merge went ahead unlabeled before the failure was read
# (0.6.0's probe 2).
scratch_pr_label() {
  jq -n --arg l "${3:?}" '{labels: [$l]}' |
    drill_gh api "repos/${1:?}/issues/${2:?}/labels" --input - >/dev/null
}

# scratch_pr_labels <repo> <number> — the labels actually on the PR, so the
# probe can confirm rather than assume.
scratch_pr_labels() {
  drill_gh api "repos/${1:?}/issues/${2:?}/labels" --jq '.[].name'
}

# scratch_pr_merge <repo> <number> — prints the merge commit SHA.
scratch_pr_merge() {
  jq -n '{merge_method: "merge"}' |
    drill_gh api "repos/${1:?}/pulls/${2:?}/merge" --method PUT --input - --jq '.sha'
}

# scratch_tag_count <repo> / scratch_release_count <repo> — the before/after
# measurement every refusal probe is asserted on (D3).
scratch_tag_count() {
  drill_gh api "repos/${1:?}/tags?per_page=100" --jq 'length'
}

scratch_release_count() {
  drill_gh api "repos/${1:?}/releases?per_page=100" --jq 'length'
}

scratch_release_tags() {
  drill_gh api "repos/${1:?}/releases?per_page=100" --jq '.[].tag_name'
}

# scratch_version <repo> <ref> — the tree's VERSION at a ref, for the
# re-arm assertions.
scratch_version() {
  drill_gh api "repos/${1:?}/contents/VERSION?ref=${2:?}" --jq '.content' 2>/dev/null |
    base64 -d 2>/dev/null | tr -d '[:space:]'
}

# scratch_run_for <repo> <head-sha> — wait for the newest run at a head and
# print `<id><TAB><conclusion>`.
#
# The poll interval is injectable because the stubbed suite drives this same
# function: a rehearsal that could only be exercised live would be exactly
# the manual hour this issue exists to replace.
scratch_run_for() {
  local repo="${1:?}" sha="${2:?}" tries=0 row status
  local max="${DRILL_RUN_TRIES:-90}" nap="${DRILL_RUN_POLL_SECONDS:-10}"
  while [ "$tries" -lt "$max" ]; do
    row="$(drill_gh api "repos/$repo/actions/runs?head_sha=$sha&per_page=100" \
      --jq '[.workflow_runs[]] | sort_by(.id) | last
            | if . == null then "" else "\(.id)\t\(.status)\t\(.conclusion // "")" end')" || row=""
    if [ -n "$row" ]; then
      status="$(cut -f2 <<<"$row")"
      if [ "$status" = completed ]; then
        printf '%s\t%s\n' "$(cut -f1 <<<"$row")" "$(cut -f3 <<<"$row")"
        return 0
      fi
    fi
    tries=$((tries + 1))
    [ "$nap" = 0 ] || sleep "$nap"
  done
  echo "scratch_run_for: no completed run at $repo@$sha after $max polls" >&2
  return 1
}

# scratch_run_rerun <repo> <run-id> — re-run a completed run and wait for the
# new attempt. Probe 4 is the door's own guard re-decided against unchanged
# facts, so it must be the same run and a later attempt, never a fresh run.
scratch_run_rerun() {
  local repo="${1:?}" run="${2:?}" tries=0 row attempt status
  local max="${DRILL_RUN_TRIES:-90}" nap="${DRILL_RUN_POLL_SECONDS:-10}"
  local before
  before="$(drill_gh api "repos/$repo/actions/runs/$run" --jq '.run_attempt // 1')" || return 1
  drill_gh api "repos/$repo/actions/runs/$run/rerun" --method POST >/dev/null || return 1
  while [ "$tries" -lt "$max" ]; do
    row="$(drill_gh api "repos/$repo/actions/runs/$run" \
      --jq '"\(.run_attempt // 1)\t\(.status)\t\(.conclusion // "")"')" || row=""
    if [ -n "$row" ]; then
      attempt="$(cut -f1 <<<"$row")"
      status="$(cut -f2 <<<"$row")"
      if [ "$attempt" -gt "$before" ] && [ "$status" = completed ]; then
        printf '%s\t%s\n' "$attempt" "$(cut -f3 <<<"$row")"
        return 0
      fi
    fi
    tries=$((tries + 1))
    [ "$nap" = 0 ] || sleep "$nap"
  done
  echo "scratch_run_rerun: attempt after $before never completed for run $run" >&2
  return 1
}

# scratch_archive <repo> — archive, then read the flag back. The record
# states the disposal its author observed, never the one it asked for: 0.2.0
# shipped a record asserting a cleanup that had not happened (#135).
scratch_archive() {
  local repo="${1:?}" observed
  jq -n '{archived: true}' |
    drill_gh api "repos/$repo" --method PATCH --input - >/dev/null || return 1
  observed="$(drill_gh api "repos/$repo" --jq '"archived=\(.archived) private=\(.private)"')" || return 1
  printf '%s\n' "$observed"
}
