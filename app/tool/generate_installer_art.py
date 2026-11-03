#!/usr/bin/env python3
"""Render the Windows installer artwork from the editable icon master.

Writes app/windows/installer/art/:
- welcome.bmp (328x628): the welcome/finish page panel, 2x the 164x314 NSIS slot so it
  stays sharp on high-DPI screens,
- header.bmp (300x114): the inner-page header image, 2x the 150x57 slot,
- installer.ico: the setup and uninstaller icon, every Windows size as an uncompressed
  bitmap entry so Explorer shows it at all zoom levels.

Requires rsvg-convert and Pillow. Run from app/: python3 tool/generate_installer_art.py
"""
import io
import re
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

APP = Path(__file__).resolve().parents[1]
MASTER = APP / 'assets/sim_bridge_icon.svg'
OUT = APP / 'windows/installer/art'
FONT = APP / 'assets/fonts/BricolageGrotesque-ExtraBold.ttf'
MONO = APP / 'assets/fonts/JetBrainsMono-Medium.ttf'
# Palette tokens from lib/theme.dart.
BOARD_TOP, BOARD_BOTTOM = (0x1E, 0x3A, 0x30), (0x0E, 0x1B, 0x16)
PORCELAIN = (0xF6, 0xF2, 0xEA)
CHIP = (0xD9, 0xA1, 0x3F)
HAZE = (0xB8, 0xC4, 0xBC)
ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def svg(size: int, background: bool = True) -> Image.Image:
    source = MASTER.read_text(encoding='utf-8')
    if not background:
        source = re.sub(r'<rect id="background"[^>]*/>', '', source)
    png = subprocess.run(['rsvg-convert', '--width', str(size), '--height', str(size)],
                         input=source.encode('utf-8'), capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert('RGBA')


def gradient(size) -> Image.Image:
    width, height = size
    image = Image.new('RGB', size)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / max(1, height - 1)
        draw.line([(0, y), (width, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(BOARD_TOP, BOARD_BOTTOM)))
    return image


def welcome() -> Image.Image:
    image = gradient((328, 628))
    mark = svg(220, background=False)
    image.paste(mark, (54, 150), mask=mark.getchannel('A'))
    draw = ImageDraw.Draw(image)
    title = ImageFont.truetype(str(FONT), 40)
    tagline = ImageFont.truetype(str(MONO), 17)
    for text, font, color, y in (('Sim Bridge', title, PORCELAIN, 404), ('Your SMS on', tagline, CHIP, 468),
                                 ('every device.', tagline, CHIP, 492)):
        width = draw.textlength(text, font=font)
        draw.text(((328 - width) / 2, y), text, font=font, fill=color)
    return image


def header() -> Image.Image:
    image = Image.new('RGB', (300, 114), (255, 255, 255))
    mark = svg(88, background=False)
    image.paste(mark, (300 - 88 - 18, 13), mask=mark.getchannel('A'))
    return image


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    welcome().save(OUT / 'welcome.bmp', format='BMP')
    header().save(OUT / 'header.bmp', format='BMP')
    # The full tile (with its board background) reads well on light and dark desktops.
    master = svg(256)
    master.save(OUT / 'installer.ico', format='ICO', sizes=[(size, size) for size in ICON_SIZES], bitmap_format='bmp')
    print('Wrote', ', '.join(p.name for p in sorted(OUT.iterdir())))


if __name__ == '__main__':
    main()
