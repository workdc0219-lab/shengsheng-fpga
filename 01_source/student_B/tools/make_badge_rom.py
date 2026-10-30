#!/usr/bin/env python3
"""Render the F1/F3 unit glyphs into a small 1-bit badge ROM (board_b/src/ss_badge_rom.v).

The main phrase ROM (ss_phrase_rom.v, 16 KB) is full to within ~50 bytes of
its 14-bit descriptor cap, so the two summary-screen unit glyphs live here
instead. The overlay reaches them through descriptor ids PH_C_TI / PH_C_XING
(emitted by make_phrase_rom.py with stride bit 6 set as the badge-ROM select
flag); the base in those descriptors is an offset into THIS ROM.

Fixed layout (keep in sync with the descriptors make_phrase_rom.py emits):
  art 1  "题"  base 0     font 20, dy 6   -> stride 3 B, width 24
  art 2  "星"  base 128   font 20, dy 6   -> stride 3 B, width 24
Each slot is 128 bytes (32 rows x 4 B pad); the ROM is 256 x 8 -- the
overlay only ever addresses base 0/128 plus row*stride+col < 96, so the
2048-deep variant either wasted a BRAM or fell back to a huge distributed
RAM (the place gate showed BRAM stuck at 43 with it in the netlist).
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "board_b" / "src"
FONT = Path("C:/Windows/Fonts/Dengb.ttf")
ROWS = 32
SLOT_BYTES = 128          # base pitch of the fixed layout above
ROM_DEPTH = 256
THRESHOLD = 120

# (name, text, base). Order defines the art index the overlay references.
ART = [
    ("C_TI", "题", 0),
    ("C_XING", "星", 128),
]
CELL_W_MAX = 24
SIZE = 20
DY = 6


def write_lf(path: Path, text: str, encoding: str = "ascii") -> None:
    # LF endings: iverilog reads these files (see make_phrase_rom.py note).
    with open(path, "w", encoding=encoding, newline="\n") as fh:
        fh.write(text)


def render(text: str, font) -> tuple[int, list[list[int]]]:
    """1-bit strip, 8 px per byte, MSB = leftmost (same rule as the phrase ROM)."""
    width = int(font.getlength(text)) + 4
    assert width <= CELL_W_MAX, (text, width)
    ss = 2
    img = Image.new("L", (width * ss, ROWS * ss), 0)
    draw = ImageDraw.Draw(img)
    big = ImageFont.truetype(font.path, font.size * ss)
    draw.text((2 * ss, DY * ss), text, font=big, fill=255)
    stride = (width + 7) // 8
    rows = []
    for y in range(ROWS):
        row = []
        for bx in range(stride):
            byte = 0
            for b in range(8):
                x = bx * 8 + b
                if x >= width:
                    level = 0
                else:
                    acc = 0
                    for sy in range(ss):
                        for sx in range(ss):
                            acc += img.getpixel((x * ss + sx, y * ss + sy))
                    level = 1 if (acc // (ss * ss)) >= THRESHOLD else 0
                byte |= level << (7 - b)
            row.append(byte)
        rows.append(row)
    return width, rows


def main() -> None:
    font = ImageFont.truetype(str(FONT), SIZE)
    rom = [0] * ROM_DEPTH
    meta = []
    for name, text, base in ART:
        width, rows = render(text, font)
        stride = (width + 7) // 8
        assert len(rows) * stride <= SLOT_BYTES, (name, base)
        for r, row in enumerate(rows):
            for bx, byte in enumerate(row):
                rom[base + r * stride + bx] = byte
        meta.append((name, text, base, width, stride))

    lines = [
        "`timescale 1ns/1ps",
        "// F1/F3 unit glyphs (题/星) for the summary score strip -- GENERATED",
        "// by tools/make_badge_rom.py - do not edit by hand. Reached through",
        "// PH_C_TI / PH_C_XING descriptors (stride bit 6 = badge-ROM select).",
        "// 256 x 8; every address the descriptors can reach (base 0/128 +",
        "// 31 rows x 3 B stride + col < 8) lands below 224.",
        "module ss_badge_rom (",
        "    input  wire        clk,",
        "    input  wire        ce,",
        "    input  wire [7:0]  addr,",
        "    output reg  [7:0]  data",
        ");",
        "    reg [7:0] rom [0:255];",
        "    integer i;",
        "    initial begin",
        "        for (i = 0; i < 256; i = i + 1) rom[i] = 8'h00;",
    ]
    for name, text, base, width, stride in meta:
        lines.append(f"        // {name} '{text}' base {base} width {width} stride {stride}")
    for i, byte in enumerate(rom):
        if byte:
            lines.append(f"        rom[{i}] = 8'h{byte:02x};")
    lines += [
        "    end",
        "    always @(posedge clk) if (ce) data <= rom[addr];",
        "endmodule",
    ]
    # utf-8: the header comments name the glyphs in Chinese
    write_lf(RTL / "ss_badge_rom.v", "\n".join(lines) + "\n", "utf-8")
    print("ss_badge_rom.v:", ", ".join(f"{n}@{b} w{w}" for n, _, b, w, _ in meta))


if __name__ == "__main__":
    main()
