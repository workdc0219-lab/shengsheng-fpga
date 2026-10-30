`timescale 1ns/1ps
// ShengSheng training logic (docs/39 section 3, docs/40 section 2.6).
// Runs in the video clock domain. UI time uses the local 60Hz ui_tick;
// trk_valid consumes real remote samples only. Modes: 0 display, 1 tone
// climb, 2 balloon, 3 loudness train, 4 picture cards, 5 unscored discovery.
//
// Tone climb / cards: INTRO (prompt) -> DEMO (model voice, target path
// revealed in step with the sound) -> GUARD (200 ms echo guard) -> LISTEN
// (scorer armed, live curve and pitch ball) -> FEED (stars, score, hint,
// ding or soft prompt) -> next question on two or more stars, otherwise the
// demo repeats; a too-short attempt goes straight back to LISTEN.
//
// Teacher demo (docs/14 section 1): while teacher_on (link up and the
// A-board SW1 on) the DEMO phase plays no model voice; it waits for the next
// teacher curve from Board A, redraws the target mountain with the teacher's
// shape placed at the target tone's template level, and moves on to GUARD.
// No curve within 8 s falls back to the model voice and the built-in
// template for that question. Scoring is unchanged either way.
module shengsheng_game #(parameter integer ENABLE_SINGLE_MIC=0) (
    input wire single_mic,mic_teacher,mic_ready,mic_transition,
    input  wire         clk,
    input  wire         rst_n,
    input  wire [2:0]   mode,
    input  wire         key_next,
    input  wire         key_replay,
    input  wire [1:0]   difficulty,
    input  wire [1:0]   active_index,
    input  wire         ui_tick,
    input  wire         link_up,
    input  wire         tch_armed,
    // pitch tracker, once per frame
    input  wire         trk_valid,
    input  wire         trk_voiced,
    input  wire [9:0]   trk_pitch,
    input  wire [7:0]   trk_level,
    // tone scorer
    input  wire         sc_valid,
    input  wire         sc_active,       // audit P1: scorer processing in-flight
    input  wire         sc_short,
    input  wire [6:0]   sc_score,
    input  wire [1:0]   sc_stars,
    input  wire [2:0]   sc_hint,
    input  wire [9:0]   sc_mean,
    input  wire [159:0] sc_bins,
    input  wire         sc_point_valid,
    input  wire [6:0]   sc_point_index,
    input  wire [9:0]   sc_point_value,
    output reg          sc_arm,
    output reg          sc_cancel,
    output reg          demo_request,
    output reg          demo_cancel,
    output reg  [2:0]   sc_target,
    output wire         sc_enable,
    // model voice
    input  wire         syn_playing,
    input  wire [7:0]   syn_progress,
    input  wire         syn_done,
    output reg          syn_cmd_valid,
    output reg  [2:0]   syn_cmd_mode,
    output reg  [2:0]   syn_cmd_tone,
    // background picture
    output reg          goto_valid,
    output reg  [1:0]   goto_index,
    output wire         training,
    // R73: 3-star FEED celebration (ridge gold pulse) and the live level
    // micro-bar during LISTEN before anything voiced is picked up
    output reg          celebrate,
    output wire         listen_meter,
    // overlay scene
    output wire         panel_show,
    output wire         child_show,
    output reg  [9:0]   target_reveal,
    output wire         ball_show,
    output reg  [8:0]   ball_col,
    output reg  [7:0]   ball_y,
    output wire         balloon_show,
    output reg  [7:0]   balloon_r,
    output wire         train_show,
    output reg  [9:0]   train_x,
    output reg  [7:0]   meter_level,
    output wire [7:0]   win_lo,
    output wire [7:0]   win_hi,
    output reg          meter_ok,
    output wire         card_show,
    output wire [1:0]   card_index,
    output wire [1:0]   eff_diff,           // R82: adaptive difficulty
    output reg  [5:0]   s0_id,
    output reg  [5:0]   s1_id,
    output reg  [47:0]  s2_cells,   // 8 x 6-bit phrase ids, LSB cell = the
                                    // leftmost 24 px slot
    output reg  [5:0]   s3_id,
    output reg  [1:0]   s3_class,
    // column-buffer drawer
    output reg          cmd_valid,
    input  wire         cmd_ready,
    output reg          cmd_buf,
    output reg  [8:0]   cmd_x0,
    output reg  [3:0]   cmd_log2n,
    output reg  [7:0]   cmd_y0,
    output reg  [7:0]   cmd_y1,
    output reg          cmd_vis,
    // teacher demo (docs/14)
    input  wire         teacher_on,
    input  wire         tch_new,             // 1-clk: a checked teacher curve
    input  wire [127:0] tch_off,             // 16 x signed 8 shape
    output wire [2:0]   phase_o,
    output wire         tch_used,            // this question's mountain is the teacher's
    output wire         summary_show,        // F1: session summary screen active
    output wire         discover_show,       // F2: voice discovery mode active
    output wire [7:0]   disc_radius_o,       // F2: discovery circle size
    output wire [2:0]   disc_hue_o,          // F2: discovery circle color
    output wire [7:0]   sess_q_o,            // F1: session question count
    output wire [7:0]   sess_star_o          // F1: session star count
);
`include "ss_phrases.vh"

    localparam [2:0] M_DISPLAY = 3'd0, M_TONE = 3'd1, M_BALLOON = 3'd2,
                     M_TRAIN = 3'd3, M_CARD = 3'd4, M_DISCOVER = 3'd5;
    localparam [2:0] PH_INTRO = 3'd0, PH_DEMO = 3'd1, PH_GUARD = 3'd2,
                     PH_LISTEN = 3'd3, PH_FEED = 3'd4, PH_SUMMARY = 3'd5;
    localparam [1:0] CL_INFO = 2'd0, CL_GOOD = 2'd1, CL_HINT = 2'd2, CL_CUE = 2'd3;
    localparam [9:0] CENTER_DEFAULT = 10'd401;     // 260 Hz
    localparam [7:0] BALLOON_MIN = 8'd24, BALLOON_MAX = 8'd120;
    localparam [9:0] TRAIN_START = 10'd48, TRAIN_END = 10'd540;
    localparam [7:0] TRAIN_CENTER = 8'd185;

    reg [2:0] mode_q;
    reg link_q;
    // audit F1: session counters for the summary screen (F1 bug found in v2:
    // they were declared and displayed but never incremented)
    reg [7:0] sess_q;        // completed questions this round, maximum ten
    reg [7:0] sess_star;     // final stars committed once per completed question
    reg question_completed; // replaying an already completed question cannot recount it
    // audit F2: discover mode visualization
    reg [7:0] disc_radius;   // circle size = f(level)
    reg [2:0] disc_hue;      // color = f(pitch high bits)
    reg [2:0] phase;
    reg [9:0] timer;
    reg [1:0] q_idx;
    reg retry_demo, retry_listen;
    reg heard;               // something voiced during this LISTEN

    reg [3:0] sess_stars;    // stars collected this mode session, cap 9
    reg [3:0] sess_next;     // sess_stars including the result being shown
    // R82: adaptive difficulty -- tracks recent success rate and biases the
    // effective difficulty within +-1 of the manual setting. The child stays
    // in the "challenging but achievable" zone without the parent adjusting
    // KEY4 every question.
    reg [2:0] adapt_lv;      // 0-7, 4 = neutral; >=5 one step harder, <=1 one step easier
    reg [1:0] retry_count;   // consecutive retries on the same tone
    reg [8:0] feed_limit;    // FEED duration in frames, by stars
    // R82 adaptive difficulty: adapt_lv biases the effective difficulty
    // within +-1 of the manual setting; the scorer sees the same value so
    // the scoring thresholds adapt too
    reg  [1:0] eff_diff_r;
    always @* begin
        case (adapt_lv)
            3'd0, 3'd1: eff_diff_r = (difficulty > 2'd0) ? difficulty - 2'd1 : 2'd0;
            3'd2, 3'd3, 3'd4: eff_diff_r = difficulty;
            default: eff_diff_r = (difficulty < 2'd3) ? difficulty + 2'd1 : 2'd3;
        endcase
    end
    assign eff_diff = eff_diff_r;
    // answer window by effective difficulty: 12/10/8/6 s (R19 -- speech-delayed
    // children need longer; the hardest tier tightens the pace)
    wire [9:0] listen_limit = (eff_diff_r == 2'd0) ? 10'd720 :
                              (eff_diff_r == 2'd1) ? 10'd600 :
                              (eff_diff_r == 2'd2) ? 10'd480 : 10'd360;
    reg [9:0] center;
    reg [6:0] ball_age;
    reg [9:0] bg_timer;
    reg [9:0] center_draw;                   // centre used for the curve on screen
    reg popped;
    // teacher demo
    reg tch_wait;                            // DEMO is waiting for the teacher
    reg tch_got;                             // a curve arrived during this wait
    reg tch_ack;                             // current request accepted by A
    reg use_tch;                             // mountain drawn from tch_q
    reg [127:0] tch_q;
    localparam [9:0] TCH_TIMEOUT = 10'd480;  // 8 s, then the model voice
    assign phase_o = phase;
    assign tch_used = use_tch;

    assign training = (mode != M_DISPLAY);
    wire shared_mic=(ENABLE_SINGLE_MIC!=0) && single_mic;
    wire child_selected=!shared_mic || (!mic_teacher && mic_ready && !mic_transition);
    wire teacher_selected=!shared_mic || (mic_teacher && mic_ready && !mic_transition);
    // The train starts only on an explicit NEXT event after link/role readiness.
    // REPLAY wins if both events coincide; a reconnect cannot queue a start.
    wire train_start_requested=key_next && !key_replay && link_up && link_q && child_selected;
    wire mic_pause=shared_mic && (
        (phase==PH_INTRO && teacher_on && !teacher_selected) ||
        (phase==PH_DEMO && tch_wait && !tch_got && !teacher_selected) ||
        ((phase==PH_GUARD || phase==PH_LISTEN) && !child_selected));
    reg mic_teacher_q;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)mic_teacher_q<=0;else mic_teacher_q<=mic_teacher;
    wire word_mode = (mode == M_TONE) || (mode == M_CARD);
    assign summary_show  = word_mode && (phase == PH_SUMMARY);
    assign discover_show = (mode_q == M_DISCOVER) && (mode == M_DISCOVER);
    assign disc_radius_o = disc_radius;
    assign disc_hue_o    = disc_hue;
    assign sess_q_o      = sess_q;
    assign sess_star_o   = sess_star;
    assign listen_meter = word_mode && (phase == PH_LISTEN) && !heard;
    assign panel_show = (mode == M_TONE) && !summary_show;
    assign child_show = (mode == M_TONE) && !summary_show;
    assign card_show = (mode == M_CARD) && !summary_show;
    assign card_index = q_idx;
    assign balloon_show = (mode == M_BALLOON) && !popped;
    assign train_show = (mode == M_TRAIN);
    assign ball_show = (mode == M_TONE) && (phase == PH_LISTEN) && (ball_age < 7'd8);
    assign sc_enable = child_selected && link_up && word_mode && (mode == mode_q) &&
                       (phase == PH_LISTEN) && !syn_playing && !key_next && !key_replay;

    // ------------------------------------------------------ helpers
    function signed [7:0] tpl;               // tables.TONE_TEMPLATES (q4)
        input [1:0] t;                       // tone - 1
        input [3:0] i;
        reg signed [7:0] v;
        begin
            case (t)
            2'd1: case (i)
                0: v = 0; 1: v = 0; 2: v = 2; 3: v = 5; 4: v = 10; 5: v = 16;
                6: v = 22; 7: v = 29; 8: v = 35; 9: v = 42; 10: v = 48; 11: v = 53;
                12: v = 58; 13: v = 61; 14: v = 62; default: v = 64; endcase
            2'd2: case (i)
                0: v = 0; 1: v = -9; 2: v = -21; 3: v = -28; 4: v = -35; 5: v = -40;
                6: v = -44; 7: v = -47; 8: v = -48; 9: v = -46; 10: v = -42; 11: v = -38;
                12: v = -34; 13: v = -29; 14: v = -24; default: v = -19; endcase
            2'd3: case (i)
                0: v = 64; 1: v = 62; 2: v = 58; 3: v = 50; 4: v = 40; 5: v = 29;
                6: v = 16; 7: v = 3; 8: v = -10; 9: v = -22; 10: v = -34; 11: v = -43;
                12: v = -51; 13: v = -58; 14: v = -62; default: v = -64; endcase
            default: v = 64;
            endcase
            tpl = v;
        end
    endfunction

    function [7:0] clamp_y;                  // 128 - 1.5*offset, clamped to 0..255
        input signed [11:0] off;
        reg signed [13:0] v;
        begin
            v = 14'sd128 - off - (off >>> 1);
            clamp_y = (v < 0) ? 8'd0 : (v > 14'sd255) ? 8'd255 : v[7:0];
        end
    endfunction

    function [7:0] map_c;                    // pitch_q4 -> panel row
        input [9:0] p;
        input [9:0] c;
        begin
            map_c = clamp_y($signed({2'b00, p}) - $signed({2'b00, c}));
        end
    endfunction

    function [5:0] digit_id;
        input [3:0] d;
        begin
            digit_id = PH_C_0 + {2'b00, d};
        end
    endfunction

    reg [1:0] sum_scan;                  // 0 score, 1 sess_q, 2 sess_star
    reg [3:0] sq_t_q, sq_o_q, ss_t_q, ss_o_q;
    wire [7:0] sess_q_d = sess_q;
    wire [7:0] sess_star_d = sess_star;
    // score digits: hundreds (score 100), tens, ones -- input muxed by the
    // summary scan (the scorer cannot fire during PH_SUMMARY, so the score
    // path never sees a muxed value)
    wire [6:0] sc_mod = (sum_scan == 2'd1) ? {1'b0, sess_q_d} :
                        (sum_scan == 2'd2) ? {1'b0, sess_star_d} :
                        (sc_score >= 7'd100) ? 7'd0 : sc_score;
    wire [3:0] sc_tens = (sc_mod >= 7'd90) ? 4'd9 : (sc_mod >= 7'd80) ? 4'd8 :
                         (sc_mod >= 7'd70) ? 4'd7 : (sc_mod >= 7'd60) ? 4'd6 :
                         (sc_mod >= 7'd50) ? 4'd5 : (sc_mod >= 7'd40) ? 4'd4 :
                         (sc_mod >= 7'd30) ? 4'd3 : (sc_mod >= 7'd20) ? 4'd2 :
                         (sc_mod >= 7'd10) ? 4'd1 : 4'd0;
    wire [6:0] sc_ones = sc_mod - {sc_tens, 3'b000} - {2'b00, sc_tens, 1'b0};

    // F1 summary strip BCD: the score ladder below is SHARED -- during the
    // first two summary frames sum_scan routes sess_q (scan 1) then
    // sess_star (scan 2) through it and the digits are latched, so the
    // summary needs no second ladder (the place gate could not afford one).
    // A session ends at 10 scored questions (summary fires, counters reset),
    // so the values cannot exceed ~40 and no 99 cap is needed.
    // ------------------------------------------------------ live points FIFO
    reg [16:0] lp_fifo [0:3];
    reg [1:0] lp_wr, lp_rd;
    reg [2:0] lp_count;
    reg [7:0] lp_prev_y;
    // drawer jobs
    reg pend_clear, pend_target, pend_bins;
    reg [3:0] seg;
    reg [1:0] job;                           // 0 none, 1 clear, 2 target, 3 bins
    reg lp_push, lp_pop;                     // per-cycle FIFO events (blocking)
    reg [159:0] bins_q;
    reg primed;                              // y of point 0 is in dr_prev_y
    reg [7:0] dr_prev_y;
    wire [16:0] lp_head = lp_fifo[lp_rd];
    // 96 samples across 512 columns. floor(i*16/3) is exact for 0..95
    // with the fixed reciprocal below. Eight-pixel segments overlap by
    // 2/3 columns; clamp the final segment so writes never wrap at x=512.
    wire [17:0] live_x_product = lp_head[16:10] * 11'd1366;
    wire [9:0] live_x_raw = live_x_product[17:8];
    wire [8:0] live_x = (live_x_raw > 10'd504) ? 9'd504 : live_x_raw[8:0];
    // point index for target/bins jobs: 0 while priming, else seg + 1 (max 15)
    wire [3:0] pt_k = !primed ? 4'd0 : (seg == 4'd15) ? 4'd15 : seg + 1'b1;
    wire [9:0] bin_k = bins_q[pt_k*10 +: 10];
    wire signed [7:0] tpl_k = tpl(q_idx, pt_k);
    // teacher shape at the target tone's level: the rounded mean of each
    // built-in template (64, 32, -32, 0 for tones 1..4, docs/14 section 2)
    wire signed [7:0] tch_k = tch_q[pt_k*8 +: 8];
    wire signed [8:0] tch_lvl = (q_idx == 2'd0) ? 9'sd64 : (q_idx == 2'd1) ? 9'sd32 :
                                (q_idx == 2'd2) ? -9'sd32 : 9'sd0;
    // the INTRO-time template draw always uses the template; the teacher
    // redraw is issued on the DEMO -> GUARD edge (phase already GUARD)
    wire draw_tch = use_tch && (phase != PH_INTRO);
    reg signed [11:0] y_off;
    always @* begin
        if (job == 2'd2)
            y_off = draw_tch ? ({{4{tch_k[7]}}, tch_k} + {{3{tch_lvl[8]}}, tch_lvl})
                             : {{4{tpl_k[7]}}, tpl_k};
        else if (job == 2'd3)
            y_off = $signed({2'b00, bin_k}) - $signed({2'b00, center_draw});
        else
            y_off = $signed({2'b00, lp_head[9:0]}) - $signed({2'b00, center_draw});
    end
    wire [7:0] y_calc = clamp_y(y_off);

    // ------------------------------------------------------ balloon / train state
    reg [9:0] held;
    reg [3:0] unv;
    reg [9:0] last_pitch;
    reg [7:0] effect_timer;
    reg arrived;
    // one pixel of radius every grow_div voiced frames: 96 px from min to pop
    // takes 1.6 / 3.2 / 4.8 / 8.0 s for difficulty 0..3
    wire [2:0] grow_div = (eff_diff_r == 2'd0) ? 3'd1 : (eff_diff_r == 2'd1) ? 3'd2 :
                          (eff_diff_r == 2'd2) ? 3'd3 : 3'd5;
    reg [2:0] grow_cnt;
    wire [7:0] half_win = (eff_diff_r == 2'd0) ? 8'd28 : (eff_diff_r == 2'd1) ? 8'd20 :
                          (eff_diff_r == 2'd2) ? 8'd14 : 8'd10;
    wire [7:0] lvl_lo = TRAIN_CENTER - half_win;
    wire [7:0] lvl_hi = TRAIN_CENTER + half_win;
    function [7:0] meter_map;                // level 100..227 -> 0..255
        input [7:0] lv;
        begin
            meter_map = (lv <= 8'd100) ? 8'd0 : (lv >= 8'd227) ? 8'd255 : {lv - 8'd100, 1'b0};
        end
    endfunction
    assign win_lo = meter_map(lvl_lo);
    assign win_hi = meter_map(lvl_hi);
    // held voicing time as BCD: 6 frames = 0.1 s
    reg [2:0] ht_sub;
    reg [3:0] ht_tenth, ht_ones, ht_tens;
    wire [47:0] held_cells = {12'd0, PH_C_SEC, digit_id(ht_tenth), PH_C_DOT,
                              digit_id(ht_ones),
                              (ht_tens == 4'd0) ? PH_BLANK : digit_id(ht_tens), PH_BLANK};

    wire [1:0] next_q = retry_demo ? q_idx : q_idx + 1'b1;

    // desired background bank per mode
    wire [1:0] desired_bg = (mode == M_TONE) ? 2'd1 : (mode == M_CARD) ? 2'd3 : 2'd2;

    task cancel_attempt;
        begin
            sc_cancel <= 1'b1; sc_arm <= 1'b0;
            demo_cancel <= 1'b1;
            tch_wait <= 1'b0; tch_got <= 1'b0; tch_ack <= 1'b0; use_tch <= 1'b0;
            syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd0;
            heard <= 1'b0; ball_age <= 7'd127;
            meter_level <= 8'd0; meter_ok <= 1'b0;
            lp_wr <= 2'd0; lp_rd <= 2'd0; lp_count <= 3'd0;
            job <= 2'd0; primed <= 1'b0;
            pend_clear <= 1'b1; pend_bins <= 1'b0; pend_target <= 1'b0;
        end
    endtask

    // Enter the same completed-round view from feedback or link recovery.
    // Recovery must not reopen LISTEN for an already completed tenth question.
    task enter_summary;
        begin
            phase <= PH_SUMMARY; timer <= 10'd0;
            s0_id <= PH_D_SUMMARY; s3_id <= PH_F_GREAT;
            s3_class <= CL_GOOD;
            s1_id <= PH_BLANK;
            s2_cells <= 48'd0;
            sum_scan <= 2'd1;
            celebrate <= 1'b1;
        end
    endtask

    // F1: leave the summary and restart the round. Both exit paths call
    // this -- the KEY2 path from the standalone block (any cycle) and the
    // 600-frame timeout from the PH_SUMMARY branch -- so their field lists
    // cannot drift apart. Everything the summary screen changed gets
    // restored: the strip cells, the title, the question word, the reveal.
    task summary_exit;
        begin
            cancel_attempt;
            sess_q <= 8'd0; sess_star <= 8'd0;
            question_completed <= 1'b0;
            sess_stars <= 4'd0;              // audit P2-2: streak too
            celebrate <= 1'b0; sum_scan <= 2'd0;
            q_idx <= 2'd0;
            phase <= PH_INTRO; timer <= 10'd0;
            s0_id <= (mode == M_CARD) ? PH_MODE_CARD : PH_MODE_TONE;
            s1_id <= (mode == M_CARD) ? PH_P_MAO : PH_P_MA1;
            s2_cells <= 48'd0;               // strip must not leak onward
            s3_id <= PH_S_LISTEN_DEMO; s3_class <= CL_INFO;
            target_reveal <= 10'd0; pend_clear <= 1'b1;
            pend_target <= (mode == M_TONE);
            adapt_lv <= 3'd4;
            retry_demo <= 1'b0; retry_listen <= 1'b0; retry_count <= 2'd0;
        end
    endtask

    task start_question;
        begin
            cancel_attempt;
            phase <= PH_INTRO;
            timer <= 10'd0;
            s1_id <= (mode == M_CARD) ? PH_P_MAO + {4'd0, q_idx} : PH_P_MA1 + {4'd0, q_idx};
            s2_cells <= 48'd0;
            s3_id <= PH_S_LISTEN_DEMO;
            s3_class <= CL_INFO;
            target_reveal <= 10'd0;
            pend_clear <= 1'b1;
            pend_target <= (mode == M_TONE);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_q <= 3'd7; link_q <= 1'b0;
            phase <= PH_INTRO; timer <= 10'd0; q_idx <= 2'd0;
            retry_demo <= 1'b0; retry_listen <= 1'b0; center <= CENTER_DEFAULT;
            heard <= 1'b0; celebrate <= 1'b0; sess_stars <= 4'd0; feed_limit <= 9'd150;
            sess_q <= 8'd0; sess_star <= 8'd0;
            question_completed <= 1'b0;
            sum_scan <= 2'd0; sq_t_q <= 4'd0; sq_o_q <= 4'd0;
            ss_t_q <= 4'd0; ss_o_q <= 4'd0;
            adapt_lv <= 3'd4; retry_count <= 2'd0;
            ball_age <= 7'd127; bg_timer <= 10'd0;
            sc_arm <= 1'b0; sc_target <= 3'd1;
            sc_cancel <= 1'b0; demo_request <= 1'b0; demo_cancel <= 1'b0;
            syn_cmd_valid <= 1'b0; syn_cmd_mode <= 3'd0; syn_cmd_tone <= 3'd1;
            goto_valid <= 1'b0; goto_index <= 2'd0;
            target_reveal <= 10'd0; ball_col <= 9'd0; ball_y <= 8'd128;
            balloon_r <= BALLOON_MIN; train_x <= TRAIN_START; meter_level <= 8'd0;
            meter_ok <= 1'b0;
            s0_id <= PH_BLANK; s1_id <= PH_BLANK; s2_cells <= 48'd0;
            s3_id <= PH_BLANK; s3_class <= CL_INFO;
            cmd_valid <= 1'b0; cmd_buf <= 1'b0; cmd_x0 <= 9'd0; cmd_log2n <= 4'd0;
            cmd_y0 <= 8'd0; cmd_y1 <= 8'd0; cmd_vis <= 1'b0;
            lp_wr <= 2'd0; lp_rd <= 2'd0; lp_count <= 3'd0; lp_prev_y <= 8'd128;
            pend_clear <= 1'b0; pend_target <= 1'b0; pend_bins <= 1'b0;
            seg <= 4'd0; job <= 2'd0; bins_q <= 160'd0; center_draw <= CENTER_DEFAULT;
            primed <= 1'b0; dr_prev_y <= 8'd128;
            ht_sub <= 3'd0; ht_tenth <= 4'd0; ht_ones <= 4'd0; ht_tens <= 4'd0;
            lp_push = 1'b0; lp_pop = 1'b0;
            popped <= 1'b0; held <= 10'd0; unv <= 4'd0; last_pitch <= 10'd0;
            effect_timer <= 8'd0; arrived <= 1'b0; grow_cnt <= 3'd0;
            tch_wait <= 1'b0; tch_got <= 1'b0; tch_ack <= 1'b0;
            use_tch <= 1'b0; tch_q <= 128'd0;
        end else begin
            sc_arm <= 1'b0;
            sc_cancel <= 1'b0; demo_request <= 1'b0; demo_cancel <= 1'b0;
            link_q <= link_up;
            syn_cmd_valid <= 1'b0;
            goto_valid <= 1'b0;

            // ---------------------------------------------- live points + drawer
            lp_push = sc_point_valid && sc_enable && (lp_count != 3'd4);
            lp_pop = 1'b0;
            if (lp_push) begin
                lp_fifo[lp_wr] <= {sc_point_index, sc_point_value};
                lp_wr <= lp_wr + 1'b1;
            end
            if (cmd_valid) begin
                if (cmd_ready)
                    cmd_valid <= 1'b0;                 // accepted this cycle
            end else if (job == 2'd1) begin
                cmd_valid <= 1'b1; cmd_buf <= 1'b1; cmd_x0 <= 9'd0; cmd_log2n <= 4'd9;
                cmd_y0 <= 8'd0; cmd_y1 <= 8'd0; cmd_vis <= 1'b0;
                lp_prev_y <= 8'd128;
                job <= 2'd0;
            end else if (job == 2'd2 || job == 2'd3) begin
                if (!primed) begin
                    dr_prev_y <= y_calc;
                    primed <= 1'b1;
                end else begin
                    cmd_valid <= 1'b1; cmd_buf <= (job == 2'd3); cmd_x0 <= {seg, 5'd0};
                    cmd_log2n <= 4'd5; cmd_y0 <= dr_prev_y; cmd_y1 <= y_calc; cmd_vis <= 1'b1;
                    dr_prev_y <= y_calc;
                    seg <= seg + 1'b1;
                    if (seg == 4'd15) begin
                        job <= 2'd0;
                        primed <= 1'b0;
                    end
                end
            end else if (pend_clear) begin
                pend_clear <= 1'b0; job <= 2'd1;
            end else if (pend_target) begin
                pend_target <= 1'b0; job <= 2'd2; seg <= 4'd0; primed <= 1'b0;
            end else if (pend_bins) begin
                pend_bins <= 1'b0; job <= 2'd3; seg <= 4'd0; primed <= 1'b0;
            end else if (lp_count != 3'd0) begin
                lp_pop = 1'b1;
                lp_rd <= lp_rd + 1'b1;
                lp_prev_y <= y_calc;
                if (lp_head[16:10] < 7'd96) begin
                    cmd_valid <= 1'b1; cmd_buf <= 1'b1;
                    cmd_x0 <= live_x; cmd_log2n <= 4'd3;
                    cmd_y0 <= (lp_head[16:10] == 7'd0) ? y_calc : lp_prev_y;
                    cmd_y1 <= y_calc;
                    cmd_vis <= 1'b1;
                    ball_col <= live_x + 9'd7;
                    ball_y <= y_calc;
                    ball_age <= 7'd0;
                end
            end
            if (lp_push && !lp_pop)
                lp_count <= lp_count + 1'b1;
            else if (lp_pop && !lp_push)
                lp_count <= lp_count - 1'b1;

            // ---------------------------------------------- mode entry
            if (mode != mode_q) begin
                cancel_attempt;
                mode_q <= mode;
                syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd0;
                q_idx <= 2'd0; sess_stars <= 4'd0; celebrate <= 1'b0;
                adapt_lv <= 3'd4; retry_count <= 2'd0;
                sess_q <= 8'd0; sess_star <= 8'd0; sum_scan <= 2'd0;
                question_completed <= 1'b0;
                phase <= PH_INTRO; timer <= 10'd0;
                retry_demo <= 1'b0; retry_listen <= 1'b0;
                popped <= 1'b0; held <= 10'd0; unv <= 4'd0; balloon_r <= BALLOON_MIN;
                ht_sub <= 3'd0; ht_tenth <= 4'd0; ht_ones <= 4'd0; ht_tens <= 4'd0;
                train_x <= TRAIN_START; arrived <= 1'b0; effect_timer <= 8'd0;
                s1_id <= PH_BLANK; s2_cells <= 48'd0; s3_id <= PH_BLANK; s3_class <= CL_INFO;
                bg_timer <= 10'd0;
                if (mode != M_DISPLAY) begin
                    goto_valid <= (active_index != desired_bg);
                    goto_index <= desired_bg;
                end
                case (mode)
                    M_TONE: s0_id <= PH_MODE_TONE;
                    M_BALLOON: begin s0_id <= PH_MODE_BALLOON; s3_id <= PH_I_BALLOON; end
                    M_TRAIN: begin s0_id <= PH_MODE_TRAIN; s3_id <= PH_I_TRAIN; end
                    M_CARD: s0_id <= PH_MODE_CARD;
                    M_DISCOVER: begin s0_id <= PH_MODE_DISCOVER; s3_id <= PH_D_HINT;
                                      disc_radius <= 8'd40; disc_hue <= 3'd2; end
                    default: s0_id <= PH_BLANK;
                endcase
                if (mode == M_TONE || mode == M_CARD) begin
                    sc_target <= 3'd1;
                    phase <= PH_INTRO; timer <= 10'd0;
                    s1_id <= (mode == M_CARD) ? PH_P_MAO : PH_P_MA1;
                    s3_id <= PH_S_LISTEN_DEMO; s3_class <= CL_INFO;
                    target_reveal <= 10'd0;
                    pend_clear <= 1'b1;
                    pend_target <= (mode == M_TONE);
                end
            end else if (ui_tick) begin
                // Local UI time continues when remote samples disappear.
                if (ball_age != 7'd127) ball_age <= ball_age + 1'b1;
                // keep asking for the scene picture until it is shown
                if (training && active_index != desired_bg) begin
                    bg_timer <= bg_timer + 1'b1;
                    if (bg_timer == 10'd120) begin
                        bg_timer <= 10'd0;
                        goto_valid <= 1'b1;
                        goto_index <= desired_bg;
                    end
                end else begin
                    bg_timer <= 10'd0;
                end
                if (word_mode && link_up && !mic_pause) begin
                    if (timer != 10'd1023) timer <= timer + 1'b1;
                    case (phase)
                    PH_INTRO: if (timer >= 10'd36) begin
                        // teacher demo: wait for the teacher instead of
                        // playing the model voice
                        if (!teacher_on) begin
                            syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd1;
                            syn_cmd_tone <= {1'b0, q_idx} + 3'd1;
                            s3_id <= PH_S_LISTEN_DEMO;
                        end else begin
                            demo_request <= 1'b1;
                            s3_id <= PH_WAIT_TEACHER;
                        end
                        tch_wait <= teacher_on; tch_got <= 1'b0; tch_ack <= 1'b0; use_tch <= 1'b0;
                        sc_target <= {1'b0, q_idx} + 3'd1;
                        phase <= PH_DEMO; timer <= 10'd0;
                    end
                    PH_DEMO: begin
                        if (tch_wait) begin
                            if (tch_got) begin
                                tch_wait <= 1'b0; use_tch <= 1'b1;
                                demo_cancel <= 1'b1;
                                pend_target <= (mode == M_TONE);
                                target_reveal <= 10'd512;
                                s3_id <= PH_S_YOUR_TURN; s3_class <= CL_CUE;
                                phase <= PH_GUARD; timer <= 10'd0;
                            end else if (timer >= TCH_TIMEOUT || !teacher_on) begin
                                // no teacher curve (or the link dropped):
                                // this question falls back to the model voice
                                tch_wait <= 1'b0;
                                tch_ack <= 1'b0; demo_cancel <= 1'b1;
                                s3_id <= PH_S_LISTEN_DEMO;
                                syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd1;
                                syn_cmd_tone <= {1'b0, q_idx} + 3'd1;
                                timer <= 10'd0;
                            end
                        end else begin
                            if (syn_playing && timer > 10'd1)
                                target_reveal <= {1'b0, syn_progress, 1'b0} + 10'd2;
                            if (!syn_playing && timer > 10'd2) begin
                                target_reveal <= 10'd512;
                                s3_id <= PH_S_YOUR_TURN; s3_class <= CL_CUE;
                                phase <= PH_GUARD; timer <= 10'd0;
                            end
                        end
                    end
                    PH_GUARD: if (timer >= 10'd12) begin
                        sc_arm <= 1'b1;
                        center_draw <= center;
                        pend_clear <= 1'b1;
                        heard <= 1'b0;
                        meter_level <= 8'd0; meter_ok <= 1'b0;
                        phase <= PH_LISTEN; timer <= 10'd0;
                    end
                    PH_LISTEN: begin
                        // audit P1 fix (round-10 was half-done): when the
                        // child has spoken, extend the window by 26 frames
                        // (+0.43 s) so the scorer's END_FRAMES=24 tail can
                        // produce sc_valid before start_question discards it.
                        // The old code dropped results landing within ~400 ms
                        // of the window end and bypassed the 3-retry cap.
                        if (timer >= listen_limit + (heard ? 10'd26 : 10'd0) && !sc_active) begin
                            if (heard) begin
                                start_question;   // spoke, but nothing scoreable
                            end else begin
                                // nothing picked up at all: tell the child
                                // louder, then re-listen without the demo
                                retry_listen <= 1'b1;
                                // Silence does not consume or reset valid retries.
                                sc_cancel <= 1'b1;
                                s3_id <= PH_H_LOUDER; s3_class <= CL_HINT;
                                s2_cells <= 48'd0;
                                phase <= PH_FEED; timer <= 10'd0;
                                feed_limit <= 9'd120;   // audit 2e: no longer inherits the previous score's 210-frame window
                            end
                        end
                    end
                    PH_FEED: if (timer >= feed_limit &&
                                 ((!key_next && !key_replay) || sess_q >= 8'd10)) begin
                        if (sess_q >= 8'd10) begin
                            // A question completes on success or exhausted retries.
                            // In-question retries never consume another round slot.
                            enter_summary;
                        end else if (retry_listen) begin
                            s3_id <= PH_S_YOUR_TURN; s3_class <= CL_CUE;
                            s2_cells <= 48'd0;
                            celebrate <= 1'b0;
                            phase <= PH_GUARD; timer <= 10'd0;
                        end else begin
                            cancel_attempt;
                            q_idx <= next_q;
                            if (!retry_demo) begin
                                retry_count <= 2'd0;
                                question_completed <= 1'b0;
                            end
                            s1_id <= (mode == M_CARD) ? PH_P_MAO + {4'd0, next_q}
                                                      : PH_P_MA1 + {4'd0, next_q};
                            phase <= PH_INTRO; timer <= 10'd0;
                            pend_clear <= 1'b1;
                            target_reveal <= 10'd0;
                            s2_cells <= 48'd0;
                            s3_id <= PH_S_LISTEN_DEMO; s3_class <= CL_INFO;
                            pend_target <= (mode == M_TONE);
                            celebrate <= 1'b0;
                        end
                    end
                    PH_SUMMARY: begin
                        // two-frame digit scan (see the ladder mux above)
                        if (timer == 10'd0) begin
                            sq_t_q <= sc_tens; sq_o_q <= sc_ones;
                            sum_scan <= 2'd2;
                        end else if (timer == 10'd1) begin
                            ss_t_q <= sc_tens; ss_o_q <= sc_ones;
                            sum_scan <= 2'd0;
                        end else if (timer == 10'd2) begin
                            // one frame after the star latch: the digits
                            // must already be registered when the strip
                            // assembles (a same-edge read would see zeros)
                            s2_cells <= {PH_BLANK, PH_C_STAR,
                                         digit_id(ss_o_q), digit_id(ss_t_q),
                                         PH_BLANK, PH_C_QUESTIONS,
                                         digit_id(sq_o_q), digit_id(sq_t_q)};
                        end
                        if (timer >= 10'd600)
                            summary_exit;   // timeout: the key path lives
                    end                     // in the standalone block below
                    default: phase <= PH_INTRO;
                    endcase
                end
                if (mode == M_BALLOON && link_up && popped) begin
                        effect_timer <= effect_timer + 1'b1;
                        if (effect_timer >= 8'd90) begin
                            popped <= 1'b0; balloon_r <= BALLOON_MIN; held <= 10'd0;
                            ht_sub <= 3'd0; ht_tenth <= 4'd0; ht_ones <= 4'd0; ht_tens <= 4'd0;
                            s3_id <= PH_I_BALLOON; s3_class <= CL_INFO; s2_cells <= 48'd0;
                        end
                end
                if (mode == M_TRAIN && link_up && arrived) begin
                    effect_timer <= effect_timer + 1'b1;
                    if (effect_timer >= 8'd120) begin
                        arrived <= 1'b0; train_x <= TRAIN_START;
                        phase <= PH_INTRO; effect_timer <= 8'd0;
                        meter_level <= 8'd0; meter_ok <= 1'b0;
                        s2_cells <= 48'd0; s3_id <= PH_I_TRAIN; s3_class <= CL_INFO;
                    end
                end
            end

            // Feature-driven changes consume each real packet once, even
            // when its pulse is between video frames. No stale sample replay.
            if (trk_valid && link_up && child_selected && mode == mode_q && !key_next && !key_replay) begin
                if (mode == M_DISCOVER) begin
                    disc_radius <= 8'd20 + {2'd0, trk_level[7:2]};
                    disc_hue <= trk_pitch[9:7];
                end
                if (word_mode && phase == PH_LISTEN) begin
                    if (trk_voiced) heard <= 1'b1;
                    meter_level <= trk_level; meter_ok <= trk_voiced;
                end
                if (mode == M_BALLOON && !popped) begin
                    if (trk_voiced) begin
                        unv <= 4'd0;
                        if (held != 10'd1023) held <= held + 1'b1;
                        s2_cells <= held_cells;
                        if (ht_sub == 3'd5) begin
                            ht_sub <= 3'd0;
                            if (ht_tenth == 4'd9) begin
                                ht_tenth <= 4'd0;
                                if (ht_ones == 4'd9) begin
                                    ht_ones <= 4'd0;
                                    if (ht_tens != 4'd9) ht_tens <= ht_tens + 1'b1;
                                end else begin
                                    ht_ones <= ht_ones + 1'b1;
                                end
                            end else begin
                                ht_tenth <= ht_tenth + 1'b1;
                            end
                        end else begin
                            ht_sub <= ht_sub + 1'b1;
                        end
                        last_pitch <= trk_pitch;
                        if (eff_diff_r < 2'd2 || held == 10'd0 ||
                            (trk_pitch < last_pitch + 10'd24 && last_pitch < trk_pitch + 10'd24)) begin
                            if (grow_cnt + 1'b1 >= grow_div) begin
                                grow_cnt <= 3'd0;
                                if (balloon_r + 8'd1 >= BALLOON_MAX) begin
                                    balloon_r <= BALLOON_MAX;
                                    popped <= 1'b1; effect_timer <= 8'd0;
                                    syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd4;
                                    s3_id <= PH_F_POP; s3_class <= CL_GOOD;
                                end else begin
                                    balloon_r <= balloon_r + 8'd1;
                                end
                            end else begin
                                grow_cnt <= grow_cnt + 1'b1;
                            end
                        end
                    end else begin
                        if (unv != 4'd15) unv <= unv + 1'b1;
                        if (unv >= 4'd8) begin
                            held <= 10'd0;
                            ht_sub <= 3'd0; ht_tenth <= 4'd0; ht_ones <= 4'd0; ht_tens <= 4'd0;
                        end
                        grow_cnt <= 3'd0;
                        balloon_r <= (balloon_r > BALLOON_MIN) ? balloon_r - 8'd1 : BALLOON_MIN;
                    end
                end
                if (mode == M_TRAIN && phase == PH_LISTEN && !arrived) begin
                    meter_level <= trk_voiced ? meter_map(trk_level) : 8'd0;
                    meter_ok <= trk_voiced && trk_level >= lvl_lo && trk_level <= lvl_hi;
                    if (trk_voiced && trk_level >= lvl_lo && trk_level <= lvl_hi) begin
                        s3_id <= PH_F_KEEPUP; s3_class <= CL_GOOD;
                        if (train_x + 10'd2 >= TRAIN_END) begin
                            train_x <= TRAIN_END;
                            arrived <= 1'b1; effect_timer <= 8'd0;
                            phase <= PH_FEED;
                            syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd2;
                            s3_id <= PH_F_ARRIVE;
                            s2_cells <= {12'd0, PH_C_STAR, PH_C_STAR, PH_C_STAR, PH_BLANK, PH_BLANK, PH_BLANK};
                        end else begin
                            train_x <= train_x + 10'd2;
                        end
                    end else if (trk_voiced && trk_level > lvl_hi) begin
                        s3_id <= PH_H_SOFTER; s3_class <= CL_HINT;
                    end else if (trk_voiced) begin
                        s3_id <= PH_H_LOUDER; s3_class <= CL_HINT;
                    end else begin
                        s3_id <= PH_H_LOUDER; s3_class <= CL_HINT;
                    end
                end
            end

            // ---------------------------------------------- scorer result
            if (sc_valid && child_selected && link_up && word_mode && mode == mode_q &&
                phase == PH_LISTEN && !key_next && !key_replay) begin
                phase <= PH_FEED; timer <= 10'd0;
                feed_limit <= 9'd150;
                celebrate <= 1'b0;
                if (sc_short) begin
                    retry_listen <= 1'b1;
                    // Preserve the last valid-result retry identity. The listen
                    // retry branch already suppresses a new demo after short input.
                    s3_id <= PH_H_LONGER; s3_class <= CL_HINT;
                    syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd3;
                end else begin
                    retry_listen <= 1'b0;
                    // R82 max-retry: after 3 retries on the same tone,
                    // advance anyway -- repeating forever frustrates the
                    // child and stalls the session
                    if (retry_demo) begin
                        if (retry_count < 2'd3)
                            retry_count <= retry_count + 1'b1;
                        // else: retry_count stays 3, retry_demo goes 0 below
                    end else begin
                        retry_count <= 2'd0;
                    end
                    // audit P2-1: rc_old < 2 gives exactly 3 retries
                    // (the old <3 let a 4th retry through)
                    retry_demo <= (sc_stars < 2'd2) && (retry_count < 2'd2);
                    feed_limit <= (sc_stars == 2'd3) ? 9'd210 :
                                  (sc_stars == 2'd0) ? 9'd120 : 9'd150;
                    celebrate <= (sc_stars == 2'd3);
                    // the strip shows the count INCLUDING this answer --
                    // reading sess_stars here would lag one question
                    sess_next = ({1'b0, sess_stars} + {3'd0, sc_stars} > 5'd9)
                                 ? 4'd9
                                 : (sess_stars + {1'b0, sc_stars});
                    sess_stars <= sess_next;
                    // Commit only the final valid result for this question.
                    // retry_count==2 is the third retry (fourth total attempt).
                    if (!question_completed && sess_q < 8'd10 &&
                        (sc_stars >= 2'd2 || retry_count >= 2'd2)) begin
                        question_completed <= 1'b1;
                        sess_q <= sess_q + 8'd1;
                        sess_star <= sess_star + {6'd0, sc_stars};
                    end
                    // (F3 badge milestones were here; deferred to docs/19 D8
                    //  with the badge_journal library module -- the B board's
                    //  place gate could not afford the flash journal)
                    // R82 adaptive difficulty: bias adapts to the child's
                    // recent success rate
                    if (sc_stars >= 2'd2 && adapt_lv != 3'd7)
                        adapt_lv <= adapt_lv + 1'b1;
                    else if (sc_stars == 2'd0 && adapt_lv != 3'd0)
                        adapt_lv <= adapt_lv - 1'b1;
                    bins_q <= sc_bins;
                    pend_clear <= 1'b1;
                    pend_bins <= 1'b1;
                    // This attempt only: score + unit + three stars. Session
                    // progress is rendered separately as "本轮 N/10".
                    s2_cells <= {PH_BLANK,
                                 (sc_stars > 2'd2) ? PH_C_STAR : PH_C_STAR_EMPTY,
                                 (sc_stars > 2'd1) ? PH_C_STAR : PH_C_STAR_EMPTY,
                                 (sc_stars > 2'd0) ? PH_C_STAR : PH_C_STAR_EMPTY,
                                 PH_C_POINTS,
                                 digit_id(sc_ones[3:0]),
                                 (sc_score >= 7'd10) ? digit_id(sc_tens) : PH_BLANK,
                                 (sc_score >= 7'd100) ? PH_C_1 : PH_BLANK};
                    case (sc_hint)
                        3'd0: begin s3_id <= PH_F_GREAT; s3_class <= CL_GOOD; end
                        3'd1: begin s3_id <= PH_H_STEADY; s3_class <= CL_HINT; end
                        3'd2: begin s3_id <= PH_H_RISE; s3_class <= CL_HINT; end
                        3'd3: begin s3_id <= PH_H_DIPRISE; s3_class <= CL_HINT; end
                        default: begin s3_id <= PH_H_FALL; s3_class <= CL_HINT; end
                    endcase
                    syn_cmd_valid <= 1'b1;
                    syn_cmd_mode <= (sc_stars >= 2'd2) ? 3'd2 : 3'd3;
                    begin : blk_center
                        reg signed [11:0] dc;
                        reg signed [11:0] nc;
                        dc = $signed({2'b00, sc_mean}) - $signed({2'b00, center});
                        nc = $signed({2'b00, center}) + (dc >>> 2);
                        center <= (nc < 12'sd240) ? 10'd240 : (nc > 12'sd640) ? 10'd640 : nc[9:0];
                    end
                    // audit P2-3: a LISTEN timeout landing on this same edge
                    // calls start_question (reveal<=0, pend_target<=1) -- the
                    // FEED phase must keep the scored mountain visible
                    target_reveal <= 10'd512;
                    pend_target <= 1'b0;
                end
            end

            // ---------------------------------------------- teacher curve
            // a curve that lands while DEMO waits is the one drawn; later
            // curves cannot change the question's mountain
            if (link_up && phase == PH_DEMO && tch_wait && tch_armed)
                tch_ack <= 1'b1;
            if (tch_new && link_up && phase == PH_DEMO && tch_wait &&
                (tch_ack || tch_armed) && !tch_got && mode == mode_q && !key_next && !key_replay) begin
                tch_got <= 1'b1;
                tch_q <= tch_off;
            end

            // ---------------------------------------------- keys
            // audit P2-4: the keys block sits AFTER the phase case, so its
            // q_idx/s1 writes would override the PH_SUMMARY exit (KEY2 left
            // the child at question 2 instead of restarting the round).
            // During the summary the branch above owns the keys.
            // The tenth completed question must reach its summary. Short keys
            // during its feedback cannot skip the screen or create question 11.
            if (word_mode && mode == mode_q && !summary_show && sess_q < 8'd10) begin
                if (key_next) begin
                    cancel_attempt;
                    q_idx <= q_idx + 1'b1;
                    question_completed <= 1'b0;
                    syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd0;
                    phase <= PH_INTRO; timer <= 10'd0;
                    celebrate <= 1'b0; retry_count <= 2'd0; retry_demo <= 1'b0;   // audit P2-2
                    s1_id <= (mode == M_CARD) ? PH_P_MAO + {4'd0, q_idx + 2'd1}
                                              : PH_P_MA1 + {4'd0, q_idx + 2'd1};
                    s2_cells <= 48'd0; s3_id <= PH_S_LISTEN_DEMO; s3_class <= CL_INFO;
                    target_reveal <= 10'd0; pend_clear <= 1'b1; pend_target <= (mode == M_TONE);
                end else if (key_replay) begin
                    syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd0;
                    celebrate <= 1'b0;   // audit P2-2
                    start_question;
                end
            end

            // Non-word exercises have no question bank. The train uses NEXT to
            // start/restart and REPLAY to return to standby; the other exercises
            // retain their reset behavior. Keys follow feature work so a same-edge
            // sample cannot undo the reset; link-loss remains highest priority.
            if (!word_mode && training && mode == mode_q && (key_next || key_replay)) begin
                cancel_attempt;
                syn_cmd_valid <= 1'b1; syn_cmd_mode <= 3'd0;
                celebrate <= 1'b0; effect_timer <= 8'd0;
                popped <= 1'b0; balloon_r <= BALLOON_MIN;
                held <= 10'd0; unv <= 4'd0; grow_cnt <= 3'd0;
                ht_sub <= 3'd0; ht_tenth <= 4'd0; ht_ones <= 4'd0; ht_tens <= 4'd0;
                arrived <= 1'b0; train_x <= TRAIN_START;
                meter_level <= 8'd0; meter_ok <= 1'b0;
                disc_radius <= 8'd40; disc_hue <= 3'd2;
                s2_cells <= 48'd0;
                s3_id <= (mode == M_BALLOON) ? PH_I_BALLOON :
                         (mode == M_TRAIN) ? (train_start_requested ? PH_H_LOUDER : PH_I_TRAIN) : PH_D_HINT;
                s3_class <= (mode == M_TRAIN && train_start_requested) ? CL_HINT : CL_INFO;
                if (mode == M_TRAIN)
                    phase <= train_start_requested ? PH_LISTEN : PH_INTRO;
            end

            // ---------------------------------------------- F1 summary exit
            // audit P2-4: this block owns the KEY2 exit. It must live
            // OUTSIDE the trk_valid gate (the case branch only sees keys on
            // feature frames, so a key landing between frames would be
            // missed) and AFTER the keys block (which is gated off during
            // the summary -- its q_idx+1/s1 writes would otherwise override
            // the round restart, leaving the child at question 2). One task
            // serves both exits so the field list cannot drift.
            if (summary_show && key_next && link_up)
                summary_exit;

            // Shared-mic role transitions cannot finalize an abandoned child
            // answer. Hold local timers until the requested speaker is selected.
            // New teacher selection explicitly restarts a teacher demonstration.
            if(shared_mic && link_up && word_mode && !summary_show && mode==mode_q)begin
                if(mic_pause)begin
                    timer<=0;
                    if(phase==PH_GUARD || phase==PH_LISTEN)begin
                        sc_cancel<=1;phase<=PH_GUARD;heard<=0;meter_level<=0;meter_ok<=0;
                        s3_id<=PH_S_YOUR_TURN;s3_class<=CL_CUE;
                    end else s3_id<=PH_WAIT_TEACHER;
                end
                if(mic_transition)begin
                    sc_cancel<=1;
                    if(phase==PH_LISTEN || phase==PH_GUARD)begin
                        phase<=PH_GUARD;timer<=0;heard<=0;
                    end
                end
                if(mic_teacher && !mic_teacher_q && teacher_on)begin
                    cancel_attempt;start_question;
                    syn_cmd_valid<=1;syn_cmd_mode<=0;
                end
                if(!mic_teacher && mic_teacher_q && phase==PH_DEMO && tch_wait && !tch_got)begin
                    cancel_attempt;start_question;
                end
            end

            // Selecting the teacher or entering the shared-mic protection period
            // cancels a train run. Returning to a ready child requires NEXT again.
            if (mode == M_TRAIN && mode == mode_q && shared_mic && !child_selected) begin
                phase <= PH_INTRO; timer <= 10'd0;
                train_x <= TRAIN_START; arrived <= 1'b0; effect_timer <= 8'd0;
                meter_level <= 8'd0; meter_ok <= 1'b0; s2_cells <= 48'd0;
                s3_id <= PH_I_TRAIN; s3_class <= CL_INFO;
            end

            // Link-loss overrides same-edge samples, results and key work.
            // Counters do not advance and incomplete speech is discarded.
            if (training && !link_up) begin
                if (link_q || mode != mode_q) cancel_attempt;
                phase <= PH_INTRO; timer <= 10'd0;
                s3_id <= PH_WAIT_LINK; s3_class <= CL_INFO;
                s2_cells <= 48'd0; celebrate <= 1'b0;
                meter_level <= 8'd0; meter_ok <= 1'b0;
                target_reveal <= 10'd0; disc_radius <= 8'd20;
                popped <= 1'b0; balloon_r <= BALLOON_MIN;
                arrived <= 1'b0; train_x <= TRAIN_START;
                held <= 10'd0; unv <= 4'd0; grow_cnt <= 3'd0;
                ht_sub <= 3'd0; ht_tenth <= 4'd0; ht_ones <= 4'd0; ht_tens <= 4'd0;
            end else if (training && link_up && !link_q && mode == mode_q) begin
                if (word_mode) begin
                    if (sess_q >= 8'd10) enter_summary;
                    else start_question;
                end
                else begin
                    s3_id <= (mode == M_BALLOON) ? PH_I_BALLOON :
                             (mode == M_TRAIN) ? PH_I_TRAIN : PH_D_HINT;
                    s3_class <= CL_INFO;
                    if (mode == M_TRAIN) phase <= PH_INTRO;
                end
            end

        end
    end
endmodule
