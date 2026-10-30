`timescale 1ns/1ps

// V8 display-mode caption layer: a 3/4-opaque band along the bottom with a
// seamlessly scrolling slogan (1 px per frame), a title chip for the current
// picture (top left) and a running-time chip (top right, hh:mm:ss since
// power-up -- the board has no real-time clock, so it is labelled 运行).
// Strings come from osd_caption_rom_v8 (tools/make_caption_rom_v8.py);
// every product is a shift and add or a constant table, no DSP.
//
// RGB, DE, VSYNC and X are delayed by two clocks together (address -> ROM
// -> compose). Scroll, digits, picture and enables are latched at frame
// start, so a frame never tears.
module osd_caption_layer_v8 #(
    parameter integer CLKS_PER_SEC = 25000000,
    parameter integer SCROLL_INIT = 0,       // simulation only: start near the wrap
    parameter [23:0]  TIME_INIT = 24'h000000 // simulation only: BCD hhmmss at reset
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    input  wire        show,         // display mode with the player running
    input  wire        band_enable,  // 0 while the SW4 diagnostics own the bottom line
    input  wire [1:0]  picture,
    output reg         vsync_out,
    output reg         de_out,
    output reg  [9:0]  pixel_x_out,
    output reg  [23:0] rgb_out
);
`include "osd_caption_v8.vh"

    localparam integer BAND_Y0 = 446;   // two accent rows, then the dark band to the last line
    localparam integer BAND_Y1 = 480;
    localparam integer BAND_TY = 454;   // 20 text rows centred in the 32 dark rows
    localparam integer CHIP_Y0 = 10;
    localparam integer CHIP_H  = 28;
    localparam integer CHIP_TY = 14;
    localparam integer TITLE_X0 = 12;   // chip 12 .. 36 + title width; text at 24
    localparam integer TITLE_TX = 24;
    localparam integer TIME_X0 = 474;   // chip 474 .. 627
    localparam integer TIME_X1 = 628;
    localparam integer LABEL_X = 486;   // 运行: 40 px of ink from column 1, 44 px region
    localparam integer DIGIT_X = 532;   // cells 12 12 6 12 12 6 12 12 = 84 px

    localparam [23:0] C_DARK_Q = 24'h221E1A;   // #2E2823 * 3/4
    localparam [23:0] C_ACCENT = 24'hC25A1A;   // same orange as the panel's lit segments
    localparam [23:0] C_TEXT   = 24'hFFF6E9;
    localparam [23:0] C_LABEL  = 24'hD9CBB8;
    localparam [10:0] SLOGAN_W = CAP_SLOGAN_W;
    localparam [11:0] BTY0 = BAND_TY;
    localparam [11:0] CY0  = CHIP_Y0;
    localparam [11:0] CTY0 = CHIP_TY;
    localparam [11:0] CH_M1 = CHIP_H - 1;

    // ---------------------------------------------------- line counter
    reg [11:0] line_y;
    reg de_d, vs_d;
    wire frame_start = vs_d && !vsync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0; de_d <= 1'b0; vs_d <= 1'b1;
        end else begin
            de_d <= de; vs_d <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_d && !de)
                line_y <= line_y + 1'b1;
        end
    end

    // ---------------------------------------------------- running time (BCD)
    reg [24:0] sec_div;
    reg [3:0] s0, s1, m0, m1, h0, h1;
    wire sec_tick = (sec_div == CLKS_PER_SEC - 1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_div <= 25'd0;
            {h1, h0, m1, m0, s1, s0} <= TIME_INIT;
        end else begin
            sec_div <= sec_tick ? 25'd0 : sec_div + 1'b1;
            if (sec_tick) begin
                if (s0 != 4'd9) s0 <= s0 + 1'b1;
                else begin
                    s0 <= 4'd0;
                    if (s1 != 4'd5) s1 <= s1 + 1'b1;
                    else begin
                        s1 <= 4'd0;
                        if (m0 != 4'd9) m0 <= m0 + 1'b1;
                        else begin
                            m0 <= 4'd0;
                            if (m1 != 4'd5) m1 <= m1 + 1'b1;
                            else begin
                                m1 <= 4'd0;
                                if (h0 != 4'd9) h0 <= h0 + 1'b1;
                                else begin
                                    h0 <= 4'd0;
                                    h1 <= (h1 == 4'd9) ? 4'd0 : h1 + 1'b1;   // 99:59:59 -> 00:00:00
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    // ---------------------------------------------------- per-frame values
    reg        f_show, f_band;
    reg [1:0]  f_pic;
    reg [9:0]  f_scroll;
    reg [23:0] f_time;           // {h1, h0, m1, m0, s1, s0}
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_show <= 1'b0; f_band <= 1'b0; f_pic <= 2'd0;
            f_scroll <= SCROLL_INIT; f_time <= 24'd0;
        end else if (frame_start) begin
            f_show <= show; f_band <= band_enable; f_pic <= picture;
            f_time <= {h1, h0, m1, m0, s1, s0};
            f_scroll <= (f_scroll == SLOGAN_W - 1) ? 10'd0 : f_scroll + 1'b1;
        end
    end

    // ---------------------------------------------------- stage A: geometry
    // rounded corners, radius 8: inset of the first five rows (as the panel)
    function [2:0] corner_inset;
        input [4:0] r;
        begin
            case (r)
                5'd0: corner_inset = 3'd5;
                5'd1: corner_inset = 3'd3;
                5'd2: corner_inset = 3'd2;
                5'd3, 5'd4: corner_inset = 3'd1;
                default: corner_inset = 3'd0;
            endcase
        end
    endfunction

    // chips
    wire in_chip_y = line_y >= CHIP_Y0 && line_y < CHIP_Y0 + CHIP_H;
    wire [11:0] cy = line_y - CY0;
    wire [11:0] cy_rev = CH_M1 - cy;
    wire [4:0] chip_row = (cy < CHIP_H / 2) ? cy[4:0] : cy_rev[4:0];
    wire [2:0] inset = corner_inset(chip_row);
    wire chip_text_row = line_y >= CHIP_TY && line_y < CHIP_TY + 20;
    wire [11:0] crow_w = line_y - CTY0;
    wire [4:0] crow = crow_w[4:0];

    wire [7:0] tw = cap_title_w(f_pic);
    wire [9:0] title_x1 = 10'd36 + {2'd0, tw};
    wire [9:0] t_left = pixel_x - TITLE_X0;
    wire [9:0] t_right = title_x1 - 10'd1 - pixel_x;
    wire in_title = f_show && de && in_chip_y && pixel_x >= TITLE_X0 && pixel_x < title_x1 &&
                    t_left >= inset && t_right >= inset;
    wire [9:0] m_left = pixel_x - TIME_X0;
    wire [9:0] m_right = TIME_X1 - 1 - pixel_x;
    wire in_time = f_show && de && in_chip_y && pixel_x >= TIME_X0 && pixel_x < TIME_X1 &&
                   m_left >= inset && m_right >= inset;

    // title n: TITLE_BASE + n*320 + row*16 + x/8
    wire [9:0] tx = pixel_x - TITLE_TX;
    wire in_title_txt = in_title && chip_text_row && pixel_x >= TITLE_TX && pixel_x < TITLE_TX + 128;
    wire [11:0] title_addr = CAP_TITLE_BASE + {2'd0, f_pic, 8'd0} + {4'd0, f_pic, 6'd0} +
                             {3'd0, crow, 4'd0} + {8'd0, tx[6:3]};
    // label: LABEL_BASE + row*6 + x/8
    wire [9:0] lx = pixel_x - LABEL_X;
    wire in_label_txt = in_time && chip_text_row && pixel_x >= LABEL_X && pixel_x < LABEL_X + 44;
    wire [11:0] label_addr = CAP_LABEL_BASE + {5'd0, crow, 2'd0} + {6'd0, crow, 1'd0} +
                             {9'd0, lx[5:3]};
    // digits: glyph g (10 = ':') at DIGIT_BASE + g*40 + row*2 + col/8
    wire [9:0] dx = pixel_x - DIGIT_X;
    wire in_digit_txt = in_time && chip_text_row && pixel_x >= DIGIT_X && pixel_x < DIGIT_X + 84;
    reg [3:0] glyph;
    reg [9:0] dc;
    always @* begin
        if      (dx < 10'd12) begin glyph = f_time[23:20]; dc = dx; end
        else if (dx < 10'd24) begin glyph = f_time[19:16]; dc = dx - 10'd12; end
        else if (dx < 10'd30) begin glyph = 4'd10;         dc = dx - 10'd24; end
        else if (dx < 10'd42) begin glyph = f_time[15:12]; dc = dx - 10'd30; end
        else if (dx < 10'd54) begin glyph = f_time[11:8];  dc = dx - 10'd42; end
        else if (dx < 10'd60) begin glyph = 4'd10;         dc = dx - 10'd54; end
        else if (dx < 10'd72) begin glyph = f_time[7:4];   dc = dx - 10'd60; end
        else                  begin glyph = f_time[3:0];   dc = dx - 10'd72; end
    end
    wire [11:0] digit_addr = CAP_DIGIT_BASE + {3'd0, glyph, 5'd0} + {5'd0, glyph, 3'd0} +
                             {6'd0, crow, 1'd0} + {11'd0, dc[3]};

    // band: the slogan strip tiles with period SLOGAN_W
    wire in_band = f_show && f_band && de && line_y >= BAND_Y0 && line_y < BAND_Y1;
    wire band_accent = in_band && line_y < BAND_Y0 + 2;
    wire in_band_txt = in_band && line_y >= BAND_TY && line_y < BAND_TY + 20;
    wire [10:0] sx_raw = {1'b0, pixel_x} + {1'b0, f_scroll};
    wire [10:0] sx = (sx_raw >= SLOGAN_W) ? sx_raw - SLOGAN_W : sx_raw;
    wire [11:0] brow_w = line_y - BTY0;
    wire [11:0] band_addr = cap_slogan_row(brow_w[4:0]) + {4'd0, sx[10:3]};

    // the four text regions never overlap, so one ROM port serves them all
    wire any_txt = in_band_txt || in_title_txt || in_label_txt || in_digit_txt;
    wire [11:0] rom_addr = in_band_txt  ? band_addr :
                           in_title_txt ? title_addr :
                           in_label_txt ? label_addr : digit_addr;
    wire [2:0] bit_sel = in_band_txt  ? sx[2:0] :
                         in_title_txt ? tx[2:0] :
                         in_label_txt ? lx[2:0] : dc[2:0];
    wire [7:0] rom_data;
    osd_caption_rom_v8 u_rom (.clk(clk), .ce(any_txt), .addr(rom_addr), .data(rom_data));

    reg        a_de, a_vs, a_box, a_accent, a_txt, a_label;
    reg [2:0]  a_bit;
    reg [9:0]  a_x;
    reg [23:0] a_rgb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_de <= 1'b0; a_vs <= 1'b1; a_x <= 10'd0; a_rgb <= 24'd0;
            a_box <= 1'b0; a_accent <= 1'b0; a_txt <= 1'b0; a_label <= 1'b0; a_bit <= 3'd0;
        end else begin
            a_de <= de; a_vs <= vsync; a_x <= pixel_x; a_rgb <= rgb_in;
            a_box <= in_band || in_title || in_time;
            a_accent <= band_accent;
            a_txt <= any_txt;
            a_label <= in_label_txt;
            a_bit <= bit_sel;
        end
    end

    // ---------------------------------------------------- stage B: compose
    wire text_on = a_txt && rom_data[3'd7 - a_bit];
    wire [23:0] quarter = (a_rgb >> 2) & 24'h3F3F3F;
    wire [23:0] out_rgb = a_accent ? C_ACCENT :
                          !a_box ? a_rgb :
                          text_on ? (a_label ? C_LABEL : C_TEXT) :
                          quarter + C_DARK_Q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 1'b0; vsync_out <= 1'b1; pixel_x_out <= 10'd0; rgb_out <= 24'd0;
        end else begin
            de_out <= a_de; vsync_out <= a_vs; pixel_x_out <= a_x; rgb_out <= out_rgb;
        end
    end
endmodule
