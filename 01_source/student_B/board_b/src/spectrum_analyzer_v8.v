`timescale 1ns/1ps

// V8 F4 spectrum analyzer: the PCM actually sent to HDMI -> 16 bar heights.
// Bit-exact with tools/model_f4_v8.py (class Spectrum).
//
//   48 kHz samples, averaged in pairs  -> 24 kHz, x >>> 7 (10-bit)
//   Hann window from a quarter-cosine table, one 256-sample window per
//   10.7 ms (no overlap)
//   direct DFT, bins 1..117 (94 Hz .. 11 kHz): per decimated sample, bin k
//   adds x*cos(2*pi*k*n/256) and x*sin(..) to its accumulator; the 234
//   accumulators live in one block RAM, one read-modify-write per clock
//   at window end: power (re/16)^2 + (im/16)^2 summed into 16 log-spaced
//   bands, log level 4*msb + 2 fraction bits (~0.75 dB/step), then a
//   per-band floor and shift-add gain (spectrum_v8_tables.vh) -> 0..32.
//   All 16 heights are published together (heights_valid), so a reader
//   never sees a half-updated window.
//
// Cost per decimated sample (every ~1042 clocks): 1 + 234 + 2 clocks;
// window end adds 4 clocks per bin (468). One 18x18 multiplier is shared by
// the window, the DFT products and the squares, so the module uses 1 DSP
// and 1 BRAM. A sample pair that completes while a pass is still running
// waits in a one-deep slot (never in the product: the passes take at most
// ~710 of the 1042 clocks); a second one sets `overrun`.
// After reset the accumulators are cleared (256 clocks) before the first
// sample is taken.
module spectrum_analyzer_v8 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,     // one pulse per 48 kHz sample
    input  wire signed [15:0] sample,
    output reg  [95:0]        heights,          // band b in [6b+5:6b], 0..32
    output reg                heights_valid,    // pulse: a window closed
    output reg                overrun
);
`include "spectrum_v8_tables.vh"

    // round(1023*cos(2*pi*i/256)) from the 65-entry quarter table
    function signed [10:0] cos256;
        input [7:0] i;
        reg [8:0] t;
        reg [6:0] q;
        reg neg;
        begin
            if (i <= 8'd64)       begin t = {1'b0, i};            neg = 1'b0; end
            else if (i <= 8'd128) begin t = 9'd128 - {1'b0, i};   neg = 1'b1; end
            else if (i <= 8'd192) begin t = {1'b0, i} - 9'd128;   neg = 1'b1; end
            else                  begin t = 9'd256 - {1'b0, i};   neg = 1'b0; end
            q = t[6:0];
            cos256 = neg ? -$signed({1'b0, f4_cos_q(q)}) : $signed({1'b0, f4_cos_q(q)});
        end
    endfunction

    // 4*msb(p) + next two bits, 0 below 4
    function [7:0] log_level;
        input [33:0] p;
        integer j;
        reg [7:0] r;
        begin
            // one priority chain: the highest set bit j >= 2 picks 4*j plus
            // the two bits below it (no encoder + barrel shifter)
            r = 8'd0;
            for (j = 2; j < 34; j = j + 1)
                if (p[j]) r = {j[5:0], p[j-1], p[j-2]};
            log_level = r;
        end
    endfunction

    function [5:0] band_height;
        input [7:0] level;
        input [3:0] b;
        reg [7:0] fl;
        reg [8:0] d, s;
        begin
            fl = f4_band_floor(b);
            d = (level > fl) ? {1'b0, level - fl} : 9'd0;
            case (f4_band_scale(b))
                3'd0: s = d << 1;
                3'd1: s = d + (d >> 1);
                3'd2: s = d;
                3'd3: s = (d >> 1) + (d >> 2);
                default: s = d >> 1;
            endcase
            band_height = (s > {3'd0, F4_HMAX}) ? F4_HMAX : s[5:0];
        end
    endfunction

    // ---------------------------------------------------- accumulator RAM
    // |re|, |im| <= 512 * 128 (Hann sum) < 2^16, so 18 signed bits suffice
    reg signed [17:0] acc_mem [0:255] /* fehdl force_ram=1, ram_style="bram" */;
    reg [7:0]  raddr;
    reg signed [17:0] rdata;
    reg        we;
    reg [7:0]  waddr;
    reg signed [17:0] wdata;
    always @(posedge clk) begin
        rdata <= acc_mem[raddr];
        if (we)
            acc_mem[waddr] <= wdata;
    end

    // ---------------------------------------------------- input pairing
    reg               half_valid;
    reg signed [15:0] half;
    reg               pend;
    reg signed [9:0]  pend_xd;
    wire signed [16:0] pair_sum = half + sample;
    wire signed [9:0]  pair_xd = pair_sum >>> 7;

    // ---------------------------------------------------- shared multiplier
    localparam [2:0] S_CLR = 3'd0, S_IDLE = 3'd1, S_WIN = 3'd2, S_ACC = 3'd3, S_FIN = 3'd4,
                     S_DONE = 3'd5;
    reg [2:0] state;
    reg signed [17:0] m_a, m_b;
    wire signed [35:0] m_p = m_a * m_b;

    reg [7:0]  n;                 // window position of the current pass
    reg signed [9:0]  xd;
    reg signed [10:0] xw;         // windowed sample
    reg [7:0]  idx;               // k*n mod 256
    reg [6:0]  k;
    reg        part;              // 0: re (cos), 1: im (sin)
    reg        issuing;
    reg [1:0]  drain;
    // pipeline
    reg signed [10:0] c_q;
    reg [7:0]  a_q, a_q2;
    reg        v_q, v_q2;
    reg signed [21:0] p_q;
    // finalize
    reg [1:0]  ph;
    reg [3:0]  b;
    reg signed [14:0] fr, fi;
    reg [28:0] sqr;
    reg [33:0] bacc;
    reg        band_done;         // bacc holds a finished band; scale it next clock
    reg        done_step;
    reg [95:0] hw;                // heights of the window being finalised
    wire [33:0] bacc_next = bacc + {5'd0, sqr} + {5'd0, m_p[28:0]};
    wire [7:0] trig_idx = part ? idx - 8'd64 : idx;
    // one cosine table serves both: the window reads it only in S_WIN,
    // the DFT twiddles only in S_ACC
    wire signed [10:0] cos_v = cos256((state == S_WIN) ? n : trig_idx);
    wire signed [12:0] win_full = 13'sd1023 - cos_v;           // 0..2046
    wire [9:0] win = win_full[10:1];
    wire signed [18:0] re_round = rdata + 19'sd8;
    wire signed [21:0] p_rnd = p_q + 22'sd512;
    wire signed [11:0] p_sh = p_rnd >>> 10;

    always @* begin
        case (state)
            S_WIN:   begin m_a = xd;  m_b = {8'd0, win}; end
            S_FIN:   begin m_a = (ph == 2'd3) ? fi : fr; m_b = m_a; end
            default: begin m_a = xw;  m_b = c_q; end
        endcase
    end

    always @* begin
        we = 1'b0; waddr = a_q2; wdata = 18'd0; raddr = a_q;
        case (state)
            S_CLR: begin we = 1'b1; waddr = n; end
            S_ACC: begin
                we = v_q2; waddr = a_q2;
                wdata = rdata + p_sh;
                raddr = a_q;
            end
            S_FIN: begin
                raddr = {ph != 2'd0, k};
                we = (ph == 2'd1) || (ph == 2'd2);
                waddr = {ph == 2'd2, k};
            end
            default: ;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            heights <= 96'd0; heights_valid <= 1'b0; overrun <= 1'b0;
            half_valid <= 1'b0; half <= 16'sd0; pend <= 1'b0; pend_xd <= 10'sd0;
            state <= S_CLR; n <= 8'd0; xd <= 10'sd0; xw <= 11'sd0; idx <= 8'd0;
            k <= 7'd0; part <= 1'b0; issuing <= 1'b0; drain <= 2'd0;
            c_q <= 11'sd0; a_q <= 8'd0; a_q2 <= 8'd0; v_q <= 1'b0; v_q2 <= 1'b0; p_q <= 22'sd0;
            ph <= 2'd0; b <= 4'd0; fr <= 15'sd0; fi <= 15'sd0; sqr <= 29'd0; bacc <= 34'd0;
            band_done <= 1'b0; done_step <= 1'b0; hw <= 96'd0;
        end else begin
            heights_valid <= 1'b0;

            // pair the 48 kHz samples; a finished pair waits in `pend`
            if (sample_valid) begin
                if (!half_valid) begin
                    half <= sample; half_valid <= 1'b1;
                end else begin
                    half_valid <= 1'b0;
                    if (pend) overrun <= 1'b1;
                    pend <= 1'b1; pend_xd <= pair_xd;
                end
            end

            // ACC pipeline stages 1 and 2 (stage 2's write is combinational above)
            p_q <= m_p[21:0];
            a_q2 <= a_q; v_q2 <= v_q;
            v_q <= 1'b0;

            case (state)
                S_CLR: begin
                    // write zero to all 256 words; n wraps back to 0
                    n <= n + 1'b1;
                    if (n == 8'd255)
                        state <= S_IDLE;
                end
                S_IDLE: begin
                    if (pend && !(sample_valid && half_valid)) begin
                        pend <= 1'b0; xd <= pend_xd; state <= S_WIN;
                    end
                end
                S_WIN: begin
                    xw <= m_p[20:10];          // (xd * w) >>> 10
                    k <= 7'd1; part <= 1'b0; idx <= n; issuing <= 1'b1; drain <= 2'd0;
                    state <= S_ACC;
                end
                S_ACC: begin
                    if (issuing) begin
                        c_q <= cos_v;
                        a_q <= {part, k};
                        v_q <= 1'b1;
                        part <= ~part;
                        if (part) begin
                            idx <= idx + n;
                            if (k == F4_KMAX) issuing <= 1'b0;
                            k <= k + 1'b1;
                        end
                    end else if (drain != 2'd2) begin
                        drain <= drain + 1'b1;
                    end else begin
                        n <= n + 1'b1;
                        if (n == 8'd255) begin
                            state <= S_FIN; k <= 7'd1; ph <= 2'd0; b <= 4'd0; bacc <= 34'd0;
                            band_done <= 1'b0;
                        end else
                            state <= S_IDLE;
                    end
                end
                S_FIN: begin
                    ph <= ph + 1'b1;
                    case (ph)
                        2'd0: if (band_done) begin
                            // the band closed at the previous bin: scale it from
                            // the register, off the accumulate adder's path
                            hw[b*6 +: 6] <= band_height(log_level(bacc), b);
                            bacc <= 34'd0;
                            b <= b + 1'b1;
                            band_done <= 1'b0;
                        end
                        2'd1: fr <= re_round >>> 4;
                        2'd2: begin fi <= re_round >>> 4; sqr <= m_p[28:0]; end
                        default: begin
                            bacc <= bacc_next;
                            band_done <= (k == f4_band_last(b));
                            k <= k + 1'b1;
                            if (k == F4_KMAX) begin
                                state <= S_DONE; done_step <= 1'b0;
                            end
                        end
                    endcase
                end
                S_DONE: begin
                    // last band, then publish all 16 at once
                    if (!done_step) begin
                        hw[b*6 +: 6] <= band_height(log_level(bacc), b);
                        band_done <= 1'b0;
                        done_step <= 1'b1;
                    end else begin
                        heights <= hw;
                        heights_valid <= 1'b1;
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
