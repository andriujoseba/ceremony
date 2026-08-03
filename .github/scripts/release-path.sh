#!/usr/bin/env bash
# The release doors' executable path (discussion #217; issue #237). The
# 0.5.0 record had to explain why lib/ruling.sh changed without changing a
# door. Keep this list executable so a doors-unchanged record measures the
# workflow and only the scripts it actually runs, while the test catches a
# new or removed dependency before a record can silently omit it.
set -euo pipefail

printf '%s\n' \
  .github/workflows/release.yml \
  bin/ \
  lib/version.sh \
  lib/decide.sh \
  lib/facts.sh \
  lib/changelog.sh
