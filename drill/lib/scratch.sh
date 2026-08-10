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

# drill_gh_soft <gh-args...> — absent and failed, told apart.
#
# `gh api --jq` applies the filter to the *error* body on a 404 and still
# prints it, so a missing ref answers `null` and an absent file answers a
# JSON object; both read as data downstream. Only the exit status tells them
# apart, so every "does this exist yet" read goes through here.
#
# **Absent** is exit 0 and no output: a 404, and equally the `Git Repository
# is empty. (HTTP 409)` a freshly created repo answers from the git data API
# — the same "not there *yet*" the bootstrap in scratch_commit anticipates,
# and a state the caller reaches by retrying, never by aborting. **Failed**
# is anything else — a 500, a timeout, a refusal — and it is non-zero, for
# the caller to retry or abort on. Collapsing those two into one answer is
# how the 0.7.0 cut came to report a write as failed when it had landed
# (#369): a stale read and a broken one looked identical here.
drill_gh_soft() {
  local out err message rc=0
  err="$(mktemp)"
  out="$(drill_gh "$@" 2>"$err")" || rc=$?
  message="$(cat "$err")"
  rm -f "$err"
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$message" in
    *"(HTTP 404)"* | *"Git Repository is empty"*) return 0 ;;
  esac
  printf '%s\n' "$message" >&2
  return 1
}

# drill_read <mode> <what> <read-cmd...> — a bounded retry around one read.
#
# The 0.7.0 cut aborted four times in setup before a single probe ran, and
# three of those were one defect: every read here follows a write, GitHub
# answered stale or transiently, and nothing in the path retried (#369).
# Shaped like `scratch_run_for` below, whose 90 × 10s poll already says a
# workflow run takes time to appear — a commit was the thing assumed to
# appear instantly. Both bounds are env-overridable so the stubbed suite runs
# at zero nap.
#
# The mode is the caller's judgement about what an empty answer means:
#
#   any       retry while the read FAILS; an absent answer ends it. A ref
#             nobody wrote is answered in one call and spends no budget
#             waiting for a thing that will never arrive.
#   nonempty  retry while it fails OR answers empty — for a read that follows
#             a write this instrument just made, where absence can only be a
#             stale index.
#
# Reads only. A retried write against the git data API risks a second commit,
# which is why one function does every write here (D5).
drill_read() {
  local mode="${1:?drill_read: mode required}"
  local what="${2:?drill_read: description required}"
  shift 2
  local max="${DRILL_READ_TRIES:-10}" nap="${DRILL_READ_NAP_SECONDS:-1}"
  local tries=0 out rc plural=attempts
  # A misspelled mode must not read as the weaker one: `nonempty` is the mode
  # that retries a stale answer, and silently degrading to `any` would put
  # 0.7.0's defect back with nothing to notice it.
  case "$mode" in
    any | nonempty) ;;
    *)
      echo "drill_read: unknown mode '$mode' — expected 'any' or 'nonempty'." >&2
      return 2
      ;;
  esac
  [ "$max" -ge 1 ] || max=1
  while :; do
    tries=$((tries + 1))
    rc=0
    out="$("$@")" || rc=$?
    if [ "$rc" -eq 0 ] && { [ "$mode" != nonempty ] || [ -n "$out" ]; }; then
      [ -z "$out" ] || printf '%s\n' "$out"
      return 0
    fi
    [ "$tries" -lt "$max" ] || break
    [ "$nap" = 0 ] || sleep "$nap"
  done
  # What this message may not do is assert the write failed. Two of 0.7.0's
  # four aborts said exactly that — "the bootstrap commit left … with no
  # head", "the rewritten pin does not read the candidate SHA" — about writes
  # that had landed, and the hour that cost went into re-reading GitHub by
  # hand to find out (#369).
  [ "$tries" -ne 1 ] || plural=attempt
  echo "drill: $what did not read back after $tries $plural — a failed read, not a failed write; the write may well have landed." >&2
  return 1
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

# scratch_ref_sha <repo> <branch> [mode] — the branch head, empty when it has
# none. The mode is drill_read's: `any` (the default) reports a branch nobody
# created, `nonempty` is for the read that follows a write of this very ref.
scratch_ref_sha() {
  local repo="${1:?}" branch="${2:?}" mode="${3:-any}"
  drill_read "$mode" "refs/heads/$branch on $repo" \
    drill_gh_soft api "repos/$repo/git/ref/heads/$branch" --jq '.object.sha'
}

# scratch_paths <repo> <ref> [mode] — every path in the ref's tree, one per
# line. Same two modes, for the same reason.
scratch_paths() {
  local repo="${1:?}" ref="${2:?}" mode="${3:-any}"
  drill_read "$mode" "the tree of $ref on $repo" \
    drill_gh_soft api "repos/$repo/git/trees/$ref?recursive=1" \
    --jq '.tree[] | select(.type == "blob") | .path'
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
  if [ -z "$base_sha" ]; then
    # A freshly created repository refuses the git data API outright —
    # `Git Repository is empty. (HTTP 409)`: blobs and trees need a first
    # commit to hang from. The contents endpoint is the one door open there,
    # so the first file lands through it and everything after rides a tree.
    local seed_path seed_file
    IFS=$'\t' read -r _ seed_path seed_file < <(awk -F'\t' '$1 == "A" { print; exit }' "$manifest")
    if [ -z "${seed_path:-}" ]; then
      echo "scratch_commit: $repo has no commits and the manifest adds no file — nothing to bootstrap from." >&2
      return 1
    fi
    jq -n --arg m "$message" --arg b "$branch" \
      --arg c "$(base64 <"$seed_file" | tr -d '\n')" \
      '{message: $m, branch: $b, content: $c}' |
      drill_gh api "repos/$repo/contents/$seed_path" --method PUT --input - >/dev/null || return 1
    # The write above landed; the read below is the one that can be wrong, so
    # it retries an empty answer rather than reporting the commit as lost.
    base_sha="$(scratch_ref_sha "$repo" "$branch" nonempty)" || return 1
  fi
  if [ -n "$base_sha" ]; then
    # `Git Repository is empty. (HTTP 409)` against a repo `gh repo create`
    # had just returned is what aborted the third 0.7.0 attempt, and it is
    # this read — the base tree of a commit the instrument had just made.
    base_tree="$(drill_read nonempty "the tree of commit $base_sha on $repo" \
      drill_gh_soft api "repos/$repo/git/commits/$base_sha" --jq '.tree.sha')" || return 1
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

# scratch_pr_labels <repo> <number> [mode] — the labels actually on the PR, so
# the probe can confirm rather than assume. drill_read's modes again: `any` for
# "what is on this PR", `nonempty` for the read that follows a label write of
# this instrument's own, where an empty answer can only be a stale index.
scratch_pr_labels() {
  local repo="${1:?}" number="${2:?}" mode="${3:-any}"
  drill_read "$mode" "the labels on $repo#$number" \
    drill_gh_soft api "repos/$repo/issues/$number/labels" --jq '.[].name'
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

# scratch_release_prerelease <repo> <tag> — `true` or `false` for one release.
#
# The rc legs' whole claim is this flag (#321): a candidate published as a
# full release, or retroactively relabeled by the promotion that followed it,
# is a failed probe, and the flag is what says so rather than the prose beside
# it. A tag nobody published is a refusal here rather than an empty string
# downstream — the `probe_counts` lesson, applied to the other measurement the
# rc probes are asserted on.
scratch_release_prerelease() {
  local repo="${1:?}" tag="${2:?}" flag
  flag="$(drill_gh api "repos/$repo/releases?per_page=100" \
    --jq '.[] | "\(.tag_name)\t\(.prerelease)"' |
    awk -F'\t' -v t="$tag" '$1 == t { print $2; exit }')"
  case "$flag" in
    true | false) printf '%s\n' "$flag" ;;
    *)
      echo "scratch_release_prerelease: no release tagged '$tag' at $repo answered with a prerelease flag ('$flag') — a flag nobody read is not a measurement." >&2
      return 1
      ;;
  esac
}

# scratch_file <repo> <ref> <path> <out-file> [mode] — the file's bytes at a
# ref, put where a byte comparison can reach them.
#
# `scratch_version` below strips whitespace because a version is a token;
# this one strips nothing, because the rc cut's changelog claim is `cmp` and
# not prose (#321 D3): "byte-identical before and after" is only a
# measurement if the bytes are what was compared.
#
# The mode is drill_read's, and it defaults to `any` because "is this path
# here" is a real question. Every caller reading a file back off main after a
# release door wrote it passes `nonempty` instead: a 404 there is GitHub being
# stale about a file it holds, and taking it at face value reports the file
# missing — the false absence D1 exists to retire.
scratch_file() {
  local repo="${1:?}" ref="${2:?}" path="${3:?}" out="${4:?}" mode="${5:-any}" encoded
  encoded="$(drill_read "$mode" "$path at $repo@$ref" \
    drill_gh_soft api "repos/$repo/contents/$path?ref=$ref" --jq '.content')" || return 1
  if [ -z "$encoded" ]; then
    echo "scratch_file: $repo@$ref has no '$path' to read." >&2
    return 1
  fi
  base64 -d <<<"$encoded" >"$out"
}

# scratch_version <repo> <ref> [mode] — the tree's VERSION at a ref, for the
# re-arm assertions. Same two modes as scratch_file, for the same reason: the
# re-arm reads are `nonempty`, because the door has just written that file and
# an empty answer about it is a stale index rather than a repo without a
# VERSION. A caller that reads this in `any` mode and then asserts on the
# result is asserting on a read that may not have happened — which is why the
# re-arm sites branch on the exit status rather than on the string.
scratch_version() {
  local repo="${1:?}" ref="${2:?}" mode="${3:-any}" encoded
  encoded="$(drill_read "$mode" "VERSION at $repo@$ref" \
    drill_gh_soft api "repos/$repo/contents/VERSION?ref=$ref" --jq '.content')" || return 1
  [ -n "$encoded" ] || return 0
  base64 -d <<<"$encoded" 2>/dev/null | tr -d '[:space:]'
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
#
# That read is read-after-write like any other, so it goes through the helper
# (D3). The `select(.archived)` is what makes `nonempty` bite here: this read
# answers with a formatted string either way, so a stale `archived=false` about
# a repo the PATCH above just archived is non-empty and would end the retry on
# the wrong answer — the one shape of staleness this call can suffer. Selecting
# on the value just written turns it back into the empty answer `nonempty`
# retries, exactly as the bootstrap's ref re-read does.
#
# And this is the one site in that family where the *wrong* answer is
# representable, so an answer may not be filed as an absence (D7). A read that
# says `archived=false` ten times knows the archive did not land; folding it
# into "the read never answered" throws away exactly what #135 installed the
# read-back for, after 0.2.0 shipped a record asserting a cleanup that had not
# happened. Three dispositions, and the caller states the one it has:
#
#   0  archived, and observed so — the flag is on stdout
#   3  read, and it says the repo is NOT archived — the last answer is on
#      stdout, and the archive did not land
#   1  never answered — nothing on stdout, and nothing may be claimed
scratch_archive() {
  local repo="${1:?}" observed raw last rc=0
  jq -n '{archived: true}' |
    drill_gh api "repos/$repo" --method PATCH --input - >/dev/null || return 1
  raw="$(mktemp)"
  observed="$(drill_read nonempty "the archived flag on $repo" \
    scratch_archived_flag "$repo" "$raw")" || rc=$?
  last="$(cat "$raw")"
  rm -f "$raw"
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$observed"
    return 0
  fi
  # The reads answered, and what they answered was `archived=false`. That is a
  # measurement, not a missing one.
  if [ -n "$last" ]; then
    printf '%s\n' "$last"
    return 3
  fi
  return 1
}

# scratch_archived_flag <repo> <raw-file> — one read of the archive flag,
# recording the whole answer and printing only the archived one.
#
# The split is what keeps D7's two dispositions apart: the raw file holds the
# last answer the read actually got, so an exhausted retry can tell "it said
# false every time" from "it never said anything", while stdout stays empty on
# a false so `drill_read nonempty` goes on retrying the staleness it is there
# for. The file is truncated on a failed read, because a disposition is only
# ever claimed from the answer this attempt got.
scratch_archived_flag() {
  local repo="${1:?}" raw="${2:?}" answer
  : >"$raw"
  answer="$(drill_gh_soft api "repos/$repo" \
    --jq '"archived=\(.archived) private=\(.private)"')" || return 1
  printf '%s' "$answer" >"$raw"
  case "$answer" in
    archived=true*) printf '%s\n' "$answer" ;;
  esac
}
