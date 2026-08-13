#!/usr/bin/env bash
set -euo pipefail

# runner-isolated.sh [<workflows-dir> [<pr-code-runner-labels>]] — assert
# that no workflow file which EXECUTES PR-AUTHORED CODE names a self-hosted
# runner label the consumer has not vouched for (#58; epic #56 decision D5;
# the axis corrected and the allowlist added in #395).
#
# The threat, stated once: a `pull_request` workflow runs code from the
# PR's branch. When that branch comes from a fork and the repo's fork-PR
# settings do not require approval, that code is UNREVIEWED. Point such a
# job at a self-hosted runner and unreviewed code executes on our own
# hardware, inside our own network. Nothing else in the fleet's setup
# gates that path — the write-token and secrets toggles (correctly off,
# #16's ruling) protect credentials, not the runner.
#
# Nothing was wrong the day this was written: incubator's deploy.yml is
# push-triggered and self-hosted (legal), its pr-checks.yml is
# PR-triggered and hosted, and the rule lived as a sentence in
# pr-checks.yml's header, kept true by whoever remembered it. This guard
# is that sentence moved into CI — the same move drill-recorded made
# after three releases shipped through a documented-but-unenforced gate
# (its header: "that is not a gate, it is luck with good manners").
#
# THE AXIS: "DOES THIS FILE EXECUTE PR CODE", NOT "IS IT PR-TRIGGERED"
# (#395). The first version asked whether the trigger block named
# pull_request. That question comes apart from the one it means to ask
# exactly where it matters: `pull_request_target` plus an explicit
# checkout of the PR head is base-branch privileges running PR-authored
# code — the most dangerous shape in the trigger surface — and it passed,
# while a `pull_request_target` caller with no checkout at all was
# blocked for naming a label. So the verdict is now:
#
#   pull_request        -> executes PR code. Unconditionally, no checkout
#                          inspection: the trigger implies the context,
#                          and a false positive here is cheaper than a
#                          false negative (#395 decision 3).
#   pull_request_target -> executes NO PR code, UNLESS the file checks out
#                          a PR ref (#395 decision 4).
#   anything else       -> executes no PR code; the runner half alone was
#                          never the offence.
#
# TWO AXES, ONE INPUT. Whether a runner tier is isolated cannot be read
# off a workflow file, so it stays the consumer's assertion:
# `pr-code-runner-labels` names the labels on which PR-authored code may
# execute. Whether a file checks out a PR ref CAN be read off the file,
# so it must not be asserted — every avoidable assertion is a place the
# guard can be told something false (#395). The input is named for the
# assertion and not for the tier because the TRUSTED tier is precisely
# the one that must never appear in it (the misreading that sank #389).
#
# A `runs-on:` label set is a CONJUNCTION — a runner must carry every
# label named — so a spec is vouched for when ANY of its labels is
# vouched: adding labels only narrows the matching runners, and every
# runner matching `[self-hosted, pr-runner]` is in the pr-runner tier.
# The empty allowlist therefore vouches nothing and reproduces the
# pre-#395 verdict on every PR-code file (#395 decision 8).
#
# THE UNIT OF THAT ARGUMENT IS A VALUE, NOT A LINE (#395 round 2). One
# line can name two runners — `with: {a: '["self-hosted","pr-runner"]',
# b: '["self-hosted","ci-runner"]'}` is two reusable-workflow inputs and
# two tiers — and reading it as one set made the vouched input vouch for
# the unvouched one, because a set is vouched when any member is. Each
# value of an inline flow mapping is therefore its own spec, judged on
# its own labels; a fragment that is not a mapping is one value, so
# `[self-hosted, ci-runner]` stays the single conjunction it is. One
# line reports as many specs as it carries, which is also why a line
# matching several shapes at once still reports once: the fragment is
# chosen once, and there is one place that records it.
#
# AND THE UNIT IS NOT BOUNDED BY THE LINE EITHER (#395 round 3). A flow
# collection may open on one line and close on another, and a `runs-on:`
# may sit inside a mapping that opened before it — so the fragment is
# the COLLECTION, taken from its own `{` and read on until its own
# bracket closes it, rather than the tail of a line. Both halves were
# fail-OPEN: a sibling key's scalar vouching for a `runs-on:` value it
# is no part of, and a `with: {` alone on a line losing every value
# below it in silence. The machine is at flow_feed below.
#
# THE RULE IS FILE-LEVEL, DELIBERATELY. The precise rule — no JOB
# reachable from a PR-code trigger runs self-hosted — needs a YAML
# parser, and a second parser in bash is a new class of guard bug bought
# in exchange for permitting a file shape we do not want. So: a file
# FAILS when it derives as executing PR code AND it names an unvouched
# self-hosted runner anywhere, even in a different job. The false
# positive has a clean, safer fix — SPLIT THE WORKFLOW; incubator already
# keeps pr-checks.yml apart from deploy.yml, which is the shape this
# guard asks for. False NEGATIVES are what a security guard must not
# have, and file-level granularity has none for the modelled threat: it
# can only be stricter than the precise rule, never laxer.
#
# Self-hosted detection covers three shapes. The same-line rule alone
# ("runs-on and self-hosted on one line") would pass the block-sequence
# form — a false negative, the one defect this guard is not allowed to
# have — and reading `runs-on:` alone misses the label a caller passes
# through an INPUT, which is what #383's `runner:` made routine and
# heavy-duty/incubator#144 shipped (#395 decision 5):
#
#     runs-on: [self-hosted, ci-runner]      # same line: caught
#     runs-on:                               # block sequence: the bare
#       - self-hosted                        #   key opens a window over
#       - ci-runner                          #   its `- …` list items
#     with:                                  # input value: the window a
#       runner: '["self-hosted","ci-runner"]'#   bare `with:` opens over
#                                            #   its more-indented block
#     with:                                  # …and an input value may
#       runner:                              #   itself be a block
#         - self-hosted                      #   sequence, accumulated
#         - ci-runner                        #   as one spec like above
#     with: {                                # …and a flow collection may
#       safe: '["self-hosted","pr-runner"]', #   SPAN LINES: it is read on
#       hot:  '["self-hosted","ci-runner"]'  #   until its own bracket
#     }                                      #   closes it, one spec per
#                                            #   value (#395 round 3)
#     with: {                                # …and so may one VALUE: a
#       hot: '["self-hosted",                #   quoted scalar is opaque,
#         "ci-runner"]' }                    #   so a bracket inside it
#                                            #   is text and not the
#                                            #   collection's end, and
#                                            #   the values after it are
#                                            #   not lost (#395 round 4)
#     with:                                  # …and a value may be a
#       runner: |                            #   BLOCK SCALAR: its text
#         ["self-hosted","ci-runner"]        #   reaches the callee like
#                                            #   any other, so the block
#                                            #   is one spec, closed at
#                                            #   the key's own indent
#                                            #   (#395 round 4)
#     with: {                                # …and a COMMENT is none of
#       note: plain, # } closes nothing      #   those: it ends with its
#       hot: '["self-hosted","ci-runner"]' } #   line and closes nothing,
#                                            #   so the values below it
#                                            #   are still read (#395
#                                            #   round 5)
#     with: {# } closes nothing              # …and it may begin right
#       hot: '["self-hosted","ci-runner"]'}  #   after a flow indicator or
#                                            #   a quoted scalar's close,
#                                            #   not only after a space
#                                            #   (#395 round 6)
#     runs-on:                               # …and a bare key's value may
#       [self-hosted, ci-runner]             #   be a FLOW COLLECTION on
#                                            #   the next line instead of
#                                            #   a `- …` list — the same
#                                            #   value, written the other
#                                            #   way (#395 round 8)
#     env:                                   # …and it may be an ALIAS,
#       R: &r '["self-hosted","ci-runner"]'  #   which reaches the callee
#     with:                                  #   as its ANCHOR'S value and
#       runner: *r                           #   is read as one (#395
#                                            #   round 8)
#     jobs: {build: {runs-on: [self-hosted], # A key BESIDE a spec never
#       environment: pr-runner}}             #   joins it, however many
#                                            #   brackets are between —
#                                            #   the split follows the
#                                            #   innermost collection's
#                                            #   kind (#395 round 4)
#
# A `with:` value is judged identically to a `runs-on:` value, and only
# AFTER the trigger axis has decided whether the file executes PR code at
# all — which is why incubator's three callers, all `with:`-passing
# `["self-hosted","ci-runner"]` and none of them executing PR code, need
# no allowlist entry (#395 decision 6, and test/runner-isolated.test.sh
# carries them verbatim as the regression fixture).
#
# PR-REF CHECKOUT DETECTION is deliberately loose in the SAFE direction:
# any non-comment line carrying a `ref:` key together with
# `github.event.pull_request` (which covers `.head.sha` and `.head.ref`),
# `github.head_ref`, or a `refs/pull/` path — the last one because the
# same checkout is routinely spelled `refs/pull/${{ github.event.number
# }}/merge`, whose expression names neither of the other two, and it
# catches a hardcoded `refs/pull/N/head` besides. It is not tied to a
# recognised checkout step, because binding it to `uses:
# actions/checkout` is the YAML-parsing problem again and every miss
# there is a false NEGATIVE on the one row this change exists to close.
# Over-reading a `ref:` line can only make a file derive as executing PR
# code — never permit one.
#
# KNOWN LIMITS, named in action.yml's description too so a consumer
# never reads silence as coverage:
#   - workflow_call reachability is still not followed across FILES: a
#     PR-code caller `uses:`-ing a callee that names self-hosted in its
#     own `runs-on` goes unseen. What #395 closed is the label passed
#     through `with:`, which is the shape the fleet actually uses.
#   - a PR head fetched by hand — `git fetch origin pull/N/head` in a
#     `run:` block — is not a `ref:` key and is not detected.
#   - any trigger whose name contains `pull_request` (for example
#     `pull_request_review`) reads as `pull_request` and derives as
#     executing PR code. Pre-#395 behaviour, kept: conservative.
#   - indirection is not resolved: a runner GROUP names its hardware
#     elsewhere, and a matrix or expression value is decided at run time,
#     so either can reach self-hosted hardware without the string
#     appearing on any line this guard reads.
#   - a `with:` input's value is read as runner labels WHATEVER THE KEY
#     is called, the guard having no way to tell `runner:` from `body:`
#     or `script:`, so prose passed to a reusable workflow by a PR-code
#     file is reported as a label set. RULED, not pending: the key axis
#     is unbounded because the CALLEE names its own inputs and this
#     guard never opens that file, so a name allowlist is a false
#     negative whose size somebody else's naming sets; and a whole-item
#     value test would drop a real spec embedded in a longer string
#     (`args: --runner self-hosted --fast`) to the same probe that
#     reports prose. Measured across the fleet's 36 workflow files the
#     day it was ruled: every prose `self-hosted` sits on a comment line
#     this guard skips, and every `with:`-passed one is a real spec — no
#     live false positive was bought. Reopens on one real consumer file,
#     as a bug with that file measured (#395 decision 5; discussion #403,
#     ruled 2026-08-13).
#   - an ALIAS is resolved only from an anchor THIS FILE defines above
#     it, and an anchor is recorded from the line it heads: a value
#     spanning further lines — a block scalar, or a collection opening
#     on the anchor's line and closing below — is recorded as far as
#     that line goes. An unresolved alias is left as written and reads
#     as no label at all, which is the one direction that can fail open,
#     so it is named here rather than left to silence (#395 round 8).
#   - …and one gap where the string IS on a line it reads, one being all
#     that is left of the two round 8 found: `runs-on:` in its
#     BLOCK-MAPPING form — `group:` and `labels:` keys beneath the key
#     rather than a value beside it — selects no fragment, so `runs-on:`
#     + `labels: [self-hosted, …]` underneath goes unseen. The inline
#     spelling of the same mapping is read. Documented GitHub syntax,
#     unread before #395 as much as after it, and out of #395 by
#     decision 9 (#395 round 5, claude-bot's nit; discussion #401). The
#     other one — a FLOW COLLECTION opening on the line after its key —
#     is read as of round 8 and no longer belongs on this list.
#
# COMMENTS ARE NOT CONTENT, and the rule is one sentence with one
# exception. A workflow that merely mentions self-hosted in prose is not
# the bug — incubator's pr-checks.yml header is exactly that prose, and a
# guard that cried wolf on comments would be turned off within a week —
# so a comment line is skipped, and an inline comment ends its line's
# text for every window that reads one: the flow scanner, which leaves
# the collection OPEN because a comment closes nothing, and the
# block-sequence window, whose item is a value and not a note about one.
# Both windows apply ONE implementation of that rule (no_comment, and
# flow_feed character by character where it also carries quote state);
# stating it once and implementing it twice made the two spellings of a
# label set disagree (#395 round 6, claude-bot's nit 2).
#
# WHERE a `#` is content is a property of SCALARS. It is content only
# where it CONTINUES A PLAIN SCALAR — so `ci#runner` is one label, and
# `{a:#b}` is the single scalar `a:#b` rather than a key and a comment —
# or where it sits inside a quoted one, which is text like everything
# else there. Everywhere else it opens a comment: after separation
# whitespace, after a flow indicator (`{`, `[`, `,`, `]`, `}`), and after
# a quoted scalar's own closing quote. Asking only about whitespace left
# `with: {# } closes nothing` — and its comma, bracket and quote
# spellings — feeding a comment's `}` to the scanner, which popped the
# collection and lost the runner value below it (#395 round 6, codex-bot
# blocking).
#
# AND AN INDICATOR IS ONLY AN INDICATOR IN FLOW CONTEXT, which is that
# same sentence read the other way. A plain scalar cannot contain a `,`
# inside a flow collection — that is WHY the rule above holds — but in
# BLOCK context it can, so `- a,#self-hosted` is one label named
# `a,#self-hosted`, and cutting it at that `,#` dropped the tail and
# passed the file. Both windows therefore carry the open bracket kinds,
# and both keep the whitespace and quote-close arms unconditional; a
# closing `]` or `}` counts as an indicator even where it returns the
# depth to zero, being the collection's own (#395 round 8, claude-bot's
# nit).
#
# The exception is the BLOCK SCALAR, whose lines are literal text the
# callee receives verbatim: there a `#` opens nothing and a label written
# behind one is a label this file passes (#395 round 5).
#
# A missing workflows directory is a PASS, not an error — most repos in
# the family have one, but a guard that fails on absence is a guard
# nobody adopts.
#
# A file of its own (not inlined in action.yml) so
# test/runner-isolated.test.sh can drive it against constructed trees —
# the same discipline as the four guards beside it.

workflows_dir="${1:-${WORKFLOWS_DIR:-.github/workflows}}"
allowlist_raw="${2:-${PR_CODE_RUNNER_LABELS:-}}"

# The consumer's assertion, comma-separated. Newlines are accepted too, so
# a YAML block scalar in a caller is not a silent misparse.
allowed=()
while IFS= read -r allow_label; do
  allow_label="${allow_label#"${allow_label%%[![:space:]]*}"}"
  allow_label="${allow_label%"${allow_label##*[![:space:]]}"}"
  allow_label="${allow_label#[\"\']}"
  allow_label="${allow_label%[\"\']}"
  if [ -n "$allow_label" ]; then
    allowed+=("$allow_label")
  fi
done <<<"${allowlist_raw//,/$'\n'}"

if [ "${#allowed[@]}" -gt 0 ]; then
  allowlist_shown="$(printf '%s, ' "${allowed[@]}")"
  allowlist_shown="${allowlist_shown%, }"
else
  allowlist_shown="empty — no label is vouched for"
fi

# labels_in <value> — the runner labels a `runs-on:` or input value names,
# comma-separated on one line. JSON, YAML flow lists, block-sequence items
# and bare scalars reduce to the same thing: brackets, braces, quotes and
# the item dash are punctuation. A `key:` prefix goes too, because the
# inline flow-mapping form (`with: {runner: …}`) carries one INSIDE the
# value — and a label parsed as `runner: self-hosted` matches no allowlist
# entry, which fails safe but refuses a consumer who vouched correctly.
# The prefixes are stripped to a FIXED POINT: a value taken from a nested
# mapping carries one per level (`build: runs-on: self-hosted`), and one
# strip left the message naming something that is not a label at all
# (#395 round 4, claude-bot's nit 2).
#
# An ANCHOR goes the same way, for the same reason: `runs-on: &r
# [self-hosted, ci-runner]` names two labels and no runner carries `&r`,
# so a message quoting it names something the consumer cannot vouch for
# even in principle (#395 round 8).
#
# It takes a VALUE and not a line, so it does not remove comments: the
# caller that reads a line removes that line's own comment (no_comment
# below), and a value reaching here from the flow scanner never carries
# one, that scanner having dropped it as it read. Trimming here as well
# cut a quoted `#` out of a label the file really names, because the
# accumulated value of a collection is not a line and has no tail to
# trim (#395 round 5).
labels_in() {
  local value="$1"
  printf '%s' "$value" \
    | tr -d "\"'[]{}" \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*-*[[:space:]]*//' \
          -e 's/^&[A-Za-z0-9_-]*[[:space:]]*//' \
          -e ':k' -e 's/^[A-Za-z0-9_-]*:[[:space:]]*//' -e 'tk' \
          -e 's/[[:space:]]*$//' \
    | grep -v '^$' \
    | paste -sd, - || true
}

# no_comment <line> — a physical line without its trailing YAML comment,
# for the window that reads a value a LINE at a time: a block sequence's
# `- …` items. There the comment is the line's own tail, and it is not
# part of the value or of the runner probe — a `- ubuntu-latest # never
# self-hosted` item filed a spec for the word in its note (#395 round 5,
# codex-bot's converse in the block-sequence arm). A whole comment LINE is
# skipped before this is ever reached.
#
# IT IS flow_feed'S RULE, ON A LINE INSTEAD OF A COLLECTION, and it has to
# be: a rule stated once and implemented twice is two rules, and the two
# disagreed. Round 5 trimmed here at the first whitespace-`#`, quotes and
# all, so `- "pr #runner"` lost the label its inline spelling keeps and
# `- ['ci # tier', self-hosted]` under a `with:` key lost its self-hosted
# altogether — a fail-open round 5 introduced, and the sentence in the
# header claiming this rule sees a quote was true of the flow scanner
# only (#395 round 6, claude-bot's nit 2). So: a quote OPENS only where a
# scalar can start, escaping is honoured inside it, and a `#` ends the
# text only outside a quote and only where it does not continue a plain
# scalar — after whitespace, after a flow indicator, after a quoted
# scalar's close, or at the start.
#
# A block SCALAR is deliberately not passed through this: `#` inside one
# is literal text that reaches the callee, so a `self-hosted` there is a
# label the file really passes, and dropping it would be the fail-open
# shape d exists to close.
no_comment() {
  local text="$1" i=0 cut=-1 ch prev quote="" fresh=1 qend=0 was_qend=0
  local kinds="" ind=0 was_ind=0
  while [ "$i" -lt "${#text}" ]; do
    ch="${text:i:1}"
    prev=""
    if [ "$i" -gt 0 ]; then
      prev="${text:i-1:1}"
    fi
    was_qend="$qend"
    qend=0
    was_ind="$ind"
    ind=0
    i=$((i + 1))
    if [ -n "$quote" ]; then
      if [ "$quote" = '"' ] && [ "$ch" = "\\" ] && [ "$i" -lt "${#text}" ]; then
        i=$((i + 1))
        continue
      fi
      if [ "$ch" = "$quote" ]; then
        if [ "$quote" = "'" ] && [ "${text:i:1}" = "'" ]; then
          i=$((i + 1))
          continue
        fi
        quote=""
        qend=1
      fi
      continue
    fi
    # A FLOW INDICATOR IS ONLY AN INDICATOR IN FLOW CONTEXT, which is why
    # the bracket kinds are carried here as well and not just in
    # flow_feed. A `,` is illegal inside a flow-context plain scalar and
    # so ends one — but a BLOCK-context plain scalar may contain it, so
    # `- a,#self-hosted` is the single label `a,#self-hosted` and not a
    # value with a note after it. Cutting there dropped the tail and
    # passed the file: this window's own fail-open, the same class as the
    # one round 6 closed, and reported as a nit rather than found by the
    # suite (#395 round 8, claude-bot's nit). A closing `]` or `}` stays
    # an indicator even as it returns the depth to zero — it is the
    # collection's own — so `- [a]#b` still comments.
    if [ "$ch" = '#' ] && [ -n "$prev" ]; then
      if [ "$was_qend" -eq 1 ] || [ "$was_ind" -eq 1 ]; then
        cut=$((i - 1))
        break
      fi
      case "$prev" in
        ' ' | '	')
          cut=$((i - 1))
          break
          ;;
      esac
    fi
    case "$ch" in
      '"' | "'")
        if [ "$fresh" -eq 1 ]; then
          quote="$ch"
        fi
        fresh=0
        ;;
      '[' | '{')
        kinds="$kinds$ch"
        ind=1
        fresh=1
        ;;
      ']' | '}')
        if [ -n "$kinds" ]; then
          kinds="${kinds%?}"
          ind=1
        fi
        fresh=0
        ;;
      ',')
        if [ -n "$kinds" ]; then
          ind=1
        fi
        fresh=1
        ;;
      ':') fresh=1 ;;
      ' ' | '	') ;;
      # A LEADING `- ` is the sequence item's own indicator and not a
      # character of its value, so a scalar may start after it — which is
      # the one position flow_feed has no equivalent of, a fragment never
      # beginning with an item dash. Only the leading one: the `-` inside
      # `ubuntu-don't` is plain-scalar text, and treating it as an
      # indicator would let that apostrophe open a quote.
      '-')
        fresh=0
        if [ "$i" -eq 1 ]; then
          case "${text:i:1}" in
            ' ' | '	' | '') fresh=1 ;;
          esac
        fi
        ;;
      *) fresh=0 ;;
    esac
  done
  if [ "$cut" -lt 0 ]; then
    printf '%s' "$text"
    return
  fi
  text="${text:0:cut}"
  # The comment's own separating whitespace goes with it, as the tail-trim
  # this replaced dropped it: a value's trailing space is nobody's label.
  printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# AN ALIAS IS ITS ANCHOR'S VALUE, AND THE GUARD MUST READ IT AS ONE.
# GitHub Actions accepts YAML anchors and aliases, so
#
#     env:
#       RUNNER_INPUT: &runner-input '["self-hosted","ci-runner"]'
#     jobs:
#       call:
#         uses: …
#         with:
#           runner: *runner-input
#
# passes `["self-hosted","ci-runner"]` to the callee exactly as writing it
# out would. The `with:` window saw the token `*runner-input`, whose text
# names no runner, while the anchored value sat outside every window —
# exit 0 with an empty allowlist, a fail-open on PR-authored code and
# against the criterion decision 5 exists for (#395 round 8, codex-bot
# blocking).
#
# So anchors are recorded as the file is read and aliases are resolved
# before a value is judged. Resolution happens where the VALUE is chosen
# — at frag_start and on each line fed to an open collection — and
# deliberately not at flush: expanding a whole accumulated collection
# would merge `{runner: *a, hot: *b}` into one spec, and a set is vouched
# when any member is, which is round 2's mis-vouch bought back.
#
# A document's anchors are its own, so the table is cleared per file. An
# anchor must be DEFINED BEFORE the alias that uses it — YAML requires
# it, and one pass over the lines gets it for free.
alias_names=()
alias_values=()

# anchor_record <line> — an `&name` heading a VALUE, with the rest of its
# line as that value. Only at the head of a value (`KEY: &name …`, or a
# sequence item's `- &name …`), because a bare `&` elsewhere on a line is
# ordinarily not an anchor at all — `run: a && b` is the routine case,
# and reading one there would let a shell fragment answer to an alias.
anchor_record() {
  local text="$1" name="" value=""
  case "$text" in
    '-'[[:space:]]*)
      text="${text#-}"
      text="${text#"${text%%[![:space:]]*}"}"
      ;;
  esac
  case "$text" in
    '&'*) ;;
    *:[[:space:]]*)
      text="${text#*:}"
      text="${text#"${text%%[![:space:]]*}"}"
      ;;
    *) return ;;
  esac
  case "$text" in
    '&'*) ;;
    *) return ;;
  esac
  text="${text#&}"
  while [ -n "$text" ]; do
    case "$text" in
      [A-Za-z0-9_-]*)
        name="$name${text:0:1}"
        text="${text:1}"
        ;;
      *) break ;;
    esac
  done
  value="${text#"${text%%[![:space:]]*}"}"
  if [ -n "$name" ] && [ -n "$value" ]; then
    alias_names+=("$name")
    alias_values+=("$value")
  fi
}

# alias_expand <text> — every `*name` standing where a node may begin,
# replaced by its anchor's value. An unknown name is left as it was
# written: this guard resolves what the file itself defines and claims
# nothing about an anchor it never saw (KNOWN LIMITS below).
alias_expand() {
  local text="$1" out="" i=0 ch prev name idx found
  case "$text" in
    *'*'*) ;;
    *)
      printf '%s' "$text"
      return
      ;;
  esac
  while [ "$i" -lt "${#text}" ]; do
    ch="${text:i:1}"
    prev=""
    if [ "$i" -gt 0 ]; then
      prev="${text:i-1:1}"
    fi
    if [ "$ch" != '*' ]; then
      out="$out$ch"
      i=$((i + 1))
      continue
    fi
    # Where a node may begin: a fragment's start, or after separation
    # whitespace or a flow indicator. A `*` anywhere else is a character
    # of the scalar it sits in — a `paths: ['**/*.yml']` glob, say.
    case "$prev" in
      '' | ' ' | '	' | '{' | '[' | ',' | ':') ;;
      *)
        out="$out$ch"
        i=$((i + 1))
        continue
        ;;
    esac
    i=$((i + 1))
    name=""
    while [ "$i" -lt "${#text}" ]; do
      case "${text:i:1}" in
        [A-Za-z0-9_-])
          name="$name${text:i:1}"
          i=$((i + 1))
          ;;
        *) break ;;
      esac
    done
    found=""
    idx=0
    while [ "$idx" -lt "${#alias_names[@]}" ]; do
      if [ "${alias_names[idx]}" = "$name" ]; then
        found="${alias_values[idx]}"
      fi
      idx=$((idx + 1))
    done
    if [ -n "$name" ] && [ -n "$found" ]; then
      out="$out$found"
    else
      out="$out*$name"
    fi
  done
  printf '%s' "$out"
}

# THE FRAGMENT IS A FLOW COLLECTION, NOT A SLICE OF A LINE — frag_start,
# flow_feed and flow_flush below are that one idea, and the two shapes
# #395 round 3 found are the two halves of it:
#
#   - A collection's values are ITS OWN. `{runs-on: [self-hosted,
#     ci-runner], environment: pr-runner}` is a job written as a flow
#     mapping, not a runner spec, and reading it from the `runs-on:` key
#     to the end of the line let `environment`'s vouched scalar into the
#     spec's label set. So a fragment carrying a flow mapping begins at
#     the mapping's `{`, and its values are split apart there.
#   - A collection NEED NOT CLOSE on the line that opens it. `with: {`
#     alone on a line handed the splitter one character, and every value
#     below it belonged to no open window at all — both specs vanished,
#     a silent loss rather than a mis-vouch. So the split is a state
#     machine fed one line at a time, carrying bracket depth between
#     lines, rather than a function over one string.
#
# flow_kinds is the open collections' BRACKET KINDS, innermost last —
# `{[` is a list inside a mapping. A comma separates values when the
# collection it sits in is a MAPPING, each value judged alone (#395 round
# 2: two reusable-workflow inputs sharing a line are two different
# runners, and the conjunction argument holds only WITHIN one value); a
# `[…]` list or a bare scalar is ONE value however many lines it spans,
# which is why `[self-hosted, ci-runner]` is not split at its own comma.
# The kind is carried per level rather than the depth counted, because a
# depth-1 test made that rule true of the OUTERMOST mapping only: nest a
# second bracket before the key — `jobs: {build: {runs-on: […], tier:
# pr-runner}}` is the routine spelling — and the nested mapping was one
# value again, its sibling scalar back in the spec's label set. Round 3's
# defect, one level in (#395 round 4, claude-bot's blocker 1).
#
# A QUOTED SCALAR IS OPAQUE, AND IT IS OPAQUE ACROSS ITS PHYSICAL LINES.
# flow_quote used to be cleared at every line end, so a quoted label
# wrapping a line stopped being quoted and the first `]` in its
# continuation was counted as the collection's own close: everything
# after it belonged to no window and vanished — a self-hosted label
# passing with an empty allowlist, no vouch needed (#395 round 4, codex
# and kimi blocking, claude-bot's blocker 2). What that reset defended
# against was an apostrophe in a plain scalar (`don't`) reading as a
# quote, and flow_fresh defends it more narrowly: a quote OPENS only
# where a scalar can start — a fragment's beginning, or after `{`, `[`,
# `,` or `:`. Inside the quote, YAML's own escaping is honoured, so a
# JSON-in-a-string value written `"[\"self-hosted\"]"` yields labels and
# not backslashes, and a correct vouch is not refused (codex, converse).
flow_open=0
flow_kinds=""
flow_fresh=1
flow_quote=""
flow_qend=0
flow_cur=""
flow_hit=""

# flow_flush — the value that just ended becomes a spec if it names
# self-hosted, reported at the first line the value's text appeared on:
# the same choice the block-sequence window makes, and the reason a
# collection spanning lines points at the line carrying the label rather
# than at the bracket that opened it.
flow_flush() {
  case "$flow_cur" in
    *self-hosted*)
      spec_lines+=("${flow_hit:-$lineno: $line}")
      spec_labels+=("$(labels_in "$flow_cur")")
      ;;
  esac
  flow_cur=""
  flow_hit=""
}

# flow_feed <chunk> — one line's worth of an open collection.
flow_feed() {
  local text="$1" i=0 ch prev esc qend ind=0 was_ind=0
  while [ "$i" -lt "${#text}" ]; do
    ch="${text:i:1}"
    prev=""
    if [ "$i" -gt 0 ]; then
      prev="${text:i-1:1}"
    fi
    # Did the PREVIOUS character close a quoted scalar? A `#` after one is a
    # comment (`{a: 'ok'#}`), while a `'` that never opened a scalar is an
    # apostrophe inside a plain one and its `#` is plain text.
    qend="$flow_qend"
    flow_qend=0
    was_ind="$ind"
    ind=0
    i=$((i + 1))
    if [ -n "$flow_quote" ]; then
      # Inside a double-quoted scalar `\` escapes the next character,
      # which is text whatever it is — `\"` is a quote the scalar
      # CONTAINS, not its end, and the backslash is not part of the
      # label. A single-quoted scalar has no backslash escape; its own
      # is `''`, a literal quote that does not close the scalar.
      if [ "$flow_quote" = '"' ] && [ "$ch" = "\\" ] && [ "$i" -lt "${#text}" ]; then
        esc="${text:i:1}"
        i=$((i + 1))
        flow_cur="$flow_cur$esc"
        continue
      fi
      if [ "$ch" = "$flow_quote" ]; then
        if [ "$flow_quote" = "'" ] && [ "${text:i:1}" = "'" ]; then
          i=$((i + 1))
          flow_cur="$flow_cur'"
          continue
        fi
        flow_quote=""
        flow_qend=1
      fi
      flow_cur="$flow_cur$ch"
      continue
    fi
    # A COMMENT IS NOT CONTENT, AND IT CLOSES NOTHING. Outside a quoted
    # scalar a `#` begins a YAML comment that runs to the end of its line,
    # so the rest of this chunk is text belonging to nobody: stop reading
    # it and leave every open collection OPEN, which is the whole
    # difference from the line ending. Feeding it as content let a `}` or
    # `]` inside a comment pop flow_kinds and close the fragment — the
    # values below vanished, self-hosted and all, with no vouch needed —
    # while a `# … self-hosted …` note beside a hosted runner filed a spec
    # that named the comment's tier and refused a correct file (#395 round
    # 5, codex-bot and claude-bot blocking).
    #
    # WHERE a `#` is content is a property of SCALARS, not a list of
    # characters: an unquoted `#` is content only where it CONTINUES A
    # PLAIN SCALAR, which is why `ci#runner` is one label and not a label
    # and a comment. Everywhere else it opens a comment — after separation
    # whitespace, after a flow indicator (`{`, `[`, `,`, `]`, `}`), which
    # a plain scalar cannot contain in flow context, after a quoted
    # scalar's own closing quote, or at a fragment's start. Round 5 had
    # the whitespace half alone, so `with: {# } closes nothing` and its
    # comma, bracket and quote spellings each fed a comment's `}` to the
    # scanner and closed the fragment before the runner value below it —
    # exit 0 with an empty allowlist, the bypass in full (#395 round 6,
    # codex-bot blocking).
    #
    # `:` is NOT in that set, deliberately: `{a:#b}` is the single plain
    # scalar `a:#b` to YAML, so reading a comment there would drop a value
    # the callee really receives — this rule's own fail-open, one step
    # further out than the one it fixes. Nor is the START of a chunk: a
    # whole comment LINE is skipped before it can arrive here, a
    # continuation line arrives with its folded newline in front of it,
    # and the one text that does reach here beginning with a `#` is the
    # loose arm's slice of a plain scalar that CONTAINS one.
    # …and an indicator is one only IN FLOW CONTEXT: a fragment that is a
    # plain scalar carries no open bracket, and a block-context plain
    # scalar may contain a `,` — `runs-on: a,#self-hosted` is one label to
    # YAML, and cutting at that `,#` dropped the tail and passed the file.
    # The same defect no_comment carries above, in the window this rule is
    # stated in: fixing one and not the other would re-open the
    # stated-once-implemented-twice split of round 6 (#395 round 8).
    if [ "$ch" = '#' ] && [ -n "$prev" ]; then
      if [ "$qend" -eq 1 ] || [ "$was_ind" -eq 1 ]; then
        break
      fi
      case "$prev" in
        ' ' | '	') break ;;
      esac
    fi
    case "$ch" in
      '"' | "'")
        if [ "$flow_fresh" -eq 1 ]; then
          flow_quote="$ch"
        fi
        flow_fresh=0
        ;;
      '[' | '{')
        flow_kinds="$flow_kinds$ch"
        flow_fresh=1
        ind=1
        ;;
      ']' | '}')
        if [ -n "$flow_kinds" ]; then
          flow_kinds="${flow_kinds%?}"
          ind=1
          # The collection's own close: what follows it on this line is
          # not one of its values.
          if [ -z "$flow_kinds" ]; then
            flow_flush
            flow_open=0
            return
          fi
        fi
        flow_fresh=0
        ;;
      ',')
        flow_fresh=1
        if [ -n "$flow_kinds" ]; then
          ind=1
        fi
        # A separator only inside a mapping — see flow_kinds above.
        if [ "${flow_kinds: -1}" = '{' ]; then
          flow_flush
          continue
        fi
        ;;
      ':') flow_fresh=1 ;;
      ' ' | '	') ;;
      *) flow_fresh=0 ;;
    esac
    flow_cur="$flow_cur$ch"
  done

  # A fragment ends with its own line unless something is still open:
  # a collection, or a quoted scalar wrapping onto the next line.
  if [ -z "$flow_kinds" ] && [ -z "$flow_quote" ]; then
    flow_flush
    flow_open=0
    return
  fi

  if [ -z "$flow_hit" ]; then
    case "$flow_cur" in
      *self-hosted*) flow_hit="$lineno: $line" ;;
    esac
  fi
}

# frag_start <fragment> — begin a fragment on this line. Whatever opens
# it is fed like any other character, so a leading `{` is a mapping whose
# values are split apart and anything else is one value, collection or
# scalar; a fragment begins where a scalar may.
frag_start() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="$(alias_expand "$text")"
  flow_cur=""
  flow_hit=""
  flow_quote=""
  flow_qend=0
  flow_kinds=""
  flow_fresh=1
  flow_open=1
  flow_feed "$text"
}

# spec_vouched <comma-joined-labels> — true when the consumer has vouched
# for at least one label in the set. See the conjunction argument above.
spec_vouched() {
  local labels="$1" label allow
  while IFS= read -r label; do
    if [ -z "$label" ]; then
      continue
    fi
    for allow in ${allowed[@]+"${allowed[@]}"}; do
      if [ "$label" = "$allow" ]; then
        return 0
      fi
    done
  done <<<"${labels//,/$'\n'}"
  return 1
}

if [ ! -d "$workflows_dir" ]; then
  echo "runner-isolated: no workflows directory at '$workflows_dir' — nothing to scan"
  exit 0
fi

shopt -s nullglob
files=("$workflows_dir"/*.yml "$workflows_dir"/*.yaml)

if [ "${#files[@]}" -eq 0 ]; then
  echo "runner-isolated: 0 workflow files under '$workflows_dir' — nothing to scan"
  exit 0
fi

offenders=0
for file in "${files[@]}"; do
  trig_pr=0
  trig_pr_target=0
  prref_hit=""
  spec_lines=()
  spec_labels=()
  in_on=0
  in_seq=0
  in_with=0
  with_indent=0
  in_blk=0
  blk_indent=0
  blk_labels=""
  blk_hit=""
  seq_labels=""
  seq_hit=""
  seq_indent=0
  seq_items=0
  alias_names=()
  alias_values=()
  flow_open=0
  flow_kinds=""
  flow_fresh=1
  flow_quote=""
  flow_qend=0
  flow_cur=""
  flow_hit=""

  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    # A blank line ends nothing: it is not a top-level key, and a YAML
    # sequence may legally continue past one.
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac

    stripped="${line#"${line%%[![:space:]]*}"}"
    indent=$((${#line} - ${#stripped}))

    # Comment lines are invisible to every half of the rule — EXCEPT
    # inside an open block scalar, where a `#` opens no comment at all: a
    # block scalar's lines are literal text, handed to the callee exactly
    # as written, so a self-hosted label written under a `runner: |` with
    # a `#` in front of it is a label the file passes and not a note
    # about one. Found while writing round 5's own fix, the same
    # comment-versus-content root one window over (#395 round 5).
    case "$stripped" in
      '#'*)
        if [ "$in_blk" -eq 0 ] || [ "$indent" -le "$blk_indent" ]; then
          continue
        fi
        ;;
    esac

    # Half one, second question: does this file check out a PR ref? Only
    # `pull_request_target` files are asked (a `pull_request` one already
    # derives as executing PR code), but the answer is collected for
    # every file — the trigger block may sit below the checkout. Asked
    # HERE, before any window can consume the line: an unterminated
    # collection above it used to eat the file's own `ref:` line, and a
    # file that checks out the PR head then derived as executing no PR
    # code — a silent pass, the one verdict this guard may not reach by
    # accident (#395 round 4, claude-bot's nit 1).
    case "$stripped" in
      *ref:*)
        case "$line" in
          *github.event.pull_request* | *github.head_ref* | *refs/pull/*)
            if [ -z "$prref_hit" ]; then
              prref_hit="$lineno: $stripped"
            fi
            ;;
        esac
        ;;
    esac

    # …and, before any window can consume the line either, the anchors it
    # defines: an alias below may be the only place a runner label is
    # named, and the definition routinely sits in a block — `env:` — that
    # no window of this guard reads. Skipped inside an open block scalar,
    # whose `&` is literal text the callee receives rather than an anchor
    # (#395 round 8).
    case "$stripped" in
      *'&'*)
        if [ "$in_blk" -eq 0 ] || [ "$indent" -le "$blk_indent" ]; then
          anchor_record "$(no_comment "$stripped")"
        fi
        ;;
    esac

    # A flow collection opened on an earlier line goes on consuming lines
    # until its own bracket closes it — the whole of codex-bot's round-3
    # blocker. The line break itself folds to a space, as YAML folds it,
    # so a scalar wrapping a line does not lose the word boundary. It is
    # BOUNDED at a top-level key, which a flow collection cannot contain:
    # a file whose brackets never balance stops there rather than
    # swallowing the rest of itself, trigger block and all, which would
    # turn a malformed file into a silent pass.
    if [ "$flow_open" -eq 1 ]; then
      if [ "$indent" -gt 0 ]; then
        flow_feed " $(alias_expand "$stripped")"
        continue
      fi
      flow_flush
      flow_open=0
    fi

    # Half two, shape b: the window a bare key opened over its list items
    # closes at the first line that is not a `- …` item, and the whole
    # sequence is ONE spec — its labels are read together, so a vouched
    # tier label on a later line still covers the `self-hosted` one above
    # it. The key is `runs-on:` itself or any input key inside an open
    # `with:` window: "a with: value is judged identically to a runs-on:
    # value" has to cover this shape too, and reading each `- …` item as
    # its own one-label spec refused a consumer who had vouched correctly
    # (#395 round 2, claude-bot's nit 2).
    consumed_item=0
    if [ "$in_seq" -eq 1 ]; then
      case "$stripped" in
        '-'*)
          consumed_item=1
          seq_items=$((seq_items + 1))
          # The item's own text: its trailing comment is the line's, not
          # the value's, and the runner probe reads the same text the
          # labels come from — a note is not a spec (#395 round 5). An
          # alias item is its anchor's value, resolved after the comment
          # goes so a `*name` written in a note answers to nothing.
          item_text="$(alias_expand "$(no_comment "$stripped")")"
          item_labels="$(labels_in "$item_text")"
          if [ -n "$item_labels" ]; then
            seq_labels="${seq_labels:+$seq_labels,}$item_labels"
          fi
          case "$item_text" in
            *self-hosted*)
              if [ -z "$seq_hit" ]; then
                seq_hit="$lineno: $line"
              fi
              ;;
          esac
          ;;
        *)
          in_seq=0
          if [ -n "$seq_hit" ]; then
            spec_lines+=("$seq_hit")
            spec_labels+=("$seq_labels")
          fi
          seq_hit=""
          seq_labels=""
          # A BARE KEY'S VALUE MAY BE A FLOW COLLECTION ON THE NEXT LINE,
          # not only a `- …` list: `runs-on:` with `[self-hosted,
          # ci-runner]` indented underneath is the same value written the
          # other way, and GitHub reads it the same. The window closed
          # recording nothing and the line then matched no fragment arm,
          # so it was read by NOTHING — including the `with:`-passed
          # spelling this change exists to catch (#395 round 8,
          # claude-bot blocking). Only as the window's FIRST line and
          # only deeper than its key: after an item has been read the
          # value is the sequence, and at or outside the key's own indent
          # the line belongs to something else entirely.
          if [ "$seq_items" -eq 0 ] && [ "$indent" -gt "$seq_indent" ]; then
            case "$stripped" in
              '['* | '{'*)
                consumed_item=1
                frag_start "$stripped"
                ;;
            esac
          fi
          ;;
      esac
    fi

    # …and shape d: a BLOCK SCALAR value, `runner: |` with its text
    # indented under it. Found while re-reading round 4's own fix rather
    # than reported: the callee receives that text exactly as it receives
    # a quoted one, so a self-hosted label written this way was passed to
    # a reusable workflow and seen by nothing — a fail-open needing no
    # vouch, and against the same criterion decision 5 exists for. The
    # whole block is ONE spec, like the sequence window above, and it
    # closes when indentation returns to the key's own level.
    if [ "$in_blk" -eq 1 ]; then
      if [ "$indent" -gt "$blk_indent" ]; then
        consumed_item=1
        item_labels="$(labels_in "$stripped")"
        if [ -n "$item_labels" ]; then
          blk_labels="${blk_labels:+$blk_labels,}$item_labels"
        fi
        case "$line" in
          *self-hosted*)
            if [ -z "$blk_hit" ]; then
              blk_hit="$lineno: $line"
            fi
            ;;
        esac
      else
        in_blk=0
        if [ -n "$blk_hit" ]; then
          spec_lines+=("$blk_hit")
          spec_labels+=("$blk_labels")
        fi
        blk_hit=""
        blk_labels=""
      fi
    fi

    # The `with:` window closes when indentation returns to the key's own
    # level or further out.
    if [ "$in_with" -eq 1 ] && [ "$indent" -le "$with_indent" ]; then
      in_with=0
    fi

    # A line starting a top-level key opens or closes the trigger block.
    # YAML 1.1 parses bare `on` as a boolean, so some repos quote the
    # key — a guard that missed '"on":' would silently pass the file it
    # most needs to read.
    case "$line" in
      [![:space:]]*)
        in_seq=0
        in_with=0
        case "$line" in
          'on:'* | '"on":'* | "'on':"*) in_on=1 ;;
          *) in_on=0 ;;
        esac
        ;;
    esac

    # Half one: the trigger, and which of the two it is. Checked on the
    # `on:` line itself (scalar and inline-list shapes) and on every line
    # of its block. `pull_request_target` contains `pull_request`, so the
    # longer token is consumed before the shorter one is looked for.
    if [ "$in_on" -eq 1 ]; then
      probe="$line"
      case "$probe" in
        *pull_request_target*) trig_pr_target=1 ;;
      esac
      probe="${probe//pull_request_target/}"
      case "$probe" in
        *pull_request*) trig_pr=1 ;;
      esac
    fi

    # A line consumed as an item of an open sequence window is already
    # part of that window's one spec, so it selects no fragment of its
    # own. THIS is what makes "one line, one report" structural rather
    # than a sentence broader than the code: round 2 left the flush path
    # and the arms below both able to record an item line, and a
    # `- runs-on: […]` item under an open `with:` sequence was reported
    # twice (#395 round 3, claude-bot's nit).
    if [ "$consumed_item" -eq 1 ]; then
      continue
    fi

    # Half two, shapes a and c: WHICH FRAGMENT of this line carries
    # runner specs — a `runs-on:` value, or a label passed through an
    # input, which is what a caller writing
    # `runner: '["self-hosted","ci-runner"]'` is doing (#395 decision 5).
    # The fragment is chosen ONCE, and there is one recording point
    # below.
    frag=""
    case "$stripped" in
      'with:' | 'with:'[[:space:]]*)
        rest="${stripped#with:}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest" in
          '' | '#'*)
            in_with=1
            with_indent=$indent
            ;;
          # The inline flow-mapping form, `with: {runner: …}`, taken as a
          # whole and split per value below. Taken HERE, before the
          # `runs-on:` arm can reach it, because slicing
          # `with: {runs-on: …, note: …}` at `runs-on:` swallows the
          # sibling key and its labels (#395 round 2, claude-bot's nit 1).
          *) frag="$rest" ;;
        esac
        ;;
      'runs-on:' | 'runs-on:'[[:space:]]*)
        rest="${stripped#runs-on:}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest" in
          '' | '#'*)
            in_seq=1
            seq_indent=$indent
            seq_items=0
            ;;
          '|'* | '>'*)
            in_blk=1
            blk_indent=$indent
            ;;
          *) frag="$rest" ;;
        esac
        ;;
      *)
        case "$stripped" in
          # A `runs-on:` that is not this line's own key — a job written
          # as a flow mapping, say, which is the shape this arm's own
          # comment named while reading straight past it: when a mapping
          # opens BEFORE the key, the fragment is that mapping, taken
          # from its `{`. Slicing the line at `runs-on:` instead runs to
          # the end of it, and a sibling key's scalar joined the spec's
          # labels and vouched for a runner it is no part of (#395 round
          # 3, claude-bot's blocker — the round-2 fix reaching the third
          # arm). With no mapping open, read loosely: a miss here is a
          # false NEGATIVE.
          *runs-on:*)
            case "${stripped%%runs-on:*}" in
              *'{'*) frag="{${stripped#*\{}" ;;
              *) frag="${stripped#*runs-on:}" ;;
            esac
            ;;
          *)
            # An input inside an open `with:` window: a bare key opens a
            # block-sequence window exactly as `runs-on:` does, and a key
            # with a value hands that value over as the fragment.
            if [ "$in_with" -eq 1 ] && [ "$in_seq" -eq 0 ]; then
              case "$stripped" in
                # …and `with:`'s OWN value may be a flow mapping on the
                # next line, which is a value and not a key with one:
                # slicing `{safe: [ok], hot: "self-hosted"}` at its first
                # `:` threw away the mapping and everything the arm below
                # needs to split, so `hot:` was read by nothing (#395
                # round 8, claude-bot blocking).
                '['* | '{'*) frag="$stripped" ;;
                *:*)
                  rest="${stripped#*:}"
                  rest="${rest#"${rest%%[![:space:]]*}"}"
                  case "$rest" in
                    '' | '#'*)
                      in_seq=1
                      seq_indent=$indent
                      seq_items=0
                      ;;
                    '|'* | '>'*)
                      in_blk=1
                      blk_indent=$indent
                      ;;
                    *) frag="$rest" ;;
                  esac
                  ;;
              esac
            fi
            ;;
        esac
        ;;
    esac

    # …and the verdict material: every VALUE that fragment carries which
    # names self-hosted is a spec of its own, judged on its own labels —
    # recorded here as each value ends, which may be on this line or on
    # a later one if the collection stays open.
    if [ -n "$frag" ]; then
      frag_start "$frag"
    fi
  done <"$file"

  # A block sequence running to the end of the file still closes.
  if [ -n "$seq_hit" ]; then
    spec_lines+=("$seq_hit")
    spec_labels+=("$seq_labels")
  fi

  # …and so does a block scalar the file ends inside of.
  if [ -n "$blk_hit" ]; then
    spec_lines+=("$blk_hit")
    spec_labels+=("$blk_labels")
  fi

  # …and so does a flow collection the file ends inside of.
  if [ "$flow_open" -eq 1 ]; then
    flow_flush
    flow_open=0
  fi

  # The derivation, in the order the ruling states it.
  pr_code_reason=""
  if [ "$trig_pr" -eq 1 ]; then
    pr_code_reason="its trigger block names pull_request, which runs the PR branch's code"
  elif [ "$trig_pr_target" -eq 1 ] && [ -n "$prref_hit" ]; then
    pr_code_reason="its trigger block names pull_request_target and it checks out a PR ref at line ${prref_hit%%:*} (${prref_hit#*: }) — base-branch privileges with PR-authored code"
  fi

  if [ -z "$pr_code_reason" ] || [ "${#spec_lines[@]}" -eq 0 ]; then
    continue
  fi

  unvouched=()
  index=0
  while [ "$index" -lt "${#spec_lines[@]}" ]; do
    if ! spec_vouched "${spec_labels[index]}"; then
      shown_labels="${spec_labels[index]//,/, }"
      unvouched+=("${spec_lines[index]}"$'\n'"        labels: $shown_labels — none of them is named in pr-code-runner-labels ($allowlist_shown)")
    fi
    index=$((index + 1))
  done

  if [ "${#unvouched[@]}" -gt 0 ]; then
    offenders=$((offenders + 1))
    {
      echo "runner-isolated: $file executes PR-authored code — $pr_code_reason — on a self-hosted runner nobody has vouched for:"
      printf '    %s\n' "${unvouched[@]}"
    } >&2
  fi
done

if [ "$offenders" -gt 0 ]; then
  cat >&2 <<EOF
runner-isolated: $offenders offending workflow file(s). A file that executes
  PR-authored code runs a fork's unreviewed code, and a self-hosted runner
  would execute it on our own hardware, inside our own network. Two unblocks,
  and only one of them is an assertion:
    - SPLIT THE WORKFLOW: PR-triggered checks in one file on hosted runners,
      self-hosted work behind push/dispatch triggers in another — the shape
      incubator's pr-checks.yml and deploy.yml already have; or drop the
      PR-ref checkout, which is what makes a pull_request_target file derive
      as executing PR code at all.
    - VOUCH FOR THE TIER: pass its label in \`pr-code-runner-labels\` — an
      assertion that PR-authored code may execute there, so it holds only for
      a runner that publishes no artifact a trusted job consumes, holds no
      credential the job should not have, and reaches nothing the PR author
      should not reach (docs/CONSUMERS.md states the bar). Never the tier that
      publishes your images.
  The rule is file-level on purpose (this script's header): a file mixing the
  two is one editing mistake away from being the real bug.
EOF
  exit 1
fi

echo "runner-isolated: ${#files[@]} workflow file(s) scanned under '$workflows_dir' — no PR-authored code on an unvouched self-hosted runner"
