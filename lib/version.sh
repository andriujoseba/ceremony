#!/usr/bin/env bash
# lib/version.sh — one version abstraction, two backends (issue #3).
#
# Sourced, never executed: no set -e/-u here — the sourcing script owns its
# own shell options. No git in this lib either: "version at the base commit"
# is the caller's job (git show / git worktree the base tree, then point
# version_read at it) — keeping the lib pure keeps its tests trivial.
#
# Backends ($1 of version_read / version_write):
#   file          — a VERSION file in the tree (box, rig, incubator)
#   package-json  — package.json's version field (cast)

# version_read <backend> [dir] — print the version; fail loudly on a
# missing/empty source. A wrong release is worse than a missing one, so
# every unreadable state is exit 1 with a message, never an empty print.
version_read() {
  local backend="${1:?version_read: backend required}" dir="${2:-.}"
  local path ver
  case "$backend" in
    file)
      path="$dir/VERSION"
      if [ ! -f "$path" ]; then
        echo "version_read: $path: no such file" >&2
        return 1
      fi
      # Whitespace-stripped, following box's drill-recorded.sh: a trailing
      # newline or a stray space in VERSION must never make 0.7.0 look
      # unlike 0.7.0 (whole-version matching everywhere).
      ver="$(tr -d '[:space:]' <"$path")"
      if [ -z "$ver" ]; then
        echo "version_read: $path is empty" >&2
        return 1
      fi
      printf '%s\n' "$ver"
      ;;
    package-json)
      # A clear message beats a bare command-not-found from deep inside a
      # workflow log.
      if ! command -v node >/dev/null 2>&1; then
        echo "version_read: node is required for version-source: package-json" >&2
        return 1
      fi
      path="$dir/package.json"
      if [ ! -f "$path" ]; then
        echo "version_read: $path: no such file" >&2
        return 1
      fi
      # Read via node's own parser, never regex — cast's "pkg_version
      # discipline" (cast release.yml): grepping JSON for "version" finds
      # dependency versions, engine fields, anything. An absent or
      # non-string field fails here rather than printing "undefined".
      node -e '
        const p = require(require("path").resolve(process.argv[1]));
        if (typeof p.version !== "string" || p.version === "") {
          console.error("version_read: " + process.argv[1] + ": no version field");
          process.exit(1);
        }
        console.log(p.version);
      ' "$path"
      ;;
    *)
      echo "version_read: unknown backend: $backend" >&2
      return 1
      ;;
  esac
}

# version_is_dev <ver> — exit 0 iff ver ends in the literal -dev suffix.
# Only -dev: an rc (1.2.3-rc1) is a pre-release, not a dev tree, and
# treating it as one would let the armed guard key on the wrong state.
version_is_dev() {
  case "${1:?version_is_dev: version required}" in
    *-dev) return 0 ;;
    *) return 1 ;;
  esac
}

# version_is_rc <ver> — exit 0 iff ver is exactly X.Y.Z-rcN, with N numeric.
# An rc dev tree ends in -dev and remains version_is_dev's state instead.
version_is_rc() {
  [[ "${1:?version_is_rc: version required}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc[0-9]+$ ]]
}

# version_next_dev <ver> — bare X.Y.Z -> X.Y.(Z+1)-dev, and
# X.Y.Z-rcN -> X.Y.Z-rc(N+1)-dev (print). #317 made that one rc convention
# arithmetic; -dev, malformed and other pre-release identifiers still refuse
# rather than guessing (box's drills/ prefix-confusion lore).
version_next_dev() {
  local ver="${1:?version_next_dev: version required}"
  local major minor patch rc
  if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-rc([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    rc="${BASH_REMATCH[4]}"
    # 10#: a zero-padded rc number ("09") would otherwise be read as octal.
    printf '%s.%s.%s-rc%s-dev\n' "$major" "$minor" "$patch" "$((10#$rc + 1))"
    return 0
  fi
  if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS=. read -r major minor patch <<<"$ver"
    # 10#: a zero-padded patch ("09") would otherwise be read as octal.
    printf '%s.%s.%s-dev\n' "$major" "$minor" "$((10#$patch + 1))"
    return 0
  fi
  echo "version_next_dev: refusing '$ver' — expected bare X.Y.Z or X.Y.Z-rcN" >&2
  return 1
}

# version_write <backend> <ver> [dir] — write the version into the tree.
version_write() {
  local backend="${1:?version_write: backend required}"
  local ver="${2:?version_write: version required}"
  local dir="${3:-.}"
  case "$backend" in
    file)
      printf '%s\n' "$ver" >"$dir/VERSION"
      ;;
    package-json)
      if ! command -v npm >/dev/null 2>&1; then
        echo "version_write: npm is required for version-source: package-json" >&2
        return 1
      fi
      # npm pkg set + a lockfile-only install, exactly cast's incantation
      # (cast release.yml L233–L239): package-lock.json embeds the version
      # twice, and a bump that skips the lockfile leaves every subsequent
      # `npm ci` failing on the mismatch. --ignore-scripts because a
      # version bump must never run anybody's install hooks.
      (cd "$dir" && npm pkg set version="$ver" \
        && npm install --package-lock-only --ignore-scripts)
      ;;
    *)
      echo "version_write: unknown backend: $backend" >&2
      return 1
      ;;
  esac
}
