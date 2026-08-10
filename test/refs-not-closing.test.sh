#!/usr/bin/env bash
# Contract tests for actions/refs-not-closing (issue #218). Bodies and
# closing-reference sets are fixtures: no network and no pull request are
# involved. set -u, not -e: failures are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/actions/refs-not-closing/refs-not-closing.sh"
ACTION="$ROOT/actions/refs-not-closing/action.yml"
ENTRYPOINT="$ROOT/actions/refs-not-closing/run.sh"
WORKFLOW="$ROOT/.github/workflows/refs-guard.yml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

body() {
  local name="$1"
  shift
  printf '%s\n' "$@" >"$TMP/$name.md"
}

guard() {
  local name="$1"
  shift
  bash "$SCRIPT" "$TMP/$name.md" "$@"
}

body ref-5 'Refs #5'
check "Refs target with empty closing set passes" 0 "no Refs target" guard ref-5
check "Refs target with itself closing fails" 1 "#5" guard ref-5 5
check "Refs target with another issue closing passes" 0 "no Refs target" guard ref-5 9

body ordinary 'Closes #5'
check "ordinary Closes PR remains green" 0 "no Refs target" guard ordinary 5

body mixed 'Refs #5' '' 'This PR legitimately Closes #9.'
check "Refs #5 plus Closes #9 remains green" 0 "no Refs target" guard mixed 9

body prose 'Refs #5' '' 'Triage closes #5 by hand after the live proof.'
check "closing prose for a Refs target fails" 1 "closes #5" guard prose 5
check "failure prints the surrounding sentence" 1 \
  "sentence: Triage closes #5 by hand after the live proof" guard prose 5
check "failure offers number-first rewrite" 1 "#N is" guard prose 5
check "failure offers number-free rewrite" 1 "closes the issue" guard prose 5

body code-span 'Refs #5' '' "The body must not contain \`Closes #5\` anywhere."
check "backticked closing keyword is reported as the match" 1 \
  "matched: Closes #5" guard code-span 5
check "backticked match points at the Development sidebar remedy" 1 \
  "remove the Development sidebar link" guard code-span 5

diagnostic_contains_retired_sentence() {
  bash "$SCRIPT" "$TMP/code-span.md" 5 2>&1 |
    grep -qF "Backticks do not protect"
}

check "failure omits the retired backtick claim" 1 "" \
  diagnostic_contains_retired_sentence

# Prove the diagnostic pin is load-bearing rather than merely compatible with
# both the retired and replacement text (#359).
MUTANT="$TMP/refs-not-closing-without-routes.sh"
sed '/The closing graph can come from a/,/sidebar link\./c\
  The closing graph has an unexplained entry.' "$SCRIPT" >"$MUTANT"

diagnostic_names_both_routes() {
  local candidate="$1" output
  output="$(bash "$candidate" "$TMP/code-span.md" 5 2>&1)"
  grep -qF "closing keyword adjacent to the number in the body's prose" \
    <<<"$output" && grep -qF "Development" <<<"$output"
}

check "diagnostic names both closing-graph routes" 0 "" \
  diagnostic_names_both_routes "$SCRIPT"
check "two-route mutation changes the script" 1 "" \
  cmp -s "$SCRIPT" "$MUTANT"
check "removing the two-route diagnostic reds its pin" 1 "" \
  diagnostic_names_both_routes "$MUTANT"

body adjacency 'Refs #5' '' 'Triage closes #9 and #5 after the proof.'
check "non-adjacent #5 does not join closing set #9" 0 "no Refs target" \
  guard adjacency 9

body empty ''
check "empty body remains green" 0 "no Refs target" guard empty 5

body incidents-211 'Refs #209' 'Triage closes #209 by hand.'
check "#211 incident replays red" 1 "#209" guard incidents-211 209
body incidents-214 'Refs #212' 'Triage closes #212 and #209 on that evidence.'
check "#214 incident replays red" 1 "#212" guard incidents-214 212
body incidents-200 'Refs #199' "A later edit added \`Closes #199\`."
check "#200 incident replays red" 1 "#199" guard incidents-200 199

body multiple 'Refs #5 and Refs #7.' 'Triage closes #5 and fixes #7 by hand.'
check "failure names every intersecting issue" 1 \
  "scheduled to close: #5 #7" guard multiple 5 7

body soft-wrap 'Refs #5' '' 'Triage closes' '#5 by hand after the live proof.'
check "soft-wrapped closing prose is reported as one sentence" 1 \
  "sentence: Triage closes #5 by hand after the live proof" \
  guard soft-wrap 5

body refs-colon 'Refs: #5' '' 'Triage closes #5 after proof.'
check "Refs colon form is protected" 1 "matched: closes #5" \
  guard refs-colon 5
body refs-link 'Refs [#5](https://example.test/issues/5)' '' \
  'Triage closes #5 after proof.'
check "linked Refs form is protected" 1 "matched: closes #5" \
  guard refs-link 5

for number in 207 191 190 176 165 164; do
  body "incident-$number" "Refs #$number"
  check "#$number incident replays green" 0 "no Refs target" \
    guard "incident-$number"
done

check "missing body is a loud failure" 1 "missing or unreadable" \
  bash "$SCRIPT" "$TMP/missing.md"
check "invalid closing set is a loud failure" 1 "invalid closing issue" \
  guard ref-5 nope

# The action owns the network boundary. Drive its executable entrypoint with
# a fake `gh` so failures are behavioral assertions, not YAML text guesses.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
case "${FAKE_GH_MODE:-success}" in
  failure)
    echo "fake GraphQL read failed" >&2
    exit 42
    ;;
  partial)
    has_next=true
    ;;
  success)
    has_next=false
    ;;
  *)
    echo "unknown fake mode: ${FAKE_GH_MODE:-}" >&2
    exit 2
    ;;
esac
printf '{"data":{"repository":{"pullRequest":{"body":"Refs #5","closingIssuesReferences":{"nodes":[],"pageInfo":{"hasNextPage":%s}}}}}}\n' "$has_next"
EOF
chmod +x "$TMP/bin/gh"

action_boundary() {
  local mode="$1"
  env PATH="$TMP/bin:$PATH" FAKE_GH_MODE="$mode" \
    GITHUB_REPOSITORY="heavy-duty/ceremony" PR_NUMBER=268 \
    GITHUB_ACTION_PATH="$ROOT/actions/refs-not-closing" \
    bash "$ENTRYPOINT"
}

check "action boundary fails when GraphQL read fails" 42 \
  "fake GraphQL read failed" action_boundary failure
check "action boundary refuses a partial closing-reference page" 5 \
  "refusing a partial verdict" action_boundary partial
check "action boundary accepts a complete GraphQL read" 0 \
  "no Refs target" action_boundary success

one_graphql_read() {
  [ "$(grep -c "gh api graphql" "$ENTRYPOINT")" -eq 1 ]
  printf '1\n'
}

check "action performs exactly one GraphQL read" 0 "1" \
  one_graphql_read
check "composite delegates to the tested entrypoint" 0 "run.sh" \
  grep -F "run: bash \"\$GITHUB_ACTION_PATH/run.sh\"" "$ACTION"

check "workflow wakes on body edits" 0 "types: [opened, edited, reopened, synchronize]" \
  grep -F "types: [opened, edited, reopened, synchronize]" "$WORKFLOW"
check "workflow is pull_request-only" 1 "" \
  grep -E '^  (push|pull_request_target|workflow_dispatch|schedule|issue_comment):' \
  "$WORKFLOW"
check "workflow grants read-only pull request access" 0 "pull-requests: read" \
  grep -F "pull-requests: read" "$WORKFLOW"

summary
