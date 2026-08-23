#!/usr/bin/env python3
"""Rebuild the DSH Desktop icon: composite the DeepSeek Harness logo
(rendered from the running GUI's /favicon.svg) onto a macOS-style rounded
gradient tile.  Pure Python stdlib (PNG decode + encode).

The icon is derived from the DeepSeek Harness favicon; "DeepSeek" and
"DeepSeek Harness" are trademarks of DeepSeek.  See THIRD_PARTY_NOTICES.md."""

import math
import struct
import sys
import zlib

# ---------------------------------------------------------------------------
# minimal PNG decode (8-bit, non-interlaced, RGB/RGBA/gray)
# ---------------------------------------------------------------------------

def decode_png(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    idat = b""
    w = h = bitd = ctype = None
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, bitd, ctype, _, _, _ = struct.unpack(">IIBBBBB", chunk)
        elif tag == b"IDAT":
            idat += chunk
        elif tag == b"IEND":
            break
        pos += 12 + ln
    assert bitd == 8, "only 8-bit supported"
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray()
    prev = bytearray(stride)
    for y in range(h):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out += line
        prev = line
    # -> RGBA
    rgba = bytearray(w * h * 4)
    for y in range(h):
        for x in range(w):
            o = (y * w + x) * ch
            d = (y * w + x) * 4
            if ctype == 6:
                rgba[d:d + 4] = out[o:o + 4]
            elif ctype == 2:
                rgba[d:d + 3] = out[o:o + 3]
                rgba[d + 3] = 255
            elif ctype == 0:
                rgba[d:d + 3] = out[o:o + 1] * 3
                rgba[d + 3] = 255
            elif ctype == 4:
                rgba[d:d + 3] = out[o:o + 1] * 3
                rgba[d + 3] = out[o + 1]
    return w, h, rgba

def encode_png(path, w, h, rgba):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += bytes(rgba[y * w * 4:(y + 1) * w * 4])
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def sd_round_rect(px, py, cx, cy, hw, hh, r):
    dx = abs(px - cx) - (hw - r)
    dy = abs(py - cy) - (hh - r)
    ox, oy = max(dx, 0.0), max(dy, 0.0)
    return math.hypot(ox, oy) + min(max(dx, dy), 0.0) - r

def aa(d, w=1.6):
    return max(0.0, min(1.0, 0.5 - d / w))

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))

def box_blur(w, h, a, radius, passes=2):
    """separable box blur on float alpha array (fresh buffers, value-bounded)"""
    cur = list(a)
    for _ in range(passes):
        tmp = [0.0] * (w * h)
        nxt = [0.0] * (w * h)
        # horizontal
        for y in range(h):
            acc = 0.0
            for x in range(w):
                acc += cur[y * w + x]
                if x > radius:
                    acc -= cur[y * w + (x - radius - 1)]
                tmp[y * w + x] = acc / (radius + 1)
        # vertical
        for x in range(w):
            acc = 0.0
            for y in range(h):
                acc += tmp[y * w + x]
                if y > radius:
                    acc -= tmp[(y - radius - 1) * w + x]
                nxt[y * w + x] = acc / (radius + 1)
        cur = nxt
    return cur

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

W = H = 1024
C_TOP = (0x14, 0x2B, 0x63)
C_BOT = (0x2E, 0x1E, 0x5C)
C_GLOW = (0x4D, 0x6B, 0xFE)
WHITE = (255, 255, 255)

def main(logo_path, out_path):
    lw, lh, lrgba = decode_png(logo_path)
    assert lw == lh == W, f"logo must be {W}x{W}, got {lw}x{lh}"
    # silhouette mask + color stats
    mask = [0.0] * (W * H)
    for i in range(W * H):
        mask[i] = lrgba[i * 4 + 3] / 255.0
    # bounding box of the logo
    xs = [x for y in range(H) for x in range(W) if mask[y * W + x] > 0.25]
    ys = [y for y in range(H) for x in range(W) if mask[y * W + x] > 0.25]
    bbox = (min(xs), min(ys), max(xs), max(ys))
    bw, bh = bbox[2] - bbox[0] + 1, bbox[3] - bbox[1] + 1
    print(f"logo bbox: {bbox}, {bw}x{bh}")

    # scale/center the logo inside the tile (80% of inner width)
    MARGIN = 56
    CORNER = 210
    CX = CY = W / 2
    inner_w = W - 2 * MARGIN
    scale = (inner_w * 0.80) / bw
    if bh * scale > inner_w * 0.80:
        scale = (inner_w * 0.80) / bh
    ow = bw * scale
    oh = bh * scale
    ox = CX - ow / 2
    oy = CY - oh / 2 + 10  # slight upward bias

    # build logo raster (white) + shadow raster at target placement
    logo_a = [0.0] * (W * H)
    for y in range(H):
        for x in range(W):
            # map target pixel center back to source
            sx = bbox[0] + (x + 0.5 - ox) / scale - 0.5
            sy = bbox[1] + (y + 0.5 - oy) / scale - 0.5
            if 0 <= sx < W and 0 <= sy < H:
                x0, y0 = int(sx), int(sy)
                x1, y1 = min(x0 + 1, W - 1), min(y0 + 1, H - 1)
                fx, fy = sx - x0, sy - y0
                a00 = mask[y0 * W + x0]
                a10 = mask[y0 * W + x1]
                a01 = mask[y1 * W + x0]
                a11 = mask[y1 * W + x1]
                logo_a[y * W + x] = (a00 * (1 - fx) + a10 * fx) * (1 - fy) + (a01 * (1 - fx) + a11 * fx) * fy
    # shadow: logo shifted down, slightly larger, blurred
    dy = 14
    sh_a = [0.0] * (W * H)
    for y in range(H):
        for x in range(W):
            sy = y - dy
            if 0 <= sy < H:
                sh_a[y * W + x] = logo_a[sy * W + x] * 0.55
    sh_a = box_blur(W, H, sh_a, 12, passes=2)
    glow = box_blur(W, H, [v * 0.9 for v in logo_a], 24, passes=2)

    out = bytearray()
    for y in range(H):
        for x in range(W):
            d = sd_round_rect(x + 0.5, y + 0.5, CX, CY, W / 2 - MARGIN, H / 2 - MARGIN, CORNER)
            if d > 2.0:
                out += b"\x00\x00\x00\x00"
                continue
            t = (y + 0.5) / H
            base = lerp(C_TOP, C_BOT, t)
            alpha = aa(d)
            # top edge light
            edge = max(0.0, min(1.0, 0.5 - d / 1.6)) * 0.10
            col = lerp(base, C_GLOW, edge)
            # glow behind logo
            g = glow[y * W + x]
            col = lerp(col, C_GLOW, g * 0.35)
            # shadow
            s = sh_a[y * W + x]
            col = lerp(col, (0, 0, 0), s * 0.75)
            # logo
            la = logo_a[y * W + x]
            col = lerp(col, WHITE, la)
            if max(col[0], col[1], col[2]) > 255 or min(col[0], col[1], col[2]) < 0:
                raise SystemExit(f"OOR {(x, y)} d={d} edge={edge} g={g} s={s} la={la} col={col}")
            out += bytes((col[0], col[1], col[2], int(round(alpha * 255))))
    encode_png(out_path, W, H, out)
    print(f"wrote {out_path}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
