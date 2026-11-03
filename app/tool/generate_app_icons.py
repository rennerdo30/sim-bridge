#!/usr/bin/env python3
"""Render launcher assets from the editable SVG. Requires rsvg-convert and Pillow."""
import copy
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from PIL import Image

APP = Path(__file__).resolve().parents[1]
MASTER = APP / 'assets/sim_bridge_icon.svg'
IOS = APP / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
RES = APP / 'android/app/src/main/res'
BACKGROUND = '#1E3A30'  # The master board gradient's first color.
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
SVG_NS = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG_NS)


def render(source, destination, size, opaque):
    png = subprocess.check_output([
        'rsvg-convert', '--width', str(size), '--height', str(size), str(source),
    ])
    image = Image.open(io.BytesIO(png)).convert('RGBA')
    assert image.size == (size, size)
    if opaque:
        assert image.getchannel('A').getextrema() == (255, 255), 'Opaque icons must fill every pixel'
        image = image.convert('RGB')
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, format='PNG', optimize=False)


def main():
    if not shutil.which('rsvg-convert'):
        raise SystemExit('Install rsvg-convert before generating icons')
    root = ET.parse(MASTER).getroot()
    background = next(node for node in root if node.get('id') == 'background')
    board = next(node for node in root.iter() if node.get('id') == 'board')
    assert next(iter(board)).get('stop-color').upper() == BACKGROUND
    assert background.get('fill') == 'url(#board)'
    catalog = json.loads((IOS / 'Contents.json').read_text())
    assets = {}
    for entry in catalog['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        assets[entry['filename']] = size
    for filename, size in assets.items():
        render(MASTER, IOS / filename, size, opaque=True)
    foreground = copy.deepcopy(root)
    foreground.remove(next(node for node in foreground if node.get('id') == 'background'))
    mark = next(node for node in foreground if node.get('id') == 'sim-mark')
    # Android adaptive layers are 108dp; the protected center has a 66dp diameter.
    # The card's farthest corner is 455 master units from center. At scale .66
    # it is 300 units away, inside the 313-unit radius of that protected circle.
    mark.set('transform', 'translate(512 512) scale(0.66) translate(-512 -512)')
    with tempfile.TemporaryDirectory(prefix='sim-bridge-icons-') as temporary:
        source = Path(temporary) / 'foreground.svg'
        ET.ElementTree(foreground).write(source, encoding='utf-8', xml_declaration=True)
        for density, factor in DENSITIES.items():
            folder = RES / f'mipmap-{density}'
            render(MASTER, folder / 'ic_launcher.png', round(48 * factor), opaque=True)
            render(source, folder / 'ic_launcher_foreground.png', round(108 * factor), opaque=False)
    values = RES / 'values/ic_launcher_colors.xml'
    values.parent.mkdir(parents=True, exist_ok=True)
    values.write_text(f'<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">{BACKGROUND}</color>\n</resources>\n')
    adaptive = RES / 'mipmap-anydpi-v26/ic_launcher.xml'
    adaptive.parent.mkdir(parents=True, exist_ok=True)
    adaptive.write_text('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n    <background android:drawable="@color/ic_launcher_background" />\n    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n</adaptive-icon>\n')
    print(f'Generated {len(assets)} opaque iOS icons and launcher assets for {len(DENSITIES)} Android densities.')


if __name__ == '__main__':
    main()
