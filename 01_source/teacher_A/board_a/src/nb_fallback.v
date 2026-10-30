`timescale 1ns/1ps
// Naive-Bayes fallback classifier (docs/09 §3, R80 P1.5).
//
// The 3-bit F0 LUT inside Board B's tone_scorer abstains on ~15% of real
// utterances (empty table cells); the trained diagonal-Gaussian NB over the
// 10 spectral/quality features recovers 86.6% of THOSE (5-fold CV, see
// tools/spectral_cv_report_20261001.txt model d). This core lives on Board
// A (Board B has no LE headroom) and its verdict travels to Board B in
// feature-frame byte 12.
//
// Structure:
//   - utterance accumulator: activates on the first voiced frame, freezes
//     24 unvoiced frames after the last one (matching the scorer's
//     END_FRAMES), and holds the frozen verdict until the next utterance
//     -- Board B may read it at any point during that gap;
//   - running means via sum >> floor(log2(count)) (no divider);
//   - 40-term quadratic evaluation, one shared multiplier, 2 cycles per
//     term (80 clocks per refresh against a 416k-clock frame -- idle).
// Constants come from tools/export_nb_constants.py -> nb_constants.vh
// (keep it next to this file for TD include resolution).
`include "nb_constants.vh"
module nb_fallback (
    input  wire        clk,           // 25 MHz video clock
    input  wire        rst_n,
    input  wire        frame_valid,   // 1-clk per tracker frame
    input  wire        voiced,
    input  wire [63:0] bands,         // 8 x e_q from goertzel_8band
    input  wire [3:0]  jitter_q,
    input  wire [3:0]  shimmer_q,
    output reg  [2:0]  nb_tone,       // 1..4, frozen per utterance
    output reg         nb_ready       // a completed utterance is held
);
    localparam integer UV_RESET = 24;  // = tone_scorer END_FRAMES
    localparam integer MIN_FRAMES = 8; // below this the mean is noise

    // ------------------------------------------------------ accumulator
    reg        acc_active;             // utterance window open
    reg        acc_frozen;             // completed, holding the verdict
    reg [5:0]  uv_cnt;
    reg [6:0]  cnt;                    // frames in the window (<= 96)
    reg [15:0] sum_e0, sum_e1, sum_e2, sum_e3;
    reg [15:0] sum_e4, sum_e5, sum_e6, sum_e7;
    reg [11:0] sum_j, sum_s;

    wire [63:0] feat = bands;         // e_q bytes, band k in [8k+7:8k]

    // floor(log2(cnt)) for cnt = 1..127 (0 impossible: cnt>=1 when active)
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
                default:    shf_of = 3'd0;   // cnt == 1
            endcase
        end
    endfunction

    wire [2:0]  shf   = shf_of(cnt);
    wire [7:0]  m_e0  = sum_e0 >> shf;
    wire [7:0]  m_e1  = sum_e1 >> shf;
    wire [7:0]  m_e2  = sum_e2 >> shf;
    wire [7:0]  m_e3  = sum_e3 >> shf;
    wire [7:0]  m_e4  = sum_e4 >> shf;
    wire [7:0]  m_e5  = sum_e5 >> shf;
    wire [7:0]  m_e6  = sum_e6 >> shf;
    wire [7:0]  m_e7  = sum_e7 >> shf;
    wire [7:0]  m_j   = {4'd0, sum_j} >> shf;
    wire [7:0]  m_s   = {4'd0, sum_s} >> shf;

    // ------------------------------------------------------ NB evaluation
    // 40 terms = 4 classes x 10 features; term = (x-mu)^2 * inv_var
    reg [5:0]  term_idx;              // 0..39: class = idx/10, feat = idx%10
    reg [1:0]  term_cls;
    reg [3:0]  term_feat;
    reg        term_phase;            // 0 = square, 1 = scale+accumulate
    reg        eval_busy;
    reg        eval_done;
    reg signed [8:0] diff;
    reg [17:0] sq;
    reg signed [33:0] acc0, acc1, acc2, acc3;
    reg signed [33:0] best;
    reg [1:0]  best_cls;

    always @* begin
        term_cls  = term_idx / 10;    // 0..3, synthesises as a small compare
        term_feat = term_idx % 10;    // 0..9
    end

    // feature select for the current term
    reg [7:0] feat_x;
    always @* begin
        case (term_feat)
            4'd0: feat_x = m_e0;
            4'd1: feat_x = m_e1;
            4'd2: feat_x = m_e2;
            4'd3: feat_x = m_e3;
            4'd4: feat_x = m_e4;
            4'd5: feat_x = m_e5;
            4'd6: feat_x = m_e6;
            4'd7: feat_x = m_e7;
            4'd8: feat_x = m_j;
            default: feat_x = m_s;
        endcase
    end

    // per-(class,feature) constants via one flat case on the term index
    reg [7:0]  c_mu;
    reg [11:0] c_iv;
    always @* begin
        case (term_idx)
            6'd0:  begin c_mu = NB_MU1_0;  c_iv = NB_IV1_0;  end
            6'd1:  begin c_mu = NB_MU1_1;  c_iv = NB_IV1_1;  end
            6'd2:  begin c_mu = NB_MU1_2;  c_iv = NB_IV1_2;  end
            6'd3:  begin c_mu = NB_MU1_3;  c_iv = NB_IV1_3;  end
            6'd4:  begin c_mu = NB_MU1_4;  c_iv = NB_IV1_4;  end
            6'd5:  begin c_mu = NB_MU1_5;  c_iv = NB_IV1_5;  end
            6'd6:  begin c_mu = NB_MU1_6;  c_iv = NB_IV1_6;  end
            6'd7:  begin c_mu = NB_MU1_7;  c_iv = NB_IV1_7;  end
            6'd8:  begin c_mu = NB_MU1_8;  c_iv = NB_IV1_8;  end
            6'd9:  begin c_mu = NB_MU1_9;  c_iv = NB_IV1_9;  end
            6'd10: begin c_mu = NB_MU2_0;  c_iv = NB_IV2_0;  end
            6'd11: begin c_mu = NB_MU2_1;  c_iv = NB_IV2_1;  end
            6'd12: begin c_mu = NB_MU2_2;  c_iv = NB_IV2_2;  end
            6'd13: begin c_mu = NB_MU2_3;  c_iv = NB_IV2_3;  end
            6'd14: begin c_mu = NB_MU2_4;  c_iv = NB_IV2_4;  end
            6'd15: begin c_mu = NB_MU2_5;  c_iv = NB_IV2_5;  end
            6'd16: begin c_mu = NB_MU2_6;  c_iv = NB_IV2_6;  end
            6'd17: begin c_mu = NB_MU2_7;  c_iv = NB_IV2_7;  end
            6'd18: begin c_mu = NB_MU2_8;  c_iv = NB_IV2_8;  end
            6'd19: begin c_mu = NB_MU2_9;  c_iv = NB_IV2_9;  end
            6'd20: begin c_mu = NB_MU3_0;  c_iv = NB_IV3_0;  end
            6'd21: begin c_mu = NB_MU3_1;  c_iv = NB_IV3_1;  end
            6'd22: begin c_mu = NB_MU3_2;  c_iv = NB_IV3_2;  end
            6'd23: begin c_mu = NB_MU3_3;  c_iv = NB_IV3_3;  end
            6'd24: begin c_mu = NB_MU3_4;  c_iv = NB_IV3_4;  end
            6'd25: begin c_mu = NB_MU3_5;  c_iv = NB_IV3_5;  end
            6'd26: begin c_mu = NB_MU3_6;  c_iv = NB_IV3_6;  end
            6'd27: begin c_mu = NB_MU3_7;  c_iv = NB_IV3_7;  end
            6'd28: begin c_mu = NB_MU3_8;  c_iv = NB_IV3_8;  end
            6'd29: begin c_mu = NB_MU3_9;  c_iv = NB_IV3_9;  end
            6'd30: begin c_mu = NB_MU4_0;  c_iv = NB_IV4_0;  end
            6'd31: begin c_mu = NB_MU4_1;  c_iv = NB_IV4_1;  end
            6'd32: begin c_mu = NB_MU4_2;  c_iv = NB_IV4_2;  end
            6'd33: begin c_mu = NB_MU4_3;  c_iv = NB_IV4_3;  end
            6'd34: begin c_mu = NB_MU4_4;  c_iv = NB_IV4_4;  end
            6'd35: begin c_mu = NB_MU4_5;  c_iv = NB_IV4_5;  end
            6'd36: begin c_mu = NB_MU4_6;  c_iv = NB_IV4_6;  end
            6'd37: begin c_mu = NB_MU4_7;  c_iv = NB_IV4_7;  end
            6'd38: begin c_mu = NB_MU4_8;  c_iv = NB_IV4_8;  end
            default: begin c_mu = NB_MU4_9;  c_iv = NB_IV4_9;  end
        endcase
    end

    wire signed [8:0]  diff_n = $signed({1'b0, feat_x}) - $signed({1'b0, c_mu});
    wire signed [17:0] sq_n   = diff_n * diff_n;
    wire signed [33:0] term   = $signed(sq_n) * $signed({4'b0000, c_iv});

    // ------------------------------------------------------ control
    integer gi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_active <= 1'b0; acc_frozen <= 1'b0; uv_cnt <= 6'd0;
            cnt <= 7'd0;
            sum_e0 <= 16'd0; sum_e1 <= 16'd0; sum_e2 <= 16'd0; sum_e3 <= 16'd0;
            sum_e4 <= 16'd0; sum_e5 <= 16'd0; sum_e6 <= 16'd0; sum_e7 <= 16'd0;
            sum_j <= 12'd0; sum_s <= 12'd0;
            term_idx <= 6'd0; term_phase <= 1'b0; eval_busy <= 1'b0;
            eval_done <= 1'b0;
            diff <= 9'sd0; sq <= 18'd0;
            acc0 <= 34'sd0; acc1 <= 34'sd0; acc2 <= 34'sd0; acc3 <= 34'sd0;
            best <= 34'sd0; best_cls <= 2'd0;
            // nb_tone/nb_ready are driven ONLY by the tail block below
        end else begin
            // ---- utterance window maintenance ----
            if (frame_valid) begin
                if (voiced) begin
                    uv_cnt <= 6'd0;
                    if (!acc_active) begin
                        // open a fresh window (also un-freezes the hold)
                        acc_active <= 1'b1;
                        acc_frozen <= 1'b0;
                        cnt <= 7'd0;
                        sum_e0 <= 16'd0; sum_e1 <= 16'd0;
                        sum_e2 <= 16'd0; sum_e3 <= 16'd0;
                        sum_e4 <= 16'd0; sum_e5 <= 16'd0;
                        sum_e6 <= 16'd0; sum_e7 <= 16'd0;
                        sum_j <= 12'd0; sum_s <= 12'd0;
                    end
                end else if (acc_active) begin
                    uv_cnt <= uv_cnt + 1'b1;
                    if (uv_cnt + 1'b1 >= UV_RESET) begin
                        // window closed: freeze the accumulated verdict
                        acc_active <= 1'b0;
                        acc_frozen <= 1'b1;
                    end
                end
                // accumulate this frame's features while the window is open
                if (acc_active) begin
                    // audit P2-2 + round-5: saturate AND freeze -- >127 voiced
                    // frames used to wrap the denominator, and the eight 16-bit
                    // band sums wrap even earlier (258 full-scale frames) than
                    // the 12-bit jitter sums did
                    if (cnt != 7'd127)
                        cnt <= cnt + 1'b1;
                    if (cnt <= 7'd126) begin
                        sum_e0 <= sum_e0 + feat[7:0];
                        sum_e1 <= sum_e1 + feat[15:8];
                        sum_e2 <= sum_e2 + feat[23:16];
                        sum_e3 <= sum_e3 + feat[31:24];
                        sum_e4 <= sum_e4 + feat[39:32];
                        sum_e5 <= sum_e5 + feat[47:40];
                        sum_e6 <= sum_e6 + feat[55:48];
                        sum_e7 <= sum_e7 + feat[63:56];
                    end
                    // audit N4: the sums are 12-bit -- freeze them once the
                    // frame counter saturates (long utterances used to wrap
                    // the noise-mean denominator)
                    if (cnt != 7'd127) begin
                        sum_j <= sum_j + jitter_q;
                        sum_s <= sum_s + shimmer_q;
                    end
                end
            end

            // ---- NB evaluation: one term per two clocks ----
            if (frame_valid && (acc_active || acc_frozen) && !eval_busy) begin
                eval_busy <= 1'b1;
                term_idx  <= 6'd0;
                term_phase<= 1'b0;
                acc0 <= 34'sd0; acc1 <= 34'sd0;
                acc2 <= 34'sd0; acc3 <= 34'sd0;
                best <= 34'sd8589934591;  // 2^33-1
            end else if (eval_busy) begin
                if (!term_phase) begin
                    diff <= diff_n;
                    sq   <= sq_n;
                    term_phase <= 1'b1;
                end else begin
                    case (term_cls)
                        2'd0: acc0 <= acc0 + term;
                        2'd1: acc1 <= acc1 + term;
                        2'd2: acc2 <= acc2 + term;
                        default: acc3 <= acc3 + term;
                    endcase
                    term_phase <= 1'b0;
                    if (term_idx == 6'd39) begin
                        eval_done <= 1'b1;   // one-cycle pulse; the argmin
                                             // block samples the settled
                                             // accumulators next cycle
                        eval_busy <= 1'b0;
                    end else begin
                        term_idx <= term_idx + 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------ argmin (4-way)
    // Computed from the settled accumulators one cycle AFTER the last acc
    // write (eval_done) -- comparing inside the FSM would race with the
    // accumulator commits (the R72 non-blocking lesson, again).
    // class index 0..3 maps to the exported constants _1.._4 (tone 1..4)
    wire signed [33:0] s0  = acc0 + NB_LDT1 - NB_LPR1;
    wire signed [33:0] s1c = acc1 + NB_LDT2 - NB_LPR2;
    wire signed [33:0] s2c = acc2 + NB_LDT3 - NB_LPR3;
    wire signed [33:0] s3c = acc3 + NB_LDT4 - NB_LPR4;

    function [1:0] argmin4;
        input signed [33:0] a;
        input signed [33:0] b;
        input signed [33:0] c;
        input signed [33:0] d;
        reg signed [33:0] m;
        reg [1:0] idx;
        begin
            m = a; idx = 2'd0;
            if (b < m) begin m = b; idx = 2'd1; end
            if (c < m) begin m = c; idx = 2'd2; end
            if (d < m) begin m = d; idx = 2'd3; end
            argmin4 = idx;                 // ties -> lowest class (np.argmax)
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nb_tone <= 3'd0;
            nb_ready <= 1'b0;
        end else begin
            if (eval_done) begin
                nb_tone  <= {1'b0, argmin4(s0, s1c, s2c, s3c)} + 3'd1;
                // audit P2-1: acc_frozen alone let a 1-frame noise window
                // (frozen on silence) report ready -- require the window to
                // have been worth averaging when it closed
                nb_ready <= (cnt >= MIN_FRAMES) && acc_frozen;
            end
            if (frame_valid && voiced && !acc_active)
                nb_ready <= 1'b0;          // a new window invalidated the hold
        end
    end
endmodule
