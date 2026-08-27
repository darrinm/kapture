# Releasing Kapture

A release is a git tag. `.github/workflows/release.yml` does the rest: builds, signs with
Developer ID, packages a DMG, notarizes and staples it, signs the update for Sparkle, and
publishes both `Kapture.dmg` and `appcast.xml` to the GitHub release. kapture.sh redirects
`/download` and `/appcast.xml` at those assets, so GitHub serves every byte.

```sh
git tag v0.2.0
git push origin v0.2.0
```

## One-time setup

Six repository secrets. Nothing else about a machine is required — the workflow builds on a
clean runner.

### Signing certificate

Export the **Developer ID Application** certificate from Keychain Access as a `.p12`, then:

```sh
base64 -i Kapture.p12 | pbcopy      # → secret DEVELOPER_ID_P12
```

Add `DEVELOPER_ID_P12_PASSWORD` with the password used at export.

An *Apple Development* certificate is not enough. It is what local `bundle.sh` builds use, and
it keeps TCC grants stable across rebuilds, but macOS refuses a downloaded app signed with it.

### Notarization

- `APPLE_ID` — the Apple ID of the developer account
- `APPLE_TEAM_ID` — from developer.apple.com › Membership
- `APPLE_APP_PASSWORD` — an app-specific password from appleid.apple.com, *not* the account
  password

### Sparkle update keys

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It writes the private key into the login Keychain and prints the public key. Export the private
half for CI with `generate_keys -x private.key`, put its contents in `SPARKLE_PRIVATE_KEY`, and
the printed public key in `SPARKLE_PUBLIC_KEY`. Delete `private.key` afterwards.

The public key is baked into `Info.plist` as `SUPublicEDKey` at bundle time. A build without it
(any local `bundle.sh` run) has its updater disabled outright rather than running unverified —
"Check for Updates…" opens the download page instead.

**Do not rotate the private key casually.** Every installed copy trusts only the public key it
shipped with; a new key means those copies stop seeing updates and must be reinstalled by hand.

## What each release must survive

The workflow fails rather than publishing if any of these do not hold:

- `codesign --verify --deep --strict` passes and the identity really is Developer ID
- `notarytool submit --wait` returns accepted, and `stapler staple` succeeds
- `spctl -a -t open` accepts the DMG — Gatekeeper's own verdict, checked on the runner instead
  of on a friend's Mac
- the generated appcast parses as XML

## Version numbers

`CFBundleShortVersionString` comes from the tag (`v0.2.0` → `0.2.0`) and `CFBundleVersion` from
the workflow run number, which is monotonic. Sparkle compares the latter, so a re-run of an
older tag will never look newer than a release cut after it.
