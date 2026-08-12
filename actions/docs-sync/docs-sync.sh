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
  "  against the pin, and without one there is nothing to verify against."

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
# An if, not `&&`: the trap's last status becomes the script's exit code,
# and a bare `[ -n ] && rm` returns 1 whenever there was nothing to clean —
# turning every --source success into a failure.
cleanup() { if [ -n "$fetch_tmp" ]; then rm -rf "$fetch_tmp"; fi; }
trap cleanup EXIT

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
goes red. They are changed in heavy-duty/ceremony, through its own flow,
and arrive here when the pin moves.

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

  [ "$failures" -eq 0 ] || die "docs-sync: $failures problem(s) — see above."
  echo "docs-sync: $MIRROR/ is an exact mirror of $origin (${#manifest[@]} files)"
}

# --- fix ------------------------------------------------------------------------

run_fix() {
  local changed=0 f rel dest
  note() {
    printf 'docs-sync: %s\n' "$1"
    changed=$((changed + 1))
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

  if [ "$changed" -eq 0 ]; then
    echo "docs-sync: nothing to do — $MIRROR/ already mirrors $origin exactly"
  else
    echo "docs-sync: $changed change(s); $MIRROR/ now mirrors $origin exactly"
  fi
}

guard_plain_tree
case "$mode" in
  check) run_check ;;
  fix) run_fix ;;
esac
