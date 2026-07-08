#!/usr/bin/env python3
"""Generates the RepoMen app icon: a disk platter being swept by a bold reclaim
arrow, on the standard macOS rounded-square tile.

This is the committed master's *source of truth* — the icon is pure geometry, so the
generator (not a binary blob) is what gets edited. It renders with signed-distance
functions at 2048px and box-downsamples to every size the asset catalog needs.

Outputs (all committed):
  media-sources/icon.png                                   1024px master
  RepoMen/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-{16,32,64,128,256,512,1024}.png

Requirements: python3 + numpy (no PIL/ImageMagick). Run from the repo root:
  python3 media-sources/generate-icon.py
"""

import struct
import zlib
from pathlib import Path

import numpy as np

SS = 2048          # supersampled working resolution
REPO = Path(__file__).resolve().parent.parent
ICONSET = REPO / "RepoMen/Resources/Assets.xcassets/AppIcon.appiconset"


def rgb(hexcode):
    return np.array([(hexcode >> 16) & 255, (hexcode >> 8) & 255, hexcode & 255],
                    dtype=np.float32) / 255.0


# Palette: slate tile, silver platter, emerald "repossess" arrow.
TILE_TOP, TILE_BOTTOM = rgb(0x3D4A5A), rgb(0x1F252E)
PLATTER, PLATTER_RIM = rgb(0xD8DEE6), rgb(0x8A95A3)
GROOVE, HUB, HUB_DOT = rgb(0x707C8A), rgb(0x333C47), rgb(0xD8DEE6)
ARROW = rgb(0x2ED49A)

# Pixel grid (icon coordinates: 1024-based, y down).
_ys, _xs = np.mgrid[0:SS, 0:SS].astype(np.float32)
X = (_xs + 0.5) * (1024.0 / SS)
Y = (_ys + 0.5) * (1024.0 / SS)
PX = 1024.0 / SS   # width of one working pixel, for anti-aliasing


def coverage(sdf):
    """Anti-aliased coverage from a signed distance field (negative = inside)."""
    return np.clip(0.5 - sdf / PX, 0.0, 1.0)


def sd_rounded_rect(cx, cy, half, radius):
    qx = np.abs(X - cx) - (half - radius)
    qy = np.abs(Y - cy) - (half - radius)
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - radius


def sd_circle(cx, cy, r):
    return np.hypot(X - cx, Y - cy) - r


def sd_ring(cx, cy, r, width):
    return np.abs(np.hypot(X - cx, Y - cy) - r) - width / 2.0


def sd_arc(cx, cy, r, width, start_deg, sweep_deg):
    """Ring limited to an angular window (degrees, image coords: 0° = +x, CW on
    screen because y points down); rounded start cap, flat end (the head covers it)."""
    theta = np.degrees(np.arctan2(Y - cy, X - cx))
    rel = np.mod(theta - start_deg, 360.0)
    ring = sd_ring(cx, cy, r, width)
    arc = np.where(rel <= sweep_deg, ring, np.float32(np.inf))
    sx, sy = cx + r * np.cos(np.radians(start_deg)), cy + r * np.sin(np.radians(start_deg))
    cap = sd_circle(sx, sy, width / 2.0)
    return np.minimum(arc, cap)


def sd_triangle(p0, p1, p2):
    """Exact SDF of a triangle (Inigo Quilez's construction)."""
    def seg(px_, py_, ax, ay, bx, by):
        pax, pay = px_ - ax, py_ - ay
        bax, bay = bx - ax, by - ay
        h = np.clip((pax * bax + pay * bay) / (bax * bax + bay * bay), 0.0, 1.0)
        return np.hypot(pax - bax * h, pay - bay * h)

    d = np.minimum(np.minimum(
        seg(X, Y, *p0, *p1), seg(X, Y, *p1, *p2)), seg(X, Y, *p2, *p0))
    # Sign: inside when the point is on the same side of all three edges.
    def side(ax, ay, bx, by):
        return (bx - ax) * (Y - ay) - (by - ay) * (X - ax)
    s0, s1, s2 = side(*p0, *p1), side(*p1, *p2), side(*p2, *p0)
    inside = ((s0 <= 0) & (s1 <= 0) & (s2 <= 0)) | ((s0 >= 0) & (s1 >= 0) & (s2 >= 0))
    return np.where(inside, -d, d)


class Canvas:
    def __init__(self):
        self.rgb = np.zeros((SS, SS, 3), dtype=np.float32)
        self.alpha = np.zeros((SS, SS), dtype=np.float32)

    def paint(self, mask, color):
        a = mask[..., None]
        self.rgb = color * a + self.rgb * (1.0 - a)
        self.alpha = mask + self.alpha * (1.0 - mask)

    def paint_gradient(self, mask, top, bottom, y0, y1):
        t = np.clip((Y - y0) / (y1 - y0), 0.0, 1.0)[..., None]
        color = top * (1.0 - t) + bottom * t
        a = mask[..., None]
        self.rgb = color * a + self.rgb * (1.0 - a)
        self.alpha = mask + self.alpha * (1.0 - mask)


def render():
    c = Canvas()
    cx = cy = 512.0

    # macOS icon grid: content tile ≈ 824px of 1024, corner radius ≈ 186.
    tile = coverage(sd_rounded_rect(cx, cy, 412.0, 186.0))
    c.paint_gradient(tile, TILE_TOP, TILE_BOTTOM, 100.0, 924.0)

    # The disk platter: rim, surface, a data groove, and the spindle hub.
    c.paint(coverage(sd_circle(cx, cy, 262.0)), PLATTER_RIM)
    c.paint_gradient(coverage(sd_circle(cx, cy, 248.0)), PLATTER, PLATTER * 0.82, 264.0, 760.0)
    c.paint(coverage(sd_ring(cx, cy, 168.0, 14.0)), GROOVE)
    c.paint(coverage(sd_circle(cx, cy, 84.0)), HUB)
    c.paint(coverage(sd_circle(cx, cy, 26.0)), HUB_DOT)

    # The repossession arrow: a sweep around the platter, head about to close the loop.
    r, w = 330.0, 62.0
    start, sweep = 300.0, 245.0   # degrees; end lands at 185° (left edge, mid-height)
    arrow = coverage(sd_arc(cx, cy, r, w, start, sweep))

    end = np.radians(start + sweep)
    ex, ey = cx + r * np.cos(end), cy + r * np.sin(end)
    tx, ty = -np.sin(end), np.cos(end)          # tangent, direction of travel
    nx, ny = np.cos(end), np.sin(end)           # outward radial
    head = coverage(sd_triangle(
        (ex + tx * 108.0, ey + ty * 108.0),      # tip
        (ex + nx * 78.0, ey + ny * 78.0),        # outer base corner
        (ex - nx * 78.0, ey - ny * 78.0)))       # inner base corner
    c.paint(np.maximum(arrow, head), ARROW)

    # Nothing may draw outside the tile.
    c.alpha *= tile
    out = np.zeros((SS, SS, 4), dtype=np.float32)
    out[..., :3] = c.rgb
    out[..., 3] = c.alpha
    return out


def downsample(img, size):
    f = SS // size
    return img.reshape(size, f, size, f, 4).mean(axis=(1, 3))


def write_png(path, img):
    """img: float32 (h, w, 4) in [0, 1], straight alpha."""
    data = (np.clip(img, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    h, w = data.shape[:2]
    raw = b"".join(b"\x00" + data[y].tobytes() for y in range(h))

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))
    print(f"wrote {path.relative_to(REPO)} ({w}x{h})")


def main():
    img = render()
    write_png(REPO / "media-sources/icon.png", downsample(img, 1024))
    for size in (16, 32, 64, 128, 256, 512, 1024):
        write_png(ICONSET / f"AppIcon-{size}.png", downsample(img, size))


if __name__ == "__main__":
    main()
