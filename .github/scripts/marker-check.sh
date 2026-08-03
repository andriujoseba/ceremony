#!/usr/bin/env bash
# Availability-marker guard (issue #238). Five of five markers found by #221
# outlived the releases that shipped their machinery. A release candidate must
# therefore reject a marker its assembled changelog makes false, while every
# tree rejects an untraceable marker. Cross-repo citations are traceable but
# are not compared with this repository's changelog.
#
# Usage: marker-check.sh [tree-dir]   (default: the repository root)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tree="${1:-$ROOT}"

fail() {
  printf '%s\n' "$@" >&2
  exit 1
}

if ! git -C "$tree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "marker-check: $tree is not a Git work tree; tracked Markdown cannot be determined."
fi

marker_records="$(mktemp)"
trap 'rm -f "$marker_records"' EXIT

mapfile -d '' markdown_files < <(git -C "$tree" ls-files -z -- '*.md')
for relative in "${markdown_files[@]}"; do
  case "$relative" in
    changelog.d/*) continue ;;
  esac

  if ! awk -v file="$relative" '
    { lines[NR] = $0 }
    END {
      token = "**unreleased**"
      citation_re = "^[[:space:]]*\\((([[:alnum:]_.-]+/)?[[:alnum:]_.-]+)?#[0-9]+\\)"
      bad = 0

      for (line_no = 1; line_no <= NR; line_no++) {
        remaining = lines[line_no]
        offset = 0
        while ((at = index(remaining, token)) != 0) {
          rest = substr(remaining, at + length(token))
          candidate = rest
          next_line = line_no + 1
          while (candidate ~ /^[[:space:]]*$/ && next_line <= NR) {
            candidate = candidate " " lines[next_line]
            next_line++
          }

          if (match(candidate, citation_re)) {
            citation = substr(candidate, RSTART, RLENGTH)
            sub(/^[[:space:]]*\(/, "", citation)
            sub(/\)$/, "", citation)
            printf "%s\t%d\t%s\n", file, line_no, citation
          } else {
            printf "marker-check: %s:%d: %s\n", file, line_no, lines[line_no] > "/dev/stderr"
            printf "marker-check: every **unreleased** marker must be immediately followed by an issue citation such as (#238), (crew#293), or (owner/repo#293).\n" > "/dev/stderr"
            bad = 1
          }

          offset += at + length(token) - 1
          remaining = substr(lines[line_no], offset + 1)
        }
      }
      exit bad
    }
  ' "$tree/$relative" >>"$marker_records"; then
    exit 1
  fi
done

version=""
if [ -f "$tree/VERSION" ]; then
  IFS= read -r version <"$tree/VERSION" || true
fi

if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  [ -f "$tree/CHANGELOG.md" ] || \
    fail "marker-check: bare VERSION '$version' requires CHANGELOG.md for the release-marker check."

  shipped_issues="$(awk '
    $1 == "##" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {
      if (in_section) exit
      in_section = 1
      next
    }
    in_section && /^##[[:space:]]/ { exit }
    in_section {
      text = $0
      while (match(text, /(^|[^[:alnum:]_./-])#[0-9]+/)) {
        issue = substr(text, RSTART, RLENGTH)
        sub(/^.*#/, "", issue)
        print issue
        text = substr(text, RSTART + RLENGTH)
      }
    }
  ' "$tree/CHANGELOG.md" | sort -u)"

  while IFS=$'\t' read -r file line citation; do
    case "$citation" in
      \#*)
        issue="${citation#\#}"
        if printf '%s\n' "$shipped_issues" | grep -qxF "$issue"; then
          fail "marker-check: $file:$line: **unreleased** (#$issue) is false on release candidate $version; CHANGELOG.md's top release section cites #$issue, so clear the marker in this release PR."
        fi
        ;;
    esac
  done <"$marker_records"
fi

echo "marker-check: availability markers agree with the tree."
