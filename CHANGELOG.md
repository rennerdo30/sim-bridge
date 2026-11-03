# Changelog

## 1.2.0 (in preparation)

- Android gateway no longer asks to become the default phone app, as Google Play requires a
  full dialer for that role. Calls are still started from paired devices, and paired devices
  still see when the gateway rings, answers and hangs up; the caller's number is not shown, and
  calls can no longer be declined or ended from another device.
- Android store build: signed with the Play upload key, target API 36, 16 KB page-size aligned.
- iOS privacy manifests for the app and its notification extension.

## 1.1.1

- Windows installer: Sim Bridge artwork and icon, a page to choose the install folder (it must
  be empty or an existing Sim Bridge folder you can write to, so uninstalling never removes
  anything else), and clearer welcome and finish texts in English and German.
- Windows: the native title bar and caption buttons now use the app's light colours instead of
  a dark bar in system dark mode.
- About Sim Bridge, available everywhere including before pairing: version, check for updates,
  automatic updates, website, source code, privacy and all licenses.
- Copies installed by the renner.dev launcher leave updates to the launcher
  (`--managed-updates`, or detected from the launcher's install folder).
- Update checks keep working when the GitHub API rate-limits a shared network.

## 1.1.0

- Windows installer: `Sim-Bridge-<version>-windows-x64-setup.exe` installs Sim Bridge for your
  account without administrator rights, adds a Start menu entry and an uninstaller, and keeps
  your pairing and settings across updates. The portable zip remains available.
- Automatic updates on the desktop: Sim Bridge checks for a new release once a day (switchable
  under Settings → Updates, with Check now) and verifies every download against the release
  checksums. Windows installs the update and restarts; macOS and Linux save the verified new
  version in your Downloads folder.
- Linux packages are portable zips.

Updating from 1.0.0 is a one-time manual install; later versions arrive through the updater.

## 1.0.0

First public release.

- Android gateway: forwards incoming SMS and call activity, sends SMS and places calls on the
  chosen SIM, survives restarts, and never resends an SMS after a crash or a lost confirmation.
- Clients for iOS, iPadOS, Android, macOS, Windows and Linux with a shared design, tablet and
  desktop layouts, keyboard shortcuts on desktop, and English and German text.
- End-to-end encryption with AES-256-GCM under a 256-bit bridge key created on the gateway and
  shared by QR code or 52-character recovery code. Commands are bound to bridge, sender and
  target and refused when replayed or stale.
- Relay that keeps all state in memory, writes nothing to disk, and syncs clients through
  authenticated event streams without polling. Runs on Node.js, in Docker behind a tunnel, or on
  Cloudflare Workers with a RAM-only Durable Object.
- Pairing recovery: after a relay restart the Android gateway restores authorization and
  clients keep their identities.
- Sensitive clipboard handling for verification codes and recovery codes on every platform.
- Encrypted push previews on iOS through a notification service extension.

Desktop packages are not yet notarized or publisher-signed. Store releases for Android and iOS
are in preparation.
