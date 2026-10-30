`timescale 1ns/1ps

// P0 board-mounted 8-digit seven-segment display (docs/08 section 5). Shows
// the live training state so the learner does not have to face the HDMI
// screen: D7..D0 = {level% tens, level% ones, mode, tone, stars,
// score hundreds, score tens, score ones}, zero-padded.
//
// Clocking: the scanner runs on sys_clk (50 MHz) with a 1 ms digit period
// (1 kHz per digit, 125 Hz full-frame refresh). The input values live in the
// video domain, so every bit crosses through a 2-flop synchroniser inside
// this module (same treatment as the other slow control buses in the top).
// The buses only change between utterances / menu events, so a one-frame
// tear shows a briefly mixed digit at worst, corrected on the next scan.
//
// Polarity is taken verbatim from the official board demo
// 4_seg_led_static_top: both segment and digit lines are ACTIVE LOW, with
// seg_led[0..6] = segments a..g and seg_led[7] = dp. The demo's decode table
// ('0' = 8'b1100_0000, a..f lit, g/dp off) is reused unchanged.
module seven_seg_display #(
    parameter integer CLKS_PER_DIGIT = 50000    // 50 MHz / 50000 = 1 kHz
) (
    input  wire       clk,         // sys_clk, 50 MHz
    input  wire       rst_n,
    // video-domain values (synchronised internally)
    input  wire [6:0] score,       // sc_score, 0..100
    input  wire [1:0] stars,       // sc_stars, 0..3
    input  wire [2:0] tone,        // sc_tone, 0..4
    input  wire [2:0] mode,        // game mode, 0..4
    input  wire [7:0] level,       // streamed feature level, 0..255
    // Stable system-domain storage fault snapshot, D7..D0 hexadecimal.
    input  wire       diagnostic_valid,
    input  wire [31:0] diagnostic_data,
    output reg  [7:0] seg_led,     // active-low segments a..dp
    output reg  [7:0] seg_sel      // active-low digit select, D7..D0
);
    // ---- 2FF synchronisation of the video-domain inputs ----
    reg score_s1  [0:6];
    reg score_s2  [0:6];
    reg stars_s1  [0:1];
    reg stars_s2  [0:1];
    reg tone_s1   [0:2];
    reg tone_s2   [0:2];
    reg mode_s1   [0:2];
    reg mode_s2   [0:2];
    reg level_s1  [0:7];
    reg level_s2  [0:7];
    wire [6:0] score_sync;
    wire [1:0] stars_sync;
    wire [2:0] tone_sync;
    wire [2:0] mode_sync;
    wire [7:0] level_sync;
    genvar b;
    generate
        for (b = 0; b < 7; b = b + 1) begin : g_sync_score
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    score_s1[b] <= 1'b0;
                    score_s2[b] <= 1'b0;
                end else begin
                    score_s1[b] <= score[b];
                    score_s2[b] <= score_s1[b];
                end
            end
            assign score_sync[b] = score_s2[b];
        end
        for (b = 0; b < 2; b = b + 1) begin : g_sync_stars
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    stars_s1[b] <= 1'b0;
                    stars_s2[b] <= 1'b0;
                end else begin
                    stars_s1[b] <= stars[b];
                    stars_s2[b] <= stars_s1[b];
                end
            end
            assign stars_sync[b] = stars_s2[b];
        end
        for (b = 0; b < 3; b = b + 1) begin : g_sync_tone_mode_a
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tone_s1[b] <= 1'b0;
                    tone_s2[b] <= 1'b0;
                end else begin
                    tone_s1[b] <= tone[b];
                    tone_s2[b] <= tone_s1[b];
                end
            end
            assign tone_sync[b] = tone_s2[b];
        end
        for (b = 0; b < 3; b = b + 1) begin : g_sync_mode
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    mode_s1[b] <= 1'b0;
                    mode_s2[b] <= 1'b0;
                end else begin
                    mode_s1[b] <= mode[b];
                    mode_s2[b] <= mode_s1[b];
                end
            end
            assign mode_sync[b] = mode_s2[b];
        end
        for (b = 0; b < 8; b = b + 1) begin : g_sync_level
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    level_s1[b] <= 1'b0;
                    level_s2[b] <= 1'b0;
                end else begin
                    level_s1[b] <= level[b];
                    level_s2[b] <= level_s1[b];
                end
            end
            assign level_sync[b] = level_s2[b];
        end
    endgenerate

    // ---- BCD decode ----
    // level percent = level*100/256, two decimal digits (0..99)
    wire [13:0] lvl_prod   = level_sync * 7'd25;        // 255*25 = 6375
    wire [6:0]  pct        = lvl_prod[13:6];            // 0..99
    wire [14:0] pct_pr     = {1'b0, pct} * 13'd205;     // 99*205 = 20295
    wire [3:0]  pct_tens   = pct_pr[14:11];             // exact for pct <= 102
    wire [3:0]  pct_ones_w = pct[6:0] - ((pct_tens << 3) + (pct_tens << 1));

    // score 0..100 in three decimal digits
    wire        is100      = (score_sync == 7'd100);
    wire [6:0]  sub100     = is100 ? 7'd0 : score_sync;
    wire [14:0] tens_pr    = sub100 * 13'd205;          // 99*205 = 20295 < 2^15
    wire [3:0]  sc_tens    = tens_pr[14:11];            // exact here
    wire [3:0]  sc_ones_w  = sub100 - ((sc_tens << 3) + (sc_tens << 1));
    wire [3:0]  sc_hund    = is100 ? 4'd1 : 4'd0;

    // ---- digit scanner ----
    reg [15:0] scan_cnt;
    reg [2:0]  digit_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt  <= 16'd0;
            digit_idx <= 3'd0;
        end else if (scan_cnt == CLKS_PER_DIGIT[15:0] - 16'd1) begin
            scan_cnt  <= 16'd0;
            digit_idx <= digit_idx + 3'd1;
        end else begin
            scan_cnt <= scan_cnt + 16'd1;
        end
    end

    // D7..D0 layout
    function [3:0] digit_of;
        input [2:0] idx;
        begin
            if (diagnostic_valid)
                digit_of = (diagnostic_data >> {idx, 2'b00}) & 4'hf;
            else case (idx)
                3'd0: digit_of = sc_ones_w[3:0];    // score ones
                3'd1: digit_of = sc_tens;           // score tens
                3'd2: digit_of = sc_hund;           // score hundreds
                3'd3: digit_of = {1'b0, stars_sync}; // stars
                3'd4: digit_of = {1'b0, tone_sync};  // tone
                3'd5: digit_of = {1'b0, mode_sync};  // mode
                3'd6: digit_of = pct_ones_w[3:0];   // level % ones
                3'd7: digit_of = pct_tens;          // level % tens
                default: digit_of = 4'd0;
            endcase
        end
    endfunction

    // active-low segment table, verbatim from the official demo
    function [7:0] seg_dec;
        input [3:0] n;
        begin
            case (n)
                4'h0:    seg_dec = 8'b1100_0000;
                4'h1:    seg_dec = 8'b1111_1001;
                4'h2:    seg_dec = 8'b1010_0100;
                4'h3:    seg_dec = 8'b1011_0000;
                4'h4:    seg_dec = 8'b1001_1001;
                4'h5:    seg_dec = 8'b1001_0010;
                4'h6:    seg_dec = 8'b1000_0010;
                4'h7:    seg_dec = 8'b1111_1000;
                4'h8:    seg_dec = 8'b1000_0000;
                4'h9:    seg_dec = 8'b1001_0000;
                4'ha:    seg_dec = 8'b1000_1000;
                4'hb:    seg_dec = 8'b1000_0011;
                4'hc:    seg_dec = 8'b1100_0110;
                4'hd:    seg_dec = 8'b1010_0001;
                4'he:    seg_dec = 8'b1000_0110;
                4'hf:    seg_dec = 8'b1000_1110;
                default: seg_dec = 8'b1100_0000;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_led <= 8'hFF;                 // everything off
            seg_sel <= 8'hFF;                 // no digit selected
        end else begin
            seg_led <= seg_dec(digit_of(digit_idx));
            seg_sel <= ~(8'h01 << digit_idx); // active-low one-hot
        end
    end
endmodule
