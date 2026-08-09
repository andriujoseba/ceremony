#!/usr/bin/env bash
# The armed fixture and the consumer caller stub the drill seeds (#313).
# Sourced, never run.

# fixture_write <dir> <version> — the armed state drills/README step 3 names:
# `X.Y.Z-dev`, a preamble-only CHANGELOG.md, the fragments directory with its
# README marker plus fragments for the ceremony to consume, and a non-blank
# drills record so `drill-recorded` has something to find.
#
# The fragments carry terminal issue citations because the candidate's own
# `bin/changelog-assemble` refuses an uncited entry (#262) — 0.6.0's fixture
# was written before that rule and had to be rewritten mid-drill.
fixture_write() {
  local dir="${1:?fixture_write: dir required}" ver="${2:?fixture_write: version required}"
  mkdir -p "$dir/changelog.d" "$dir/drills"
  printf '%s-dev\n' "$ver" >"$dir/VERSION"
  cat >"$dir/CHANGELOG.md" <<'EOF'
# Changelog

Every released version has a section here. The next release's section is
assembled from `changelog.d/` by the ceremony PR.
EOF
  cat >"$dir/changelog.d/README.md" <<'EOF'
# changelog.d/

The marker that keeps this directory tracked when it holds no fragments.
EOF
  printf -- '- The drill fixture arms a first ordinary change (#313).\n' \
    >"$dir/changelog.d/1.md"
  printf -- '- A second fragment, so the assembled section is plural (#313).\n' \
    >"$dir/changelog.d/2.md"
  printf -- '- A third fragment, proving the whole directory is consumed (#313).\n' \
    >"$dir/changelog.d/3.md"
  # shellcheck disable=SC2016 # backticks are the record's own Markdown
  printf '# %s — drill fixture record\n\nSeeded by `drill/rehearsal.sh` so the tree is not bare-version-without-a-record.\n' \
    "$ver" >"$dir/drills/$ver.md"
}

# fixture_paths — the fixture's paths, in the order they are committed.
fixture_paths() {
  local ver="${1:?fixture_paths: version required}"
  printf '%s\n' VERSION CHANGELOG.md changelog.d/README.md \
    changelog.d/1.md changelog.d/2.md changelog.d/3.md "drills/$ver.md"
}

# caller_write <dir> <fork-repo> <fork-ref> — docs/CONSUMERS.md's entire
# release.yml, verbatim but for the pin, which is the drill's whole point.
caller_write() {
  local dir="${1:?caller_write: dir required}"
  local repo="${2:?caller_write: fork repo required}"
  local ref="${3:?caller_write: fork ref required}"
  mkdir -p "$dir/.github/workflows"
  cat >"$dir/.github/workflows/release.yml" <<EOF
name: release
# Triggers and permissions MUST live here (a called workflow cannot define them):
on:
  # ONE push key, both filters — YAML maps are last-key-wins; a second sibling
  # \`push:\` silently replaces the first and kills a door (rig's review catch).
  push:
    tags: ["**"]      # every tag — a wrong tag must FAIL the assert loudly,
                      # never be skipped by a shape filter that didn't match
    branches: [main]
permissions:
  contents: write       # tag ref create + release create + the bump push
  pull-requests: write  # decide's label read; the bump-fallback \`gh pr create\`
  issues: write         # --label on that fallback PR rides the issues API
jobs:
  release:
    uses: $repo/.github/workflows/release.yml@$ref
    with:
      version-source: file
EOF
}

# fixture_assert_seeded <repo> <branch> — the 0.4.0 lesson, enforced in code.
#
# The fixture is committed BEFORE the caller so the first door run has a real
# parent version to inspect; a caller landing on an empty tree runs the doors
# against nothing and its green tells you nothing. This reads the scratch
# repo's own tree rather than trusting a local flag, so the ordering is
# asserted against what GitHub holds.
fixture_assert_seeded() {
  local repo="${1:?fixture_assert_seeded: repo required}"
  local branch="${2:?fixture_assert_seeded: branch required}"
  local paths missing="" want
  paths="$(scratch_paths "$repo" "$branch")"
  for want in VERSION CHANGELOG.md changelog.d/README.md; do
    grep -qxF "$want" <<<"$paths" || missing="$missing $want"
  done
  if [ -n "$missing" ]; then
    echo "drill: refusing to install the caller stub — $repo@$branch is missing the armed fixture:$missing. The fixture is seeded before the caller so the first door run has a real parent version to inspect (the 0.4.0 setup lesson)." >&2
    return 1
  fi
}

# caller_install <repo> <branch> <stage> <fork-repo> <fork-ref> <workdir>
#
# The one door into installing the caller, and the reason the ordering is
# enforced rather than documented: the seeding assertion is inside this
# function, so no reordering of the orchestration above can install a caller
# onto an unseeded tree. Prints the commit SHA.
caller_install() {
  local repo="${1:?}" branch="${2:?}" stage="${3:?}"
  local fork_repo="${4:?}" fork_ref="${5:?}" work="${6:?}" manifest
  fixture_assert_seeded "$repo" "$branch" || return 1
  caller_write "$stage" "$fork_repo" "$fork_ref"
  manifest="$work/caller.manifest"
  printf 'A\t.github/workflows/release.yml\t%s\n' \
    "$stage/.github/workflows/release.yml" >"$manifest"
  scratch_commit "$repo" "$branch" \
    "install the docs/CONSUMERS.md release caller, pinned at $fork_repo@$fork_ref" \
    "$manifest"
}

# ceremony_assemble <dir> <version> <date> <root> — what the ceremony PR
# stamps, assembled by the candidate's own bin/changelog-assemble so the
# probe consumes the release path's real assembler, not a drill-local copy.
ceremony_assemble() {
  local dir="${1:?}" ver="${2:?}" stamp="${3:?}" root="${4:?}"
  (cd "$dir" && "$root/bin/changelog-assemble" "$ver" "$stamp") >/dev/null
}
