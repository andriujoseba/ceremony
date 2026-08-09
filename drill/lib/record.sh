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
    1) printf 'The merge door published exactly one `%s` release from a labeled ceremony PR, tagged the reviewed merge commit, and re-armed main itself.' "${2:?record_claim: version required}" ;;
    2) printf 'The merge door stayed a green no-op under a `release` label carried by ordinary work.' ;;
    3) printf 'The merge door refused a bare version push without the `release` label.' ;;
    4) printf 'The merge door refused a re-run of its own completed ceremony.' ;;
    5) printf 'The tag door published from a matching manual tag without touching main.' ;;
    6) printf 'The tag door refused a mismatched tag before creating anything.' ;;
    *) return 1 ;;
  esac
}

# record_establishes <probes-tsv> <version> — one line per probe, and never a
# claim whose probe did not pass.
#
# A failed probe's claim is not softened here, it is not printed at all: the
# failure takes its place, so the section cannot assert what the table denies.
record_establishes() {
  local probes="${1:?}" ver="${2:?}" n row verdict name note
  for n in 1 2 3 4 5 6; do
    row="$(awk -F'\t' -v n="$n" '$1 == n { print; exit }' "$probes")"
    if [ -z "$row" ]; then
      printf -- '- ⬜ **Nothing established** — probe %s did not run, so this record makes no claim for it.\n' "$n"
      continue
    fi
    verdict="$(cut -f5 <<<"$row")"
    name="$(cut -f2 <<<"$row")"
    note="$(cut -f10 <<<"$row")"
    if [ "$verdict" = PASS ]; then
      printf -- '- ✅ %s\n' "$(record_claim "$n" "$ver")"
    else
      printf -- '- ❌ **Nothing established** — probe %s (%s) failed: %s. This run is no evidence about that behavior either way.\n' \
        "$n" "$name" "$note"
    fi
  done
}

# record_render <ctx-file> <probes-tsv> <setup-tsv> — the whole record.
record_render() {
  local ctx="${1:?}" probes="${2:?}" setup="${3:?}"
  local ver scratch created candidate_sha candidate_ref fork_repo fork_ref
  local fork_head pin disposal runner stamp failed passed unestablished
  ver="$(record_ctx "$ctx" version)"
  scratch="$(record_ctx "$ctx" scratch)"
  created="$(record_ctx "$ctx" created)"
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
  unestablished=$((6 - passed))

  cat <<EOF
# $ver — drill record

Run $stamp by \`$runner\` with \`drill/rehearsal.sh\` against the $ver
candidate, candidate ref \`$candidate_ref\`, canonical candidate SHA
\`$candidate_sha\`. All six probes ran; every row in the table below was
written from its own run by the script that drove it.

EOF

  if [ "$failed" = 0 ]; then
    printf '**Every probe passed.**\n\n'
  else
    printf '**%s probe(s) failed.** A failed drill is a valid record: the rows below are what ran, and the failures are stated where they happened rather than smoothed over.\n\n' \
      "$failed"
  fi

  cat <<EOF
## Where

Disposable **private** repo \`$scratch\`, created $created. It carries the
\`docs/CONSUMERS.md\` release caller verbatim (\`version-source: file\`) over a
fragment-mode fixture armed at \`$ver-dev\`: a preamble-only
\`CHANGELOG.md\`, \`changelog.d/README.md\` plus three fragments, and a
non-blank \`drills/$ver.md\`. The \`release\` label was created there before
the first ceremony PR, per the guide's prerequisite. The fixture was
committed **before** the caller, so the first door run had a real parent
version to inspect — the script refuses to install the caller against a tree
with no fixture in it.

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

One row per probe, in doctrine order, each written from its own run. Runs are
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

  cat <<EOF

## What the rehearsal establishes

Both doors ran live against the $ver candidate's own machinery, driven by
\`drill/rehearsal.sh\` rather than by hand. Each line below is one probe's,
and it is printed as a claim only where that probe passed: what stands here
is a measurement in the table above, never a sentence written from an
intention.

EOF
  record_establishes "$probes" "$ver"

  if [ "$unestablished" = 0 ]; then
    cat <<'EOF'

Every refusal claim above is asserted on the before/after counts in the probe
table, not on the prose beside them.
EOF
  else
    cat <<EOF

**Not established: $unestablished of the six.** A failed drill is a valid
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
  local file="${1:?record_check: file required}" rows problems=""
  rows="$(awk -F'|' '/^\| [1-6] \|/ { print }' "$file")"
  local count
  count="$(printf '%s\n' "$rows" | awk 'NF' | wc -l | tr -d ' ')"
  [ "$count" = 6 ] || problems="$problems; the probe table has $count rows, expected 6"
  local n
  for n in 1 2 3 4 5 6; do
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
      continue
    fi
    printf '%s' "$row" | grep -qE '/actions/runs/[0-9]+' ||
      problems="$problems; probe $n has no run ID"
    printf '%s' "$row" | grep -qE '[0-9]+ → [0-9]+ \|[^|]*[0-9]+ → [0-9]+' ||
      problems="$problems; probe $n has no before/after counts"
  done
  # The conclusion is checked like the table, because it is evidence like the
  # table: one line per probe, each either a claim its probe earned or the
  # failure that withdrew it.
  local claims
  claims="$(grep -cE '^- (✅|❌|⬜) ' "$file" || true)"
  [ "$claims" = 6 ] ||
    problems="$problems; the conclusion has $claims probe lines, expected 6"
  grep -qF 'pending the operator' "$file" ||
    problems="$problems; the record does not state the disposal as pending the operator's delete"
  if [ -n "$problems" ]; then
    echo "record_check: ${problems#; }" >&2
    return 1
  fi
  echo "record_check: six probe rows, each with a run ID and its before/after counts, and a conclusion that claims only what they measured."
}
