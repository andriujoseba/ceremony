#!/usr/bin/env bash
set -u

# The dispatched merge entrance is deliberately inert until a caller opts in
# (#467): the workflow's gate, fixed-head seam and dry scratch caller are one
# contract. These assertions stay scoped to their named jobs so a matching
# line elsewhere cannot make a broken door look sound.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"

RELEASE_WORKFLOW="${RELEASE_WORKFLOW:-$ROOT/.github/workflows/release.yml}"
EXERCISE_WORKFLOW="${EXERCISE_WORKFLOW:-$ROOT/.github/workflows/release-exercise.yml}"

job_block() { # $1 = file, $2 = job name
  awk -v job="^  $2:\$" '
    $0 ~ job { found = 1 }
    found && $0 !~ job && /^  [a-zA-Z0-9_-]+:$/ { exit }
    found { print }
  ' "$1"
}

input_block() { # $1 = file, $2 = input name
  awk -v input="^      $2:\$" '
    $0 ~ input { found = 1 }
    found && $0 !~ input && /^      [a-zA-Z0-9_-]+:$/ { exit }
    found { print }
  ' "$1"
}

step_body() { # $1 = file, $2 = exact step name
  awk -v name="      - name: $2" '
    $0 == name { step = 1; next }
    step && /^        run: \|$/ { body = 1; next }
    body && /^          / { print substr($0, 11); next }
    body { exit }
  ' "$1"
}

MERGE_JOB="$(job_block "$RELEASE_WORKFLOW" release-on-merge)"
TAG_JOB="$(job_block "$RELEASE_WORKFLOW" release-on-tag)"
CALL_JOB="$(job_block "$EXERCISE_WORKFLOW" call)"
MERGED_SHA_INPUT="$(input_block "$RELEASE_WORKFLOW" merged-sha)"

check "merged-sha is an optional string input" 0 $'type: string\n        required: false\n        default: ""' \
  printf '%s\n' "$MERGED_SHA_INPUT"
for phrase in workflow_dispatch '40-character lowercase commit SHA' 'empty value keeps the merge door shut'; do
  check "merged-sha description states '$phrase'" 0 "$phrase" \
    printf '%s\n' "$MERGED_SHA_INPUT"
done

check "merge door keeps the push+main entrance" 0 \
  "(github.event_name == 'push' && github.ref == 'refs/heads/main')" \
  printf '%s\n' "$MERGE_JOB"
check "merge door adds only dispatch+non-empty merged-sha" 0 \
  "(github.event_name == 'workflow_dispatch' && inputs.merged-sha != '')" \
  printf '%s\n' "$MERGE_JOB"
check "merge door has exactly two event-name forms" 0 "2" bash -c \
  'printf "%s\n" "$1" | grep -o "github.event_name" | wc -l | tr -d " "' _ "$MERGE_JOB"
check "tag door remains push-only" 1 "" \
  grep -F 'workflow_dispatch' <<<"$TAG_JOB"

check "merge job defines the one shipped-head seam" 0 \
  'MERGE_SHA: ${{ inputs.merged-sha || github.sha }}' \
  printf '%s\n' "$MERGE_JOB"
check "merge job has no direct github.sha consumer" 1 "" \
  grep -F 'github.sha' <<<"$(printf '%s\n' "$MERGE_JOB" | grep -vF 'inputs.merged-sha || github.sha')"
check "the checkout reads MERGE_SHA" 0 'ref: ${{ env.MERGE_SHA }}' \
  printf '%s\n' "$MERGE_JOB"
check "facts and tag both read MERGE_SHA" 0 "2" bash -c \
  'printf "%s\n" "$1" | grep -F "MERGE_SHA: \${{ env.MERGE_SHA }}" | wc -l | tr -d " "' _ "$MERGE_JOB"

VALIDATE_NAME="assert a dispatched head is a full lowercase commit SHA"
validate_line="$(grep -nF -- "- name: $VALIDATE_NAME" "$RELEASE_WORKFLOW" | cut -d: -f1)"
checkout_line="$(grep -nF -- '- uses: actions/checkout@' "$RELEASE_WORKFLOW" | head -1 | cut -d: -f1)"
check "SHA-shape assert precedes the first checkout" 0 "" \
  test "$validate_line" -lt "$checkout_line"
check "SHA-shape assert runs only for the dispatched entrance" 0 \
  "if: inputs.merged-sha != ''" \
  awk -v line="$validate_line" 'NR >= line && NR <= line + 3 { print }' "$RELEASE_WORKFLOW"

VALIDATION_BODY="$(step_body "$RELEASE_WORKFLOW" "$VALIDATE_NAME")"
if [ -z "$VALIDATION_BODY" ]; then
  echo "FAIL: SHA-shape step has no executable body"
  FAIL=$((FAIL + 1))
else
  echo "ok: SHA-shape step has an executable body"
  PASS=$((PASS + 1))
fi

VALIDATION_CASE=0
run_validation() { # $1 = value; invalid executions must create nothing
  value="$1"
  VALIDATION_CASE=$((VALIDATION_CASE + 1))
  case_dir="$TMP/case-$VALIDATION_CASE"
  mkdir -p "$case_dir"
  (
    cd "$case_dir"
    MERGED_SHA="$value" bash -c "$VALIDATION_BODY"
  )
  rc=$?
  if find "$case_dir" -mindepth 1 -print -quit | grep -q .; then
    echo "validation created a file for '$value'" >&2
    return 99
  fi
  return "$rc"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
check "full lowercase SHA is accepted" 0 "" run_validation \
  0123456789abcdef0123456789abcdef01234567
check "ref-shaped input is refused without creating anything" 1 \
  "must be a full 40-character lowercase commit SHA" run_validation main
check "abbreviated SHA is refused without creating anything" 1 \
  "must be a full 40-character lowercase commit SHA" run_validation 0123456
check "empty-but-set SHA is refused without creating anything" 1 \
  "must be a full 40-character lowercase commit SHA" run_validation ""

check "scratch call job passes no merged-sha" 1 "" \
  grep -F 'merged-sha' <<<"$CALL_JOB"

summary
