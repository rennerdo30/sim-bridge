# Native desktop smoke test

Run this test explicitly on a macOS host. Ordinary `flutter test` runs the unit/widget suites;
it does not establish native Keychain, native UI, or other operating-system behavior.

Start the portable fixture in one terminal from the repository root:

```sh
node app/tool/desktop_smoke_relay.mjs
```

It creates its own memory-only relay, automatically publishes encrypted synthetic SIM
state and an incoming SMS, and prints `READY` before accepting optional `sms`, `roster`,
`commands`, or `quit` input. `quit`, Ctrl-C, SIGTERM, or stdin EOF stops its relay child and
discards volatile relay data. The helper resolves the server relative to itself and refuses an
occupied port rather than connecting to an existing relay.

In a second terminal:

```sh
cd app
flutter pub get
flutter drive --profile -d macos --target=integration_test/desktop_smoke_test.dart \
  --driver=test_driver/desktop_smoke_driver.dart --no-pub
```

The local Xcode 27 / Flutter 3.38 combination exposes only an `arm64e` debug destination,
while Flutter requests `arm64`. The profile driver uses the generic macOS build path and
retains the VM service required by the integration driver. On compatible SDKs,
`flutter test integration_test/desktop_smoke_test.dart -d macos --no-pub` is also supported.

The fixture uses `http://127.0.0.1:18798` and a synthetic bridge whose root key is 32 zero
bytes; its manual recovery code is 52 zero digits. It contains no real SIM or credentials
and does not inherit operator APNs, TLS, database, access-key, or logging settings. Never
point a fixture at `server/data/sim-bridge.sqlite` or the live relay on port 8787.
For another disposable loopback port, start the helper with `SIM_BRIDGE_SMOKE_PORT=<port>`
and add `--dart-define=SIM_BRIDGE_SMOKE_RELAY=http://127.0.0.1:<port>` to the Flutter command.
Both reject port 8787; the integration test also rejects non-loopback hosts.

The test uses real platform plugins. It writes, reloads through a new storage object, and
deletes credentials under `dev.renner.simbridge.desktop.smoke.credentials`, using the app's
macOS Keychain policy. Keep the committed `flutter_secure_storage_darwin` 0.4.3 lock entry:
older versions before 0.4.2 issue unsupported synchronizable queries during native delete
and existence checks with the classic macOS Keychain. It never changes the app's regular credential service or preferences.
It enrolls a desktop client with gateway capabilities disabled, decrypts the fixture's events,
then submits an encrypted command to a separate relay-only synthetic gateway. That target has
no native worker or hardware: the test checks the stored command's sealed bindings and payload,
acknowledges it, and revokes both test enrollments in cleanup.

The client and synthetic target also establish real header-authenticated event streams.
The test verifies initial readiness, a new encrypted-message hint, a command hint reaching
only its target, and terminal HTTP 401 after client revocation. The fixture republishes
encrypted SIM state on attachment changes and never polls for presence. If building takes
longer than the five-minute message buffer, enter `sms` in the fixture terminal before
running the test against the cached build.

A passing run establishes native Keychain access and encrypted REST/event-stream roundtrips on that Mac.
It does not establish delivery of a real SMS, visible OS notifications, pairing UI operation,
or a second-process Keychain restoration. Windows and Linux need their own native verification.
The command builds a profile test runner; retain the separately verified release bundle for
packaging.
