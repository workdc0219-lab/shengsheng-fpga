`timescale 1ns/1ps
// D4 diagnostic observer (2026-10-25): windowed live RATES, not stickies.
// D1 already proved stickies+counts can be healthy on a dead layout; the
// open question is whether a VIDEO-ALIVE R3-family layout keeps pacing the
// audio stream. Three 32-bit words alternate on the seven-segment page,
// each held for one second (quasi-static bus, 2FF-synced to sys domain):
//   word A: {D4, A0, pcm_tap_valid rate}    expect 48000 = BB80
//   word B: {D4, B0, acr_valid rate}        expect  1000 = 03E8
//   word C: {D4, C0, acr_cts[15:0]}         expect 25000 = 61A8
// Decision tree: rates healthy + still silent -> fault inside the encrypted
// packetizer/PHY (C-level disclosure). Any rate dead/frozen -> open-RTL
// source/ACR chain, fixable. Diagnostic only; no output feeds the product.
module audio_probe_d4 #(
    parameter [24:0] WINDOW_CLKS = 25'd24999999  // 1 s at 25 MHz
) (
    input wire sys_clk, sys_rst_n, pix_clk, pix_rst_n,
    input wire pcm_valid, acr_valid,
    input wire [19:0] acr_cts,
    output wire [31:0] status_sys
);
    reg [24:0] win_cnt;
    reg [15:0] pcm_cnt, acr_cnt;
    reg [15:0] cts_snap;  // latched ON the acr_valid pulse (D1 method)
    reg [1:0]  alt;
    reg [31:0] word_pix;
    wire win_end = (win_cnt == WINDOW_CLKS);

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            win_cnt <= 0; pcm_cnt <= 0; acr_cnt <= 0;
            alt <= 0;
            word_pix <= 32'hd4a0_0000;
        end else begin
            if (pcm_valid) pcm_cnt <= pcm_cnt + 1'b1;
            if (acr_valid) acr_cnt <= acr_cnt + 1'b1;
            if (acr_valid) cts_snap <= acr_cts[15:0];
            if (win_end) begin
                // reads of pcm_cnt/acr_cnt below see the just-finished
                // window's totals (their clears are nonblocking, same edge)
                win_cnt <= 0;
                pcm_cnt <= 0;
                acr_cnt <= 0;
                alt     <= (alt == 2'd2) ? 2'd0 : alt + 1'b1;
                case ((alt == 2'd2) ? 2'd0 : alt + 1'b1)
                    2'd0:    word_pix <= {8'hd4, 8'ha0, pcm_cnt};
                    2'd1:    word_pix <= {8'hd4, 8'hb0, acr_cnt};
                    default: word_pix <= {8'hd4, 8'hc0, cts_snap};
                endcase
            end else
                win_cnt <= win_cnt + 1'b1;
        end
    end

    reg [31:0] s1, s2;
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            s1 <= 32'hd4a0_0000; s2 <= 32'hd4a0_0000;
        end else begin
            s1 <= word_pix;
            s2 <= s1;
        end
    end
    assign status_sys = s2;
endmodule
