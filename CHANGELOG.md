# Changelog

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
