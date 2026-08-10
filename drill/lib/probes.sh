#!/usr/bin/env bash
# The eight probes, in doctrine order (#313 D1, D3; #321 D1). Sourced,
# never run.
#
# The list is drills/README.md's, byte-faithful:
#
#   1. a merge-door ceremony publishes exactly one release and re-arms main
#      to `-dev`;
#   2. a mislabeled ordinary PR is a green NOTICE no-op;
#   3. a bare-version PR without the `release` label refuses;
#   4. a re-run of the completed ceremony refuses;
#   5. a tag-door release from a manual tag;
#   6. a mismatched tag refuses;
#   7. an rc cut publishes a prerelease and stamps nothing;
#   8. the promotion after it ships the final version.
#
# Every probe reads the tag count and the release count before and after
# itself. A refusal that leaves a tag or a release behind is a failed probe,
# and that claim is these two measurements — never the prose beside them.
#
# A failed probe does not abort the rehearsal: a failed drill is a valid
# record, and a record that stops at the first surprise hides the seven
# probes nobody then ran.

DRILL_PROBE_NAMES="merge-door ceremony
mislabeled ordinary PR
bare-version PR without \`release\`
re-run of the completed ceremony
tag-door release from a manual tag
mismatched tag
rc cut, tag-only and marked prerelease
promotion of the rc to the final version"

# The doctrine list's length. The record grades every probe the doctrine
# names rather than the rows it happens to have been handed, so the count
# lives beside the names and nothing downstream repeats it as a literal —
# the two rc legs arrived as one edit here (#321).
# shellcheck disable=SC2034 # read by drill/lib/record.sh and rehearsal.sh
DRILL_PROBE_COUNT="$(printf '%s\n' "$DRILL_PROBE_NAMES" | wc -l | tr -d ' ')"

# probe_name <n>
probe_name() { sed -n "${1:?probe_name: n required}p" <<<"$DRILL_PROBE_NAMES"; }

# probe_counts <repo> — `<tags><TAB><releases>`, or a refusal.
#
# A count that did not read is not a count. `scratch_tag_count` prints
# nothing when the API errors, and `$((after - before))` over an empty string
# is 0 — which is exactly the delta a refusal probe wants to see, so a
# swallowed read would record a PASS asserted on measurements nobody took.
# The refusal is here, at the point of measurement, rather than left to the
# shape check downstream of the row already being written.
probe_counts() {
  local repo="${1:?probe_counts: repo required}" tags releases
  tags="$(scratch_tag_count "$repo")" || tags=""
  releases="$(scratch_release_count "$repo")" || releases=""
  local kind value
  for kind in tag:"$tags" release:"$releases"; do
    value="${kind#*:}"
    case "$value" in
      '' | *[!0-9]*)
        echo "probe_counts: the ${kind%%:*} count at $repo did not read as a number ('$value') — a refusal probe asserted on a count nobody took is not a measurement." >&2
        return 1
        ;;
    esac
  done
  printf '%s\t%s\n' "$tags" "$releases"
}

# probe_record <n> <run> <attempt> <verdict> <tb> <ta> <rb> <ra> <note>
probe_record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$(probe_name "$1")" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
    >>"$DRILL_PROBES"
  printf 'drill: probe %s (%s) %s — tags %s→%s, releases %s→%s\n' \
    "$1" "$(probe_name "$1")" "$4" "$5" "$6" "$7" "$8" >&2
}

# probe_run <n> <probe-fn> — run one probe without letting it take the
# rehearsal down with it.
#
# The probes are the stretch of this script that talks to a live API over
# minutes, so a failure inside one is not always a door verdict:
# `scratch_run_for` exhausting its polls on a run that never completes is the
# realistic case, and it says nothing about the door. Called bare under
# `set -e` such a probe aborts the script before the archive and the record,
# and the EXIT trap then removes the work directory with `probes.tsv` in it —
# an unarchived scratch repo and no record at all, under a header comment
# promising the record either way. So the abort becomes what it is: this
# probe's failed row, and seven probes that still get asked their question.
probe_run() {
  local n="${1:?probe_run: n required}" fn="${2:?probe_run: probe required}"
  local rows_before rows_after counts status=0
  local tb='?' ta='?' rb='?' ra='?'
  rows_before="$(wc -l <"$DRILL_PROBES")"
  counts="$(probe_counts "$DRILL_REPO")" || counts=""
  [ -z "$counts" ] || IFS=$'\t' read -r tb rb <<<"$counts"
  "$fn" || status=$?
  rows_after="$(wc -l <"$DRILL_PROBES")"
  # The probe reached its own verdict and recorded it: that row is the answer,
  # whatever the probe's exit status was on the way out of it.
  if [ "$rows_after" -gt "$rows_before" ]; then
    return 0
  fi
  counts="$(probe_counts "$DRILL_REPO")" || counts=""
  [ -z "$counts" ] || IFS=$'\t' read -r ta ra <<<"$counts"
  probe_record "$n" '—' 1 FAIL "$tb" "$ta" "$rb" "$ra" \
    "aborted before it reached a verdict (exit $status) — this run is no evidence about this probe; the counts either side are the drill's own, not the door's"
}

# probe_setup_record <run> <conclusion> <what>
probe_setup_record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$DRILL_SETUP"
}

# probe_verdict <expected-conclusion> <got> <tb> <ta> <rb> <ra> <want-tag-delta> <want-release-delta>
#
# Prints the failure list, empty when the probe held. Kept separate from the
# probes so the stubbed suite can drive the assertion itself: this function is
# where "the refusal created nothing" is actually decided.
probe_verdict() {
  local want_conc="$1" got_conc="$2" tb="$3" ta="$4" rb="$5" ra="$6" dt="$7" dr="$8"
  local problems=""
  [ "$got_conc" = "$want_conc" ] ||
    problems="$problems; the run concluded '$got_conc', expected '$want_conc'"
  [ "$((ta - tb))" = "$dt" ] ||
    problems="$problems; tags moved $tb→$ta, expected a delta of $dt"
  [ "$((ra - rb))" = "$dr" ] ||
    problems="$problems; releases moved $rb→$ra, expected a delta of $dr"
  printf '%s' "${problems#; }"
}

# probe_branch <branch> <from-sha> — a branch for one probe.
probe_branch() {
  scratch_ref_create "$DRILL_REPO" "refs/heads/${1:?}" "${2:?}"
}

# probe_stage <name> — a copy of the mirrored main tree for one probe to edit.
probe_stage() {
  local dir="$DRILL_WORK/${1:?}"
  rm -rf "$dir"
  cp -R "$DRILL_STAGE" "$dir"
  printf '%s\n' "$dir"
}

# probe_manifest <stage> <paths…> — an add line per path, into a fresh file.
probe_manifest() {
  local stage="${1:?}" manifest path
  shift
  manifest="$stage.manifest"
  : >"$manifest"
  for path in "$@"; do
    printf 'A\t%s\t%s\n' "$path" "$stage/$path" >>"$manifest"
  done
  printf '%s\n' "$manifest"
}

# probe_trim_blank <file> — the file with its trailing blank lines dropped.
#
# `changelog_section` prints the blank line that separates a section from the
# next heading and `changelog-assemble --check` does not, so the promotion's
# "stamped with the assembled body" claim would fail on that separator alone.
# Trailing blanks only: a blank line inside the body is content.
probe_trim_blank() {
  awk '{ lines[NR] = $0; if (NF) last = NR }
       END { for (i = 1; i <= last; i++) print lines[i] }' "${1:?}"
}

# probe_fragment_paths <repo> <ref> <out-file> — the fragment directory's
# paths at a ref, sorted. The rc leg's "every fragment survives" and the
# promotion's "fragments consumed" are both this list, compared.
probe_fragment_paths() {
  scratch_paths "${1:?}" "${2:?}" | grep '^changelog\.d/' | sort >"${3:?}" || :
}

# probe_merge_and_wait <branch> <title> <label?> — PR, optional label, merge,
# wait. Prints `<run-id><TAB><conclusion>`.
probe_merge_and_wait() {
  local branch="${1:?}" title="${2:?}" label="${3:-}" pr merge_sha labels
  pr="$(scratch_pr_create "$DRILL_REPO" "$branch" main "$title")" || return 1
  if [ -n "$label" ]; then
    scratch_pr_label "$DRILL_REPO" "$pr" "$label" || return 1
    # Confirmed, never assumed: 0.6.0's probe 2 merged unlabeled because a
    # label write failed and the failure was read after the merge. `nonempty`
    # because this read follows the write directly above it — an empty label
    # list there is a stale index, and refusing to merge on it would abort a
    # probe over a read rather than over the label (#369 D3).
    #
    # The read is taken before it is judged, rather than piped into the `grep`
    # that judges it (#369 D6). Left of a pipe the read's exit status is the
    # `grep`'s, so an exhausted read reached the refusal below and said the PR
    # did not carry a label nobody had read — the false claim D4 retires, one
    # layer up. Two refusals now, because they are two different facts.
    if ! labels="$(scratch_pr_labels "$DRILL_REPO" "$pr" nonempty)"; then
      echo "drill: the labels on PR #$pr did not read back after the write, so the '$label' label was never checked — refusing to merge on a read that did not answer, which is not the same as a label that is not there." >&2
      return 1
    fi
    if ! grep -qxF "$label" <<<"$labels"; then
      echo "drill: PR #$pr did not carry the '$label' label after the write — refusing to merge an unlabeled tree into a probe that is about the label." >&2
      return 1
    fi
  fi
  merge_sha="$(scratch_pr_merge "$DRILL_REPO" "$pr")" || return 1
  scratch_run_for "$DRILL_REPO" "$merge_sha"
}

# --------------------------------------------------------------------------
# Probe 1 — a merge-door ceremony publishes exactly one release and re-arms
# main to -dev.
# --------------------------------------------------------------------------
probe_1_ceremony() {
  local before after stage manifest run conc tb ta rb ra problems="" frag
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"
  probe_branch probe1-ceremony "$(scratch_ref_sha "$DRILL_REPO" main)" || return 1
  stage="$(probe_stage probe1)"
  printf '%s\n' "$DRILL_V1" >"$stage/VERSION"
  # The candidate's own assembler, run from the candidate checkout this
  # script lives in: the ceremony PR's section must be the release path's
  # real output, not a drill-local imitation of it.
  ceremony_assemble "$stage" "$DRILL_V1" "$DRILL_DATE" "$DRILL_ROOT" || return 1
  manifest="$(probe_manifest "$stage" VERSION CHANGELOG.md)"
  for frag in 1 2 3; do
    [ -f "$stage/changelog.d/$frag.md" ] ||
      printf 'D\tchangelog.d/%s.md\n' "$frag" >>"$manifest"
  done
  scratch_commit "$DRILL_REPO" probe1-ceremony \
    "release $DRILL_V1 — the ceremony PR's own commit" "$manifest" >/dev/null || return 1
  IFS=$'\t' read -r run conc < <(probe_merge_and_wait probe1-ceremony \
    "release $DRILL_V1" release) || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  problems="$(probe_verdict success "$conc" "$tb" "$ta" "$rb" "$ra" 1 1)"
  scratch_release_tags "$DRILL_REPO" | grep -qxF "$DRILL_V1" ||
    problems="$problems; no '$DRILL_V1' release exists after the ceremony"
  # Branched on the read, not on the string it returned. `probe_run` calls each
  # probe as `"$fn" || status=$?`, which suppresses `set -e` inside it — so an
  # exhausted read left `armed` empty here and the probe recorded "main reads
  # '' after the ceremony", a claim about the world derived from a read that
  # never happened. That is D4's lie one layer up from drill_read, and the
  # honest message it prints to stderr does not reach the record (#369).
  local armed
  if armed="$(scratch_version "$DRILL_REPO" main nonempty)"; then
    [ "$armed" = "$DRILL_V2-dev" ] ||
      problems="$problems; main reads '$armed' after the ceremony, expected '$DRILL_V2-dev'"
  else
    problems="$problems; VERSION did not read back off main after the ceremony, so the re-arm was never checked"
  fi
  # The mirror follows what the door did to main: the re-arm is the door's
  # own commit, not the script's.
  printf '%s-dev\n' "$DRILL_V2" >"$DRILL_STAGE/VERSION"
  cp "$stage/CHANGELOG.md" "$DRILL_STAGE/CHANGELOG.md"
  rm -f "$DRILL_STAGE"/changelog.d/[123].md
  if [ -z "$problems" ]; then
    probe_record 1 "$run" 1 PASS "$tb" "$ta" "$rb" "$ra" \
      "exactly one \`$DRILL_V1\` release; main re-armed to \`$DRILL_V2-dev\`"
  else
    probe_record 1 "$run" 1 FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
}

# --------------------------------------------------------------------------
# Probe 2 — a mislabeled ordinary PR is a green NOTICE no-op. The label alone
# ships nothing; the version transition is what tells a ceremony from
# ordinary work on the release machinery.
# --------------------------------------------------------------------------
probe_2_mislabeled() {
  local before after stage manifest run conc tb ta rb ra problems
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"
  probe_branch probe2-mislabeled "$(scratch_ref_sha "$DRILL_REPO" main)" || return 1
  stage="$(probe_stage probe2)"
  printf -- '- Ordinary work under the release label, shipping nothing (#313).\n' \
    >"$stage/changelog.d/9.md"
  manifest="$(probe_manifest "$stage" changelog.d/9.md)"
  scratch_commit "$DRILL_REPO" probe2-mislabeled \
    "ordinary work, labeled release" "$manifest" >/dev/null || return 1
  IFS=$'\t' read -r run conc < <(probe_merge_and_wait probe2-mislabeled \
    "ordinary work under the release label" release) || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  problems="$(probe_verdict success "$conc" "$tb" "$ta" "$rb" "$ra" 0 0)"
  cp "$stage/changelog.d/9.md" "$DRILL_STAGE/changelog.d/9.md"
  if [ -z "$problems" ]; then
    probe_record 2 "$run" 1 PASS "$tb" "$ta" "$rb" "$ra" \
      "green NOTICE no-op under the label; nothing created"
  else
    probe_record 2 "$run" 1 FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
}

# --------------------------------------------------------------------------
# Probe 3 — a bare-version PR without the `release` label refuses (decide's
# row 5). The refusal is loud: the job is red and nothing is created.
# --------------------------------------------------------------------------
probe_3_bare() {
  local before after stage manifest run conc tb ta rb ra problems repair_run
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"
  probe_branch probe3-bare "$(scratch_ref_sha "$DRILL_REPO" main)" || return 1
  stage="$(probe_stage probe3)"
  printf '%s\n' "$DRILL_V2" >"$stage/VERSION"
  manifest="$(probe_manifest "$stage" VERSION)"
  scratch_commit "$DRILL_REPO" probe3-bare \
    "bump to bare $DRILL_V2 with no label" "$manifest" >/dev/null || return 1
  IFS=$'\t' read -r run conc < <(probe_merge_and_wait probe3-bare \
    "bare $DRILL_V2, unlabeled") || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  problems="$(probe_verdict failure "$conc" "$tb" "$ta" "$rb" "$ra" 0 0)"
  if [ -z "$problems" ]; then
    probe_record 3 "$run" 1 PASS "$tb" "$ta" "$rb" "$ra" \
      "refused at decide (row 5); no tag, no release"
  else
    probe_record 3 "$run" 1 FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
  # Re-arm main: the refusal left a bare version on main, and the remaining
  # probes need an armed tree. This is setup, not a probe, and it gets its
  # own line in the record — a run the record does not explain is
  # indistinguishable from a door that failed.
  stage="$(probe_stage rearm)"
  printf '%s-dev\n' "$DRILL_V2" >"$stage/VERSION"
  manifest="$(probe_manifest "$stage" VERSION)"
  local rearm_sha
  rearm_sha="$(scratch_commit "$DRILL_REPO" main \
    "re-arm main to $DRILL_V2-dev after probe 3's refusal" "$manifest")" || return 1
  IFS=$'\t' read -r repair_run conc < <(scratch_run_for "$DRILL_REPO" "$rearm_sha") || return 1
  probe_setup_record "$repair_run" "$conc" \
    "re-arming main to \`$DRILL_V2-dev\` after probe 3's refusal left a bare version there — decide's row 2, a -dev tree that changed"
}

# --------------------------------------------------------------------------
# Probe 4 — a re-run of the completed ceremony refuses at the nothing-exists
# assert. It must be the same run at a later attempt: the door's own guard
# re-decided against facts that have not changed is the point, and a fresh
# run would be a different probe.
# --------------------------------------------------------------------------
probe_4_rerun() {
  local before after run attempt conc tb ta rb ra problems
  run="$(awk -F'\t' '$1 == 1 { print $3; exit }' "$DRILL_PROBES")"
  if [ -z "$run" ]; then
    echo "drill: probe 4 has no probe-1 run to re-run — the ceremony probe must run first." >&2
    return 1
  fi
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"
  IFS=$'\t' read -r attempt conc < <(scratch_run_rerun "$DRILL_REPO" "$run") || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  problems="$(probe_verdict failure "$conc" "$tb" "$ta" "$rb" "$ra" 0 0)"
  if [ -z "$problems" ]; then
    probe_record 4 "$run" "$attempt" PASS "$tb" "$ta" "$rb" "$ra" \
      "refused at the nothing-exists assert; the release count stayed $ra"
  else
    probe_record 4 "$run" "$attempt" FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
}

# --------------------------------------------------------------------------
# Probe 5 — the tag door publishes from a manual tag matching its tree. The
# tagged tree sits on a side branch, not main: the tag door takes no bump
# step, and pointing it at a branch proves that without a bare version ever
# resting on main.
# --------------------------------------------------------------------------
probe_5_tag() {
  local before after stage manifest run conc tb ta rb ra problems sha armed
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"
  probe_branch probe5-tag "$(scratch_ref_sha "$DRILL_REPO" main)" || return 1
  stage="$(probe_stage probe5)"
  printf '%s\n' "$DRILL_V2" >"$stage/VERSION"
  ceremony_assemble "$stage" "$DRILL_V2" "$DRILL_DATE" "$DRILL_ROOT" || return 1
  manifest="$(probe_manifest "$stage" VERSION CHANGELOG.md)"
  [ -f "$stage/changelog.d/9.md" ] ||
    printf 'D\tchangelog.d/9.md\n' >>"$manifest"
  sha="$(scratch_commit "$DRILL_REPO" probe5-tag \
    "the tag door's tree at $DRILL_V2" "$manifest")" || return 1
  scratch_ref_create "$DRILL_REPO" "refs/tags/$DRILL_V2" "$sha" || return 1
  IFS=$'\t' read -r run conc < <(scratch_run_for "$DRILL_REPO" "$sha") || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  problems="$(probe_verdict success "$conc" "$tb" "$ta" "$rb" "$ra" 1 1)"
  scratch_release_tags "$DRILL_REPO" | grep -qxF "$DRILL_V2" ||
    problems="$problems; no '$DRILL_V2' release exists after the tag door ran"
  if armed="$(scratch_version "$DRILL_REPO" main nonempty)"; then
    [ "$armed" = "$DRILL_V2-dev" ] ||
      problems="$problems; main reads '$armed' after the tag door, expected it untouched at '$DRILL_V2-dev'"
  else
    problems="$problems; VERSION did not read back off main after the tag door, so 'main untouched' was never checked"
  fi
  if [ -z "$problems" ]; then
    probe_record 5 "$run" 1 PASS "$tb" "$ta" "$rb" "$ra" \
      "\`$DRILL_V2\` published from its own changelog section; main untouched"
  else
    probe_record 5 "$run" 1 FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
}

# --------------------------------------------------------------------------
# Probe 6 — a mismatched tag refuses before publication. The probe tag is the
# operator's artefact, never the workflow's: it is removed afterwards, and
# the counts either side of the probe are what proves the door created
# nothing.
# --------------------------------------------------------------------------
probe_6_mismatched_tag() {
  local before after stage manifest run conc tb ta rb ra problems sha
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"
  probe_branch probe6-mismatch "$(scratch_ref_sha "$DRILL_REPO" main)" || return 1
  stage="$(probe_stage probe6)"
  printf 'A tree whose VERSION is not 9.9.9.\n' >"$stage/PROBE6.md"
  manifest="$(probe_manifest "$stage" PROBE6.md)"
  sha="$(scratch_commit "$DRILL_REPO" probe6-mismatch \
    "a tree for the mismatched tag to disagree with" "$manifest")" || return 1
  scratch_ref_create "$DRILL_REPO" refs/tags/9.9.9 "$sha" || return 1
  IFS=$'\t' read -r run conc < <(scratch_run_for "$DRILL_REPO" "$sha") || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  # The probe tag is counted out before the comparison: it is the operator's
  # ref, and leaving it in the after-count would read as a door that created
  # something.
  ta=$((ta - 1))
  problems="$(probe_verdict failure "$conc" "$tb" "$ta" "$rb" "$ra" 0 0)"
  if scratch_release_tags "$DRILL_REPO" | grep -qxF 9.9.9; then
    problems="$problems; a '9.9.9' release exists — the door published from a mismatched tag"
  fi
  scratch_ref_delete "$DRILL_REPO" tags/9.9.9 || return 1
  if [ -z "$problems" ]; then
    probe_record 6 "$run" 1 PASS "$tb" "$ta" "$rb" "$ra" \
      "refused before publication; no \`9.9.9\` release, and the probe tag was removed afterwards (its own ref is excluded from the after-count)"
  else
    probe_record 6 "$run" 1 FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
}

# --------------------------------------------------------------------------
# Probe 7 — the rc cut. A labeled ceremony PR bumping to `X.Y.Z-rc1` is a
# shippable ceremony (only `-dev` is special-cased, so an rc transition
# reaches decide's row 6), and what it ships is tag-only: the notes are
# assembled from the fragments, which survive it, `CHANGELOG.md` is not
# touched at all, the release is marked a prerelease, and the re-arm is
# arithmetic here too — `X.Y.Z-rc(N+1)-dev`.
#
# The ladder starts from an armed `-dev` tree, and the probes above leave
# main at `$DRILL_V2-dev` with `$DRILL_V2` already published by the tag door,
# which touches main by design. So this probe arms main at `$DRILL_V3-dev`
# first — the post-release bump nothing else makes — and seeds one more
# fragment there, so "every fragment survives" is measured over a set rather
# than over a file. That commit is setup, not a probe, and it gets its own
# line in the record for the reason probe 3's re-arm does. The before-counts
# are taken ahead of it, so a setup commit that somehow published lands in
# this probe's own delta rather than beside it.
# --------------------------------------------------------------------------
probe_7_rc_cut() {
  local before after stage manifest run conc tb ta rb ra problems=""
  local arm_sha arm_run arm_conc prerelease armed
  local changelog_before="$DRILL_WORK/probe7-changelog.before"
  local changelog_after="$DRILL_WORK/probe7-changelog.after"
  local frags_before="$DRILL_WORK/probe7-fragments.before"
  local frags_after="$DRILL_WORK/probe7-fragments.after"
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"

  stage="$(probe_stage rc-arm)"
  printf '%s-dev\n' "$DRILL_V3" >"$stage/VERSION"
  printf -- '- A second fragment, so the rc legs prove a set survives rather than a file (#321).\n' \
    >"$stage/changelog.d/10.md"
  manifest="$(probe_manifest "$stage" VERSION changelog.d/10.md)"
  arm_sha="$(scratch_commit "$DRILL_REPO" main \
    "arm the rc ladder at $DRILL_V3-dev, with one more fragment for it to assemble" \
    "$manifest")" || return 1
  IFS=$'\t' read -r arm_run arm_conc < <(scratch_run_for "$DRILL_REPO" "$arm_sha") || return 1
  probe_setup_record "$arm_run" "$arm_conc" \
    "arming main at \`$DRILL_V3-dev\` before the rc legs and seeding a second fragment there — decide's row 2, a -dev tree that changed. \`$DRILL_V2\` was published by the tag door, which leaves main alone by design, so this is the post-release bump nothing else makes"
  cp "$stage/VERSION" "$DRILL_STAGE/VERSION"
  cp "$stage/changelog.d/10.md" "$DRILL_STAGE/changelog.d/10.md"

  # The two states an rc must not disturb, read off main before the cut.
  # `nonempty`: main was written by the arming commit a few lines up, so an
  # empty answer here is a stale index and not a repo without a CHANGELOG.
  scratch_file "$DRILL_REPO" main CHANGELOG.md "$changelog_before" nonempty || return 1
  probe_fragment_paths "$DRILL_REPO" main "$frags_before"

  probe_branch probe7-rc-cut "$(scratch_ref_sha "$DRILL_REPO" main)" || return 1
  stage="$(probe_stage probe7)"
  printf '%s\n' "$DRILL_RC1" >"$stage/VERSION"
  # The version and the rc's own drill record, and nothing else: an rc stamps
  # no section and consumes no fragment, so those are the only two files a
  # ceremony PR cutting one has to carry. Every rc that ships carries its own
  # record, which is why the emission names this path (#321 D4).
  # shellcheck disable=SC2016 # backticks are the record's own Markdown
  printf '# %s — drill record\n\nThe rc legs of `drill/rehearsal.sh`, run against this scratch repo.\n' \
    "$DRILL_RC1" >"$stage/drills/$DRILL_RC1.md"
  manifest="$(probe_manifest "$stage" VERSION "drills/$DRILL_RC1.md")"
  scratch_commit "$DRILL_REPO" probe7-rc-cut \
    "release $DRILL_RC1 — the rc ceremony PR bumps the version and nothing else" \
    "$manifest" >/dev/null || return 1
  IFS=$'\t' read -r run conc < <(probe_merge_and_wait probe7-rc-cut \
    "release $DRILL_RC1" release) || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  problems="$(probe_verdict success "$conc" "$tb" "$ta" "$rb" "$ra" 1 1)"
  scratch_release_tags "$DRILL_REPO" | grep -qxF "$DRILL_RC1" ||
    problems="$problems; no '$DRILL_RC1' release exists after the rc cut"
  prerelease="$(scratch_release_prerelease "$DRILL_REPO" "$DRILL_RC1")" || prerelease="unread"
  [ "$prerelease" = true ] ||
    problems="$problems; the '$DRILL_RC1' release reports isPrerelease: $prerelease, expected true"
  if scratch_file "$DRILL_REPO" main CHANGELOG.md "$changelog_after" nonempty; then
    cmp -s "$changelog_before" "$changelog_after" ||
      problems="$problems; CHANGELOG.md is not byte-identical across the rc cut — an rc is tag-only and stamps no section"
  else
    problems="$problems; CHANGELOG.md did not read back after the rc cut, so the byte comparison was never taken"
  fi
  probe_fragment_paths "$DRILL_REPO" main "$frags_after"
  cmp -s "$frags_before" "$frags_after" ||
    problems="$problems; the fragment set changed across the rc cut ($(tr '\n' ' ' <"$frags_before")→ $(tr '\n' ' ' <"$frags_after")) — an rc assembles its notes and consumes nothing"
  if armed="$(scratch_version "$DRILL_REPO" main nonempty)"; then
    [ "$armed" = "$DRILL_RC2-dev" ] ||
      problems="$problems; main reads '$armed' after the rc cut, expected '$DRILL_RC2-dev'"
  else
    problems="$problems; VERSION did not read back off main after the rc cut, so the re-arm was never checked"
  fi
  # The mirror follows what the door did to main, as probe 1's does.
  printf '%s-dev\n' "$DRILL_RC2" >"$DRILL_STAGE/VERSION"
  if [ -z "$problems" ]; then
    probe_record 7 "$run" 1 PASS "$tb" "$ta" "$rb" "$ra" \
      "\`$DRILL_RC1\` published as a prerelease; \`CHANGELOG.md\` byte-identical either side, every fragment still there, main re-armed to \`$DRILL_RC2-dev\`"
  else
    probe_record 7 "$run" 1 FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
}

# --------------------------------------------------------------------------
# Probe 8 — the promotion. A ceremony PR to bare `X.Y.Z` after the rc ships
# the full release the candidates were rehearsing: the fragments the rc left
# alone are consumed, `## X.Y.Z` carries the body they assemble to, and the
# candidate keeps its prerelease mark — a promotion that relabels the rc it
# came from rewrites published history, so that is a failed probe and not a
# tidy-up.
# --------------------------------------------------------------------------
probe_8_promotion() {
  local before after stage manifest run conc tb ta rb ra problems=""
  local frag prerelease armed leftover
  local expected="$DRILL_WORK/probe8-notes.expected"
  local stamped="$DRILL_WORK/probe8-notes.stamped"
  local changelog_after="$DRILL_WORK/probe8-changelog.after"
  local frags_after="$DRILL_WORK/probe8-fragments.after"
  before="$(probe_counts "$DRILL_REPO")"
  tb="$(cut -f1 <<<"$before")"
  rb="$(cut -f2 <<<"$before")"
  probe_branch probe8-promotion "$(scratch_ref_sha "$DRILL_REPO" main)" || return 1
  stage="$(probe_stage probe8)"
  printf '%s\n' "$DRILL_V3" >"$stage/VERSION"
  # Read before the assembler consumes anything: this is the body the rc
  # published its own notes from, and the promotion's section must be it.
  (cd "$stage" && "$DRILL_ROOT/bin/changelog-assemble" "$DRILL_V3" --check) \
    >"$expected" || return 1
  ceremony_assemble "$stage" "$DRILL_V3" "$DRILL_DATE" "$DRILL_ROOT" || return 1
  manifest="$(probe_manifest "$stage" VERSION CHANGELOG.md)"
  for frag in 9 10; do
    [ -f "$stage/changelog.d/$frag.md" ] ||
      printf 'D\tchangelog.d/%s.md\n' "$frag" >>"$manifest"
  done
  scratch_commit "$DRILL_REPO" probe8-promotion \
    "release $DRILL_V3 — the promotion's own ceremony PR" "$manifest" >/dev/null || return 1
  IFS=$'\t' read -r run conc < <(probe_merge_and_wait probe8-promotion \
    "release $DRILL_V3" release) || return 1
  after="$(probe_counts "$DRILL_REPO")"
  ta="$(cut -f1 <<<"$after")"
  ra="$(cut -f2 <<<"$after")"
  problems="$(probe_verdict success "$conc" "$tb" "$ta" "$rb" "$ra" 1 1)"
  scratch_release_tags "$DRILL_REPO" | grep -qxF "$DRILL_V3" ||
    problems="$problems; no '$DRILL_V3' release exists after the promotion"
  prerelease="$(scratch_release_prerelease "$DRILL_REPO" "$DRILL_V3")" || prerelease="unread"
  [ "$prerelease" = false ] ||
    problems="$problems; the '$DRILL_V3' release reports isPrerelease: $prerelease, expected false — the promotion is the final version"
  prerelease="$(scratch_release_prerelease "$DRILL_REPO" "$DRILL_RC1")" || prerelease="unread"
  [ "$prerelease" = true ] ||
    problems="$problems; the '$DRILL_RC1' release reports isPrerelease: $prerelease after the promotion — promoting must not retroactively relabel the candidate"
  if scratch_file "$DRILL_REPO" main CHANGELOG.md "$changelog_after" nonempty; then
    changelog_section "$changelog_after" "$DRILL_V3" >"$stamped"
    if ! cmp -s <(probe_trim_blank "$expected") <(probe_trim_blank "$stamped"); then
      problems="$problems; the '## $DRILL_V3' section on main is not the body its fragments assemble to"
    fi
  else
    problems="$problems; CHANGELOG.md did not read back after the promotion, so the stamped section was never compared"
  fi
  probe_fragment_paths "$DRILL_REPO" main "$frags_after"
  grep -qxF changelog.d/README.md "$frags_after" ||
    problems="$problems; changelog.d/README.md is gone after the promotion — the directory's marker survives the consumption"
  leftover="$(grep -vxF changelog.d/README.md "$frags_after" | tr '\n' ' ')"
  [ -z "$leftover" ] ||
    problems="$problems; fragments survived the promotion ($leftover) — a final consumes them"
  if armed="$(scratch_version "$DRILL_REPO" main nonempty)"; then
    [ "$armed" = "$DRILL_V4-dev" ] ||
      problems="$problems; main reads '$armed' after the promotion, expected '$DRILL_V4-dev'"
  else
    problems="$problems; VERSION did not read back off main after the promotion, so the re-arm was never checked"
  fi
  if [ -z "$problems" ]; then
    probe_record 8 "$run" 1 PASS "$tb" "$ta" "$rb" "$ra" \
      "\`$DRILL_V3\` published as a full release from the body its fragments assemble to; they are consumed, \`$DRILL_RC1\` is still a prerelease, and main re-armed to \`$DRILL_V4-dev\`"
  else
    probe_record 8 "$run" 1 FAIL "$tb" "$ta" "$rb" "$ra" "${problems#; }"
  fi
}
