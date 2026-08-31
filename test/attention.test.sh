#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=lib/attention.sh
source "$ROOT/lib/attention.sh"

check "attention on an unassigned PR is malformed" 0 "MALFORMED_PR" \
  attention_target_decision pr 0
check "attention on an assigned PR is still malformed" 0 "MALFORMED_PR" \
  attention_target_decision pr 1
check "attention on an unassigned issue is malformed" 0 "MALFORMED_UNASSIGNED" \
  attention_target_decision issue 0
check "attention on an assigned issue is healthy" 0 "KEEP" \
  attention_target_decision issue 1
check "an unknown surface is rejected" 2 "" attention_target_decision discussion 0

check "a malformed PR target is commented" 0 "POST" \
  attention_comment_decision MALFORMED_PR ""
check "an unassigned issue target is commented without precedence" 0 "POST" \
  attention_comment_decision MALFORMED_UNASSIGNED ""
check "claimed-unassigned precedence suppresses the second comment" 0 "SUPPRESS" \
  attention_comment_decision MALFORMED_UNASSIGNED claimed-unassigned
# Not a duplicate of the case above, and the literal is synthetic on purpose.
# The helper under test asks PRESENCE — `lib/attention.sh:29` is
# `[ -n "$2" ]`, not a comparison — so this is the only case pinning that the
# verdict does not key on which precedence it was handed. Weaken that line to
# `[ "$2" = claimed-unassigned ]` and this case is the sole red; its neighbour
# stays green. A real board state here would name the thing the rule must not
# look at, which is how this case last read as redundant and acquired a
# retired state's name (#586).
check "a second, different precedence suppresses just the same" 0 "SUPPRESS" \
  attention_comment_decision MALFORMED_UNASSIGNED any-other-precedence
check "a healthy target stays silent" 0 "KEEP" \
  attention_comment_decision KEEP ""

check "the newest labeled event defines the episode" 0 "2026-08-03T12:00:00Z" \
  attention_newest_flag <<'EOF'
2026-08-03T10:00:00Z
2026-08-03T12:00:00Z
2026-08-03T11:00:00Z
EOF
check "the marker names the label episode" 0 \
  '<!-- ceremony:attention-malformed:2026-08-03T12:00:00Z -->' \
  attention_episode_marker 2026-08-03T12:00:00Z

# Diagnosis is the only write this library may own. Pin the absence of every
# label/assignee mutation spelling so a later refactor cannot quietly turn a
# report into a repair (#229 D2).
check "the attention library contains no issue/PR edit mutation" 1 "" \
  grep -E 'gh (issue|pr) edit|--(add|remove)-(label|assignee)' "$ROOT/lib/attention.sh"

summary
