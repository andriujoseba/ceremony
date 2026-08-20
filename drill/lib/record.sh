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

# The `## Known gaps` section's own prose, spelled once (#484 D5). Three
# readers share it — `record_render` writes it, `record_parse` skips it, and
# `record_check` greps it — and two spellers would drift, which is the same
# reason `record_count_word` exists. A drifted copy would red the round trip
# on a record nobody edited.
#
# The line breaks are part of the value: the render's own prose is hard-wrapped
# and this is the render's own prose.
RECORD_GAP_PREAMBLE='Declared before the run and rendered here as given. Each names something no
probe drives, so the rehearsal establishes nothing about it; a probe that ran
and failed is not a gap and is written in its own row above.'
RECORD_GAP_NONE="None declared: every claim this record makes is a probe row's, and nothing was
declared outside them."

# record_gap_rows <gaps-tsv> — one line per declared gap, verbatim.
#
# Never re-wrapped (#484 D5). The renderer hard-wraps the prose it writes
# itself, but a gap is declared INPUT: wrapping it would be a transformation
# the parse has to invert exactly, and a re-wrap disagreeing with the original
# by one space reds the round trip on a record nobody edited. Not wrapping is
# the only shape that is invertible by construction, and a long line is the
# price.
#
# It REFUSES a title carrying `** — `, the separator the next `printf` is about
# to write. This is the library's half of the round-1 fix: `drill/rehearsal.sh`
# refuses the same title at argument-parse time, before a scratch repo exists,
# which is where an author wants to hear it — but the invariant belongs here,
# because this function is the only thing that ever writes a gap line and
# `record_parse` cuts at the FIRST separator. Guarding only the CLI would make
# "what the renderer writes, the parse inverts exactly" a property of one
# argument parser rather than of the pair. The round trip cannot stand in for
# it: re-rendering the re-cut pair recreates the identical bytes, so a record
# whose declared title was lost passes byte-identity
# (@codex-bot-andresmgsl, @claude-bot-andresmgsl, round 1).
record_gap_rows() {
  local tsv="${1:?}" title body
  while IFS=$'\t' read -r title body; do
    [ -n "${title:-}" ] || continue
    case "$title" in
      *'** — '*)
        printf 'record_gap_rows: the gap title %s carries the title/body separator `** — `, which record_parse cuts at, so this pair would not survive its own render. A body may carry it; a title may not.\n' \
          "'$title'" >&2
        return 1
        ;;
    esac
    printf -- '- **%s** — %s\n' "$title" "$body"
  done <"$tsv"
}

# record_gap_prose_line <line> <block> — 0 when <line> is one of <block>'s
# lines. The section's fixed sentences are the render's, so the parse skips
# them rather than reading one as a gap.
record_gap_prose_line() {
  local line="${1-}" known
  while IFS= read -r known; do
    [ "$line" != "$known" ] || return 0
  done <<<"${2-}"
  return 1
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

# record_render <ctx-file> <probes-tsv> <setup-tsv> [gaps-tsv] — the whole
# record.
#
# The gaps TSV is `title<TAB>body`, one row per declared gap, in declaration
# order (#484 D6). `ctx.tsv` is a single-line key/value lookup and cannot hold
# a list, so gaps travel the way probes and setup rows do: their own file.
# It is the one optional input, and absent means what an empty one means —
# no gap was declared. That keeps every caller that has none to declare
# writing the call it already wrote, and a caller that drops a gaps file it
# should have passed is caught by the round trip, whose re-render then differs
# from the record's own bytes.
record_render() {
  local ctx="${1:?}" probes="${2:?}" setup="${3:?}" gaps="${4:-}"
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

  # -- ## Known gaps, the sixth section and the LAST (#484 D1, D2) ----------
  # It qualifies the conclusion, so it reads immediately after it, and
  # appending to the parse's `want` array leaves the five existing sections'
  # order and every field's bounded search unchanged.
  #
  # Rendered on every emission, empty or not. An optional section would make
  # `record_parse`'s heading search conditional and give a record two legal
  # shapes; a required one keeps the parse a fixed lookup and makes "this
  # drill declared no gaps" a claim the record STATES rather than an absence
  # a reader has to infer. `## Setup, and the runs that are not probes`
  # already renders its own empty-state sentence for the same reason.
  #
  # A gap is COVERAGE, never a failed probe (D3), and the section's opening
  # sentence says so: a failed or unrun probe already writes its own row, its
  # own preamble sentence and the not-established tail above, and filing one
  # here would soften it.
  printf '\n## Known gaps\n\n'
  if [ -n "$gaps" ] && [ -s "$gaps" ]; then
    printf '%s\n\n' "$RECORD_GAP_PREAMBLE"
    # Propagated, never swallowed: a render that could not write an invertible
    # gap line must not return a record its caller will then commit.
    record_gap_rows "$gaps" || return 1
  else
    printf '%s\n' "$RECORD_GAP_NONE"
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
  # The sixth section is graded at emission time like every other (#484 D8),
  # so a malformed one reds where it is WRITTEN rather than at the next cut.
  # Either the record declares no gaps in the section's own words, or every
  # gap line carries a non-empty title and a non-empty body.
  local gap_section gap_all gap_ok
  if ! grep -qx '## Known gaps' "$file"; then
    problems="$problems; the record has no '## Known gaps' section"
  else
    gap_section="$(sed -n '/^## Known gaps$/,$p' "$file")"
    gap_all="$(printf '%s\n' "$gap_section" | grep -c '^- \*\*' || true)"
    # A well-formed line is `- **<title>** — <body>` with both halves
    # non-empty; the regex refuses each empty half by requiring a character
    # on either side of the separator.
    gap_ok="$(printf '%s\n' "$gap_section" | grep -cE '^- \*\*.+\*\* — .+$' || true)"
    if printf '%s\n' "$gap_section" | grep -qF "${RECORD_GAP_NONE%%$'\n'*}"; then
      :
    elif [ "$gap_all" = 0 ]; then
      problems="$problems; the '## Known gaps' section carries neither the none-declared sentence nor a gap line"
    elif [ "$gap_ok" != "$gap_all" ]; then
      problems="$problems; $((gap_all - gap_ok)) of the $gap_all gap line(s) carry no title or no body"
    fi
  fi
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

# ---------------------------------------------------------------------------
# The round trip (#373) — the record graded by re-render.
#
# `record_check` grades SHAPE, and a shape is what a hand edit leaves intact:
# a copy of the committed 0.7.0 record with one sentence added to its preamble
# passes it, exit 0 (@claude-bot-andresmgsl, the 0.7.0 panel round). Row
# counts, run IDs, before/after counts and the door sentence are all still
# there after a prose edit, so all of them still pass. The comment above
# `record_check` conceded the shape of it — "a hand-touched record, or a
# second renderer, gets the same grading the table has always had" — and a
# code comment naming a hazard is not a guard against it.
#
# What actually discharged #313's "the script's emission, not a hand-written
# record" at the 0.7.0 cut was two reviewers rebuilding the render inputs from
# the record's own stated measurements, re-rendering and diffing. That worked
# and it is not a mechanism: it was done by hand, twice, at one cut, and
# nothing would have done it at the next.
#
# So the grading moves from shape to AUTHORSHIP. Parse the record back into
# the three inputs `record_render` consumes, render those, demand the bytes
# back. A hand-added sentence, a reordered field, an edited count: none of
# them survive being regenerated from what the file itself claims, because
# the render writes that prose from the measurements and not from the file.
# ---------------------------------------------------------------------------

# The parse helpers hand back through a global rather than on stdout, and the
# exit status says which of the two it is holding: the recovered value on 0,
# the reason it could not recover one on 1. Command substitution would run
# them in a subshell, and a refusal owes the caller the reason AND the line
# number it happened on — only the caller knows the second, so the reason has
# to survive the return. Read it on the line after the call, never further.
RECORD_PARSE_OUT=''

# record_parse_die <file> <lineno> <why> <line> — D5's contract: a record that
# cannot be parsed FAILS and says which line defeated it. "Unparseable
# therefore fine" is the silent skip that would re-open the hole this closes,
# so there is no path here that returns 0 without a value.
record_parse_die() {
  printf 'record_parse: %s:%s: %s\n' "${1:?}" "${2:?}" "${3:?}" >&2
  printf '  | %s\n' "${4-}" >&2
  return 1
}

# record_parse_run_cell <cell> <scratch-repo> — a rendered run cell back into
# `<run><TAB><attempt>`, or the reason it is not one, in RECORD_PARSE_OUT.
#
# The inversion is total on purpose. `record_run_cell` can only emit a cell
# whose link text, whose URL's run ID and whose URL's repo all agree — it
# builds all three out of two variables — so a cell where they disagree is
# not this renderer's output. That matters because it is the commonest hand
# edit a record can suffer: a run ID retyped on one side of the link. Caught
# here it is a parse failure naming the line, which is a better diagnostic
# than the same edit surfacing as a diff several sections down.
record_parse_run_cell() {
  local cell="${1-}" repo="${2:?}" attempt=1 text url_repo url_run
  local link='^\[([0-9]+)\]\(https://github\.com/(.+)/actions/runs/([0-9]+)\)$'
  local suffix='^(.*) \(attempt ([0-9]+)\)$'
  # A probe that aborted before any run existed has no run to link, and
  # `record_run_cell` renders both the empty run and an explicit dash the
  # same way, so the dash is what inverts to.
  if [ "$cell" = '—' ]; then
    RECORD_PARSE_OUT="—"$'\t'"1"
    return 0
  fi
  if [[ "$cell" =~ $suffix ]]; then
    cell="${BASH_REMATCH[1]}"
    attempt="${BASH_REMATCH[2]}"
    # The suffix is emitted only above 1, so `(attempt 1)` is a cell the
    # renderer would never have written.
    if [ "$attempt" -le 1 ]; then
      RECORD_PARSE_OUT="the run cell carries '(attempt $attempt)', which record_run_cell emits only above attempt 1"
      return 1
    fi
  fi
  if [[ ! "$cell" =~ $link ]]; then
    RECORD_PARSE_OUT="the run cell is not a run link: '$cell'"
    return 1
  fi
  text="${BASH_REMATCH[1]}"
  url_repo="${BASH_REMATCH[2]}"
  url_run="${BASH_REMATCH[3]}"
  if [ "$text" != "$url_run" ]; then
    RECORD_PARSE_OUT="the run cell's link text ($text) and its URL's run ID ($url_run) disagree — one side was edited"
    return 1
  fi
  if [ "$url_repo" != "$repo" ]; then
    RECORD_PARSE_OUT="the run link points at $url_repo, but this record's scratch repo is $repo"
    return 1
  fi
  RECORD_PARSE_OUT="$text"$'\t'"$attempt"
}

# record_parse <record-file> <ctx-out> <probes-out> <setup-out> <gaps-out> —
# invert `record_render` into the four TSVs the instrument writes (#373 D1,
# #484 D6).
#
# The gaps output is required rather than optional, unlike the render's
# corresponding input: it is an OUT parameter, and a caller with nowhere to
# put the gaps would be silently discarding what it just parsed.
#
# Only the render's INPUTS are recovered here. Everything the render computes
# — the preamble's run count, the failed count, the door sentences, the
# per-probe claims, the not-established tail — is deliberately not read: it is
# regenerated from the probe rows, which is exactly what makes an edited count
# show up as a difference instead of being parsed back in and re-emitted.
#
# Everything it needs is in the file by construction, the record being
# generated from precisely this data. Where that stops being true the RENDER
# is what moves, never the tolerance here.
#
# The regexes below are the render's own sentences, so they are single-quoted
# and they carry backticks and dollars as literal bytes of the record — never
# as expansions. Function-scoped rather than per-line: every one of them is
# the same deliberate quoting, and eight repetitions of the directive would
# be harder to read than the rule stated once.
# shellcheck disable=SC2016
record_parse() {
  local file="${1:?record_parse: record file required}"
  local ctx_out="${2:?record_parse: ctx output required}"
  local probes_out="${3:?record_parse: probes output required}"
  local setup_out="${4:?record_parse: setup output required}"
  local gaps_out="${5:?record_parse: gaps output required}"
  if [ ! -f "$file" ]; then
    printf 'record_parse: %s: no such file\n' "$file" >&2
    return 1
  fi

  local -a lines=()
  local line
  # `|| [ -n "$line" ]` keeps a final unterminated line: the render always
  # ends with a newline, so a record that does not is already not its output
  # and the difference should be reported, not silently absorbed.
  while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done <"$file"
  local total="${#lines[@]}"
  if [ "$total" -lt 6 ]; then
    printf 'record_parse: %s: %s line(s) — too short to be a rendered record\n' \
      "$file" "$total" >&2
    return 1
  fi

  # -- the fixed opening ----------------------------------------------------
  # Lines 1 and 3-5 are literal in the render's first heredoc, so their shape
  # is not a guess: a record whose opening is not this was not rendered here.
  local ver stamp runner candidate_ref candidate_sha
  local re
  re='^# (.+) — drill record$'
  [[ "${lines[0]}" =~ $re ]] ||
    record_parse_die "$file" 1 "not the record heading" "${lines[0]}" || return 1
  ver="${BASH_REMATCH[1]}"
  [ -z "${lines[1]}" ] ||
    record_parse_die "$file" 2 "expected a blank line after the heading" "${lines[1]}" || return 1
  re='^Run (.+) by `(.+)` with `drill/rehearsal\.sh` against the (.+)$'
  [[ "${lines[2]}" =~ $re ]] ||
    record_parse_die "$file" 3 "not the run sentence's first line" "${lines[2]}" || return 1
  stamp="${BASH_REMATCH[1]}"
  runner="${BASH_REMATCH[2]}"
  if [ "${BASH_REMATCH[3]}" != "$ver" ]; then
    record_parse_die "$file" 3 \
      "the run sentence names version ${BASH_REMATCH[3]}, the heading names $ver" \
      "${lines[2]}" || return 1
  fi
  re='^candidate, candidate ref `(.+)`, canonical candidate SHA$'
  [[ "${lines[3]}" =~ $re ]] ||
    record_parse_die "$file" 4 "not the candidate-ref line" "${lines[3]}" || return 1
  candidate_ref="${BASH_REMATCH[1]}"
  re='^`(.+)`\.$'
  [[ "${lines[4]}" =~ $re ]] ||
    record_parse_die "$file" 5 "not the candidate-SHA line" "${lines[4]}" || return 1
  candidate_sha="${BASH_REMATCH[1]}"

  # -- the sections ---------------------------------------------------------
  # The six headings are constants in the render and they come in one order.
  # Finding them first turns every field lookup below into a bounded search,
  # so a sentence added to one section cannot be answered by a line in
  # another. `## Known gaps` joins as the LAST member (#484 D2): the list
  # stays closed and gains one, so a seventh heading the renderer did not
  # write is still a record this parse refuses.
  local -a want=('## Where' '## Candidate-ref deviation' '## Probes'
    '## Setup, and the runs that are not probes' '## What the rehearsal establishes'
    '## Known gaps')
  local -a at=()
  local h i seen
  for h in "${want[@]}"; do
    seen=-1
    for ((i = 5; i < total; i++)); do
      [ "${lines[i]}" = "$h" ] || continue
      if [ "$seen" -ge 0 ]; then
        record_parse_die "$file" "$((i + 1))" "'$h' appears more than once" "${lines[i]}" ||
          return 1
      fi
      seen="$i"
    done
    if [ "$seen" -lt 0 ]; then
      printf "record_parse: %s: no '%s' heading — not a rendered record\\n" "$file" "$h" >&2
      return 1
    fi
    at+=("$seen")
  done
  for ((i = 1; i < ${#at[@]}; i++)); do
    if [ "${at[i]}" -le "${at[i - 1]}" ]; then
      record_parse_die "$file" "$((at[i] + 1))" \
        "'${want[i]}' comes before '${want[i - 1]}'" "${lines[at[i]]}" || return 1
    fi
  done
  local where_at="${at[0]}" deviation_at="${at[1]}" probes_at="${at[2]}"
  local setup_at="${at[3]}" establishes_at="${at[4]}" gaps_at="${at[5]}"

  # -- ## Where -------------------------------------------------------------
  local attempt visibility private scratch created rc_version disposal
  local w=$((where_at + 2))
  re='^Attempt \*\*`(.+)`\*\* used disposable \*\*(private|public)\*\* repo `(.+)`, created$'
  [[ "${lines[w]-}" =~ $re ]] ||
    record_parse_die "$file" "$((w + 1))" "not the scratch-repo line" "${lines[w]-}" || return 1
  attempt="${BASH_REMATCH[1]}"
  visibility="${BASH_REMATCH[2]}"
  scratch="${BASH_REMATCH[3]}"
  private=true
  [ "$visibility" = private ] || private=false
  re='^(.+)\. It carries the$'
  [[ "${lines[w + 1]-}" =~ $re ]] ||
    record_parse_die "$file" "$((w + 2))" "not the creation-stamp line" "${lines[w + 1]-}" || return 1
  created="${BASH_REMATCH[1]}"

  re='^The rc legs run one rung further along the ladder — `(.+)-dev` →$'
  record_parse_one "$file" "$where_at" "$deviation_at" "$re" 'the rc ladder line' || return 1
  rc_version="$RECORD_PARSE_OUT"
  re='^\*\*Disposal, as this run observed it\*\*: (.+)\.$'
  record_parse_one "$file" "$where_at" "$deviation_at" "$re" 'the disposal line' || return 1
  disposal="$RECORD_PARSE_OUT"

  # -- ## Candidate-ref deviation -------------------------------------------
  local fork_repo fork_ref fork_head pin
  re='^`(.+)/\.github/workflows/release\.yml@(.+)`\. That fork ref was$'
  record_parse_one "$file" "$deviation_at" "$probes_at" "$re" 'the caller pin line' 2 || return 1
  fork_repo="${RECORD_PARSE_OUT%%$'\t'*}"
  fork_ref="${RECORD_PARSE_OUT#*$'\t'}"
  re='^additional commit \(`(.+)`\) rewrites every workflow carrying$'
  record_parse_one "$file" "$deviation_at" "$probes_at" "$re" 'the fork-head line' || return 1
  fork_head="$RECORD_PARSE_OUT"
  re='^`CEREMONY_SELF_REF` to the rewritten pin `(.+)`\. The pins were read back$'
  record_parse_one "$file" "$deviation_at" "$probes_at" "$re" 'the rewritten-pin line' || return 1
  pin="$RECORD_PARSE_OUT"

  # -- the probe table ------------------------------------------------------
  local -a rows=()
  local n name cell counts_t counts_r result verdict note tb ta rb ra
  local header='| # | probe | run | tags | releases | result |'
  local rule='|---|---|---|---|---|---|'
  local header_seen=0 rule_seen=0
  for ((i = probes_at + 1; i < setup_at; i++)); do
    line="${lines[i]}"
    case "$line" in
      "$header")
        header_seen=1
        continue
        ;;
      "$rule")
        rule_seen=1
        continue
        ;;
      '| '*) ;;
      *) continue ;;
    esac
    if [ "$rule_seen" = 0 ]; then
      record_parse_die "$file" "$((i + 1))" \
        'a probe row before the table header' "$line" || return 1
    fi
    # The row is split on the render's own ' | ' separator rather than on a
    # bare '|': a cell containing a pipe would break the table for every
    # reader, and here it lands as a field count that is not six — a refusal
    # naming the line, which is the point of D5.
    local row="${line#| }"
    row="${row% |}"
    local -a f=()
    IFS=$'\t' read -r -a f <<<"${row// | /$'\t'}"
    if [ "${#f[@]}" -ne 6 ]; then
      record_parse_die "$file" "$((i + 1))" \
        "the probe row has ${#f[@]} cells, expected 6" "$line" || return 1
    fi
    n="${f[0]}"
    name="${f[1]}"
    cell="${f[2]}"
    counts_t="${f[3]}"
    counts_r="${f[4]}"
    result="${f[5]}"
    if ! record_parse_counts "$counts_t"; then
      record_parse_die "$file" "$((i + 1))" \
        "the tags cell is not a before/after pair: '$counts_t'" "$line" || return 1
    fi
    tb="${RECORD_PARSE_OUT%%$'\t'*}"
    ta="${RECORD_PARSE_OUT#*$'\t'}"
    if ! record_parse_counts "$counts_r"; then
      record_parse_die "$file" "$((i + 1))" \
        "the releases cell is not a before/after pair: '$counts_r'" "$line" || return 1
    fi
    rb="${RECORD_PARSE_OUT%%$'\t'*}"
    ra="${RECORD_PARSE_OUT#*$'\t'}"
    # `record_probe_rows` prints the mark and the note as two arguments with
    # one space between them, and the mark is a two-way function of the
    # verdict, so the verdict inverts exactly. The note is taken by stripping
    # the mark as a literal prefix rather than by slicing a character off the
    # front: the marks are multi-byte, and `${result:0:1}` is a character
    # under a UTF-8 locale and a byte under LC_ALL=C.
    case "$result" in
      '✅ '*)
        verdict=PASS
        note="${result#✅ }"
        ;;
      '❌ '*)
        verdict=FAIL
        note="${result#❌ }"
        ;;
      *)
        record_parse_die "$file" "$((i + 1))" \
          "the result cell opens with neither ✅ nor ❌: '$result'" "$line" || return 1
        ;;
    esac
    if ! record_parse_run_cell "$cell" "$scratch"; then
      record_parse_die "$file" "$((i + 1))" "$RECORD_PARSE_OUT" "$line" || return 1
    fi
    rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$n" "$name" "${RECORD_PARSE_OUT%%$'\t'*}" "${RECORD_PARSE_OUT#*$'\t'}" \
      "$verdict" "$tb" "$ta" "$rb" "$ra" "$note")")
  done
  if [ "$header_seen" = 0 ] || [ "$rule_seen" = 0 ]; then
    printf 'record_parse: %s: the Probes section has no table header\n' "$file" >&2
    return 1
  fi
  if [ "${#rows[@]}" -eq 0 ]; then
    printf 'record_parse: %s: the probe table has no rows\n' "$file" >&2
    return 1
  fi

  # -- the setup rows -------------------------------------------------------
  local -a setups=()
  local none='None: every run on the scratch repo is a probe row above.'
  local none_seen=0 conclusion what rest
  for ((i = setup_at + 1; i < establishes_at; i++)); do
    line="${lines[i]}"
    [ -n "$line" ] || continue
    if [ "$line" = "$none" ]; then
      none_seen=1
      continue
    fi
    case "$line" in
      '- **'*) ;;
      *)
        record_parse_die "$file" "$((i + 1))" \
          'not a setup row and not the no-setup sentence' "$line" || return 1
        ;;
    esac
    rest="${line#- \*\*}"
    cell="${rest%%\*\* (*}"
    if [ "$cell" = "$rest" ]; then
      record_parse_die "$file" "$((i + 1))" \
        'the setup row has no (conclusion) after its run link' "$line" || return 1
    fi
    rest="${rest#"$cell"\*\* (}"
    conclusion="${rest%%) — *}"
    if [ "$conclusion" = "$rest" ]; then
      record_parse_die "$file" "$((i + 1))" \
        'the setup row has no em-dash separator after its conclusion' "$line" || return 1
    fi
    what="${rest#"$conclusion") — }"
    if ! record_parse_run_cell "$cell" "$scratch"; then
      record_parse_die "$file" "$((i + 1))" "$RECORD_PARSE_OUT" "$line" || return 1
    fi
    # `record_setup_rows` renders every setup run at attempt 1 and writes no
    # attempt of its own, so there is nothing to invert and a cell carrying
    # one is not its output.
    if [ "${RECORD_PARSE_OUT#*$'\t'}" != 1 ]; then
      record_parse_die "$file" "$((i + 1))" \
        'a setup row carries an attempt, which record_setup_rows never renders' "$line" || return 1
    fi
    setups+=("$(printf '%s\t%s\t%s' "${RECORD_PARSE_OUT%%$'\t'*}" "$conclusion" "$what")")
  done
  if [ "${#setups[@]}" -gt 0 ] && [ "$none_seen" = 1 ]; then
    printf 'record_parse: %s: the Setup section says there are none and then lists some\n' \
      "$file" >&2
    return 1
  fi
  if [ "${#setups[@]}" -eq 0 ] && [ "$none_seen" = 0 ]; then
    printf 'record_parse: %s: the Setup section has neither rows nor the no-setup sentence\n' \
      "$file" >&2
    return 1
  fi

  # -- ## Known gaps (#484 D6) ----------------------------------------------
  # Order is preserved, because determinism is what the round trip grades.
  # The section's own fixed sentences are skipped rather than read as gaps,
  # and anything that is neither is REFUSED by line number: a gap body
  # hard-wrapped across two lines leaves a continuation this arm catches,
  # which is a better diagnostic than the same edit surfacing as a diff two
  # lines further down.
  local -a declared=()
  local gap_none_seen=0 gap_title gap_body gap_rest
  for ((i = gaps_at + 1; i < total; i++)); do
    line="${lines[i]}"
    [ -n "$line" ] || continue
    if record_gap_prose_line "$line" "$RECORD_GAP_NONE"; then
      gap_none_seen=1
      continue
    fi
    record_gap_prose_line "$line" "$RECORD_GAP_PREAMBLE" && continue
    case "$line" in
      '- **'*) ;;
      *)
        record_parse_die "$file" "$((i + 1))" \
          "not a gap line, and not one of the section's own sentences" "$line" || return 1
        ;;
    esac
    gap_rest="${line#- \*\*}"
    # The FIRST separator, so a body may carry `** — `.
    #
    # Byte-identity is NOT what makes that safe, and this comment used to say
    # it was: re-rendering any pair this split produces recreates the line it
    # came from, including a pair cut out of the middle of a title, so the
    # round trip greens a record whose declared title was lost
    # (@claude-bot-andresmgsl, round 1). What makes the DECLARED pair
    # recoverable is that a title may not carry the separator at all —
    # `record_gap_rows` refuses to write such a line and `gap_add` refuses to
    # accept one — so the first separator is always the boundary the writer
    # meant. Nothing is checkable here: after the cut, a title never contains
    # the sequence and a body carrying it is legitimate input D5 requires be
    # rendered verbatim, so a refusal at this site could only fire on correct
    # records. The guard has to live where a pair becomes a line.
    gap_title="${gap_rest%%\*\* — *}"
    if [ "$gap_title" = "$gap_rest" ]; then
      record_parse_die "$file" "$((i + 1))" \
        'the gap line has no `** — ` between its title and its body' "$line" || return 1
    fi
    gap_body="${gap_rest#"$gap_title"\*\* — }"
    if [ -z "$gap_title" ] || [ -z "$gap_body" ]; then
      record_parse_die "$file" "$((i + 1))" \
        'a gap needs a non-empty title and a non-empty body' "$line" || return 1
    fi
    declared+=("$(printf '%s\t%s' "$gap_title" "$gap_body")")
  done
  if [ "${#declared[@]}" -gt 0 ] && [ "$gap_none_seen" = 1 ]; then
    printf 'record_parse: %s: the Known gaps section says there are none and then declares some\n' \
      "$file" >&2
    return 1
  fi
  if [ "${#declared[@]}" -eq 0 ] && [ "$gap_none_seen" = 0 ]; then
    printf 'record_parse: %s: the Known gaps section has neither a gap nor the none-declared sentence\n' \
      "$file" >&2
    return 1
  fi

  # -- the four TSVs, in the shapes the instrument writes -------------------
  {
    printf 'version\t%s\n' "$ver"
    printf 'rc_version\t%s\n' "$rc_version"
    printf 'scratch\t%s\n' "$scratch"
    printf 'attempt\t%s\n' "$attempt"
    printf 'created\t%s\n' "$created"
    printf 'private\t%s\n' "$private"
    printf 'candidate_sha\t%s\n' "$candidate_sha"
    printf 'candidate_ref\t%s\n' "$candidate_ref"
    printf 'fork_repo\t%s\n' "$fork_repo"
    printf 'fork_ref\t%s\n' "$fork_ref"
    printf 'fork_head\t%s\n' "$fork_head"
    printf 'pin\t%s\n' "$pin"
    printf 'disposal\t%s\n' "$disposal"
    printf 'runner\t%s\n' "$runner"
    printf 'stamp\t%s\n' "$stamp"
  } >"$ctx_out"
  printf '%s\n' "${rows[@]}" >"$probes_out"
  : >"$setup_out"
  [ "${#setups[@]}" -eq 0 ] || printf '%s\n' "${setups[@]}" >"$setup_out"
  : >"$gaps_out"
  [ "${#declared[@]}" -eq 0 ] || printf '%s\n' "${declared[@]}" >"$gaps_out"
}

# record_parse_counts <cell> — `<before><TAB><after>` out of a `N → M` cell.
# The two count columns are what every refusal probe is asserted on, so a
# cell that is prose rather than a pair is a parse failure and not a zero.
record_parse_counts() {
  local cell="${1-}" re='^([^ ]+) → ([^ ]+)$'
  [[ "$cell" =~ $re ]] || return 1
  RECORD_PARSE_OUT="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"
}

# record_parse_one <file> <from> <to> <regex> <what> [captures] — the captures
# of the ONE line between two headings matching <regex>, tab-joined into
# RECORD_PARSE_OUT.
#
# Exactly one match is required in both directions. None means the sentence
# the render always writes is not there; more than one means a section was
# duplicated — neither is something `record_render` emits, and answering a
# lookup from the first of two matches is how a parse quietly tolerates a
# record it should have refused.
#
# It reads `lines` out of `record_parse`'s scope rather than taking the file
# again: bash scopes dynamically, the array is the caller's `local`, and
# re-reading the file per field would make the line numbers in the
# diagnostics disagree with the ones the caller already reported.
record_parse_one() {
  local file="${1:?}" from="${2:?}" to="${3:?}" re="${4:?}" what="${5:?}"
  # Not `want`: record_parse holds an array by that name, and bash's dynamic
  # scoping makes the two the same name to a reader and to shellcheck.
  local captures="${6:-1}"
  local i seen=-1 out='' c
  for ((i = from; i < to; i++)); do
    [[ "${lines[i]}" =~ $re ]] || continue
    if [ "$seen" -ge 0 ]; then
      record_parse_die "$file" "$((i + 1))" "$what appears more than once" "${lines[i]}"
      return 1
    fi
    seen="$i"
    out=''
    for ((c = 1; c <= captures; c++)); do
      [ "$c" = 1 ] || out="$out"$'\t'
      out="$out${BASH_REMATCH[c]}"
    done
  done
  if [ "$seen" -lt 0 ]; then
    printf 'record_parse: %s: %s is missing between lines %s and %s\n' \
      "$file" "$what" "$((from + 1))" "$to" >&2
    return 1
  fi
  RECORD_PARSE_OUT="$out"
}

# ---------------------------------------------------------------------------
# Which record shape this is (#373 D9) — because the round trip grades
# EMISSIONS, and two of the three shapes drills/README.md sanctions are
# hand-written by design.
#
# `drills/0.6.2.md` and `drills/0.6.3.md` are doors-unchanged scope rulings
# (#233), and `drill-recorded` blesses a WAIVED record in its own refusal
# text. Neither is `record_render`'s output and neither can be. A guard that
# demanded a round trip of every bare-version tree would red the release
# immediately before 0.7.0 — two correct guards closing a door on each other.
#
# So the class is READ FROM THE RECORD, never from a path list or a version
# list someone must remember to update: each shape declares itself, and the
# declaration is written down in drills/README.md so a record author knows
# which one they are writing.
# ---------------------------------------------------------------------------
RECORD_CLASS=''
RECORD_CLASS_WHY=''

# record_class <record-file> — sets RECORD_CLASS to `emission` or
# `scope-ruling`, and RECORD_CLASS_WHY to the sentence the step prints.
#
# It FAILS CLOSED. A record declaring both shapes, or neither, is graded as an
# emission and must round-trip: "could not tell" resolving to "allowed" is
# `drill-recorded`'s own stated hazard and #373 D5's. The four pre-convention
# records (0.1.0–0.4.0) declare neither and land there by construction; no CI
# path reads them, because the step reads `drills/$ver.md` and nothing else.
#
# SC2016: the discriminator patterns match the record's own Markdown, so their
# backticks are literal bytes and never expansions — the same rule record_parse
# states above. SC2034: both variables are the function's whole return value,
# read by .github/scripts/record-roundtrip.sh and the rehearsal suite.
# shellcheck disable=SC2016,SC2034
record_class() {
  local file="${1:?record_class: record file required}" emission=0 ruling=0
  if [ ! -f "$file" ]; then
    printf 'record_class: %s: no such file\n' "$file" >&2
    return 1
  fi
  # The instrument's own run sentence, which `record_render` writes on line 3
  # of every emission and nothing else writes at all.
  if grep -qE '^Run .* with `drill/rehearsal\.sh` against the ' "$file"; then
    emission=1
  fi
  # The heading a doors-unchanged or WAIVED record opens its claim with.
  if grep -qE '^## Scope ruling — ' "$file"; then
    ruling=1
  fi
  if [ "$emission" = 1 ] && [ "$ruling" = 1 ]; then
    RECORD_CLASS=emission
    RECORD_CLASS_WHY="it declares BOTH shapes — the instrument's run sentence and a scope ruling — so it cannot be classified, and an unclassifiable record is graded as an emission"
    return 0
  fi
  if [ "$emission" = 1 ]; then
    RECORD_CLASS=emission
    RECORD_CLASS_WHY="it carries drill/rehearsal.sh's own run sentence and declares no scope ruling"
    return 0
  fi
  if [ "$ruling" = 1 ]; then
    RECORD_CLASS=scope-ruling
    RECORD_CLASS_WHY="it declares a scope ruling — a doors-unchanged or WAIVED record under drills/README.md, hand-written by design"
    return 0
  fi
  RECORD_CLASS=emission
  RECORD_CLASS_WHY="it declares NEITHER shape — no instrument run sentence and no scope ruling — so it cannot be classified, and an unclassifiable record is graded as an emission"
}

# record_roundtrip <record-file> — the check (#373 D2): the record passes when
# `record_render(record_parse(file))` is byte-identical to the file.
#
# That is a grading of authorship. Any hand-added sentence, any reordered
# field, any second renderer's output fails it, because none of them survive
# being regenerated from what the file itself claims.
record_roundtrip() {
  local file="${1:?record_roundtrip: record file required}" work rc=0
  if [ ! -f "$file" ]; then
    printf 'record_roundtrip: %s: no such file\n' "$file" >&2
    return 1
  fi
  work="$(mktemp -d)" || return 1
  # The parse's own refusal already names the line that defeated it, so
  # nothing is layered on top of it — the second sentence only says which
  # check was asking.
  if ! record_parse "$file" "$work/ctx.tsv" "$work/probes.tsv" "$work/setup.tsv" \
    "$work/gaps.tsv"; then
    rm -rf "$work"
    printf 'record_roundtrip: %s cannot be parsed back into the inputs that would render it, so it cannot be graded as this script'"'"'s emission.\n' \
      "$file" >&2
    return 1
  fi
  if ! record_render "$work/ctx.tsv" "$work/probes.tsv" "$work/setup.tsv" \
    "$work/gaps.tsv" >"$work/rendered.md"; then
    rm -rf "$work"
    printf 'record_roundtrip: %s: record_render refused the inputs parsed back out of it.\n' \
      "$file" >&2
    return 1
  fi
  if cmp -s "$file" "$work/rendered.md"; then
    rm -rf "$work"
    echo "record_roundtrip: $file is byte-identical to record_render's output from the inputs the file itself states — the script's emission, not a hand-written record."
    return 0
  fi
  record_roundtrip_report "$file" "$work/rendered.md"
  rc=$?
  rm -rf "$work"
  [ "$rc" = 0 ] || return "$rc"
  return 1
}

# record_roundtrip_report <record-file> <re-rendered> — the first differing
# line, with both sides. One line and not a whole diff: the re-render's prose
# is computed from the rows, so a single edited count moves several sentences
# and a full diff buries the edit that caused them under its consequences.
record_roundtrip_report() {
  local file="${1:?}" rendered="${2:?}" i max a b
  local -a want=() got=()
  mapfile -t want <"$file"
  mapfile -t got <"$rendered"
  max="${#want[@]}"
  [ "${#got[@]}" -le "$max" ] || max="${#got[@]}"
  printf 'record_roundtrip: %s is not what record_render emits from the inputs it states.\n' \
    "$file" >&2
  for ((i = 0; i < max; i++)); do
    a="${want[i]-}"
    b="${got[i]-}"
    [ "$a" != "$b" ] || continue
    printf '  first difference at line %s:\n' "$((i + 1))" >&2
    if [ "$i" -ge "${#want[@]}" ]; then
      printf '    the record:  (ends at line %s)\n' "${#want[@]}" >&2
    else
      printf '    the record:  %s\n' "$a" >&2
    fi
    if [ "$i" -ge "${#got[@]}" ]; then
      printf '    the re-render: (ends at line %s)\n' "${#got[@]}" >&2
    else
      printf '    the re-render: %s\n' "$b" >&2
    fi
    record_roundtrip_why >&2
    return 0
  done
  # Every line agrees and the bytes do not: the record's final newline is the
  # only thing left, and the render always writes one.
  printf '  every line agrees, so the difference is the trailing newline the render always writes.\n' >&2
  record_roundtrip_why >&2
}

# record_roundtrip_why — the sentence that turns a diff into a diagnosis.
record_roundtrip_why() {
  cat <<'EOF'
  A record is graded by re-render (#373): it must be regenerable from its own
  stated measurements. So this is a line record_render would not have written
  from what this file says — a hand edit, a field out of order, or a count
  that no longer follows from the rows above it. The prose is computed from
  the probe table, so fix the measurement and the sentence follows.
EOF
}
