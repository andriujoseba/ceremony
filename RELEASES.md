# Release management

This file describes the release-management pattern available to governed
repositories. Adoption is per repository and operator-ruled: a repository
without version epics is not out of compliance. A repo-local roadmap is the
map; each epic remains the source of truth for its own release. Where an older
repo-local description differs from this file, this file governs.

## The ladder

Represent each planned release with one version epic. The epic is the working
surface for that release: it states the goal, names the members, and records
the ordered waves as checklists. Keep the machine-readable progress checklist
under the exact heading `## Task list`; the issue-flow sweep reads that heading
when it decides whether to nudge triage about a completed epic.

Keep a short repo-local roadmap beside the epics. The roadmap shows the whole
ladder and points to each working surface; it does not duplicate the live
member lists or ordering. crew's roadmap discussion [heavy-duty/crew#338](https://github.com/heavy-duty/crew/discussions/338)
maps the ladder whose `0.1.2` working surface moved from the crufty ledger
[heavy-duty/crew#162](https://github.com/heavy-duty/crew/issues/162) to
[heavy-duty/crew#346](https://github.com/heavy-duty/crew/issues/346).

## Gates

Each version epic declares the predecessor that opens it. Special ordering —
a double gate or an out-of-chain gate — is written explicitly on that epic;
there is no hidden global schedule. Shipping closes the current epic, and its
close is the signal for triage to open the next release-init cycle by hand.
Version epics carry `epic`, not a queue label: `ready` offers work to builders,
and builders never pick epics.

The gate orders windows, not their contents. Members enter a release only by
decision during release-init. The double gate on heavy-duty/crew#163 and the
out-of-chain track on [heavy-duty/crew#348](https://github.com/heavy-duty/crew/issues/348)
are worked examples of exceptions declared where they apply.

## Release-init

The preceding epic's close is the trigger. Triage then runs five steps:

1. Mint the epic's “to mint when this arc opens” list together with findings,
   deferred work, and discussion outcomes accumulated since the epic was
   written. Each member initially declares `Blocked by <the epic>`.
2. Graph hard `Blocked by` edges and same-file clusters on the epic.
3. Write the waves into the epic body as checklists in claim order, with a
   separate verification lane and the progress view under `## Task list`.
4. Ask the operator to bless the order, then have triage open the first wave
   by applying the flip mechanics below. The operator's blessing is the one
   step this chain never automates.
5. Ship through the repository's cut process, close the epic, and treat that
   close as the trigger for the next window.

heavy-duty/crew#346 is the worked wave plan; its graph made both hard edges
and shared-file contention visible before builders entered the queue. If init
finds no work worth minting, the operator either folds the empty window into a
later release or skips the version, recording that ruling on the epic before
closing it unshipped.

## One primary window, declared parallel tracks

Run one primary release window by default. A cut takes whatever has landed, so
interleaving unrelated windows blurs both the release story and the evidence
behind it. Gates open windows; they do not silently admit members, so builders
still see one deliberately ordered queue.

The operator may declare a parallel track at init when its footprint is
disjoint from the primary window: another repository, another artifact, or
provably non-overlapping clusters. The declaration names the boundary and any
bridge work that must rejoin the primary. [heavy-duty/crew#348](https://github.com/heavy-duty/crew/issues/348)
is the worked example: its app and artifact form a parallel track while its
small crew-side bridge remains in the primary window.

## Flip mechanics

To admit a member, strike its live `Blocked by <the epic>` declaration and
swap `blocked` to `ready` in the same edit. Never preserve history by negating
the marker phrase — the blocker parser unions declarations even when prose
says they no longer apply. Preserve the old text only after striking or
rewriting the parseable clause, then verify the parser's resulting set.

Release membership is a decision, never a sweep default. Triage performs each
flip only after the operator blesses the wave; the issue-flow sweep may resolve
ordinary issue dependencies, but it does not choose a release's contents.
heavy-duty/crew#346 records the member-by-member flip that opened its first
wave.

## The ledger pattern

When a release epic has become too crufty to remain a clear working surface,
create a replacement and treat the old epic as a ledger. Do not close the old
epic until every live member declaration points at the replacement and the
blocker parser verifies the new set. Closing early can release every member
that still names the old issue.

The [heavy-duty/crew#162](https://github.com/heavy-duty/crew/issues/162) to
[heavy-duty/crew#346](https://github.com/heavy-duty/crew/issues/346)
transition is the worked example: all member declarations were re-pointed and
parse-verified before #162 closed; #162 remains the historical record while
#346 is the release's working surface.
