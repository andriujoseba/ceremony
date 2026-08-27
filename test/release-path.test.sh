#!/usr/bin/env bash
# Contract tests for the release-door path manifest (issue #237). The list
# is evidence for skipping a live drill, so drift in either direction must
# fail before a release record can make an incomplete claim.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

PATH_SCRIPT="$ROOT/.github/scripts/release-path.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

readme_path() {
  awk '
    /^2\. The release path is exactly the output of$/ { condition = 1; next }
    condition && /^   ```text$/ { fence = 1; next }
    fence && /^   ```$/ { closed = 1; exit }
    fence {
      line = $0
      sub(/^   /, "", line)
      print line
    }
    END { if (!condition || !fence || !closed) exit 1 }
  ' "$1/drills/README.md"
}

readme_path_check() {
  local tree="$1" declared documented
  documented="$(readme_path "$tree")" || {
    printf 'release-path: README list not found\n' >&2
    return 1
  }
  if [ -z "$documented" ]; then
    printf 'release-path: README list is empty\n' >&2
    return 1
  fi
  declared="$(declared_path "$tree")"
  diff -u <(printf '%s\n' "$declared") <(printf '%s\n' "$documented")
}

library_refs() {
  local sibling_refs=no
  case "$1" in
    */lib/*.sh) sibling_refs=yes ;;
  esac
  awk -v sibling_refs="$sibling_refs" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      while (match(line, /lib\/[[:alnum:]_.-]+\.sh/)) {
        print substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
      # Door libraries source siblings through their own BASH_SOURCE dirname,
      # so the executable line ends in /name.sh without a literal lib/ (#237).
      if (sibling_refs == "yes" && $0 ~ /^[[:space:]]*(\.|source)[[:space:]]/) {
        line = $0
        while (match(line, /\/[[:alnum:]_.-]+\.sh/)) {
          print "lib" substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
        }
      }
    }
  ' "$1"
}

# derive_path <tree> — print the workflow, bin/ when a bin command sources a
# door library, and the workflow's direct + transitive lib dependencies.
derive_path() {
  local tree="$1" workflow
  local pending seen=" " lib file refs ref bin_uses_lib=no
  workflow="$tree/.github/workflows/release.yml"

  printf '%s\n' .github/workflows/release.yml
  pending="$(library_refs "$workflow" | sort -u)"

  while [ -n "$pending" ]; do
    lib="$(printf '%s\n' "$pending" | sed -n '1p')"
    pending="$(printf '%s\n' "$pending" | sed '1d')"
    case "$seen" in
      *" $lib "*) continue ;;
    esac
    seen="$seen$lib "
    printf '%s\n' "$lib"
    file="$tree/$lib"
    [ -f "$file" ] || continue
    refs="$(library_refs "$file" | sort -u)"
    if [ -n "$refs" ]; then
      pending="$(printf '%s\n%s\n' "$pending" "$refs" | sed '/^$/d' | sort -u)"
    fi
  done

  if [ -d "$tree/bin" ]; then
    for file in "$tree"/bin/*; do
      [ -f "$file" ] || continue
      refs="$(library_refs "$file")"
      for ref in $refs; do
        case "$seen" in
          *" $ref "*) bin_uses_lib=yes ;;
        esac
      done
    done
  fi
  [ "$bin_uses_lib" = no ] || printf '%s\n' bin/
}

declared_path() {
  bash "$1/.github/scripts/release-path.sh"
}

path_check() {
  local tree="$1" declared derived missing extra
  declared="$(declared_path "$tree" | sort -u)"
  derived="$(derive_path "$tree" | sort -u)"
  missing="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$derived"))"
  extra="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$derived"))"
  if [ -n "$missing" ]; then
    printf 'release-path: missing dependency: %s\n' "$missing" >&2
  fi
  if [ -n "$extra" ]; then
    printf 'release-path: stale path: %s\n' "$extra" >&2
  fi
  [ -z "$missing" ] && [ -z "$extra" ]
}

fixture() {
  local name="$1" tree
  tree="$TMP/$name"
  mkdir -p "$tree/.github/scripts" "$tree/.github/workflows" "$tree/lib" \
    "$tree/bin" "$tree/drills"
  cp "$PATH_SCRIPT" "$tree/.github/scripts/release-path.sh"
  cp "$ROOT/drills/README.md" "$tree/drills/README.md"
  printf '#!/usr/bin/env bash\n. "%s"\n' \
    "\$ROOT/lib/changelog.sh" >"$tree/bin/assemble"
  printf '#!/usr/bin/env bash\n' >"$tree/lib/changelog.sh"
  printf '#!/usr/bin/env bash\n' >"$tree/lib/decide.sh"
  printf '#!/usr/bin/env bash\n' >"$tree/lib/tag-classify.sh"
  printf '#!/usr/bin/env bash\n# shellcheck source=lib/version.sh\n. "%s"\n' \
    "\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)/version.sh" \
    >"$tree/lib/facts.sh"
  printf '#!/usr/bin/env bash\n' >"$tree/lib/version.sh"
  printf '%s\n' "$tree"
}

# Exact output is the record author's copy-paste source.
check "manifest prints the specified ordered release path" 0 \
  $'.github/workflows/release.yml\nbin/\nlib/tag-classify.sh\nlib/version.sh\nlib/decide.sh\nlib/facts.sh\nlib/changelog.sh' \
  bash "$PATH_SCRIPT"
check "README prints the manifest's ordered release path" 0 "" \
  readme_path_check "$ROOT"
check "real workflow and transitive dependencies match the manifest" 0 "" \
  path_check "$ROOT"

# The convenience copy is guarded in both directions, including order, and
# losing the extractor's anchor cannot turn the comparison vacuously green
# (#514).
tree="$(fixture readme-script-added)"
sed -i 's|  lib/changelog.sh$|  lib/changelog.sh \\|' \
  "$tree/.github/scripts/release-path.sh"
printf '  lib/ruling.sh\n' >>"$tree/.github/scripts/release-path.sh"
check "a manifest-only entry reds the README comparison" 1 \
  "lib/ruling.sh" readme_path_check "$tree"

tree="$(fixture readme-entry-removed)"
sed -i '/^   lib\/tag-classify\.sh$/d' "$tree/drills/README.md"
check "a README-only removal reds the comparison" 1 \
  "lib/tag-classify.sh" readme_path_check "$tree"

tree="$(fixture readme-reordered)"
sed -i \
  -e 's|^   lib/version\.sh$|   lib/ORDER-SWAP|' \
  -e 's|^   lib/decide\.sh$|   lib/version.sh|' \
  -e 's|^   lib/ORDER-SWAP$|   lib/decide.sh|' \
  "$tree/drills/README.md"
check "reordering the README list reds the comparison" 1 \
  "lib/decide.sh" readme_path_check "$tree"

tree="$(fixture readme-list-missing)"
sed -i 's/^2\. The release path is exactly the output of$/2. Release-path copy:/' \
  "$tree/drills/README.md"
check "a missing README list reds instead of comparing nothing" 1 \
  "README list not found" readme_path_check "$tree"

# A door growing a dependency must name the missing path (#237 D7).
tree="$(fixture missing)"
printf 'run: bash "%s"\nrun: bash "%s"\nrun: bash "%s"\nrun: . "%s"\nrun: . "%s"\nrun: . "%s"\n' \
  "\$CEREMONY_DIR/lib/tag-classify.sh" \
  "\$CEREMONY_DIR/lib/facts.sh" "\$CEREMONY_DIR/lib/decide.sh" \
  "\$CEREMONY_DIR/lib/changelog.sh" "\$CEREMONY_DIR/lib/version.sh" \
  "\$CEREMONY_DIR/lib/ruling.sh" \
  >"$tree/.github/workflows/release.yml"
printf '#!/usr/bin/env bash\n' >"$tree/lib/ruling.sh"
check "a new workflow library fails with its missing path" 1 \
  "missing dependency: lib/ruling.sh" path_check "$tree"

# A library growing a sibling dependency in the production idiom must also
# name the missing path; a literal lib/ marker in a comment is not evidence.
tree="$(fixture missing-transitive)"
printf 'run: bash "%s"\nrun: bash "%s"\nrun: bash "%s"\nrun: . "%s"\n' \
  "\$CEREMONY_DIR/lib/tag-classify.sh" \
  "\$CEREMONY_DIR/lib/facts.sh" "\$CEREMONY_DIR/lib/decide.sh" \
  "\$CEREMONY_DIR/lib/changelog.sh" \
  >"$tree/.github/workflows/release.yml"
printf '# shellcheck source=lib/ruling.sh\n. "%s"\n' \
  "\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)/ruling.sh" \
  >>"$tree/lib/facts.sh"
printf '#!/usr/bin/env bash\n' >"$tree/lib/ruling.sh"
check "a new sibling library fails with its missing path" 1 \
  "missing dependency: lib/ruling.sh" path_check "$tree"

# A manifest may not rot into a safe-looking superset.
tree="$(fixture extra)"
printf 'run: bash "%s"\nrun: bash "%s"\nrun: bash "%s"\nrun: . "%s"\n' \
  "\$CEREMONY_DIR/lib/tag-classify.sh" \
  "\$CEREMONY_DIR/lib/facts.sh" "\$CEREMONY_DIR/lib/decide.sh" \
  "\$CEREMONY_DIR/lib/changelog.sh" \
  >"$tree/.github/workflows/release.yml"
sed -i 's|  lib/changelog.sh$|  lib/changelog.sh \\|' \
  "$tree/.github/scripts/release-path.sh"
printf '  lib/ruling.sh\n' >>"$tree/.github/scripts/release-path.sh"
printf '#!/usr/bin/env bash\n' >"$tree/lib/ruling.sh"
check "a path no door reads fails as stale" 1 "stale path: lib/ruling.sh" \
  path_check "$tree"

# Transitive sourcing is part of the derivation, not decoration.
tree="$(fixture transitive)"
printf 'run: bash "%s"\nrun: bash "%s"\nrun: bash "%s"\nrun: . "%s"\n' \
  "\$CEREMONY_DIR/lib/tag-classify.sh" \
  "\$CEREMONY_DIR/lib/facts.sh" "\$CEREMONY_DIR/lib/decide.sh" \
  "\$CEREMONY_DIR/lib/changelog.sh" \
  >"$tree/.github/workflows/release.yml"
: >"$tree/lib/facts.sh"
check "removing facts' version source fails as a stale path" 1 \
  "stale path: lib/version.sh" path_check "$tree"

summary
