from functools import lru_cache

from .ansi import BACKGROUND, fit_text, image_rows
from .widgets import GOLD


@lru_cache(maxsize=1)
def panel_rows(width, height, art, health, armor, ammo, keys):
    if art is not None and art.has_status_bar and height > 1:
        patch = art.status_bar(health, armor, ammo, keys)
        return tuple(image_rows(patch, width, height))

    text = f"HP {health}%   ARM {armor}%   AMMO {ammo}"
    cards = "".join(key for bit, key in enumerate("BYR") if keys & (1 << bit))
    if cards:
        text += "   " + cards
    if len(text) > width:
        text = f"H{health} A{armor} M{ammo} {cards}".rstrip()
    return (GOLD + fit_text(text, width).center(width) + BACKGROUND,)
