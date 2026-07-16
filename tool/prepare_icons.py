#!/usr/bin/env python3
"""Turns assets/icon.png into the two images the launcher icons are built from.

Run after changing the icon, then `dart run flutter_launcher_icons` in android/.

Two things make this more than a resize:

Android masks an adaptive icon to whatever shape the launcher likes. The
drawable is 108 units, but only the middle 72 survive the mask at all, and the
shape that is guaranteed on every launcher is a circle of 66 - Pixel really does
use a plain circle. Our artwork is a square composition running edge to edge, so
to keep its corners it has to fit *inside* that circle, not merely inside a
66-unit square: a square inscribed in a circle of 66 has a side of only 66/root2,
about 47 units, which is where FOREGROUND_SCALE comes from. It looks small on
the 108 canvas and correct on the phone, because the phone only ever shows 72.

The artwork is also black on nothing at all. A transparent icon disappears into
a dark launcher background, so the adaptive background layer is a solid colour
and the legacy icon is flattened onto the same one.
"""

from PIL import Image

SOURCE = 'assets/icon.png'
OUT_DIR = 'android/assets'

# 108dp at xxxhdpi. The source is 396px, so everything here only ever shrinks
# the artwork - upscaling it would just smear the edges.
CANVAS = 432

# The share of the canvas the artwork may occupy.
#
# Foreground: a square inscribed in the 66/108 safe circle, 66 / sqrt(2) / 108.
# flutter_launcher_icons would otherwise apply its own 16% inset on top of this
# and shrink the artwork twice, so adaptive_icon_foreground_inset is set to 0
# and all the spacing is decided here, where the reason for it is written down.
#
# Legacy: not masked nearly as hard, but a launcher may still round it off.
FOREGROUND_SCALE = 0.44
LEGACY_SCALE = 0.80

BACKGROUND = (255, 255, 255, 255)


def fitted(source: Image.Image, scale: float) -> Image.Image:
    """The artwork, scaled to `scale` of the canvas and centred on it."""
    limit = round(CANVAS * scale)
    art = source.copy()
    # Keeps the aspect ratio: the source is 396x395, not square, and stretching
    # it to a square would show.
    art.thumbnail((limit, limit), Image.LANCZOS)

    canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(art, ((CANVAS - art.width) // 2, (CANVAS - art.height) // 2))
    return canvas


def main() -> None:
    source = Image.open(SOURCE).convert('RGBA')

    foreground = fitted(source, FOREGROUND_SCALE)
    foreground.save(f'{OUT_DIR}/icon_foreground.png')

    legacy = Image.new('RGBA', (CANVAS, CANVAS), BACKGROUND)
    legacy.alpha_composite(fitted(source, LEGACY_SCALE))
    legacy.save(f'{OUT_DIR}/icon_legacy.png')

    print(f'wrote {OUT_DIR}/icon_foreground.png and {OUT_DIR}/icon_legacy.png')


if __name__ == '__main__':
    main()
