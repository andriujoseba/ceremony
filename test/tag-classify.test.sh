#!/usr/bin/env bash
# The tag door has three intentional outcomes (#497): version-shaped tags
# release, declared non-release namespaces no-op, and every other tag reaches
# the existing loud tree-version assertion.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
# shellcheck disable=SC1091
. "$ROOT/test/harness.sh"

CLASSIFY="$ROOT/lib/tag-classify.sh"
WORKFLOW="$ROOT/.github/workflows/release.yml"

classify() { # $1 = tag, $2 = namespace
  env TAG="$1" NON_RELEASE_NAMESPACE="$2" bash "$CLASSIFY"
}

assert_step_head() {
  local line
  line="$(grep -nF -- "- name: the tag must name the tree's own version" "$WORKFLOW" | cut -d: -f1)"
  sed -n "$line,$((line + 4))p" "$WORKFLOW"
}

classifier_gate_count() {
  awk '
    BEGIN { quote = sprintf("%c", 39) }
    /^  release-on-tag:$/ { tag = 1 }
    tag && index($0, "if: steps.classify.outputs.release == " quote "yes" quote) { count++ }
    END { print count + 0 }
  ' "$WORKFLOW"
}

check "a final version remains a release" 0 "release=yes" \
  classify 1.2.3 ""
check "an rc remains a release" 0 "release=yes" \
  classify 1.2.3-rc4 ""
check "a version wins even over an all-matching namespace" 0 "release=yes" \
  classify 1.2.3 '**'

check "a declared drill namespace is a clean no-op" 0 "release=no" \
  classify drill/0.1.2-a877cd9 'drill/**'
check "the no-op log names the namespace" 0 \
  "matched declared non-release namespace 'drill/**'" \
  classify drill/0.1.2-a877cd9 'drill/**'
check "the no-op log names why no release work runs" 0 \
  "skipping release publication and version assertion; creating nothing" \
  classify drill/0.1.2-a877cd9 'drill/**'

check "the same drill tag without a declaration reaches the assertion" 0 \
  "release=yes" classify drill/0.1.2-a877cd9 ""
check "a non-matching declaration cannot create a fallthrough no-op" 0 \
  "release=yes" classify malformed-tag 'drill/**'
check "a malformed tag with no declaration preserves the assertion path" 0 \
  "release=yes" classify malformed-tag ""

# The classifier runs before the version assertion; every release-side step
# is then explicitly gated. This makes the no-op perform no version read,
# notes assembly, artifact hook, or publish rather than relying on fallthrough.
check "the tree-version assertion is gated by classification" 0 \
  "if: steps.classify.outputs.release == 'yes'" assert_step_head
check "all four release-side steps carry the classifier gate" 0 "4" \
  classifier_gate_count

summary
