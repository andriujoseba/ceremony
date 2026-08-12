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
# `github.event.pull_request` (which covers `.head.sha` and `.head.ref`)
# or `github.head_ref`. It is not tied to a recognised checkout step,
# because binding it to `uses: actions/checkout` is the YAML-parsing
# problem again and every miss there is a false NEGATIVE on the one row
# this change exists to close. Over-reading a `ref:` line can only make a
# file derive as executing PR code — never permit one.
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
#   - indirection is not resolved: a runner group (`runs-on: {group: …}`)
#     or a matrix/expression value can reach self-hosted hardware without
#     the string appearing on any line this guard reads.
#
# Comments are skipped on BOTH halves of the rule: a workflow that merely
# mentions self-hosted in prose is not the bug (incubator's pr-checks.yml
# header is exactly that prose), and a guard that cried wolf on comments
# would be turned off within a week. A missing workflows directory is a
# PASS, not an error — most repos in the family have one, but a guard
# that fails on absence is a guard nobody adopts.
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
# and bare scalars reduce to the same thing: brackets, quotes and the
# item dash are punctuation.
labels_in() {
  local value="$1"
  case "$value" in
    *[[:space:]]'#'*) value="${value%%[[:space:]]#*}" ;;
  esac
  printf '%s' "$value" \
    | tr -d "\"'[]" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*-*[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | paste -sd, - || true
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
  in_runs_on=0
  in_with=0
  with_indent=0
  seq_labels=""
  seq_hit=""

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

    # Comment lines are invisible to every half of the rule.
    case "$stripped" in
      '#'*) continue ;;
    esac

    indent=$((${#line} - ${#stripped}))

    # Half two, shape b: the window a bare `runs-on:` key opened over its
    # list items closes at the first line that is not a `- …` item, and
    # the whole sequence is ONE spec — its labels are read together, so a
    # vouched tier label on a later line still covers the `self-hosted`
    # one above it.
    if [ "$in_runs_on" -eq 1 ]; then
      case "$stripped" in
        '-'*)
          item_labels="$(labels_in "$stripped")"
          if [ -n "$item_labels" ]; then
            seq_labels="${seq_labels:+$seq_labels,}$item_labels"
          fi
          case "$line" in
            *self-hosted*)
              if [ -z "$seq_hit" ]; then
                seq_hit="$lineno: $line"
              fi
              ;;
          esac
          ;;
        *)
          in_runs_on=0
          if [ -n "$seq_hit" ]; then
            spec_lines+=("$seq_hit")
            spec_labels+=("$seq_labels")
          fi
          seq_hit=""
          seq_labels=""
          ;;
      esac
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
        in_runs_on=0
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

    # Half one, second question: does this file check out a PR ref? Only
    # `pull_request_target` files are asked (a `pull_request` one already
    # derives as executing PR code), but the answer is collected for
    # every file — the trigger block may sit below the checkout.
    case "$stripped" in
      *ref:*)
        case "$line" in
          *github.event.pull_request* | *github.head_ref*)
            if [ -z "$prref_hit" ]; then
              prref_hit="$lineno: $stripped"
            fi
            ;;
        esac
        ;;
    esac

    # Half two, shape a: `runs-on:` on one line, and the bare key that
    # opens the block-sequence window.
    case "$line" in
      *runs-on*)
        case "$line" in
          *self-hosted*)
            spec_lines+=("$lineno: $line")
            spec_labels+=("$(labels_in "${stripped#*runs-on:}")")
            ;;
        esac
        case "$stripped" in
          'runs-on:' | 'runs-on:'[[:space:]]*)
            rest="${stripped#runs-on:}"
            rest="${rest#"${rest%%[![:space:]]*}"}"
            case "$rest" in
              '' | '#'*) in_runs_on=1 ;;
            esac
            ;;
        esac
        ;;
    esac

    # Half two, shape c: a label passed through an input. A caller
    # writing `runner: '["self-hosted","ci-runner"]'` is doing what
    # naming it in `runs-on` does (#395 decision 5).
    case "$stripped" in
      'with:' | 'with:'[[:space:]]*)
        rest="${stripped#with:}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest" in
          '' | '#'*)
            in_with=1
            with_indent=$indent
            ;;
          *)
            # The inline flow-mapping form, `with: {runner: …}`.
            case "$line" in
              *self-hosted*)
                spec_lines+=("$lineno: $line")
                spec_labels+=("$(labels_in "$rest")")
                ;;
            esac
            ;;
        esac
        ;;
      *)
        if [ "$in_with" -eq 1 ]; then
          case "$line" in
            *self-hosted*)
              spec_lines+=("$lineno: $line")
              spec_labels+=("$(labels_in "${stripped#*:}")")
              ;;
          esac
        fi
        ;;
    esac
  done <"$file"

  # A block sequence running to the end of the file still closes.
  if [ -n "$seq_hit" ]; then
    spec_lines+=("$seq_hit")
    spec_labels+=("$seq_labels")
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
