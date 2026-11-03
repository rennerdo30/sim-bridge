#!/usr/bin/env python3
"""Render desktop icons from the shared SVG; never modifies mobile assets.

Requires rsvg-convert and Pillow. Run from any directory.
"""
import io
import json
from pathlib import Path
import shutil
import subprocess

from PIL import Image

APP = Path(__file__).resolve().parents[1]
MASTER = APP / 'assets/sim_bridge_icon.svg'
MACOS = APP / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'


def render(size):
    png = subprocess.check_output([
        'rsvg-convert', '--width', str(size), '--height', str(size), str(MASTER),
    ])
    image = Image.open(io.BytesIO(png)).convert('RGBA')
    assert image.size == (size, size)
    assert image.getchannel('A').getextrema() == (255, 255)
    return image


def main():
    if not shutil.which('rsvg-convert'):
        raise SystemExit('Install rsvg-convert before generating icons')
    assets = {}
    for entry in json.loads((MACOS / 'Contents.json').read_text())['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        assets[entry['filename']] = size
    for filename, size in assets.items():
        render(size).convert('RGB').save(MACOS / filename, format='PNG')
    windows = APP / 'windows/runner/resources/app_icon.ico'
    windows.parent.mkdir(parents=True, exist_ok=True)
    render(256).save(windows, format='ICO', sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
    linux = APP / 'linux/resources/sim-bridge.png'
    linux.parent.mkdir(parents=True, exist_ok=True)
    render(256).convert('RGB').save(linux, format='PNG')
    print(f'Generated {len(assets)} macOS PNG icons, Windows ICO, and Linux PNG.')


if __name__ == '__main__':
    main()
