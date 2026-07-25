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
