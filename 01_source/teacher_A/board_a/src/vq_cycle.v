`timescale 1ns/1ps
// Cycle-level voice quality (docs/10 §5, R81 A-board fill).
//
// Clinically standard voice-quality measures at the GLOTTAL-CYCLE level --
// the quantities voice clinics actually report (Jitter %, Shimmer %):
//   - rising zero-crossing detection on the raw front-end sample gives the
//     period sequence T_i (in samples at 15.625 kHz);
//   - the running peak magnitude within each period gives A_i;
//   - per-cycle quality = ladder16(|dT|, T) and ladder16(|dA|, A)
//     (the docs/08 §2 log ladder, q=k <-> ratio >= 2^(k-6)).
// Two outputs per frame:
//   *_c[7:0]   mean over the current utterance window (8-bit: 4-bit ladder
//              mean scaled x16 -- a finer resolution than the frame-pair
//              proxy it replaces);
//   *_f[3:0]   last completed cycle (fast path, teacher OSD).
// Windowing matches nb_fallback: opens on the first voiced frame, freezes
// UV_RESET unvoiced frames after the last one.
//
// The utterance mean is computed WITHOUT a divider: sum(q) * 16 / count is
// approximated by sum(q) << 4 >> floor(log2(count)) (same monotone
// <=2x-error approximation the argmin bin uses -- ample for a quality
// metric whose absolute calibration is the ladder itself).
module vq_cycle #(
    parameter integer UV_RESET = 24
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,   // 15.625 kHz
    input  wire signed [15:0] sample,         // raw front-end sample
    input  wire               frame_valid,    // tracker frame strobe
    input  wire               voiced,
    output reg  [7:0]         jitter_c,       // utterance mean, x16 ladder
    output reg  [7:0]         shimmer_c,
    output reg  [3:0]         jitter_f,       // last cycle, fast
    output reg  [3:0]         shimmer_f
);
    // ---------------- zero-crossing period measurement ----------------
    reg signed [15:0] prev_sample;
    reg        in_period;                     // above/below zero state
    reg [8:0]  period_cnt;                    // samples since last rising ZC
    reg [8:0]  period_len;                    // latched at rising ZC
    reg [15:0] period_peak;                   // |sample| max this period
    reg        have_prev_period;
    reg [8:0]  prev_period_len;
    reg [15:0] prev_period_peak;

    wire rising_zc = (sample >= 0) && (prev_sample < 0);
    wire [15:0] abs_sample = sample[15] ? (~sample + 1'b1) : sample;

    // finer ladder for cycle level: q over 8 bits (ratio >= 2^(q-12),
    // q=12 means ratio >= 1) -- 2x steps of ~6%
    function [7:0] ladder_fine;
        input [15:0] d;
        input [15:0] v;
        reg [3:0]  q;
        integer i;
        begin
            q = 4'd0;
            for (i = 1; i < 16; i = i + 1) begin
                if (i <= 12) begin
                    if ((d << (12 - i)) >= v) q = i[3:0];
                end else begin
                    if (d >= (v << (i - 12))) q = i[3:0];
                end
            end
            ladder_fine = {4'd0, q};           // 0..15 in an 8-bit lane
        end
    endfunction

    // ---------------- utterance accumulator ----------------
    reg        acc_active, acc_frozen;
    reg [5:0]  uv_cnt;
    reg [6:0]  cnt;
    reg [15:0] sum_j, sum_s;

    function [2:0] shf_of;
        input [6:0] c;
        begin
            casez (c)
                7'b1??????: shf_of = 3'd6;
                7'b01?????: shf_of = 3'd5;
                7'b001????: shf_of = 3'd4;
                7'b0001???: shf_of = 3'd3;
                7'b00001??: shf_of = 3'd2;
                7'b000001?: shf_of = 3'd1;
                default:    shf_of = 3'd0;
            endcase
        end
    endfunction

    wire [2:0] mean_shf = shf_of(cnt);
    // audit P2-3: evaluate in widened context -- sum_j>=4096 used to wrap
    // the 16-bit (sum<<4) before the shift
    wire [20:0] mean_j_full = {sum_j, 4'd0} >> mean_shf;
    wire [7:0] mean_j = (mean_j_full > 21'd255) ? 8'd255 : mean_j_full[7:0];
    wire [20:0] mean_s_full = {sum_s, 4'd0} >> mean_shf;
    wire [7:0] mean_s = (mean_s_full > 21'd255) ? 8'd255 : mean_s_full[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_sample <= 16'sd0; in_period <= 1'b0;
            period_cnt <= 9'd0; period_len <= 9'd0;
            period_peak <= 16'd0; have_prev_period <= 1'b0;
            prev_period_len <= 9'd0; prev_period_peak <= 16'd0;
            acc_active <= 1'b0; acc_frozen <= 1'b0; uv_cnt <= 6'd0;
            cnt <= 7'd0; sum_j <= 16'd0; sum_s <= 16'd0;
            jitter_c <= 8'd0; shimmer_c <= 8'd0;
            jitter_f <= 4'd0; shimmer_f <= 4'd0;
        end else begin
            // ---------- per-sample period tracking ----------
            if (sample_valid) begin
                // audit P2-4: saturate -- a silent stretch with no rising
                // ZC used to wrap and report a fake short period on revoice
                if (period_cnt != 9'd511)
                    period_cnt <= period_cnt + 1'b1;
                if (abs_sample > period_peak)
                    period_peak <= abs_sample;
                if (rising_zc && period_cnt > 9'd4) begin
                    // a period closed (min 4 samples: 3.9 kHz ceiling)
                    if (have_prev_period && in_period) begin
                        // ratios against the PREVIOUS period
                        jitter_f <= ladder_fine(
                            (period_cnt > prev_period_len)
                                ? (period_cnt - prev_period_len)
                                : (prev_period_len - period_cnt),
                            {7'd0, prev_period_len});
                        shimmer_f <= ladder_fine(
                            (period_peak > prev_period_peak)
                                ? (period_peak - prev_period_peak)
                                : (prev_period_peak - period_peak),
                            prev_period_peak);
                        // accumulate into the utterance window
                        // audit round-5: freeze at the cnt saturation point --
                        // the 16-bit sums wrapped after ~1.75-2.9 s of voiced
                        // audio (before cnt saturated) and read as perfect quality
                        if (acc_active && cnt != 7'd127) begin
                            sum_j <= sum_j + {4'd0, jitter_f};
                            sum_s <= sum_s + {4'd0, shimmer_f};
                        end
                    end
                    prev_period_len  <= period_cnt;
                    prev_period_peak <= period_peak;
                    have_prev_period <= 1'b1;
                    period_cnt <= 9'd0;
                    period_peak <= 16'd0;
                end
                prev_sample <= sample;
                in_period   <= 1'b1;
            end

            // ---------- utterance window ----------
            if (frame_valid) begin
                if (voiced) begin
                    uv_cnt <= 6'd0;
                    if (!acc_active) begin
                        acc_active <= 1'b1;
                        acc_frozen <= 1'b0;
                        cnt <= 7'd0;
                        sum_j <= 16'd0; sum_s <= 16'd0;
                    end
                end else if (acc_active) begin
                    uv_cnt <= uv_cnt + 1'b1;
                    if (uv_cnt + 1'b1 >= UV_RESET) begin
                        acc_active <= 1'b0;
                        acc_frozen <= 1'b1;
                        // freeze the window means
                        jitter_c  <= mean_j;
                        shimmer_c <= mean_s;
                    end
                end
                if (acc_active)
                    if (cnt != 7'd127)     // audit N2: saturate like nb_fallback
                        cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
