#!/usr/bin/env bash
set -euo pipefail

# The composite action's executable boundary (#218). Keeping the GraphQL
# gather here lets the offline contract test replace `gh` and prove that
# failed and partial reads cannot accidentally produce a green verdict.

owner="${GITHUB_REPOSITORY%%/*}"
name="${GITHUB_REPOSITORY#*/}"
[ -n "${PR_NUMBER:-}" ] || {
  echo "refs-not-closing: pull request number is unavailable" >&2
  exit 1
}

facts="$(gh api graphql \
  -f query='query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        body
        closingIssuesReferences(first: 100) {
          nodes { number }
          pageInfo { hasNextPage }
        }
      }
    }
  }' \
  -F owner="$owner" -F name="$name" -F number="$PR_NUMBER")"

body_file="$(mktemp)"
closing_file="$(mktemp)"
trap 'rm -f "$body_file" "$closing_file"' EXIT
jq -er '
  .data.repository.pullRequest
  | if . == null then error("pull request was not returned") else .body // "" end
' <<<"$facts" >"$body_file"
jq -r '
  .data.repository.pullRequest.closingIssuesReferences
  | if . == null then
      error("closing issue references were not returned")
    elif .pageInfo.hasNextPage then
      error("more than 100 closing issue references; refusing a partial verdict")
    else
      .nodes[].number
    end
' <<<"$facts" >"$closing_file"

mapfile -t closing_issues <"$closing_file"
bash "$GITHUB_ACTION_PATH/refs-not-closing.sh" \
  "$body_file" "${closing_issues[@]}"
