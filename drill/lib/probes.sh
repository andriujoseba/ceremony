#!/usr/bin/env bash
# The six probes, in doctrine order (#313 D1, D3). Sourced, never run.
#
# The list is drills/README.md's, byte-faithful:
#
#   1. a merge-door ceremony publishes exactly one release and re-arms main
#      to `-dev`;
#   2. a mislabeled ordinary PR is a green NOTICE no-op;
#   3. a bare-version PR without the `release` label refuses;
#   4. a re-run of the completed ceremony refuses;
#   5. a tag-door release from a manual tag;
#   6. a mismatched tag refuses.
#
# Every probe reads the tag count and the release count before and after
# itself. A refusal that leaves a tag or a release behind is a failed probe,
# and that claim is these two measurements — never the prose beside them.
#
# A failed probe does not abort the rehearsal: a failed drill is a valid
# record, and a record that stops at the first surprise hides the five
# probes nobody then ran.

DRILL_PROBE_NAMES="merge-door ceremony
mislabeled ordinary PR
bare-version PR without \`release\`
re-run of the completed ceremony
tag-door release from a manual tag
mismatched tag"

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
# probe's failed row, and five probes that still get asked their question.
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

# probe_merge_and_wait <branch> <title> <label?> — PR, optional label, merge,
# wait. Prints `<run-id><TAB><conclusion>`.
probe_merge_and_wait() {
  local branch="${1:?}" title="${2:?}" label="${3:-}" pr merge_sha
  pr="$(scratch_pr_create "$DRILL_REPO" "$branch" main "$title")" || return 1
  if [ -n "$label" ]; then
    scratch_pr_label "$DRILL_REPO" "$pr" "$label" || return 1
    # Confirmed, never assumed: 0.6.0's probe 2 merged unlabeled because a
    # label write failed and the failure was read after the merge.
    if ! scratch_pr_labels "$DRILL_REPO" "$pr" | grep -qxF "$label"; then
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
  local armed
  armed="$(scratch_version "$DRILL_REPO" main)"
  [ "$armed" = "$DRILL_V2-dev" ] ||
    problems="$problems; main reads '$armed' after the ceremony, expected '$DRILL_V2-dev'"
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
  armed="$(scratch_version "$DRILL_REPO" main)"
  [ "$armed" = "$DRILL_V2-dev" ] ||
    problems="$problems; main reads '$armed' after the tag door, expected it untouched at '$DRILL_V2-dev'"
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
