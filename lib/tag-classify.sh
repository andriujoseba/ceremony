#!/usr/bin/env bash
# Classify a pushed tag before the tag door reads or asserts the tree version
# (#497). Version-shaped tags always take the release path. Every other tag
# takes it too unless the caller explicitly declared a matching no-op glob.
set -euo pipefail

tag="${TAG:?tag-classify: TAG required}"
namespace="${NON_RELEASE_NAMESPACE:-}"

if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
  printf 'classification=release\n'
  exit 0
fi

# The unquoted RHS is deliberately the caller-declared glob. A skip is
# reachable only through this explicit declaration; an empty declaration
# and a non-match both preserve the old loud assertion path.
# shellcheck disable=SC2053
if [ -n "$namespace" ] && [[ "$tag" == $namespace ]]; then
  echo "NOTICE: tag '$tag' matched declared non-release namespace '$namespace' — skipping release publication and version assertion; creating nothing." >&2
  printf 'classification=non-release\n'
else
  printf 'classification=invalid\n'
fi
