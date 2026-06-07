# Release, Signing, And Distribution

Auditorium v0 ships as a native macOS app plus the `symphony` Rust CLI.

## Release Build

The app has an Xcode `Release` configuration for the shared `Auditorium` scheme.

Local unsigned release smoke build:

```sh
xcodebuild build \
	-workspace Auditorium.xcworkspace \
	-scheme Auditorium \
	-configuration Release \
	-destination 'platform=macOS,arch=arm64' \
	CODE_SIGNING_ALLOWED=NO
```

CI builds both Debug and Release app configurations without signing so build regressions are caught without requiring Apple credentials.

## Signing Review

Current app target signing settings:

- Bundle identifier: `co.charliewil.Auditorium`
- Development team: `824752FF3X`
- Code signing style: Automatic
- Hardened Runtime: enabled
- App Sandbox: disabled
- Entitlements file: none

Hardened Runtime should remain enabled for Developer ID distribution and notarization.

## Sandbox And Security Policy

v0 uses a non-sandboxed Developer ID app policy.

Reason:

- The app launches local Git, GitHub CLI, Codex CLI, and `symphony` processes.
- The app creates deterministic local workspaces and reports outside its bundle.
- The app needs GitHub network access and Keychain-backed credentials.

Because v0 is not sandboxed, product safety is enforced through application policy:

- GitHub credentials live in Keychain, not SwiftData.
- Runtime and agent preflight runs before workspace creation.
- Settings expose network, filesystem, and pull-request confirmation controls.
- v0 never auto-merges pull requests.
- Reports, logs, and screenshots must not include secret material.

## Distribution And Notarization Plan

v0 distribution target is Developer ID outside the Mac App Store.

Release sequence:

1. Archive the app with the `Auditorium` scheme in Release.
2. Export a Developer ID signed `.app` or `.pkg`.
3. Verify signing and hardened runtime:

	```sh
	codesign -dvvv --entitlements :- path/to/Auditorium.app
	```

4. Submit for notarization with `notarytool`.
5. Staple the notarization ticket.
6. Validate Gatekeeper assessment:

	```sh
	spctl -a -vv path/to/Auditorium.app
	```

Final v0 acceptance still requires launching the signed, notarized build on a clean Mac.
