`timescale 1ns/1ps

// V8 parameter panel: shows the parameter changed last -- Chinese label,
// Chinese value and a segment bar -- while `show` is high (the top holds it
// for 3 s after any adjustment). Strings come from osd_panel_rom_v8
// (tools/make_osd_rom_v8.py). Every product is a shift and add; no DSP.
//
// F7 removes the baked-in help cards from all four TF pictures. This opaque
// 320-pixel card appears only during a parameter change, below the cover
// title / training playfield and above the F3 caption band at y=446.
//   picture 0:   x 160..479, y 352..423
//   pictures 1-3: x 160..479, y 374..437
// Both cards are centred on x=320; the content x positions stay fixed.
//
// Placed after shengsheng_overlay: RGB, DE, VSYNC and X are delayed by two
// clocks together (address -> ROM -> compose), like the overlay before it.
// Parameter values are latched at frame start so a change never tears.
//
// kind: 0 brightness, 1 contrast, 2 volume, 3 slideshow period,
//       4 transition style, 5 difficulty
module osd_param_panel_v8 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    input  wire        show,
    input  wire [1:0]  picture,      // selects the card geometry
    input  wire [2:0]  kind,
    input  wire [7:0]  brightness,   // 255 / 192 / 128 / 64
    input  wire [2:0]  contrast,     // 0..4 = 50..150 %
    input  wire [7:0]  volume,       // 0 / 64 / 128 / 192 / 255
    input  wire [31:0] period_ms,
    input  wire [1:0]  style,        // 0 classic, 1 up, 2 down, 3 rotate
    input  wire [1:0]  difficulty,
    output reg         vsync_out,
    output reg         de_out,
    output reg  [9:0]  pixel_x_out,
    output reg  [23:0] rgb_out
);
`include "osd_panel_v8.vh"

    // label slot + value + bar = 282 px, centred on x = 319; labels are
    // right-aligned in their slot, so every label ends 8 px before its value
    localparam integer LABEL_X = 178;
    localparam integer VALUE_X = LABEL_X + 70;
    localparam integer BAR_X   = VALUE_X + 62;
    localparam integer BAR_W   = 150;
    localparam integer BAR_H   = 14;
    localparam [9:0]  LX0 = LABEL_X;
    localparam [9:0]  VX0 = VALUE_X;
    localparam [9:0]  BX0 = BAR_X;

    localparam [23:0] C_FILL0   = 24'hE7EEF8;   // picture-0 card (light blue)
    localparam [23:0] C_FILL1   = 24'hFFF6E9;   // picture 1-3 card (cream)
    // luminance ladder fill > empty > lit, so the bar does not rely on hue:
    // lit vs fill 3.8 / 4.1 : 1, lit vs empty 2.4 / 2.6 : 1, empty vs fill 1.6 : 1
    localparam [23:0] C_EMPTY0  = 24'hB4C1D2;
    localparam [23:0] C_EMPTY1  = 24'hD2C3AE;
    localparam [23:0] C_ACCENT  = 24'hC25A1A;
    localparam [23:0] C_LABEL   = 24'h7A6A58;
    localparam [23:0] C_VALUE   = 24'h3C3125;

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

    // ---------------------------------------------------- per-frame values
    reg        f_show;
    reg        f_g1;          // 0: picture-0 card, 1: picture 1-3 card
    reg [2:0]  f_label;
    reg [4:0]  f_value;
    reg        f_seg5;        // 5 segments instead of 4
    reg        f_single;      // light only segment f_level (style)
    reg [2:0]  f_level;       // segments lit: idx < f_level, or idx == f_level
    reg [2:0]  n_label;
    reg [4:0]  n_value;
    reg        n_seg5, n_single;
    reg [2:0]  n_level;
    always @* begin
        n_label = OSDL_BRIGHT; n_value = OSDV_P100; n_seg5 = 1'b0;
        n_single = 1'b0; n_level = 3'd4;
        case (kind)
            3'd0: begin
                n_label = OSDL_BRIGHT;
                case (brightness)
                    8'd255: begin n_value = OSDV_P100; n_level = 3'd4; end
                    8'd192: begin n_value = OSDV_P75;  n_level = 3'd3; end
                    8'd128: begin n_value = OSDV_P50;  n_level = 3'd2; end
                    default: begin n_value = OSDV_P25; n_level = 3'd1; end
                endcase
            end
            3'd1: begin
                n_label = OSDL_CONTRAST; n_seg5 = 1'b1;
                case (contrast)
                    3'd0: begin n_value = OSDV_P50;  n_level = 3'd1; end
                    3'd1: begin n_value = OSDV_P75;  n_level = 3'd2; end
                    3'd2: begin n_value = OSDV_P100; n_level = 3'd3; end
                    3'd3: begin n_value = OSDV_P125; n_level = 3'd4; end
                    default: begin n_value = OSDV_P150; n_level = 3'd5; end
                endcase
            end
            3'd2: begin
                n_label = OSDL_VOLUME;
                case (volume)
                    8'd0:   begin n_value = OSDV_MUTE; n_level = 3'd0; end
                    8'd64:  begin n_value = OSDV_P25;  n_level = 3'd1; end
                    8'd128: begin n_value = OSDV_P50;  n_level = 3'd2; end
                    8'd192: begin n_value = OSDV_P75;  n_level = 3'd3; end
                    default: begin n_value = OSDV_P100; n_level = 3'd4; end
                endcase
            end
            3'd3: begin
                n_label = OSDL_PERIOD;
                if (period_ms < 32'd3500)       begin n_value = OSDV_S2;  n_level = 3'd1; end
                else if (period_ms < 32'd7500)  begin n_value = OSDV_S5;  n_level = 3'd2; end
                else if (period_ms < 32'd20000) begin n_value = OSDV_S10; n_level = 3'd3; end
                else                            begin n_value = OSDV_S30; n_level = 3'd4; end
            end
            3'd4: begin
                // bar order follows the KEY2 ladder: rotate, classic, up, down
                n_label = OSDL_STYLE; n_single = 1'b1;
                n_level = {1'b0, style + 2'd1};
                n_value = OSDV_ROTATE + {3'd0, style + 2'd1};
            end
            default: begin
                n_label = OSDL_DIFF;
                n_value = OSDV_L1 + {3'd0, difficulty};
                n_level = {1'b0, difficulty} + 3'd1;
            end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_show <= 1'b0; f_g1 <= 1'b0; f_label <= 3'd0; f_value <= 5'd0;
            f_seg5 <= 1'b0; f_single <= 1'b0; f_level <= 3'd0;
        end else if (frame_start) begin
            f_show <= show; f_g1 <= (picture != 2'd0);
            f_label <= n_label; f_value <= n_value;
            f_seg5 <= n_seg5; f_single <= n_single; f_level <= n_level;
        end
    end

    // ---------------------------------------------------- stage A: geometry
    // rounded corners, radius 8: inset of the first five rows
    function [2:0] corner_inset;
        input [5:0] r;
        begin
            case (r)
                6'd0: corner_inset = 3'd5;
                6'd1: corner_inset = 3'd3;
                6'd2: corner_inset = 3'd2;
                6'd3, 6'd4: corner_inset = 3'd1;
                default: corner_inset = 3'd0;
            endcase
        end
    endfunction
    wire [9:0]  gx0   = 10'd160;
    wire [9:0]  gx1   = 10'd480;     // exclusive
    wire [11:0] gy0   = f_g1 ? 12'd374 : 12'd352;
    wire [11:0] gh_m1 = f_g1 ? 12'd63  : 12'd71;      // height - 1
    wire [11:0] gty   = f_g1 ? 12'd396 : 12'd378;     // text rows, centred
    wire [11:0] gby   = f_g1 ? 12'd399 : 12'd381;     // bar rows, centred
    wire [9:0]  px = pixel_x - gx0;
    wire [9:0]  px_rev = gx1 - 10'd1 - pixel_x;
    wire [11:0] py = line_y - gy0;
    wire [11:0] py_rev = gh_m1 - py;
    wire in_box = f_show && de && pixel_x >= gx0 && pixel_x < gx1 &&
                  line_y >= gy0 && line_y <= gy0 + gh_m1;
    wire [11:0] edge_row = (py < py_rev) ? py : py_rev;
    wire [2:0] inset = corner_inset(edge_row[5:0]);
    wire in_panel = in_box && px >= inset && px_rev >= inset;

    wire in_text_row = line_y >= gty && line_y < gty + 12'd20;
    wire in_label = in_panel && in_text_row && pixel_x >= LABEL_X && pixel_x < LABEL_X + 64;
    wire in_value = in_panel && in_text_row && pixel_x >= VALUE_X && pixel_x < VALUE_X + 48;
    wire [11:0] trow_w = line_y - gty;
    wire [4:0] trow = trow_w[4:0];
    wire [9:0] lx_w = pixel_x - LX0;
    wire [5:0] lx = lx_w[5:0];
    wire [9:0] vx_w = pixel_x - VX0;
    wire [5:0] vx = vx_w[5:0];
    // label n at n*160 + row*8 + x/8; value n at OSDV_BASE + n*120 + row*6 + x/8
    wire [11:0] label_addr = {f_label, 7'd0} + {2'd0, f_label, 5'd0} +
                             {4'd0, trow, 3'd0} + {9'd0, lx[5:3]};
    wire [11:0] value_addr = OSDV_BASE + {f_value, 7'd0} - {4'd0, f_value, 3'd0} +
                             {5'd0, trow, 2'd0} + {6'd0, trow, 1'd0} + {9'd0, vx[5:3]};
    wire [11:0] rom_addr = in_label ? label_addr : value_addr;
    wire [7:0]  rom_data;
    osd_panel_rom_v8 u_rom (.clk(clk), .ce(in_label || in_value), .addr(rom_addr), .data(rom_data));

    // bar: 4 segments of 34 px on a 38 px pitch, or 5 of 26 px on 31 px
    wire [9:0] bx = pixel_x - BX0;
    wire in_bar = in_panel && pixel_x >= BAR_X && pixel_x < BAR_X + BAR_W &&
                  line_y >= gby && line_y < gby + BAR_H;
    reg       seg_on;
    reg [2:0] seg_idx;
    always @* begin
        seg_on = 1'b0; seg_idx = 3'd0;
        if (f_seg5) begin
            if      (bx < 10'd26)  begin seg_on = 1'b1; seg_idx = 3'd0; end
            else if (bx < 10'd31)  seg_on = 1'b0;
            else if (bx < 10'd57)  begin seg_on = 1'b1; seg_idx = 3'd1; end
            else if (bx < 10'd62)  seg_on = 1'b0;
            else if (bx < 10'd88)  begin seg_on = 1'b1; seg_idx = 3'd2; end
            else if (bx < 10'd93)  seg_on = 1'b0;
            else if (bx < 10'd119) begin seg_on = 1'b1; seg_idx = 3'd3; end
            else if (bx < 10'd124) seg_on = 1'b0;
            else                   begin seg_on = 1'b1; seg_idx = 3'd4; end
        end else begin
            if      (bx < 10'd34)  begin seg_on = 1'b1; seg_idx = 3'd0; end
            else if (bx < 10'd38)  seg_on = 1'b0;
            else if (bx < 10'd72)  begin seg_on = 1'b1; seg_idx = 3'd1; end
            else if (bx < 10'd76)  seg_on = 1'b0;
            else if (bx < 10'd110) begin seg_on = 1'b1; seg_idx = 3'd2; end
            else if (bx < 10'd114) seg_on = 1'b0;
            else if (bx < 10'd148) begin seg_on = 1'b1; seg_idx = 3'd3; end
            else                   seg_on = 1'b0;
        end
    end
    wire seg_lit = f_single ? (seg_idx == f_level) : (seg_idx < f_level);

    reg        a_de, a_vs, a_panel, a_label, a_value, a_seg, a_lit, a_g1;
    reg [2:0]  a_bit;
    reg [9:0]  a_x;
    reg [23:0] a_rgb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_de <= 1'b0; a_vs <= 1'b1; a_x <= 10'd0; a_rgb <= 24'd0;
            a_panel <= 1'b0; a_label <= 1'b0; a_value <= 1'b0;
            a_seg <= 1'b0; a_lit <= 1'b0; a_g1 <= 1'b0; a_bit <= 3'd0;
        end else begin
            a_de <= de; a_vs <= vsync; a_x <= pixel_x; a_rgb <= rgb_in;
            a_panel <= in_panel; a_label <= in_label; a_value <= in_value;
            a_seg <= in_bar && seg_on; a_lit <= seg_lit; a_g1 <= f_g1;
            a_bit <= in_label ? lx[2:0] : vx[2:0];
        end
    end

    // ---------------------------------------------------- stage B: compose
    wire text_on = (a_label || a_value) && rom_data[3'd7 - a_bit];
    wire [23:0] out_rgb = !a_panel ? a_rgb :
                          text_on ? (a_label ? C_LABEL : C_VALUE) :
                          a_seg ? (a_lit ? C_ACCENT : (a_g1 ? C_EMPTY1 : C_EMPTY0)) :
                          (a_g1 ? C_FILL1 : C_FILL0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 1'b0; vsync_out <= 1'b1; pixel_x_out <= 10'd0; rgb_out <= 24'd0;
        end else begin
            de_out <= a_de; vsync_out <= a_vs; pixel_x_out <= a_x; rgb_out <= out_rgb;
        end
    end
endmodule
