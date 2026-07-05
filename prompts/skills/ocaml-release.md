---
description: Guides releasing OCaml packages to opam — choosing a version, changelog discipline, the dune-release tag/distrib/publish/submit workflow, and what opam-repository CI and review expect. Use when preparing or cutting a release, publishing a package to opam, bumping a version, writing release notes, or fixing a failing opam-repository PR. Triggers on phrases like "release this package", "publish to opam", "dune-release", "bump the version", "cut a release", "update the changelog", or "the opam PR failed". For scaffolding a project before its first release, load ocaml-project-setup.
---

# OCaml Release

Releasing to opam is two handshakes: a tarball published on your forge,
and a pull request against `ocaml/opam-repository` pointing at it.
`dune-release` automates both for dune projects hosted on GitHub and is
still the standard tool; `dune pkg` is about consuming dependencies, not
publishing. For non-GitHub or non-dune projects, `opam publish` or a
manual PR against opam-repository are the fallbacks.

## 1. Pre-Release Audit

Scaffolding correctness is the `ocaml-project-setup` skill (opam
metadata generated from `dune-project`, license, `.mli` coverage); the
test suite is `ocaml-testing`. On top of that, before every release:

- Confirm `dune-project` has no `(version ...)` field. The version is
  stamped at release time (dune's own docs: "It is not necessary to
  specify `(version)`, this will be added at release time if you use
  dune-release"). A hardcoded version goes stale and fights the
  release tool.
- Commit everything. `dune-release distrib` archives the HEAD commit
  and silently ignores uncommitted changes, so an unstaged fix simply
  won't be in the tarball.
- Run `dune-release check`: it verifies the repository lints, builds,
  and passes tests — the same gates the later steps assume.
- Audit `(depends ...)` lower bounds. opam-repository CI has a
  lower-bounds job that installs the oldest versions the solver
  allows; a guessed `(>= 1.0)` that only compiles against 4.2 fails
  there, not on your machine.

## 2. Choose the Version

opam version ordering is Debian-style, not semver. The consequences
that matter:

- `~` sorts before the empty string: `1.0.0~beta1 < 1.0.0`. Use `~`
  for pre-releases and dev suffixes (`2.0.0~alpha1`, `1.1.0~dev`).
- A semver-style hyphen sorts the wrong way: `1.0-rc1 > 1.0` in opam
  ordering, so `-rc1` would supersede the final release. Never use
  `-` for pre-releases.
- Digit runs compare numerically (`~beta2 < ~beta10`), so numbered
  pre-releases are safe.

What the ecosystem actually keys on is API compatibility, because
opam-repository CI rebuilds every reverse dependency of your package on
each release. Bump the major version (minor, pre-1.0) whenever the API
breaks: downstream constraint fixes and the revdep failures in your
release PR are then legible as "expected, needs upper bounds" rather
than an accident. Constraint hygiene is mostly repo-side and
retroactive — when a release breaks dependents, upper bounds like
`"foo" {< "2.0.0"}` get added to the *dependents'* opam files in
opam-repository — so your job is honest bounds in your own
`(depends ...)`, not speculative upper bounds on everything.

## 3. Write the Changelog

`dune-release` parses `CHANGES.md` (Markdown or Asciidoc): the version
number must be in the first item of the file, usually a section title,
and the body of that first entry is the release note that travels with
the release. Format:

```markdown
## v1.2.0 (2026-07-03)

- Add streaming decoder (#42, @contributor)
- Fix off-by-one in chunk boundaries (#45)

## v1.1.0 (2026-03-10)

...
```

Rules with reasons:

- The topmost heading must be the version you are about to release,
  because `dune-release tag` extracts the version from it. A lingering
  `## Unreleased` heading at the top means the tool tags the wrong
  thing or refuses; rename it to the real version as the first step of
  the release.
- Write entries for users, not for git: what changed in the API, what
  breaks, what to migrate. Reviewers on the opam PR and downstream
  maintainers read exactly this text.
- Date the entry. The `## v1.2.0 (2026-07-03)` shape is what the tool
  documents and what the ecosystem expects to skim.

## 4. Tag and Build the Distribution

```
dune-release tag        # reads CHANGES.md, creates an annotated tag
dune-release distrib    # builds the tarball from HEAD
```

- The tag must be annotated; dune-release creates it that way and both
  dune-release and dune only work with annotated tags. The reason is
  `git describe`, which the version substitution machinery relies on
  and which ignores lightweight tags by default.
- `distrib` also performs watermarking: every `%%ID%%` string in the
  project is substituted before the tarball is created. Known
  watermarks include `%%NAME%%`, `%%VERSION%%` (from
  `git describe --always --dirty`), `%%VERSION_NUM%%` (same, leading
  `v`/`V` dropped), `%%VCS_COMMIT_ID%%`, and `%%PKG_MAINTAINER%%` /
  `%%PKG_HOMEPAGE%%` / other `%%PKG_*%%` fields read from the opam
  file. Put `%%VERSION%%` in a `--version` string rather than editing
  a constant by hand each release.
- `dune subst` performs the same substitution outside dune-release;
  the generated opam build instructions run it as
  `["dune" "subst"] {dev}` so a user pinning your git repo gets
  watermarked sources too. It can also add the `(version ...)` field
  to `dune-project` — this, plus the release-time stamping, is why
  the field must not be committed (section 1).
- Tarball contents are frozen at merge: opam-repository prohibits
  changing the checksum of an already-merged package. If the tag or
  tarball is wrong, the fix is a new point release, never a
  force-pushed tag or re-uploaded archive.

## 5. Publish and Submit

```
dune-release publish      # GitHub release + tarball upload
dune-release opam pkg     # opam file with url section + checksum
dune-release opam submit  # PR against ocaml/opam-repository
```

`dune-release bistro` runs the whole pipeline (check, tag if needed,
distrib, publish, opam pkg, submit) in one command; use it once the
process is routine, use the individual steps when something needs
inspection between stages. Notes:

- `publish` talks to GitHub over SSH by default; if the environment
  only has HTTPS credentials, configure git to rewrite SSH GitHub
  URLs to HTTPS.
- The generated opam file records `x-commit-hash`, the commit the
  release was cut from. Leave it in: the tarball is not a git
  checkout, and this field is how tooling and humans map it back to
  history.
- For a manual submission (no dune-release): the `url` section needs a
  publicly reachable archive plus checksums — at least sha256 or
  stronger, and more than one checksum is recommended — and the
  `name`, `version`, and `pin-depends` fields must be removed, since
  the repository encodes name and version in the file path and
  `pin-depends` is meaningless in a published package.

## 6. Survive opam-repository CI and Review

The PR is tested far more broadly than your CI:

- `opam lint` plus repository-specific lints.
- Build and test across recent OCaml compiler versions, multiple
  operating systems (Linux distributions, FreeBSD, macOS, Windows),
  and architectures, including compiler variants.
- A lower-bounds run installing the oldest dependency versions the
  solver permits. Failure here means a lower bound in your
  `(depends ...)` is a lie; raise it to the oldest version that
  actually works.
- A reverse-dependencies run rebuilding everything that depends on
  you. Failures mean the release broke API; the standard resolution
  is adding upper bounds on the failing dependents in the same or a
  follow-up opam-repository change, not withdrawing your release.

Platform limits have two distinct tools: `available` when the package
cannot work on a platform in principle (excludes it from the solver),
and `x-ci-accept-failures` when a specific distribution is known-broken
for incidental reasons. Using `available` for an incidental failure
hides the package from users who could run it.

Expect human review of metadata (synopsis, description, maintainer,
constraints) on top of CI; maintainers review batches regularly, so an
unattended red PR just sits. Fix failures or explain them in the PR
thread — pre-existing failures that also occur on the previous
version are acceptable and worth pointing out.

## 7. Declare Maintenance Intent

opam-repository archives package versions on a schedule (periodic runs
move them to `ocaml/opam-repository-archive`): versions that fall
outside a package's declared maintenance intent, are uninstallable, or
require compilers older than the cutoff. The `x-maintenance-intent`
field in the opam file declares which versions you maintain:

- `["(latest)"]` — only the newest version stays; older ones may be
  archived once nothing in the repository needs them.
- `["(any)"]` — keep every version; the current default.
- Patterns compose: `["(latest)" "(latest-1)"]`, `["2.(latest)"]`,
  `["(any).(latest)"]`.

Declare it explicitly (most libraries want `["(latest)"]`) rather than
riding the default: the default is announced to change, and an explicit
intent makes archival of your old versions predictable instead of a
surprise. Adding it to the latest release is sufficient, and it can be
PRed directly to opam-repository without cutting a release. Versions
outside your intent that another retained package depends on are kept
anyway, so declaring `(latest)` cannot strand downstream users.

## 8. Post-Release

- Verify the published artifacts: the GitHub release exists, the
  tarball installs (`opam install ./pkg.opam` equivalents are not
  enough — the PR's CI installs from the tarball URL, which is the
  path users take).
- If a defect ships, release a point version. The archive and its
  checksum are immutable once merged, so there is no in-place fix.
- Keep the changelog ready for the next cycle, remembering that the
  top entry must be the released version at the moment of the next
  `dune-release tag`.

## Checklist

- [ ] No `(version ...)` in `dune-project`; everything committed
      before `distrib` (it archives HEAD and ignores the worktree)
- [ ] `dune-release check` passes; lower bounds in `(depends ...)`
      are real, not guessed
- [ ] Version chosen by API impact; pre-releases use `~` (never `-`),
      breaking changes bump the major
- [ ] `CHANGES.md` top entry is the release version with a date and
      user-facing notes
- [ ] Annotated tag created via `dune-release tag`
- [ ] Watermarks (`%%VERSION%%` etc.) used instead of hand-edited
      version constants
- [ ] Published via `publish` / `opam pkg` / `opam submit` (or
      `bistro`); `x-commit-hash` left in the opam file
- [ ] Manual submissions: sha256-or-stronger checksums, `name` /
      `version` / `pin-depends` fields removed
- [ ] opam-repository CI triaged: lower-bounds failures fix your
      bounds, revdep failures get upper bounds on dependents
- [ ] `x-maintenance-intent` declared (usually `["(latest)"]`)
- [ ] Broken release answered with a point release, never a mutated
      tag or tarball
