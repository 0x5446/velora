#!/usr/bin/env python3
"""Procedurally render Velora's app icon: a warm-cream badge with a clay
waveform mark, echoing the app's own MacVoiceWaveform HUD component.

Hex constants below must stay byte-for-byte in sync with
Velora/Sources/Velora/DesignSystem/VeloraTheme.swift (VeloraPalette).

Usage: python3 scripts/generate_app_icon.py
Requires: Pillow (pip install pillow)
"""

import os

from PIL import Image, ImageDraw

BACKGROUND_LIGHT = 0xF7F3EA
ACCENT_LIGHT = 0xBF5B3A

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAC_ICONSET = os.path.join(
    REPO_ROOT, "Apps", "VeloraMac", "Assets.xcassets", "AppIcon.appiconset"
)
IOS_ICONSET = os.path.join(
    REPO_ROOT, "Apps", "VeloraiOS", "Assets.xcassets", "AppIcon.appiconset"
)
PREVIEW_DIR = os.path.join(REPO_ROOT, ".claude-scratch", "icon-preview")

MASTER_SIZE = 4096
BAR_HEIGHT_FRACTIONS = [0.35, 0.6, 1.0, 0.6, 0.35]

# (filename, pixel size) pairs matching AppIcon.appiconset/Contents.json.
MAC_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def hex_to_rgb(value):
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


def draw_waveform(draw, cx, cy, glyph_box):
    """Draw the 5-bar mirrored waveform glyph centered at (cx, cy)."""
    bar_count = len(BAR_HEIGHT_FRACTIONS)
    gap = glyph_box * 0.16
    bar_width = (glyph_box - gap * (bar_count - 1)) / bar_count
    accent = hex_to_rgb(ACCENT_LIGHT)

    total_width = bar_width * bar_count + gap * (bar_count - 1)
    start_x = cx - total_width / 2

    for index, fraction in enumerate(BAR_HEIGHT_FRACTIONS):
        bar_height = glyph_box * fraction
        x0 = start_x + index * (bar_width + gap)
        x1 = x0 + bar_width
        y0 = cy - bar_height / 2
        y1 = cy + bar_height / 2
        radius = bar_width / 2
        draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=accent)


def render_mac_master():
    """Rounded-square badge with margin — macOS does not auto-mask icons."""
    size = MASTER_SIZE
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    margin = size * 0.09
    content = size - margin * 2
    radius = content * 0.22
    background = hex_to_rgb(BACKGROUND_LIGHT)

    draw.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=radius,
        fill=background,
    )

    glyph_box = content * 0.46
    draw_waveform(draw, size / 2, size / 2, glyph_box)
    return image


def render_ios_master():
    """Full-bleed opaque square — iOS applies its own mask and corners."""
    size = MASTER_SIZE
    image = Image.new("RGB", (size, size), hex_to_rgb(BACKGROUND_LIGHT))
    draw = ImageDraw.Draw(image)

    glyph_box = size * 0.46
    draw_waveform(draw, size / 2, size / 2, glyph_box)
    return image


def save_resized(master, path, pixel_size):
    resized = master.resize((pixel_size, pixel_size), Image.LANCZOS)
    resized.save(path)


def main():
    os.makedirs(MAC_ICONSET, exist_ok=True)
    os.makedirs(IOS_ICONSET, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)

    mac_master = render_mac_master()
    for filename, pixel_size in MAC_SIZES:
        save_resized(mac_master, os.path.join(MAC_ICONSET, filename), pixel_size)
    save_resized(mac_master, os.path.join(PREVIEW_DIR, "mac_128.png"), 128)
    save_resized(mac_master, os.path.join(PREVIEW_DIR, "mac_32.png"), 32)

    ios_master = render_ios_master()
    save_resized(ios_master, os.path.join(IOS_ICONSET, "icon_1024.png"), 1024)
    save_resized(ios_master, os.path.join(PREVIEW_DIR, "ios_128.png"), 128)

    print(f"macOS icons written to {MAC_ICONSET}")
    print(f"iOS icon written to {IOS_ICONSET}")
    print(f"Preview crops written to {PREVIEW_DIR}")


if __name__ == "__main__":
    main()
