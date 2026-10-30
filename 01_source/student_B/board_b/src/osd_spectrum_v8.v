`timescale 1ns/1ps

// V8 F4 spectrum overlay: 16 bars of the music being played, drawn in a
// 3/4-opaque chip at the top centre of the display-mode screen, between the
// title chip and the running-time chip (same height, rows 10..37).
// Heights come from spectrum_analyzer_v8 (0..32). Once per video frame the
// bars follow them (state in a 16-stage ring, see below) with an instant
// attack and an F4_RELEASE px/frame fall;
// a cream peak cap holds F4_PEAK_HOLD frames, then falls 1 px per frame.
// Rule shared with tools/model_f4_v8.py (class Bars). No multiplier.
//
// RGB, DE, VSYNC and X are delayed by two clocks together.
module osd_spectrum_v8 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    input  wire        show,
    input  wire [95:0] heights,      // band b in [6b+5:6b]
    output reg         vsync_out,
    output reg         de_out,
    output reg  [9:0]  pixel_x_out,
    output reg  [23:0] rgb_out
);
`include "spectrum_v8_tables.vh"

    // chip x 169..457, rows 10..37; bars 13 px wide on a 17 px pitch from
    // x 179, bottom row 35; 1 px baseline on row 36
    localparam [9:0]  CHIP_X0 = 10'd169;
    localparam [9:0]  CHIP_X1 = 10'd458;     // exclusive
    localparam [11:0] CHIP_Y0 = 12'd10;
    localparam [11:0] CHIP_Y1 = 12'd38;      // exclusive
    localparam [9:0]  BAR_X0  = 10'd179;
    localparam [9:0]  BAR_X1  = 10'd447;     // exclusive: 179 + 15*17 + 13
    localparam [11:0] BASE_Y  = 12'd36;      // bars end above this row
    localparam [23:0] C_DARK_Q = 24'h221E1A; // #2E2823 * 3/4, as the chips
    localparam [23:0] C_BASE_Q = 24'h4A433C; // baseline, * 3/4
    localparam [23:0] C_CAP    = 24'hFFF6E9;

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

    // ---------------------------------------------------- column counter
    // c_col / c_sub describe the CURRENT pixel: c_col 0..15 inside the bar
    // area, 16 outside; c_sub 0..16 within a 17 px pitch (13 px bar + 4 gap)
    reg [4:0] c_col;
    reg [4:0] c_sub;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_col <= 5'd16; c_sub <= 5'd0;
        end else if (de) begin
            if (pixel_x == BAR_X0 - 10'd1) begin
                c_col <= 5'd0; c_sub <= 5'd0;
            end else if (c_sub == 5'd16) begin
                c_sub <= 5'd0;
                if (c_col != 5'd16) c_col <= c_col + 1'b1;
            end else
                c_sub <= c_sub + 1'b1;
        end
    end

    // ---------------------------------------------------- bar state ring
    // The 16 band states {level, peak, hold} sit in a 16-stage ring and only
    // the head is read, so there is no 16-way read or write multiplexer.
    // The ring turns exactly 16 steps per pass and so always comes back to
    // band 0 at the head:
    //   - once per frame, in the 16 clocks after frame start (vertical
    //     sync, no active pixels): the head is updated against band ub's
    //     target on its way to the tail;
    //   - on every active line, on the last pixel of each band's 17 px
    //     pitch, so the head is the band being drawn.
    // Targets are sampled from `heights` band by band in those 16 clocks;
    // the analyzer publishes all 16 at once about every 4.4 frames, so a
    // frame mixes two windows only if that publish lands in the same 16
    // clocks (the next frame is then whole again).
    reg [5:0] r_lvl  [0:15];
    reg [5:0] r_peak [0:15];
    reg [4:0] r_hold [0:15];
    reg        upd;
    reg [3:0]  ub;
    reg        f_show;
    wire [5:0] h_lvl  = r_lvl[0];
    wire [5:0] h_peak = r_peak[0];
    wire [4:0] h_hold = r_hold[0];
    wire [5:0] t_b = heights[ub*6 +: 6];
    wire [5:0] fall = (h_lvl > F4_RELEASE) ? h_lvl - F4_RELEASE : 6'd0;
    wire [5:0] l_new = (t_b >= h_lvl) ? t_b : ((fall > t_b) ? fall : t_b);
    wire       p_up  = (l_new >= h_peak);
    wire [5:0] p_new = p_up ? l_new :
                       (h_hold != 5'd0 || h_peak == 6'd0) ? h_peak : h_peak - 1'b1;
    wire [4:0] o_new = p_up ? F4_PEAK_HOLD : (h_hold != 5'd0) ? h_hold - 1'b1 : 5'd0;
    wire col_step = de && (c_col != 5'd16) && (c_sub == 5'd16);
    wire rotate = upd || col_step;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) begin
                r_lvl[i] <= 6'd0; r_peak[i] <= 6'd0; r_hold[i] <= 5'd0;
            end
            upd <= 1'b0; ub <= 4'd0; f_show <= 1'b0;
        end else begin
            if (rotate) begin
                for (i = 0; i < 15; i = i + 1) begin
                    r_lvl[i] <= r_lvl[i+1]; r_peak[i] <= r_peak[i+1]; r_hold[i] <= r_hold[i+1];
                end
                r_lvl[15]  <= upd ? l_new : h_lvl;
                r_peak[15] <= upd ? p_new : h_peak;
                r_hold[15] <= upd ? o_new : h_hold;
            end
            if (frame_start) begin
                upd <= 1'b1; ub <= 4'd0; f_show <= show;
            end else if (upd) begin
                ub <= ub + 1'b1;
                if (ub == 4'd15) upd <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------- stage A
    // rounded corners, radius 8 (as the caption chips)
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
    // displayed px = h * 11/16 (0..22)
    function [4:0] disp;
        input [5:0] h;
        begin
            disp = h[5:1] + {2'd0, h[5:3]} + {3'd0, h[5:4]};
        end
    endfunction
    wire [11:0] cy = line_y - CHIP_Y0;
    wire [11:0] cy_rev = CHIP_Y1 - 12'd1 - line_y;
    wire [4:0]  crow = (cy < cy_rev) ? cy[4:0] : cy_rev[4:0];
    wire [2:0]  inset = corner_inset(crow);
    wire [9:0]  cx_l = pixel_x - CHIP_X0;
    wire [9:0]  cx_r = CHIP_X1 - 10'd1 - pixel_x;
    wire in_chip = f_show && de && pixel_x >= CHIP_X0 && pixel_x < CHIP_X1 &&
                   line_y >= CHIP_Y0 && line_y < CHIP_Y1 && cx_l >= inset && cx_r >= inset;
    // c_col is 16 everywhere outside the bar area (before x 179 it still
    // holds the 16 it reached at the end of the previous line)
    wire in_cols = (c_col != 5'd16) && (c_sub < 5'd13);
    wire [3:0] band = c_col[3:0];
    wire [4:0] hpx = disp(h_lvl);
    wire [4:0] ppx = disp(h_peak);
    wire bar_on = in_chip && in_cols && line_y < BASE_Y && line_y >= BASE_Y - hpx;
    // 2 px cap on the two rows just above the peak height, for a raised peak:
    // rows [BASE_Y - ppx - 2, BASE_Y - ppx)
    wire [11:0] y_plus = line_y + {7'd0, ppx};
    wire cap_on = in_chip && in_cols && h_peak != 6'd0 &&
                  y_plus < BASE_Y && y_plus + 12'd2 >= BASE_Y;
    wire base_on = in_chip && pixel_x >= BAR_X0 && pixel_x < BAR_X1 && line_y == BASE_Y;

    reg        a_de, a_vs, a_chip, a_bar, a_cap, a_base;
    reg [3:0]  a_band;
    reg [9:0]  a_x;
    reg [23:0] a_rgb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_de <= 1'b0; a_vs <= 1'b1; a_x <= 10'd0; a_rgb <= 24'd0;
            a_chip <= 1'b0; a_bar <= 1'b0; a_cap <= 1'b0; a_base <= 1'b0; a_band <= 4'd0;
        end else begin
            a_de <= de; a_vs <= vsync; a_x <= pixel_x; a_rgb <= rgb_in;
            a_chip <= in_chip; a_bar <= bar_on; a_cap <= cap_on && !bar_on;
            a_base <= base_on; a_band <= band;
        end
    end

    // ---------------------------------------------------- stage B
    wire [23:0] quarter = (a_rgb >> 2) & 24'h3F3F3F;
    wire [23:0] out_rgb = !a_chip ? a_rgb :
                          a_bar  ? f4_bar_rgb(a_band) :
                          a_cap  ? C_CAP :
                          a_base ? quarter + C_BASE_Q : quarter + C_DARK_Q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 1'b0; vsync_out <= 1'b1; pixel_x_out <= 10'd0; rgb_out <= 24'd0;
        end else begin
            de_out <= a_de; vsync_out <= a_vs; pixel_x_out <= a_x; rgb_out <= out_rgb;
        end
    end
endmodule
