#!/usr/bin/env python3
"""Record documentation captures after rendering; requires Pillow."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parents[2]
folder = root / 'docs/public/screenshots'
sources = [
    'app/test/support/documentation_capture.dart', 'app/lib/bridge_page.dart',
    'app/lib/theme.dart', 'app/lib/l10n/app_en.arb', 'app/pubspec.lock',
]
manifest = {
    'format': 1,
    'purpose': 'documentation preview; not store media',
    'captureType': 'production Flutter widgets with synthetic in-memory data',
    'nativeDeviceCapture': False,
    'locale': 'en-US', 'flutter': '3.38.6',
    'bodyFont': 'Flutter SDK Roboto; native system typography may differ',
    'capturedUtc': datetime.now(timezone.utc).isoformat(),
    'sourceDigests': {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sources},
    'images': [],
}
for path in sorted(folder.glob('*.png')):
    with Image.open(path) as image:
        image.load()
        manifest['images'].append({
            'path': path.relative_to(root).as_posix(),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'bytes': path.stat().st_size,
            'width': image.width, 'height': image.height,
            'format': image.format, 'mode': image.mode,
        })
if len(manifest['images']) != 5:
    raise SystemExit('Expected exactly the five documentation captures.')
(folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Recorded five fully decoded documentation captures.')
