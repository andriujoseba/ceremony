# changelog.d/ — the next release's section, one fragment per issue

Machine-assembled by `bin/changelog-assemble` (#112): every PR that changes
behavior writes one file here — `<issue>.md`, the exact prose that will be
published, nothing else — and the release PR folds them all into the next
`## X.Y.Z — DATE` section of `CHANGELOG.md`, consuming them. Distinct
filenames never conflict, which is this directory's whole reason to exist.
This README is the marker that keeps the directory tracked when it holds no
fragments (#112 D1) — `changelog-armed` refuses a tree without it; do not
delete it. The `shape` sentinel beside it declares the set's shape —
`grouped` here, so every fragment carries `### ` headings (#182).

## How an entry must be written

`changelog-armed` enforces two rules about the entries themselves, and both
are cheapest to obey here rather than to discover on a red merge door
(#571). Each reads an entry the same way: the `- ` bullet and every line
that continues it, joined into one string, runs of whitespace collapsed to
single spaces, the ends trimmed. The `- ` marker is not part of it.

- **An entry is at most 300 characters** — counted on that joined, collapsed
  string, so it is a bound on the whole entry and not on any one line of it.
  Wrapping a long entry across three lines does not shorten it. Over the
  bound, split it into several `- ` entries in this same fragment.
- **Exactly one `(#N)` citation group ends the entry, with the final `.`
  after it.** That group may carry more than one reference, separated by a
  comma and a space, and a reference may name another repository. All three
  of these shapes are admitted:

  ```text
  - … (#N).
  - … (#N, #M).
  - … (owner/repo#N, #M).
  ```

  So an entry citing two issues writes `(#141, #163).` — one group, two
  references — and one citing a sibling repository writes
  `(heavy-duty/ceremony#567, #61).`, the bare form `ceremony#567` included.

  What fails is a **second parenthesised citation group anywhere in the
  entry**: with two groups no single group closes the entry, so no group is
  terminal, and `(#141) (#163).` is refused where `(#141, #163).` passes.
  The same applies to anything after the closing `.` — a further sentence,
  a trailing aside — which moves the group off the end.
