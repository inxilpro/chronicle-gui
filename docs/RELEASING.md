# Releasing Chronicle

Releases are cut by pushing a `vX.Y.Z` tag. `.github/workflows/release.yml`
builds, signs, notarizes, staples, packages, generates the Sparkle appcast, and
publishes everything to the GitHub Release for that tag. Before the first
release, complete the one-time setup below.

> The repository is assumed to be `inxilpro/chronicle-gui`. If it lives elsewhere,
> update the `SUFeedURL` in `Chronicle/Info.plist` and the
> `--download-url-prefix` in `.github/workflows/release.yml`.

## One-time setup

### 1. Sparkle EdDSA keypair

Sparkle signs each update archive with an EdDSA key; the app verifies with the
matching public key baked into `Info.plist`.

1. Download the Sparkle distribution matching the SPM-resolved version
   (currently 2.9.6):

   ```sh
   curl -fsSLO https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
   tar -xJf Sparkle-2.9.6.tar.xz
   ```

2. Generate the keypair (stored in your login keychain):

   ```sh
   ./bin/generate_keys
   ```

   It prints the **public** key (base64). Put it into
   `Chronicle/Info.plist` as the value of `SUPublicEDKey`, replacing
   `REPLACE_WITH_SPARKLE_ED_PUBLIC_KEY`, and commit that change.

3. Export the **private** key for CI:

   ```sh
   ./bin/generate_keys -x sparkle-private-key.txt
   ```

   The file's contents become the `SPARKLE_PRIVATE_KEY` secret. Keep a secure
   backup (e.g. a password manager); losing the private key strands every
   installed copy on its current version. Delete the exported file afterwards.

### 2. Developer ID Application certificate

1. In Xcode → Settings → Accounts → your team (657AK7D2D9) → Manage
   Certificates, create a **Developer ID Application** certificate if one does
   not exist (or create it at developer.apple.com → Certificates).
2. In Keychain Access, find the certificate (with its private key), select
   both, and export as a `.p12`, choosing an export password.
3. Base64-encode it for the secret:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```

   The clipboard contents become `MACOS_CERTIFICATE_P12`; the export password
   becomes `MACOS_CERTIFICATE_PASSWORD`.

### 3. App Store Connect API key (for notarization)

1. In App Store Connect → Users and Access → Integrations → App Store Connect
   API → Team Keys, generate a key with the **Developer** role.
2. Download the `.p8` file (only possible once).
3. Record:
   - the **Key ID** → `ASC_KEY_ID`
   - the **Issuer ID** (top of the keys page) → `ASC_ISSUER_ID`
   - the file contents (`cat AuthKey_XXXX.p8`) → `ASC_PRIVATE_KEY`

### 4. GitHub secrets

Set each secret on the repository (Settings → Secrets and variables → Actions,
or with `gh`):

```sh
gh secret set MACOS_CERTIFICATE_P12       # base64 of the Developer ID .p12
gh secret set MACOS_CERTIFICATE_PASSWORD  # the .p12 export password
gh secret set KEYCHAIN_PASSWORD           # any random string, e.g. `uuidgen`
gh secret set APPLE_TEAM_ID               # 657AK7D2D9
gh secret set ASC_KEY_ID                  # App Store Connect API key ID
gh secret set ASC_ISSUER_ID               # App Store Connect API issuer ID
gh secret set ASC_PRIVATE_KEY             # contents of the .p8 file
gh secret set SPARKLE_PRIVATE_KEY         # contents of generate_keys -x output
```

`KEYCHAIN_PASSWORD` protects only the throwaway keychain created for a single
CI run; any random value is fine.

## How updates are served (SUFeedURL)

`Chronicle/Info.plist` sets:

```
SUFeedURL = https://github.com/inxilpro/chronicle-gui/releases/latest/download/appcast.xml
```

GitHub's `releases/latest/download/<asset>` URL always redirects to the asset
on the **latest** release. This is the standard pattern for GitHub-hosted
Sparkle feeds, and it means each release's `appcast.xml` only ever needs to
describe the newest version — the release workflow generates the appcast from
just the zip it built, with enclosure URLs pointing at that tag's release
assets. There is no cumulative feed to maintain.

Consequences to be aware of:

- Marking an older release as "latest" in the GitHub UI would serve its
  (older) appcast; don't do that.
- Pre-releases are not "latest", so a prerelease tag will not be offered to
  users automatically.

## Cutting a release

1. Make sure `main` is green (CI runs `swift test` and an unsigned app build).
2. Choose the next version. The tag is the single source of truth: the
   workflow strips the `v` and overrides both `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` with it, so versions must be strictly increasing
   `X.Y.Z` for Sparkle's comparisons to work.
3. Tag and push:

   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```

4. Watch the Release workflow. On success the GitHub Release for the tag
   contains `Chronicle-X.Y.Z.dmg`, `Chronicle-X.Y.Z.zip`, and `appcast.xml`.

## Verifying the update path end-to-end

Do this at least once after the initial setup, and any time signing or feed
configuration changes:

1. Download the DMG from the release and install the app into `/Applications`.
   Launch it — Gatekeeper should show no warnings (notarized and stapled).
2. Spot-check locally:

   ```sh
   codesign --verify --deep --strict --verbose=2 /Applications/Chronicle.app
   spctl -a -t exec -vv /Applications/Chronicle.app
   curl -sL https://github.com/inxilpro/chronicle-gui/releases/latest/download/appcast.xml
   ```

   The appcast should describe the released version, and its
   `sparkle:edSignature` should be present on the zip enclosure.
3. Cut a second release with a higher version (a throwaway `v1.0.1` is fine).
4. In the installed (older) app, use **Check for Updates…**. Sparkle should
   offer the new version, download the zip, verify the EdDSA signature against
   `SUPublicEDKey`, install, and relaunch.
5. Confirm the relaunched app reports the new version in About.

If Sparkle reports a signature error, the `SUPublicEDKey` in the shipped app
does not match the `SPARKLE_PRIVATE_KEY` secret used to sign the appcast —
re-check step 1 of the one-time setup.
