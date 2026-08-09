#!/usr/bin/env bash
# drill/rehearsal.sh — the release drill, run by a script (#313).
#
# `drills/` is the record, not the instrument; this is the instrument. It
# automates drills/README.md's rehearsal end to end — scratch repo, armed
# fixture, caller stub at a rewritten fork pin, the six probes in doctrine
# order, the archive, and the record — because a manual hour of hand-steps
# loses to a waiver every time and a script does not.
#
# Two refusals are wired into the instrument rather than left to its
# operator, because both are incidents:
#
#   * it archives and never deletes — `delete_repo` is absent from fleet
#     tokens by doctrine, so the delete is printed as the operator's own step
#     and the 403 wall is never retried (#135);
#   * it refuses to pin the caller stub at a tag-named ref on the canonical
#     repo — such a ref shadows the tag for every consumer until someone
#     deletes it (the 0.1.0 shadow-tag rule).
#
# A failed probe is not a failed run: the record is emitted either way, with
# the failures where they happened. A drill that stops at the first surprise
# hides the probes nobody then ran.
set -euo pipefail

DRILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/version.sh
source "$DRILL_ROOT/lib/version.sh"
# shellcheck source=drill/lib/scratch.sh
source "$DRILL_ROOT/drill/lib/scratch.sh"
# shellcheck source=drill/lib/candidate.sh
source "$DRILL_ROOT/drill/lib/candidate.sh"
# shellcheck source=drill/lib/fixture.sh
source "$DRILL_ROOT/drill/lib/fixture.sh"
# shellcheck source=drill/lib/probes.sh
source "$DRILL_ROOT/drill/lib/probes.sh"
# shellcheck source=drill/lib/record.sh
source "$DRILL_ROOT/drill/lib/record.sh"

usage() {
  cat >&2 <<'EOF'
usage: drill/rehearsal.sh --owner <login> --version <X.Y.Z>
                          --fork-ref <owner/repo@ref> --candidate-sha <sha>
                          [--repo-name <name>] [--candidate-ref <ref>]
                          [--out <file>] [--date <YYYY-MM-DD>]

  --owner          where the disposable private scratch repo is created
  --version        the candidate's release version; the fixture arms X.Y.Z-dev
  --fork-ref       the stub source and the ref to create there, `owner/repo@ref`
  --candidate-sha  the canonical candidate SHA every CEREMONY_SELF_REF is
                   rewritten to on that fork ref
  --repo-name      scratch repo name (default: ceremony-drill-<version>)
  --candidate-ref  the candidate branch, recorded (default: the fork ref)
  --out            where the record is written (default: ./<version>-drill.md)
  --date           the ceremony's changelog stamp (default: today, UTC)

Run it from a checkout of the candidate: the ceremony probe assembles its
changelog section with the candidate's own bin/changelog-assemble.
EOF
  exit 2
}

refuse() {
  printf 'drill: %s\n' "$1" >&2
  exit 1
}

owner=""
version=""
fork_spec=""
candidate_sha=""
repo_name=""
candidate_ref=""
out=""
stamp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) [ $# -ge 2 ] || usage; owner="$2"; shift ;;
    --version) [ $# -ge 2 ] || usage; version="$2"; shift ;;
    --fork-ref) [ $# -ge 2 ] || usage; fork_spec="$2"; shift ;;
    --candidate-sha) [ $# -ge 2 ] || usage; candidate_sha="$2"; shift ;;
    --repo-name) [ $# -ge 2 ] || usage; repo_name="$2"; shift ;;
    --candidate-ref) [ $# -ge 2 ] || usage; candidate_ref="$2"; shift ;;
    --out) [ $# -ge 2 ] || usage; out="$2"; shift ;;
    --date) [ $# -ge 2 ] || usage; stamp="$2"; shift ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
  shift
done

[ -n "$owner" ] || usage
[ -n "$version" ] || usage
[ -n "$fork_spec" ] || usage
[ -n "$candidate_sha" ] || usage

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  refuse "--version '$version' is not a bare X.Y.Z. The fixture arms X.Y.Z-dev and the ceremony probe ships X.Y.Z; an rc is #321's leg, not this one."
case "$fork_spec" in
  */*@*) ;;
  *) refuse "--fork-ref '$fork_spec' is not 'owner/repo@ref'." ;;
esac
fork_repo="${fork_spec%@*}"
fork_ref="${fork_spec##*@}"
[ -n "$fork_ref" ] || refuse "--fork-ref '$fork_spec' names no ref."

# D4, first refusal — checked before anything is created anywhere.
pin_assert_fork_ref "$fork_repo" "$fork_ref" || exit 1

for tool in gh jq base64; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool is required and is not on PATH."
done
[ -x "$DRILL_ROOT/bin/changelog-assemble" ] ||
  refuse "$DRILL_ROOT/bin/changelog-assemble is missing — run this from a checkout of the candidate, whose own assembler the ceremony probe must use."

DRILL_V1="$version"
DRILL_V2="$(version_next_dev "$version")"
DRILL_V2="${DRILL_V2%-dev}"
DRILL_DATE="${stamp:-$(date -u +%Y-%m-%d)}"
DRILL_REPO="$owner/${repo_name:-ceremony-drill-$version}"
DRILL_WORK="$(mktemp -d)"
DRILL_STAGE="$DRILL_WORK/stage"
DRILL_PROBES="$DRILL_WORK/probes.tsv"
DRILL_SETUP="$DRILL_WORK/setup.tsv"
out="${out:-$PWD/$version-drill.md}"
: >"$DRILL_PROBES"
: >"$DRILL_SETUP"
export DRILL_ROOT DRILL_V1 DRILL_V2 DRILL_DATE DRILL_REPO DRILL_WORK DRILL_STAGE
export DRILL_PROBES DRILL_SETUP
trap 'rm -rf "$DRILL_WORK"' EXIT

runner="$(drill_gh api user --jq '.login')" || refuse "cannot read the authenticated login from gh."

printf 'drill: %s rehearsal — scratch %s, candidate %s, fork %s@%s\n' \
  "$DRILL_V1" "$DRILL_REPO" "$candidate_sha" "$fork_repo" "$fork_ref" >&2

# ---- the scratch repo -----------------------------------------------------
scratch_create "$DRILL_REPO"
created="$(scratch_created_at "$DRILL_REPO")"

# ---- the armed fixture, BEFORE the caller (the 0.4.0 lesson) --------------
fixture_write "$DRILL_STAGE" "$DRILL_V1"
fixture_manifest="$DRILL_WORK/fixture.manifest"
: >"$fixture_manifest"
while IFS= read -r path; do
  printf 'A\t%s\t%s\n' "$path" "$DRILL_STAGE/$path" >>"$fixture_manifest"
done < <(fixture_paths "$DRILL_V1")
scratch_commit "$DRILL_REPO" main \
  "the armed fixture at $DRILL_V1-dev" "$fixture_manifest" >/dev/null

# ---- the candidate pin, on a fork ref and never on the canonical repo -----
fork_head="$(fork_ref_prepare "$fork_repo" "$fork_ref" "$candidate_sha" "$DRILL_WORK")"
pin="$(fork_ref_verify "$fork_repo" "$fork_ref" "$candidate_sha" "$DRILL_WORK")"

# ---- the caller stub, which refuses an unseeded tree from inside ----------
caller_sha="$(caller_install "$DRILL_REPO" main "$DRILL_STAGE" \
  "$fork_repo" "$fork_ref" "$DRILL_WORK")"
IFS=$'\t' read -r baseline_run baseline_conc < <(scratch_run_for "$DRILL_REPO" "$caller_sha")
probe_setup_record "$baseline_run" "$baseline_conc" \
  "the caller's own landing on an armed tree — the green baseline no-op, and the run that proves the door was live before any probe asked it a question"

# The guide's prerequisite: the label exists before the first ceremony PR.
scratch_label_create "$DRILL_REPO" release

# ---- the six probes, in doctrine order ------------------------------------
# Each through probe_run, so an abort inside one is that probe's failed row
# rather than the end of the rehearsal: the archive and the record below are
# what the header promises either way.
probe_run 1 probe_1_ceremony
probe_run 2 probe_2_mislabeled
probe_run 3 probe_3_bare
probe_run 4 probe_4_rerun
probe_run 5 probe_5_tag
probe_run 6 probe_6_mismatched_tag

# ---- disposal: archive, observe, and stop ---------------------------------
observed="$(scratch_archive "$DRILL_REPO")"
disposal="the repository is **archived** — \`PATCH /repos/$DRILL_REPO\` with \`archived: true\`, and a fresh read afterwards reported \`$observed\`"

# ---- the record -----------------------------------------------------------
ctx="$DRILL_WORK/ctx.tsv"
{
  printf 'version\t%s\n' "$DRILL_V1"
  printf 'scratch\t%s\n' "$DRILL_REPO"
  printf 'created\t%s\n' "$created"
  printf 'candidate_sha\t%s\n' "$candidate_sha"
  printf 'candidate_ref\t%s\n' "${candidate_ref:-$fork_repo@$fork_ref}"
  printf 'fork_repo\t%s\n' "$fork_repo"
  printf 'fork_ref\t%s\n' "$fork_ref"
  printf 'fork_head\t%s\n' "$fork_head"
  printf 'pin\t%s\n' "$pin"
  printf 'disposal\t%s\n' "$disposal"
  printf 'runner\t%s\n' "$runner"
  printf 'stamp\t%s\n' "$DRILL_DATE"
} >"$ctx"

record_render "$ctx" "$DRILL_PROBES" "$DRILL_SETUP" >"$out"
record_check "$out"

failed="$(awk -F'\t' '$5 == "FAIL"' "$DRILL_PROBES" | wc -l | tr -d ' ')"
cat >&2 <<EOF

drill: record written to $out
drill: probes passed $(($(wc -l <"$DRILL_PROBES") - failed))/6, failed $failed

The scratch repo is archived and **pending your delete**. That step is
yours — no fleet token holds delete_repo, and this script refuses to call
it (#135). Run it yourself when you are done reading the runs:

    gh api -X DELETE repos/$DRILL_REPO

Cleanup gates nothing: not ready-for-review, not the panel, not the merge.
EOF
