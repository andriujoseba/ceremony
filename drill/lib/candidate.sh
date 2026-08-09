#!/usr/bin/env bash
# The candidate pin: the fork ref the scratch caller points at, and the
# rewrite that makes it resolvable (#313). Sourced, never run.
#
# The candidate's own CEREMONY_SELF_REF is by construction the tag this
# release has not created yet, so the consumer path cannot resolve directly
# from the candidate. The rehearsal rewrites that pin to the canonical
# candidate SHA on a fork ref, and never on the canonical repo.

DRILL_CANONICAL_REPO="heavy-duty/ceremony"

# pin_is_tag_named <ref> — exit 0 iff the ref reads like a release tag.
#
# Whole-field, and rc-aware: `0.7.0-rc1` shadows a tag as thoroughly as
# `0.7.0` does, while `drill/0.7.0` — the shape the drill actually uses —
# does not.
pin_is_tag_named() {
  local ref="${1:?pin_is_tag_named: ref required}"
  ref="${ref#refs/heads/}"
  ref="${ref#refs/tags/}"
  [[ "$ref" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]
}

# pin_assert_fork_ref <owner/repo> <ref> — the first of D4's two refusals.
#
# Creating a branch named like the tag on heavy-duty/ceremony would shadow
# that tag for every consumer until someone remembered to delete it (the
# 0.1.0 shadow-tag rule). The fork-ref rewrite is the only pin path this
# instrument will take, so the canonical repo as a tag-named stub source is a
# hard error rather than a warning.
pin_assert_fork_ref() {
  local repo="${1:?pin_assert_fork_ref: repo required}"
  local ref="${2:?pin_assert_fork_ref: ref required}"
  if [ "$repo" = "$DRILL_CANONICAL_REPO" ] && pin_is_tag_named "$ref"; then
    echo "drill: refusing --fork-ref '$repo@$ref' — a ref named like the tag on $DRILL_CANONICAL_REPO shadows that tag for every consumer until someone deletes it (the 0.1.0 shadow-tag rule). Pin the stub at a fork ref instead." >&2
    return 1
  fi
}

# pin_read <file> — the CEREMONY_SELF_REF a workflow carries, empty if none.
pin_read() {
  awk -F'"' '/^[[:space:]]*CEREMONY_SELF_REF:/ { print $2; exit }' "${1:?pin_read: file required}"
}

# pin_rewrite <file> <sha> — point every carrier line at the candidate SHA.
pin_rewrite() {
  local file="${1:?pin_rewrite: file required}" sha="${2:?pin_rewrite: sha required}" tmp
  tmp="$(mktemp)"
  awk -v sha="$sha" '
    /^[[:space:]]*CEREMONY_SELF_REF:/ {
      match($0, /^[[:space:]]*/)
      printf "%sCEREMONY_SELF_REF: \"%s\"\n", substr($0, 1, RLENGTH), sha
      next
    }
    { print }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

# fork_ref_prepare <fork-repo> <ref> <candidate-sha> <workdir>
#
# Create the ref at the candidate SHA and land one commit rewriting every
# workflow that carries the pin. Prints the rewritten head SHA. Every carrier
# moves together because self-ref-check refuses a tree whose pins disagree,
# and a drill running against a self-inconsistent ref would be measuring a
# tree no consumer could ever have.
fork_ref_prepare() {
  local repo="${1:?}" ref="${2:?}" sha="${3:?}" work="${4:?}"
  local branch="${ref#refs/heads/}" existing manifest carriers path local_file head
  pin_assert_fork_ref "$repo" "$branch" || return 1
  existing="$(scratch_ref_sha "$repo" "$branch")"
  if [ -n "$existing" ]; then
    echo "drill: refusing to prepare '$repo@$branch' — the ref already exists at $existing. Delete it or name another --fork-ref; the drill will not rewrite a ref it did not create." >&2
    return 1
  fi
  scratch_ref_create "$repo" "refs/heads/$branch" "$sha" || return 1
  carriers="$(scratch_paths "$repo" "$branch" | grep '^\.github/workflows/.*\.yml$' || true)"
  if [ -z "$carriers" ]; then
    echo "drill: refusing — $repo@$branch carries no .github/workflows/*.yml, so there is no CEREMONY_SELF_REF to rewrite." >&2
    return 1
  fi
  manifest="$work/pin-manifest"
  : >"$manifest"
  mkdir -p "$work/pins"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    local_file="$work/pins/$(printf '%s' "$path" | tr '/' '_')"
    drill_gh api "repos/$repo/contents/$path?ref=$branch" --jq '.content' |
      base64 -d >"$local_file" || return 1
    [ -n "$(pin_read "$local_file")" ] || continue
    pin_rewrite "$local_file" "$sha"
    printf 'A\t%s\t%s\n' "$path" "$local_file" >>"$manifest"
  done <<<"$carriers"
  if [ ! -s "$manifest" ]; then
    echo "drill: refusing — no workflow on $repo@$branch carries CEREMONY_SELF_REF; the pin guard would have nothing to rewrite (self-ref-check treats that as a failure too)." >&2
    return 1
  fi
  head="$(scratch_commit "$repo" "$branch" \
    "drill: rewrite CEREMONY_SELF_REF to the candidate SHA $sha" "$manifest")" || return 1
  printf '%s\n' "$head"
}

# fork_ref_verify <fork-repo> <ref> <candidate-sha> <workdir> — read the pins
# back and refuse unless every carrier reads the candidate SHA.
#
# The record claims the pin was rewritten; a claim in the one file whose job
# is to be evidence gets measured, not asserted.
fork_ref_verify() {
  local repo="${1:?}" ref="${2:?}" sha="${3:?}" work="${4:?}"
  local branch="${ref#refs/heads/}" path local_file pin wrong=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    local_file="$work/verify_$(printf '%s' "$path" | tr '/' '_')"
    drill_gh api "repos/$repo/contents/$path?ref=$branch" --jq '.content' |
      base64 -d >"$local_file" || return 1
    pin="$(pin_read "$local_file")"
    [ -n "$pin" ] || continue
    [ "$pin" = "$sha" ] || wrong="$wrong $path=$pin"
  done < <(scratch_paths "$repo" "$branch" | grep '^\.github/workflows/.*\.yml$' || true)
  if [ -n "$wrong" ]; then
    echo "drill: the rewritten pin does not read the candidate SHA $sha —$wrong" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}
