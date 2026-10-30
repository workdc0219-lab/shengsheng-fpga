#!/usr/bin/env python3
"""Text bitmaps for the Board A teacher console (docs/14 section 4).

Every phrase is drawn with DengXian Bold into a 20-row strip at 2x
supersampling and reduced to 2 bits/pixel (4-level anti-aliasing, MSB pair =
leftmost pixel), the same encoding as the child screen's ss_phrase_rom so the
two screens share one typographic look. Row stride = ceil(width / 4) bytes:
addr = base + row * stride + (col >> 2) (a 5x6-bit LUT multiply; padding
strides to powers of two would have cost 21 KB instead of ~15 KB).

Outputs  board_a/src/console_text_rom.v   byte ROM (block RAM)
         board_a/src/console_phrases.vh   ids + {base, log2_stride, width}
         build/console_phrases.png        preview sheet
"""
from __future__ import annotations

from pathlib import Path
import argparse
import json

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "board_a" / "src"
FONT = Path("C:/Windows/Fonts/Dengb.ttf")
UI = json.loads((ROOT / "spec" / "ui.json").read_text(encoding="utf-8"))
ROWS = SIZE = UI["fonts"]["teacher_primary_px"]
DEPTH = UI["fonts"]["teacher_rom_bytes"]  # 14-bit address, frozen 16 KB
assert DEPTH == 16384 and UI["fonts"]["teacher_bpp"] == 2

# (id, text, size). Order defines the id; 0 must stay blank.
PHRASES = [
    ("BLANK", "", SIZE),
    ("TITLE", "声声教师端", SIZE),
    ("LINK_OK", "孩子端已连接", SIZE),
    ("LINK_NO", "孩子端未连接", SIZE),
    ("M_SHOW", "图片展示", SIZE),
    ("M_TONE", "声调爬山", SIZE),
    ("M_BALLOON", "吹气球", SIZE),
    ("M_TRAIN", "音量小火车", SIZE),
    ("M_CARD", "看图跟读", SIZE),
    ("T1", "一声 mā", SIZE),
    ("T2", "二声 má", SIZE),
    ("T3", "三声 mǎ", SIZE),
    ("T4", "四声 mà", SIZE),
    ("CUE_DEMO", "请示范", SIZE),
    ("CUE_LISTEN", "孩子跟读中", SIZE),
    ("CUE_FEED", "反馈中", SIZE),
    ("CUE_SYN", "合成示范中", SIZE),
    ("LIVE", "实时音高", SIZE),
    ("CHILD", "孩子", SIZE),
    ("TEACHER", "老师", SIZE),
    ("TEMPLATE", "标准", SIZE),
    ("CMP", "归一化对比", SIZE),
    ("PROG", "进步曲线", SIZE),
    ("DEMO_ON", "真人", SIZE),
    ("DEMO_OFF", "合成", SIZE),
    ("THIS", "本题", SIZE),
    ("FEN", "分", SIZE),
    ("DONE", "尝试", SIZE),
    ("TI", "次", SIZE),  # existing ID: attempts are events, not question IDs
    ("AVG", "平均", SIZE),
    ("SHORT", "太短", SIZE),
    ("NONE", "待首题", SIZE),
]
CELLS = [(f"D{d}", str(d), SIZE) for d in range(10)] + [
    ("STAR", "★", 18), ("STAR_E", "☆", 18), ("DASH", "-", SIZE),
]
CELL_W = 16                         # every cell renders into exactly 16 px
EXTRA_PHRASES = [
    ("M_DISCOVERY", "自由探索", SIZE),   # IDs 0..44 are preserved
    ("STORAGE_ERROR", "存储异常", SIZE),
    ("CUE_WAIT", "等待准备", SIZE),
    ("VALID", "有效", SIZE),
    ("HIST_EMPTY", "历史为空", SIZE),
    ("READ_ERROR", "读取失败", SIZE),
    ("WRITE_ERROR", "保存失败", SIZE),
    ("COUNT_CAP", "计数封顶", SIZE),
    # Append only: IDs 0..52 remain stable. The five concise labels above
    # recover 1000 bytes without removing live storage/error/counter messages.
    ("CARD_MAO", "māo 猫", SIZE),
    ("CARD_YU", "yú 鱼", SIZE),
    ("CARD_GOU", "gǒu 狗", SIZE),
    ("CARD_TU", "tù 兔", SIZE),
]


def render(text: str, size: int, width: int | None) -> tuple[int, list[list[int]]]:
    """Draw `text` at 2x into a ROWS-tall strip, vertically centred on the
    font's ink box, then reduce 2x2 blocks to 4 coverage levels."""
    if not text:
        return 0, []
    ss = 2
    big = ImageFont.truetype(str(FONT), size * ss)
    left, top, right, bottom = big.getbbox(text)
    natural = (right - left) // ss + 2
    w = width if width else natural
    img = Image.new("L", (w * ss, ROWS * ss), 0)
    draw = ImageDraw.Draw(img)
    x = (w * ss - (right - left)) // 2 - left if width else ss - left
    y = (ROWS * ss - (bottom - top)) // 2 - top
    draw.text((x, y), text, font=big, fill=255)
    stride = (w + 3) // 4
    rows = []
    for yy in range(ROWS):
        row = []
        for bx in range(stride):
            byte = 0
            for b in range(4):
                xx = bx * 4 + b
                level = 0
                if xx < w:
                    acc = sum(img.getpixel((xx * ss + sx, yy * ss + sy))
                              for sy in range(ss) for sx in range(ss))
                    cov = acc // (ss * ss)
                    level = 0 if cov < 32 else 1 if cov < 96 else 2 if cov < 176 else 3
                byte |= level << (6 - 2 * b)
            row.append(byte)
        rows.append(row)
    return w, rows


def write_lf(path: Path, text: str) -> None:
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", type=Path,
                        help="preview image destination (default: build/console_phrases.png)")
    args = parser.parse_args()
    entries = ([(n, t, s, None) for n, t, s in PHRASES]
               + [(n, t, s, CELL_W) for n, t, s in CELLS]
               + [(n, t, s, None) for n, t, s in EXTRA_PHRASES])
    assert len(entries) <= 64, "phrase IDs exceed the existing six-bit interface"
    data: list[int] = []
    descs = []
    previews = []
    for name, text, size, cw in entries:
        w, rows = render(text, size, cw)
        stride = len(rows[0]) if rows else 0
        base = len(data)
        for r in rows:
            data.extend(r)
        descs.append((name, base, stride, w))
        previews.append((w, rows))
    assert len(data) <= DEPTH, len(data)

    lines = [
        "`timescale 1ns/1ps",
        f"// Teacher-console text bitmaps: 2 bits/pixel (4-level AA), {ROWS} rows,",
        "// MSB pair = leftmost pixel, stride = ceil(width / 4) bytes (docs/14 s4).",
        "// GENERATED by tools/make_console_rom.py - do not edit by hand.",
        "module console_text_rom (",
        "    input  wire        clk,",
        "    input  wire [13:0] addr,",
        "    output reg  [7:0]  data",
        ");",
        f"    reg [7:0] rom [0:{DEPTH - 1}] /* fehdl force_ram=1, ram_style=\"bram\" */;",
        "    integer i;",
        "    initial begin",
        f"        for (i = 0; i < {DEPTH}; i = i + 1) rom[i] = 8'h00;",
    ]
    for addr, value in enumerate(data):
        if value:
            lines.append(f"        rom[{addr}] = 8'h{value:02x};")
    lines += ["    end", "    always @(posedge clk) data <= rom[addr];", "endmodule", ""]
    write_lf(SRC / "console_text_rom.v", "\n".join(lines))

    vh = ["// GENERATED by tools/make_console_rom.py - do not edit by hand.",
          f"localparam integer CP_FONT_ROWS = {ROWS};"]
    for i, (name, *_rest) in enumerate(descs):
        vh.append(f"localparam [5:0] CP_{name} = 6'd{i};")
    vh += ["// {base[13:0], stride_bytes[5:0], width[8:0]}",
           "function [28:0] cphrase;", "    input [5:0] id;", "    begin", "        case (id)"]
    for i, (_, base, stride, w) in enumerate(descs):
        assert stride < 64 and w < 512
        vh.append(f"            6'd{i}: cphrase = {{14'd{base}, 6'd{stride}, 9'd{w}}};")
    vh += ["            default: cphrase = 29'd0;", "        endcase", "    end", "endfunction", ""]
    write_lf(SRC / "console_phrases.vh", "\n".join(vh))

    sheet_w = max(w for w, _ in previews) + 8
    sheet = Image.new("RGB", (sheet_w, (ROWS + 4) * len(previews)), (15, 23, 42))
    for i, (w, rows) in enumerate(previews):
        for y, row in enumerate(rows):
            for x in range(w):
                lvl = (row[x >> 2] >> (6 - 2 * (x & 3))) & 3
                if lvl:
                    g = (230 * lvl) // 3
                    sheet.putpixel((4 + x, i * (ROWS + 4) + 2 + y), (g, g, min(255, g + 12)))
    out = args.preview if args.preview else ROOT / "build" / "console_phrases.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    print(f"CONSOLE_ROM_DONE entries={len(descs)} bytes={len(data)} preview={out}")


if __name__ == "__main__":
    main()
