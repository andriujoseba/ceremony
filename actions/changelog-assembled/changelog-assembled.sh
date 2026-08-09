#!/usr/bin/env bash
set -euo pipefail

# changelog-assembled.sh [<base-ref>] [<changelog>] [<fragments-dir>] [<version-source>]
# — assert that a release PR's stamped section is EXACTLY what the fragments
# it consumed assemble to: read the fragments as of the MERGE BASE (they are
# gone from HEAD's tree — that is the point of the ceremony), replay the
# assembler's --check over that set, and compare byte-for-byte against
# changelog_section on HEAD (#116; the fragment flow is #112).
#
# The failure it exists to catch leaves no trace — the shape every guard in
# this family was bought by. bin/changelog-assemble is run BY HAND in the
# release PR, deliberately: the assembled section must land in the PR diff
# where the panel reads it (#114). Drop one fragment from the deletion and
# its entry is simply absent from the release: the file is well-formed,
# changelog-armed is green (the section exists and has prose),
# changelog-monotonic is green (no heading was deleted), and the publisher
# happily publishes the shortened section. Hand-edit one word of the
# assembled prose and the published history quietly stops being what the
# authors wrote. The only way anyone finds out is by reading the release
# body against a directory that no longer exists.
#
# Why this cannot live in changelog-armed: "the section matches the
# fragments it consumed" is not a property of a TREE — no single tree holds
# both the fragments and the section they became. It is a property of a
# DIFF: what existed at the merge base versus what HEAD stamped. That is
# exactly the argument changelog-monotonic made for being its own git-aware
# action rather than a clause inside changelog-armed, and this is the third
# guard on the same reasoning. changelog-armed.sh stays drivable against
# constructed two-file trees that are not git repos at all.
#
# The date is never compared as prose: --check prints the section BODY with
# no '## ' heading, and changelog_section extracts the body below HEAD's
# heading — so the date HEAD stamped into its heading never enters the
# comparison, and a date difference can never masquerade as a prose one.

base_ref="${1:-${CHANGELOG_ASSEMBLED_BASE:-origin/main}}"
changelog="${2:-${CHANGELOG:-CHANGELOG.md}}"
dir="${3:-${CHANGELOG_ASSEMBLED_DIR:-changelog.d}}"
version_source="${4:-${VERSION_SOURCE:-file}}"

# Fail-closed switch, changelog-monotonic's stance exactly: CI sets it (the
# action defaults strict to "1"), so a degradation that is sensible on a
# laptop becomes a red run there. A guard that can quietly stop guarding is
# the failure shape this whole family of checks exists to refuse.
strict="${CHANGELOG_ASSEMBLED_STRICT:-0}"

# The shared libs and the assembler travel with this action: a consumer's
# `uses: heavy-duty/ceremony/actions/changelog-assembled@<tag>` downloads
# this whole repository at that ref, so ../../lib and ../../bin are always
# present and always at the same ref — no checkout step, no version skew.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/version.sh
. "$here/../../lib/version.sh"
# shellcheck source=lib/changelog.sh
. "$here/../../lib/changelog.sh"
assemble="$here/../../bin/changelog-assemble"

skip() {
  if [ "$strict" = "1" ]; then
    echo "changelog-assembled: $* — and CHANGELOG_ASSEMBLED_STRICT=1, so this is a FAILURE, not a skip." >&2
    echo "  CI sets STRICT because a guard that quietly stops guarding is worse than no guard." >&2
    echo "  Fix the checkout, not this script: the base ref must be fetched (fetch-depth: 0)." >&2
    exit 1
  fi
  echo "changelog-assembled: SKIPPED — $*"
  echo "  (Everything this guard asserts compares HEAD against the merge base —"
  echo "   without the history there is nothing it can honestly say. In CI this"
  echo "   same condition is a hard failure.)"
  exit 0
}

# A pass with a NOTICE, never a skip in silence: an inapplicable tree is a
# legitimate green, and the log says why instead of implying a check ran.
notice() {
  echo "changelog-assembled: NOTICE — $*"
  exit 0
}

[ -f "$changelog" ] || { echo "changelog-assembled: no such file: $changelog" >&2; exit 1; }

# --- everything here needs the HISTORY ---------------------------------------
# Even applicability does: "fragment mode" is a fact about the merge base,
# not about HEAD's tree, whose fragments are consumed by construction. So
# unlike changelog-monotonic there is no history-free half to run first —
# an unusable checkout degrades (or, under STRICT, refuses) before the
# guard claims anything.

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || skip "not inside a git work tree, so there is no merge base to read the fragments from"

git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null \
  || skip "base ref '$base_ref' does not resolve here (a shallow clone, or a fork checkout without the upstream remote)"

merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null || true)"
[ -n "$merge_base" ] \
  || skip "no merge base between '$base_ref' and HEAD (unrelated histories, or a clone too shallow to reach one)"

short_base="$(git rev-parse --short "$merge_base")"

# Push-to-main shape: the merge base IS HEAD, so the fragment set this guard
# would replay is HEAD's own — nothing was consumed between the two points,
# and comparing a tree against itself would assert nothing. Named honestly,
# the same discipline as changelog-monotonic's vacuous line.
if [ "$merge_base" = "$(git rev-parse HEAD)" ]; then
  echo "changelog-assembled: vacuous (the merge base IS HEAD, so no fragments were consumed between them — there is no diff for the section to answer to)."
  exit 0
fi

# --- applicability: the ceremony PR, and nothing else ------------------------

if ! git cat-file -e "$merge_base:$dir" 2>/dev/null; then
  notice "no '$dir/' at the merge base ($short_base) — legacy mode; the changelog is edited directly and there is no fragment set for a section to answer to"
fi

# version_read refuses loudly on a missing or empty source; the wrapper line
# names the guard so a workflow log shows which check refused.
ver="$(version_read "$version_source")" || {
  echo "changelog-assembled: cannot read the version (version-source: $version_source)" >&2
  exit 1
}

if version_is_dev "$ver"; then
  notice "version '$ver' is a development tree — no release section is being stamped; whatever this PR does to '$dir/' is cargo for a future ceremony, not a consumption to verify"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git show "$merge_base:$changelog" >"$tmp/base-changelog.md" 2>/dev/null || : >"$tmp/base-changelog.md"

# An rc cut is tag-only (#317 D1): the inverse of a bare release ceremony.
# Every fragment that existed at the merge base must survive, and the
# changelog must be byte-identical. These are deliberately diff assertions;
# neither can be proven by inspecting HEAD alone.
if version_is_rc "$ver"; then
  failures=0
  deleted=""
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    case "$name" in
      README.md) continue ;;
      *.md) ;;
      *) continue ;;
    esac
    if [ ! -e "$path" ]; then
      deleted="${deleted}    ${path}"$'\n'
    fi
  done < <(git ls-tree -r -z --name-only "$merge_base" -- "$dir/")

  if [ -n "$deleted" ]; then
    {
      echo "changelog-assembled: rc tree '$ver' consumed fragment(s) that existed at the merge base ($short_base):"
      echo
      printf '%s' "$deleted"
      echo
      echo "  RC cuts are tag-only (#317 D1): every fragment must survive for the final release."
    } >&2
    failures=$((failures + 1))
  fi

  if ! cmp -s "$tmp/base-changelog.md" "$changelog"; then
    {
      echo "changelog-assembled: rc tree '$ver' changed $changelog from the merge base ($short_base)."
      echo "  RC cuts are tag-only (#317 D1): CHANGELOG.md must remain byte-identical."
    } >&2
    failures=$((failures + 1))
  fi

  [ "$failures" -eq 0 ] || exit 1
  echo "changelog-assembled: rc tree '$ver' consumed no fragments and left $changelog byte-identical to the merge base ($short_base)"
  exit 0
fi

# A branch that merely SITS on a release is not the ceremony that stamped
# it: right after a release merges, main's version is bare until the -dev
# bump lands, and a PR branched in that window would otherwise be asked to
# answer for a consumption that happened at its merge base, not on it. If
# the section already existed at the merge base, this branch did not stamp
# it. Whole-version match, as everywhere in this family.
if awk -v ver="$ver" '/^## / && $2 == ver { found = 1; exit } END { exit !found }' "$tmp/base-changelog.md"; then
  notice "the section for '$ver' already exists at the merge base ($short_base) — this branch is not the ceremony that stamped it, so there is no consumed set to answer to"
fi

# --- the replay: the merge base's fragment set, byte for byte ----------------
# Every blob in the directory is extracted — strays included, and subtrees
# recreated — so the replay refuses exactly what a real assembler run over
# that tree would have refused, instead of quietly narrowing the set.

mkdir -p "$tmp/$dir"
base_frags=""
while IFS= read -r -d '' entry; do
  meta="${entry%%$'\t'*}"
  path="${entry#*$'\t'}"
  otype="$(printf '%s\n' "$meta" | awk '{ print $2 }')"
  name="${path##*/}"
  case "$otype" in
    blob)
      git show "$merge_base:$path" >"$tmp/$dir/$name"
      case "$name" in
        README.md) ;;
        *.md) base_frags="${base_frags}${path}"$'\n' ;;
      esac
      ;;
    tree)
      mkdir -p "$tmp/$dir/$name"
      ;;
  esac
done < <(git ls-tree -z "$merge_base" -- "$dir/")

frag_count="$(printf '%s' "$base_frags" | grep -c . || true)"

failures=0

# Refusal: a fragment the ceremony consumed is still present on HEAD. The
# ceremony deletes exactly what it assembles (#112) — a fragment that
# survives its own release sits in the directory and is assembled AGAIN
# into the NEXT section, republishing its prose as if it were new.
survivors=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ -e "$p" ]; then
    survivors="${survivors}    ${p}"$'\n'
  fi
done <<<"$base_frags"
if [ -n "$survivors" ]; then
  {
    echo "changelog-assembled: fragment(s) present at the merge base ($short_base) are STILL PRESENT on HEAD:"
    echo
    printf '%s' "$survivors"
    echo
    echo "  The ceremony deletes exactly what it assembles. A fragment that survives"
    echo "  its own release is assembled AGAIN into the next section, republishing"
    echo "  its prose as if it were new. Delete it in this PR — its entry is (or"
    echo "  should be) already in the stamped section."
  } >&2
  failures=$((failures + 1))
fi

expected=""
if expected="$( (cd "$tmp" && "$assemble" "$ver" --check --changelog "$tmp/base-changelog.md" --dir "$dir") 2>&1)"; then
  found="$(changelog_section "$changelog" "$ver")"
  if [ -z "$found" ]; then
    {
      echo "changelog-assembled: the version is '$ver' (a release tree) and '$dir/' at the"
      echo "  merge base ($short_base) holds $frag_count fragment(s), but $changelog has no"
      echo "  non-empty section for '$ver' on HEAD."
      echo
      echo "  The fragments were consumed and their prose went nowhere: the release"
      echo "  this tree is about to publish would have a body the authors never got"
      echo "  to write. The ceremony's edit is one tool run, in this PR:"
      echo
      echo "      bin/changelog-assemble '$ver'"
    } >&2
    failures=$((failures + 1))
  else
    if ! diff_out="$(diff -u \
        --label "expected — assembled from the $frag_count fragment(s) at the merge base ($short_base)" \
        --label "found — section '$ver' in $changelog on HEAD" \
        <(printf '%s\n' "$expected") <(printf '%s\n' "$found"))"; then
      {
        echo "changelog-assembled: the section '$ver' in $changelog is NOT what the fragments it consumed assemble to:"
        echo
        printf '%s\n' "$diff_out" | sed 's/^/    /'
        echo
        echo "  The release body is published verbatim from this section, so any"
        echo "  difference here ships: a missing line is an author's entry silently"
        echo "  dropped from history, an extra or edited line is prose nobody wrote,"
        echo "  and a re-ordering is not the canonical order the assembler produces."
        echo "  The fix is to redo the ceremony's edit with the tool — re-run"
        echo "  bin/changelog-assemble '$ver' <date> from the merge base's fragments —"
        echo "  never to hand-edit the section into agreement."
      } >&2
      failures=$((failures + 1))
    fi
  fi
else
  {
    echo "changelog-assembled: the merge base's fragment set does not assemble — the replay refuses:"
    echo
    printf '%s\n' "$expected" | sed 's/^/    /'
    echo
    echo "  The set replayed is exactly '$dir/' as of the merge base ($short_base)."
    echo "  A section that bin/changelog-assemble would refuse to produce cannot"
    echo "  have been produced by it — whatever stamped this section did it by"
    echo "  hand, and the release body cannot be trusted to be what the fragment"
    echo "  authors wrote."
  } >&2
  failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1

echo "changelog-assembled: section '$ver' in $changelog is byte-for-byte the assembly of the $frag_count fragment(s) consumed at the merge base ($short_base)"
