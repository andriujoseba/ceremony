#!/usr/bin/env bash
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
else
  # Fixture tests source the pure functions and deliberately inspect failures.
  set -u
fi

# labels-scope.sh — the additive half of the labels automation: derive
# scope:* labels from a PR's changed paths and ADD them, touching nothing
# else. This seat belonged to actions/labeler@v5 until #130: even under
# `sync-labels: false`, labeler computes (labels-fetched-at-job-start ∪
# derived) and writes it back with `PUT /issues/{n}/labels`
# (src/labeler.ts: api.setLabels — a full replace), so any label applied
# between its read and its write is silently removed. On ceremony#128 the
# builder's `release` — the merge door's declared-intent read — landed in
# that window and vanished two seconds later; v6 and v7 write the same
# way, so the fix is this replacement, not a newer pin.
#
# The only write here is `POST /issues/{n}/labels`: GitHub adds the named
# labels, ignores ones already present, and removes nothing. A label
# applied while this runs survives by construction.
#
# The path mapping stays in the consumer's .github/labeler.yml, read via
# the API at CONFIG_REF — the base branch, never the PR head, so a PR
# cannot label itself by editing the mapping. The accepted shape is the
# one every governed repo uses:
#
#   scope:name:
#     - changed-files:
#         - any-glob-to-any-file: ["glob", ...]
#
# in any YAML spelling (block or flow; a glob list may be a single
# string). Anything else — all-globs-to-all-files, branch matchers,
# negations, backslash escapes — is refused loudly rather than
# half-honoured: this parser exists to make one write additive, not to
# reimplement minimatch. Globs support `**` (crosses `/`), `*` and `?`
# (do not); a leading dot is not special; the whole path must match
# (`README` matches README, never docs/README).

log() { printf 'labels-scope: %s\n' "$*"; }

run() { # every mutation goes through here — DRY_RUN=1 logs instead of doing
  if [ -n "${DRY_RUN:-}" ]; then log "DRY_RUN: $*"; else "$@"; fi
}

glob_to_regex() { # $1 = glob (the subset above) → anchored ERE, one line
  local glob="$1" out="" c i=0 n
  n="${#glob}"
  while [ "$i" -lt "$n" ]; do
    c="${glob:i:1}"
    case "$c" in
      \*)
        if [ "${glob:i:2}" = '**' ]; then
          out="$out.*"
          i=$((i + 2))
          continue
        fi
        out="${out}[^/]*"
        ;;
      \?) out="${out}[^/]" ;;
      [a-zA-Z0-9_/-]) out="$out$c" ;;
      *) out="$out\\$c" ;; # every other byte is literal — ., +, {, (, …
    esac
    i=$((i + 1))
  done
  printf '^%s$\n' "$out"
}

parse_labeler_config() { # labeler.yml on stdin → "label<TAB>glob" lines
  # yq only normalizes YAML to JSON; the shape contract is enforced in jq,
  # where an unsupported key is a loud error naming the label it sits under.
  yq -o=json '.' - | jq -r '
    if type != "object" then
      error("labeler config: top level must be a map of label -> rules")
    else . end
    | to_entries[]
    | .key as $label
    | (if (.value | type) != "array" then
         error("labeler config: \($label): rules must be a list")
       else .value end)[]
    | (if type != "object" then
         error("labeler config: \($label): each rule must be a map")
       else . end)
    | ((keys - ["changed-files"]) as $extra
       | if ($extra | length) > 0 then
           error("labeler config: \($label): unsupported key(s) \($extra | join(", ")) — the scope job accepts changed-files/any-glob-to-any-file only (#130)")
         else . end)
    | .["changed-files"]
    | (if type == "object" then [.]
       elif type == "array" then .
       else error("labeler config: \($label): changed-files must be a list") end)[]
    | (if type != "object" then
         error("labeler config: \($label): each changed-files entry must be a map")
       else . end)
    | ((keys - ["any-glob-to-any-file"]) as $extra
       | if ($extra | length) > 0 then
           error("labeler config: \($label): unsupported matcher(s) \($extra | join(", ")) — the scope job accepts any-glob-to-any-file only (#130)")
         else . end)
    | .["any-glob-to-any-file"]
    | (if type == "string" then [.]
       elif type == "array" then .
       else error("labeler config: \($label): any-glob-to-any-file must be a glob or a list of globs") end)[]
    | (if type != "string" then
         error("labeler config: \($label): globs must be strings")
       elif contains("\\") then
         error("labeler config: \($label): backslash in glob \(.) — escapes are not supported (#130)")
       else . end)
    | [$label, .] | @tsv
  '
}

derive_labels() { # $1 = "label<TAB>glob" lines, $2 = changed files (one per
  # line) → matched labels, one per line, config order, deduped
  local tsv="$1" files="$2" label glob matched=$'\n'
  [ -n "$files" ] || return 0
  while IFS=$'\t' read -r label glob; do
    [ -n "$label" ] || continue
    case "$matched" in *$'\n'"$label"$'\n'*) continue ;; esac
    # Herestring, never a pipe: `grep -qE` exits at the first matching path,
    # so a pipe leaves printf writing the rest of a PR's changed-file list,
    # EPIPE, and `pipefail` — armed above when this script is executed —
    # fails the pipeline although grep matched. Inside this per-glob loop
    # that is a scope label silently not applied, or a dead run (#364, #411).
    if grep -qE -- "$(glob_to_regex "$glob")" <<<"$files"; then
      matched="$matched$label"$'\n'
      printf '%s\n' "$label"
    fi
  done <<<"$tsv"
}

main() {
  REPO="${REPO:?set REPO to owner/name}"
  PR_NUMBER="${PR_NUMBER:?set PR_NUMBER to the pull request number}"
  CONFIG_REF="${CONFIG_REF:?set CONFIG_REF to the base commit the mapping is read at}"
  CONFIG_PATH="${CONFIG_PATH:-.github/labeler.yml}"

  local config tsv files labels
  # No mapping is a consumer that has not adopted scope labels — an
  # advisory no-op, not a red run (scopes locate, they do not alert). A
  # mapping that EXISTS but does not parse still fails loudly below.
  if ! config="$(gh api "repos/$REPO/contents/$CONFIG_PATH?ref=$CONFIG_REF" \
    --jq '.content' 2>/dev/null | base64 -d)" || [ -z "$config" ]; then
    log "no $CONFIG_PATH at $CONFIG_REF — nothing to derive"
    return 0
  fi
  tsv="$(parse_labeler_config <<<"$config")"
  files="$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" --jq '.[].filename')"
  labels="$(derive_labels "$tsv" "$files")"

  if [ -z "$labels" ]; then
    log "#$PR_NUMBER: no scope labels derived"
    return 0
  fi
  local args=()
  while IFS= read -r label; do args+=(-f "labels[]=$label"); done <<<"$labels"
  run gh api "repos/$REPO/issues/$PR_NUMBER/labels" "${args[@]}" --silent
  log "#$PR_NUMBER: scopes -> $(paste -sd, <<<"$labels") (additive POST; already-present names are no-ops)"
}

# sourced by test/labels-scope.test.sh for the fixture tests; executed in CI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
