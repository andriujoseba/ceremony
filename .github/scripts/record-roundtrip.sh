#!/usr/bin/env bash
# The drill record's round-trip guard (issue #373). `record_check` grades the
# emission's SHAPE at the moment the instrument writes it, where authorship is
# guaranteed and therefore unprovable by checking. The edit this guard is
# about happens AFTER the instrument exits and BEFORE the commit: a copy of
# the committed 0.7.0 record with one hand-added sentence in its preamble
# passes `record_check`, exit 0 (@claude-bot-andresmgsl, the 0.7.0 panel
# round). Only something reading the COMMITTED file catches that, which is
# why this runs in CI and `record_check` keeps its present job unchanged.
#
# It grades by re-render: `record_render(record_parse(file))` must be
# byte-identical to the file. That is a grading of authorship rather than of
# shape — a hand-added sentence, a reordered field, a second renderer's
# output, none of them survive being regenerated from what the file itself
# claims.
#
# WHY IT IS NOT IN actions/drill-recorded (#373 D3): that action is ported
# into box, rig and cast, and those consumers have no `drill/lib` — it cannot
# re-render anything, and giving it a dependency on this repository's
# internals would break the one action all four repos converge on. The
# vendored action is byte-unchanged by this guard; it keeps asserting
# existence and non-blankness for every consumer, and this repository adds
# the authorship grading on top, for its own tree only.
#
# Keyed exactly the way drill-recorded is, and for the same reason — the two
# states are genuinely different:
#
#   version ends in -dev  ->  PASS, and say so out loud. A development tree
#                             ships nothing, so it has no record to have
#                             authored. A silent skip here is the failure
#                             mode #373 D5 names: an operator reading a green
#                             log must be able to tell "the guard passed"
#                             from "the guard decided this tree was not its
#                             business".
#   version is bare       ->  the ceremony tree, the one about to ship. Its
#                             record must round-trip.
#
# A file of its own, not inlined in ci.yml, so test/drill-rehearsal.test.sh
# can drive it against constructed trees for both states — the same
# discipline as the libs it sources (CONTRIBUTING, "workflows and actions
# gather facts; scripts decide").
#
# Usage: record-roundtrip.sh [tree-dir]   (default: the repository root — the
# CI step; tests point it at fixture trees)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
tree="${1:-$root}"

# shellcheck source=lib/version.sh
. "$root/lib/version.sh"
# The doctrine list owns the probe count and record.sh refuses to load
# without it, so probes.sh comes first. Both are sourced from the ROOT, never
# from the tree under test: the guard is this repository's machinery grading a
# tree, and a fixture tree that shipped its own renderer could otherwise
# certify itself.
# shellcheck source=drill/lib/probes.sh
. "$root/drill/lib/probes.sh"
# shellcheck source=drill/lib/record.sh
. "$root/drill/lib/record.sh"

# A missing or empty version source is an ERROR, never a silent pass — the
# same rule drill-recorded states: a guard that cannot read the version cannot
# know whether this tree is its business, and "could not tell" must not
# resolve to "allowed".
# This repository is the `file` backend by construction — it carries a
# VERSION, and the guard grades its own tree, never a consumer's.
ver="$(version_read file "$tree")" || {
  echo "record-roundtrip: cannot read the version of the tree at $tree" >&2
  exit 1
}

if version_is_dev "$ver"; then
  echo "record-roundtrip: version '$ver' is a development tree — nothing to grade; only ceremony trees ship a record"
  exit 0
fi

record="$tree/drills/$ver.md"

# Existence is drill-recorded's rule and it runs in the same job, so this
# guard does not restate the argument — but it does not pass on a missing
# file either. Nothing to re-render is not a round trip that succeeded.
if [ ! -f "$record" ]; then
  cat >&2 <<EOF
record-roundtrip: the version is '$ver' — a release — and there is no drill
  record at $record to grade. drill-recorded owns that rule and states the
  unblock; this guard only adds that a record which does not exist has not
  been authored by the instrument either.
EOF
  exit 1
fi

# Classify BEFORE grading (#373 D9). Two of the three record shapes
# drills/README.md sanctions are hand-written by design — a doors-unchanged
# scope ruling and a WAIVED one — and neither is `record_render`'s output.
# `drills/0.6.3.md`, the release immediately before 0.7.0, is the standing
# instance: a guard demanding a round trip of every bare-version tree would
# red a legitimate release. The class is read out of the record itself, and
# the branch is named here for the same reason the dev-tree line is: a green
# log must distinguish "passed" from "decided this was not its business".
record_class "$record"
if [ "$RECORD_CLASS" = scope-ruling ]; then
  cat <<EOF
record-roundtrip: version '$ver' is a ceremony tree, and $record is NOT
  graded by this step: $RECORD_CLASS_WHY.

  The round trip grades the rehearsal shape — drill/rehearsal.sh's emission —
  because that is the only shape with a renderer to re-run. A scope ruling is
  a mechanically checked claim the review panel verifies from the record
  itself, and a waiver is a maintainer's judgement; drills/README.md states
  both, and drill-recorded separately requires the file to exist and be
  non-blank whichever shape it is.
EOF
  exit 0
fi

echo "record-roundtrip: version '$ver' is a ceremony tree, and $record is graded as an emission — $RECORD_CLASS_WHY. Grading it by re-render."
if ! record_roundtrip "$record"; then
  # Quoted delimiter: the prose below carries backticks, and an unquoted
  # heredoc would run them.
  cat >&2 <<'EOF'

  This record is not `drill/rehearsal.sh`'s emission as committed. #313 held
  the criterion that a cut's record is the script's emission and NOT a
  hand-written one; this is that criterion, checked.

  The unblock is not to edit the record until it passes — it is to RE-RUN the
  instrument and commit what it writes. If the difference is a renderer change
  that landed after the record was emitted, the record is stale and the
  re-render is what fixes it.
EOF
  exit 1
fi
