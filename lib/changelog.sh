#!/usr/bin/env bash
# This is the convergence point for box/cast's executable release-notes.sh
# and rig's sourced release-lib.sh. Both histories matter: the publisher and
# guards must use exactly one definition of a changelog section.
#
# box/cast: https://github.com/heavy-duty/box/blob/a17903f07c83aa18c0f009565e1a5442da6d0827/.github/scripts/release-notes.sh
# rig: https://github.com/heavy-duty/rig/blob/7f8a0e08852837475505f404985a1251a2c3a8a1/.github/scripts/release-lib.sh

# changelog_section <file> <version>
#
# Print the body of exactly one changelog section. The whole second field is
# compared as a string so dots are not regex metacharacters and 0.7.0 can
# never select 0.7.0-rc1. Leading blank padding is omitted; blank lines after
# the body starts are content. Empty output represents either an absent or an
# empty section, which callers deliberately treat as the same refusal.
changelog_section() {
  awk -v ver="$2" '
    /^## / { if (found) exit; found = ($2 == ver); next }
    found && !body && /^[[:space:]]*$/ { next }
    found { body = 1; print }
  ' "$1"
}

# changelog_section_problem <file> <version>
#
# Print the first reason a version section cannot be published. Unreleased is
# a work-in-progress template, so its headings may deliberately be empty.
# A printed problem returns 1; silence returns 0.
changelog_section_problem() {
  local file="$1" ver="$2" notes problem

  if ! awk -v ver="$ver" '/^## / && $2 == ver { found = 1; exit } END { exit !found }' "$file"; then
    printf "no section for '%s'\n" "$ver"
    return 1
  fi

  [ "$ver" = "Unreleased" ] && return 0

  notes="$(changelog_section "$file" "$ver")"
  # Herestring, never a pipe: this awk `exit`s at the first entry, so a pipe
  # would leave printf writing a section body nobody is reading, EPIPE, and
  # `pipefail` would fail the pipeline although awk matched — reporting "no
  # entries" against a section that has them (#364, #411).
  if ! awk '/^[[:space:]]*[-*][[:space:]]/ { found = 1; exit } END { exit !found }' <<<"$notes"; then
    printf "section '%s' has no entries — a heading is not an entry\n" "$ver"
    return 1
  fi

  # Herestring for the same reason, and here the race is worse: this awk
  # `exit`s only when it HAS found an empty heading, so a pipe makes the
  # substitution die under `set -e` at exactly the moment there was a true
  # violation to report — a crash instead of the diagnosis (#411).
  problem="$(
    awk '
      /^### / {
        if (heading != "" && !entry) {
          reported = 1
          print heading
          exit
        }
        heading = $0
        entry = 0
        next
      }
      heading != "" && /^[[:space:]]*[-*][[:space:]]/ { entry = 1 }
      END {
        if (!reported && heading != "" && !entry) print heading
      }
    ' <<<"$notes"
  )"
  if [ -n "$problem" ]; then
    printf "section '%s' has an empty heading: '%s'\n" "$ver" "$problem"
    return 1
  fi
}

# changelog_fragments <dir>
#
# Print fragment paths in publication order, one per line: trailing issue
# number descending — newest issue first, the way every section in this
# family already reads — tie-broken on the filename. Considers *.md only
# and skips README.md, the marker that keeps the directory trackable when
# it holds no fragments (#112 D1). An absent or fragment-free directory
# prints nothing and succeeds: whether "no fragments" is a problem belongs
# to the caller — the assembler refuses an empty release, the arming guard
# is satisfied by the directory existing.
changelog_fragments() {
  local dir="$1" f base num
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    [ "$base" = "README.md" ] && continue
    num="${base%.md}"
    num="${num##*[!0-9]}"
    [ -n "$num" ] || num=0
    printf '%s\t%s\t%s\n' "$num" "$base" "$f"
  done | sort -t "$(printf '\t')" -k1,1nr -k2,2 | cut -f3-
}

# changelog_fragment_problem <file>
#
# Print the first reason a fragment cannot publish and return 1; silence
# returns 0. The same contract as changelog_section_problem, moved onto the
# PR that writes the fragment (#112 D9): a fragment is checkable the moment
# it exists, so malformedness fails the PR that wrote it, not the release
# that consumes it. The rules, and the failure each refuses:
#   - name '<issue>.md' or '<repo>-<issue>.md': anything else has no
#     derivable order, and an invented name is the "two builders, one
#     filename" collision the naming scheme exists to avoid (#112 D2);
#   - no '## ' line: the section heading is the assembler's to write, and
#     a smuggled one would split the published section;
#   - at least one bullet: a heading is not an entry — the rule the
#     publisher enforces at release time, moved onto the PR;
#   - no '### ' heading without a bullet before the next heading or EOF:
#     the dangling grouped heading #98 taught us to refuse.
#   - no entry longer than 300 characters (#167): 0.3.0 shipped a cluster of
#     316–789-character entries straight through the prose rule, so the
#     bound moves onto the PR like every other fragment rule. Measured on
#     the normalized entry — continuation lines joined, whitespace runs
#     collapsed to one space, the '- '/'* ' marker stripped, the '(#N)'
#     citation included — so wrapping alone can never red an entry. 300
#     splits the measured history: every healthy entry passes untouched,
#     the drift cluster does not. mawk's length() counts bytes; prose here
#     is ASCII and the fuzz is acceptable.
#   - every entry ends with its issue citation (#262): one '(' group of
#     '#N', 'repo#N' or 'owner/repo#N' references separated by ', ', then
#     ')', then the final '.' and nothing after it. Stated as style and
#     enforced by nobody, this rule cost #255 a full four-bot round on a
#     missing '(#248)'; the fragment rules that live in this guard drew no
#     review comment at all across the same fifteen PRs. Measured on the
#     same normalized entry as the bound above, so a citation that wraps
#     onto a continuation line still counts. The repo token is the one the
#     filename rule already admits, so '<repo>-<issue>.md' and its cite
#     cannot drift apart; the two halves of one convention. A single group
#     is what makes 'terminal' checkable — '(#236, #250).' lands two issues
#     in one entry, '(#236) and (#250).' does not. The citation need not
#     name the file's own issue: the filename already carries the
#     authorizing one, so a fragment may cite the incident beside it.
changelog_fragment_problem() {
  local file="$1" base problem kind detail rest
  base="${file##*/}"

  # Herestring although $base is one filename and cannot fill a pipe today:
  # "bounded" is a property of this caller that a later reader of this line
  # cannot check, and one idiom throughout is what makes the family's rule
  # readable off the source rather than off a table of exceptions (#411 D2).
  if ! grep -qE '^([a-z][a-z0-9-]*-)?[0-9]+\.md$' <<<"$base"; then
    printf "fragment '%s' is not named for its issue — want <issue>.md or <repo>-<issue>.md\n" "$file"
    return 1
  fi

  if grep -q '^## ' "$file"; then
    printf "fragment '%s' carries a '## ' heading — the section heading is the assembler's to write\n" "$file"
    return 1
  fi

  if ! grep -qE '^[[:space:]]*[-*][[:space:]]' "$file"; then
    printf "fragment '%s' has no entries — a heading is not an entry\n" "$file"
    return 1
  fi

  problem="$(
    awk '
      /^### / {
        if (heading != "" && !entry) {
          reported = 1
          print heading
          exit
        }
        heading = $0
        entry = 0
        next
      }
      heading != "" && /^[[:space:]]*[-*][[:space:]]/ { entry = 1 }
      END {
        if (!reported && heading != "" && !entry) print heading
      }
    ' "$file"
  )"
  if [ -n "$problem" ]; then
    printf "fragment '%s' has an empty heading: '%s'\n" "$file" "$problem"
    return 1
  fi

  # One walk of the entries, two rules, and the order between them is
  # deliberate: an over-long entry anywhere outranks a citation problem
  # anywhere, so the length diagnosis a fragment already draws is the same
  # one it drew before the citation rule existed. Both read the entry the
  # same normalizer produces, which is the whole reason they share a pass.
  problem="$(
    awk -v max=300 '
      # cite_problem <entry> — "", "uncited" or "misplaced". Counting the
      # groups is what distinguishes the two admitted shapes: one group
      # closing the entry passes however many references it carries, and a
      # second group anywhere means no single group is terminal.
      function cite_problem(e,   rest, groups, consumed, group_end) {
        rest = e
        groups = 0
        consumed = 0
        while (match(rest, /\((([A-Za-z0-9._-]+\/)?[a-z][a-z0-9-]*)?#[0-9]+(, (([A-Za-z0-9._-]+\/)?[a-z][a-z0-9-]*)?#[0-9]+)*\)/)) {
          groups++
          group_end = consumed + RSTART + RLENGTH - 1
          consumed = group_end
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (groups == 0) return e ~ /#[0-9]/ ? "misplaced" : "uncited"
        if (groups > 1) return "misplaced"
        return (group_end == length(e) - 1 && substr(e, group_end + 1) == ".") ? "" : "misplaced"
      }
      function excerpt(e) {
        return length(e) > 60 ? substr(e, 1, 60) "…" : e
      }
      function flush(   len, e, kind) {
        if (entry == "") return 0
        e = entry
        entry = ""
        gsub(/[[:space:]]+/, " ", e)
        sub(/^ /, "", e)
        sub(/ $/, "", e)
        len = length(e)
        if (len > max) {
          reported = 1
          printf "long\t%d\t%s\n", len, excerpt(e)
          return 1
        }
        kind = cite_problem(e)
        if (kind != "" && cite_kind == "") {
          cite_kind = kind
          cite_excerpt = excerpt(e)
        }
        return 0
      }
      /^### / { if (flush()) exit; next }
      /^[[:space:]]*[-*][[:space:]]/ {
        if (flush()) exit
        entry = $0
        sub(/^[[:space:]]*[-*][[:space:]]+/, "", entry)
        next
      }
      /^[[:space:]]*$/ { next }
      entry != "" { entry = entry " " $0 }
      # An exit from a main rule still runs END, so a length row printed
      # mid-file would be followed by the citation row it outranks — two
      # lines spliced into one diagnosis, the internal protocol row landing
      # inside the human-facing excerpt (#262 round 1). The reported flag is
      # the same guard the empty-heading walk above uses, for the same
      # reason: one diagnosis per fragment is the contract.
      END {
        if (flush()) exit
        if (!reported && cite_kind != "") printf "%s\t\t%s\n", cite_kind, cite_excerpt
      }
    ' "$file"
  )"
  if [ -n "$problem" ]; then
    kind="${problem%%$'\t'*}"
    rest="${problem#*$'\t'}"
    detail="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    case "$kind" in
      long)
        printf "fragment '%s' has a %s-character entry — '%s' — the bound is 300: split it into multiple '- ' entries in this same fragment\n" \
          "$file" "$detail" "$rest"
        ;;
      uncited)
        printf "fragment '%s' has an entry with no issue citation — '%s' — end it with the issue it comes from: '(#N).'\n" \
          "$file" "$rest"
        ;;
      *)
        printf "fragment '%s' has an entry whose issue citation is not terminal — '%s' — exactly one '(#N)' group ends the entry, the final '.' after it\n" \
          "$file" "$rest"
        ;;
    esac
    return 1
  fi
}

# changelog_shape_problem <changelog> <fragments-dir>
#
# Print the first reason a fragment set cannot publish and return 1; silence
# returns 0. Shape is a set-level property (#157 D3), so this is the one
# definition shared by the PR-time guard and the release-time assembler:
# fragments may not mix grouped headings with ungrouped bullets, and a
# non-empty set must match the newest published section when one exists.
#
# The anchor is declarable (#182): an optional sentinel '<dir>/shape',
# holding exactly 'flat' or 'grouped' on one line, pins the set's shape and
# outranks the newest-published-section inference — the door a deliberate
# flip walks through, while undeclared drift stays red (#159). Absent, the
# inference binds unchanged. Any other content — empty, trailing junk, an
# unknown word — is a diagnosis naming the file, never a silent fallback.
# The sentinel lives in the fragments dir so it binds in both callers: the
# assembler calls with changelog="" and still sees it. It is not a fragment
# — changelog_fragments matches *.md only, so 'shape' never enters the list.
changelog_shape_problem() {
  local changelog="$1" dir="$2"
  local fragments f grouped_in="" ungrouped_in="" published="" published_body=""
  local sentinel="$dir/shape" declared=""

  if [ -f "$sentinel" ]; then
    # The one-line contract is checked on the file itself: command
    # substitution strips every trailing newline, so the captured word
    # cannot tell 'grouped' from 'grouped' plus blank lines.
    if [ "$(wc -l <"$sentinel")" -gt 1 ]; then
      printf "'%s' declares neither shape — its whole content must be 'flat' or 'grouped', one line\n" "$sentinel"
      return 1
    fi
    declared="$(cat "$sentinel")"
    case "$declared" in
      flat | grouped) ;;
      *)
        printf "'%s' declares neither shape — its whole content must be 'flat' or 'grouped', one line\n" "$sentinel"
        return 1
        ;;
    esac
  fi

  fragments="$(changelog_fragments "$dir")"
  [ -n "$fragments" ] || return 0

  while IFS= read -r f; do
    if [ -z "$grouped_in" ] && grep -q '^### ' "$f"; then
      grouped_in="$f"
    fi
    if [ -z "$ungrouped_in" ] && awk '
        /^### / { exit(found ? 0 : 1) }
        /^[[:space:]]*[-*][[:space:]]/ { found = 1 }
        END { exit(found ? 0 : 1) }' "$f"; then
      ungrouped_in="$f"
    fi
  done <<<"$fragments"

  if [ -n "$grouped_in" ] && [ -n "$ungrouped_in" ]; then
    if [ "$grouped_in" = "$ungrouped_in" ]; then
      printf "fragment '%s' mixes grouped headings and ungrouped bullets — a repo is one shape or the other\n" "$grouped_in"
    else
      printf "fragment '%s' is grouped but fragment '%s' is not — a repo is one shape or the other\n" "$grouped_in" "$ungrouped_in"
    fi
    return 1
  fi

  if [ -n "$declared" ]; then
    if [ "$declared" = "grouped" ] && [ -n "$ungrouped_in" ]; then
      printf "fragment '%s' is flat but '%s' declares grouped — a repo is one shape or the other\n" \
        "$ungrouped_in" "$sentinel"
      return 1
    fi
    if [ "$declared" = "flat" ] && [ -n "$grouped_in" ]; then
      printf "fragment '%s' is grouped but '%s' declares flat — a repo is one shape or the other\n" \
        "$grouped_in" "$sentinel"
      return 1
    fi
    return 0
  fi

  if [ -f "$changelog" ]; then
    published="$(awk '$1 == "##" && $2 != "Unreleased" { print $2; exit }' "$changelog")"
  fi
  [ -n "$published" ] || return 0

  published_body="$(changelog_section "$changelog" "$published")"
  # Herestring, never a pipe. `grep -q` exits at the section's first '### ',
  # so a pipe leaves printf writing the rest of the body, EPIPE, and
  # `pipefail` fails the pipeline although grep MATCHED — the `if` falls
  # through to the `elif` and fabricates "grouped fragment, flat section"
  # against a grouped one, which is what reached a consumer repo. The other
  # direction is worse and silent: flat fragments plus a genuinely grouped
  # section skip the body, $grouped_in is empty, and a real violation
  # returns 0 (#364, #411).
  if grep -q '^### ' <<<"$published_body"; then
    if [ -n "$ungrouped_in" ]; then
      printf "fragment '%s' is flat but newest published section '%s' in '%s' is grouped — a repo is one shape or the other\n" \
        "$ungrouped_in" "$published" "$changelog"
      return 1
    fi
  elif [ -n "$grouped_in" ]; then
    printf "fragment '%s' is grouped but newest published section '%s' in '%s' is flat — a repo is one shape or the other\n" \
      "$grouped_in" "$published" "$changelog"
    return 1
  fi
}

# changelog_assemble <dir>
#
# Print the assembled section body — no '## ' line; that heading belongs to
# the caller — for every fragment in changelog_fragments order. Assumes each
# fragment already passed changelog_fragment_problem; the one property only
# the whole set can show is shape: a repo is grouped or flat, never both
# (#112 D4), because merging the shapes would silently strand ungrouped
# bullets, so a mix prints a diagnosis naming the offending fragments and
# returns 1. Group order is canonical (#112 D5): Added, Changed, Fixed,
# Removed, Deprecated, Security, then any other group in first-seen order —
# appended, never dropped. Inside a group, fragment order is preserved, and
# a bullet's continuation lines travel with it verbatim: entries in this
# family wrap, and reflowing someone's prose is not this tool's business.
# An empty directory prints nothing and succeeds; refusing an empty release
# is the caller's stance, not this function's.
changelog_assemble() {
  local dir="$1" nl=$'\n'
  local fragments f grouped_in="" chunk g seen="" ordered="" body first=1 diagnosis
  fragments="$(changelog_fragments "$dir")"
  [ -n "$fragments" ] || return 0

  if ! diagnosis="$(changelog_shape_problem "" "$dir")"; then
    printf '%s\n' "$diagnosis"
    return 1
  fi

  grouped_in="$(printf '%s\n' "$fragments" | while IFS= read -r f; do
    if grep -q '^### ' "$f"; then
      printf '%s\n' "$f"
      break
    fi
  done)"
  if [ -z "$grouped_in" ]; then
    while IFS= read -r f; do
      chunk="$(awk 'body || !/^[[:space:]]*$/ { body = 1; print }' "$f")"
      [ -n "$chunk" ] || continue
      printf '%s\n' "$chunk"
    done <<<"$fragments"
    return 0
  fi

  while IFS= read -r f; do
    while IFS= read -r g; do
      # Herestring for the family's one idiom (#411 D2), although $seen holds
      # only canonical group names and cannot fill a pipe. `<<<` appends a
      # newline where `printf '%s'` did not, so the feed carries one extra
      # empty line; `-Fx` against a non-empty $g cannot match an empty line,
      # so the answer is unchanged — asserted, not assumed, in the suite.
      grep -qFx -- "$g" <<<"$seen" || seen="$seen$g$nl"
    done < <(awk '/^### / { name = substr($0, 5); sub(/[[:space:]]+$/, "", name); print name }' "$f")
  done <<<"$fragments"

  for g in Added Changed Fixed Removed Deprecated Security; do
    grep -qFx -- "$g" <<<"$seen" && ordered="$ordered$g$nl"
  done
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in
      Added | Changed | Fixed | Removed | Deprecated | Security) ;;
      *) ordered="$ordered$g$nl" ;;
    esac
  done <<<"$seen"

  while IFS= read -r g; do
    [ -n "$g" ] || continue
    body=""
    while IFS= read -r f; do
      chunk="$(awk -v want="$g" '
        /^### / { name = substr($0, 5); sub(/[[:space:]]+$/, "", name); ingroup = (name == want); next }
        ingroup' "$f" | awk 'body || !/^[[:space:]]*$/ { body = 1; print }')"
      [ -n "$chunk" ] || continue
      body="${body:+$body$nl}$chunk"
    done <<<"$fragments"
    [ -n "$body" ] || continue
    [ "$first" = 1 ] || printf '\n'
    printf '### %s\n\n%s\n' "$g" "$body"
    first=0
  done <<<"$ordered"
  return 0
}
