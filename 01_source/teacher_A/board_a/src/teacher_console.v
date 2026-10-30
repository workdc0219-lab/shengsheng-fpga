`timescale 1ns/1ps
// Board A teacher console, 640x480@60 on the second monitor (docs/14 s4).
// Everything is drawn from registers and two small block RAMs -- no SDRAM,
// no TF card:
//
//   y   0.. 39  top bar     title | mode | target tone | cue chip | link
//   y  46..285  live panel  ~10 s scrolling pitch, child orange / teacher blue
//   y 292..427  left panel  this question: teacher (or standard) vs child shape
//               right panel progress: last 32 scores as bars + average line
//   y 434..479  bottom bar  score + stars | attempts / scored | mean / storage
//
// Pixel pipeline: P0 = timing counters, P1 = registered layer lookups (text
// ROM / history RAM addresses, interpolation operands), P2 = RAM data back,
// colour composed combinationally, P3 = registered RGB to the HDMI core.
// Palette and supported pitch domain are generated from spec/ui.json.
// The comparison is a normalized contour view, not a similarity score.
module teacher_console #(parameter integer SINGLE_MIC=0) (
    input wire mic_teacher,mic_ready,teacher_tick,
    input  wire         clk,             // 25 MHz pixel clock
    input  wire         rst_n,
    // live pitch, one sample per child-tracker frame
    input  wire         frame_tick,
    input  wire         child_v,
    input  wire [9:0]   child_p,
    input  wire         teacher_v,
    input  wire [9:0]   teacher_p,
    input  wire         demo_en,
    // Board B status (return link)
    input  wire         b_link_up,
    input  wire [2:0]   b_mode,
    input  wire [2:0]   b_phase,
    input  wire [1:0]   b_q,
    input  wire         b_teacher_on,
    // results
    input  wire         res_new,
    input  wire [2:0]   res_target,
    input  wire [1:0]   res_stars,
    input  wire         res_short,
    input  wire [6:0]   res_score,
    input  wire         res_tch_used,
    input  wire [127:0] res_shape,       // child 16 x s8
    input  wire [127:0] tch_shape,       // latest teacher curve 16 x s8
    // power-on history load from the training journal (docs/14 s5): one
    // beat per record, oldest first; the session counters (n_all / n_sc /
    // sum) are NOT loaded, "本次" stays this session
    input  wire         hist_load,
    input  wire         hist_short,
    input  wire [6:0]   hist_score,
    input  wire [1:0]   hist_stars,
    // audit fix: HIGH while the journal is still replaying history -- a
    // result arriving in that ~4 us boot window is parked here and applied
    // AFTER the replay, so the progress bars keep chronological order
    input  wire         replay_busy,
    // AXI-stream video to the HDMI core
    output reg          axis_user,
    output reg          axis_valid,
    output reg          axis_last,
    output reg  [23:0]  axis_data,
    input  wire         journal_error,
    input  wire [1:0]   journal_error_kind, // 0=none, 1=read, 2=save/queue, 3=sequence conflict
    input  wire         demo_armed
);
`include "console_phrases.vh"
`include "ui_config.vh"

    // ================================================================ timing (P0)
    wire        vt_hs, vt_vs, vt_de;
    wire [11:0] vx, vy;
    video_timing_ctrl u_vtc (
        .pclk(clk), .rst_n(rst_n), .hsync(vt_hs), .vsync(vt_vs), .de(vt_de),
        .x(vx), .y(vy)
    );
    // P4 (docs/16): one register stage between the VTC counters and the
    // wide geometry cone. The counter bits toggle every pixel, and a
    // counter bit with a high fanout (x[0], 39 loads) is promoted onto a
    // global clock net; a FF-to-FF copy is not. frame_end intentionally
    // reads the RAW counters: without that second fanout TD merges the
    // delay register back into the counter and the promotion returns.
    reg [11:0] vx_q, vy_q;
    reg        de_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vx_q <= 12'd0; vy_q <= 12'd0; de_q <= 1'b0;
        end else begin
            vx_q <= vx; vy_q <= vy; de_q <= vt_de;
        end
    end
    wire [9:0] x0 = vx_q[9:0];
    wire [8:0] y0 = vy_q[8:0];
    wire frame_end = (vy == 12'd480) && (vx == 12'd0);   // once per frame

    reg [5:0] blink;                          // frame counter for the cue pulse
    always @(posedge clk or negedge rst_n)
        if (!rst_n) blink <= 6'd0;
        else if (frame_end) blink <= blink + 1'b1;

    // ================================================================ live history RAM
    // 608 columns x {child_v, child_y[7:0], teacher_v, teacher_y[7:0]}
    localparam integer HCOLS = 608;
    reg [8:0] child_hist [0:1023];
    reg [8:0] teacher_hist [0:1023];
    reg [9:0] teacher_wp,teacher_wp_disp;
    integer hi;
    initial for(hi=0;hi<1024;hi=hi+1)begin child_hist[hi]=0;teacher_hist[hi]=0;end
    reg [9:0]  wp, wp_disp;
    reg        t_v_l;
    reg [9:0]  t_p_l;
    function [7:0] p2y;                       // pitch_q4 -> row 0..199 (0 = top)
        input [9:0] p;
        reg [9:0] d;
        reg [15:0] scaled;
        begin
            d = (p <= UI_TEACHER_PITCH_Q4_MIN) ? 10'd0 : p - UI_TEACHER_PITCH_Q4_MIN;
            // 43/128 approximates 199/(640-48), within one pixel. Shift-add
            // avoids consuming a DSP block in the audio-heavy A design.
            scaled = ({6'd0,d} << 5) + ({6'd0,d} << 3) + ({6'd0,d} << 1) + {6'd0,d};
            p2y = (p >= UI_TEACHER_PITCH_Q4_MAX) ? 8'd0 : 8'd199 - scaled[14:7];
        end
    endfunction
    // Q2 single-mic display only: reject isolated 1-2 frame voiced blips.
    // Preserve pitch values and capture/scoring paths; do not flatten tones.
    reg [1:0] child_voice_run, teacher_voice_run;
    reg mic_teacher_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            child_voice_run<=0; teacher_voice_run<=0; mic_teacher_q<=0;
        end else begin
            mic_teacher_q<=mic_teacher;
            if (!mic_ready || mic_teacher!=mic_teacher_q) begin
                child_voice_run<=0; teacher_voice_run<=0;
            end else begin
                if(frame_tick) begin
                    if(!child_v || mic_teacher) child_voice_run<=0;
                    else if(child_voice_run!=2) child_voice_run<=child_voice_run+1'b1;
                end
                if(teacher_tick) begin
                    if(!teacher_v || !mic_teacher) teacher_voice_run<=0;
                    else if(teacher_voice_run!=2) teacher_voice_run<=teacher_voice_run+1'b1;
                end
            end
        end
    end
    wire child_live_v = SINGLE_MIC==0 ? child_v :
        child_v && mic_ready && !mic_teacher && mic_teacher==mic_teacher_q && child_voice_run==2;
    wire teacher_live_v = teacher_v && mic_ready && mic_teacher &&
        mic_teacher==mic_teacher_q && teacher_voice_run==2;
    always @(posedge clk) begin
        if (frame_tick) child_hist[wp] <= {child_live_v,p2y(child_p)};
        if(SINGLE_MIC!=0)begin
            if(teacher_tick)teacher_hist[teacher_wp]<={teacher_live_v,p2y(teacher_p)};
        end else if(frame_tick)teacher_hist[wp]<={t_v_l,p2y(t_p_l)};
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 10'd0; wp_disp <= 10'd0; teacher_wp<=0;teacher_wp_disp<=0; t_v_l <= 1'b0; t_p_l <= 10'd0;
        end else begin
            t_v_l <= teacher_v; t_p_l <= teacher_p;
            if (frame_tick) wp <= (wp == HCOLS - 1) ? 10'd0 : wp + 1'b1;
            if(teacher_tick)teacher_wp <= (teacher_wp==HCOLS-1)?0:teacher_wp+1'b1;
            if(frame_end)teacher_wp_disp<=teacher_wp;
            if (frame_end) wp_disp <= wp;     // no mid-frame scroll tearing
        end
    end
    // column c of the plot (x = 16 + c) shows entry (wp_disp + c) mod 608:
    // oldest at the left, newest at the right edge
    wire [9:0]  hc   = x0 - 10'd16;
    wire [10:0] hsum = {1'b0, wp_disp} + {1'b0, hc};
    wire [9:0]  hra  = (hsum >= HCOLS) ? hsum - HCOLS : hsum[9:0];
    reg  [17:0] hq;                           // valid in P1 for the P0 pixel
    wire [10:0] thsum={1'b0,teacher_wp_disp}+{1'b0,hc};
    wire [9:0] thra=(thsum>=HCOLS)?thsum-HCOLS:thsum[9:0];
    always @(posedge clk) hq <= {child_hist[hra],teacher_hist[(SINGLE_MIC!=0)?thra:hra]};

    // ================================================================ results
    reg [127:0] cmp_child, cmp_ref;
    reg         cmp_valid, cmp_is_tch, last_short;
    reg [6:0]   last_score;
    reg [1:0]   last_stars;
    reg [6:0]   bar_score [0:31];
    reg [1:0]   bar_stars [0:31];
    reg         bar_short [0:31];
    reg [4:0]   bar_wr;
    reg [5:0]   bar_cnt;                      // saturates at 32
    // audit F4: trend arrow — last 10 scored results, newest first
    reg [6:0]   trend_buf [0:9];
    reg [3:0]   trend_cnt;                    // saturates at 10
    reg [9:0]   n_all;                        // attempts, session statistics freeze at 1023
    reg [3:0]   na_k, na_h, na_t, na_o;       // BCD of n_all (0..1023)
    reg [9:0]   n_sc;                         // scored (not too short)
    reg [3:0]   ns_k, ns_h, ns_t, ns_o;       // BCD of n_sc (0..1023)
    reg [16:0]  sum_sc;
    reg [6:0]   avg;
    // template shapes, mean removed (game tpl() minus its rounded mean)
    function [127:0] tpl_shape;
        input [2:0] tone;
        begin
            case (tone)
                3'd2: tpl_shape = {8'd33, 8'd31, 8'd30, 8'd27, 8'd22, 8'd17, 8'd11, 8'd4,
                                   -8'sd2, -8'sd9, -8'sd15, -8'sd21, -8'sd26, -8'sd29, -8'sd31, -8'sd31};
                3'd3: tpl_shape = {8'd13, 8'd8, 8'd3, -8'sd2, -8'sd6, -8'sd10, -8'sd14, -8'sd16,
                                   -8'sd15, -8'sd12, -8'sd8, -8'sd3, 8'd4, 8'd11, 8'd23, 8'd32};
                3'd4: tpl_shape = {-8'sd62, -8'sd60, -8'sd56, -8'sd49, -8'sd41, -8'sd32, -8'sd20, -8'sd8,
                                   8'd5, 8'd18, 8'd31, 8'd42, 8'd52, 8'd60, 8'd64, 8'd66};
                default: tpl_shape = 128'd0;
            endcase
        end
    endfunction

    // serial divider for the average: avg = sum_sc / n_sc (17 steps)
    reg        dv_run;
    reg [4:0]  dv_it;
    reg [16:0] dv_num, dv_quo;
    reg [10:0] dv_rem;
    wire [10:0] dv_t  = {dv_rem[9:0], dv_num[16]};
    wire        dv_ge = (dv_t >= {1'b0, n_sc});

    integer bi;
    // audit fix: 1-deep park for a result that lands while the journal is
    // still replaying (replay_busy) -- applied after the replay so the
    // progress bars stay chronological
    reg        pend_v;
    reg [6:0]  pend_score;
    reg [1:0]  pend_stars;
    reg        pend_short;
    reg [127:0] pend_shape;
    reg [127:0] pend_ref;
    reg        pend_tch;
    reg [2:0]  pend_target;
    // Oldest pending result wins. A simultaneous new result replaces the
    // consumed pending slot, and is applied exactly once on the next cycle.
    wire        eff_live  = res_new && !replay_busy && !pend_v;
    wire        eff_pend  = pend_v && !replay_busy;
    wire        eff_new   = eff_live || eff_pend;
    wire        eff_short = eff_live ? res_short   : pend_short;
    wire [6:0]  eff_score = eff_live ? res_score   : pend_score;
    wire [1:0]  eff_stars = eff_live ? res_stars   : pend_stars;
    wire [127:0] eff_shape = eff_live ? res_shape  : pend_shape;
    wire        eff_tch   = eff_live ? res_tch_used : pend_tch;
    wire [2:0]  eff_target = eff_live ? res_target : pend_target;
    wire [127:0] eff_ref = eff_live ? (res_tch_used ? tch_shape : tpl_shape(res_target)) : pend_ref;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmp_child <= 128'd0; cmp_ref <= 128'd0; cmp_valid <= 1'b0;
            cmp_is_tch <= 1'b0; last_short <= 1'b0; last_score <= 7'd0; last_stars <= 2'd0;
            bar_wr <= 5'd0; bar_cnt <= 6'd0; n_all <= 10'd0;
            na_k <= 4'd0; na_h <= 4'd0; na_t <= 4'd0; na_o <= 4'd0;
            n_sc <= 10'd0; sum_sc <= 17'd0; avg <= 7'd0;
            ns_k <= 4'd0; ns_h <= 4'd0; ns_t <= 4'd0; ns_o <= 4'd0;
            dv_run <= 1'b0; dv_it <= 5'd0; dv_num <= 17'd0; dv_quo <= 17'd0; dv_rem <= 11'd0;
            pend_v <= 1'b0; pend_score <= 7'd0; pend_stars <= 2'd0;
            pend_short <= 1'b0; pend_shape <= 128'd0; pend_tch <= 1'b0;
            pend_target <= 3'd0;
            pend_ref <= 128'd0;
            for (bi = 0; bi < 32; bi = bi + 1) begin
                bar_score[bi] <= 7'd0; bar_stars[bi] <= 2'd0; bar_short[bi] <= 1'b0;
            end
            for (bi = 0; bi < 10; bi = bi + 1) begin
                trend_buf[bi] <= 7'd0;      // audit R7-A2-F3: the F4 trend
            end                             // state skipped this block
            trend_cnt <= 4'd0;
        end else begin
            // park whenever the live result cannot be applied THIS cycle:
            // during the replay, or while an earlier parked result is still
            // unapplied (self-review fix: the old condition dropped a result
            // arriving in the one cycle where replay had just ended)
            if (res_new && (replay_busy || pend_v)) begin
                pend_v <= 1'b1; pend_short <= res_short; pend_score <= res_score;
                pend_stars <= res_stars; pend_shape <= res_shape;
                pend_tch <= res_tch_used; pend_target <= res_target;
                pend_ref <= res_tch_used ? tch_shape : tpl_shape(res_target);
            end
            if (eff_new) begin
                cmp_valid <= !eff_short;
                cmp_child <= eff_shape;
                cmp_is_tch <= eff_tch;
                cmp_ref <= eff_ref;
                last_short <= eff_short; last_score <= eff_score; last_stars <= eff_stars;
                bar_score[bar_wr] <= eff_short ? 7'd0 : eff_score;
                bar_stars[bar_wr] <= eff_short ? 2'd0 : eff_stars;
                bar_short[bar_wr] <= eff_short;
                bar_wr <= bar_wr + 1'b1;
                if (bar_cnt != 6'd32) bar_cnt <= bar_cnt + 1'b1;
                // audit F4: shift trend buffer on live scored results
                if (!eff_short) begin
                    trend_buf[9] <= trend_buf[8]; trend_buf[8] <= trend_buf[7];
                    trend_buf[7] <= trend_buf[6]; trend_buf[6] <= trend_buf[5];
                    trend_buf[5] <= trend_buf[4]; trend_buf[4] <= trend_buf[3];
                    trend_buf[3] <= trend_buf[2]; trend_buf[2] <= trend_buf[1];
                    trend_buf[1] <= trend_buf[0]; trend_buf[0] <= eff_score;
                    if (trend_cnt != 4'd10) trend_cnt <= trend_cnt + 1'b1;
                end
                if (n_all != 10'd1023) begin
                    n_all <= n_all + 1'b1;
                    if (na_o == 4'd9) begin
                        na_o <= 4'd0;
                        if (na_t == 4'd9) begin
                            na_t <= 4'd0;
                            if (na_h == 4'd9) begin na_h <= 4'd0; na_k <= na_k + 1'b1; end
                            else na_h <= na_h + 1'b1;
                        end
                        else na_t <= na_t + 1'b1;
                    end else na_o <= na_o + 1'b1;
                end
                // One session window: once attempts reach 1023, attempts,
                // scored count and sum freeze together. Live bars still work.
                if (!eff_short && n_all != 10'd1023 && n_sc != 10'd1023) begin
                    n_sc <= n_sc + 1'b1;
                    if (ns_o == 4'd9) begin
                        ns_o <= 4'd0;
                        if (ns_t == 4'd9) begin
                            ns_t <= 4'd0;
                            if (ns_h == 4'd9) begin ns_h <= 4'd0; ns_k <= ns_k + 1'b1; end
                            else ns_h <= ns_h + 1'b1;
                        end else ns_t <= ns_t + 1'b1;
                    end else ns_o <= ns_o + 1'b1;
                    sum_sc <= sum_sc + eff_score;
                    dv_run <= 1'b1;               // starts next cycle on updated values
                    dv_it <= 5'd0;
                end
                if (eff_pend && !res_new) pend_v <= 1'b0;
            end else if (hist_load) begin
                // journal replay: bars only, session counters untouched
                bar_score[bar_wr] <= hist_short ? 7'd0 : hist_score;
                bar_stars[bar_wr] <= hist_short ? 2'd0 : hist_stars;
                bar_short[bar_wr] <= hist_short;
                bar_wr <= bar_wr + 1'b1;
                if (bar_cnt != 6'd32) bar_cnt <= bar_cnt + 1'b1;
                // audit F4: populate trend buffer from replayed history
                if (!hist_short) begin
                    trend_buf[9] <= trend_buf[8]; trend_buf[8] <= trend_buf[7];
                    trend_buf[7] <= trend_buf[6]; trend_buf[6] <= trend_buf[5];
                    trend_buf[5] <= trend_buf[4]; trend_buf[4] <= trend_buf[3];
                    trend_buf[3] <= trend_buf[2]; trend_buf[2] <= trend_buf[1];
                    trend_buf[1] <= trend_buf[0]; trend_buf[0] <= hist_score;
                    if (trend_cnt != 4'd10) trend_cnt <= trend_cnt + 1'b1;
                end
            end else if (dv_run) begin
                if (dv_it == 5'd0) begin
                    dv_num <= sum_sc; dv_quo <= 17'd0; dv_rem <= 11'd0;
                    dv_it <= 5'd1;
                end else begin
                    dv_rem <= dv_ge ? dv_t - {1'b0, n_sc} : dv_t;
                    dv_quo <= {dv_quo[15:0], dv_ge};
                    dv_num <= {dv_num[15:0], 1'b0};
                    dv_it <= dv_it + 1'b1;
                    if (dv_it == 5'd17) begin
                        avg <= {dv_quo[5:0], dv_ge};
                        dv_run <= 1'b0;
                    end
                end
            end
        end
    end

    function [11:0] bcd3;                     // 0..127 -> {hundreds, tens, ones}
        input [6:0] v;
        reg [6:0] r;
        reg [3:0] h, t;
        begin
            h = (v >= 7'd100) ? 4'd1 : 4'd0;
            r = (v >= 7'd100) ? v - 7'd100 : v;
            t = (r >= 7'd90) ? 4'd9 : (r >= 7'd80) ? 4'd8 : (r >= 7'd70) ? 4'd7 :
                (r >= 7'd60) ? 4'd6 : (r >= 7'd50) ? 4'd5 : (r >= 7'd40) ? 4'd4 :
                (r >= 7'd30) ? 4'd3 : (r >= 7'd20) ? 4'd2 : (r >= 7'd10) ? 4'd1 : 4'd0;
            r = r - {t, 3'b000} - {2'b00, t, 1'b0};
            bcd3 = {h, t, r[3:0]};
        end
    endfunction
    wire [11:0] sc_bcd  = bcd3(last_score);
    wire [3:0]  sc_o    = sc_bcd[3:0];
    wire [11:0] av_bcd  = bcd3(avg);
    wire [3:0]  av_o    = av_bcd[3:0];
    wire        has_res = (n_all != 10'd0);
    wire        history_empty = (bar_cnt == 6'd0) && !replay_busy;
    wire        count_capped = (n_all == 10'd1023);
    wire        storage_error = journal_error || (journal_error_kind != 2'd0);
    wire [5:0]  storage_phrase = (journal_error_kind == 2'd1) ? CP_READ_ERROR :
                                (journal_error_kind == 2'd2) ? CP_WRITE_ERROR : CP_STORAGE_ERROR;

    // ================================================================ text slots (P0 -> P1)
    // Each slot: phrase id, left x, top y, scale (1 = 2x pixels), colour index.
    localparam [3:0] C_TEXT = 4'd0, C_SUB = 4'd1, C_CHILD = 4'd2, C_TCH = 4'd3,
                     C_GOLD = 4'd4, C_GREEN = 4'd5, C_DARK = 4'd6, C_AMBER = 4'd7,
                     C_MUTED = 4'd8, C_BLUE = 4'd9, C_RED = 4'd10;
    function [5:0] digit;
        input [3:0] d;
        digit = CP_D0 + {2'b00, d};
    endfunction

    wire tone_mode = (b_mode == 3'd1) || (b_mode == 3'd4);
    reg [5:0] cue_id;
    reg [3:0] cue_col;
    always @* begin
        cue_id = CP_BLANK; cue_col = C_TEXT;
        if (b_link_up && (b_mode == 3'd1 || b_mode == 3'd4)) begin
            case (b_phase)
                3'd1: begin
                    cue_id = b_teacher_on ? (demo_armed ? CP_CUE_DEMO : CP_CUE_WAIT) : CP_CUE_SYN;
                    cue_col = (b_teacher_on && demo_armed) ? C_DARK : C_SUB;
                end
                3'd2, 3'd3: begin cue_id = CP_CUE_LISTEN; cue_col = C_GREEN; end
                3'd4: begin cue_id = CP_CUE_FEED; cue_col = C_SUB; end
                default: ;
            endcase
        end
    end
    wire cue_chip = b_link_up && tone_mode && (b_phase == 3'd1) && b_teacher_on && demo_armed;

    reg [5:0]  s_id;
    reg [9:0]  s_x;
    reg [8:0]  s_y;
    reg        s_sc;
    reg [3:0]  s_col;
    reg        s_hit;
    always @* begin
        s_hit = 1'b1; s_id = CP_BLANK; s_x = 10'd0; s_y = 9'd0; s_sc = 1'b0; s_col = C_TEXT;
        if (y0 >= 9'd8 && y0 < 9'd32) begin                       // top bar
            s_y = 9'd8;
            if (x0 < 10'd196)      begin s_id = (SINGLE_MIC!=0) ? (mic_teacher ? CP_CUE_DEMO : CP_CUE_LISTEN) : CP_TITLE; s_x = 10'd16;
                s_col = (SINGLE_MIC!=0) ? (!mic_ready ? C_MUTED : mic_teacher ? C_TCH : C_CHILD) : C_TEXT; end
            else if (x0 < 10'd304) begin s_id = b_link_up ? (b_mode == 3'd0 ? CP_M_SHOW :
                                                b_mode == 3'd1 ? CP_M_TONE : b_mode == 3'd2 ? CP_M_BALLOON :
                                                b_mode == 3'd3 ? CP_M_TRAIN : b_mode == 3'd4 ? CP_M_CARD : CP_M_DISCOVERY) : CP_BLANK;
                                         s_x = 10'd198; s_col = C_BLUE; end
            else if (x0 < 10'd384) begin s_id = (b_link_up && tone_mode) ?
                                             ((b_mode == 3'd4) ? CP_CARD_MAO + {4'd0, b_q} :
                                                                  CP_T1 + {4'd0, b_q}) : CP_BLANK;
                                         s_x = 10'd306; s_col = C_TEXT; end
            else if (x0 < 10'd500) begin s_id = cue_id; s_x = 10'd392; s_col = cue_col; end
            else                   begin s_id = b_link_up ? CP_LINK_OK : CP_LINK_NO;
                                         s_x = 10'd514; s_col = b_link_up ? C_TEXT : C_MUTED; end
        end else if (y0 >= 9'd50 && y0 < 9'd74) begin              // live panel header
            s_y = 9'd50;
            if (x0 < 10'd200)      begin s_id = CP_LIVE; s_x = 10'd20; s_col = C_SUB; end
            else if (x0 < 10'd440) begin s_id = CP_CHILD; s_x = 10'd396; s_col = C_CHILD; end
            else if (x0 < 10'd520) begin s_id = CP_TEACHER; s_x = 10'd460; s_col = C_TCH; end
            else                   begin s_id = demo_en ? CP_DEMO_ON : CP_DEMO_OFF; s_x = 10'd528;
                                         s_col = demo_en ? C_AMBER : C_MUTED; end
        end else if (y0 >= 9'd298 && y0 < 9'd322) begin            // panel titles
            s_y = 9'd298;
            if (x0 < 10'd200)      begin s_id = CP_CMP; s_x = 10'd20; s_col = C_SUB; end
            else if (x0 < 10'd260) begin s_id = cmp_valid ? (cmp_is_tch ? CP_TEACHER : CP_TEMPLATE) : CP_BLANK;
                                         s_x = 10'd214; s_col = cmp_is_tch ? C_TCH : C_MUTED; end
            else if (x0 < 10'd320) begin s_id = cmp_valid ? CP_CHILD : CP_BLANK; s_x = 10'd264; s_col = C_CHILD; end
            else                   begin s_id = CP_PROG; s_x = 10'd336; s_col = C_SUB; end
        end else if (y0 >= 9'd432) begin                           // bottom bar
            s_y = 9'd444;
            // The left score stays full size. Discovery suppresses only
            // this score region, never the session counters or storage state.
            if (x0 < 10'd248) begin
                if (b_mode == 3'd5) begin s_id = CP_M_DISCOVERY; s_x = 10'd24; s_col = C_TEXT; end
                else if (x0 < 10'd68) begin s_id = CP_THIS; s_x = 10'd24; s_col = C_SUB; end
                else if (!has_res) begin s_id = CP_NONE; s_x = 10'd72; s_col = C_MUTED; end
                else if (x0 < 10'd144) begin
                    if (last_short) begin s_id = CP_SHORT; s_x = 10'd72; s_col = C_RED; end
                    else begin
                        s_y = 9'd432; s_sc = 1'b1; s_col = C_TEXT;
                        if (x0 < 10'd96) begin s_x = 10'd68; s_id = (sc_bcd[11:8] != 0) ? digit(sc_bcd[11:8]) : CP_BLANK; end
                        else if (x0 < 10'd120) begin s_x = 10'd92; s_id = (last_score >= 7'd10) ? digit(sc_bcd[7:4]) : CP_BLANK; end
                        else begin s_x = 10'd116; s_id = digit(sc_o); end
                    end
                end else if (x0 < 10'd172) begin s_id = !last_short ? CP_FEN : CP_BLANK; s_x = 10'd148; s_col = C_SUB; end
                else begin
                    s_col = C_GOLD;
                    if (x0 < 10'd190) begin s_x = 10'd174; s_id = last_short ? CP_BLANK : (last_stars > 2'd0 ? CP_STAR : CP_STAR_E); end
                    else if (x0 < 10'd208) begin s_x = 10'd192; s_id = last_short ? CP_BLANK : (last_stars > 2'd1 ? CP_STAR : CP_STAR_E); end
                    else if (x0 < 10'd226) begin s_x = 10'd210; s_id = last_short ? CP_BLANK : (last_stars > 2'd2 ? CP_STAR : CP_STAR_E); end
                    else s_hit = 1'b0;
                end
            end else if (x0 < 10'd276) s_hit = 1'b0;
            else if (x0 < 10'd408) begin
                // Two rows, unscaled 20 px text; four 16 px digit slots.
                // Both counters cap together at 1023 attempts; short results
                // increment attempts but never scored count or score sum.
                s_y = (y0 < 9'd456) ? 9'd434 : 9'd456;
                if (x0 < 10'd320) begin
                    s_x = 10'd276; s_id = (y0 < 9'd456) ? CP_DONE : CP_VALID; s_col = C_SUB;
                end else if (x0 < 10'd384) begin
                    s_col = C_TEXT;
                    if (y0 < 9'd456) begin
                        if (x0 < 10'd336) begin s_x = 10'd320; s_id = (na_k != 0) ? digit(na_k) : CP_BLANK; end
                        else if (x0 < 10'd352) begin s_x = 10'd336; s_id = (na_k != 0 || na_h != 0) ? digit(na_h) : CP_BLANK; end
                        else if (x0 < 10'd368) begin s_x = 10'd352; s_id = (na_k != 0 || na_h != 0 || na_t != 0) ? digit(na_t) : CP_BLANK; end
                        else begin s_x = 10'd368; s_id = digit(na_o); end
                    end else begin
                        if (x0 < 10'd336) begin s_x = 10'd320; s_id = (ns_k != 0) ? digit(ns_k) : CP_BLANK; end
                        else if (x0 < 10'd352) begin s_x = 10'd336; s_id = (ns_k != 0 || ns_h != 0) ? digit(ns_h) : CP_BLANK; end
                        else if (x0 < 10'd368) begin s_x = 10'd352; s_id = (ns_k != 0 || ns_h != 0 || ns_t != 0) ? digit(ns_t) : CP_BLANK; end
                        else begin s_x = 10'd368; s_id = digit(ns_o); end
                    end
                end else begin s_x = 10'd386; s_id = CP_TI; s_col = C_SUB; end
            end else if (x0 < 10'd446) s_hit = 1'b0;
            else if (y0 < 9'd456) begin
                s_y = 9'd434;
                if (x0 < 10'd492) begin s_id = CP_AVG; s_x = 10'd446; s_col = C_SUB; end
                else if (x0 < 10'd540) begin
                    s_col = C_TEXT;
                    if (n_sc == 10'd0) begin s_x = 10'd508; s_id = (x0 >= 10'd508 && x0 < 10'd524) ? CP_DASH : CP_BLANK; end
                    else if (x0 < 10'd508) begin s_x = 10'd492; s_id = (av_bcd[11:8] != 0) ? digit(av_bcd[11:8]) : CP_BLANK; end
                    else if (x0 < 10'd524) begin s_x = 10'd508; s_id = (avg >= 7'd10) ? digit(av_bcd[7:4]) : CP_BLANK; end
                    else begin s_x = 10'd524; s_id = digit(av_o); end
                end else if (x0 < 10'd566) begin s_id = CP_FEN; s_x = 10'd542; s_col = C_SUB; end
                else s_hit = 1'b0;
            end else begin
                s_y = 9'd456; s_x = 10'd446;
                if (storage_error) begin s_id = storage_phrase; s_col = C_RED; end
                else if (history_empty) begin s_id = CP_HIST_EMPTY; s_col = C_MUTED; end
                else if (count_capped) begin s_id = CP_COUNT_CAP; s_col = C_AMBER; end
                else s_hit = 1'b0;
            end
        end else
            s_hit = 1'b0;
    end

    wire [28:0] desc   = cphrase(s_id);
    wire [13:0] d_base = desc[28:15];
    wire [5:0]  d_strd = desc[14:9];
    wire [8:0]  d_w    = desc[8:0];
    wire [9:0]  lx_raw = x0 - s_x;
    wire [8:0]  ly_raw = y0 - s_y;
    wire [9:0]  lx     = s_sc ? {1'b0, lx_raw[9:1]} : lx_raw;
    wire [4:0]  ly     = s_sc ? ly_raw[5:1] : ly_raw[4:0];
    // the row test is on the full-width difference: a 5-bit row would wrap
    // and repeat glyph rows above/below a band (seen in the first render)
    wire        t_in   = s_hit && (s_id != CP_BLANK) && (x0 >= s_x) && (y0 >= s_y) &&
                         (lx < {1'b0, d_w}) && (ly_raw < (s_sc ? 2*CP_FONT_ROWS : CP_FONT_ROWS));
    wire [13:0] t_addr = d_base + ly * d_strd + lx[9:2];

    // ================================================================ P1 registers
    reg        p1_de, p1_first, p1_tin;
    reg [9:0]  p1_x;
    reg [8:0]  p1_y;
    reg [1:0]  p1_pair;
    reg [3:0]  p1_col;
    reg [13:0] p1_taddr;
    // comparison panel interpolation operands
    reg signed [7:0] p1_ca, p1_cb, p1_ra, p1_rb;
    reg [3:0]  p1_f;
    reg        p1_cmp_x;
    // progress bars
    reg [6:0]  p1_bscore;
    reg [1:0]  p1_bstars;
    reg        p1_bshort, p1_bvalid, p1_bgap, p1_bx;

    wire [9:0] cx  = x0 - 10'd44;             // cmp plot x 44..283 (15 segments x 16)
    wire [3:0] ck  = cx[7:4];
    wire [3:0] ck1 = (ck == 4'd15) ? 4'd15 : ck + 1'b1;
    wire [9:0] bxr = x0 - 10'd350;            // bars x 350..605, 8 px pitch
    wire [4:0] bi_ = bxr[7:3];
    wire [4:0] bslot = bar_wr + bi_;          // oldest at the left
    wire       bvalid = ({1'b0, bi_} >= (6'd32 - bar_cnt));

    wire [7:0] rom_q;                         // valid in P2 (registered ROM)
    console_text_rom u_rom (.clk(clk), .addr(p1_taddr), .data(rom_q));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_de <= 1'b0; p1_first <= 1'b0; p1_tin <= 1'b0; p1_x <= 10'd0; p1_y <= 9'd0;
            p1_pair <= 2'd0; p1_col <= 4'd0; p1_taddr <= 14'd0;
            p1_ca <= 8'sd0; p1_cb <= 8'sd0; p1_ra <= 8'sd0; p1_rb <= 8'sd0; p1_f <= 4'd0;
            p1_cmp_x <= 1'b0; p1_bscore <= 7'd0; p1_bstars <= 2'd0; p1_bshort <= 1'b0;
            p1_bvalid <= 1'b0; p1_bgap <= 1'b0; p1_bx <= 1'b0;
        end else begin
            p1_de <= de_q; p1_first <= de_q && (vx_q == 12'd0) && (vy_q == 12'd0);
            p1_x <= x0; p1_y <= y0;
            p1_tin <= t_in; p1_pair <= lx[1:0]; p1_col <= s_col; p1_taddr <= t_addr;
            p1_ca <= cmp_child[ck*8 +: 8];  p1_cb <= cmp_child[ck1*8 +: 8];
            p1_ra <= cmp_ref[ck*8 +: 8];    p1_rb <= cmp_ref[ck1*8 +: 8];
            p1_f  <= cx[3:0];
            p1_cmp_x <= (x0 >= 10'd44) && (x0 < 10'd284);
            p1_bscore <= bar_score[bslot]; p1_bstars <= bar_stars[bslot];
            p1_bshort <= bar_short[bslot]; p1_bvalid <= bvalid;
            p1_bgap <= (bxr[2:0] == 3'd7); p1_bx <= (x0 >= 10'd350) && (x0 < 10'd606);
        end
    end

    // ================================================================ P2: compose
    reg        p2_de, p2_first;
    reg [9:0]  p2_x;
    reg [8:0]  p2_y;
    reg        p2_tin;
    reg [1:0]  p2_pair;
    reg [3:0]  p2_col;
    reg [17:0] p2_h, p2_hp;
    reg signed [7:0] p2_ca, p2_cb, p2_ra, p2_rb;
    reg [3:0]  p2_f;
    reg        p2_cmp_x;
    reg [6:0]  p2_bscore;
    reg [1:0]  p2_bstars;
    reg        p2_bshort, p2_bvalid, p2_bgap, p2_bx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2_de <= 1'b0; p2_first <= 1'b0; p2_x <= 10'd0; p2_y <= 9'd0; p2_tin <= 1'b0;
            p2_pair <= 2'd0; p2_col <= 4'd0; p2_h <= 18'd0; p2_hp <= 18'd0;
            p2_ca <= 8'sd0; p2_cb <= 8'sd0; p2_ra <= 8'sd0; p2_rb <= 8'sd0; p2_f <= 4'd0;
            p2_cmp_x <= 1'b0; p2_bscore <= 7'd0; p2_bstars <= 2'd0; p2_bshort <= 1'b0;
            p2_bvalid <= 1'b0; p2_bgap <= 1'b0; p2_bx <= 1'b0;
        end else begin
            p2_de <= p1_de; p2_first <= p1_first; p2_x <= p1_x; p2_y <= p1_y;
            p2_tin <= p1_tin; p2_pair <= p1_pair; p2_col <= p1_col;
            p2_h <= hq; p2_hp <= p2_h;           // hq = column p1_x; p2_h = previous
            p2_ca <= p1_ca; p2_cb <= p1_cb; p2_ra <= p1_ra; p2_rb <= p1_rb; p2_f <= p1_f;
            p2_cmp_x <= p1_cmp_x; p2_bscore <= p1_bscore; p2_bstars <= p1_bstars;
            p2_bshort <= p1_bshort; p2_bvalid <= p1_bvalid; p2_bgap <= p1_bgap; p2_bx <= p1_bx;
        end
    end

    // ---- colour helpers
    function [23:0] palette;
        input [3:0] c;
        begin
            case (c)
                C_TEXT:  palette = UI_TEACHER_INK;
                C_SUB:   palette = 24'h8EA0BC;
                C_CHILD: palette = UI_CHILD_CURVE;
                C_TCH:   palette = UI_REFERENCE_CURVE;
                C_GOLD:  palette = 24'hFBBF24;
                C_GREEN: palette = UI_SUCCESS;
                C_DARK:  palette = 24'h1A1206;
                C_AMBER: palette = UI_WARNING;
                C_MUTED: palette = 24'h64748B;
                C_BLUE:  palette = 24'h93C5FD;
                C_RED:   palette = UI_WARNING;
                default: palette = 24'hFFFFFF;
            endcase
        end
    endfunction
    function [23:0] blend;                    // 4-level AA: 0 bg, 1 25%, 2 50%, 3 fg
        input [23:0] fg;
        input [23:0] bg;
        input [1:0]  lvl;
        integer ch;
        reg [9:0] a;
        begin
            for (ch = 0; ch < 3; ch = ch + 1) begin
                case (lvl)
                    2'd3: a = {2'b00, fg[ch*8 +: 8]} << 2;
                    2'd2: a = ({2'b00, fg[ch*8 +: 8]} + {2'b00, bg[ch*8 +: 8]}) << 1;
                    2'd1: a = {2'b00, fg[ch*8 +: 8]} + {1'b0, bg[ch*8 +: 8], 1'b0} + {2'b00, bg[ch*8 +: 8]};
                    default: a = {2'b00, bg[ch*8 +: 8]} << 2;
                endcase
                blend[ch*8 +: 8] = a[9:2];
            end
        end
    endfunction
    // rounded rectangle (2 px corner cut)
    function inrect;
        input [9:0] x; input [8:0] y;
        input [9:0] xa; input [8:0] ya; input [9:0] xb; input [8:0] yb;
        reg [9:0] dx, ex; reg [8:0] dy, ey;
        begin
            dx = x - xa; ex = xb - x; dy = y - ya; ey = yb - y;
            inrect = (x >= xa) && (x <= xb) && (y >= ya) && (y <= yb) &&
                     !((dx < 2 || ex < 2) && (dy < 2 || ey < 2) && !(dx == 1 && dy == 1) &&
                       !(ex == 1 && dy == 1) && !(dx == 1 && ey == 1) && !(ex == 1 && ey == 1));
        end
    endfunction
    function onedge;                          // 1-px border of the same rectangle
        input [9:0] x; input [8:0] y;
        input [9:0] xa; input [8:0] ya; input [9:0] xb; input [8:0] yb;
        begin
            onedge = (x == xa) || (x == xb) || (y == ya) || (y == yb) ||
                     ((x == xa + 1 || x == xb - 1) && (y == ya + 1 || y == yb - 1));
        end
    endfunction
    // |v - c| <= r on a line drawn between two samples
    function near_span;
        input [7:0] y;                        // pixel row in plot coords
        input [7:0] a;
        input [7:0] b;
        reg [7:0] lo, hi;
        begin
            lo = (a < b) ? a : b; hi = (a < b) ? b : a;
            near_span = (y + 8'd1 >= lo) && (y <= hi + 8'd1);
        end
    endfunction

    // ---- live panel
    wire [7:0] ly_plot = p2_y - 9'd80;        // plot rows 80..279
    wire in_live_plot = (p2_x >= 10'd16) && (p2_x < 10'd624) && (p2_y >= 9'd80) && (p2_y < 9'd280);
    wire first_col = (p2_x == 10'd16);
    wire child_hit = in_live_plot && p2_h[17] &&
                     near_span(ly_plot, p2_h[16:9], (p2_hp[17] && !first_col) ? p2_hp[16:9] : p2_h[16:9]);
    wire tch_hit   = in_live_plot && p2_h[8] &&
                     near_span(ly_plot, p2_h[7:0], (p2_hp[8] && !first_col) ? p2_hp[7:0] : p2_h[7:0]);
    wire live_grid = in_live_plot && (((ly_plot[4:0] == 5'd7) && (p2_y != 9'd80)) ||
                     (p2_x == 10'd63) || (p2_x == 10'd183) || (p2_x == 10'd303) ||
                     (p2_x == 10'd423) || (p2_x == 10'd543));

    // ---- comparison panel: y = 375 - v/2, v interpolated over 16-px segments
    function signed [11:0] interp;
        input signed [7:0] a;
        input signed [7:0] b;
        input [3:0] f;
        reg signed [12:0] d, acc;
        begin
            d = b - a;
            acc = ({{5{a[7]}}, a} <<< 4) + (f[0] ? d : 13'sd0) + (f[1] ? d <<< 1 : 13'sd0) +
                  (f[2] ? d <<< 2 : 13'sd0) + (f[3] ? d <<< 3 : 13'sd0);
            interp = acc >>> 4;
        end
    endfunction
    wire signed [11:0] iv_c = interp(p2_ca, p2_cb, p2_f);
    wire signed [11:0] iv_r = interp(p2_ra, p2_rb, p2_f);
    wire signed [11:0] yc_c = 12'sd375 - (iv_c >>> 1);
    wire signed [11:0] yc_r = 12'sd375 - (iv_r >>> 1);
    wire signed [11:0] py   = {3'b000, p2_y};
    wire in_cmp_plot = p2_cmp_x && (p2_y >= 9'd328) && (p2_y <= 9'd422);
    wire cmp_c_hit = cmp_valid && in_cmp_plot && (py - yc_c <= 12'sd1) && (yc_c - py <= 12'sd1);
    wire cmp_r_hit = cmp_valid && in_cmp_plot && (py - yc_r <= 12'sd1) && (yc_r - py <= 12'sd1) &&
                     (cmp_is_tch || p2_x[2]);           // the standard template is dashed
    wire cmp_axis  = in_cmp_plot && (p2_y == 9'd375) && p2_x[1];

    // ---- progress panel: bars x 350..605, base y 424, h = score - score/16
    wire [6:0] bh = p2_bscore - {4'd0, p2_bscore[6:4]};
    wire in_bar = p2_bx && p2_bvalid && !p2_bgap && (p2_y <= 9'd424) &&
                  (p2_bshort ? (p2_y >= 9'd421) : (p2_y >= 9'd424 - {2'b00, bh}) && (p2_bscore != 7'd0));
    wire [6:0] ah = avg - {4'd0, avg[6:4]};
    wire avg_line = (n_sc != 10'd0) && p2_bx && (p2_y == 9'd424 - {2'b00, ah}) && p2_x[2];
    wire prog_base = p2_bx && (p2_y == 9'd425);
    // ---- audit F4: progress trend indicator ----
    // Compares sum(newest 5 scores) vs sum(previous 5 scores) from the
    // 10-deep trend buffer. Threshold ±15 on the 5-score sum ≈ ±3 per-score
    // average shift, enough to filter single-question noise.
    wire [9:0] trend_recent_sum = {3'd0, trend_buf[0]} + {3'd0, trend_buf[1]} +
                                   {3'd0, trend_buf[2]} + {3'd0, trend_buf[3]} +
                                   {3'd0, trend_buf[4]};
    wire [9:0] trend_older_sum = {3'd0, trend_buf[5]} + {3'd0, trend_buf[6]} +
                                  {3'd0, trend_buf[7]} + {3'd0, trend_buf[8]} +
                                  {3'd0, trend_buf[9]};
    wire trend_ready = (trend_cnt >= 4'd10);
    wire trend_up   = trend_ready && (trend_recent_sum > trend_older_sum + 10'd15);
    wire trend_down = trend_ready && (trend_recent_sum + 10'd15 < trend_older_sum);
    wire trend_flat = trend_ready && !trend_up && !trend_down;
    // trend arrow: triangle in progress panel, right of bars (x 612..625).
    // R7-A2-F1: the coordinate MUST be the full-width offset from the box
    // left edge -- p2_x[3:0]-2 starts at 2 (612 mod 16 = 4), which made the
    // apex row (dx==0) unrenderable and split wide rows into two wedges.
    wire in_trend_box = (p2_x >= 10'd612) && (p2_x < 10'd626) &&
                         (p2_y >= 9'd370) && (p2_y < 9'd392);
    wire [3:0] trend_cdx = p2_x - 10'd612;    // 0..13 inside the box
    wire [3:0] up_s = (p2_y - 9'd372) >> 1;   // half-width 0..6 (y 372..384)
    wire [3:0] dn_s = (9'd384 - p2_y) >> 1;   // half-width 0..6
    // up triangle: narrows toward top (apex x=618 y=372, base 13 px y=384)
    wire up_tri = trend_up && in_trend_box &&
                  (p2_y >= 9'd372) && (p2_y <= 9'd384) &&
                  (trend_cdx <= 4'd6 + up_s) && (trend_cdx >= 4'd6 - up_s);
    // down triangle: narrows toward bottom (base 13 px y=372, apex y=384)
    wire dn_tri = trend_down && in_trend_box &&
                  (p2_y >= 9'd372) && (p2_y <= 9'd384) &&
                  (trend_cdx <= 4'd6 + dn_s) && (trend_cdx >= 4'd6 - dn_s);
    // flat bar: horizontal rectangle
    wire fl_bar = trend_flat && in_trend_box &&
                  (p2_y >= 9'd377) && (p2_y < 9'd383) &&
                  (trend_cdx >= 4'd1) && (trend_cdx <= 4'd12);
    wire [23:0] trend_color = trend_up ? UI_SUCCESS :
                              trend_down ? UI_WARNING : UI_REFERENCE_CURVE;
    wire trend_hit = up_tri || dn_tri || fl_bar;
    wire [23:0] bar_rgb = p2_bshort ? UI_WARNING :
                          (p2_bstars == 2'd3) ? 24'hFBBF24 : (p2_bstars == 2'd2) ? UI_SUCCESS :
                          (p2_bstars == 2'd1) ? UI_REFERENCE_CURVE : 24'h64748B;

    // ---- chrome
    wire in_top = (p2_y < 9'd40);
    wire in_bot = (p2_y >= 9'd434);
    wire p_live = inrect(p2_x, p2_y, 10'd8, 9'd46, 10'd631, 9'd285);
    wire p_cmp  = inrect(p2_x, p2_y, 10'd8, 9'd292, 10'd315, 9'd427);
    wire p_prog = inrect(p2_x, p2_y, 10'd324, 9'd292, 10'd631, 9'd427);
    wire e_live = p_live && onedge(p2_x, p2_y, 10'd8, 9'd46, 10'd631, 9'd285);
    wire e_cmp  = p_cmp  && onedge(p2_x, p2_y, 10'd8, 9'd292, 10'd315, 9'd427);
    wire e_prog = p_prog && onedge(p2_x, p2_y, 10'd324, 9'd292, 10'd631, 9'd427);
    // legend swatches: 10x10 at (382,57) child, (446,57) teacher
    wire sw_c = (p2_x >= 10'd382) && (p2_x < 10'd392) && (p2_y >= 9'd57) && (p2_y < 9'd67);
    wire sw_t = (p2_x >= 10'd446) && (p2_x < 10'd456) && (p2_y >= 9'd57) && (p2_y < 9'd67);
    // link dot: 8x8 with clipped corners at (502,16)
    wire dot  = (p2_x >= 10'd502) && (p2_x < 10'd510) && (p2_y >= 9'd16) && (p2_y < 9'd24) &&
                !(((p2_x == 10'd502) || (p2_x == 10'd509)) && ((p2_y == 9'd16) || (p2_y == 9'd23)));
    // cue chip behind "please demonstrate": amber, pulsing
    wire chip = cue_chip && inrect(p2_x, p2_y, 10'd386, 9'd6, 10'd497, 9'd33);
    wire [23:0] chip_rgb = blink[5] ? UI_WARNING : 24'hE6B86A;

    reg [23:0] bg;
    always @* begin
        if (in_top || in_bot)  bg = UI_TEACHER_PANEL;
        else if (p_live || p_cmp || p_prog) bg = UI_TEACHER_PANEL;
        else                   bg = UI_TEACHER_BACKGROUND;
        if (p2_y == 9'd40 || p2_y == 9'd433) bg = UI_TEACHER_GRID;
        if (e_live || e_cmp || e_prog) bg = UI_TEACHER_GRID;
        if (chip)              bg = chip_rgb;
        if (live_grid || cmp_axis || prog_base) bg = UI_TEACHER_GRID;
    end

    reg [23:0] px;
    always @* begin
        px = bg;
        if (in_bar)    px = bar_rgb;
        if (avg_line)  px = 24'h8EA0BC;
        if (trend_hit) px = trend_color;
        if (cmp_r_hit) px = cmp_is_tch ? UI_REFERENCE_CURVE : 24'h64748B;
        if (cmp_c_hit) px = UI_CHILD_CURVE;
        if (tch_hit)   px = UI_REFERENCE_CURVE;
        if (child_hit) px = UI_CHILD_CURVE;
        if (sw_c)      px = UI_CHILD_CURVE;
        if (sw_t)      px = UI_REFERENCE_CURVE;
        if (dot)       px = b_link_up ? UI_SUCCESS : 24'h64748B;
        if (p2_tin)    px = blend(palette(p2_col), bg, rom_q[7 - {p2_pair, 1'b0} -: 2]);
    end

    // ================================================================ P3 out
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axis_user <= 1'b0; axis_valid <= 1'b0; axis_last <= 1'b0; axis_data <= 24'd0;
        end else begin
            axis_valid <= p2_de;
            axis_user  <= p2_first;
            axis_last  <= p2_de && (p2_x == 10'd639);
            axis_data  <= p2_de ? px : 24'd0;
        end
    end
endmodule
