# Sim Bridge app

Flutter client for iOS, Android, macOS, Windows, and Linux. Android can also serve as the
physical SIM gateway. Desktop clients pair by relay URL and recovery code, then request SMS
and call controls through a paired Android gateway. See the [project README](../README.md)
for relay setup, encryption, and operational limits.

## Develop and build

Run these commands from `app/`:

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos       # or windows / linux on that operating system
flutter build macos       # or windows / linux
```

Use Flutter 3.38.6 / Dart 3.10.7 or a compatible newer SDK. Desktop builds require the
matching host operating system; Flutter does not cross-build these targets from macOS.

- **macOS:** Xcode with command-line tools and CocoaPods. The deployment minimum is macOS
  12.0. Builds target the host architecture by default (Apple Silicon on this Mac);
  Intel sources remain supported, but an Intel build has not been verified. The bundle
  identifier is `dev.renner.simbridge.desktop`, separate from iOS.
  Release output: `build/macos/Build/Products/Release/Sim Bridge.app`. Debug/profile and
  release entitlements include client/server networking. Secure storage uses the classic
  login Keychain, with a desktop-specific service and the signed app's access controls;
  Data Protection Keychain sharing is not enabled because it requires a provisioning profile.
  Bonjour discovery requests local-network access.
- **Windows:** Visual Studio with Desktop development with C++, its Windows SDK, and C++ ATL
  libraries required by secure storage. Release output:
  `build/windows/x64/runner/Release/`; distribute the entire directory, including its DLLs
  and `data/`, rather than only `sim_bridge.exe`.
- **Linux:** Flutter's desktop compiler prerequisites (clang, CMake, Ninja, pkg-config, GTK3
  development headers) plus `libsecret-1-dev`. On Debian/Ubuntu:
  `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev`.
  The runtime needs `libsecret-1-0` and a running/unlocked Secret Service such as GNOME Keyring
  on session D-Bus for credential storage, plus a desktop notification service. Relay discovery
  separately needs `avahi-daemon` available on system D-Bus. If Avahi is unavailable, enter the
  relay URL manually; this does not remove the secure-storage requirement. Avahi development
  headers are not required to build the app. Release output: `build/linux/x64/release/bundle/`;
  distribute the whole bundle. A `.desktop` file and icon are included under `share/`;
  a distro package can install them under the standard applications/icon directories and
  must make `sim_bridge` available on `PATH` for that launcher entry.

Windows and Linux targets are provided as source and remain unverified on their native hosts.
A fresh checkout uses ad-hoc macOS signing and requires no owner certificate. Local owner
signing can be configured in the optional, gitignored
`macos/Runner/Configs/LocalSigning.xcconfig` with the actual installed `CODE_SIGN_IDENTITY`
and `DEVELOPMENT_TEAM`. The owner's existing local override retains Developer ID signing;
private certificates are never part of the repository.
Run `tool/build_macos_desktop.sh` from `app/` to build, verify the bundle signature, and
create `build/desktop/Sim-Bridge-macOS.dmg` containing the app and an Applications shortcut.
Use `tool/build_macos_desktop.sh --skip-build` to verify and package an existing release
bundle without rebuilding it. The script preserves the original app bundle. This local disk
image is not notarized;
notarization, Windows/Linux installers, and store packaging remain separate steps.

## GitHub desktop builds

[`.github/workflows/desktop.yml`](../.github/workflows/desktop.yml) runs on app changes in pushes
and pull requests, and through **Actions → Desktop builds → Run workflow**. Flutter is pinned
to 3.38.6 and dependencies are resolved from the committed lockfile. Each job runs analysis and
unit/widget tests before a native release build. Independent jobs cover:

| Runner | Target | Artifact contents |
| --- | --- | --- |
| `macos-15` | macOS arm64 | DMG containing `Sim Bridge.app` and an Applications shortcut |
| `macos-15-intel` | macOS x86_64 | DMG containing the Intel app and Applications shortcut |
| `windows-2022` | Windows x64 | ZIP of the full release directory, including DLLs and `data/` |
| `ubuntu-24.04` | Linux x64 | tar.gz of the full bundle, preserving executable permissions |

Download the matching artifact from a successful workflow run. Every package includes a
SHA-256 checksum and is retained for 30 days. Extract the Windows/Linux package as a whole
before launching `sim_bridge.exe` or `./sim_bridge`. The workflow does not upload to stores,
create GitHub releases, notarize macOS, or require signing secrets. GitHub execution remains
unverified until the project is published and the workflow has run on these native hosts.

The macOS CI helper is `tool/build_macos_desktop.sh --ci`. It uses Flutter's `--config-only`
configuration step followed by `xcodebuild` with explicit ad-hoc signing, empty team/profile,
and the host architecture. It preserves sandbox/network entitlements and classic Keychain
storage. CI output is isolated under `build/macos-ci/` and `build/desktop-ci/`, so it does not
overwrite the locally signed production app or DMG. CI packages are ad-hoc development builds
and are not notarized. The default script continues to use optional local signing overrides.

The arm64 CI path passed locally with `CI=true`: the ad-hoc app passed strict signature
verification with no signing team, retained sandbox/client/server network entitlements, and
contained all three font notice assets. Its complete DMG and checksum were generated. This
validates the local CI-style build; GitHub execution and Windows/Linux/Intel builds remain
unverified.

## Current verification

Build `1.0.0+5` (before 1.0.0+6) produced an arm64 macOS release with strict Developer ID signature verification
with the local owner certificate. Its 10 MB `build/desktop/Sim-Bridge-macOS.dmg` passed checksum
verification. Onboarding and the recovery dialog rendered, and native quit behavior worked.
The 57 unit/widget tests passed and `flutter analyze` was clean.

Two native macOS profile integration checks passed with `flutter_secure_storage_darwin 0.4.3`:
real OS classic Keychain write/read/delete under an isolated service, and an encrypted client
flow against a scratch Node relay on port 18798. The relay confirmed client gateway capability
was false; simulated SIM/SMS events were decrypted, and `send_sms` was queued, decrypted,
completed, then enrollment revoked. No carrier hardware or live relay on port 8787 was used.

The profile integration was rerun successfully on 13 October 2026 after the memory-only
relay/event-sync changes. Real authenticated event streams delivered readiness, a new
encrypted-message signal and a command signal only to its addressed synthetic gateway;
client revocation closed the stream and a reconnect received terminal HTTP 401. The two
functional native checks passed, the profile bundle passed strict/deep signature checks,
and the scratch relay was stopped. This verifies local macOS transport/Keychain behavior,
not carrier delivery, background iPhone notifications, or Windows/Linux runtime behavior.

The UI automation tool failed text entry with `noWindowsAvailable`. Keyboard-driven pairing,
session restoration in a second process, and native notification delivery remain unverified.
Windows, Linux, and Intel macOS builds remain unverified.

## Desktop behavior

The native window starts at 1180×800 with a minimum of 760×600. Standard native window controls
and the macOS application/edit/window menus are retained. Closing the last window quits;
minimizing or macOS Hide keeps the process available for event sync. There is no tray service,
autostart registration, or desktop push wake-up. Notifications depend on the running app,
OS permission, and notification service. Desktop pairing uses manual recovery codes, with
no camera permission or QR scanner.

macOS implements the existing `app.simbridge/clipboard` channel's `copyCode`,
`copySensitive`, and `openNotificationSettings` methods. Copied sensitive text uses advisory
transient/concealed pasteboard markers, with ownership-aware cleanup after 180 seconds. It cannot promise the iOS
`localOnly` behavior on macOS. Windows/Linux use standard Flutter clipboard copying.
Automatic copying of incoming codes defaults off on desktop. Enabling it in Settings allows
new incoming codes to replace the clipboard, so leave it off for manual copying.

## Launcher icons

`assets/sim_bridge_icon.svg` is the shared editable master. From the repository root run:

```sh
python3 app/tool/generate_desktop_icons.py
```

This requires `rsvg-convert` and Pillow and updates only desktop assets: the macOS AppIcon
catalog, Windows multi-size ICO, and Linux PNG. The mobile generator remains independent.

## Optional Wi-Fi ADB helper

`tool/connect_gateway_adb.sh HOST:PORT` connects to an authorized Android phone on your private
LAN. `--usb SERIAL` discovers that USB phone's WLAN address; `--enable` explicitly enables its
ADB TCP listener. To keep a local default, set `SIM_BRIDGE_GATEWAY_ADB` or place one private
`HOST:PORT` line in ignored `tool/.gateway-adb`. A fresh clone has no built-in phone address.
The helper retries at most five times and does not configure ongoing polling or phone recovery.
