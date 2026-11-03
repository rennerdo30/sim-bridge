# Releasing

## Version

Set `version` in `app/pubspec.yaml` (`MAJOR.MINOR.PATCH+BUILD`) and add a `CHANGELOG.md` entry.
The release tag is `vMAJOR.MINOR.PATCH` and must match the pubspec version without its build
number. Store builds need a build number higher than any previously uploaded one.

## Checks

```sh
cd app && flutter pub get --enforce-lockfile && flutter analyze && flutter test
cd ../server && npm ci && npm test && npm run test:wasm && npm run test:worker
cd ../docs && npm ci && npm run build
```

## Desktop packages

| Platform | Asset | Notes |
| --- | --- | --- |
| macOS (Apple silicon) | `Sim-Bridge-<version>-macos-arm64.zip` | The `.app` bundle; Developer ID signing and notarization when available |
| Windows x64 | `Sim-Bridge-<version>-windows-x64-setup.exe` | Per-user NSIS installer (`app/windows/installer/sim-bridge.nsi`); the in-app updater runs it silently |
| Windows x64 | `Sim-Bridge-<version>-windows-x64.zip` | Portable folder: `sim_bridge.exe` with its DLLs and `data/` |
| Linux x64 | `Sim-Bridge-<version>-linux-x64.zip` | Portable bundle; needs GTK 3 and a Secret Service. A `.tar.gz` may be added; the launcher installs zips |

Each release also carries `SHA256SUMS.txt`. The homepage download buttons and the renner.dev
launcher pick assets by these names, so keep them exact.

Builds run on native hosts: macOS with `app/tool/build_macos_desktop.sh`, Windows with
`flutter build windows --release`, Linux with `flutter build linux --release` (see
[app/README.md](app/README.md)). Package the complete bundle, not only the executable.

## Updates

Desktop builds check `releases/latest` of this repository once a day (switchable in
Settings, with **Check now**). They accept only assets of that release, from its own
`releases/download/` URLs, and verify each download against the release's
`SHA256SUMS.txt`. Windows installs the setup silently and restarts; macOS and Linux save the
verified package in Downloads. Drafts and prereleases are never offered, so publishing the
release is what ships an update.

## CI

The repository is public, so every workflow runs on GitHub-hosted runners. Never add a
self-hosted runner: pull requests from forks could run code on it. Pushing a `vX.Y.Z` tag runs
**Draft desktop release**: it builds all four desktop platforms from the tag, runs the app and
relay checks, verifies every package checksum, and creates a **draft** release with the
versioned zips and `SHA256SUMS.txt`.

CI cannot sign or notarize macOS builds, because signing identities never go into GitHub
Actions. Before publishing, replace the two macOS zips in the draft with Developer ID signed,
notarized and stapled builds made on a Mac, and update `SHA256SUMS.txt` to match.

## Publish

1. Push the tag and create the release with the assets and `SHA256SUMS.txt`, or review the
   staged draft.
2. Mark it as a stable release (not a prerelease) when it is ready for the website and the
   renner.dev launcher.
3. Never put signing keys or store credentials into GitHub Actions.
