#!/usr/bin/env bash
# The drill record — the script's emission (#313 D2). Sourced, never run.
#
# `drills/` is the record and this is the instrument's half of it: the
# rehearsal shape now has one producer. The hand-written shapes stay legal
# because *doors unchanged* and *WAIVED* are judgement, not automation.
#
# Every number in the emitted record comes from a measurement the run took.
# 0.2.0's record shipped a draft asserting a cleanup that had not happened
# (#135); nothing here is written from an intention.
#
# The probe count is one of those numbers. It was six literals in this file
# until the rc legs landed (#321), so growing the doctrine list meant editing
# every sentence that counted it and hoping none was missed. It comes from
# `drill/lib/probes.sh` now, which owns the list; source that first.
: "${DRILL_PROBE_COUNT:?drill/lib/record.sh: source drill/lib/probes.sh first — the doctrine list owns the probe count}"

# record_count_word — the probe count as the prose spells it. The record
# reads as English and the shape check greps that English, so the two need
# one speller between them; an unspelled count falls back to its digits
# rather than inventing a word.
record_count_word() {
  case "$DRILL_PROBE_COUNT" in
    6) printf 'six' ;;
    7) printf 'seven' ;;
    8) printf 'eight' ;;
    9) printf 'nine' ;;
    10) printf 'ten' ;;
    *) printf '%s' "$DRILL_PROBE_COUNT" ;;
  esac
}

# record_ctx <ctx-file> <key> — a `key<TAB>value` lookup.
record_ctx() {
  awk -F'\t' -v k="${2:?record_ctx: key required}" \
    '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }' "${1:?record_ctx: file required}"
}

# record_run_cell <scratch-repo> <run-id> <attempt> — a resolvable run link.
record_run_cell() {
  local repo="${1:?}" run="${2:-}" attempt="${3:-1}" cell
  # A probe that aborted before any run existed has no run to link, and a
  # link built around a run ID nobody holds is worse than the dash saying so.
  case "$run" in
    '' | '—')
      printf '%s\n' '—'
      return 0
      ;;
  esac
  cell="[$run](https://github.com/$repo/actions/runs/$run)"
  [ "$attempt" -le 1 ] || cell="$cell (attempt $attempt)"
  printf '%s\n' "$cell"
}

# record_probe_rows <scratch-repo> <probes-tsv> — the probe table's body.
record_probe_rows() {
  local repo="${1:?}" tsv="${2:?}"
  local n name run attempt verdict tb ta rb ra note mark
  while IFS=$'\t' read -r n name run attempt verdict tb ta rb ra note; do
    [ -n "${n:-}" ] || continue
    mark="✅"
    [ "$verdict" = PASS ] || mark="❌"
    printf '| %s | %s | %s | %s → %s | %s → %s | %s %s |\n' \
      "$n" "$name" "$(record_run_cell "$repo" "$run" "$attempt")" \
      "$tb" "$ta" "$rb" "$ra" "$mark" "$note"
  done <"$tsv"
}

# record_setup_rows <scratch-repo> <setup-tsv> — the runs that are not probes.
# A red run on a drill repo that the record does not explain is
# indistinguishable from a door that failed, so every run gets a line.
record_setup_rows() {
  local repo="${1:?}" tsv="${2:?}" run conclusion what
  while IFS=$'\t' read -r run conclusion what; do
    [ -n "${run:-}" ] || continue
    printf -- '- **%s** (%s) — %s\n' \
      "$(record_run_cell "$repo" "$run" 1)" "$conclusion" "$what"
  done <"$tsv"
}

# record_abort_path <record-path> — reserve the first sibling abort path.
# Setup failures cannot write the release record path: drill-recorded only
# checks that path exists and is non-blank, so putting partial evidence there
# could turn an unrun rehearsal into a passing release gate (#370).
record_abort_path() {
  local out="${1:?record_abort_path: record path required}" stem n=1 candidate
  stem="${out%.md}"
  while :; do
    candidate="$stem.aborted-$n.md"
    if [ -e "$candidate" ]; then
      n=$((n + 1))
      continue
    fi
    if (set -o noclobber; : >"$candidate") 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
    # A racer may have reserved the same number after the existence check.
    # Any other refusal (missing directory, permissions) is a real write
    # failure, not a collision to spin on forever.
    [ -e "$candidate" ] || return 1
    n=$((n + 1))
  done
}

# record_abort_render <ctx-file> <setup-tsv> <step> <message> <status>
# — evidence from setup, deliberately not a rehearsal record shape.
record_abort_render() {
  local ctx="${1:?}" setup="${2:?}" step="${3:?}" message="${4:-}" status="${5:?}"
  local scratch attempt created candidate_sha fork_repo fork_ref disposal
  scratch="$(record_ctx "$ctx" scratch)"
  attempt="$(record_ctx "$ctx" attempt)"
  created="$(record_ctx "$ctx" created)"
  candidate_sha="$(record_ctx "$ctx" candidate_sha)"
  fork_repo="$(record_ctx "$ctx" fork_repo)"
  fork_ref="$(record_ctx "$ctx" fork_ref)"
  disposal="$(record_ctx "$ctx" disposal)"

  printf '%s\n\n' '**Aborted in setup — no probe ran.**'
  printf -- "- **Step:** \`%s\`\n" "$step"
  printf -- "- **Exit status:** \`%s\`\n" "$status"
  printf -- '- **Message:**\n'
  if [ -n "$message" ]; then
    while IFS= read -r line; do printf '  > %s\n' "$line"; done <<<"$message"
  else
    printf '  > command exited with status %s\n' "$status"
  fi

  printf '\n## Known context\n\n'
  [ -z "$candidate_sha" ] || printf -- "- Candidate SHA: \`%s\`\n" "$candidate_sha"
  if [ -n "$fork_repo" ] && [ -n "$fork_ref" ]; then
    printf -- "- Fork ref: \`%s@%s\`\n" "$fork_repo" "$fork_ref"
  fi
  [ -z "$scratch" ] || printf -- "- Scratch repo: \`%s\`\n" "$scratch"
  [ -z "$attempt" ] || printf -- "- Attempt: \`%s\`\n" "$attempt"
  [ -z "$created" ] || printf -- "- Created: \`%s\`\n" "$created"

  if [ -n "$scratch" ] && [ -s "$setup" ]; then
    printf '\n## Setup rows recorded before the abort\n\n'
    record_setup_rows "$scratch" "$setup"
  fi
  if [ -n "$disposal" ]; then
    printf '\n## Disposal, as this run observed it\n\n%s.\n' "$disposal"
  fi
}

# record_claim <n> <version> — the one sentence probe <n> establishes when it
# passes, and that nothing establishes when it does not.
#
# The claims live here one per probe, keyed to the probe that measures them,
# because the alternative is the shape this file's header refuses: a
# concluding paragraph written once, asserting outcomes the run may not have
# had. The record's own conclusion was that shape until this round caught it
# closing a two-failure run with the two refusals that had just failed.
record_claim() {
  case "${1:?record_claim: n required}" in
    1) printf "The merge door published exactly one \`%s\` release from a labeled ceremony PR, tagged the reviewed merge commit, and re-armed main itself." "${2:?record_claim: version required}" ;;
    2) printf "The merge door stayed a green no-op under a \`release\` label carried by ordinary work." ;;
    3) printf "The merge door refused a bare version push without the \`release\` label." ;;
    4) printf 'The merge door refused a re-run of its own completed ceremony.' ;;
    5) printf 'The tag door published from a matching manual tag without touching main.' ;;
    6) printf 'The tag door refused a mismatched tag before creating anything.' ;;
    7) printf "The merge door cut \`%s-rc1\` as a prerelease from its surviving fragments, left \`CHANGELOG.md\` byte-identical, and re-armed main to \`%s-rc2-dev\`." "${3:?record_claim: rc version required}" "$3" ;;
    8) printf "The merge door promoted \`%s-rc1\` to \`%s\`, stamping the section its fragments assemble to and consuming them, while the candidate stayed a prerelease." "${3:?record_claim: rc version required}" "$3" ;;
    *) return 1 ;;
  esac
}

# record_establishes <probes-tsv> <version> <rc-version> — one line per probe,
# and never a claim whose probe did not pass.
#
# A failed probe's claim is not softened here, it is not printed at all: the
# failure takes its place, so the section cannot assert what the table denies.
record_establishes() {
  local probes="${1:?}" ver="${2:?}" rc="${3:?}" n row verdict name note
  for ((n = 1; n <= DRILL_PROBE_COUNT; n++)); do
    row="$(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$probes")"
    if [ -z "$row" ]; then
      printf -- '- ⬜ **Nothing established** — probe %s did not run, so this record makes no claim for it.\n' "$n"
      continue
    fi
    verdict="$(cut -f5 <<<"$row")"
    name="$(cut -f2 <<<"$row")"
    note="$(cut -f10 <<<"$row")"
    if [ "$verdict" = PASS ]; then
      printf -- '- ✅ %s\n' "$(record_claim "$n" "$ver" "$rc")"
    else
      printf -- '- ❌ **Nothing established** — probe %s (%s) failed: %s. This run is no evidence about that behavior either way.\n' \
        "$n" "$name" "$note"
    fi
  done
}

# record_unrun <probes-tsv> — the probe numbers with no run behind their row.
#
# The preamble asserted "All six probes ran" from the moment it was written,
# and the abort guard made that false: an aborted probe's row carries `—` for
# its run and says so in its result, under a header still claiming every row
# was written from its own run (@claude-bot-andresmgsl, round 2). It is the
# same shape the conclusion was just fixed for, at lower stakes, so it is
# fixed the same way — the sentence is a measurement now, not a constant.
record_unrun() {
  local probes="${1:?}" n row run out=""
  for ((n = 1; n <= DRILL_PROBE_COUNT; n++)); do
    row="$(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$probes")"
    if [ -z "$row" ]; then
      out="$out $n"
      continue
    fi
    run="$(cut -f3 <<<"$row")"
    case "$run" in
      '' | '—') out="$out $n" ;;
    esac
  done
  printf '%s\n' "${out# }"
}

# The doors, as the probe numbers that exercise them. Two sentences in the
# record are claims about the doors rather than about a probe, and both the
# renderer and the shape check have to split the rows the same way or they
# will disagree about a record neither of them wrote. The rc legs are the
# merge door's too: an rc cut and its promotion are both labeled ceremony
# PRs merging to main (#321).
DRILL_MERGE_PROBES='1 2 3 4 7 8'
DRILL_TAG_PROBES='5 6'

# record_ran <probes-tsv> — the probe numbers whose row was written from a run.
# The complement of record_unrun, and the measurement the door sentence stands
# on: a door ran iff at least one of its probes reached a run.
record_ran() {
  local probes="${1:?}" n row run out=""
  for ((n = 1; n <= DRILL_PROBE_COUNT; n++)); do
    row="$(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$probes")"
    [ -n "$row" ] || continue
    run="$(cut -f3 <<<"$row")"
    case "$run" in
      '' | '—') ;;
      *) out="$out $n" ;;
    esac
  done
  printf '%s\n' "${out# }"
}

# record_door_ran <ran-list> <probe>… — 0 when any of the named probes ran.
record_door_ran() {
  local ran=" ${1-} " n
  shift
  for n in "$@"; do
    case "$ran" in
      *" $n "*) return 0 ;;
    esac
  done
  return 1
}

# record_doors <probes-tsv> <version> — the opening of `## What the rehearsal
# establishes`, measured per door.
#
# "Both doors ran live" was a constant, and the abort guard makes it false the
# moment every probe of one door misses its run: the record would then assert
# an execution its own rows deny, in the failed-drill shape #313 asks to stay
# honest (@codex-bot-andresmgsl, round 3). Same fix as the preamble's, one
# level up — a door that reached no run is stated as no-evidence, never as a
# door that ran.
record_doors() {
  local probes="${1:?}" ver="${2:?}" ran merge=0 tag=0
  ran="$(record_ran "$probes")"
  # shellcheck disable=SC2086 # the door lists are probe numbers, split on purpose
  record_door_ran "$ran" $DRILL_MERGE_PROBES && merge=1
  # shellcheck disable=SC2086
  record_door_ran "$ran" $DRILL_TAG_PROBES && tag=1
  if [ "$merge" = 1 ] && [ "$tag" = 1 ]; then
    cat <<EOF
Both doors ran live against the $ver candidate's own machinery, driven by
\`drill/rehearsal.sh\` rather than by hand. Each line below is one probe's,
and it is printed as a claim only where that probe passed: what stands here
is a measurement in the table above, never a sentence written from an
intention.
EOF
  elif [ "$merge" = 1 ]; then
    cat <<EOF
The merge door ran live against the $ver candidate's own machinery, driven by
\`drill/rehearsal.sh\` rather than by hand. **The tag door reached no run at
all** (probes ${DRILL_TAG_PROBES// /, } never got one), so nothing below is
claimed for it and this record is no evidence about that door either way.
Each line below is one probe's, and it is printed as a claim only where that
probe passed: what stands here is a measurement in the table above, never a
sentence written from an intention.
EOF
  elif [ "$tag" = 1 ]; then
    cat <<EOF
The tag door ran live against the $ver candidate's own machinery, driven by
\`drill/rehearsal.sh\` rather than by hand. **The merge door reached no run at
all** (probes ${DRILL_MERGE_PROBES// /, } never got one), so nothing below is
claimed for it and this record is no evidence about that door either way.
Each line below is one probe's, and it is printed as a claim only where that
probe passed: what stands here is a measurement in the table above, never a
sentence written from an intention.
EOF
  else
    cat <<EOF
**Neither door reached a run at all**: no probe below got one, so this record
is no evidence about the $ver candidate's doors and claims nothing for
either. The rows above are the aborts themselves. Each line below is one
probe's, and it is printed as a claim only where that probe passed: what
stands here is a measurement in the table above, never a sentence written
from an intention.
EOF
  fi
}

# record_render <ctx-file> <probes-tsv> <setup-tsv> — the whole record.
record_render() {
  local ctx="${1:?}" probes="${2:?}" setup="${3:?}"
  local ver rc scratch attempt created private visibility candidate_sha candidate_ref fork_repo fork_ref
  local fork_head pin disposal runner stamp failed passed unestablished
  local unrun unrun_count word
  ver="$(record_ctx "$ctx" version)"
  # The rc ladder's own version: the probes above publish `$ver` and
  # `$ver`'s successor, and the rc legs run one further along so the
  # promotion has a version nothing has released (#321).
  rc="$(record_ctx "$ctx" rc_version)"
  word="$(record_count_word)"
  scratch="$(record_ctx "$ctx" scratch)"
  attempt="$(record_ctx "$ctx" attempt)"
  created="$(record_ctx "$ctx" created)"
  private="$(record_ctx "$ctx" private)"
  case "$private" in
    true) visibility=private ;;
    false) visibility=public ;;
    *)
      printf "record_render: private context is not true or false ('%s').\n" "$private" >&2
      return 1
      ;;
  esac
  candidate_sha="$(record_ctx "$ctx" candidate_sha)"
  candidate_ref="$(record_ctx "$ctx" candidate_ref)"
  fork_repo="$(record_ctx "$ctx" fork_repo)"
  fork_ref="$(record_ctx "$ctx" fork_ref)"
  fork_head="$(record_ctx "$ctx" fork_head)"
  pin="$(record_ctx "$ctx" pin)"
  disposal="$(record_ctx "$ctx" disposal)"
  runner="$(record_ctx "$ctx" runner)"
  stamp="$(record_ctx "$ctx" stamp)"
  failed="$(awk -F'\t' '$5 == "FAIL"' "$probes" | wc -l | tr -d ' ')"
  # A probe that never wrote a row establishes nothing either, so the
  # conclusion counts what passed rather than what failed.
  passed="$(awk -F'\t' '$5 == "PASS"' "$probes" | wc -l | tr -d ' ')"
  # Clamped: a duplicated row would otherwise render a negative count. The
  # shape check's row count catches that before the emission ships, so this
  # is belt and braces — but the arithmetic should not need a check elsewhere
  # in the file to stay sane (@claude-bot-andresmgsl, round 2).
  unestablished=$((DRILL_PROBE_COUNT - passed))
  [ "$unestablished" -ge 0 ] || unestablished=0
  unrun="$(record_unrun "$probes")"
  unrun_count="$(printf '%s\n' "$unrun" | wc -w | tr -d ' ')"

  cat <<EOF
# $ver — drill record

Run $stamp by \`$runner\` with \`drill/rehearsal.sh\` against the $ver
candidate, candidate ref \`$candidate_ref\`, canonical candidate SHA
\`$candidate_sha\`.
EOF

  if [ "$unrun_count" = 0 ]; then
    printf 'All %s probes ran; every row in the table below was written from\nits own run by the script that drove it.\n\n' "$word"
  else
    printf '**%s of the %s probes never reached a run** (probe %s): those rows\nare written from the abort itself, show a dash where a run link would be,\nand nothing is claimed for them below. Every other row in the table was written\nfrom its own run by the script that drove it.\n\n' \
      "$unrun_count" "$word" "${unrun// /, }"
  fi

  if [ "$failed" = 0 ]; then
    printf '**Every probe passed.**\n\n'
  else
    printf '**%s probe(s) failed.** A failed drill is a valid record: the rows below are what ran, and the failures are stated where they happened rather than smoothed over.\n\n' \
      "$failed"
  fi

  cat <<EOF
## Where

Attempt **\`$attempt\`** used disposable **$visibility** repo \`$scratch\`, created
$created. It carries the
\`docs/CONSUMERS.md\` release caller verbatim (\`version-source: file\`) over a
fragment-mode fixture armed at \`$ver-dev\`: a preamble-only
\`CHANGELOG.md\`, \`changelog.d/README.md\` plus three fragments, and a
non-blank \`drills/$ver.md\`. The \`release\` label was created there before
the first ceremony PR, per the guide's prerequisite. The fixture was
committed **before** the caller, so the first door run had a real parent
version to inspect — the script refuses to install the caller against a tree
with no fixture in it.
EOF

  if [ "$private" = true ]; then
    printf '\nBecause this repo is private, its run links resolve only for the repo owner.\n\n'
  else
    printf '\n'
  fi

  cat <<EOF
The rc legs run one rung further along the ladder — \`$rc-dev\` →
\`$rc-rc1\` → \`$rc\` — because the probes before them have already
published $ver and its successor, and a promotion needs a version nothing
has released. An rc that ships carries its own drill record, so the rc cut's
ceremony PR carries **\`drills/$rc-rc1.md\`** and that is the path the rc
version's record lives at.

**Disposal, as this run observed it**: $disposal.

It is **pending the operator's delete**, which no builder can perform:
\`delete_repo\` is absent from fleet tokens by doctrine (#135). No delete was attempted and none is
claimed — the instrument refuses the call rather than retrying the 403 wall.
Cleanup gates nothing.

## Candidate-ref deviation

The pure consumer path cannot resolve this candidate's own
\`CEREMONY_SELF_REF\`: it names the tag this release has not created yet. No
ref named like that tag was created on \`heavy-duty/ceremony\`, and the
script refuses to take that path at all.

The scratch caller pins
\`$fork_repo/.github/workflows/release.yml@$fork_ref\`. That fork ref was
created at the canonical candidate SHA \`$candidate_sha\`, and its one
additional commit (\`$fork_head\`) rewrites every workflow carrying
\`CEREMONY_SELF_REF\` to the rewritten pin \`$pin\`. The pins were read back
at the ref after the rewrite and all agree; all runtime machinery in every
probe below was therefore fetched from the $ver candidate tree.

## Probes
EOF

  # The same claim as the preamble's, one section down, and it was a constant
  # too: the abort fixture rendered a dashed row under a sentence saying every
  # row came from its own run (@codex-bot-andresmgsl, round 3).
  if [ "$unrun_count" = 0 ]; then
    printf '\nOne row per probe, in doctrine order, each written from its own run. Runs are\n'
  else
    printf '\nOne row per probe, in doctrine order. %s of them (probe %s) never reached a\nrun: those rows are written from the abort itself and show a dash where the\nrun link would be, and every other row was written from its own run. Runs are\n' \
      "$unrun_count" "${unrun// /, }"
  fi

  cat <<EOF
in \`$scratch\`. The two count columns are the measurement every refusal
probe is asserted on: a refusal that leaves a tag or a release behind is a
failed probe, and the assertion is these numbers, not the prose beside them.

| # | probe | run | tags | releases | result |
|---|---|---|---|---|---|
EOF
  record_probe_rows "$scratch" "$probes"

  cat <<'EOF'

## Setup, and the runs that are not probes

EOF
  if [ -s "$setup" ]; then
    record_setup_rows "$scratch" "$setup"
  else
    printf 'None: every run on the scratch repo is a probe row above.\n'
  fi

  cat <<'EOF'

## What the rehearsal establishes

EOF
  record_doors "$probes" "$ver"
  printf '\n'
  record_establishes "$probes" "$ver" "$rc"

  if [ "$unestablished" = 0 ]; then
    cat <<'EOF'

Every refusal claim above is asserted on the before/after counts in the probe
table, not on the prose beside them.
EOF
  else
    cat <<EOF

**Not established: $unestablished of the $word.** A failed drill is a valid
record and this is one — what the run proved is claimed above, what it did
not is named where it failed, and neither is smoothed into the other.
EOF
  fi
}

# record_check <record-file> — the shape check the script runs on its own
# emission before writing it out.
#
# A record whose probe table is missing a run ID is not a record: the run is
# the only thing a reader can go and look at. This is also why the emission
# is checked rather than trusted — the script is the record's only author now,
# so nothing else will notice.
record_check() {
  local file="${1:?record_check: file required}" rows problems="" exempt=0 ran=""
  local word
  word="$(record_count_word)"
  # Any numbered row, not the doctrine's range: a table carrying a row the
  # doctrine does not name must red on the count below rather than be quietly
  # skipped by the pattern that was supposed to find it (#321).
  rows="$(awk -F'|' '$2 ~ /^ [0-9]+ $/ { print }' "$file")"
  local count
  count="$(printf '%s\n' "$rows" | awk 'NF' | wc -l | tr -d ' ')"
  [ "$count" = "$DRILL_PROBE_COUNT" ] ||
    problems="$problems; the probe table has $count rows, expected $DRILL_PROBE_COUNT"
  local n
  for ((n = 1; n <= DRILL_PROBE_COUNT; n++)); do
    local row run_cell result_cell
    row="$(awk -F'|' -v n=" $n " '$2 == n { print; exit }' "$file")"
    if [ -z "$row" ]; then
      problems="$problems; probe $n has no row"
      continue
    fi
    run_cell="$(awk -F'|' -v n=" $n " '$2 == n { print $4; exit }' "$file" | tr -d ' ')"
    result_cell="$(awk -F'|' -v n=" $n " '$2 == n { print $7; exit }' "$file")"
    # An aborted probe is the one row that honestly has no run to link: it
    # never reached one. That exemption is narrow on purpose — the row must
    # say `—` for its run *and* carry the aborted failure mark, so a row that
    # merely lost its run ID still reds (#313's "must fail loudly").
    if [ "$run_cell" = "—" ] && [[ "$result_cell" == *"❌ aborted"* ]]; then
      exempt=$((exempt + 1))
      continue
    fi
    if printf '%s' "$row" | grep -qE '/actions/runs/[0-9]+'; then
      ran="$ran $n"
    else
      problems="$problems; probe $n has no run ID"
    fi
    printf '%s' "$row" | grep -qE '[0-9]+ → [0-9]+ \|[^|]*[0-9]+ → [0-9]+' ||
      problems="$problems; probe $n has no before/after counts"
  done
  # The conclusion is checked like the table, because it is evidence like the
  # table: one line per probe, each either a claim its probe earned or the
  # failure that withdrew it.
  local claims
  claims="$(grep -cE '^- (✅|❌|⬜) ' "$file" || true)"
  [ "$claims" = "$DRILL_PROBE_COUNT" ] ||
    problems="$problems; the conclusion has $claims probe lines, expected $DRILL_PROBE_COUNT"
  grep -qF 'pending the operator' "$file" ||
    problems="$problems; the record does not state the disposal as pending the operator's delete"
  # D4: the rc legs are only evidence for an rc that ships if the emission
  # says where that rc's own record lives (#321).
  grep -qE 'drills/[0-9]+\.[0-9]+\.[0-9]+-rc[0-9]+\.md' "$file" ||
    problems="$problems; the record does not name the rc version's own record path"
  # The prose that talks about the runs is graded against the rows too. It was
  # the one part of the record nothing checked, and `record_render` measuring
  # it is only a guarantee while `record_render` is the sole author
  # (@claude-bot-andresmgsl, round 3): a hand-touched record, or a second
  # renderer, gets the same grading the table has always had.
  local claimed
  if grep -qF "All $word probes ran" "$file"; then
    claimed=0
  else
    claimed="$(sed -n "s/^\\*\\*\\([0-9][0-9]*\\) of the $word probes never reached a run\\*\\*.*/\\1/p" \
      "$file" | head -n 1)"
  fi
  if [ -z "$claimed" ]; then
    problems="$problems; the record's preamble does not say how many probes reached a run"
  elif [ "$claimed" != "$exempt" ]; then
    problems="$problems; the preamble says $claimed probe(s) never reached a run, the table shows $exempt"
  fi
  if [ "$exempt" != 0 ] &&
    grep -qF 'in doctrine order, each written from its own run' "$file"; then
    problems="$problems; $exempt row(s) reached no run, but the probe table says every row was written from its own run"
  fi
  # Which doors the rows say ran, and the sentence the conclusion owes for it.
  local merge=0 tag=0 doors
  # shellcheck disable=SC2086 # the door lists are probe numbers, split on purpose
  record_door_ran "${ran# }" $DRILL_MERGE_PROBES && merge=1
  # shellcheck disable=SC2086
  record_door_ran "${ran# }" $DRILL_TAG_PROBES && tag=1
  if [ "$merge" = 1 ] && [ "$tag" = 1 ]; then
    doors='Both doors ran live against the'
  elif [ "$merge" = 1 ]; then
    doors='**The tag door reached no run at'
  elif [ "$tag" = 1 ]; then
    doors='**The merge door reached no run at'
  else
    doors='**Neither door reached a run at all**'
  fi
  grep -qF "$doors" "$file" ||
    problems="$problems; the rows measure merge-door-ran=$merge tag-door-ran=$tag, but the conclusion does not say so (expected \"$doors\")"
  if [ -n "$problems" ]; then
    echo "record_check: ${problems#; }" >&2
    return 1
  fi
  # The success line is evidence too, and it used to announce a run ID for
  # every row one line after excusing a row that had none. It says what it checked
  # (@claude-bot-andresmgsl, round 2).
  if [ "$exempt" = 0 ]; then
    echo "record_check: $word probe rows, each with a run ID and its before/after counts, and a conclusion that claims only what they measured."
  else
    # The sentence counts rows, so it agrees with the count it just printed
    # (@claude-bot-andresmgsl, round 3).
    local carries='carry'
    [ "$exempt" != 1 ] || carries='carries'
    echo "record_check: $word probe rows — $exempt aborted before reaching a run and $carries the aborted mark in place of a run ID, the rest carry a run ID and their before/after counts — and a conclusion that claims only what they measured."
  fi
}
