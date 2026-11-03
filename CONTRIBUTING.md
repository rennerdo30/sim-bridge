# Contributing to Sim Bridge

Read the [project overview](README.md), [app build notes](app/README.md), and
[relay documentation](server/README.md) before changing the corresponding component.
Keep changes focused and describe their behavior, validation, and remaining limitations
in the pull request.

## Local checks

Use the Flutter SDK version pinned in the desktop workflow, Node.js 22 LTS as pinned
in [server/.nvmrc](server/.nvmrc), and the committed dependency lockfiles.
Native builds require the matching host operating system and its toolchain; see the
app build notes for Xcode, Visual Studio C++/ATL, and Linux GTK/libsecret prerequisites.

From `app/`:

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
```

From `server/`:

```sh
npm ci
npm test
```

For Android native changes, set `JAVA_HOME` to a JDK 17 installation and run from
`app/android/`:

```sh
./gradlew :app:testDebugUnitTest
```

Use `gradlew.bat :app:testDebugUnitTest` in Windows Command Prompt. Regenerate Flutter
localizations with `flutter gen-l10n` from `app/` after editing the ARB sources.
Run the checks relevant to the change and report any checks that could not run.

Tests must use synthetic data, disposable loopback ports, and isolated in-memory relay state.
Run them without operator `SIM_BRIDGE_*` settings or live APNs/TLS credentials; do not
load `server/.env.local`. Never run tests or probes against port 8787 or
`server/data/sim-bridge.sqlite`: those may belong to a paired, operating gateway.
The optional [native desktop smoke test](app/integration_test/README.md) supplies an
isolated relay fixture and documents its macOS commands and limits.

## Change conventions

- Keep bridge keys, device tokens, SMS bodies, phone numbers, verification codes, and
  SIM details out of relay plaintext, logs, issues, and screenshots. Preserve sealed
  sender/target bindings, command freshness, replay protection, and upload deduplication.
- Put app-facing strings in both English and German ARB files; use placeholders and
  plurals rather than concatenating translated fragments. Follow the existing design
  tokens and presentational widget conventions.
- Keep signing keys, APNs keys, provisioning material, local configuration, device
  identifiers, and relay databases outside source control. Use synthetic examples in
  documentation and reports.
- Update documentation when behavior or setup changes. Retain bundled third-party
  license notices when replacing or packaging assets.

## Desktop CI artifacts

The [desktop workflow](.github/workflows/desktop.yml) builds on native macOS, Windows,
and Linux runners and uploads complete application bundles with SHA-256 checksums.
Preserve the whole Windows/Linux bundle, including its libraries and Flutter assets.
CI artifacts are development builds; release signing, notarization, installers, and
store distribution require separate configuration and verification.

A successful build or unit test does not verify native secure storage, visible
notifications, device pairing, or carrier SMS delivery. Record native runtime evidence
separately. Mobile installation and live gateway operations require an explicitly
authorized device workflow.

## Documentation and release preparation

From `docs/`, run `npm ci` and `npm run build`. Use the pinned Node version in `docs/.nvmrc`.
The homepage in `website/` is plain HTML and CSS; the documentation build copies it to the site root.
[RELEASING.md](RELEASING.md) describes the version and tag gates for releases.
Store screenshots are generated from the production widgets with synthetic data; see
[store/media-candidates/README.md](store/media-candidates/README.md).

The exact MIT notice is included in the Flutter asset bundle at `assets/licenses/SimBridge-MIT.txt`;
keep it byte-identical to root `LICENSE`. The release-preparation workflow checks this and the
package integrity rejection gates. Never add production store/signing credentials to CI.
