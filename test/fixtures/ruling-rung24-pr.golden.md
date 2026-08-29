<!-- ceremony:needs-ruling-rung24 -->
@setter — this ruling is 24 hours past its `labeled` event: the ladder's
24h rung ([BUILDER.md — the ruling ask](https://github.com/heavy-duty/ceremony/blob/main/BUILDER.md#the-ruling-ask),
heavy-duty/ceremony#50 D13). Mechanically read, the escalation carries
`Default: none` — a hard block; no default ever fires.

At 24h the builder proceeds regardless, **as a PR**: pick an option and
state in the PR body which way you went and what doubt remains. Nothing
merges by this — the human still gates the merge. Past 24h the choice is
triage's to make: triage picks the option, records it as a decision, and
remains accountable; the operator may overturn it at merge. The rungs run on
the `labeled` clock and do not reset on activity; this comment fires once
per flag episode and covers everything past 24h — there is no further
timer.
