#!/usr/bin/env bash
set -euo pipefail

# refs-not-closing.sh <body-file> [<closing-issue-number> ...] — compare the
# issues a PR promises merely to reference with GitHub's closing-issue graph
# (#218). The graph is authoritative because it includes both closing
# keywords and sidebar links. The body still matters: only an issue named by
# `Ref #N` or `Refs #N` is protected, so an ordinary `Closes #N` PR remains
# untouched.
#
# This decision stays network-free so test/refs-not-closing.test.sh can drive
# the incident matrix offline. The composite action gathers both facts in one
# GraphQL read and passes them here. A failed or partial read never reaches
# this script: action.yml refuses it before asking for a verdict.

body_file="${1:-}"
shift || true

[ -n "$body_file" ] && [ -f "$body_file" ] || {
  echo "refs-not-closing: body file is missing or unreadable: ${body_file:-<none>}" >&2
  exit 1
}

declare -A closing=()
for issue in "$@"; do
  case "$issue" in
    ''|*[!0-9]*)
      echo "refs-not-closing: invalid closing issue number: '$issue'" >&2
      exit 1
      ;;
  esac
  closing["$issue"]=1
done

mapfile -t refs_targets < <(
  awk '
    {
      rest = tolower($0)
      while (match(rest, /(^|[^[:alnum:]_])refs?[[:space:]]+#[0-9]+/)) {
        token = substr(rest, RSTART, RLENGTH)
        sub(/^.*#/, "", token)
        print token + 0
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$body_file" | sort -nu
)

intersections=()
for issue in "${refs_targets[@]}"; do
  if [ -n "${closing[$issue]:-}" ]; then
    intersections+=("$issue")
  fi
done

if [ "${#intersections[@]}" -eq 0 ]; then
  echo "refs-not-closing: no Refs target appears in GitHub's closing-issue graph"
  exit 0
fi

sentence_for_issue() {
  local issue="$1" mode="$2"
  awk -v issue="$issue" -v mode="$mode" '
    {
      text = text separator $0
      separator = "\n"
    }
    END {
      count = split(text, sentence, /[.!?][[:space:]]+|\n+/)
      if (mode == "closing") {
        needle = "(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+#[[:space:]]*" issue "([^0-9]|$)"
      } else {
        needle = "(^|[^[:alnum:]_])refs?[[:space:]]+#[[:space:]]*" issue "([^0-9]|$)"
      }
      for (i = 1; i <= count; i++) {
        lower = tolower(sentence[i])
        if (match(lower, needle)) {
          matched = substr(sentence[i], RSTART, RLENGTH)
          sub(/^[^[:alnum:]_]*/, "", matched)
          sub(/[^0-9]*$/, "", matched)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", sentence[i])
          printf "%s\t%s\n", matched, sentence[i]
          exit
        }
      }
    }
  ' "$body_file"
}

{
  printf 'refs-not-closing: Refs target(s) also scheduled to close:'
  printf ' #%s' "${intersections[@]}"
  printf '\n'

  for issue in "${intersections[@]}"; do
    detail="$(sentence_for_issue "$issue" closing)"
    if [ -z "$detail" ]; then
      detail="$(sentence_for_issue "$issue" refs)"
      printf "  #%s: GitHub reports a closing reference; no adjacent closing keyword was found, so inspect the Development sidebar link.\n" "$issue"
    fi
    if [ -n "$detail" ]; then
      matched="${detail%%$'\t'*}"
      sentence="${detail#*$'\t'}"
      printf '    matched: %s\n' "$matched"
      printf '    sentence: %s\n' "$sentence"
    fi
  done

  cat <<'EOF'
  A `Refs #N` PR must not close N. Remove the sidebar closing link or rewrite
  an adjacent closing-keyword sentence so the number comes first (`#N is
  closed by hand`) or the number is omitted (`triage closes the issue by
  hand`). Backticks do not protect a closing keyword from GitHub's parser.
EOF
} >&2
exit 1
