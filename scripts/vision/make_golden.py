#!/usr/bin/env python3
"""make_golden.py - deterministic golden screenshots for `llmctl vision validate`.

Renders the vision validation fixtures (PNG) whose content is KNOWN by construction, so a local vision
model can be checked against a machine-readable expectation file (validation/suites/vision-golden-v1/
expectations.json) without any LLM-as-judge.

Byte reproducibility (why this file is stdlib-only and carries its own font and DEFLATE encoder):
  * No PIL / ImageMagick / system font. Text is drawn from the 5x7 bitmap font embedded below, scaled by
    an integer factor, so the pixels never depend on a FreeType build, a hinting setting or an installed
    font file. Honest consequence: the text is blocky "LCD-style" uppercase; there is no lowercase and no
    anti-aliasing. That is a deliberate trade-off for reproducibility, documented in docs/golden-set.md (section "Vision golden screenshots").
  * No zlib.compress(). Different zlib builds (zlib, zlib-ng, cloudflare-zlib) may emit different but
    equally valid DEFLATE streams, which would change the file bytes. This module writes its own DEFLATE
    stream (one final block, fixed Huffman codes, greedy LZ77 over distance 1 and distance = one row), so
    the same Python source always produces the same bytes. zlib is used only for crc32/adler32, which are
    fixed checksums (no implementation freedom), and by the tests to DECODE (round-trip) the output.
  * Palette PNG (colour type 3), no ancillary chunks (no time stamp, no gamma, no text).

Usage:
  make_golden.py --out DIR            write every fixture PNG into DIR
  make_golden.py --check DIR          regenerate in memory and compare with DIR byte for byte (exit 1 on diff)
  make_golden.py --list               print fixture ids
"""
import argparse
import hashlib
import os
import struct
import sys
import zlib

W = H = 896  # Gemma 3's SigLIP encoder input is 896x896: a native-size canvas means no resampling.

# --- 5x7 bitmap font ------------------------------------------------------------------------------------
FONT = {
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    ":": [".....", "..#..", "..#..", ".....", "..#..", "..#..", "....."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
}


class Canvas:
    """Palette canvas: one byte per pixel (palette index)."""

    def __init__(self, w, h, palette, bg):
        self.w, self.h = w, h
        self.palette = list(palette)          # list of (r, g, b)
        self.names = {}
        self.px = bytearray([self.color(bg)]) * (w * h)

    def color(self, rgb):
        if rgb not in self.palette:
            self.palette.append(rgb)
        return self.palette.index(rgb)

    def rect(self, x, y, w, h, rgb):
        c = self.color(rgb)
        x0, y0, x1, y1 = max(0, x), max(0, y), min(self.w, x + w), min(self.h, y + h)
        row = bytes([c]) * max(0, x1 - x0)
        for yy in range(y0, y1):
            o = yy * self.w
            self.px[o + x0:o + x1] = row

    def frame(self, x, y, w, h, rgb, t):
        self.rect(x, y, w, t, rgb)
        self.rect(x, y + h - t, w, t, rgb)
        self.rect(x, y, t, h, rgb)
        self.rect(x + w - t, y, t, h, rgb)

    def circle(self, cx, cy, r, rgb):
        c = self.color(rgb)
        for yy in range(cy - r, cy + r + 1):
            dy = yy - cy
            # integer-only span (no float rounding differences between platforms)
            span = 0
            while (span + 1) * (span + 1) + dy * dy <= r * r:
                span += 1
            o = yy * self.w
            self.px[o + cx - span:o + cx + span + 1] = bytes([c]) * (2 * span + 1)

    def text(self, x, y, s, string, rgb):
        for i, ch in enumerate(string):
            glyph = FONT[ch]
            gx = x + i * 6 * s
            for ry, line in enumerate(glyph):
                for rx, bit in enumerate(line):
                    if bit == "#":
                        self.rect(gx + rx * s, y + ry * s, s, s, rgb)

    @staticmethod
    def text_w(s, string):
        return len(string) * 6 * s - s

    def text_c(self, cy, s, string, rgb, cx=None):
        cx = self.w // 2 if cx is None else cx
        self.text(cx - self.text_w(s, string) // 2, cy, s, string, rgb)


# --- PNG + deterministic DEFLATE --------------------------------------------------------------------------
LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
            163, 195, 227, 258]
LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
             2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]


class _Bits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, value, nbits):          # LSB-first (extra bits, block header)
        self.acc |= value << self.n
        self.n += nbits
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def huff(self, code, nbits):          # Huffman codes are packed MSB-first
        rev = 0
        for _ in range(nbits):
            rev = (rev << 1) | (code & 1)
            code >>= 1
        self.put(rev, nbits)

    def flush(self):
        if self.n:
            self.out.append(self.acc & 0xFF)
        self.acc = self.n = 0
        return bytes(self.out)


def _lit(bw, sym):
    if sym <= 143:
        bw.huff(0x30 + sym, 8)
    elif sym <= 255:
        bw.huff(0x190 + sym - 144, 9)
    elif sym <= 279:
        bw.huff(sym - 256, 7)
    else:
        bw.huff(0xC0 + sym - 280, 8)


def _match(bw, length, dist):
    i = 0
    while i + 1 < len(LEN_BASE) and LEN_BASE[i + 1] <= length:
        i += 1
    _lit(bw, 257 + i)
    if LEN_EXTRA[i]:
        bw.put(length - LEN_BASE[i], LEN_EXTRA[i])
    j = 0
    while j + 1 < len(DIST_BASE) and DIST_BASE[j + 1] <= dist:
        j += 1
    bw.huff(j, 5)
    if DIST_EXTRA[j]:
        bw.put(dist - DIST_BASE[j], DIST_EXTRA[j])


def deflate_fixed(data, dists):
    """One final fixed-Huffman block; greedy LZ77 trying only the given distances. Deterministic."""
    bw = _Bits()
    bw.put(1, 1)   # BFINAL
    bw.put(1, 2)   # BTYPE=01 fixed Huffman
    n, i = len(data), 0
    while i < n:
        best_len, best_d = 0, 0
        for d in dists:
            if d > i:
                continue
            lim = min(258, n - i)
            if data[i:i + lim] == data[i - d:i - d + lim]:
                ln = lim
            else:
                ln = 0
                while ln < lim and data[i + ln] == data[i + ln - d]:
                    ln += 1
            if ln > best_len:
                best_len, best_d = ln, d
        if best_len >= 3:
            _match(bw, best_len, best_d)
            i += best_len
        else:
            _lit(bw, data[i])
            i += 1
    _lit(bw, 256)  # end of block
    return bw.flush()


def png_bytes(cv):
    stride = cv.w + 1
    raw = bytearray()
    for y in range(cv.h):
        raw.append(0)  # filter type 0 (None)
        raw += cv.px[y * cv.w:(y + 1) * cv.w]
    raw = bytes(raw)
    z = b"\x78\x01" + deflate_fixed(raw, (1, stride)) + struct.pack(">I", zlib.adler32(raw) & 0xFFFFFFFF)

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    plte = b"".join(bytes(rgb) for rgb in cv.palette)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", cv.w, cv.h, 8, 3, 0, 0, 0))
            + chunk(b"PLTE", plte)
            + chunk(b"IDAT", z)
            + chunk(b"IEND", b""))


# --- the fixtures -----------------------------------------------------------------------------------------
WHITE, BLACK = (255, 255, 255), (0, 0, 0)
GRAY, LIGHT, MID = (128, 128, 128), (235, 235, 235), (200, 200, 200)
RED, GREEN, BLUE = (220, 30, 30), (30, 160, 60), (30, 70, 210)
DARK_BG, DARK_PANEL, DARK_TEXT = (18, 18, 18), (40, 40, 40), (235, 235, 235)


def fx_text_large():
    c = Canvas(W, H, [WHITE], WHITE)
    c.text_c(300, 10, "ORANGE TIGER", BLACK)
    c.text_c(470, 14, "42", BLACK)
    return c


def fx_shapes_count():
    c = Canvas(W, H, [WHITE], WHITE)
    for cx, cy in ((170, 220), (450, 220), (730, 220)):
        c.circle(cx, cy, 80, RED)
    for x in (230, 530):
        c.rect(x, 560, 150, 150, BLUE)
    return c


def fx_login_form():
    c = Canvas(W, H, [LIGHT], LIGHT)
    c.rect(148, 120, 600, 660, WHITE)
    c.frame(148, 120, 600, 660, GRAY, 4)
    c.text_c(180, 8, "SIGN IN", BLACK)
    c.text(208, 320, 5, "USERNAME", BLACK)
    c.frame(208, 370, 480, 70, GRAY, 3)
    c.text(208, 480, 5, "PASSWORD", BLACK)
    c.frame(208, 530, 480, 70, GRAY, 3)
    c.rect(208, 650, 480, 90, BLUE)
    c.text_c(674, 6, "LOGIN", WHITE)
    return c


def fx_list_view():
    c = Canvas(W, H, [WHITE], WHITE)
    c.rect(0, 0, W, 150, BLUE)
    c.text(60, 45, 9, "FRUITS", WHITE)
    for i, item in enumerate(("APPLE", "BANANA", "CHERRY", "GRAPE")):
        y = 200 + i * 170
        c.text(80, y + 40, 8, item, BLACK)
        c.rect(40, y + 150, W - 80, 4, MID)
    return c


def fx_table():
    c = Canvas(W, H, [WHITE], WHITE)
    rows = [("NAME", "AGE", "CITY"), ("ANNA", "31", "PARIS"), ("BORIS", "45", "OSLO"), ("CLARA", "27", "ROME")]
    x0, y0, cw, rh = 58, 160, 260, 140
    c.rect(x0, y0, cw * 3, rh, MID)
    for r, row in enumerate(rows):
        for k, cell in enumerate(row):
            c.text(x0 + k * cw + 30, y0 + r * rh + 46, 7, cell, BLACK)
    for r in range(5):
        c.rect(x0, y0 + r * rh, cw * 3, 4, BLACK)
    for k in range(4):
        c.rect(x0 + k * cw, y0, 4, rh * 4 + 4, BLACK)
    return c


def fx_dialog():
    c = Canvas(W, H, [GRAY], GRAY)
    c.rect(98, 230, 700, 440, WHITE)
    c.frame(98, 230, 700, 440, BLACK, 4)
    c.rect(98, 230, 700, 100, RED)
    c.text_c(258, 7, "WARNING", WHITE)
    c.text_c(400, 7, "DELETE FILE?", BLACK)
    c.frame(158, 540, 260, 90, BLACK, 4)
    c.text(158 + 130 - Canvas.text_w(5, "CANCEL") // 2, 568, 5, "CANCEL", BLACK)
    c.rect(478, 540, 260, 90, RED)
    c.text(478 + 130 - Canvas.text_w(5, "DELETE") // 2, 568, 5, "DELETE", WHITE)
    return c


def fx_dark_theme():
    c = Canvas(W, H, [DARK_BG], DARK_BG)
    c.text(70, 80, 9, "SETTINGS", DARK_TEXT)
    c.rect(60, 240, 776, 170, DARK_PANEL)
    c.text(100, 300, 7, "DARK MODE", DARK_TEXT)
    c.rect(640, 290, 150, 70, GREEN)
    c.text(680, 309, 5, "ON", WHITE)
    c.rect(60, 470, 776, 170, DARK_PANEL)
    c.text(100, 530, 7, "VOLUME 75", DARK_TEXT)
    return c


def fx_small_text():
    c = Canvas(W, H, [WHITE], WHITE)
    c.text_c(90, 9, "RECEIPT", BLACK)
    c.text(120, 330, 4, "INVOICE NO 7731", BLACK)
    c.text(120, 420, 4, "TOTAL 58.40", BLACK)
    c.text(120, 510, 4, "STATUS PAID", BLACK)
    return c


def fx_color_blocks():
    c = Canvas(W, H, [WHITE], WHITE)
    for k, col in enumerate((RED, GREEN, BLUE)):
        c.rect(48 + k * 280, 318, 240, 240, col)
    return c


def fx_bad_blank():
    return Canvas(W, H, [WHITE], WHITE)


def fx_bad_wrong_content():
    c = Canvas(W, H, [WHITE], WHITE)
    c.text_c(300, 10, "PURPLE HORSE", BLACK)
    c.text_c(470, 14, "17", BLACK)
    return c


FIXTURES = [
    ("01_text_large", fx_text_large),
    ("02_shapes_count", fx_shapes_count),
    ("03_login_form", fx_login_form),
    ("04_list_view", fx_list_view),
    ("05_table", fx_table),
    ("06_dialog", fx_dialog),
    ("07_dark_theme", fx_dark_theme),
    ("08_small_text", fx_small_text),
    ("09_color_blocks", fx_color_blocks),
    ("90_bad_blank", fx_bad_blank),
    ("91_bad_wrong_content", fx_bad_wrong_content),
]


def render_all():
    return {fid: png_bytes(fn()) for fid, fn in FIXTURES}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--out")
    g.add_argument("--check")
    g.add_argument("--list", action="store_true")
    a = ap.parse_args(argv)
    if a.list:
        for fid, _ in FIXTURES:
            print(fid)
        return 0
    pngs = render_all()
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        for fid, data in pngs.items():
            with open(os.path.join(a.out, fid + ".png"), "wb") as fh:
                fh.write(data)
            print("%s.png %d bytes sha256=%s" % (fid, len(data), hashlib.sha256(data).hexdigest()))
        return 0
    bad = 0
    for fid, data in pngs.items():
        path = os.path.join(a.check, fid + ".png")
        try:
            with open(path, "rb") as fh:
                have = fh.read()
        except OSError as e:
            print("MISSING %s: %s" % (path, e))
            bad += 1
            continue
        if have == data:
            print("IDENTICAL %s.png sha256=%s" % (fid, hashlib.sha256(data).hexdigest()))
        else:
            print("DIFFERS %s.png committed=%s regenerated=%s" % (
                fid, hashlib.sha256(have).hexdigest(), hashlib.sha256(data).hexdigest()))
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
