#!/usr/bin/env bash
set -euo pipefail

# A vendored rule without a guard is memory, not enforcement (#399). Read
# only the two shipping surfaces named by the caller; fixture trees below
# them are deliberately outside this non-recursive scan.
workflows_dir="${1:-${WORKFLOWS_DIR:-.github/workflows}}"
actions_dir="${2:-${ACTIONS_DIR:-.github/actions}}"
first_party_owner="${3:-${FIRST_PARTY_OWNER:-}}"

if [ -z "$first_party_owner" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  first_party_owner="${GITHUB_REPOSITORY%%/*}"
fi

shopt -s nullglob
files=()
if [ -d "$workflows_dir" ]; then
  files+=("$workflows_dir"/*.yml "$workflows_dir"/*.yaml)
fi
if [ -d "$actions_dir" ]; then
  files+=("$actions_dir"/*/action.yml "$actions_dir"/*/action.yaml)
fi

failures=0
for file in "${files[@]}"; do
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    if [[ ! "$line" =~ ^[[:space:]]*-?[[:space:]]*uses: ]]; then
      continue
    fi

    value="${line#*:}"
    value="${value#"${value%%[![:space:]]*}"}"
    reference="${value%%[[:space:]]*}"
    reference="${reference#\"}"
    reference="${reference#\'}"
    reference="${reference%\"}"
    reference="${reference%\'}"

    case "$reference" in
      ./* | docker://*) continue ;;
    esac

    owner="${reference%%/*}"
    if [ -n "$first_party_owner" ] && [ "$owner" = "$first_party_owner" ]; then
      continue
    fi

    if [[ "$value" =~ ^[^[:space:]#]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*[^[:space:]] ]]; then
      continue
    fi

    printf '%s:%d: unpinned third-party reference %q; fix: replace @ref with @<40-lowercase-hex-commit-sha> # <version>\n' \
      "$file" "$line_number" "$reference" >&2
    failures=$((failures + 1))
  done <"$file"
done

if [ "$failures" -ne 0 ]; then
  printf 'sha-pinned: %d unpinned third-party reference(s)\n' "$failures" >&2
  exit 1
fi

printf 'sha-pinned: %d file(s) checked; every third-party reference is pinned\n' \
  "${#files[@]}"
