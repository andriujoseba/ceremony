#!/usr/bin/env bash
# lib/read.sh — the guarded read: an unreadable fact never invents a verdict.
#
# Both reconcilers source this file. The rule is the family's oldest one
# (#101, #95) and it has now been bought twice: the PR surface learned it
# when a permissions denial and a network hiccup left byte-identical
# evidence, and the ISSUE surface learned it when an HTTP 504 whose body is
# GitHub's JSON error object flowed straight into a decision function —
# `gh api` prints that body to stdout *and* exits non-zero, so the payload
# reaching the guards was valid JSON, `.labels[]` came back empty, and the
# sweep wrote `needs-triage` onto a healthy epic and called the pass a
# success (crew#329, #247).
#
# Two helpers, both used on both surfaces:
#   - guarded_read  — run a read, keep its stderr, report its status
#   - read_failure_reason — render that stderr into one bounded log line
#
# What the CALLER does with a failed read is the caller's: labels-reconcile
# leaves the PR alone for the pass, issueflow-reconcile skips the issue. The
# one thing neither may do is carry a degraded value into a decision.

guarded_read() { # $1 = variable to fill, rest = the read; sets READ_FAILURE_STDERR
  # The status check and the captured stderr are one operation on purpose: a
  # read whose failure is noticed but whose reason is thrown away is what
  # #95 had to infer a cause from a control case for — wrongly, it turned
  # out (#101 D2). Captured into a file rather than merged into stdout, so
  # an unlucky error line can never be read back as the read's own payload.
  local __var="$1" __err __out __rc=0
  shift
  __err="$(mktemp)" || return 1
  __out="$("$@" 2>"$__err")" || __rc=$?
  READ_FAILURE_STDERR="$(cat "$__err")"
  rm -f "$__err"
  printf -v "$__var" '%s' "$__out"
  return "$__rc"
}

read_failure_reason() { # $1 = captured stderr → one bounded line; pure (#101)
  # Verbatim, collapsed, bounded (D3): gh emits multi-line errors and GraphQL
  # blobs. Collapsed so the reason is exactly one log line — a raw newline
  # inside the captured per-item output block could collide with a matched
  # string — and truncated because an unbounded paste per item per sweep is
  # noise, and annotations are capped anyway.
  local reason
  reason="$(printf '%s' "${1-}" | tr '\n' ' ')"
  if [ -z "$reason" ]; then
    # Empty stderr is itself a fact (D4): a read that failed silently is a
    # different observation from a denial, and must not read as one.
    echo "no error output"
  elif [ "${#reason}" -gt 300 ]; then
    printf '%s…\n' "${reason:0:300}"
  else
    printf '%s\n' "$reason"
  fi
}
