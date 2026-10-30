`timescale 1ns/1ps
// Utterance segmentation and tone scoring (Board B variant). Segmentation,
// binning and contour scoring are bit-exact with tools/shengsheng/golden.py
// (ToneScorer / score_contour) and identical to the single-board rule-cascade
// version. PRODUCT (ENABLE_CLASSIFIER=0) omits recognition and returns tone=0;
// only DIAG (ENABLE_CLASSIFIER=1) uses the trained lookup cascade. Instead of
// the hand-tuned if-else cascade at
// the classification step, the five contour features are looked up in a
// 32768-entry table trained offline on the 1418-clip real-speech corpus
// (tools/train_classifier.py -> classifier_lut.hex, R78 dual-board round).
// The classified tone feeds the same outputs as before (teacher-mode OSD);
// scoring itself never used it, so stars/score/hints are unchanged by design.
//
// One call per video frame (frame_valid with the tracker's voiced/pitch):
// three voiced frames open an utterance, 24 unvoiced frames or 96 points
// close it. Each stored point passes an octave guard. On close the points
// are averaged into 16 binv (bin k covers [k*n>>4, (k+1)*n>>4)), contour
// features are extracted and the target tone is scored 0..100 with
// difficulty-dependent thresholds. Every stored point is also streamed out
// for the live on-screen curve; the 16 binv are exported for the redraw.
module tone_scorer #(
    parameter LUT_HEX = "classifier_lut.hex",
    parameter integer ENABLE_CLASSIFIER = 0
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         arm,             // restart with target/difficulty
    input  wire         cancel,          // highest priority: abandon this attempt
    input  wire [2:0]   target,          // 1..4
    input  wire [1:0]   difficulty,
    input  wire         enable,
    input  wire         frame_valid,
    input  wire         voiced,
    input  wire [9:0]   pitch_q4,
    input  wire         nb_valid,        // Board-A NB fallback hold (v3 link)
    input  wire [2:0]   nb_tone,         // its verdict; consumed on LUT abstain
    input  wire         dtw_valid,       // Board-A DTW matcher hold (v5 link)
    input  wire [2:0]   dtw_tone,        // its verdict; last cascade stage
    output reg          result_valid,
    output reg  [6:0]   n_points,
    output reg          too_short,
    output reg  [2:0]   tone,
    output reg  [6:0]   score,
    output reg  [1:0]   stars,
    output reg  [2:0]   hint,
    output reg  [9:0]   mean_q4,
    output reg  [159:0] bins_flat,
    output reg          point_valid,
    output reg  [6:0]   point_index,
    output reg  [9:0]   point_value,
    output wire         active
);
    localparam integer START_FRAMES = 3;
    // Utterance close delay, in silent 60 Hz frames. Was 9 (150 ms), which cut
    // every half-third production right at its trough: measured on the 1418-clip
    // real corpus (build/_diag/stage_Lp_segment_diagnosis.py, Q0 reproduces the
    // archived 790/1418), 137 of the 160 true third tones judged as fourth tones
    // have their rising half voiced AFTER a median 267 ms unvoiced gap -- 0 of
    // 137 fit inside 150 ms, 136 of 137 inside 500 ms. Landed on 24 frames
    // (400 ms): 81 of the 160 re-classified as third tones, no correct clip
    // flipped, tone-3 recall 0.379 -> 0.629, tone-2 recall 0.950 unchanged
    // (evidence/shengsheng/real_speech_end24_full_20260928.json). Golden
    // mirror: tables.SCORER_END_FRAMES -- change the two together and
    // regenerate sim/vectors (make_vectors.py) before running the suites.
    localparam integer END_FRAMES = 24;
    localparam integer MAX_POINTS = 96;
    localparam integer MIN_POINTS = 10;

    // ------------------------------------------------------ point memory
    reg [9:0] pts [0:127];
    reg [6:0] wr_addr;
    reg [9:0] wr_data;
    reg wr_en;
    reg [6:0] rd_j;
    reg [9:0] rd_data;
    always @(posedge clk) begin
        if (wr_en)
            pts[wr_addr] <= wr_data;
        rd_data <= pts[rd_j];
    end

    function [9:0] guard;
        input [9:0] p;
        input [9:0] last;
        reg signed [11:0] d;
        reg signed [11:0] dm, dp;
        reg signed [11:0] v;
        begin
            d = $signed({2'b00, p}) - $signed({2'b00, last});
            dm = d - 12'sd192;
            dp = d + 12'sd192;
            v = $signed({2'b00, p});
            if ((d >= 12'sd144) || (d <= -12'sd144)) begin
                if (dm > -12'sd48 && dm < 12'sd48)
                    v = v - 12'sd192;
                else if (dp > -12'sd48 && dp < 12'sd48)
                    v = v + 12'sd192;
                else
                    v = $signed({2'b00, last});
            end
            guard = (v < 0) ? 10'd0 : (v > 12'sd1023) ? 10'd1023 : v[9:0];
        end
    endfunction

    function [12:0] recip;
        input [2:0] k;
        begin
            case (k)
                3'd1: recip = 13'd4096; 3'd2: recip = 13'd2048;
                3'd3: recip = 13'd1365; 3'd4: recip = 13'd1024;
                3'd5: recip = 13'd819;  3'd6: recip = 13'd683;
                default: recip = 13'd585;
            endcase
        end
    endfunction

    // lin(x, lo, hi) = 0 below lo, 100 above hi, else min(100, (x-lo)*mul>>8)
    function [6:0] lin;
        input signed [11:0] x;
        input [7:0] lo;
        input [7:0] hi;
        input [11:0] mul;
        reg signed [12:0] dx;
        reg [24:0] prod;
        begin
            dx = x - $signed({5'b00000, lo});
            if (x <= $signed({4'b0000, lo}))
                lin = 7'd0;
            else if (x >= $signed({4'b0000, hi}))
                lin = 7'd100;
            else begin
                prod = dx[11:0] * mul;
                lin = (prod[24:8] > 17'd100) ? 7'd100 : prod[14:8];
            end
        end
    endfunction

    // ------------------------------------------------------ state
    localparam [3:0] ST_IDLE = 4'd0, ST_ON1 = 4'd1, ST_ON2 = 4'd2,
                     ST_ACT = 4'd3, FB_START = 4'd4, FB_ISSUE = 4'd5,
                     FB_TAKE = 4'd6, FB_MUL = 4'd7, FB_NEXT = 4'd8,
                     FT_SCAN = 4'd9, FT_FEAT = 4'd10, FT_LUT = 4'd11,
                     FT_OUT = 4'd12, ST_SHORT = 4'd13, FT_LIN = 4'd14;
    reg [3:0] st;
    reg armed;
    reg [2:0] tgt;
    reg [1:0] diff_lv;
    reg [1:0] run_len;
    reg [9:0] run0, run1;
    reg [9:0] onset_p;
    reg [9:0] last_pt;
    reg [6:0] n;
    reg [5:0] uv;
    reg in_utt;
    assign active = in_utt;

    // binning
    reg [3:0] k;
    reg [10:0] kn;
    reg [6:0] j_hi;
    reg [2:0] cnt, remain;
    reg [12:0] bsum;
    reg [9:0] binv [0:15];
    // features
    reg [10:0] mn;
    reg [9:0] mx;
    reg [3:0] argmin;
    reg [13:0] bin_total;
    reg signed [11:0] f_delta, f_rng, f_dip, f_tail;
    // The right-hand side of the third-tone clause, f_delta + TONE3_MARGIN.
    // It is 13 bits on purpose: f_delta is signed [11:0], so the addition must
    // be widened before the compare or it wraps when f_delta sits near its
    // negative full scale (measured range is [-478, 451], and the corpus has
    // clips past -400). Both the decision at FT_SCORE and the scoring penalty
    // at FT_LIN read THIS register rather than re-deriving the sum, so the two
    // sites cannot drift apart -- the failure mode docs/44 section 12 warns
    // about.
    reg signed [12:0] f_t3_rhs;
    reg f_mid;
    reg [6:0] s_raw;

    wire [10:0] kn_next = kn + {4'd0, n};
    wire [6:0] lo_idx = kn[10:4];
    wire [6:0] hi_idx = kn_next[10:4];
    wire [10:0] start_sum = {1'b0, binv[0]} + {1'b0, binv[1]};
    wire [10:0] end_sum = {1'b0, binv[14]} + {1'b0, binv[15]};
    wire [9:0] f_start = start_sum[10:1];
    wire [9:0] f_end = end_sum[10:1];
    // f_end - f_start, sign-extended to 13 bits. A wire (not just the f_delta
    // register) so that f_delta and f_t3_rhs are both driven from the same
    // source in the same clocked block -- see the FT_FEAT comment.
    wire signed [12:0] f_delta_next = $signed({3'b000, f_end}) - $signed({3'b000, f_start});

    // difficulty tables (golden tables.py; mul = 25600 // (hi - lo))
    reg [7:0] t1_bad, t1_span, t2_hi, t3_hi, t4_hi;
    reg [11:0] t1_mul, t2_mul, t3_mul, t4_mul;
    always @* begin
        case (diff_lv)
            2'd0: begin t1_bad = 8'd96; t1_span = 8'd64; t1_mul = 12'd400;
                        t2_hi = 8'd32; t2_mul = 12'd1066; t3_hi = 8'd16; t3_mul = 12'd2133;
                        t4_hi = 8'd48; t4_mul = 12'd800; end
            2'd1: begin t1_bad = 8'd80; t1_span = 8'd56; t1_mul = 12'd457;
                        t2_hi = 8'd40; t2_mul = 12'd800; t3_hi = 8'd20; t3_mul = 12'd1600;
                        t4_hi = 8'd64; t4_mul = 12'd533; end
            2'd2: begin t1_bad = 8'd64; t1_span = 8'd48; t1_mul = 12'd533;
                        t2_hi = 8'd48; t2_mul = 12'd640; t3_hi = 8'd28; t3_mul = 12'd1066;
                        t4_hi = 8'd80; t4_mul = 12'd400; end
            default: begin t1_bad = 8'd48; t1_span = 8'd36; t1_mul = 12'd711;
                        t2_hi = 8'd56; t2_mul = 12'd533; t3_hi = 8'd36; t3_mul = 12'd800;
                        t4_hi = 8'd96; t4_mul = 12'd320; end
        endcase
    end

    // one shared lin() evaluator: pass 0 = the target's main feature,
    // pass 1 = the third tone's tail rise
    reg lin_pass;
    reg [6:0] lin_first;
    reg signed [11:0] lin_x;
    reg [7:0] lin_lo, lin_hi;
    reg [11:0] lin_mul;
    always @* begin
        if (lin_pass) begin
            // Third-tone tail-rise term. Full score used to need 64 q4 (4.0
            // semitones) of rise back up, which a correct third tone never
            // reaches -- the target scored 52 and the best attempt on stage
            // could not earn the third star. Recalibrated to 32 q4 with
            // SCORE_T3_TAIL_LO = 8, so lin_mul = 25600/(32-8) = 1066.
            // Mirrors tables.SCORE_T3_TAIL_HI = 32; see docs/48 stage D and
            // selfcheck group 15, which parses this literal.
            lin_x = f_tail; lin_lo = 8'd8; lin_hi = 8'd32; lin_mul = 12'd1066;
        end else begin
            case (tgt)
                3'd1: begin lin_x = $signed({4'b0000, t1_bad}) - f_rng; lin_lo = 8'd0;
                            lin_hi = t1_span; lin_mul = t1_mul; end
                3'd2: begin lin_x = f_delta; lin_lo = 8'd8; lin_hi = t2_hi; lin_mul = t2_mul; end
                3'd3: begin lin_x = f_dip; lin_lo = 8'd4; lin_hi = t3_hi; lin_mul = t3_mul; end
                default: begin lin_x = -f_delta; lin_lo = 8'd16; lin_hi = t4_hi; lin_mul = t4_mul; end
            endcase
        end
    end
    // The octave guard is a pure function of the new pitch and the last kept
    // point. One shared evaluator replaces the three copies the FSM used to
    // instantiate; the selected source is a function of the state, so the
    // result is bit-identical in every state that consumes it.
    reg [9:0] g_src;
    always @* begin
        case (st)
            ST_ON1:  g_src = run1;
            ST_ON2:  g_src = onset_p;
            default: g_src = pitch_q4;
        endcase
    end
    wire [9:0] g_val = guard(g_src, last_pt);

    wire [6:0] lin_out = lin(lin_x, lin_lo, lin_hi, lin_mul);
    // bin mean = (sum * 4096 / cnt) >> 12, with 4096/cnt precomputed in recip.
    // The product needs 25 bits, not 21: bsum is 13 bits (7 points * 1023 max,
    // 7161) and recip peaks at 4096 (cnt == 1), so 7161 * 4096 = 29,331,456.
    // At 21 bits the product wrapped for any bin mean above 512 Q4 -- i.e. any
    // bin above 387 Hz, which children's speech reaches routinely -- and the
    // wrapped value then produced a bin mean of 0..11 instead of the real one.
    // That corrupted f_start/f_end and with them delta, rng, argmin and mid.
    wire [24:0] bin_prod = {12'd0, bsum} * {12'd0, recip(cnt)};
    // (s * 154) >> 8 with 154 = 128 + 16 + 8 + 2
    wire [13:0] t2_pen = {lin_out, 7'd0} + {3'd0, lin_out, 4'd0} +
                         {4'd0, lin_out, 3'd0} + {6'd0, lin_out, 1'b0};
    wire [6:0] t3_min = (lin_first < lin_out) ? lin_first : lin_out;

    // ------------------------------------------------------ LUT classifier
    // Trained replacement for the single-board rule cascade. The feature
    // registers (f_rng/f_delta/f_dip/f_tail/argmin) are stable from the edge
    // that leaves FT_FEAT, so the classifier's combinational address is valid
    // from the following cycle on; lut_feat_valid pulses in that cycle (see
    // FT_FEAT/FT_LUT below), and the classifier returns result_valid with the
    // aligned tone two cycles after that. Deterministic 2-cycle response, so
    // FT_LUT cannot hang: even an all-zero/empty table produces tone=0
    // ("abstain"), the same semantic the cascade's fall-through else had.
    reg  lut_feat_valid;
    wire lut_result_valid;
    wire [2:0] lut_tone;
    wire [1:0] lut_conf;
    generate if (ENABLE_CLASSIFIER) begin : g_classifier
    lookup_classifier #(.HEX_FILE(LUT_HEX)) u_lut (
        .clk(clk), .rst_n(rst_n),
        .feat_valid(lut_feat_valid),
        .rng(f_rng), .delta(f_delta), .dip(f_dip),
        .tail_rise(f_tail), .argmin(argmin),
        .result_valid(lut_result_valid),
        .tone(lut_tone), .confidence(lut_conf)
    );
    end else begin : g_product
        assign lut_result_valid = 1'b0;
        assign lut_tone = 3'd0;
        assign lut_conf = 2'd0;
    end endgenerate

    integer bi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; armed <= 1'b0; tgt <= 3'd1; diff_lv <= 2'd1;
            run_len <= 2'd0; run0 <= 10'd0; run1 <= 10'd0; onset_p <= 10'd0;
            last_pt <= 10'd0; n <= 7'd0; uv <= 6'd0; in_utt <= 1'b0;
            wr_en <= 1'b0; wr_addr <= 7'd0; wr_data <= 10'd0; rd_j <= 7'd0;
            k <= 4'd0; kn <= 11'd0; j_hi <= 7'd0; cnt <= 3'd0; remain <= 3'd0;
            bsum <= 13'd0; mn <= 11'd0; mx <= 10'd0; argmin <= 4'd0;
            bin_total <= 14'd0; f_delta <= 12'sd0; f_rng <= 12'sd0;
            f_dip <= 12'sd0; f_tail <= 12'sd0; f_mid <= 1'b0; s_raw <= 7'd0;
            f_t3_rhs <= 13'sd0;
            lin_pass <= 1'b0; lin_first <= 7'd0;
            lut_feat_valid <= 1'b0;
            result_valid <= 1'b0; n_points <= 7'd0; too_short <= 1'b0;
            tone <= 3'd0; score <= 7'd0; stars <= 2'd0; hint <= 3'd0;
            mean_q4 <= 10'd0; bins_flat <= 160'd0;
            point_valid <= 1'b0; point_index <= 7'd0; point_value <= 10'd0;
            for (bi = 0; bi < 16; bi = bi + 1) binv[bi] <= 10'd0;
        end else begin
            result_valid <= 1'b0;
            point_valid <= 1'b0;
            wr_en <= 1'b0;
            lut_feat_valid <= 1'b0;
            if (cancel) begin
                armed <= 1'b0; in_utt <= 1'b0;
                run_len <= 2'd0; n <= 7'd0; uv <= 6'd0;
                st <= ST_IDLE;
                tone <= 3'd0;
                n_points <= 7'd0;
                too_short <= 1'b0;
            end else if (arm) begin
                armed <= 1'b1;
                tgt <= target;
                diff_lv <= difficulty;
                run_len <= 2'd0;
                in_utt <= 1'b0;
                n <= 7'd0;
                uv <= 6'd0;
                st <= ST_IDLE;
            end else begin
            case (st)
            ST_IDLE, ST_ACT: begin
                if (frame_valid && enable && armed) begin
                    if (!in_utt) begin
                        if (voiced) begin
                            if (run_len == 2'd0) begin
                                run0 <= pitch_q4; run_len <= 2'd1;
                            end else if (run_len == 2'd1) begin
                                run1 <= pitch_q4; run_len <= 2'd2;
                            end else begin
                                // third voiced frame: store run0, g(run1), g(p)
                                onset_p <= pitch_q4;
                                run_len <= 2'd0;
                                in_utt <= 1'b1;
                                uv <= 6'd0;
                                wr_en <= 1'b1; wr_addr <= 7'd0; wr_data <= run0;
                                point_valid <= 1'b1; point_index <= 7'd0; point_value <= run0;
                                last_pt <= run0;
                                n <= 7'd1;
                                st <= ST_ON1;
                            end
                        end else begin
                            run_len <= 2'd0;
                        end
                    end else if (voiced) begin
                        uv <= 6'd0;
                        wr_en <= 1'b1; wr_addr <= n; wr_data <= g_val;
                        point_valid <= 1'b1; point_index <= n; point_value <= g_val;
                        last_pt <= g_val;
                        n <= n + 1'b1;
                        if (n + 1'b1 >= MAX_POINTS) begin
                            k <= 4'd0; kn <= 11'd0;
                            st <= FB_START;
                        end
                    end else begin
                        uv <= uv + 1'b1;
                        if (uv + 1'b1 >= END_FRAMES) begin
                            if (n < MIN_POINTS) begin
                                st <= ST_SHORT;
                            end else begin
                                k <= 4'd0; kn <= 11'd0;
                                st <= FB_START;
                            end
                        end
                    end
                end
            end
            ST_ON1: begin
                wr_en <= 1'b1; wr_addr <= 7'd1; wr_data <= g_val;
                point_valid <= 1'b1; point_index <= 7'd1; point_value <= g_val;
                last_pt <= g_val;
                n <= 7'd2;
                st <= ST_ON2;
            end
            ST_ON2: begin
                wr_en <= 1'b1; wr_addr <= 7'd2; wr_data <= g_val;
                point_valid <= 1'b1; point_index <= 7'd2; point_value <= g_val;
                last_pt <= g_val;
                n <= 7'd3;
                st <= ST_ACT;
            end
            ST_SHORT: begin
                n_points <= n;
                too_short <= 1'b1;
                tone <= 3'd0; score <= 7'd0; stars <= 2'd0; hint <= 3'd5;
                mean_q4 <= 10'd0;
                result_valid <= 1'b1;
                in_utt <= 1'b0; n <= 7'd0; uv <= 6'd0; run_len <= 2'd0;
                st <= ST_IDLE;
            end
            FB_START: begin
                rd_j <= lo_idx;
                j_hi <= hi_idx;
                cnt <= (hi_idx > lo_idx) ? (hi_idx - lo_idx) : 3'd0;
                remain <= (hi_idx > lo_idx) ? (hi_idx - lo_idx) : 3'd0;
                bsum <= 13'd0;
                st <= FB_ISSUE;
            end
            FB_ISSUE: st <= FB_TAKE;                  // read latency
            FB_TAKE: begin
                if (cnt == 3'd0) begin
                    binv[k] <= rd_data;
                    st <= FB_NEXT;
                end else if (remain == 3'd1) begin
                    bsum <= bsum + rd_data;
                    st <= FB_MUL;
                end else begin
                    bsum <= bsum + rd_data;
                    remain <= remain - 1'b1;
                    rd_j <= rd_j + 1'b1;
                    st <= FB_ISSUE;
                end
            end
            FB_MUL: begin
                binv[k] <= (bin_prod + 25'd2048) >> 12;
                st <= FB_NEXT;
            end
            FB_NEXT: begin
                if (k == 4'd15) begin
                    k <= 4'd0;
                    mn <= 11'd1024; mx <= 10'd0; argmin <= 4'd0; bin_total <= 14'd0;
                    st <= FT_SCAN;
                end else begin
                    k <= k + 1'b1;
                    kn <= kn_next;
                    st <= FB_START;
                end
            end
            FT_SCAN: begin
                if ({1'b0, binv[k]} < mn) begin
                    mn <= {1'b0, binv[k]};
                    argmin <= k;
                end
                if (binv[k] > mx)
                    mx <= binv[k];
                bin_total <= bin_total + binv[k];
                if (k == 4'd15)
                    st <= FT_FEAT;
                else
                    k <= k + 1'b1;
            end
            FT_FEAT: begin
                // f_end - f_start, sign-extended. Also the base of the
                // third-tone threshold below; kept in a wire so both registers
                // read the SAME source. Reading f_delta in the next statement
                // would sample its OLD value -- all of these are non-blocking
                // assignments in one clocked block, so f_delta is still the
                // previous clip's delta at this point. That mistake made the
                // third-tone clause compare against a stale threshold and sent
                // a valid third tone (n=96, delta=-24) down the fall-through.
                f_delta <= $signed({2'b00, f_end}) - $signed({2'b00, f_start});
                f_rng <= $signed({2'b00, mx}) - $signed({1'b0, mn});
                f_dip <= $signed({2'b00, (f_start < f_end) ? f_start : f_end}) -
                         $signed({1'b0, mn});
                f_tail <= $signed({2'b00, f_end}) - $signed({1'b0, mn});
                // Sign-extend to 13 bits, then add. Writing this as
                // (f_delta >= 12'sd-16) would be a different rule: it tests a
                // fixed floor, and the whole point of the clause is to compare
                // the dip against the clip's OWN net movement.
                f_t3_rhs <= f_delta_next + 13'sd16;
                f_mid <= (argmin >= 4'd5) && (argmin <= 4'd13);
                // features commit on this edge; pulse the classifier in the
                // same edge so lut_feat_valid is high exactly when the new
                // f_* values are first stable
                lut_feat_valid <= ENABLE_CLASSIFIER != 0;
                if (ENABLE_CLASSIFIER) begin
                    st <= FT_LUT;
                end else begin
                    tone <= 3'd0;
                    lin_pass <= 1'b0;
                    st <= FT_LIN;
                end
            end
            FT_LUT: begin
                // Classification moved to the trained lookup table (R78).
                // The single-board cascade this state used to hold (rng<32
                // one-tone, scale-free third-tone dip rule, delta bands, the
                // rng<48 rescue) survives in the golden model and the
                // single-board RTL; its measured limits on real speech are
                // what motivated the trained-table architecture.
                lut_feat_valid <= 1'b0;
                if (lut_result_valid) begin
                    // result_valid and lut_tone are edge-aligned (see
                    // lookup_classifier), so this capture is race-free.
                    // Classification cascade (docs/10 section 3): LUT first,
                    // then the Board-A NB fallback verdict when its hold is
                    // valid (docs/09 3.2 -- CV: 75.0% -> 86.6% on the abstain
                    // set, model d), then the Board-A DTW template verdict,
                    // else abstain (tone 0).
                    tone <= (lut_tone != 3'd0) ? lut_tone
                          : (nb_valid  ? nb_tone
                          : (dtw_valid ? dtw_tone : 3'd0));
                    lin_pass <= 1'b0;
                    st <= FT_LIN;
                end
            end
            FT_LIN: begin
                if (!lin_pass) begin
                    case (tgt)
                        3'd1: begin s_raw <= lin_out; st <= FT_OUT; end
                        3'd2: begin
                            // Same clause as the FT_SCORE decision above, on
                            // purpose: this penalty means "you were asked for a
                            // second tone but you produced the third-tone
                            // shape". If the two sites used different tests,
                            // the scorer would punish a take it had just
                            // classified as a perfectly good second tone (or
                            // let a third-shaped take through unscored).
                            s_raw <= (f_mid && f_tail >= 12'sd16 && f_dip >= f_t3_rhs)
                                     ? {1'b0, t2_pen[13:8]} : lin_out;
                            st <= FT_OUT;
                        end
                        3'd3: begin lin_first <= lin_out; lin_pass <= 1'b1; end
                        default: begin s_raw <= lin_out; st <= FT_OUT; end
                    endcase
                end else begin
                    s_raw <= f_mid ? t3_min : (t3_min >> 1);
                    lin_pass <= 1'b0;
                    st <= FT_OUT;
                end
            end
            FT_OUT: begin
                n_points <= n;
                too_short <= 1'b0;
                score <= s_raw;
                stars <= (s_raw >= 7'd85) ? 2'd3 : (s_raw >= 7'd60) ? 2'd2 :
                         (s_raw >= 7'd30) ? 2'd1 : 2'd0;
                hint <= (s_raw >= 7'd85) ? 3'd0 : tgt;
                mean_q4 <= bin_total[13:4];
                for (bi = 0; bi < 16; bi = bi + 1)
                    bins_flat[bi*10 +: 10] <= binv[bi];
                result_valid <= 1'b1;
                in_utt <= 1'b0; n <= 7'd0; uv <= 6'd0; run_len <= 2'd0;
                st <= ST_IDLE;
            end
            default: st <= ST_IDLE;
            endcase
            end
        end
    end
endmodule
