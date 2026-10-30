#!/usr/bin/env python3
"""Render every on-screen phrase of ShengSheng into a 1-bit bitmap ROM.

Each phrase is drawn with the local DengXian Bold font into a 32-row strip,
thresholded to 1 bit and packed row-major (MSB = leftmost pixel). Outputs:
  rtl/shengsheng/ss_phrase_rom.v   byte ROM (block RAM)
  rtl/shengsheng/ss_phrases.vh     phrase ids and a descriptor function
  build/shengsheng_phrases.png     preview sheet for visual review
Cell glyphs (digits, stars, units) keep their natural advance plus 4 px and
must fit the overlay's fixed 24 px score slots; stars and the unit glyph are
drawn a little smaller (CELL_STYLE) so that they do.
"""
from __future__ import annotations

from pathlib import Path
import json
import hashlib

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]          # the dual-board project
RTL = ROOT / "board_b" / "src"
FONT = Path("C:/Windows/Fonts/Dengb.ttf")
UI = json.loads((ROOT / "spec/ui.json").read_text(encoding="utf-8"))
ROWS = 32
SIZE = UI["fonts"]["child_primary_px"]
THRESHOLD = 120


def write_lf(path: Path, text: str, encoding: str = "ascii") -> None:
    """Write with LF endings on any supported Python.

    Path.write_text(..., newline="\\n") would be tidier but that keyword only
    exists from Python 3.10, while this toolchain is 3.8 -- it raises
    TypeError there. The generated files are read by iverilog, so the line
    endings must be exactly LF.
    """
    with open(path, "w", encoding=encoding, newline="\n") as fh:
        fh.write(text)

# (id name, text). Order defines the id. Id 0 must stay blank.
PHRASES = [
    ("BLANK", ""),
    ("BRAND", ""),  # reserved ID 1; the brand lives in PIC1, not the ROM
    ("MODE_TONE", "声调爬山"),
    ("MODE_BALLOON", "吹气球"),
    ("MODE_TRAIN", "音量小火车"),
    ("MODE_CARD", "看图跟读"),
    ("P_MA1", "mā  妈"),
    ("P_MA2", "má  麻"),
    ("P_MA3", "mǎ  马"),
    ("P_MA4", "mà  骂"),
    ("P_MAO", "māo  猫"),
    ("P_YU", "yú  鱼"),
    ("P_GOU", "gǒu  狗"),
    ("P_TU", "tù  兔"),
    ("S_LISTEN_DEMO", "请听示范"),
    ("S_YOUR_TURN", "轮到你说啦"),
    ("F_GREAT", "太棒了！"),
    ("H_STEADY", "保持平稳"),
    ("H_RISE", "尾音上扬"),
    ("H_DIPRISE", "先降再升"),
    ("H_FALL", "用力下降"),
    ("H_LONGER", "说长一点"),
    ("H_LOUDER", "大声一点"),
    ("H_SOFTER", "小声一点"),
    ("F_POP", "气球吹爆啦！"),
    ("F_ARRIVE", "到站啦！"),
    ("F_KEEPUP", "继续加油"),
    ("I_BALLOON", "持续发“啊”"),
    ("I_TRAIN", "按KEY2开始"),
    ("MODE_DISCOVER", "自由探索"),
    ("D_HINT", "试试看"),
    ("D_SUMMARY", "本轮成绩"),
]
CELLS = [
    ("C_0", "0"), ("C_1", "1"), ("C_2", "2"), ("C_3", "3"), ("C_4", "4"),
    ("C_5", "5"), ("C_6", "6"), ("C_7", "7"), ("C_8", "8"), ("C_9", "9"),
    ("C_STAR", "★"), ("C_STAR_EMPTY", "☆"), ("C_SEC", "秒"), ("C_DOT", "."),
]
CELL_W_MAX = 24
# per-cell (font size, vertical offset) overrides so every cell fits 24 px
CELL_STYLE = {"C_STAR": (20, 5), "C_STAR_EMPTY": (20, 5), "C_SEC": (20, 6),
              "C_QUESTIONS": (20, 6), "C_POINTS": (20, 6),
              "SUMMARY_QUESTIONS": (24, 2), "SUMMARY_STARS": (24, 2)}

STATUS_PHRASES = [("WAIT_LINK", "等连接"), ("WAIT_TEACHER", "等老师")]
EXTRA_PHRASES = [("ROUND", "本轮", False),
                 ("SUMMARY_QUESTIONS", "完成题数", False),
                 ("SUMMARY_STARS", "累计星数", False),
                 ("C_QUESTIONS", "题", True), ("C_POINTS", "分", True),
                 ("C_SLASH", "/", True)]


def render(text: str, font, cell: bool, dy: int = 0):
    """Render one strip as 1-bit coverage, 8 pixels per byte (OPT-8, docs/53).

    The text is drawn at 2x in both axes and box-downsampled: each 2x2 block
    averages to a coverage 0..255 that binarises at THRESHOLD, packed 8
    pixels per byte (MSB = leftmost pixel). This halves the ROM to ~15 KB
    (32 -> 16 BRAM9K blocks); the R76 2-bit AA is deliberately traded for
    area here -- the overlay's edge rules soften edge pixels to a 50 % blend
    and the acceptance gates are the preview sheet, the scene counters and
    the board text review (docs/53 section 5, ported to docs/16 L2). The row
    stride in BYTES is (width + 7) // 8 -- main() must use the same formula
    for the descriptor.
    """
    if not text:
        return 0, []
    width = int(font.getlength(text)) + (4 if cell else 2)
    ss = 2
    img = Image.new("L", (width * ss, ROWS * ss), 0)
    draw = ImageDraw.Draw(img)
    # draw with a font at ss x the size: the canvas is ss x larger. Drawing
    # with the 1x font here (the R76 version did) rendered every glyph at
    # HALF size inside a full-size descriptor -- found by the docs/13 S10
    # RTL render (tb_child_scene), fixed 2026-10-02
    big = ImageFont.truetype(font.path, font.size * ss)
    draw.text((2 * ss if cell else ss, dy * ss), text, font=big, fill=255)
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
                    cov = acc // (ss * ss)
                    level = 1 if cov >= THRESHOLD else 0
                byte |= level << (7 - b)
            row.append(byte)
        rows.append(row)
    return width, rows


def main() -> None:
    font = ImageFont.truetype(str(FONT), SIZE)
    entries = ([(n, t, False) for n, t in PHRASES] +
               [(n, t, True) for n, t in CELLS] +
               [(n, t, False) for n, t in STATUS_PHRASES] + EXTRA_PHRASES)
    assert len(entries) <= 64
    assert entries[46][0] == "WAIT_LINK" and entries[47][0] == "WAIT_TEACHER"
    data = []
    descs = []
    previews = []
    manifest = []
    for name, text, cell in entries:
        size, dy = CELL_STYLE.get(name, (SIZE, 0))
        f = font if size == SIZE else ImageFont.truetype(str(FONT), size)
        width, rows = render(text, f, cell, dy)
        if cell:
            assert width <= CELL_W_MAX, (name, width)
        stride = (width + 7) // 8   # 1 bit per pixel (OPT-8, docs/53)
        payload = bytes(v for r in rows for v in r)
        # Offline suffix/prefix sharing stores identical padding bytes once.
        # The FPGA still performs the original base + row*stride addressing;
        # there is no decompressor, extra ROM, new texture or pixel latency.
        overlap = 0
        for count in range(min(len(data), len(payload)), 0, -1):
            if bytes(data[-count:]) == payload[:count]:
                overlap = count
                break
        base = len(data) - overlap
        data.extend(payload[overlap:])
        assert bytes(data[base:base+len(payload)]) == payload, name
        descs.append((name, base, stride, width))
        previews.append((width, rows))
        manifest.append({"id": len(descs)-1, "name": name, "text": text,
                         "base": base, "stride": stride, "width": width,
                         "bitmap_bytes": len(payload), "shared_prefix_bytes": overlap,
                         "bitmap_sha256": hashlib.sha256(payload).hexdigest()})
    assert len(data) <= UI["fonts"]["child_rom_bytes"] == 16384, len(data)
    for name, base, stride, width in descs:
        assert base + stride * ROWS <= 16384, name
        assert stride < 64 and width < 1024, name
    depth = 16384
    lines = [
        "`timescale 1ns/1ps",
        "// Phrase bitmaps (1 bit/pixel, 8 px per byte, MSB = leftmost; OPT-8).",
        "// GENERATED by tools/make_phrase_rom.py - do not edit by hand.",
        "// OPT-2 (docs/53): the read port carries ce -- when the overlay is not",
        "// addressing a text pixel the BRAM output holds, so the word lines stop",
        "// toggling outside the text bands.",
        "module ss_phrase_rom (",
        "    input  wire clk,",
        "    input  wire ce,",
        "    input  wire [13:0] addr,",
        "    output reg  [7:0] data",
        ");",
        "    reg [7:0] rom [0:16383] /* fehdl force_ram=1, ram_style=\"bram\" */;",
        "    integer i;",
        "    initial begin",
        "        for (i = 0; i < 16384; i = i + 1) rom[i] = 8'h00;",
    ]
    for addr, value in enumerate(data):
        if value:
            lines.append(f"        rom[{addr}] = 8'h{value:02x};")
    lines += ["    end", "    always @(posedge clk) if (ce) data <= rom[addr];", "endmodule", ""]
    write_lf(RTL / "ss_phrase_rom.v", "\n".join(lines))

    vh = ["// GENERATED by tools/make_phrase_rom.py - do not edit by hand.",
          "// All descriptors address this 16KB ROM; ID 1 is reserved blank."]
    for index, (name, _, _, _) in enumerate(descs):
        vh.append(f"localparam [5:0] PH_{name} = 6'd{index};")
    vh += [
        "// {base[13:0], stride[6:0], width[9:0]}",
        "function [31:0] phrase_desc;",
        "    input [5:0] id;",
        "    begin",
        "        case (id)",
    ]
    for index, (_, base, stride, width) in enumerate(descs):
        vh.append(f"            6'd{index}: phrase_desc = {{14'd{base}, 7'd{stride}, 10'd{width}}};")
    vh += ["            default: phrase_desc = 32'd0;", "        endcase", "    end",
           "endfunction", ""]
    write_lf(RTL / "ss_phrases.vh", "\n".join(vh))

    # preview sheet
    sheet_w = max(w for w, _ in previews) + 8
    sheet = Image.new("RGB", (sheet_w, (ROWS + 4) * len(previews)), (30, 30, 40))
    for i, (w, rows) in enumerate(previews):
        for y, row in enumerate(rows):
            for x in range(w):
                lvl = (row[x >> 3] >> (7 - (x & 7))) & 1
                if lvl:
                    sheet.putpixel((4 + x, i * (ROWS + 4) + 2 + y), (255, 230, 90))
    out = ROOT / "build" / "shengsheng_phrases.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    (ROOT / "build/phrase_manifest_v7.json").write_text(
        json.dumps({"capacity": depth, "used_bytes": len(data), "entries": manifest,
                    "packing": "byte-exact suffix/prefix sharing, no RTL decoder"},
                   ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"PHRASE_ROM_DONE entries={len(descs)} bytes={len(data)} preview={out}")


if __name__ == "__main__":
    main()
