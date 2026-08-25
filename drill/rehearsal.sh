#!/usr/bin/env bash
# drill/rehearsal.sh — the release drill, run by a script (#313).
#
# `drills/` is the record, not the instrument; this is the instrument. It
# automates drills/README.md's rehearsal end to end — scratch repo, armed
# fixture, caller stub at a rewritten fork pin, the probes in doctrine
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
# shellcheck source=lib/changelog.sh
source "$DRILL_ROOT/lib/changelog.sh"
# shellcheck source=drill/lib/scratch.sh
source "$DRILL_ROOT/drill/lib/scratch.sh"
# shellcheck source=drill/lib/attempt.sh
source "$DRILL_ROOT/drill/lib/attempt.sh"
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
                          --fork-ref <owner/repo[@ref]> --candidate-sha <sha>
                          [--repo-name <name>] [--candidate-ref <ref>]
                          [--private] [--out <file>] [--date <YYYY-MM-DD>]
                          [--gap '<title>|<body>']…
   or: drill/rehearsal.sh --amend-record <path> --gap '<title>|<body>'…

  --owner          where the disposable public scratch repo is created
  --version        the candidate's release version; the fixture arms X.Y.Z-dev
  --fork-ref       the stub source; omitted ref is picked as drill/<version>-<n>;
                   a taken explicit ref refuses before creating anything and
                   prints a retry using the first free paired attempt
  --candidate-sha  the canonical candidate SHA every CEREMONY_SELF_REF is
                   rewritten to on that fork ref
  --repo-name      scratch repo name (default: first free ceremony-drill-<version>-<n>)
  --candidate-ref  the candidate branch, recorded (default: the fork ref)
  --private        create a private repo; record links then resolve only for its owner
  --out            where the record is written (default: ./<version>-drill.md)
  --date           the ceremony's changelog stamp (default: today, UTC)
  --gap            a coverage gap the record declares under `## Known gaps`,
                   split at the FIRST `|`; repeatable, rendered in declaration
                   order. A gap is coverage no probe drives at all — never a
                   probe that ran and failed, which writes its own row. The
                   record renders it as `- **<title>** — <body>` and parses
                   back at the first `** — `, so a body may carry that
                   sequence and a title may not
  --amend-record   add gaps to an already committed record and re-render it,
                   running no probe, creating no repository and making no
                   network call. It refuses a record that does not already
                   round-trip, and one that is not the instrument's emission

Run it from a checkout of the candidate: the ceremony probe assembles its
changelog section with the candidate's own bin/changelog-assemble.
EOF
  exit 2
}

refuse() {
  printf 'drill: %s\n' "$1" >&2
  exit 1
}

# The declared gaps, `title<TAB>body` per element, in declaration order
# (#484 D6). Validated as each one is parsed, which is BEFORE the first remote
# read and long before the scratch repo: a refusal that fired after the repo
# existed would have burned a scratch name to reject a typo.
gap_specs=()

gap_add() { # <'title|body'> — every D6 refusal, each naming which gap defeated it
  local spec="${1-}" title body n=$((${#gap_specs[@]} + 1)) seen
  case "$spec" in
    *'|'*) ;;
    *) refuse "--gap #$n ('$spec') has no '|': a gap is '<title>|<body>', split at the first '|'." ;;
  esac
  # The FIRST `|`, so a body may carry one and a title may not. Titles are
  # short labels and that asymmetry is free.
  title="${spec%%|*}"
  body="${spec#*|}"
  [ -n "$title" ] ||
    refuse "--gap #$n ('$spec') has an empty title. A gap is '<title>|<body>' and both halves are required."
  [ -n "$body" ] ||
    refuse "--gap #$n ('$spec') has an empty body. A gap is '<title>|<body>' and both halves are required."
  # A gap travels as a TSV row and is re-rendered verbatim, so a TAB or a
  # newline would break the row, and surrounding whitespace would not survive
  # a re-render — each is refused here rather than discovered at the round
  # trip on a record nobody edited.
  case "$title$body" in
    *$'\t'*)
      refuse "--gap #$n ('$title') carries a TAB. A gap travels as a TSV row, so a TAB would break it."
      ;;
  esac
  case "$title$body" in
    *$'\n'*)
      refuse "--gap #$n ('$title') carries a newline. A gap is rendered as ONE line, verbatim and never re-wrapped (#484 D5)."
      ;;
  esac
  case "$title" in
    ' '* | *' ')
      refuse "--gap #$n ('$title') has leading or trailing whitespace in its title, which would not survive a re-render."
      ;;
  esac
  case "$body" in
    ' '* | *' ')
      refuse "--gap #$n ('$title') has leading or trailing whitespace in its body, which would not survive a re-render."
      ;;
  esac
  # The record's own separator, and the one refusal whose absence the round
  # trip could not see. `record_render` writes `- **<title>** — <body>` and
  # `record_parse` cuts at the FIRST `** — `, so a title carrying it comes back
  # cut at its own interior — and re-rendering that re-cut pair recreates the
  # identical bytes, which is why `record_roundtrip` passed over it. The pair
  # is what was lost, not the line. A body may still carry the separator, for
  # the same reason a body may carry a `|` above: the split is at the first
  # one, so only the left half has to stay clear of it
  # (@codex-bot-andresmgsl, @claude-bot-andresmgsl, round 1).
  case "$title" in
    *'** — '*)
      refuse "--gap #$n ('$title') carries '** — ' in its TITLE, which is the record's own separator between a title and its body. record_parse splits at the FIRST one, so this title would come back cut and the record could then declare two gaps sharing a parsed title (#484 D6). A body may carry it; a title may not."
      ;;
  esac
  for seen in ${gap_specs[@]+"${gap_specs[@]}"}; do
    [ "${seen%%$'\t'*}" != "$title" ] ||
      refuse "--gap #$n declares the title '$title', which an earlier --gap already declared. Two gaps may not share a title."
  done
  gap_specs+=("$title"$'\t'"$body")
}

# amend_run <record-path> — D7's whole mode. It parses the committed record,
# appends the declared gaps, re-renders, and writes it back.
#
# IT REFUSES TO LAUNDER. Before it writes anything it requires that the file
# is `record_class`'s `emission` AND that `record_roundtrip` already passes on
# it as committed. A record that does not round-trip is stale or hand-touched,
# and the unblock for that is re-running the instrument —
# .github/scripts/record-roundtrip.sh's own refusal text says so. This mode
# must never become the path that makes such a file green.
#
# The re-rendered record is graded BEFORE it replaces the committed one,
# never after: a re-render that failed its own grading must not be what is
# left on disk. Every refusal below therefore leaves the record byte-unchanged.
amend_run() {
  local file="${1:?}" work title seen
  [ -n "${gap_specs[*]:-}" ] ||
    refuse "--amend-record '$file' needs at least one --gap: the mode exists to add a declared gap to a record that already round-trips, and with none to add it would rewrite the file to no purpose."
  [ -f "$file" ] || refuse "--amend-record '$file': no such file."
  record_class "$file" || exit 1
  if [ "$RECORD_CLASS" != emission ]; then
    refuse "--amend-record '$file' is not the instrument's emission — $RECORD_CLASS_WHY. Only the rehearsal shape has a renderer to re-run, so there is nothing here to amend; the file is unchanged."
  fi
  if ! record_roundtrip "$file" >/dev/null; then
    refuse "--amend-record '$file' does not round-trip as committed, so it is stale or hand-touched. The unblock is to RE-RUN the instrument and commit what it writes, exactly as .github/scripts/record-roundtrip.sh says — never this mode, which would only make a record that is not the instrument's emission look like one. The file is unchanged."
  fi
  work="$(mktemp -d)" || refuse "--amend-record: could not create a work directory."
  # shellcheck disable=SC2064 # $work is expanded now on purpose: the trap must
  # name the directory this call made, not whatever the variable holds later
  trap "rm -rf '$work'" EXIT
  record_parse "$file" "$work/ctx.tsv" "$work/probes.tsv" "$work/setup.tsv" \
    "$work/gaps.tsv" ||
    refuse "--amend-record '$file': the parse refused it after the round trip passed, which should not happen. The file is unchanged."
  # A title the record already declares is the same duplicate D6 refuses
  # between two --gap arguments, one run later.
  while IFS=$'\t' read -r title _; do
    [ -n "${title:-}" ] || continue
    for seen in "${gap_specs[@]}"; do
      [ "${seen%%$'\t'*}" != "$title" ] ||
        refuse "--gap declares the title '$title', which $file already declares. Two gaps may not share a title; the file is unchanged."
    done
  done <"$work/gaps.tsv"
  printf '%s\n' "${gap_specs[@]}" >>"$work/gaps.tsv"
  record_render "$work/ctx.tsv" "$work/probes.tsv" "$work/setup.tsv" \
    "$work/gaps.tsv" >"$work/amended.md" ||
    refuse "--amend-record '$file': the re-render refused the amended inputs. The file is unchanged."
  record_check "$work/amended.md" ||
    refuse "--amend-record '$file': the amended record fails the shape check. The file is unchanged."
  record_roundtrip "$work/amended.md" >/dev/null ||
    refuse "--amend-record '$file': the amended record does not round-trip. The file is unchanged."
  # Written through, never renamed: the record keeps its inode and its mode,
  # and a reader holding it open sees the amendment rather than the old file.
  cat "$work/amended.md" >"$file"
  printf 'drill: %s amended — %s declared gap(s) added; the record was re-rendered from its own stated measurements and round-trips.\n' \
    "$file" "${#gap_specs[@]}" >&2
}

owner=""
version=""
fork_spec=""
amend_record=""
candidate_sha=""
repo_name=""
candidate_ref=""
out=""
stamp=""
private=0
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) [ $# -ge 2 ] || usage; owner="$2"; shift ;;
    --version) [ $# -ge 2 ] || usage; version="$2"; shift ;;
    --fork-ref) [ $# -ge 2 ] || usage; fork_spec="$2"; shift ;;
    --candidate-sha) [ $# -ge 2 ] || usage; candidate_sha="$2"; shift ;;
    --repo-name) [ $# -ge 2 ] || usage; repo_name="$2"; shift ;;
    --candidate-ref) [ $# -ge 2 ] || usage; candidate_ref="$2"; shift ;;
    --private) private=1 ;;
    --out) [ $# -ge 2 ] || usage; out="$2"; shift ;;
    --date) [ $# -ge 2 ] || usage; stamp="$2"; shift ;;
    --gap) [ $# -ge 2 ] || usage; gap_add "$2"; shift ;;
    --amend-record) [ $# -ge 2 ] || usage; amend_record="$2"; shift ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
  shift
done

# ---- --amend-record: a gap added after the run, by re-rendering (#484 D7) --
# Without this the section is nearly unusable: a reviewer asking for a
# disclosure mid-panel would otherwise cost a full rehearsal
# against a fresh scratch repo, which is the cost that made the second-document
# option unacceptable on #482. It is a MODE of this script rather than a second
# entry point because `usage`, `refuse` and the argument parser above are
# already here, and a second file would duplicate all three to gain nothing.
#
# It runs before every check the rehearsal owes — the required arguments, the
# tool probe, the fixture probe — because it needs none of them: no probe, no
# scratch repo, no network.
if [ -n "$amend_record" ]; then
  amend_run "$amend_record"
  exit 0
fi

[ -n "$owner" ] || usage
[ -n "$version" ] || usage
[ -n "$fork_spec" ] || usage
[ -n "$candidate_sha" ] || usage

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  refuse "--version '$version' is not a bare X.Y.Z. The fixture arms X.Y.Z-dev and the ceremony probe ships X.Y.Z, and the rc legs run further along the ladder this script derives from it — an rc is never the candidate version here (#321)."
case "$fork_spec" in
  */*) ;;
  *) refuse "--fork-ref '$fork_spec' is not 'owner/repo[@ref]'." ;;
esac
fork_repo="${fork_spec%@*}"
fork_ref=""
fork_ref_explicit=0
case "$fork_spec" in
  */*@*) fork_ref="${fork_spec##*@}"; [ -z "$fork_ref" ] || fork_ref_explicit=1 ;;
  */*) fork_repo="$fork_spec" ;;
  *) refuse "--fork-ref '$fork_spec' is not 'owner/repo[@ref]'." ;;
esac

# D4, first refusal — checked before anything is created anywhere.
[ "$fork_ref_explicit" -eq 0 ] || pin_assert_fork_ref "$fork_repo" "$fork_ref" || exit 1

for tool in gh jq base64; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool is required and is not on PATH."
done
[ -x "$DRILL_ROOT/bin/changelog-assemble" ] ||
  refuse "$DRILL_ROOT/bin/changelog-assemble is missing — run this from a checkout of the candidate, whose own assembler the ceremony probe must use."

DRILL_V1="$version"
DRILL_V2="$(version_next_dev "$version")"
DRILL_V2="${DRILL_V2%-dev}"
# The rc ladder runs one rung further along: the probes before it publish
# DRILL_V1 through the merge door and DRILL_V2 through the tag door, and a
# promotion needs a version nothing has released (#321). Its own arithmetic
# is the candidate's — version_next_dev, twice for the ladder's foot and
# once over the rc for the re-arm the rc cut owes.
DRILL_V3="$(version_next_dev "$DRILL_V2")"
DRILL_V3="${DRILL_V3%-dev}"
DRILL_V4="$(version_next_dev "$DRILL_V3")"
DRILL_V4="${DRILL_V4%-dev}"
DRILL_RC1="$DRILL_V3-rc1"
DRILL_RC2="$(version_next_dev "$DRILL_RC1")"
DRILL_RC2="${DRILL_RC2%-dev}"
# The rc the TAG door publishes (#499 D6). The promotion arms main at
# DRILL_V4-dev and releases nothing on that line, so its first candidate is
# the free rung a manual rc tag can name.
DRILL_RC_TAG="$DRILL_V4-rc1"
DRILL_DATE="${stamp:-$(date -u +%Y-%m-%d)}"
DRILL_WORK="$(mktemp -d)"
DRILL_STAGE="$DRILL_WORK/stage"
DRILL_PROBES="$DRILL_WORK/probes.tsv"
DRILL_SETUP="$DRILL_WORK/setup.tsv"
DRILL_GAPS="$DRILL_WORK/gaps.tsv"
out="${out:-$PWD/$version-drill.md}"
: >"$DRILL_PROBES"
: >"$DRILL_SETUP"
# The gaps were declared and validated at the CLI, before anything remote
# happened; this is only where they land for the render (#484 D6).
: >"$DRILL_GAPS"
[ -z "${gap_specs[*]:-}" ] || printf '%s\n' "${gap_specs[@]}" >"$DRILL_GAPS"
export DRILL_ROOT DRILL_V1 DRILL_V2 DRILL_V3 DRILL_V4 DRILL_RC1 DRILL_RC2
export DRILL_RC_TAG DRILL_NON_RELEASE_NAMESPACE
export DRILL_DATE DRILL_REPO DRILL_WORK DRILL_STAGE
export DRILL_PROBES DRILL_SETUP DRILL_GAPS
trap 'rm -rf "$DRILL_WORK"' EXIT

retry_command_for_attempt() { # <attempt> <fork-ref> — print a complete invocation
  local suggested="${1:?}" suggested_ref="${2:?}" retry_command
  local -a retry_args=(drill/rehearsal.sh --owner "$owner" --version "$version"
    --fork-ref "$fork_repo@$suggested_ref" --candidate-sha "$candidate_sha"
    --repo-name "ceremony-drill-$version-$suggested")
  [ -z "$candidate_ref" ] || retry_args+=(--candidate-ref "$candidate_ref")
  [ "$private" -eq 0 ] || retry_args+=(--private)
  retry_args+=(--out "$out")
  [ -z "$stamp" ] || retry_args+=(--date "$stamp")
  printf -v retry_command '%q ' "${retry_args[@]}"
  printf '%s\n' "${retry_command% }"
}

# setup_ctx writes only facts the setup has actually established. In
# particular, a planned scratch name is not evidence that the repo exists.
setup_ctx() { # <file> [disposal]
  local file="${1:?}" disposal="${2:-}"
  {
    printf 'candidate_sha\t%s\n' "$candidate_sha"
    printf 'fork_repo\t%s\n' "$fork_repo"
    printf 'fork_ref\t%s\n' "$fork_ref"
    [ "${scratch_created:-0}" = 0 ] || printf 'scratch\t%s\n' "$DRILL_REPO"
    [ -z "${attempt:-}" ] || printf 'attempt\t%s\n' "$attempt"
    [ -z "${created:-}" ] || printf 'created\t%s\n' "$created"
    [ -z "$disposal" ] || printf 'disposal\t%s\n' "$disposal"
  } >"$file"
}

archive_disposal() { # print the disposal this run observed; always return 0
  local observed archive_rc=0
  observed="$(scratch_archive "$DRILL_REPO")" || archive_rc=$?
  if [ "$archive_rc" -eq 0 ]; then
    printf "the repository is **archived** — \`PATCH /repos/%s\` with \`archived: true\`, and a fresh read afterwards reported \`%s\`" \
      "$DRILL_REPO" "$observed"
  elif [ "$archive_rc" -eq 3 ]; then
    printf "the repository is **not archived** — \`PATCH /repos/%s\` with \`archived: true\` was sent, and every read afterwards reported \`%s\`; the archive did not land, and the repository is still live" \
      "$DRILL_REPO" "$observed"
  else
    printf "the repository was sent \`PATCH /repos/%s\` with \`archived: true\`, but the read afterwards never answered — the archive may well have landed; it is unobserved, and this record does not claim it did" \
      "$DRILL_REPO"
  fi
}

setup_abort() { # <step> <status> <stderr-file>
  local step="${1:?}" status="${2:?}" errors="${3:?}" disposal="" ctx abort_path message
  if [ "${scratch_created:-0}" = 1 ]; then
    disposal="$(archive_disposal)"
  fi
  ctx="$DRILL_WORK/abort-ctx.tsv"
  setup_ctx "$ctx" "$disposal"
  if ! abort_path="$(record_abort_path "$out")" || [ -z "$abort_path" ]; then
    printf 'drill: setup aborted in %s; could not reserve abort evidence beside %s\n' \
      "$step" "$out" >&2
    exit "$status"
  fi
  message="$(cat "$errors")"
  record_abort_render "$ctx" "$DRILL_SETUP" "$step" "$message" "$status" >"$abort_path"
  printf 'drill: setup aborted in %s; evidence written to %s\n' "$step" "$abort_path" >&2
  if [ "${scratch_created:-0}" = 1 ]; then
    cat >&2 <<EOF

The scratch repo is pending your delete. Run this yourself when you are done
reading the abort evidence:

    gh api -X DELETE repos/$DRILL_REPO
EOF
  fi
  exit "$status"
}

setup_capture() { # <variable> <step> <command> [args...]
  local variable="${1:?}" step="${2:?}" stdout stderr status
  shift 2
  stdout="$DRILL_WORK/setup.stdout"
  stderr="$DRILL_WORK/setup.stderr"
  : >"$stdout"
  : >"$stderr"
  set +e
  (set -e; "$@") >"$stdout" 2>"$stderr"
  status=$?
  set -e
  cat "$stderr" >&2
  [ "$status" -eq 0 ] || setup_abort "$step" "$status" "$stderr"
  [ "$variable" = _ ] || printf -v "$variable" '%s' "$(cat "$stdout")"
}

setup_run() { # <step> <command> [args...]
  setup_capture _ "$@"
}

fixture_manifest_write() {
  local paths path
  fixture_write "$DRILL_STAGE" "$DRILL_V1"
  paths="$(fixture_paths "$DRILL_V1")" || return 1
  : >"$fixture_manifest"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf 'A\t%s\t%s\n' "$path" "$DRILL_STAGE/$path" >>"$fixture_manifest"
  done <<<"$paths"
}

scratch_created=0
created=""
observed_private=""
runner=""
fork_head=""
pin=""
caller_sha=""
baseline=""

# An explicit ref keeps its refuse-rather-than-route contract, but the read
# now happens before the first remote write. The later fork_ref_prepare check
# remains the race backstop for this rehearsal and every direct caller (#387).
if [ "$fork_ref_explicit" -eq 1 ]; then
  explicit_ref_sha=""
  if ! explicit_ref_sha="$(scratch_ref_sha "$fork_repo" "$fork_ref")"; then
    exit 1
  fi
  if [ -n "$explicit_ref_sha" ]; then
    suggestion="$(attempt_first_free "$owner" "$version" "$fork_repo")" || exit 1
    retry_command="$(retry_command_for_attempt "$suggestion" "drill/$version-$suggestion")"
    fork_ref_exists_refusal "$fork_repo" "$fork_ref" "$explicit_ref_sha" || true
    printf 'drill: Retry with: %s\n' "$retry_command" >&2
    exit 1
  fi
fi

setup_capture runner authenticated_login drill_gh api user --jq '.login'

attempt=""
if [ -n "$repo_name" ]; then
  DRILL_REPO="$owner/$repo_name"
  if [ "$fork_ref_explicit" -eq 0 ]; then
    case "$repo_name" in
      ceremony-drill-"$version"-[0-9]*)
        attempt="${repo_name##*-}"
        [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=""
        ;;
    esac
    [ -n "$attempt" ] || setup_capture attempt scratch_attempt_ref \
      attempt_first_free_ref "$fork_repo" "$version"
    fork_ref="drill/$version-$attempt"
    setup_run scratch_attempt_ref_free attempt_ref_absent \
      "$fork_repo" "$version" "$attempt"
  else
    case "$repo_name $fork_ref" in
      *"drill/$version-"[0-9]*) attempt="${fork_ref##*-}" ;;
      *) attempt=1 ;;
    esac
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=1
  fi
  explicit_rc=0
  explicit_errors="$DRILL_WORK/setup.stderr"
  : >"$explicit_errors"
  scratch_create_attempt "$DRILL_REPO" "$private" 2>"$explicit_errors" || explicit_rc=$?
  cat "$explicit_errors" >&2
  if [ "$explicit_rc" -eq 3 ]; then
    suggestion_fork_repo="$fork_repo"
    [ "$fork_ref_explicit" -eq 0 ] || suggestion_fork_repo=""
    suggestion="$(attempt_first_free "$owner" "$version" "$suggestion_fork_repo")" || exit 1
    suggested_ref="$fork_ref"
    [ "$fork_ref_explicit" -eq 1 ] || suggested_ref="drill/$version-$suggestion"
    retry_command="$(retry_command_for_attempt "$suggestion" "$suggested_ref")"
    refuse "--repo-name '$repo_name' is already taken. Retry with: ${retry_command% }"
  fi
  [ "$explicit_rc" -eq 0 ] || setup_abort scratch_create "$explicit_rc" "$explicit_errors"
  scratch_created=1
else
  suggestion_fork_repo="$fork_repo"
  [ "$fork_ref_explicit" -eq 0 ] || suggestion_fork_repo=""
  setup_capture attempt scratch_attempt_name attempt_create_default \
    "$owner" "$version" "$suggestion_fork_repo" "$private"
  DRILL_REPO="$owner/ceremony-drill-$version-$attempt"
  scratch_created=1
fi
[ "$fork_ref_explicit" -eq 1 ] || fork_ref="drill/$version-$attempt"

printf 'drill: %s rehearsal — scratch %s, candidate %s, fork %s@%s\n' \
  "$DRILL_V1" "$DRILL_REPO" "$candidate_sha" "$fork_repo" "$fork_ref" >&2

# ---- the scratch repo (already claimed while choosing its attempt) --------
setup_capture created scratch_created_at scratch_created_at "$DRILL_REPO"
setup_capture observed_private scratch_private scratch_private "$DRILL_REPO"

# ---- the armed fixture, BEFORE the caller (the 0.4.0 lesson) --------------
fixture_manifest="$DRILL_WORK/fixture.manifest"
setup_run fixture_manifest fixture_manifest_write
setup_run scratch_commit scratch_commit "$DRILL_REPO" main \
  "the armed fixture at $DRILL_V1-dev" "$fixture_manifest"

# ---- the candidate pin, on a fork ref and never on the canonical repo -----
setup_capture fork_head fork_ref_prepare fork_ref_prepare \
  "$fork_repo" "$fork_ref" "$candidate_sha" "$DRILL_WORK"
setup_capture pin fork_ref_verify fork_ref_verify \
  "$fork_repo" "$fork_ref" "$candidate_sha" "$DRILL_WORK"

# ---- the caller stub, which refuses an unseeded tree from inside ----------
setup_capture caller_sha caller_install caller_install "$DRILL_REPO" main \
  "$DRILL_STAGE" "$fork_repo" "$fork_ref" "$DRILL_WORK"
setup_capture baseline baseline_run_wait scratch_run_for "$DRILL_REPO" "$caller_sha"
IFS=$'\t' read -r baseline_run baseline_conc <<<"$baseline"
setup_run probe_setup_record probe_setup_record "$baseline_run" "$baseline_conc" \
  "the caller's own landing on an armed tree — the green baseline no-op, and the run that proves the door was live before any probe asked it a question"

# The guide's prerequisite: the label exists before the first ceremony PR.
setup_run scratch_label_create scratch_label_create "$DRILL_REPO" release

# ---- the probes, in doctrine order ----------------------------------------
# Each through probe_run, so an abort inside one is that probe's failed row
# rather than the end of the rehearsal: the archive and the record below are
# what the header promises either way.
probe_run 1 probe_1_ceremony
probe_run 2 probe_2_mislabeled
probe_run 3 probe_3_bare
probe_run 4 probe_4_rerun
probe_run 5 probe_5_tag
probe_run 6 probe_6_mismatched_tag
probe_run 7 probe_7_rc_cut
probe_run 8 probe_8_promotion
# The tag door's three remaining classifications, after the rc ladder because
# probe 9 needs a version nothing has released (#499 D6).
probe_run 9 probe_9_rc_tag
probe_run 10 probe_10_namespace_tag
probe_run 11 probe_11_malformed_tag

# ---- disposal: archive, observe, and stop ---------------------------------
# The read-back can exhaust its retries (#369 D4), and if it does, that must
# not take the record with it: every probe has already run and the header
# promises their rows either way. So the disposal sentence reports the read
# that did not answer, rather than `set -e` ending the run one line short of
# the thing the run is for.
#
# Three dispositions, never two (#369 D7). A read that answered `archived=
# false` to the end of its budget has measured a cleanup that did not happen,
# which is the exact thing #135 put this read-back here to catch; filing it as
# "the read never answered" would hand the operator the softer of the two
# sentences on the harder of the two facts.
disposal="$(archive_disposal)"

# ---- the record -----------------------------------------------------------
ctx="$DRILL_WORK/ctx.tsv"
{
  printf 'version\t%s\n' "$DRILL_V1"
  printf 'rc_version\t%s\n' "$DRILL_V3"
  printf 'scratch\t%s\n' "$DRILL_REPO"
  printf 'attempt\t%s\n' "$attempt"
  printf 'created\t%s\n' "$created"
  printf 'private\t%s\n' "$observed_private"
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

record_render "$ctx" "$DRILL_PROBES" "$DRILL_SETUP" "$DRILL_GAPS" >"$out"
record_check "$out"

failed="$(awk -F'\t' '$5 == "FAIL"' "$DRILL_PROBES" | wc -l | tr -d ' ')"
cat >&2 <<EOF

drill: record written to $out
drill: probes passed $(($(wc -l <"$DRILL_PROBES") - failed))/$DRILL_PROBE_COUNT, failed $failed

The scratch repo is archived and **pending your delete**. That step is
yours — no fleet token holds delete_repo, and this script refuses to call
it (#135). Run it yourself when you are done reading the runs:

    gh api -X DELETE repos/$DRILL_REPO

Cleanup gates nothing: not ready-for-review, not the panel, not the merge.
EOF
