#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
source "$ROOT/test/harness.sh"
# shellcheck source=lib/ruling.sh
source "$ROOT/lib/ruling.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Pure decisions. Epochs are arbitrary fixed numbers — no wall clock anywhere.
# ---------------------------------------------------------------------------

check "needs-ruling is stale-exempt" 0 "EXEMPT" ruling_stale_exempt <<< $'claimed\nneeds-ruling'
check "a flag-free issue sweeps normally" 0 "SWEEP" ruling_stale_exempt <<< $'claimed'

L=100000 # the labeled event, in every window case below

check "escalation 14 minutes before the flag accompanies it" 0 "ACCOMPANIED" \
  ruling_bare_decision setter "$L" <<<"setter $((L - 840))"
check "escalation exactly 15 minutes before still accompanies (no earlier than)" 0 "ACCOMPANIED" \
  ruling_bare_decision setter "$L" <<<"setter $((L - 900))"
check "escalation after the flag accompanies it" 0 "ACCOMPANIED" \
  ruling_bare_decision setter "$L" <<<"setter $((L + 60))"
check "escalation 16 minutes before is bare" 0 "BARE" \
  ruling_bare_decision setter "$L" <<<"setter $((L - 960))"
check "somebody else's comment does not satisfy the contract" 0 "BARE" \
  ruling_bare_decision setter "$L" <<<"bystander $((L - 60))"
check "no comment at all is bare" 0 "BARE" \
  ruling_bare_decision setter "$L" </dev/null

# Re-flag: every fact anchors to the NEWEST labeled event, so an escalation
# that accompanied the first flag does not satisfy the second.
L2=$((L + 7200))
newest="$(ruling_newest_flag <<< "$(printf 'setter\t2020-01-01T00:00:00Z\nsetter\t2020-01-01T02:00:00Z\n')")"
check "the newest labeled event wins" 0 "" test "$newest" = "$(printf 'setter\t2020-01-01T02:00:00Z')"
check "first-flag escalation does not satisfy a re-flag" 0 "BARE" \
  ruling_bare_decision setter "$L2" <<<"setter $((L - 60))"

check "no marked comment yet posts" 0 "POST" ruling_bare_comment_needed "$L" ""
check "a marked comment newer than the event skips" 0 "SKIP" ruling_bare_comment_needed "$L" $((L + 300))
check "a marked comment from an earlier flag episode re-posts" 0 "POST" ruling_bare_comment_needed "$L2" $((L + 300))

NOW=2000000000
check "8 days of silence nudges" 0 "NUDGE" ruling_nudge_decision "$NOW" $((NOW - 8 * 86400))
check "6 days of silence holds" 0 "KEEP" ruling_nudge_decision "$NOW" $((NOW - 6 * 86400))
check "exactly 7 days holds — strictly past the horizon, like the stale sweep" 0 "KEEP" \
  ruling_nudge_decision "$NOW" $((NOW - 7 * 86400))
check "fresh activity holds" 0 "KEEP" ruling_nudge_decision "$NOW" $((NOW - 60))

# -- the ladder's rungs (#50 D13): anchored to the labeled event ------------

check "11h59m is rung 0" 0 "RUNG0" ruling_deadline_decision "$NOW" $((NOW - 12 * 3600 + 60))
check "exactly 12h starts the rung — at means at, unlike the nudge horizon" 0 "RUNG12" \
  ruling_deadline_decision "$NOW" $((NOW - 12 * 3600))
check "12h01m is rung 12" 0 "RUNG12" ruling_deadline_decision "$NOW" $((NOW - 12 * 3600 - 60))
check "23h59m is still rung 12" 0 "RUNG12" ruling_deadline_decision "$NOW" $((NOW - 24 * 3600 + 60))
check "exactly 24h starts the last rung" 0 "RUNG24" ruling_deadline_decision "$NOW" $((NOW - 24 * 3600))
check "25h is rung 24 — past-24h has no fourth timer" 0 "RUNG24" \
  ruling_deadline_decision "$NOW" $((NOW - 25 * 3600))

# -- the Default: line, parsed for wording only (#50 D14) -------------------

check "a timed default parses to its deadline" 0 "DEADLINE 2026-07-23T21:00Z" \
  ruling_default_decision <<<$'Blocked:  x\nDefault:  A at 2026-07-23T21:00Z if no ruling'
check "a bold default line with seconds parses" 0 "DEADLINE 2026-07-23T21:00:30Z" \
  ruling_default_decision <<<$'**Default:**  A at 2026-07-23T21:00:30Z if quiet'
check "none is a hard block" 0 "HARDBLOCK" ruling_default_decision <<<$'Default:  none — hard block'
check "prose is unparseable, never guessed" 0 "UNPARSEABLE" \
  ruling_default_decision <<<$'Default:  when it feels right'
check "a missing default line is unparseable" 0 "UNPARSEABLE" \
  ruling_default_decision <<<$'Options: A\nRecommend: A.'
check "a timestamp off the default line is somebody's prose" 0 "UNPARSEABLE" \
  ruling_default_decision <<<$'the deadline 2026-07-23T21:00Z came up above\nDefault:  soonish'

rows="$(printf 'setter %s https://x/first\nsetter %s https://x/late\nbystander %s https://x/other\nsetter %s https://x/early-out\n' \
  "$((L - 300))" "$((L + 600))" "$((L - 60))" "$((L - 5000))")"
check "the nudge links the earliest in-window escalation by the setter" 0 "https://x/first" \
  ruling_escalation_url setter "$L" <<<"$rows"
check "no qualifying escalation yields no link" 0 "" \
  ruling_escalation_url setter "$L" <<<"bystander $((L - 60)) https://x/other"
check "the url survives the base64 body column" 0 "https://x/first" \
  ruling_escalation_url setter "$L" <<<"setter $((L - 300)) https://x/first $(printf 'Options: A' | base64)"
check "the row carries the body for the shape check" 0 "https://x/first $(printf 'Options: A' | base64)" \
  ruling_escalation_row setter "$L" <<<"setter $((L - 300)) https://x/first $(printf 'Options: A' | base64)"

# -- the escalation comment's shape (#50 D12): presence only, line-anchored --

TPL=$'🧭 needs-ruling — fixture decision\nOptions:  A — on   B — off\nRecommend: A, because the drill says so.\nBlocked:  the fixture stops; everything else continues\nDefault:  A at 2026-07-23T21:00Z if no ruling'
TPL_BOLD=$'🧭 needs-ruling — fixture decision\n**Options:**  A — on   B — off\n**Recommend:** A, because the drill says so.\n**Blocked:**  the fixture stops\n**Default:**  none — hard block'

check "all four field labels present is shaped" 0 "SHAPED" ruling_shape_decision <<<"$TPL"
check "bold field labels are shaped — the live escalations write them bold" 0 "SHAPED" \
  ruling_shape_decision <<<"$TPL_BOLD"
check "labels inside a details fold are shaped — line-anchored, not fold-aware" 0 "SHAPED" \
  ruling_shape_decision <<<$'<details><summary>fold</summary>\nOptions: A — x   B — y\nRecommend: A.\nBlocked: nothing\nDefault: none\n</details>'
check "leading whitespace is tolerated" 0 "SHAPED" \
  ruling_shape_decision <<<$'  Options: A   B\n  Recommend: A.\n  Blocked: x\n  Default: none'
check "one missing label is named" 0 "MALFORMED Recommend:" \
  ruling_shape_decision <<<$'Options:  A — x   B — y\nBlocked:  z\nDefault:  none — hard block'
check "two missing labels are both named" 0 "MALFORMED Recommend: Default:" \
  ruling_shape_decision <<<$'Options:  A — x   B — y\nBlocked:  z'
check "labels only mid-sentence are malformed — line-anchoring is the rule" 0 \
  "MALFORMED Options: Recommend: Blocked: Default:" \
  ruling_shape_decision <<<$'we should Options: A or B, and I Recommend: A; Blocked: no; Default: none'
check "an empty body is missing everything" 0 "MALFORMED Options: Recommend: Blocked: Default:" \
  ruling_shape_decision </dev/null

# -- escalation selection: best-shaped wins, earliest breaks ties (#226) ----
# The crew#293 incident: a whole-round reply and the escalation land seconds
# apart inside one window, the reply earlier. Earliest-wins graded the reply.
# b64 here mirrors jq's @base64 — unwrapped, or the TSV rows would split.

b64enc() { printf '%s' "$1" | base64 | tr -d '\n'; }
ROUND_REPLY=$'🔧 addressing round on head 86c35f14 — every point answered below'
PARTIAL=$'Options:  A — x   B — y\nBlocked:  z'

replay="$(printf 'setter %s https://x/reply %s\nsetter %s https://x/escalation %s\n' \
  "$((L - 40))" "$(b64enc "$ROUND_REPLY")" "$((L - 7))" "$(b64enc "$TPL")")"
check "crew#293 replay: the complete escalation is selected over the earlier round reply" 0 \
  "https://x/escalation $(b64enc "$TPL")" ruling_escalation_row setter "$L" <<<"$replay"
sel="$(ruling_escalation_row setter "$L" <<<"$replay")"
check "crew#293 replay: the selected body grades SHAPED" 0 "SHAPED" \
  ruling_shape_decision <<<"$(base64 -d <<<"${sel#* }")"
check "the nudge's link follows the same selection" 0 "https://x/escalation" \
  ruling_escalation_url setter "$L" <<<"$replay"
check "the rung wording reads Default: from the selected body" 0 "DEADLINE 2026-07-23T21:00Z" \
  ruling_default_decision <<<"$(base64 -d <<<"${sel#* }")"

check "escalation-then-follow-up still selects the escalation" 0 \
  "https://x/escalation $(b64enc "$TPL")" ruling_escalation_row setter "$L" <<<"$(
    printf 'setter %s https://x/escalation %s\nsetter %s https://x/followup %s\n' \
      "$((L - 300))" "$(b64enc "$TPL")" "$((L - 60))" "$(b64enc 'thanks — clarified above')")"

check "a complete escalation beats an earlier partial" 0 \
  "https://x/complete $(b64enc "$TPL")" ruling_escalation_row setter "$L" <<<"$(
    printf 'setter %s https://x/partial %s\nsetter %s https://x/complete %s\n' \
      "$((L - 300))" "$(b64enc "$PARTIAL")" "$((L - 60))" "$(b64enc "$TPL")")"
check "a complete escalation beats a later partial" 0 \
  "https://x/complete $(b64enc "$TPL")" ruling_escalation_row setter "$L" <<<"$(
    printf 'setter %s https://x/complete %s\nsetter %s https://x/partial %s\n' \
      "$((L - 300))" "$(b64enc "$TPL")" "$((L - 60))" "$(b64enc "$PARTIAL")")"

check "equal full scores break to the earliest" 0 \
  "https://x/one $(b64enc "$TPL")" ruling_escalation_row setter "$L" <<<"$(
    printf 'setter %s https://x/one %s\nsetter %s https://x/two %s\n' \
      "$((L - 300))" "$(b64enc "$TPL")" "$((L - 60))" "$(b64enc "$TPL_BOLD")")"
check "all-zero scores still break to the earliest" 0 "https://x/first" \
  ruling_escalation_url setter "$L" <<<"$(
    printf 'setter %s https://x/first\nsetter %s https://x/second\n' \
      "$((L - 300))" "$((L - 60))")"

check "an out-of-window all-four row is never selected" 0 \
  "https://x/in $(b64enc "$PARTIAL")" ruling_escalation_row setter "$L" <<<"$(
    printf 'setter %s https://x/out %s\nsetter %s https://x/in %s\n' \
      "$((L - 5000))" "$(b64enc "$TPL")" "$((L - 60))" "$(b64enc "$PARTIAL")")"
check "an out-of-window all-four row cannot turn an empty result non-empty" 0 "" \
  ruling_escalation_row setter "$L" <<<"setter $((L - 5000)) https://x/out $(b64enc "$TPL")"
check "another actor's all-four row is never selected" 0 "" \
  ruling_escalation_row setter "$L" <<<"bystander $((L - 60)) https://x/other $(b64enc "$TPL")"

check "a garbage body column scores 0 and never errors" 0 \
  "https://x/good $(b64enc "$PARTIAL")" ruling_escalation_row setter "$L" <<<"$(
    printf 'setter %s https://x/garbage !!!not-base64!!!\nsetter %s https://x/good %s\n' \
      "$((L - 300))" "$((L - 60))" "$(b64enc "$PARTIAL")")"
check "a garbage-only candidate is still a legal selection" 0 \
  "https://x/garbage !!!not-base64!!!" \
  ruling_escalation_row setter "$L" <<<"setter $((L - 300)) https://x/garbage !!!not-base64!!!"

# shellcheck disable=SC2016 # the literal $field is the assertion — one spelling, unexpanded
check "the field matcher has exactly one spelling in lib/ruling.sh" 0 "1" \
  grep -cF '(\*\*)?$field' "$ROOT/lib/ruling.sh"

# ---------------------------------------------------------------------------
# The orchestrator, against a recording gh stub. The stub serves fixture JSON
# per endpoint (missing file = unreadable read), applies the caller's --jq
# with real jq, appends posted comments back into the fixture (so a second
# sweep sees the first sweep's writes, exactly like the live board), and
# records every `gh issue edit` — which must never happen from this code.
# ---------------------------------------------------------------------------

REPO=owner/repo
log() { printf 'test-sweep: %s\n' "$*"; }
run() { "$@"; }

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

gh() {
  if [ "$1" = api ]; then
    shift
    local jqexpr="" endpoint="" file
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) jqexpr="$2"; shift ;;
        -*) ;;
        *) [ -n "$endpoint" ] || endpoint="$1" ;;
      esac
      shift
    done
    file="$TMP/$(printf '%s' "$endpoint" | tr '/' '_').json"
    [ -f "$file" ] || return 1
    if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$file"; else cat "$file"; fi
  elif [ "$1" = issue ] && [ "$2" = comment ]; then
    local n="$3" body="" file
    shift 3
    while [ $# -gt 0 ]; do
      case "$1" in --body) body="$2"; shift ;; esac
      shift
    done
    printf '%s\n----\n' "$body" >>"$TMP/posted-$n"
    file="$TMP/repos_${REPO%%/*}_${REPO#*/}_issues_${n}_comments.json"
    [ -f "$file" ] || printf '[]\n' >"$file"
    jq --arg b "$body" --arg at "$(iso "$NOW")" \
      '. + [{"user":{"login":"sweep-bot"},"created_at":$at,"html_url":"https://x/posted","body":$b}]' \
      "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  elif [ "$1" = issue ] && [ "$2" = edit ]; then
    printf '%s\n' "$*" >>"$TMP/edits"
  fi
}

posts() { [ -f "$TMP/posted-$1" ] && grep -c '^----$' "$TMP/posted-$1" || echo 0; }
timeline_file() { printf '%s/repos_owner_repo_issues_%s_timeline.json' "$TMP" "$1"; }
comments_file() { printf '%s/repos_owner_repo_issues_%s_comments.json' "$TMP" "$1"; }

# -- bare flag, swept twice: exactly one comment -----------------------------
T=$((NOW - 3600))
jq -n --arg at "$(iso "$T")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 9)"
printf '[]\n' >"$(comments_file 9)"
check "a bare flag is commented on" 0 "ruling flag is bare" reconcile_ruling 9 "$T" "$NOW"
check "...and the sweep never posted twice" 0 "" reconcile_ruling 9 "$T" "$NOW"
check "one bare comment across two sweeps" 0 "1" posts 9
check "the bare comment carries its marker" 0 "" \
  grep -qF '<!-- ceremony:needs-ruling-bare -->' "$TMP/posted-9"
check "the bare comment names the missing contract" 0 "" \
  grep -q 'question' "$TMP/posted-9"
check "a bare flag draws no shape or rung comment — bare stops here" 1 "" \
  grep -qE 'needs-ruling-(shape|rung)' "$TMP/posted-9"

# -- accompanied, conforming (bold, the live spelling): silence --------------
jq -n --arg at "$(iso "$T")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 10)"
jq -n --arg at "$(iso "$((T - 840))")" --arg b "$TPL_BOLD" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc","body":$b}]' \
  >"$(comments_file 10)"
reconcile_ruling 10 "$T" "$NOW" >/dev/null
check "an accompanied conforming flag posts nothing" 0 "0" posts 10

# -- re-flag: judged on its own escalation, marker scoped per event ----------
T1=$((NOW - 86400)) T2=$((NOW - 7200))
jq -n --arg t1 "$(iso "$T1")" --arg t2 "$(iso "$T2")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$t1},
    {"event":"unlabeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$t2},
    {"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$t2}]' \
  >"$(timeline_file 11)"
jq -n --arg esc "$(iso "$((T1 - 60))")" --arg marked "$(iso "$((T1 + 300))")" \
  '[{"user":{"login":"setter"},"created_at":$esc,"html_url":"https://x/esc1","body":"the first escalation"},
    {"user":{"login":"sweep-bot"},"created_at":$marked,"html_url":"https://x/bare1","body":"<!-- ceremony:needs-ruling-bare -->\nolder episode"}]' \
  >"$(comments_file 11)"
reconcile_ruling 11 "$T2" "$NOW" >/dev/null
check "a re-flag is re-checked against its own escalation" 0 "1" posts 11

# -- nudge: fires past 7 quiet days, links the escalation, resets itself -----
# The escalation is conforming and the rung markers are pre-seeded (by 8 days
# in, both rungs fired long ago — the realistic board), so the nudge's
# behavior is observed alone.
T0=$((NOW - 8 * 86400))
jq -n --arg at "$(iso "$T0")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 12)"
jq -n --arg at "$(iso "$((T0 - 60))")" --arg b "$TPL" \
  --arg r12 "$(iso "$((T0 + 13 * 3600))")" --arg r24 "$(iso "$((T0 + 25 * 3600))")" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc12","body":$b},
    {"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nrung"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nrung"}]' \
  >"$(comments_file 12)"
check "8 quiet days nudge" 0 "ruling nudge" reconcile_ruling 12 "$T0" "$NOW"
check "one nudge posted" 0 "1" posts 12
check "the nudge links the escalation comment" 0 "" grep -qF 'https://x/esc12' "$TMP/posted-12"
check "the nudge addresses the decider" 0 "" grep -qF '@danmt' "$TMP/posted-12"
check "the nudge does not tag the flag-setter" 1 "" grep -qF '@setter' "$TMP/posted-12"
check "the nudge carries no marker — the comment itself resets the window" 1 "" \
  grep -qF "$RULING_BARE_MARKER" "$TMP/posted-12"
# The reset, through the surfaces' own activity computation: the nudge the
# stub appended is the newest comment, so the recomputed last-activity is NOW.
newest_at="$(jq -r 'map(.created_at) | max' "$(comments_file 12)")"
check "the posted nudge is now the newest activity" 0 "" \
  test "$(date -d "$newest_at" +%s)" = "$NOW"
reconcile_ruling 12 "$(date -d "$newest_at" +%s)" "$NOW" >/dev/null
check "a sweep right after the nudge holds its silence" 0 "1" posts 12

# -- 6 quiet days: silence. The flag itself is fresh (label churn is not
# activity, so a quiet item can be freshly flagged): rung 0, no nudge. ------
jq -n --arg at "$(iso "$((NOW - 3600))")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 13)"
jq -n --arg at "$(iso "$((NOW - 3660))")" --arg b "$TPL" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc13","body":$b}]' \
  >"$(comments_file 13)"
reconcile_ruling 13 $((NOW - 6 * 86400)) "$NOW" >/dev/null
check "6 quiet days do not nudge, and a fresh flag sits on rung 0" 0 "0" posts 13

# -- unreadable timeline: nothing happens ------------------------------------
check "an unreadable timeline invents no verdict" 0 "timeline unreadable" \
  reconcile_ruling 14 "$T" "$NOW"
check "...and posts nothing" 0 "0" posts 14

# -- malformed escalation, rung 0: the shape comment, exactly once -----------
T15=$((NOW - 3600))
jq -n --arg at "$(iso "$T15")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 15)"
jq -n --arg at "$(iso "$((T15 - 60))")" \
  --arg b $'Options:  A — x   B — y\nBlocked:  z\nDefault:  none — hard block' \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc15","body":$b}]' \
  >"$(comments_file 15)"
check "a malformed escalation is commented on" 0 "escalation malformed" \
  reconcile_ruling 15 "$T15" "$NOW"
reconcile_ruling 15 "$T15" "$NOW" >/dev/null
check "one shape comment across two sweeps" 0 "1" posts 15
check "the shape comment names exactly the missing label" 0 "" \
  grep -qF 'missing required field labels: **Recommend:**' "$TMP/posted-15"
check "the shape comment links the escalation" 0 "" grep -qF 'https://x/esc15' "$TMP/posted-15"
check "the shape comment quotes the template location" 0 "" \
  grep -qF 'BUILDER.md#the-ruling-ask' "$TMP/posted-15"
check "no bare comment beside the shape comment" 1 "" \
  grep -qF "$RULING_BARE_MARKER" "$TMP/posted-15"
check "the shape comment carries its marker" 0 "" \
  grep -qF "$RULING_SHAPE_MARKER" "$TMP/posted-15"

# -- 13h in, activity minutes old: the 12h rung fires anyway (D14) -----------
T16=$((NOW - 13 * 3600))
jq -n --arg at "$(iso "$T16")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 16)"
jq -n --arg at "$(iso "$((T16 - 60))")" --arg b "$TPL_BOLD" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc16","body":$b}]' \
  >"$(comments_file 16)"
check "the 12h rung fires despite recent activity — rungs never reset" 0 "12h rung" \
  reconcile_ruling 16 $((NOW - 60)) "$NOW"
reconcile_ruling 16 $((NOW - 60)) "$NOW" >/dev/null
check "one 12h rung comment, once per episode" 0 "1" posts 16
check "the rung comment is addressed to the flag-setter" 0 "" grep -qF '@setter' "$TMP/posted-16"
check "the rung comment names the hard block" 0 "" grep -qF 'Default: none' "$TMP/posted-16"
check "no nudge rode along — activity is recent and the nudge does reset" 1 "" \
  grep -qF '@danmt' "$TMP/posted-16"
check "the rung comment carries its marker" 0 "" \
  grep -qF "$RULING_RUNG12_MARKER" "$TMP/posted-16"

# -- the ladder walked on the cron: 12h rung at 13h, 24h rung at 25h ---------
L17=$((NOW - 25 * 3600))
jq -n --arg at "$(iso "$L17")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 17)"
jq -n --arg at "$(iso "$((L17 - 60))")" --arg b "$TPL" \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc17","body":$b}]' \
  >"$(comments_file 17)"
reconcile_ruling 17 "$L17" $((L17 + 13 * 3600)) >/dev/null
check "a sweep at 13h posts the 12h rung" 0 "1" posts 17
check "the rung comment names the stated deadline" 0 "" \
  grep -qF '2026-07-23T21:00Z' "$TMP/posted-17"
check "a sweep at 25h posts the 24h rung — one comment per rung" 0 "24h rung" \
  reconcile_ruling 17 "$L17" "$NOW"
check "two rung comments total" 0 "2" posts 17
check "the 24h comment names triage's past-24h authority" 0 "" \
  grep -qF 'triage picks the option' "$TMP/posted-17"
reconcile_ruling 17 "$L17" "$NOW" >/dev/null
check "...and never a third within the episode" 0 "2" posts 17

# -- first observed past 24h: the missed 12h moment is not paged after the
# fact — the 24h comment carries the whole remaining duty ---------------------
T18=$((NOW - 25 * 3600))
jq -n --arg at "$(iso "$T18")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 18)"
jq -n --arg at "$(iso "$((T18 - 60))")" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z\nDefault:  when it feels right' \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc18","body":$b}]' \
  >"$(comments_file 18)"
reconcile_ruling 18 "$T18" "$NOW" >/dev/null
check "a rung first observed past 24h pages once, not retroactively" 0 "1" posts 18
check "only the 24h comment fired" 1 "" grep -qF "$RULING_RUNG12_MARKER" "$TMP/posted-18"
check "the unparseable default is reported, not guessed" 0 "" \
  grep -qF 'unparseable' "$TMP/posted-18"

# -- a re-flag climbs its own ladder: old rung markers belong to the old
# episode -------------------------------------------------------------------
TA=$((NOW - 3 * 86400)) TB=$((NOW - 13 * 3600))
jq -n --arg ta "$(iso "$TA")" --arg tb "$(iso "$TB")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$ta},
    {"event":"unlabeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$tb},
    {"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$tb}]' \
  >"$(timeline_file 19)"
jq -n --arg esc "$(iso "$((TB - 60))")" --arg b "$TPL" \
  --arg r12 "$(iso "$((TA + 13 * 3600))")" --arg r24 "$(iso "$((TA + 25 * 3600))")" \
  '[{"user":{"login":"sweep-bot"},"created_at":$r12,"html_url":"https://x/r12","body":"<!-- ceremony:needs-ruling-rung12 -->\nold episode"},
    {"user":{"login":"sweep-bot"},"created_at":$r24,"html_url":"https://x/r24","body":"<!-- ceremony:needs-ruling-rung24 -->\nold episode"},
    {"user":{"login":"setter"},"created_at":$esc,"html_url":"https://x/esc19","body":$b}]' \
  >"$(comments_file 19)"
reconcile_ruling 19 "$TB" "$NOW" >/dev/null
check "a re-flag climbs its own ladder — old rung markers do not stick" 0 "1" posts 19
check "the re-flag's rung comment is the 12h rung" 0 "" \
  grep -qF "$RULING_RUNG12_MARKER" "$TMP/posted-19"

# -- unreadable comment list: nothing happens --------------------------------
jq -n --arg at "$(iso "$T")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 20)"
check "an unreadable comment list invents no verdict" 0 "comments unreadable" \
  reconcile_ruling 20 "$T" "$NOW"
check "...and it posts nothing" 0 "0" posts 20

# -- malformed AND on a rung: the shape is owed and the ladder still climbs --
T21=$((NOW - 13 * 3600))
jq -n --arg at "$(iso "$T21")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 21)"
jq -n --arg at "$(iso "$((T21 - 60))")" \
  --arg b $'Options:  A — x   B — y\nRecommend: A, because x.\nBlocked:  z' \
  '[{"user":{"login":"setter"},"created_at":$at,"html_url":"https://x/esc21","body":$b}]' \
  >"$(comments_file 21)"
reconcile_ruling 21 "$T21" "$NOW" >/dev/null
check "a malformed escalation still climbs the ladder — two comments" 0 "2" posts 21
check "the shape half fired" 0 "" grep -qF "$RULING_SHAPE_MARKER" "$TMP/posted-21"
check "the rung half fired" 0 "" grep -qF "$RULING_RUNG12_MARKER" "$TMP/posted-21"
reconcile_ruling 21 "$T21" "$NOW" >/dev/null
check "both halves are once-per-episode" 0 "2" posts 21

# ---------------------------------------------------------------------------
# The ruling clock (#534): the setter's own comments are not activity, and the
# clock floors at the current `labeled` event. Pure first, then end to end
# through a caller — because the clock is the CALLER's to compute (D4), a
# fixture that hands reconcile_ruling a hand-picked epoch cannot see this rule
# at all.
# ---------------------------------------------------------------------------

CL=2026-08-20T00:00:00Z
check "the setter's own comment is not activity" 0 "$CL" \
  ruling_clock_at setter "$CL" <<<"$(printf 'setter\t2026-08-26T00:00:00Z\n')"
check "somebody else's comment is" 0 "2026-08-26T00:00:00Z" \
  ruling_clock_at setter "$CL" <<<"$(printf 'danmt\t2026-08-26T00:00:00Z\n')"
check "one non-setter comment carries a thread of the setter's" 0 "2026-08-22T00:00:00Z" \
  ruling_clock_at setter "$CL" <<<"$(printf 'setter\t2026-08-21T00:00:00Z\ndanmt\t2026-08-22T00:00:00Z\nsetter\t2026-08-26T00:00:00Z\n')"
check "no comments at all floors at the labeled event" 0 "$CL" \
  ruling_clock_at setter "$CL" </dev/null
check "a comment older than the flag cannot lower the clock" 0 "$CL" \
  ruling_clock_at setter "$CL" <<<"$(printf 'danmt\t2020-01-01T00:00:00Z\n')"
# The empty-login column is how the PR surface feeds reviews and commits
# through: comment-shaped exclusion only (D5).
check "an unattributed row always counts — reviews and commits are not filtered" 0 \
  "2026-08-30T00:00:00Z" \
  ruling_clock_at setter "$CL" <<<"$(printf '\t2026-08-30T00:00:00Z\nsetter\t2026-09-01T00:00:00Z\n')"
# A re-flag by a different actor changes who is excluded, from that event on —
# the rule is the episode's identity, never a role or a login list.
check "a re-flag by another actor moves the exclusion" 0 "2026-08-26T00:00:00Z" \
  ruling_clock_at danmt "$CL" <<<"$(printf 'setter\t2026-08-26T00:00:00Z\ndanmt\t2026-08-27T00:00:00Z\n')"
check "an unreadable setter drops nobody — it never widens to the whole board" 0 \
  "2026-08-26T00:00:00Z" \
  ruling_clock_at "" "$CL" <<<"$(printf 'setter\t2026-08-26T00:00:00Z\n')"

# A caller, exactly as both reconcilers are: read the episode's facts and the
# comments, compute the clock with the shared rule, and only then sweep.
sweep() { # $1 issue number, $2 now (default $NOW)
  local row comments
  row="$(ruling_flag_row "$1")" || return $?
  comments="$(gh api --paginate "repos/$REPO/issues/$1/comments" \
    --jq '.[] | [.user.login, .created_at] | @tsv')"
  reconcile_ruling "$1" \
    "$(date -d "$(ruling_clock_at "${row%%$'\t'*}" "${row##*$'\t'}" <<<"$comments")" +%s)" \
    "${2:-$NOW}"
}
# The nudge alone, isolated from whatever else a pass posted — the WHOLE
# record between the stub's separators, not the tail from the addressee line
# down: a marker sits ABOVE its body, so a record starting at the addressee is
# a marker pin that can never see the marker it is pinning.
nudge_record() {
  awk '/^----$/ { if (index(buf, "a ruling on this item has been pending")) printf "%s", buf
                  buf = ""; next }
       { buf = buf $0 "\n" }' "$TMP/posted-$1"
}
nudges() { grep -c 'a ruling on this item has been pending' "$TMP/posted-$1" || true; }

# -- the setter's re-reads no longer silence the clock (D1, D2) --------------
# crew#207's shape: 8 days flagged, a conforming escalation at the flag, and
# the setter's own re-reads at days 2, 4 and 6. Shipped, each re-read bought
# another 7 quiet days and the decider was never paged.
#
# The rung markers are NOT pre-seeded here, unlike the #12 fixture above, and
# that is the fixture saying something rather than being careless: a seeded
# rung marker is a sweep comment inside the window, and a machine comment does
# still reset this clock (D8). Seeding one would move the very number this
# case exists to measure. So the 24h rung fires in the same pass, and the
# assertions are about the nudge specifically.
S0=$((NOW - 8 * 86400))
jq -n --arg at "$(iso "$S0")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 30)"
setter_thread() { # $1 issue, $2 the flag epoch, $3 an extra "login epoch" pair or ""
  # The optional row's two fields are only computed when the row is asked for.
  # Expanded unconditionally, `iso ""` reaches `date -d @` and prints its
  # complaint to stderr; the empty result then happens to be what the caller
  # meant, so the suite stayed green while emitting a diagnostic on the
  # helper's primary path.
  local other="" other_at=""
  if [ -n "${3:-}" ]; then
    other="${3%% *}"
    other_at="$(iso "${3##* }")"
  fi
  jq -n --arg esc "$(iso "$(($2 - 60))")" --arg b "$TPL" \
    --arg d2 "$(iso "$(($2 + 2 * 86400))")" \
    --arg d4 "$(iso "$(($2 + 4 * 86400))")" \
    --arg d6 "$(iso "$(($2 + 6 * 86400))")" \
    --arg other "$other" --arg other_at "$other_at" \
    '[{"user":{"login":"setter"},"created_at":$esc,"html_url":"https://x/esc","body":$b},
      {"user":{"login":"setter"},"created_at":$d2,"html_url":"https://x/rr2","body":"re-read: the default still holds"},
      {"user":{"login":"setter"},"created_at":$d4,"html_url":"https://x/rr4","body":"re-read: still holds"},
      {"user":{"login":"setter"},"created_at":$d6,"html_url":"https://x/rr6","body":"re-read: still holds"}]
     + (if $other == "" then [] else
         [{"user":{"login":$other},"created_at":$other_at,"html_url":"https://x/other","body":"looking"}] end)' \
    >"$(comments_file "$1")"
}
# The builder is pinned before the sweep that reads it. Every must-nudge row
# below would be satisfied by an empty comments file — a thread with nothing to
# exclude nudges for the wrong reason and looks the same in a green run — so
# the fixture's contents are asserted, not assumed, and the build is asserted
# silent so a re-introduced unguarded expansion reds a row instead of scrolling
# past.
setter_noise="$(setter_thread 30 "$S0" "" 2>&1)"
check "the setter-only thread builds with no shell diagnostic" 0 "[]" \
  printf '[%s]' "$setter_noise"
check "...and its fixture holds exactly four comments, all the setter's" 0 "[4 setter]" \
  printf '[%s]' \
  "$(jq -r '"\(length) \([.[].user.login] | unique | join(","))"' "$(comments_file 30)")"
check "...being the escalation and the day-2, day-4 and day-6 re-reads" 0 \
  "[https://x/esc,https://x/rr2,https://x/rr4,https://x/rr6]" \
  printf '[%s]' "$(jq -r '[.[].html_url] | join(",")' "$(comments_file 30)")"
sweep 30 >/dev/null
check "the setter's own re-reads do not hold off the nudge" 0 "1" nudges 30
check "...and the days figure is measured from the labeled event, not the last re-read" 0 \
  "" grep -qF 'no activity for 8 days' <<<"$(nudge_record 30)"
check "...naming the setter without tagging them" 1 "" grep -qF '@setter' <<<"$(nudge_record 30)"
# D3, pinned on the body that was actually posted: no marker of any kind.
check "the nudge body carries no marker at all" 1 "" grep -qF '<!--' <<<"$(nudge_record 30)"
# The self-rate-limit survives D1 because the sweep is never the setter: the
# nudge it posted is the newest comment that counts, so the window closes.
sweep 30 >/dev/null
check "a second sweep straight after the nudge posts nothing" 0 "1" nudges 30
# And it is a WINDOW, not a once-per-episode gate — the property the missing
# marker buys and the one a marker would silently take away (D3). Eight more
# quiet days and the same episode is paged again.
sweep 30 $((NOW + 8 * 86400)) >/dev/null
check "eight more quiet days page the same episode again" 0 "2" nudges 30

# -- one non-setter comment still resets it (D1) -----------------------------
jq -n --arg at "$(iso "$S0")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 31)"
setter_thread 31 "$S0" "danmt $((S0 + 6 * 86400))"
# The guard's other side: asked for, the optional row is really written.
check "the non-setter call adds a fifth comment, by the other login" 0 "[5 danmt]" \
  printf '[%s]' "$(jq -r '"\(length) \(.[-1].user.login)"' "$(comments_file 31)")"
sweep 31 >/dev/null
check "the decider's own comment at day 6 holds the nudge" 0 "0" nudges 31

# -- the floor (D2): with the setter's comments gone, most flagged items have
# no counting comment at all, and the shipped clock then fell back to the
# item's `created_at` and read an old item as quiet since long before the
# ruling existed. Here the floor IS the answer — `created_at` is not an input
# to this function at all. The whole composition, an item created 90 days ago
# and flagged an hour ago, is driven in test/issueflow-reconcile.test.sh,
# where the caller is the thing that used to supply that fallback. ----------
jq -n --arg at "$(iso "$((NOW - 3600))")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 32)"
printf '[]\n' >"$(comments_file 32)"
sweep 32 >/dev/null
check "an hour-old flag with no comments does not nudge" 0 "0" nudges 32
check "...though the bare-flag check still speaks, which is not this clock's business" 0 "" \
  grep -qF "$RULING_BARE_MARKER" "$TMP/posted-32"
jq -n --arg at "$(iso "$S0")" \
  '[{"event":"labeled","label":{"name":"needs-ruling"},"actor":{"login":"setter"},"created_at":$at}]' \
  >"$(timeline_file 33)"
printf '[]\n' >"$(comments_file 33)"
sweep 33 >/dev/null
check "the same item flagged 8 days ago nudges once" 0 "1" nudges 33
check "...reporting 8 days, the age of the flag and not of the issue" 0 "" \
  grep -qF 'no activity for 8 days' <<<"$(nudge_record 33)"

# -- the episode facts, and what an unreadable one costs ---------------------
check "the flag row is the newest episode's actor and time" 0 "" \
  test "$(ruling_flag_row 33)" = "$(printf 'setter\t%s' "$(iso "$S0")")"
check "an unreadable timeline is exit 1, distinguishable from an absent event" 1 "" \
  ruling_flag_row 999
printf '[]\n' >"$(timeline_file 34)"
check "a readable timeline with no labeled event is exit 2" 2 "" ruling_flag_row 34

# -- across every scenario above: not one label write ------------------------
check "the ruling sweep never wrote a label" 1 "" test -f "$TMP/edits"

# Grep-level pin for #50 D9: no mutation call in the sweep code names the
# flag. The only writes reconcile_ruling makes are comments.
check "no add/remove-label mutation names the ruling flag" 1 "" \
  grep -rEn -- '(add|remove)-label[^"]*needs-ruling' "$ROOT/actions" "$ROOT/lib"

summary
