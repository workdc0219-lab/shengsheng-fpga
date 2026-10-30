`timescale 1ns/1ps
// Fixed-point YIN pitch tracker, bit-exact with tools/shengsheng/golden.py
// (pitch_analyze / PitchTracker). Specification: docs/40 section 2.2.
//
// Samples are written as sample>>>4 into a 1024-entry ring. The legacy
// calibration is Fs=15.625 kHz; product dual-channel Fs=7.8125 kHz uses
// PITCH_Q4_ADJ=-192 to retain the same absolute pitch reference.
// On trigger the most recent SPAN = W + TMAX samples are analysed:
//   d(tau)  = sum_{j<W} (x[j] - x[j+tau])^2          tau = 1..TMAX
//   S(tau)  = sum d(1..tau);  CMND = floor(d*tau*4096/S), clamp 8191
// tau* is the first local descent below THR (tau >= TMIN), else the global
// minimum; a parabolic step refines it to 1/16 lag, a log2 table turns the
// lag into pitch_q4 (1/16 semitone above Fs/256) and the window energy gives
// a log level. OPT-9b (docs/53, ported as docs/16 L1 step 1): two ring
// copies give the MAC a true dual read -- x[j] from ring0 and x[j+tau] from
// ring1 in the SAME cycle -- so a full analysis takes about 83k clocks
// (3.3 ms at 25 MHz, half of the one-port version) and, together with P1,
// halves the voiced-frame switching activity of the DSP/BRAM chain. Both
// copies are written together from the same sample stream so they can never
// diverge; values and accumulation order are unchanged (bit-exact, only
// faster). Writes continue during analysis; they land above the frozen
// window.
//
// P1 (docs/16): a ~W-cycle energy pass runs FIRST; when the level is below
// level_thr the whole YIN sweep is skipped (voiced = 0, silent = 1, pitch/
// tau hold their previous values, cmnd_star = clamp). Downstream filters by
// voiced, so the held pitch is invisible; golden comparisons for
// below-threshold frames are relaxed accordingly (docs/16 s3 P1).
module pitch_tracker #(
    parameter integer W = 384,
    parameter integer TMIN = 24,
    parameter integer TMAX = 208,
    parameter integer THR = 614,
    parameter integer VOICED_MAX = 1434,
    // Absolute pitch calibration: halving Fs subtracts 192 Q4, not adds.
    parameter integer PITCH_Q4_ADJ = 0
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,
    input  wire signed [15:0] sample,
    input  wire               trigger,
    input  wire [7:0]         level_thr,
    output reg                result_valid,
    output reg                voiced,
    output reg  [9:0]         pitch_q4,
    output reg  [11:0]        tau_q4,
    output reg  [12:0]        cmnd_star,
    output reg  [7:0]         level,
    output reg  [30:0]        energy,
    output reg                used_threshold,
    output reg                silent,        // P1: YIN skipped this frame
    output wire               busy,
    output wire               ready           // full post-reset window available
);
    localparam integer SPAN = W + TMAX;
    localparam [12:0] CLAMP = 13'd8191;

    // ------------------------------------------------------ sample rings
    // OPT-9b: two copies of the ring give the MAC a true dual read. Both are
    // written together from the same sample stream so they can never
    // diverge; the write pointer stays SPAN samples ahead of the frozen
    // window, so no read-during-write collision can occur.
    reg [11:0] ring0 [0:1023];
    reg [11:0] ring1 [0:1023];
    reg [9:0] wptr;
    reg [10:0] fill_count;
    assign ready = (fill_count >= SPAN);
    reg [9:0] rd_addr0;
    reg [9:0] rd_addr1;
    reg [11:0] rd_data0;
    reg [11:0] rd_data1;
    // Configuration initialization is not a runtime RAM reset. Analysis
    // waits for SPAN fresh samples after every reset, including warm reset.
    integer init_index;
    initial begin
        for (init_index = 0; init_index < 1024; init_index = init_index + 1) begin
            ring0[init_index] = 12'd0;
            ring1[init_index] = 12'd0;
        end
    end
    always @(posedge clk) begin
        if (rst_n && sample_valid) begin
            ring0[wptr] <= sample[15:4];
            ring1[wptr] <= sample[15:4];
        end
        rd_data0 <= ring0[rd_addr0];
        rd_data1 <= ring1[rd_addr1];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 10'd0;
            fill_count <= 11'd0;
        end else if (sample_valid) begin
            wptr <= wptr + 1'b1;
            if (!ready) fill_count <= fill_count + 1'b1;
        end
    end

    // ------------------------------------------------------ states
    localparam [4:0] S_IDLE  = 5'd0,  S_ACC   = 5'd1,  S_DRAIN = 5'd2,
                     S_MUL   = 5'd3,  S_DIV0  = 5'd4,  S_DIV   = 5'd5,
                     S_DIVEND= 5'd6,  S_SEL   = 5'd7,  F_PICK  = 5'd8,
                     F_DEN   = 5'd9,  F_CLAMP = 5'd10, F_DIVI  = 5'd11,
                     F_TQ    = 5'd12, F_ROM   = 5'd13, F_OUT   = 5'd14,
                     S_ENERGY= 5'd15, S_EDRAIN= 5'd16, S_SKIP  = 5'd17;
    reg [4:0] state;
    assign busy = (state != S_IDLE);

    reg [9:0] n0;
    reg [7:0] tau;
    reg [8:0] j;
    reg e_done;       // energy pass completed (P1: no re-accumulation)

    always @* begin
        rd_addr0 = n0 + j;
        rd_addr1 = n0 + j + tau;
    end

    // ------------------------------------------------------ MAC pipeline
    reg iss_v, iss_last;
    reg signed [11:0] xa, xb;
    reg signed [12:0] diff;
    reg dv, dl;
    reg signed [11:0] ex;
    reg ex_v;
    reg [25:0] sq;
    reg sqv, sql;
    reg [23:0] esq;
    reg esqv;
    reg [32:0] d_acc;
    reg [30:0] e_acc;
    reg d_done;
    reg [32:0] d_final;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iss_v <= 1'b0; iss_last <= 1'b0;
            xa <= 12'sd0; xb <= 12'sd0;
            diff <= 13'sd0; dv <= 1'b0; dl <= 1'b0;
            ex <= 12'sd0; ex_v <= 1'b0;
            sq <= 26'd0; sqv <= 1'b0; sql <= 1'b0;
            esq <= 24'd0; esqv <= 1'b0;
            d_done <= 1'b0; d_final <= 33'd0;
        end else begin
            iss_v <= (state == S_ACC) || (state == S_ENERGY);
            iss_last <= (state == S_ACC) && (j == W - 1);
            // stage A: both samples of the term issued in the previous cycle
            dv <= 1'b0; dl <= 1'b0; ex_v <= 1'b0;
            if (iss_v) begin
                xa <= rd_data0;
                xb <= rd_data1;
                diff <= $signed(rd_data0) - $signed(rd_data1);
                dv <= 1'b1;
                dl <= iss_last;
                ex <= rd_data0;
                ex_v <= (tau == 8'd1) && !e_done;
            end
            // stage B: squares
            sq <= diff * diff;
            sqv <= dv;
            sql <= dl;
            esq <= ex * ex;
            esqv <= ex_v;
            // stage C: the last product of this lag completes d(tau)
            d_done <= sqv && sql;
            d_final <= d_acc + (sqv ? sq : 26'd0);
        end
    end

    // ------------------------------------------------------ datapath regs
    reg [32:0] d_cur;
    reg [40:0] s_acc;
    reg [40:0] s_new;
    reg [40:0] num;
    reg [41:0] rem;
    reg [12:0] quot;
    reg [3:0] bit_idx;
    reg [12:0] cm, cm1, cm2;
    reg found;
    reg [7:0] sel_tau;
    reg [12:0] sel_a, sel_b, sel_c;
    reg gmin_valid, gmin_c_valid;
    reg [13:0] gmin_v;
    reg [7:0] gmin_tau;
    reg [12:0] gmin_a, gmin_b, gmin_c;
    reg [7:0] t_star;
    reg [12:0] fa, fb, fc;
    reg f_has_c;
    reg fneg;
    reg [19:0] fnum;
    reg [19:0] fd;
    reg [3:0] mag;
    reg [1:0] fbit;
    reg [11:0] tq;
    reg [3:0] te;
    reg [7:0] log2_addr;
    wire [7:0] log2_data;

    ss_log2_rom u_log2 (.clk(clk), .addr(log2_addr), .data(log2_data));

    function [4:0] msb31;
        input [30:0] v;
        integer k;
        begin
            msb31 = 5'd0;
            for (k = 0; k < 31; k = k + 1)
                if (v[k]) msb31 = k[4:0];
        end
    endfunction

    // Product windows W=192 and W=384 share the legacy W=384 loudness
    // scale. Doubling the short-window energy is exact and costs no DSP.
    // The public energy port remains the unnormalised sum for diagnostics.
    wire [30:0] level_energy = (W == 192) ? (e_acc << 1) : e_acc;
    wire [4:0] e_msb = msb31(level_energy);
    wire [30:0] e_shift = (e_msb >= 5'd3) ? (level_energy >> (e_msb - 5'd3))
                                          : (level_energy << (5'd3 - e_msb));
    wire [8:0] level_calc = (level_energy == 31'd0) ? 9'd0
                          : {1'b0, e_msb, 3'b000} + {6'd0, e_shift[2:0]};

    // parabolic-step operands from the registered candidate
    wire signed [15:0] f_den = $signed({3'b000, fa}) - $signed({2'b00, fb, 1'b0}) +
                               $signed({3'b000, fc});
    wire signed [13:0] f_ac = $signed({1'b0, fa}) - $signed({1'b0, fc});
    wire [12:0] f_abs = f_ac[13] ? -f_ac[12:0] : f_ac[12:0];

    // tau_q4 and its octave index
    wire [11:0] tq_calc = fneg ? ({t_star, 4'b0000} - mag) : ({t_star, 4'b0000} + mag);
    wire [3:0] te_calc = tq_calc[11] ? 4'd11 : tq_calc[10] ? 4'd10 :
                         tq_calc[9] ? 4'd9 : tq_calc[8] ? 4'd8 :
                         tq_calc[7] ? 4'd7 : tq_calc[6] ? 4'd6 :
                         tq_calc[5] ? 4'd5 : tq_calc[4] ? 4'd4 :
                         tq_calc[3] ? 4'd3 : tq_calc[2] ? 4'd2 :
                         tq_calc[1] ? 4'd1 : 4'd0;
    wire [11:0] tq_norm = (te_calc >= 4'd8) ? (tq_calc >> (te_calc - 4'd8))
                                                       : (tq_calc << (4'd8 - te_calc));
    wire signed [13:0] pitch_calc = 14'sd2304 - $signed({3'b000, te, 7'b0000000}) -
                                    $signed({4'b0000, te, 6'b000000}) -
                                    $signed({6'b000000, log2_data});
    wire signed [31:0] adjusted_pitch = $signed(pitch_calc) + PITCH_Q4_ADJ;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            n0 <= 10'd0; tau <= 8'd1; j <= 9'd0;
            d_acc <= 33'd0; e_acc <= 31'd0; d_cur <= 33'd0;
            s_acc <= 41'd0; s_new <= 41'd0; num <= 41'd0;
            rem <= 42'd0; quot <= 13'd0; bit_idx <= 4'd0;
            cm <= 13'd0; cm1 <= 13'd0; cm2 <= 13'd0;
            found <= 1'b0; sel_tau <= 8'd0;
            sel_a <= 13'd0; sel_b <= 13'd0; sel_c <= 13'd0;
            gmin_valid <= 1'b0; gmin_c_valid <= 1'b0; gmin_v <= 14'd8192;
            gmin_tau <= 8'd0; gmin_a <= 13'd0; gmin_b <= 13'd0; gmin_c <= 13'd0;
            t_star <= 8'd0; fa <= 13'd0; fb <= 13'd0; fc <= 13'd0;
            f_has_c <= 1'b0; fneg <= 1'b0; fnum <= 20'd0; fd <= 20'd0;
            mag <= 4'd0; fbit <= 2'd0; tq <= 12'd0; te <= 4'd8;
            log2_addr <= 8'd0;
            result_valid <= 1'b0; voiced <= 1'b0; pitch_q4 <= 10'd0;
            tau_q4 <= 12'd0; cmnd_star <= 13'd0; level <= 8'd0;
            energy <= 31'd0; used_threshold <= 1'b0; silent <= 1'b0;
            e_done <= 1'b0;
        end else begin
            result_valid <= 1'b0;
            if (sqv)
                d_acc <= d_acc + sq;
            if (esqv)
                e_acc <= e_acc + esq;
            case (state)
            S_IDLE: begin
                if (trigger && ready) begin
                    n0 <= wptr - SPAN[9:0];
                    tau <= 8'd1; j <= 9'd0;
                    d_acc <= 33'd0; e_acc <= 31'd0; s_acc <= 41'd0;
                    found <= 1'b0;
                    gmin_valid <= 1'b0; gmin_c_valid <= 1'b0;
                    gmin_v <= 14'd8192;
                    e_done <= 1'b0;
                    state <= S_ENERGY;
                end
            end
            // P1: energy pass first -- one read per j, pipelined adds; on a
            // quiet window the whole YIN sweep below is skipped
            S_ENERGY: begin
                if (j == W - 1)
                    state <= S_EDRAIN;
                else
                    j <= j + 1'b1;
            end
            S_EDRAIN: begin
                if (!ex_v && !esqv && !sqv && !dv) begin
                    if (level_calc < {1'b0, level_thr}) begin
                        state <= S_SKIP;
                    end else begin
                        e_done <= 1'b1;
                        tau <= 8'd1; j <= 9'd0;
                        d_acc <= 33'd0; s_acc <= 41'd0;
                        found <= 1'b0;
                        gmin_valid <= 1'b0; gmin_c_valid <= 1'b0;
                        gmin_v <= 14'd8192;
                        state <= S_ACC;
                    end
                end
            end
            S_SKIP: begin
                // below-threshold frame: level/energy are real, the rest of
                // the fields hold (golden compare relaxed, docs/16 P1)
                result_valid <= 1'b1;
                voiced <= 1'b0;
                silent <= 1'b1;
                cmnd_star <= CLAMP;
                level <= (level_calc > 9'd255) ? 8'd255 : level_calc[7:0];
                energy <= e_acc;
                used_threshold <= 1'b0;
                state <= S_IDLE;
            end
            // OPT-9b: one term per cycle -- both ring reads land together,
            // the MAC pipeline drains behind them
            S_ACC: begin
                if (j == W - 1)
                    state <= S_DRAIN;
                else
                    j <= j + 1'b1;
            end
            S_DRAIN: begin
                if (d_done) begin
                    d_cur <= d_final;
                    state <= S_MUL;
                end
            end
            S_MUL: begin
                num <= d_cur * tau;
                s_new <= s_acc + d_cur;
                state <= S_DIV0;
            end
            S_DIV0: begin
                s_acc <= s_new;
                quot <= 13'd0;
                if (s_new == 41'd0) begin
                    cm <= 13'd4096;
                    state <= S_SEL;
                end else if ({1'b0, num} >= {s_new, 1'b0}) begin
                    cm <= CLAMP;
                    state <= S_SEL;
                end else begin
                    if (num >= s_new) begin
                        quot[12] <= 1'b1;
                        rem <= {1'b0, num - s_new};
                    end else begin
                        rem <= {1'b0, num};
                    end
                    bit_idx <= 4'd11;
                    state <= S_DIV;
                end
            end
            S_DIV: begin
                // rem < S, so 2*rem fits in 42 bits
                if ({rem[40:0], 1'b0} >= {1'b0, s_acc}) begin
                    rem <= {rem[40:0], 1'b0} - {1'b0, s_acc};
                    quot[bit_idx] <= 1'b1;
                end else begin
                    rem <= {rem[40:0], 1'b0};
                end
                if (bit_idx == 4'd0)
                    state <= S_DIVEND;
                else
                    bit_idx <= bit_idx - 1'b1;
            end
            S_DIVEND: begin
                cm <= quot;
                state <= S_SEL;
            end
            S_SEL: begin
                // fill the right neighbour of the pending global minimum first,
                // then a new minimum may replace it (golden order)
                if (gmin_valid && !gmin_c_valid && gmin_tau == tau - 1'b1) begin
                    gmin_c <= cm;
                    gmin_c_valid <= 1'b1;
                end
                if (tau >= TMIN && {1'b0, cm} < gmin_v) begin
                    gmin_v <= {1'b0, cm};
                    gmin_tau <= tau;
                    gmin_a <= cm1;
                    gmin_b <= cm;
                    gmin_c_valid <= 1'b0;
                    gmin_valid <= 1'b1;
                end
                if (tau >= TMIN + 1 && !found && cm1 < THR && cm1 <= cm) begin
                    found <= 1'b1;
                    sel_tau <= tau - 1'b1;
                    sel_a <= cm2;
                    sel_b <= cm1;
                    sel_c <= cm;
                end
                cm2 <= cm1;
                cm1 <= cm;
                if (tau == TMAX) begin
                    state <= F_PICK;
                end else begin
                    tau <= tau + 1'b1;
                    j <= 9'd0;
                    d_acc <= 33'd0;
                    state <= S_ACC;
                end
            end
            F_PICK: begin
                if (found) begin
                    t_star <= sel_tau; fa <= sel_a; fb <= sel_b; fc <= sel_c;
                    f_has_c <= 1'b1;
                end else begin
                    t_star <= gmin_tau; fa <= gmin_a; fb <= gmin_b; fc <= gmin_c;
                    f_has_c <= gmin_c_valid;
                end
                state <= F_DEN;
            end
            F_DEN: begin
                mag <= 4'd0;
                fneg <= f_ac[13];
                if (!f_has_c || f_den <= 16'sd0) begin
                    state <= F_TQ;
                end else begin
                    fnum <= {3'b000, f_abs, 4'b0000} + {4'b0000, f_den};
                    fd <= {3'b000, f_den, 1'b0};
                    state <= F_CLAMP;
                end
            end
            F_CLAMP: begin
                if (fnum >= {fd[16:0], 3'b000}) begin
                    mag <= 4'd8;
                    state <= F_TQ;
                end else begin
                    fbit <= 2'd2;
                    state <= F_DIVI;
                end
            end
            F_DIVI: begin
                if (fnum >= (fd << fbit)) begin
                    fnum <= fnum - (fd << fbit);
                    mag[fbit] <= 1'b1;
                end
                if (fbit == 2'd0)
                    state <= F_TQ;
                else
                    fbit <= fbit - 1'b1;
            end
            F_TQ: begin
                tq <= tq_calc;
                te <= te_calc;
                log2_addr <= tq_norm[7:0];
                state <= F_ROM;
            end
            F_ROM: state <= F_OUT;              // ROM read latency
            F_OUT: begin
                pitch_q4 <= (adjusted_pitch < 0) ? 10'd0 :
                            (adjusted_pitch > 1023) ? 10'd1023 :
                            adjusted_pitch[9:0];
                tau_q4 <= tq;
                cmnd_star <= fb;
                level <= (level_calc > 9'd255) ? 8'd255 : level_calc[7:0];
                energy <= e_acc;
                used_threshold <= found;
                voiced <= (level_calc >= {1'b0, level_thr}) && (fb <= VOICED_MAX);
                silent <= 1'b0;
                result_valid <= 1'b1;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
