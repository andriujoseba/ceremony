# incubator's callers, verbatim — the #395 regression fixture

`.github/workflows/` here holds four files copied **byte for byte** from
`heavy-duty/incubator@main`, not paraphrased. The last spec (#389) was wrong
about exactly this claim — it asserted these files would need an
`pr-code-runner-labels` entry, and they do not — so the claim is now a
fixture that fails if it stops being true.

Provenance, verifiable with `git hash-object` (the blob SHAs are GitHub's own
for those paths at incubator `main` = `c58e5706e0a754e5e4344a1a973aff30fd31c8e0`,
copied 2026-08-12):

| file | blob SHA |
|---|---|
| `labels.yml` | `7e57719ede956f8f664798948c6df65ff47e1580` |
| `labels-sweep.yml` | `99f84fb99fe3a6a30e371911282112f14e411610` |
| `release.yml` | `034acff42462355955e64f419106d08d546e899b` |
| `pr-checks.yml` | `3703408d95cf81d4b9c76e838e583149e2efd889` |

The three `with:`-passing callers are what decision 6 names: all three pass
`runner: '["self-hosted","ci-runner"]'` — which decision 5 now *sees* — and
all three derive as executing no PR-authored code, so they pass with no input
set. `pr-checks.yml` is here because it is the only one of incubator's files
that derives as executing PR code: without it the fixture would prove the
no-PR-code half of the change and nothing else.

They are a snapshot, deliberately. When incubator changes these files this
copy does not follow, and it should not: the fixture records what the guard
was proved against, and a fixture that tracks a moving tree proves nothing on
the day it breaks.
