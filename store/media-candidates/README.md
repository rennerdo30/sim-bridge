# Store media candidates

Screenshots and graphics prepared for App Store, Google Play and the renner.dev launcher.
They are **candidates** that still need the maintainer's review before they are used in a store listing.

| Store | Slot | Pixels | Locales |
| --- | --- | --- | --- |
| App Store | iPhone 6.9" (`iphone-6.9`) | 1320 × 2868 | en-US, de-DE |
| App Store | iPhone 6.3" (`iphone-6.3`) | 1206 × 2622 | en-US, de-DE |
| App Store | iPad 13" (`ipad-13`) | 2064 × 2752 | en-US, de-DE |
| Google Play | Phone screenshots | 1080 × 1920 | en-US, de-DE |
| Google Play | Icon / feature graphic | 512 × 512 / 1024 × 500 | global / en-US, de-DE |
| renner.dev | macOS and Windows window | 2360 × 1600 | en-US, de-DE |
| renner.dev | Launcher list icon | 256 × 256, 512 × 512 | global |

All screenshots are opaque RGB PNG. `manifest.json` lists every file with its size and SHA-256.

## How they are made

```sh
cd app
FLUTTER_ROOT=/path/to/flutter flutter test test/support/store_capture.dart --no-pub
python3 tool/store_media.py   # flatten, icons, feature graphics, manifest (rsvg-convert, Pillow)
```

The screenshots render the production `BridgePage` widgets at the exact store pixel size with
synthetic, in-memory data: fictional `+1 202-555-01xx` numbers, example names, a disposable key
and `relay.example.com`. No live relay, paired state, real message or SIM is used. Body text uses
Roboto from the Flutter SDK; native system typography differs slightly. Icons come from
`app/assets/sim_bridge_icon.svg`.

## Before they become store media

These are widget renders, not captures from a physical device or simulator. Review them for
each store, or replace them with native captures. Regenerate after any visible UI change.
