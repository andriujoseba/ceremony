#!/usr/bin/env bash
set -euo pipefail

# docs-sync.sh [--check|--fix] [--source <dir>] — materialize and verify the
# `.ceremony/` doctrine mirror in a governed repo. Run from the consumer's
# repo root (the action runs after the consumer's own checkout, like every
# guard).
#
# WHY A COPY EXISTS AT ALL (the reference-vs-mirror rationale — issue #19,
# PR #17's consumption model): workflows and actions are consumed BY
# REFERENCE — GitHub fetches them from the pinned ref at run time, so no
# copy ever exists in a consumer, and nothing can drift. Documents have no
# such runtime. A document's only "runtime" is an agent reading the working
# tree of the repo it stands in, and a doc that requires a cross-repo fetch
# before it governs is a doc that sometimes goes unread. So the agent-facing
# set (the manifest, docs/VENDORED.txt) must exist IN each governed repo's
# tree. Anyone tempted to "simplify" `.ceremony/` back to a pointer at
# heavy-duty/ceremony is reinventing the sometimes-unread doc. The mirror is
# the fix, and this tool is what makes the mirror safe: machine-written
# (--fix), machine-verified (--check, in the consumer's CI on every PR), so
# drift is unrepresentable — the only kind of copy the org allows.
#
# ONE PIN GOVERNS MACHINERY AND DOCTRINE. The ref is read from the
# consumer's .github/workflows/release.yml — the single
# `uses: heavy-duty/ceremony/.github/workflows/release.yml@<ref>` line —
# never from an input or a second config file: a second pin is a second
# thing to bump, and two pins can disagree, which is exactly the drift this
# tool exists to make unrepresentable. Exactly one such line must match;
# zero or several is a refusal that names the file — this tool never
# guesses a ref. Commented-out lines do not count: ceremony's own
# release.yml carries the pin shape inside its header essay, and any
# consumer that pastes a documentation snippet into a comment would
# otherwise appear to have two pins.
#
# THE MIRROR IS EXACT — manifest ∪ `.ceremony/`, nothing else. A drifted
# file, a missing file, an extra file not in the manifest, or no
# `.ceremony/` at all each fails --check with a message naming the offender
# and the fix; --fix writes AND deletes (a manifest removal must remove the
# vendored copy — mirror means mirror, or "extra" files accumulate as
# unverified doctrine).
#
# AND THE MIRROR IS PLAIN FILES. A symlink committed anywhere this tool
# touches — a vendored path, a subdirectory, `.ceremony/` itself, the root
# AGENTS.md — redirects the tool outside the mirror: cp writes THROUGH the
# link (anywhere the CI token can reach), cmp reads through it and reports
# the target's bytes as the mirror's, and a `find -type f` scan skips link
# nodes entirely, so the stray poses as doctrine while staying invisible
# (PR #43's review round, both findings reproduced). So both modes refuse
# any non-regular node before touching anything: the fix for a symlink is
# a human deleting it, never a tool following it.
#
# A THIRD FILE CLASS: THE GUARDED SCAFFOLD (#559). The mirror is a whole
# file ceremony owns; the root AGENTS.md stub is a whole file the consumer
# owns after the first write. `.github/pull_request_template.md` is neither,
# and it cannot become either. It cannot join the mirror — a pull request
# template only works at `.github/pull_request_template.md`, and `.ceremony/`
# is where GitHub never looks — and a stub lets a consumer's copy sit at the
# version it was scaffolded from forever, which is the measured defect:
# heavy-duty/crew's template was still ceremony 0.4.0's, fourteen releases
# behind, while the duty engine renders a `## Round log` shape that copy does
# not have. So ceremony owns a DELIMITED REGION of a file that otherwise
# belongs to the consumer: --fix writes the region and never a byte outside
# it, --check verifies the region at the mirror's severity, and everything
# above and below survives every future bump.
#
# THE MARKERS ARE WRITTEN BY --fix AND THE SOURCE FILE DOES NOT CARRY THEM.
# Putting them in ceremony's own template would push them into ceremony's own
# PR bodies and make the source's bytes and the block's bytes two different
# things to compare; writing them at install time keeps the comparison exact
# — extract the block, cmp against the source file, done. They are HTML
# comments, so they render as nothing.
#
# AND THE BOUNDARY IS FOUND BY COUNTING WHOLE LINES, NEVER BY A sed RANGE.
# `sed '/start/,/end/'` on a file whose end marker is missing matches to
# end-of-file, so the naive --fix deletes everything the consumer wrote below
# a truncated block. Unbalanced or duplicated markers are a REFUSAL in both
# modes — the block's boundaries are unknown, and repairing means guessing at
# which of the consumer's bytes are ours.
#
# TWO FILES ARE SPECIAL, both deliberately:
#   * `.ceremony/README.md` is GENERATED here — the machine-managed marker
#     plus where the pin lives — instead of per-file banners, so every
#     vendored file stays byte-identical to its source and the check is a
#     plain cmp, never a strip-the-banner parse. It is verified like
#     everything else (against the generated text, not the source tree):
#     the file that says "a hand edit goes red" must itself go red when
#     hand-edited, or the marker is the one unverified spot in the mirror.
#   * the consumer's ROOT AGENTS.md is scaffolded once by --fix and never
#     overwritten. Agent harnesses auto-load root AGENTS.md (the cross-agent
#     convention), so the stub is what makes "you are a reviewer here" a
#     sufficient launch prompt — but it is per-repo content the moment the
#     repo edits it, so --check asserts only that it exists.
#
# A file of its own so test/docs-sync.test.sh can drive both modes against
# constructed source and consumer trees. --source <dir> substitutes a local
# ceremony checkout for the tarball fetch: offline tests, and previewing a
# ceremony PR against a consumer before anything is released. The pin is
# still read and validated with --source — a consumer without its one pin
# line has nothing for the mirror to be verified against.

WORKFLOW=".github/workflows/release.yml"
MIRROR=".ceremony"
MANIFEST="docs/VENDORED.txt"
README_NAME="README.md"
SCAFFOLD_MANIFEST="docs/SCAFFOLDED.txt"

# One constant pair for every guarded scaffold, not one per path: a block
# sits alone in its own file, so the file already says which scaffold it is
# and the marker never has to. The literal is #559's, whose E2 fixes these
# bytes; a second manifest entry inherits them unchanged.
SCAFFOLD_START="<!-- ceremony:pr-template:start -->"
SCAFFOLD_END="<!-- ceremony:pr-template:end -->"

die() {
  printf '%s\n' "$@" >&2
  exit 1
}

# Inputs arrive as env vars from action.yml (MODE, SOURCE) or as flags for
# local and test use; flags win.
mode="${MODE:-check}"
source_dir="${SOURCE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --fix) mode=fix ;;
    --source)
      [ $# -ge 2 ] || die "docs-sync: --source needs a directory"
      source_dir="$2"
      shift
      ;;
    *) die "docs-sync: unknown argument: $1 (usage: docs-sync.sh [--check|--fix] [--source <dir>])" ;;
  esac
  shift
done
case "$mode" in
  check | fix) ;;
  *) die "docs-sync: unknown mode: '$mode' (check or fix)" ;;
esac

# --- the pin ----------------------------------------------------------------

[ -f "$WORKFLOW" ] || die \
  "docs-sync: no $WORKFLOW — the pin lives there (the single" \
  "  'uses: heavy-duty/ceremony/.github/workflows/release.yml@<ref>' line)." \
  "  Add the release caller before syncing doctrine: the mirror is verified" \
  "  against the pin, and without one there is nothing to verify against." \
  "  A repository that publishes no artifact still carries this caller:" \
  "  the pin lives here and the artifact hook is optional."

# A real `uses:` key only — a leading '#' anywhere before it is a comment
# and does not count (see the header: ceremony's own release.yml carries
# the shape in a comment).
mapfile -t pin_lines < <(grep -E \
  '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*heavy-duty/ceremony/\.github/workflows/release\.yml@' \
  "$WORKFLOW" || true)
case "${#pin_lines[@]}" in
  0)
    die "docs-sync: no pin line in $WORKFLOW — expected exactly one" \
      "  'uses: heavy-duty/ceremony/.github/workflows/release.yml@<ref>'," \
      "  found none. This tool never guesses a ref."
    ;;
  1) ;;
  *)
    die "docs-sync: ${#pin_lines[@]} pin lines in $WORKFLOW — exactly one" \
      "  'uses: heavy-duty/ceremony/.github/workflows/release.yml@<ref>' must" \
      "  match, or 'the pin' is ambiguous. This tool never guesses a ref."
    ;;
esac
ref="$(printf '%s\n' "${pin_lines[0]}" | sed -E 's/^.*@//; s/[[:space:]#].*$//')"
[ -n "$ref" ] || die "docs-sync: the pin line in $WORKFLOW carries an empty ref after '@'"

# --- the source tree ----------------------------------------------------------

fetch_tmp=""
# Block extraction compares whole files rather than shell variables: `$(…)`
# strips trailing newlines, which is the one byte a byte-identity check is
# most likely to differ by.
scratch=""
# An if, not `&&`: the trap's last status becomes the script's exit code,
# and a bare `[ -n ] && rm` returns 1 whenever there was nothing to clean —
# turning every --source success into a failure.
cleanup() {
  if [ -n "$fetch_tmp" ]; then rm -rf "$fetch_tmp"; fi
  if [ -n "$scratch" ]; then rm -rf "$scratch"; fi
}
trap cleanup EXIT
scratch="$(mktemp -d)"

if [ -n "$source_dir" ]; then
  [ -d "$source_dir" ] || die "docs-sync: --source: no such directory: $source_dir"
  src="$source_dir"
  origin="$source_dir (--source override; pin is heavy-duty/ceremony@$ref)"
else
  # The repo is public: a plain tarball fetch, no auth, no git. Works for a
  # tag, a branch, or a commit SHA alike.
  #
  # TWO STEPS, NEVER A PIPE (#393). `curl --retry … | tar -xz` can already
  # have written partial bytes into tar's stdin before curl re-sends, so a
  # mid-transfer retry corrupts the extraction instead of repairing it: the
  # naive form fixes the 503 that bought this rule and leaves a worse, rarer
  # fault behind. Download to a file, then extract the file.
  #
  # THE RETRY FLOOR. Four attempts spanning ~15 s of waiting — a bounded
  # guess at blip length, not a measurement. curl's retry-all-errors option
  # (named here without its leading dashes, so a grep for the flag stays
  # proof that it is not passed) is deliberately NOT used: it lands in curl
  # 7.71.0, and an older curl exits 2 on an unknown option, turning a
  # transient failure into a permanent one on EVERY run — strictly worse
  # than the fault being fixed. docs-sync runs on consumers' self-hosted
  # boxes and on developer laptops, not only on GitHub-hosted images, so the
  # version floor cannot be assumed. Plain --retry already covers this
  # incident's class (curl retries timeouts and HTTP 408, 429, 500, 502,
  # 503, 504) and --retry-connrefused lands in 7.52.0, effectively
  # universal. A 404 is not a transient code, so a bad pin still fails on
  # the first attempt.
  #
  # THE ARCHIVE AND THE TREE ARE DIFFERENT DIRECTORIES, so $src holds
  # exactly what a ceremony checkout holds on both paths and --source and
  # the fetch cannot diverge on a stray file. cleanup() removes $fetch_tmp
  # whole, so both go together.
  fetch_tmp="$(mktemp -d)"
  url="https://github.com/heavy-duty/ceremony/archive/${ref}.tar.gz"
  archive="$fetch_tmp/src.tar.gz"
  src="$fetch_tmp/src"
  mkdir -p "$src"

  # The status is captured, never inferred: %{http_code} into one variable,
  # curl's exit into another, and the branches below read both. %{http_code}
  # is 000 when no HTTP response arrived at all, which is what tells a
  # connection failure apart from a server that answered.
  fetch_rc=0
  http_code="$(curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused \
    -o "$archive" -w '%{http_code}' "$url")" || fetch_rc=$?

  # One diagnostic per fault class. The reader of these lines is usually a
  # bot deciding whether to re-run or escalate to a human, and one text for
  # every fault sent that reader to audit the tag, the mirror and the bump
  # twice in one afternoon for an upstream 503 (#393).
  if [ "$fetch_rc" -ne 0 ]; then
    case "$http_code" in
      404)
        die "docs-sync: heavy-duty/ceremony@$ref does not exist — HTTP 404 from" \
          "  $url. The pin in $WORKFLOW names a ref this repository does not" \
          "  have. Check the tag, or bump the pin to one that does."
        ;;
      5??)
        die "docs-sync: GitHub's archive endpoint returned HTTP $http_code for" \
          "  $url after 4 attempts. The pin is fine — heavy-duty/ceremony@$ref" \
          "  was never read. This is transient: re-run the job."
        ;;
      *)
        die "docs-sync: could not fetch $url —" \
          "  curl exit $fetch_rc, HTTP status $http_code. A network failure" \
          "  reaching GitHub, not a statement about the pin."
        ;;
    esac
  fi

  # A body that arrives and does not unpack is a fourth fault, not a fetch
  # failure: nothing above it is in doubt, so it says so on its own.
  tar -xzf "$archive" --strip-components=1 -C "$src" || die \
    "docs-sync: the archive for heavy-duty/ceremony@$ref" \
    "  downloaded but did not extract ($url) —" \
    "  a truncated or non-gzip body."

  origin="heavy-duty/ceremony@$ref"
fi

# --- the manifest -------------------------------------------------------------

# The manifest is read from the SOURCE tree, not the consumer: what gets
# mirrored is decided at the pinned ref, so bumping the pin onto a ref that
# adds or drops a doc re-shapes the mirror in the same PR, with no second
# list to update. It is also the single source of the set — nothing below
# hardcodes a filename.
manifest_file="$src/$MANIFEST"
[ -f "$manifest_file" ] || die \
  "docs-sync: no $MANIFEST in $origin — the manifest is the single source" \
  "  of what gets mirrored; a ref that predates it cannot govern a mirror." \
  "  Bump the pin to a ref that carries it."
mapfile -t manifest < <(grep -v '^[[:space:]]*$' "$manifest_file" || true)
[ "${#manifest[@]}" -gt 0 ] || die \
  "docs-sync: $MANIFEST in $origin is empty — an empty doctrine set is a" \
  "  ceremony bug, not a repo with no rules; refusing to mirror it."
for f in "${manifest[@]}"; do
  case "$f" in
    /* | *..*)
      die "docs-sync: refusing manifest path '$f' — the mirror writes only" \
        "  inside $MIRROR/, and that path escapes it."
      ;;
  esac
  [ -f "$src/$f" ] || die \
    "docs-sync: the manifest names '$f' but $origin has no such file —" \
    "  fix $MANIFEST in heavy-duty/ceremony."
done

in_manifest() {
  local p
  for p in "${manifest[@]}"; do
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

# --- the scaffold manifest ------------------------------------------------------

# Read from the SOURCE tree for the same reason the mirror's manifest is
# (see above): the set is decided at the pinned ref, so a bump that adds or
# drops a scaffold re-shapes it in the same PR, with no second list.
#
# A MISSING OR EMPTY FILE IS NO SCAFFOLDS, NOT A REFUSAL — unlike
# $MANIFEST, whose absence means the ref predates the mirror and cannot
# govern one. Every ref before #559 has no $SCAFFOLD_MANIFEST, and those
# refs govern working consumers today: dying here would turn this feature
# into a flag day for every repo pinned behind it.
scaffolds=()
scaffold_manifest_file="$src/$SCAFFOLD_MANIFEST"
if [ -f "$scaffold_manifest_file" ]; then
  mapfile -t scaffolds < <(grep -v '^[[:space:]]*$' "$scaffold_manifest_file" || true)
fi
if [ "${#scaffolds[@]}" -gt 0 ]; then
  for f in "${scaffolds[@]}"; do
    case "$f" in
      /* | *..*)
        die "docs-sync: refusing scaffold path '$f' — a guarded scaffold is" \
          "  written inside the consumer's own tree, and that path escapes it."
        ;;
    esac
    [ -f "$src/$f" ] || die \
      "docs-sync: $SCAFFOLD_MANIFEST names '$f' but $origin has no such file —" \
      "  fix $SCAFFOLD_MANIFEST in heavy-duty/ceremony."
    # The end marker is written on its own line directly after the source's
    # bytes, so a source file with no final newline would splice the marker
    # onto its last line and make the block unparseable the moment it is
    # written. Caught here, at the source, rather than in every consumer.
    if [ -s "$src/$f" ] && [ "$(tail -c 1 "$src/$f" | wc -l)" -eq 0 ]; then
      die "docs-sync: the scaffold source '$f' in $origin has no final newline," \
        "  so the end marker would land on its last line. Fix it in" \
        "  heavy-duty/ceremony."
    fi
  done
fi

# block_lines FILE — print '<status> <start> <end>' for FILE's one marked
# block. status is `ok` (with 1-based line numbers of the two marker lines),
# `none`, `unbalanced` or `duplicated`; the two numbers are 0 unless ok.
#
# grep -n -x -F: whole-line, fixed-string, line-numbered. Whole-line matching
# is what makes a marker mentioned INLINE in the consumer's own prose
# harmless — and only that. A marker on a line of its own is a marker
# wherever it sits, so a consumer who documents the pair on bare lines
# classifies as `duplicated` and is refused rather than guessed at. Counting
# the hits is what makes the unterminated case a refusal instead of a range
# that runs to end-of-file.
#
# -a IS LOAD-BEARING, not defensive. A single NUL byte anywhere in the
# consumer's file — a template once saved as UTF-16 is how one gets there —
# makes grep call it binary and print NO line numbers, so both counts come
# back 0 and the file classifies `none` however correct its block is. --fix
# would then append a second block, and a third, unbounded. The failure is
# silent AND unportable: GNU grep 3.11 warns on stderr at exit 0, ugrep 7.5
# exits 1 saying nothing at all. Downstream is already byte-safe — head,
# tail, cat and cmp are byte operations — so -a lets this function see the
# boundaries exactly rather than guess at them. That is why the answer here
# is -a and not a new refusal class: `duplicated` and `unbalanced` refuse
# because the boundary is genuinely unknown, and a NUL leaves it perfectly
# known.
block_lines() {
  local file="$1" starts ends ns ne
  starts="$(grep -a -n -x -F -e "$SCAFFOLD_START" "$file" | cut -d: -f1 || true)"
  ends="$(grep -a -n -x -F -e "$SCAFFOLD_END" "$file" | cut -d: -f1 || true)"
  ns="$(printf '%s' "$starts" | grep -c . || true)"
  ne="$(printf '%s' "$ends" | grep -c . || true)"

  if [ "$ns" -eq 0 ] && [ "$ne" -eq 0 ]; then
    printf 'none 0 0\n'
  elif [ "$ns" -gt 1 ] || [ "$ne" -gt 1 ]; then
    printf 'duplicated 0 0\n'
  elif [ "$ns" -eq 0 ] || [ "$ne" -eq 0 ]; then
    printf 'unbalanced 0 0\n'
  elif [ "$starts" -gt "$ends" ]; then
    printf 'unbalanced 0 0\n'
  else
    printf 'ok %s %s\n' "$starts" "$ends"
  fi
}

# block_current FILE START END SRCFILE — is the block's byte content exactly
# SRCFILE's? head|tail rather than a sed range: the line numbers are already
# known, and nothing here can run past the end marker.
block_current() {
  local file="$1" s="$2" e="$3" srcfile="$4" extracted rc=0
  extracted="$scratch/block"
  head -n "$((e - 1))" "$file" | tail -n +"$((s + 1))" >"$extracted"
  cmp -s "$extracted" "$srcfile" || rc=$?
  return "$rc"
}

# Every file physically present in the mirror, relative to it. sorted so
# messages come out in a stable order.
mirror_files() {
  find "$MIRROR" -type f | LC_ALL=C sort | while IFS= read -r path; do
    printf '%s\n' "${path#"$MIRROR"/}"
  done
}

# --- the two generated texts ---------------------------------------------------

readme_content() {
  cat <<'EOF'
# .ceremony/ — the vendored doctrine mirror

Machine-managed by heavy-duty/ceremony's `actions/docs-sync`. Never edit
these files here: they are byte-identical copies of
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony) at this
repository's pinned ref, and CI re-diffs them on every PR — a hand edit
goes red. They are changed in heavy-duty/ceremony, through its own flow —
[Requesting a doctrine change](https://github.com/heavy-duty/ceremony/blob/main/docs/CONSUMERS.md#requesting-a-doctrine-change)
— and arrive here when the pin moves.

**If a rule here is what is blocking you** — it cannot express your case, it
contradicts another, it names no mechanism — that flow is the way out, and
using it is not optional politeness: a workaround written locally instead
governs this repo while nobody upstream can see it. Open a
[discussion](https://github.com/heavy-duty/ceremony/discussions) quoting the
rule at this repo's pin, and cite that discussion wherever the local
workaround lives. The fix arrives the way every doctrine change arrives —
when the pin moves.

The pin lives in `.github/workflows/release.yml` — the single
`uses: heavy-duty/ceremony/.github/workflows/release.yml@<ref>` line. One
pin governs machinery and doctrine alike: bump it and re-sync this mirror
in the same PR (`docs-sync --fix`, or let the red check on the bump PR say
what is stale).
EOF
}

stub_content() {
  cat <<'EOF'
# AGENTS.md — start at .ceremony/

This repository is governed by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony). Read
`.ceremony/AGENTS.md` first — it routes you to your role file, vendored
beside it. Repo specifics (the review panel roster, the scope labels, what
a drill means here, code conventions) live in CONTRIBUTING.md.
EOF
}

# --- the mirror is plain files (see the header; PR #43's review round) ----------

# Refusals, not repairs, in BOTH modes — deliberately unlike drift, where
# --fix is the advertised cure: repairing a symlink means either deleting a
# node that points somewhere or writing through it, and a tool must do
# neither on its own. -L before -d/-f everywhere: the test that follows the
# link is exactly the bug.
guard_plain_tree() {
  local offenders
  if [ -L "$MIRROR" ]; then
    die "docs-sync: $MIRROR is a symlink, not a directory — a linked mirror" \
      "  redirects every write outside the tree this tool is allowed to" \
      "  touch. Refusing both modes: delete the symlink, then re-run" \
      "  docs-sync --fix."
  fi
  if [ -d "$MIRROR" ]; then
    offenders="$(find "$MIRROR" -mindepth 1 ! -type f ! -type d | LC_ALL=C sort)"
    [ -z "$offenders" ] || die \
      "docs-sync: non-regular node(s) in the mirror — a symlink (or fifo," \
      "  socket, …) under $MIRROR/ makes cp write and cmp read outside the" \
      "  mirror, and hides from the file scan. Refusing both modes; delete" \
      "  these by hand, then re-run docs-sync --fix:" \
      "$offenders"
  fi
  if [ -L AGENTS.md ]; then
    die "docs-sync: the root AGENTS.md is a symlink — the scaffold and the" \
      "  existence check must never resolve through a link (a dangling one" \
      "  would even make --fix write through it). Refusing both modes:" \
      "  replace the symlink with a regular file (or delete it and let" \
      "  docs-sync --fix scaffold the stub)."
  fi
  if [ -e AGENTS.md ] && [ ! -f AGENTS.md ]; then
    die "docs-sync: the root AGENTS.md exists but is not a regular file —" \
      "  nothing this tool could do to it is right. Refusing both modes:" \
      "  remove it, then re-run docs-sync --fix to scaffold the stub."
  fi

  # The same refusal for every guarded scaffold, and for the directories on
  # the way to it: --fix writes that path, so a symlink anywhere along it
  # sends the write outside the consumer's tree exactly as it would in the
  # mirror (PR #43's review round).
  if [ "${#scaffolds[@]}" -gt 0 ]; then
    local sf d
    for sf in "${scaffolds[@]}"; do
      if [ -L "$sf" ]; then
        die "docs-sync: the guarded scaffold $sf is a symlink — --fix would" \
          "  write the ceremony-owned block through it, anywhere the CI token" \
          "  can reach. Refusing both modes: replace the symlink with a" \
          "  regular file (or delete it and re-run docs-sync --fix)."
      fi
      if [ -e "$sf" ] && [ ! -f "$sf" ]; then
        die "docs-sync: $sf exists but is not a regular file — nothing this" \
          "  tool could do to it is right. Refusing both modes: remove it," \
          "  then re-run docs-sync --fix."
      fi
      d="$(dirname "$sf")"
      while [ "$d" != "." ] && [ "$d" != "/" ]; do
        if [ -L "$d" ]; then
          die "docs-sync: $d is a symlink, and the guarded scaffold $sf is" \
            "  written through it. Refusing both modes: replace the symlink" \
            "  with a real directory, then re-run docs-sync --fix."
        fi
        d="$(dirname "$d")"
      done
    done
  fi
}

# --- check ----------------------------------------------------------------------

run_check() {
  local failures=0 f rel
  complain() {
    printf '%s\n' "$@" >&2
    failures=$((failures + 1))
  }

  if [ ! -d "$MIRROR" ]; then
    complain "docs-sync: $MIRROR/ is missing entirely — this tree carries no" \
      "  doctrine mirror. Fix: run docs-sync --fix and commit the result."
  else
    for f in "${manifest[@]}"; do
      if [ ! -f "$MIRROR/$f" ]; then
        complain "docs-sync: $MIRROR/$f is missing from the mirror." \
          "  Fix: run docs-sync --fix."
      elif ! cmp -s "$src/$f" "$MIRROR/$f"; then
        complain "docs-sync: $MIRROR/$f has drifted from $origin." \
          "  Vendored files are never edited in place — they are changed in" \
          "  heavy-duty/ceremony, through its own flow. Fix: run docs-sync --fix" \
          "  (or re-run after bumping the pin, if the drift is a stale pin)."
      fi
    done
    while IFS= read -r rel; do
      [ "$rel" = "$README_NAME" ] && continue
      in_manifest "$rel" && continue
      complain "docs-sync: extra file in the mirror: $MIRROR/$rel — not in the" \
        "  manifest ($MANIFEST). The mirror is exact: everything under" \
        "  $MIRROR/ must be vendored and verified, or it poses as doctrine" \
        "  without being checked. Fix: run docs-sync --fix (it deletes orphans)."
    done < <(mirror_files)

    # The README is machine-written against generated text, so it is
    # machine-verified against the same text — the marker that warns "a hand
    # edit goes red" is not itself an unverified hole (kimi-bot, PR #43).
    if [ ! -f "$MIRROR/$README_NAME" ]; then
      complain "docs-sync: $MIRROR/$README_NAME is missing — the machine-managed" \
        "  marker is part of the mirror. Fix: run docs-sync --fix."
    elif ! readme_content | cmp -s - "$MIRROR/$README_NAME"; then
      complain "docs-sync: $MIRROR/$README_NAME has drifted from its generated" \
        "  content — the README is machine-written, and a hand edit here is" \
        "  exactly what its own text warns against. Fix: run docs-sync --fix."
    fi
  fi

  # Existence only, content free: the stub is per-repo the moment the repo
  # edits it (see the header).
  [ -f AGENTS.md ] || complain \
    "docs-sync: no root AGENTS.md — the stub that routes agents into" \
    "  $MIRROR/ is missing, so 'you are a reviewer here' has no entry point." \
    "  Fix: run docs-sync --fix (scaffolds it once; edit it freely after)."

  # The guarded scaffolds, at the mirror's severity and for the mirror's
  # reason: a check nobody's CI fails on is the sometimes-unread doc again.
  local status bs be
  if [ "${#scaffolds[@]}" -gt 0 ]; then
    for f in "${scaffolds[@]}"; do
      if [ ! -f "$f" ]; then
        complain "docs-sync: $f is missing — ceremony owns a marked block in" \
          "  that file at $origin, and this tree has no file to carry it." \
          "  Fix: run docs-sync --fix and commit the result."
        continue
      fi
      read -r status bs be < <(block_lines "$f")
      case "$status" in
        none)
          complain "docs-sync: $f carries no ceremony-owned block — no" \
            "  '$SCAFFOLD_START' line. The rest of the file is yours; the" \
            "  block is ceremony's, at $origin. Fix: run docs-sync --fix" \
            "  (it appends the block and leaves your content alone)."
          ;;
        duplicated)
          complain "docs-sync: $f carries more than one ceremony marker line," \
            "  so which bytes are ceremony's is ambiguous and --fix will not" \
            "  guess. Leave exactly one '$SCAFFOLD_START' and one" \
            "  '$SCAFFOLD_END' by hand, then run docs-sync --fix" \
            "  ($origin)."
          ;;
        unbalanced)
          complain "docs-sync: $f has unbalanced ceremony markers — a" \
            "  '$SCAFFOLD_START' without its '$SCAFFOLD_END' after it. The" \
            "  block has no end, so --fix will not guess where your content" \
            "  resumes. Close the block by hand, then run docs-sync --fix" \
            "  ($origin)."
          ;;
        ok)
          if ! block_current "$f" "$bs" "$be" "$src/$f"; then
            complain "docs-sync: the ceremony-owned block in $f has drifted" \
              "  from $origin. That block is machine-written and is never" \
              "  edited in place — it is changed in heavy-duty/ceremony," \
              "  through its own flow. Fix: run docs-sync --fix (or re-run" \
              "  after bumping the pin, if the drift is a stale pin)."
          fi
          ;;
      esac
    done
  fi

  [ "$failures" -eq 0 ] || die "docs-sync: $failures problem(s) — see above."
  echo "docs-sync: $MIRROR/ is an exact mirror of $origin (${#manifest[@]} files)"
  if [ "${#scaffolds[@]}" -gt 0 ]; then
    echo "docs-sync: ${#scaffolds[@]} guarded scaffold(s) carry a current ceremony-owned block"
  fi
}

# --- fix ------------------------------------------------------------------------

run_fix() {
  local changed=0 scaf_changed=0 total f rel dest
  note() {
    printf 'docs-sync: %s\n' "$1"
    changed=$((changed + 1))
  }
  # Scaffold work is counted apart from the mirror's because it lands
  # outside $MIRROR/ entirely, and the closing line below reports where the
  # changes went — a scaffold-only run used to sign off by naming a
  # directory it had not touched.
  note_scaffold() {
    printf 'docs-sync: %s\n' "$1"
    scaf_changed=$((scaf_changed + 1))
  }

  mkdir -p "$MIRROR"
  for f in "${manifest[@]}"; do
    dest="$MIRROR/$f"
    if [ ! -f "$dest" ]; then
      mkdir -p "$(dirname "$dest")"
      cp "$src/$f" "$dest"
      note "added $dest"
    elif ! cmp -s "$src/$f" "$dest"; then
      cp "$src/$f" "$dest"
      note "updated $dest"
    fi
  done

  while IFS= read -r rel; do
    [ "$rel" = "$README_NAME" ] && continue
    in_manifest "$rel" && continue
    rm "$MIRROR/$rel"
    note "deleted $MIRROR/$rel (not in the manifest — mirror means mirror)"
  done < <(mirror_files)
  find "$MIRROR" -mindepth 1 -type d -empty -delete

  if [ ! -f "$MIRROR/$README_NAME" ] || ! readme_content | cmp -s - "$MIRROR/$README_NAME"; then
    readme_content >"$MIRROR/$README_NAME"
    note "wrote $MIRROR/$README_NAME"
  fi

  if [ ! -e AGENTS.md ]; then
    stub_content >AGENTS.md
    note "created the root AGENTS.md stub (scaffolded once, never overwritten)"
  fi

  local status bs be srcfile rebuilt
  if [ "${#scaffolds[@]}" -gt 0 ]; then
    for f in "${scaffolds[@]}"; do
      srcfile="$src/$f"
      if [ ! -e "$f" ]; then
        mkdir -p "$(dirname "$f")"
        {
          printf '%s\n' "$SCAFFOLD_START"
          cat "$srcfile"
          printf '%s\n' "$SCAFFOLD_END"
        } >"$f"
        note_scaffold "created $f carrying the ceremony-owned block"
        continue
      fi
      read -r status bs be < <(block_lines "$f")
      case "$status" in
        none)
          # APPEND, never overwrite: an existing hand-maintained template is
          # content, not garbage. The newline is added only when the file
          # does not already end in one, so the consumer's bytes stay a
          # strict prefix of the result either way.
          if [ -s "$f" ] && [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then
            printf '\n' >>"$f"
          fi
          {
            printf '%s\n' "$SCAFFOLD_START"
            cat "$srcfile"
            printf '%s\n' "$SCAFFOLD_END"
          } >>"$f"
          note_scaffold "appended the ceremony-owned block to $f (its existing content is untouched)"
          ;;
        duplicated | unbalanced)
          # A refusal, not a repair — the same call guard_plain_tree makes
          # about a symlink, and for the same reason: the boundaries are
          # unknown, so every repair guesses at which of the consumer's
          # bytes are ceremony's. This is the branch a sed range would have
          # answered by deleting the rest of the file.
          die "docs-sync: cannot fix $f — its ceremony markers are $status," \
            "  so where the block ends is unknown and every repair would" \
            "  guess at which of your bytes are ours. --fix refuses rather" \
            "  than delete content below a broken marker. Leave exactly one" \
            "  '$SCAFFOLD_START' line and one '$SCAFFOLD_END' line after it," \
            "  then re-run docs-sync --fix."
          ;;
        ok)
          if ! block_current "$f" "$bs" "$be" "$srcfile"; then
            # head -n / tail -n +N reproduce the outside regions byte for
            # byte, including a final line with no newline: the block is
            # replaced and nothing else in the file is even read as text.
            rebuilt="$scratch/rebuilt"
            head -n "$((bs - 1))" "$f" >"$rebuilt"
            {
              printf '%s\n' "$SCAFFOLD_START"
              cat "$srcfile"
              printf '%s\n' "$SCAFFOLD_END"
            } >>"$rebuilt"
            tail -n +"$((be + 1))" "$f" >>"$rebuilt"
            cat "$rebuilt" >"$f"
            note_scaffold "updated the ceremony-owned block in $f (bytes outside the markers untouched)"
          fi
          ;;
      esac
    done
  fi

  # Where the changes landed, not just how many. The middle branch is the
  # sentence this line has always printed, and every run with no guarded
  # scaffold work takes it — so no ref before #559, and no consumer whose
  # pin predates the scaffold class, sees this output move at all.
  total=$((changed + scaf_changed))
  if [ "$total" -eq 0 ]; then
    echo "docs-sync: nothing to do — $MIRROR/ already mirrors $origin exactly"
  elif [ "$scaf_changed" -eq 0 ]; then
    echo "docs-sync: $total change(s); $MIRROR/ now mirrors $origin exactly"
  else
    echo "docs-sync: $total change(s) — $changed in $MIRROR/, $scaf_changed guarded scaffold(s); $MIRROR/ now mirrors $origin exactly"
  fi
}

guard_plain_tree
case "$mode" in
  check) run_check ;;
  fix) run_fix ;;
esac
