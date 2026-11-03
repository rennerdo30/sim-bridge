# Documentation UI captures

Run from `app/` with the project’s pinned Flutter SDK:

```sh
FLUTTER_ROOT=/path/to/flutter flutter test test/support/documentation_capture.dart --no-pub --reporter expanded
python3 tool/screenshot_manifest.py  # requires Pillow
```

`FLUTTER_ROOT` points to the SDK, not a credential. The harness loads the actual bundled display/mono fonts, the SDK’s Roboto body fonts and Material Icons, then captures production `BridgePage` widgets into PNG. Desktop captures use a 1180×800 logical viewport at 2×; mobile uses 390×844 at 3×. English locale is explicit. This is a widget-render capture without OS chrome, physical device or native notifications. Body typography uses Roboto for reproducible test rendering; native system typography can differ.

Preferences and secure storage are replaced with in-memory mocks. HTTP returns only synthetic encrypted fixture messages/roster; no actual relay is contacted. Notification and discovery channels are mocked. Example telephone numbers are from the fictional +1 202-555-01xx range, the relay domain is example.com, and the demonstration key/token are disposable fixtures. No live SMS, user identity, clipboard, paired state, or physical SIM is used.

Outputs under `docs/public/screenshots/` show inbox, device roster, settings, onboarding, and mobile inbox. `manifest.json` records actual image dimensions/format, file SHA-256, source file digests, locale, renderer, fixture provenance, and capture time. Captures should be regenerated if relevant source/fonts change.

These images are documentation previews. They are **not** native-device screenshots or uploaded store assets, do not demonstrate carrier delivery, and must not be indexed in the store contract as screenshots without the required native capture/equivalence evidence and an approved media review.
