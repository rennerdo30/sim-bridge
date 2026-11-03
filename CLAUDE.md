# Sim Bridge

One Flutter app for iOS, Android, macOS, Windows, and Linux plus a Node relay. Android can
expose its physical SIM as an SMS/call gateway; the other platforms are clients. All content
is end-to-end encrypted with AES-256-GCM under a locally generated 256-bit root key exchanged
by QR invitation or recovery code. The relay must never read message bodies, phone numbers,
SIM details, or command contents.

## Layout

- `app/lib/main.dart` contains bootstrap and MaterialApp wiring.
- `app/lib/theme.dart` defines `Palette`, `Fonts`, `Corners`, `simShape()`, and `BrandMark`.
- `app/lib/widgets.dart` contains presentational widgets with text passed in by callers.
- `app/lib/bridge_page.dart` owns visible session/read sync and the client UI.
- `app/lib/session_store.dart` owns pairing metadata and platform secure credentials.
- `app/lib/gateway_runtime.dart` is the sole gateway executor, owned by Android's service.
- `app/lib/api.dart`, `security.dart`, and `protocol.dart` implement relay access and encryption.
- `app/lib/platform_support.dart` describes platform capabilities; desktop is client-only.
- `app/lib/l10n/` contains English/German ARB files and generated localizations.
- `app/android/` owns native SMS/call/SIM integration through `app.simbridge/sms`.
- `app/ios/` owns the app and encrypted APNs notification service extension.
- `app/macos`, `windows`, and `linux` contain the native desktop runners.
- `server/` contains the relay core (`src/relay.mjs`), its Node host (`server.mjs`), its
  Cloudflare Worker/Durable Object host (`worker.mjs`, `wrangler.jsonc`), volatile in-memory
  SQLite (better-sqlite3 on Node, sql.js on Workers), and the owner dashboard. Run
  `npm test`, `npm run test:wasm` and `npm run test:worker`; the Durable Object must never
  call its storage API.

## Commands and isolation

Run app commands from `app/`:

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter gen-l10n
flutter run -d <device>
```

The relay requires Node 22+; development and CI use Node 22 LTS from `server/.nvmrc`.
Run `npm ci` and `npm test` from `server/`. Starting the relay requires an owner access key in
`SIM_BRIDGE_ACCESS_KEY`; see `server/README.md`. Android Kotlin tests need JDK 17.
Use `app/tool/desktop_smoke_relay.mjs` only with an isolated test configuration.

Tests must never use live paired state. Node suites use isolated in-memory databases and
verify legacy database/log paths are never written. Never point a test or probe at
`server/data/sim-bridge.sqlite` or the live relay on port 8787. Use a separate port and
disposable credentials.
Never commit databases, logs, `.env` files, signing keys, profiles, or local account settings.

## Design and conventions

The visual language follows the SIM card. Use `simShape()` for SIM/identity surfaces and quiet
rounded `Corners.card` content cards. Keep the porcelain, board-green, and restrained gold
palette in `Palette`; add shared tokens rather than ad-hoc colors. Use Bricolage for headings,
the platform body face, and JetBrainsMono for data such as numbers, codes, URLs, and latency.
Buttons and snackbars share the small beveled geometry.

Every user-facing string belongs in the English/German ARB files. Use placeholders and plurals
rather than concatenated fragments. Map new platform/relay errors to localized error codes.
Keep shared widgets presentational, named constants centralized, and relay SQL prepared.
Refactors must preserve authenticated event sync, gateway execution, method-channel contracts,
and shared storage keys for existing paired installations. Run analysis and relevant tests
before commits.

## Security invariants

The security and protocol tests protect these constraints; investigate a failure before
changing a test expectation.

- Root keys and device tokens belong only in platform secure storage. Never log them, send
  a root key to the relay, or include credentials in mDNS TXT records.
- Never log message bodies, phone numbers, or OTPs. Use fixed operational relay diagnostics
  without device/IP identifiers and local number redaction helpers. Release builds must not
  ship working owner credentials.
- Uploaded content goes through `Session.crypto.seal(...)`. Every command carries bridge,
  sender, target, unique command ID, and issue time inside the sealed plaintext. The gateway
  validates all bindings, freshness, and replay history before hardware side effects.
- Gateway events are bound with `bindEvent`. Trust sealed `occurredAt` and `senderDeviceId`;
  relay receipt time is display-only and must not control notification watermarks.
- Relay URLs pass `isSafeRelayUrl`: HTTPS except permitted private/LAN hosts.
- `smsGateway` is immutable after enrollment and enforced by the relay. Clients cannot
  self-assign gateway authority or publish authoritative incoming gateway messages.
- Enrollment verifiers and bearer tokens are SHA-256 hashed in volatile relay memory.
  Owner credentials authorize bridge creation/admin only and must never appear in invitations.
- Keep local Host validation, no wildcard CORS, auth rate limits, and queue retention caps.
  Return generic client failures; use fixed operational diagnostics without exception text
  or request/device identifiers.
- Android backup/extraction is disabled because native queues hold plaintext. Scope cleartext
  network access to LAN. Dial/send methods reject non-plain numbers and MMI/USSD sequences.
- Keep `FLAG_SECURE` enabled around key-bearing pairing surfaces. Call controls act only on
  the exact bound call ID, never an arbitrary current call.

## Session and Android gateway lifecycle

`PersistentGatewayService` owns the headless `gatewayMain` engine. The visible app reads
messages, roster, and status; `GatewayRuntime` alone uploads durable native SQLite events
and executes commands. Persist stable event IDs before waking the service. Acknowledge an
event locally only after upload succeeds; retry the same opaque `uploadId`, with server-side
deduplication independent of message pruning.

Save pairing credentials/metadata before native enable/start. Restore preserves existing
queues. Replacement enrollment stops the old worker and clears previous-owner content before
saving a new identity. Leaving first obtains gateway-confirmed durable revocation while
the worker can still commit policy. Only then disable recovery, await quiescence, clear
the outbox, and delete credentials. Failed/pending removal preserves local pairing and
journals and must not be described as permanent revocation. Partial/unavailable stored pairing remains on disk and
blocks replacement. Claim command journal entries before side effects. A crash or missing
carrier confirmation reports an unknown outcome and must never automatically resend an SMS.

Event-stream reconnects back off and receiver/network wake can retry promptly. Readiness distinguishes
service state, relay connectivity, each required permission, battery restrictions, and unknown
checks. Derive runtime freshness from monotonic ages; wall-clock timestamps are display-only.
OEM autostart is a manual user report, not an app-verifiable grant. Explicit stop disables
recovery; force-stop needs user reopening. Preserve the singleton worker during watchdog,
boot, service restart, and UI attachment.

## Sync and notifications

Use authenticated event streams to trigger inbox, roster and addressed-command catch-up.
Fetch messages after `_lastMessageSeq` and accumulate/decrypt only new records. Coalesce
work without dropping changes received during a fetch. Heartbeats update liveness without
fetching. Publish gateway capability snapshots only when changed. Relay application state
is memory-only, with short-lived ciphertext queues. Durable authorization belongs to the
Android gateway. Restart recovery preserves identities and journals, waits for gateway
bootstrap, and never silently creates/joins again. Read PAIRING-RECOVERY-PROTOCOL.md;
permanent authorization changes require durable gateway commit before success.
Preserve device-side journals and do not add periodic network polling.

Android authorization writes must wait for the native disk barrier before a signed
policy ACK. Readback alone proves only preference-cache visibility. The barrier is
coupled to the locked flutter_secure_storage 11 default encrypted-data, wrapped-key,
and configuration preference names; re-audit those names and commit semantics when
upgrading that dependency. Disable destructive reset-on-storage-error behavior.
Keep policy/recovery writers quiescent before deleting credentials on Leave.

On iOS retain the notification-center delegate assignment before `super` launch. APNs carries
an encrypted preview; NotificationService decrypts it from the shared notification Keychain
group. APNs credentials stay outside the repository. Match `SIM_BRIDGE_PUSH_ENVIRONMENT` to
the signed `aps-environment` entitlement. Use the decrypted gateway event ID to deduplicate
remote/local notification paths. Permission is measured through native checks, shown in
Settings, and required before reporting a notification test as successful.

Preserve UIScene configuration with `FlutterSceneDelegate` and Main storyboard. Register plugins
and custom channels in `FlutterImplicitEngineDelegate.didInitializeImplicitFlutterEngine`.
The iOS app and notification extension must inherit matching build names/numbers. Verify the
complete signed app with `codesign --verify --deep --strict`; prefer correct rebuilding to manual
re-signing, and never select an arbitrary first identity. Clipboard delivery does not establish
native Messages OTP AutoFill; review current SDK/extension requirements before promising it.

## Desktop and CI

Desktop joins by manual relay URL/recovery code, reads messages, and routes SMS/call controls
through Android. Do not show gateway setup, offer desktop scanning, call Android channels,
or imply carrier audio or desktop APNs/FCM wake-up. The native window starts at 1180×800 with
a 760×600 minimum. Closing the last window quits; minimizing or macOS Hide leaves event sync
available while the process runs. Preserve native window controls and menus.

Both macOS entitlement files retain sandbox and client/server networking for Bonjour. Declare
`_simbridge._tcp` and local-network purpose in Info.plist. Secure storage uses the classic login
Keychain with a desktop-specific service; Data Protection Keychain sharing requires a compatible
profile and is not enabled. Preserve the macOS notification plugin's foreground delegate.
The clipboard channel supports `copyCode` with `{code: String}`, `copySensitive` with
`{text: String}`, and notification settings. Sensitive copies use advisory transient/concealed
markers and ownership-aware cleanup after 180 seconds or normal quit. Do not claim iOS-style
Universal Clipboard exclusion. Desktop automatic copying defaults off and is opt-in.

Tracked signing defaults are ad-hoc/empty team. Optional local signing lives in gitignored
`macos/Runner/Configs/LocalSigning.xcconfig`, never in committed owner credentials.
`tool/build_macos_desktop.sh --ci` configures Flutter then builds with explicit ad-hoc xcodebuild
overrides while retaining sandbox entitlements. CI app/DMG outputs are isolated from owner
artifacts. Default host architecture avoids Flutter 3.38/Xcode multi-arch lipo verification
incompatibility; command-line `ARCHS` can override it with compatible tooling.

`.github/workflows/desktop.yml` builds macOS arm64/Intel, Windows x64, and Linux x64 with pinned
Flutter 3.38.6 and the committed lockfile. Each job runs analysis and unit/widget tests and
uploads the complete runnable bundle/checksum. These are development artifacts, with no store
uploads or notarization. Windows/Linux intentionally disable the unused transitive Android JNI
package's desktop JVM discovery. The arm64 CI-style path passed locally under `CI=true`:
strict ad-hoc signature verification, no signing team, retained sandbox/network entitlements,
all three font notice assets, and a complete DMG/checksum. Hosted GitHub jobs were triggered but blocked before execution by account billing;
Windows/Linux/Intel native builds remain unverified. Record actual CI/build/runtime evidence; workflow source alone does
not prove native platform execution. Build/package details are in `app/README.md`.

Linux Bonjour discovery needs Avahi on system D-Bus; no Avahi C++ build headers are required.
Keep manual relay URL entry available when discovery fails. Credential storage independently
needs a running/unlocked session Secret Service, and notifications need a desktop notification
service. Do not treat discovery availability as proof of secure-storage readiness.

Icons come from `app/assets/sim_bridge_icon.svg`. Mobile and desktop generators are separate;
never run a broad `flutter create .` over existing mobile/native changes.

## Deployment boundaries

Preparing source, tests, and build artifacts does not authorize installing on live phones,
restarting a paired relay, publishing a repository, or uploading to stores. Deploy to explicitly
authorized targets only. For a protocol change, coordinate compatible gateway/client builds;
report build, signature, install, launch, pairing, and message delivery as separate evidence.
Retain existing paired state and respect platform restrictions such as locked-device launch.
Private device identifiers, network addresses, installed-build journals, and owner signing
notes belong in ignored `LOCAL-DEVELOPMENT.md`, not public repository guidance.

## Website, releases and store media

MIT licensing is selected; retain font/dependency notices. The public site is served from
GitHub Pages at `https://sim-bridge.renner.dev`: `website/` is the static homepage at `/`, and
`docs/` (Astro Starlight/Galaxy, locked Node dependencies) builds the documentation under
`/docs/`. Privacy/terms pages must reflect the actual relay operator model. The support contact
is `support@renner.dev`.

Documentation and store screenshots are production-widget renders with isolated synthetic
preferences, credentials, native channels and encrypted HTTP fixtures, not native-device
captures. Regenerate them with `test/support/documentation_capture.dart` and
`test/support/store_capture.dart` plus `tool/store_media.py`; never capture live content.

A matching immutable SemVer tag invokes release staging. Package hashes and the tag commit are
verified before a release is created. Never describe ad-hoc/unsigned development bundles as
notarized or store-signed. No signing keys belong in GitHub Actions. Store listings,
compliance worksheets and publisher inputs live in a separate private repository, not here.
Store uploads and live-phone installations require separately authorized scope.
