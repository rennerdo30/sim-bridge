#!/usr/bin/env python3
"""Prepare store media candidates from the editable icon master and the widget renders.

Run from app/ after `flutter test test/support/store_capture.dart`:

    python3 tool/store_media.py

Writes into ../store/media-candidates/:
- every screenshot flattened to opaque RGB PNG (Apple and Play refuse alpha),
- google_play/_global/icon-512.png and feature-graphic.png (1024x500),
- renner_dev/_global/icon-256.png and icon-512.png (launcher list style: the mark
  centred on a full-bleed tile of the key colour, no text),
- manifest.json with each file's store slot, pixel size and SHA-256.

Requires rsvg-convert and Pillow. Nothing here uploads anything; the maintainer decides which candidates become store assets.
"""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFont

APP = Path(__file__).resolve().parents[1]
OUT = APP.parent / 'store/media-candidates'
MASTER = APP / 'assets/sim_bridge_icon.svg'
FONT_BOLD = APP / 'assets/fonts/BricolageGrotesque-ExtraBold.ttf'
FONT_MONO = APP / 'assets/fonts/JetBrainsMono-Medium.ttf'
# Palette tokens from lib/theme.dart.
BOARD_TOP, BOARD_BOTTOM = (0x1E, 0x3A, 0x30), (0x0E, 0x1B, 0x16)
PORCELAIN = (0xF6, 0xF2, 0xEA)
CHIP = (0xD9, 0xA1, 0x3F)
HAZE = (0xB8, 0xC4, 0xBC)
FEATURE_SIZE = (1024, 500)
TAGLINES = {
    'en-US': ('Your SMS on every device.', 'End-to-end encrypted · your own relay'),
    'de-DE': ('Deine SMS auf jedem Gerät.', 'Ende-zu-Ende-verschlüsselt · eigenes Relay'),
}


def render_svg(size: int) -> Image.Image:
    png = subprocess.check_output(['rsvg-convert', '--width', str(size), '--height', str(size), str(MASTER)])
    image = Image.open(io.BytesIO(png)).convert('RGBA')
    if image.getchannel('A').getextrema() != (255, 255):
        raise SystemExit('The icon master must fill every pixel')
    return image.convert('RGB')


def render_mark(size: int) -> Image.Image:
    """The SIM mark alone, without its square background, for placement on art."""
    import re
    svg = re.sub(r'<rect id="background"[^>]*/>', '', MASTER.read_text(encoding='utf-8'))
    png = subprocess.run(['rsvg-convert', '--width', str(size), '--height', str(size)],
                         input=svg.encode('utf-8'), capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert('RGBA')


def gradient(size) -> Image.Image:
    width, height = size
    image = Image.new('RGB', size)
    draw = ImageDraw.Draw(image)
    for x in range(width):
        t = x / max(1, width - 1)
        draw.line([(x, 0), (x, height)], fill=tuple(round(a + (b - a) * t) for a, b in zip(BOARD_TOP, BOARD_BOTTOM)))
    return image


def feature_graphic(locale: str) -> Image.Image:
    image = gradient(FEATURE_SIZE)
    mark = render_mark(380)
    image.paste(mark, (40, 60), mask=mark.getchannel('A'))
    draw = ImageDraw.Draw(image)
    headline, subline = TAGLINES[locale]
    left, right = 410, FEATURE_SIZE[0] - 48

    def fitted(text, path, size):
        # Shrink until the line fits inside the right margin.
        while size > 12:
            font = ImageFont.truetype(str(path), size)
            if left + draw.textlength(text, font=font) <= right:
                return font
            size -= 1
        return ImageFont.truetype(str(path), size)

    draw.text((left, 130), 'Sim Bridge', font=fitted('Sim Bridge', FONT_BOLD, 74), fill=PORCELAIN)
    draw.text((left, 232), headline, font=fitted(headline, FONT_BOLD, 38), fill=CHIP)
    draw.text((left, 300), subline, font=fitted(subline, FONT_MONO, 22), fill=HAZE)
    return image


def save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format='PNG', optimize=True)


def main() -> None:
    if not shutil.which('rsvg-convert'):
        raise SystemExit('Install rsvg-convert first')
    screenshots = sorted(p for p in OUT.rglob('*.png') if '/_global/' not in p.as_posix())
    if not screenshots:
        raise SystemExit('Run flutter test test/support/store_capture.dart first')
    for path in screenshots:
        image = Image.open(path)
        if image.mode != 'RGB':
            background = Image.new('RGB', image.size, PORCELAIN)
            background.paste(image, mask=image.convert('RGBA').getchannel('A'))
            save(background, path)
    save(render_svg(512), OUT / 'google_play/_global/icon-512.png')
    for locale in TAGLINES:
        save(feature_graphic(locale), OUT / f'google_play/{locale}/feature-graphic.png')
    for size in (256, 512):
        save(render_svg(size), OUT / f'renner_dev/_global/icon-{size}.png')

    entries = []
    for path in sorted(OUT.rglob('*.png')):
        image = Image.open(path)
        if image.mode != 'RGB':
            raise SystemExit(f'{path} still has transparency')
        relative = path.relative_to(OUT).as_posix()
        store, scope, name = relative.split('/')
        entries.append({
            'path': f'store/media-candidates/{relative}',
            'store': store,
            'scope': scope,
            'slot': name.rsplit('-', 1)[0] if scope != '_global' else name.removesuffix('.png'),
            'width': image.width,
            'height': image.height,
            'format': 'PNG RGB',
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    (OUT / 'manifest.json').write_text(json.dumps({
        'kind': 'store-media-candidates',
        'source': 'Production Flutter widgets rendered by app/test/support/store_capture.dart '
                  'with synthetic fixtures; icons from app/assets/sim_bridge_icon.svg.',
        'status': 'candidate; owner media review pending',
        'files': entries,
    }, indent=2) + '\n', encoding='utf-8')
    print(f'Prepared {len(entries)} candidates in {OUT}')


if __name__ == '__main__':
    main()
