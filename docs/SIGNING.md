# Developer ID Signing Flow

This document covers the remaining production distribution path for Auditorium: creating a Developer ID signed, notarized app that Gatekeeper allows on a clean Mac.

Auditorium already has the packaging script and export options needed for this path:

- `script/package_release.sh`
- `config/ExportOptions-developer-id.plist`
- bundle identifier `co.charliewil.Auditorium`
- development team `824752FF3X`
- hardened runtime enabled

The repo script should be used instead of a raw Xcode export because it also builds and bundles `symphony` into:

```txt
Auditorium.app/Contents/Resources/bin/symphony
```

## 1. Create The Developer ID Certificate

In Xcode:

1. Open `Xcode` > `Settings...` > `Accounts`.
2. Select the Apple ID used for team `824752FF3X`.
3. Select the team.
4. Click `Manage Certificates...`.
5. Click `+`.
6. Choose `Developer ID Application`.

Verify the certificate is available locally:

```sh
security find-identity -v -p codesigning
```

The output must include a `Developer ID Application` identity. An `Apple Development` identity is not enough for clean-Mac distribution.

## 2. Create A Notary Profile

Create an Apple app-specific password, then store notary credentials locally:

```sh
xcrun notarytool store-credentials "Auditorium-notary" \
	--apple-id "YOUR_APPLE_ID_EMAIL" \
	--team-id 824752FF3X \
	--password "APP_SPECIFIC_PASSWORD"
```

The password must be an app-specific password, not the normal Apple ID password.

## 3. Build, Sign, Notarize, And Staple

Run:

```sh
NOTARYTOOL_PROFILE=Auditorium-notary ./script/package_release.sh --developer-id --notarize
```

The script will:

1. Build the Release app.
2. Build the Release `symphony` binary.
3. Archive and export using Developer ID signing.
4. Copy `symphony` into the app bundle.
5. Verify the code signature.
6. Zip the app.
7. Submit the zip to Apple notarization.
8. Staple the notarization ticket.
9. Validate Gatekeeper assessment.
10. Recreate `dist/Auditorium.zip`.

## 4. Local Verification

After the script succeeds, verify the exported app:

```sh
spctl -a -vv dist/export/Auditorium.app
codesign --verify --deep --strict --verbose=2 dist/export/Auditorium.app
open dist/export/Auditorium.app
```

`spctl` should accept the app, `codesign` should verify the bundle, and the app should launch.

## 5. Clean-Mac Verification

The final distribution proof requires a separate Mac that has not built Auditorium locally.

1. Copy `dist/Auditorium.zip` to the clean Mac.
2. Unzip it.
3. Launch `Auditorium.app`.
4. Confirm Gatekeeper allows launch.
5. Confirm the app opens and can show its first-run UI.

Only after this clean-Mac launch succeeds should the release build be treated as distribution-verified.

## Current Blocker

As of 2026-06-09, the local machine had an `Apple Development` signing identity but no `Developer ID Application` identity. That certificate is required before the Developer ID signing and notarization flow can be completed.
