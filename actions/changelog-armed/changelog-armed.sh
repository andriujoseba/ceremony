#!/usr/bin/env bash
set -euo pipefail

# changelog-armed.sh [<changelog>] [<version-source>] [<fragments-dir>] —
# assert that the changelog is ARMED: that there is a place for the next PR's
# entry to land, and that it is the right one for the state this tree is in.
#
# Ported from box .github/scripts/changelog-armed.sh (box#108, confirmed
# cross-repo as rig#66) — box is the only repo that carries this guard
# today. Rig and cast LOST it: the naive form — "always require
# '## Unreleased' on top" — is false by construction on the ceremony PR's
# own tree, which legitimately stamps that heading away, so rig#44 and
# cast#108 both had to revert exactly that. This version-keyed form is the
# guard rig and cast regain when they adopt ceremony (#13, #15). Anyone
# tempted to simplify this back to the unconditional form should read
# those two reverts first.
#
# Fragment mode makes the directory itself the arming (#115): every PR gets
# its own issue-named file, so the box#108 clean-mismerge cannot happen because
# there is no shared heading to disappear under an open PR. The guard instead
# proves that the marker exists, Unreleased is gone, and every fragment is
# publishable before its author lets go of the PR. A bare release has no
# re-armed shape in this mode — there is nothing to re-arm — so it must have
# consumed every fragment and stamped its exact publishable section.
#
# The failure it exists to catch (box#108, rig#66) leaves no trace: the
# ceremony PR stamps '## Unreleased' into '## X.Y.Z — DATE' by hand, and
# nothing puts the heading back. A PR authored BEFORE the release wrote its
# entry under '## Unreleased'; that heading is gone by the time it merges, so
# git lands the entry under whatever heading now occupies that position — the
# just-shipped section — CLEANLY, with no conflict. The one signal an author
# would trust ("git told me to look") is absent exactly when the result is
# wrong, and the drift is only ever discovered by reading the file.
#
# The rule, keyed on the tree's version (a VERSION file or package.json,
# per version-source), because the two states are genuinely different:
#
#   version ends in -dev  ->  the top section MUST be '## Unreleased'
#   version is an rc      ->  fragment mode stays armed; fragments survive
#   version is bare       ->  the top section may be '## Unreleased' (armed,
#                             the ceremony's own re-arm) or the stamped
#                             section for exactly that version — AND the
#                             section for that version must exist and carry
#                             prose, because it is the one about to ship
#
# The consequence worth stating plainly: a ceremony PR that stamps and forgets
# to re-arm still passes here — its version is bare, and a bare tree is
# allowed to be stamped. It goes red the moment the '-dev' bump lands on main,
# which the release workflow does automatically in the same job as the
# publish. So the guard does not block the release; it refuses to let main
# SIT disarmed, which is the window a late PR can fall into.
#
# A file of its own (not inlined in action.yml) so
# test/changelog-armed.test.sh can drive it against constructed trees for
# both states — the same discipline as the libs it sources.

changelog="${1:-${CHANGELOG:-CHANGELOG.md}}"
version_source="${2:-${VERSION_SOURCE:-file}}"
fragments_dir="${3:-${FRAGMENTS_DIR:-changelog.d}}"

# The shared libs travel with this action: a consumer's
# `uses: heavy-duty/ceremony/actions/changelog-armed@<tag>` downloads this
# whole repository at that ref, so ../../lib is always present and always at
# the same ref — no checkout step, no version skew possible.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/version.sh
. "$here/../../lib/version.sh"
# shellcheck source=lib/changelog.sh
. "$here/../../lib/changelog.sh"

[ -f "$changelog" ] || { echo "changelog-armed: no such file: $changelog" >&2; exit 1; }

# version_read refuses loudly on a missing or empty source; the wrapper line
# names the guard so a workflow log shows which check refused.
ver="$(version_read "$version_source")" || {
  echo "changelog-armed: cannot read the version (version-source: $version_source)" >&2
  exit 1
}

if [ -d "$fragments_dir" ]; then
  [ -f "$fragments_dir/README.md" ] || {
    echo "changelog-armed: fragment mode requires the generated marker '$fragments_dir/README.md' — restore it so the empty directory remains tracked" >&2
    exit 1
  }

  if awk '$1 == "##" && $2 == "Unreleased" { found = 1 } END { exit !found }' "$changelog"; then
    echo "changelog-armed: a '## Unreleased' section survived the adoption — move its entries into '$fragments_dir/<issue>.md' and delete the heading" >&2
    exit 1
  fi

  fragments="$(changelog_fragments "$fragments_dir")"
  while IFS= read -r fragment; do
    [ -n "$fragment" ] || continue
    if ! diagnosis="$(changelog_fragment_problem "$fragment")"; then
      printf 'changelog-armed: %s\n' "$diagnosis" >&2
      exit 1
    fi
  done <<<"$fragments"

  if ! diagnosis="$(changelog_shape_problem "$changelog" "$fragments_dir")"; then
    printf 'changelog-armed: %s\n' "$diagnosis" >&2
    exit 1
  fi

  # RC cuts are tag-only (#317 D1): they neither consume fragments nor stamp
  # CHANGELOG.md. Refuse a newly stamped candidate section even if the rest of
  # the fragment tree is coherent; older rc headings deeper in history remain
  # changelog-monotonic's concern.
  top="$(grep -m1 '^## ' "$changelog" || true)"
  top_ver="$(printf '%s\n' "$top" | awk '{ print $2 }')"
  if [ -n "$top" ] && version_is_rc "$top_ver"; then
    echo "changelog-armed: the top section '$top_ver' is an rc stamp, but rc cuts are tag-only (#317 D1); leave $changelog untouched" >&2
    exit 1
  fi

  if version_is_dev "$ver"; then
    echo "changelog-armed: version '$ver' agrees with fragment mode ($fragments_dir)"
    exit 0
  fi

  if version_is_rc "$ver"; then
    echo "changelog-armed: version '$ver' agrees with the rc fragment-mode state ($fragments_dir; fragments survive)"
    exit 0
  fi

  if [ -n "$fragments" ]; then
    surviving="$(printf '%s\n' "$fragments" | awk '
      BEGIN { separator = "" }
      { printf "%s%s", separator, $0; separator = ", " }
    ')"
    echo "changelog-armed: these fragments were not consumed: $surviving — re-run 'changelog-assemble $ver'" >&2
    exit 1
  fi

  top="$(grep -m1 '^## ' "$changelog" || true)"
  [ -n "$top" ] || {
    echo "changelog-armed: $changelog has no '## ' section at all — the release stamp for '$ver' is missing" >&2
    exit 1
  }
  if ! diagnosis="$(changelog_section_problem "$changelog" "$ver")"; then
    printf "changelog-armed: the stamped section for '%s' is not publishable: %s\n" \
      "$ver" "$diagnosis" >&2
    exit 1
  fi
  top_ver="$(printf '%s\n' "$top" | awk '{ print $2 }')"
  if [ "$top_ver" != "$ver" ]; then
    cat >&2 <<EOF
changelog-armed: the version is '$ver' but the top section of $changelog is:

    $top

  Fragment mode has no re-arm step. A bare version means this tree is a
  release, so the top section must be the stamped section for '$ver' itself.
  A different version means the ceremony stamped the wrong number.
EOF
    exit 1
  fi

  echo "changelog-armed: version '$ver' agrees with fragment mode ($fragments_dir)"
  exit 0
fi

# The TOP section: the first '## ' heading in the file. Everything above it is
# the changelog's own preamble and belongs to no section.
top="$(grep -m1 '^## ' "$changelog" || true)"
[ -n "$top" ] || {
  echo "changelog-armed: $changelog has no '## ' section at all — nothing for a PR entry to land under" >&2
  exit 1
}

# '## 0.7.0 — 2026-07-19' -> '0.7.0'. Split on whitespace, the same shape
# changelog_section matches on, so the two cannot disagree about what a
# section header is.
top_ver="$(printf '%s\n' "$top" | awk '{ print $2 }')"

# A stamped rc top section is drift in every mode: candidates are tag-only
# under #317 D1. Deeper rc headings are historical and deliberately ignored.
if version_is_rc "$top_ver"; then
  echo "changelog-armed: the top section '$top_ver' is an rc stamp, but rc cuts are tag-only (#317 D1); leave $changelog untouched" >&2
  exit 1
fi

if version_is_rc "$ver"; then
  echo "changelog-armed: version '$ver' is an rc tree, but rc is fragment-mode only (#317 D4); adopt changelog fragments first" >&2
  exit 1
fi

# version_is_dev is the single definition of the -dev special case (#3): an
# rc is a pre-release, not a dev tree; its fragment-only refusal is above.
if version_is_dev "$ver"; then
  if [ "$top_ver" != "Unreleased" ]; then
    cat >&2 <<EOF
changelog-armed: the version is '$ver' (a development tree) but the top
  section of $changelog is:

    $top

  A -dev tree MUST carry '## Unreleased' at the top. Without it, a PR that
  wrote its entry under '## Unreleased' before the release merges CLEANLY into
  the section above — the one that already shipped — and the changelog quietly
  misattributes it (box#108, rig#66).

  The fix is to re-arm: add an empty '## Unreleased' immediately above
  '$top'. The release ceremony is supposed to do this in the same edit that
  stamps the version.
EOF
    exit 1
  fi
else
  # A bare version is the ceremony tree and the merge commit that publishes
  # it. Both arrangements are legal there: re-armed ('## Unreleased' back on
  # top, above the section just stamped) or not yet re-armed (the stamped
  # section still on top). What is NOT legal is a stamped top section naming
  # some OTHER version — that is a ceremony that stamped the wrong number,
  # and the release workflow would publish a body that is not this release's.
  if [ "$top_ver" != "Unreleased" ] && [ "$top_ver" != "$ver" ]; then
    cat >&2 <<EOF
changelog-armed: the version is '$ver' but the top section of $changelog is:

    $top

  A bare version means this tree is a release. Its top section must be either
  '## Unreleased' (re-armed after stamping) or the stamped section for '$ver'
  itself. A stamped section naming a different version means the ceremony
  stamped the wrong number, and the published release body would come from
  the wrong section.
EOF
    exit 1
  fi
  # The top heading is deliberately left UNCONSTRAINED above — both ceremony
  # shapes must stay legal, which is the rig#44 / cast#108 lesson and is not
  # negotiable. That asymmetry leaves a gap of its own, the HALF-ceremony
  # tree: version bumped to the release, a populated '## Unreleased' still on
  # top, and no stamped section for the version anywhere. The test above is
  # false on its first clause, short-circuits, and passes. Nothing else
  # refuses until the publisher extracts the notes — which happens AFTER the
  # merge, on main, and publishes a release with an empty body, the worst
  # place for this to land. So make the same assert one step earlier through
  # the very extractor the publisher uses — changelog_section (#4) — so the
  # guard and the publisher cannot disagree about what a section is or when
  # one counts as empty (rig#67).
  if ! diagnosis="$(changelog_section_problem "$changelog" "$ver")"; then
    cat >&2 <<EOF
changelog-armed: the version is '$ver' but $changelog has no non-empty
  section for '$ver'. The top section is:

    $top

  This is a HALF-DONE ceremony: the version was bumped but its section was
  never stamped — the stamp is MISSING, not misnumbered. A bare version means
  this tree is a release, and the section it is about to publish has to exist
  and have prose in it. Left alone, this passes CI, merges, and only then does
  the publisher refuse to extract the notes — on main, after the fact, with
  the release already half-shipped.

  The fix is the ceremony's first edit: stamp '## Unreleased' into
  '## $ver — DATE', then put an empty '## Unreleased' back above it.

  $diagnosis
EOF
    exit 1
  fi
fi

echo "changelog-armed: version '$ver' agrees with the top section ($top_ver)"
