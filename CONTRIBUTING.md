# Contributing

Kapture is one person's tool, published because it may be useful to others. That shapes what
is welcome here.

**Bug reports are welcome.** Especially with the macOS version, the Mac model, and what you
did. Capture bugs are often display-, permission-, or multi-monitor-specific, so those details
are usually the whole diagnosis.

**Ask before writing a large pull request.** Open an issue describing the change first. A big
unsolicited PR will probably sit unmerged — not out of ingratitude, but because a personal tool
has opinions, and a feature that doesn't fit them can't be merged no matter how good the code
is. Better to find that out in a paragraph than after your weekend.

**Small fixes need no ceremony.** A crash, a typo, a wrong shortcut, a broken build on a
configuration I don't have — send the PR.

**Feature requests** may well be declined, and it's nothing personal. The v2 parking lot
(cinematic motion editing, web capture at breakpoints, backgrounds and frames, webcam overlay)
is real but unscheduled.

## Working on it

```sh
scripts/bundle.sh          # build + assemble + sign Kapture.app
scripts/test.sh            # swift test
cd worker && npm test      # the share backend
```

Warnings are errors here, in both the local build and CI.

**A green local build does not mean a green CI build.** SwiftPM on a recent toolchain builds
against the host OS rather than the package's `macOS(.v14)` deployment target, so a call that is
macOS 15-only compiles fine on your machine and fails on CI with "only available in macOS 15 or
newer". Passing `-Xswiftc -target` doesn't help — SwiftPM appends its own afterwards — and
`--triple` selects a mismatched SDK. So when you reach for a recent API, guard it with
`if #available(macOS 15, *)` and a macOS 14 path, and let CI have the last word. This is not
hypothetical: it once sat on main for twenty commits. Tests that need Screen Recording or
Accessibility can't run on a headless CI runner, so that code is exercised through the headless
harness flags (`--tcc-check`, `--ingest-now`, `--gif-test`, `--share-test`) rather than by
synthesizing input.

Match the surrounding code: comments explain *why*, particularly when something looks odd —
most of the odd-looking things here are load-bearing workarounds for a real macOS behavior, and
several are documented at the point where they bit.

## License

By contributing you agree your contribution is licensed under the [MIT License](LICENSE), the
same as the rest of the project.
