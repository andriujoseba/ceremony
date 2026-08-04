#!/usr/bin/env bash
# The vendored-manifest self-guard (issue #251; #248's near-miss). Consumers
# mirror the agent-facing doc set declared by docs/VENDORED.txt, and
# actions/docs-sync already enforces "manifest ∪ .ceremony/, nothing else"
# on the CONSUMER side. Nothing enforced the other end: a new doctrine file
# could land at ceremony's root and nobody add it to the manifest, and the
# miss is SILENT — docs-sync asserts byte-identity for the files the
# manifest names, so a doc it omits is never checked and every consumer
# drifts doctrine-blind with green guards. #248 (RELEASES.md) nearly shipped
# that way, caught only by a hand-written `grep -Fx RELEASES.md` row in
# test/docs-sync.test.sh — the hardcoded list this guard abolishes, one
# layer down. That row is deleted; this script carries its intent.
#
# Two directions, two mechanisms, because only one of them can be a scan
# (#251 D2):
#
#   * MANIFEST → TREE is a scan: every entry resolves to a regular,
#     non-empty, tracked file at the declared path — no symlink (PR #43:
#     a symlink read as doctrine while staying invisible), no directory,
#     no `../` escape.
#   * TREE → MANIFEST cannot scan, because nothing in the tree answers
#     "which files are vendorable" — the manifest is the only
#     machine-readable notion of it. So it gets a CLOSED-WORLD RULE
#     instead: every `*.md` at the repository ROOT is either in the
#     manifest or in the exemption list below. Adding a root doc then
#     forces a one-line decision — vendor it or exempt it — and the
#     refusal names the file and both fixes.
#
# The rule is ROOT-LEVEL `*.md` ONLY. It does not walk docs/, actions/ or
# drills/: those hold no agent-facing doctrine, and a recursive version
# would grow the exemption list past the length at which a reviewer still
# reads it — which is the failure this rule is shaped against.
#
# The exemption list lives HERE, in the script. CONTRIBUTING.md's
# vendored-set sentence is documentation, never an input: two declarations
# of the same set is the drift the manifest exists to prevent.
#
# Usage: vendored-check.sh [tree-dir]   (default: the repo root — the CI
# step; tests point it at fixture trees)
set -euo pipefail

MANIFEST="docs/VENDORED.txt"

tree="${1:-.}"

# The root docs that are deliberately ceremony-only. Each carries the reason
# it is not vendored, because the reason is what lets the next reviewer
# judge the next addition. Prints the reason and returns 0 when exempt.
exempt_reason() {
  case "$1" in
    README.md)
      echo "ceremony's own front page — a consumer's router is AGENTS.md, not this repo's README"
      ;;
    CONTRIBUTING.md)
      echo "repo-specific facts (this repo's roster, scopes and conventions); every governed repo writes its own"
      ;;
    CHANGELOG.md)
      echo "ceremony's own release history; a consumer keeps its own"
      ;;
    FLEET.md)
      echo "the operator's fleet map — about running the fleet, not about how a governed repo works"
      ;;
    *) return 1 ;;
  esac
}

die() {
  printf 'vendored-check: %s\n' "$@" >&2
  exit 1
}

manifest_file="$tree/$MANIFEST"
[ -f "$manifest_file" ] || die \
  "no $MANIFEST under $tree — the manifest is the sole declaration of the" \
  "  vendored doc set, and this guard has nothing to guard without it."

# Blank lines are skipped, exactly as actions/docs-sync reads it: the guard
# and the tool must accept the same file, or one of them is the bug.
mapfile -t manifest < <(grep -v '^[[:space:]]*$' "$manifest_file" || true)
[ "${#manifest[@]}" -gt 0 ] || die \
  "$MANIFEST is empty — an empty doctrine set is a ceremony bug, not a repo" \
  "  with no rules."

# Whether the tracked-file assertion can bind: only when the tree IS a git
# work tree root. Fixture trees are plain directories, and asserting
# tracked-ness against an enclosing repository would be asserting about the
# wrong tree.
tracked_check=no
if command -v git >/dev/null 2>&1; then
  toplevel="$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$toplevel" ] && [ "$toplevel" = "$(cd "$tree" && pwd -P)" ]; then
    tracked_check=yes
  fi
fi

# Every refusal is collected and reported together, one multi-line string
# per offending file: a guard that stops at the first problem makes a
# builder pay one CI round per file.
problems=()

# --- manifest → tree ---------------------------------------------------------

for entry in "${manifest[@]}"; do
  case "$entry" in
    /* | *..*)
      problems+=("$(
        printf '%s\n' \
          "$MANIFEST names '$entry' — an absolute path or a '..' escape. The" \
          "  mirror writes only inside a consumer's .ceremony/, so a path that" \
          "  leaves it is never vendorable." \
          "  Fix: name the path relative to the repository root, with no '..'."
      )")
      continue
      ;;
  esac

  path="$tree/$entry"

  # -L before -f: `[ -f ]` follows the link, so a symlink to a real file
  # would otherwise pass as a regular one.
  if [ -L "$path" ]; then
    problems+=("$(
      printf '%s\n' \
        "$MANIFEST names '$entry', which is a SYMLINK. A symlink vendors as" \
        "  doctrine while its content lives somewhere the mirror never checks" \
        "  (PR #43's round: it read as doctrine and stayed invisible)." \
        "  Fix: make '$entry' a regular file, or drop the entry from $MANIFEST."
    )")
    continue
  fi
  if [ -d "$path" ]; then
    problems+=("$(
      printf '%s\n' \
        "$MANIFEST names '$entry', which is a DIRECTORY. The manifest declares" \
        "  files, one per line — a directory entry vendors nothing." \
        "  Fix: name each file under '$entry' on its own line, or drop the entry."
    )")
    continue
  fi
  if [ ! -f "$path" ]; then
    problems+=("$(
      printf '%s\n' \
        "$MANIFEST names '$entry' but the tree has no such file. Every consumer" \
        "  mirroring this ref would fail on it." \
        "  Fix: add '$entry' to the tree, or remove it from $MANIFEST."
    )")
    continue
  fi
  if [ ! -s "$path" ]; then
    problems+=("$(
      printf '%s\n' \
        "$MANIFEST names '$entry', which is EMPTY. An empty file vendors as" \
        "  doctrine that says nothing, and is read as doctrine anyway." \
        "  Fix: write '$entry', or remove it from $MANIFEST."
    )")
    continue
  fi
  if [ "$tracked_check" = yes ] &&
    ! git -C "$tree" ls-files --error-unmatch -- "$entry" >/dev/null 2>&1; then
    problems+=("$(
      printf '%s\n' \
        "$MANIFEST names '$entry', which is not TRACKED. A file absent from the" \
        "  tag's tree cannot be fetched by a consumer syncing at that tag," \
        "  however present it is on this machine." \
        "  Fix: git add '$entry', or remove it from $MANIFEST."
    )")
    continue
  fi
done

# --- tree → manifest: the closed world over root `*.md` ----------------------

in_manifest() {
  local p
  for p in "${manifest[@]}"; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

shopt -s nullglob
exempted=()
vendored=()
for path in "$tree"/*.md; do
  doc="${path##*/}"
  if in_manifest "$doc"; then
    vendored+=("$doc")
    continue
  fi
  if reason="$(exempt_reason "$doc")"; then
    exempted+=("$doc — $reason")
    continue
  fi
  problems+=("$(
    printf '%s\n' \
      "'$doc' is a root doc in NEITHER list. Every root *.md is either vendored" \
      "  doctrine — mirrored into every governed repo at .ceremony/ — or" \
      "  deliberately ceremony-only, and nothing in the tree says which, so the" \
      "  decision has to be written down. Fix, one of:" \
      "    * add '$doc' to $MANIFEST, if it is agent-facing doctrine that every" \
      "      governed repo must carry;" \
      "    * add '$doc' to the exemption list in" \
      "      .github/scripts/vendored-check.sh, with the reason it stays" \
      "      ceremony-only."
  )")
done
shopt -u nullglob

if [ "${#problems[@]}" -gt 0 ]; then
  {
    printf 'vendored-check: %d problem(s) — docs/VENDORED.txt and the tree disagree.\n\n' \
      "${#problems[@]}"
    printf '%s\n\n' "${problems[@]}"
  } >&2
  exit 1
fi

printf 'vendored-check: %d manifest entries resolve; %d root docs vendored, %d exempt.\n' \
  "${#manifest[@]}" "${#vendored[@]}" "${#exempted[@]}"
[ "${#vendored[@]}" -eq 0 ] || printf '  vendored: %s\n' "${vendored[@]}"
[ "${#exempted[@]}" -eq 0 ] || printf '  exempt:   %s\n' "${exempted[@]}"
