`timescale 1ns/1ps
// Board A: signal acquisition + feature extraction (R81 A-board fill) and,
// since docs/14, the TEACHER CONSOLE: ch2 = child mic, ch3 = teacher mic,
// the second monitor on HDMI shows both live pitch curves, the teacher-vs-
// child shape of the last question and the progress bars (teacher_console).
//
// Capture the microphone, track pitch with TWO YIN windows (default W=384
// and a W=192 short window for children's high F0; per-frame winner =
// smaller cmnd_star), extract 36-band spectral energies (AGC-normalised),
// cycle-level voice quality, formant band picks, and classify each
// utterance with NB + DTW; stream a 15-byte two-player frame per video
// frame to Board B at 921600-8N1 and a raw-audio/spectral stream to the PC
// (docs/10 contract).
//
// Player 2 (ch3 time-mux + second tracker/NB) is the next increment: the
// link already carries the player-2 fields (silence-coded, v2_valid=0).
// Build variants (docs/13 S4): the default PRODUCT bit (DIAG = 0) carries the
// teacher console + HDMI; the spectral/voice-quality/NB chain and the raw PC
// stream do not fit beside it (4942 mslices > 4900, PHY-9009 on the first
// console build) and never affect the child's score (tone_scorer scores the
// contour; the classified tone only reaches the teacher OSD and SCORE line).
// DIAG = 1 builds the data-collection bit instead: full spectral chain +
// raw-audio stream on D12, no console (HDMI pins idle).
module shengsheng_board_a_top #(
    parameter integer DIAG = 0,
    parameter integer SINGLE_MIC = 1
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input wire key_teacher_n, key_child_n, // A KEY2 / KEY3, active low
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire        stream_tx,
    input  wire        demo_sw,            // SW1: teacher live demo (1 = on, docs/14 s6)
    input  wire        scope_sw,           // SW2 (V8 F5): live panel shows the
                                           // two mic waveforms + 8-band spectrum
    output wire        HDMI_CLK_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D0_P,
    // on-board U33 data flash (W25Q64), training records (docs/14 s5);
    // NEVER the U39 configuration flash
    output wire        flash_cs_n,
    output wire        flash_sclk,
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire        flash_wp_n,
    output wire        flash_hold_n,
    output wire [3:0]  led
);
    `include "audio_config.vh"
    // ================================================================ reset
    wire rst_n;
    reset_sync u_rst (
        .clk(sys_clk), .ext_rst_n(sys_rst_n), .rst_n_sync(rst_n)
    );

    wire video_clk;
    wire pixel_clk_5x;                     // 125 MHz TMDS serial clock (console)
    wire pll_lock;
    sys_pll_promax_40 u_pll (
        .refclk(sys_clk), .reset(~rst_n),
        .clk0_out(), .clk1_out(), .clk2_out(),
        .clk3_out(video_clk), .clk4_out(pixel_clk_5x),
        .locked(pll_lock)
    );

    wire video_rst_n;
    reset_sync u_video_rst (
        .clk(video_clk), .ext_rst_n(sys_rst_n & pll_lock),
        .rst_n_sync(video_rst_n)
    );

    // ================================================================ mic frontend
    wire        fe_valid;
    wire signed [15:0] fe_sample;
    wire        fe_clip;
    wire [11:0] fe_raw;

    wire        fe2_valid;
    wire signed [15:0] fe2_sample;
    wire        fe2_clip;

    mic_adc_frontend #(
        .SOC_PERIOD(100),
        .CHANNEL(3'd2),
        .VREF_MODE("ENABLE"),
        .CLIP_LO(420),
        .CLIP_HI(3680),
        .TIME_MUX(1),
        .CHANNEL_B(3'd3)
    ) u_mic (
        .clk(video_clk), .rst_n(video_rst_n),
        .sample_valid(fe_valid), .sample(fe_sample),
        .clip(fe_clip), .raw_code(fe_raw),
        .sample_valid_b(fe2_valid), .sample_b(fe2_sample),
        .clip_b(fe2_clip)
    );

    // Keep the existing ADC timing/calibration: CH2 supplies 7812.5 S/s.
    // CH3 is still converted but is not consumed in single-microphone mode.
    wire mic_teacher,mic_changed,mic_settling,child_sample_valid,teacher_sample_valid;
    wire signed [15:0] mic_sample;
    wire single_mic_mode=(SINGLE_MIC!=0 && DIAG==0);
    single_mic_control u_mic_role (
        .clk(video_clk),.rst_n(video_rst_n),
        .key_teacher_n(key_teacher_n),.key_child_n(key_child_n),
        .sample_valid(fe_valid),.sample(fe_sample),
        .teacher_selected(mic_teacher),.role_changed(mic_changed),.settling(mic_settling),
        .child_valid(child_sample_valid),.teacher_valid(teacher_sample_valid),.routed_sample(mic_sample));
    wire child_run=!single_mic_mode || (!mic_teacher && !mic_settling);
    wire teacher_run=!single_mic_mode || (mic_teacher && !mic_settling);
    wire child_rst_n=video_rst_n && child_run;
    wire teacher_rst_n=video_rst_n && teacher_run;
    wire child_ready,teacher_ready;
    wire mic_ready=!mic_settling && (mic_teacher ? teacher_ready : child_ready);
    wire child_publish=child_run && (!single_mic_mode || child_ready);
    wire teacher_publish=teacher_run && (!single_mic_mode || teacher_ready);

    // ================================================================ frame tick
    localparam integer FRAME_CYC = 416666;
    reg [18:0] frame_cnt;
    wire frame_start_c = (frame_cnt == FRAME_CYC - 1);
    // R83: register frame_start to prevent the synthesis tool from
    // promoting frame_cnt[0] to a global clock (24-fanout mslice waste)
    reg frame_start;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n)    frame_start <= 1'b0;
        else                 frame_start <= frame_start_c;
    end
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n)       frame_cnt <= 19'd0;
        else if (frame_start)   frame_cnt <= 19'd0;
        else                    frame_cnt <= frame_cnt + 1'b1;
    end

    // ================================================================ pitch trackers (dual window)
    wire trk_valid, trk_voiced, trk_used_thr, trk_busy, trk_silent;
    wire [9:0]  trk_pitch;
    wire [11:0] trk_tau;
    wire [12:0] trk_cmnd;
    wire [7:0]  trk_level;
    wire [30:0] trk_energy;

    wire trk2_valid, trk2_voiced, trk2_used_thr, trk2_busy, trk2_silent;
    wire [9:0]  trk2_pitch;
    wire [11:0] trk2_tau;
    wire [12:0] trk2_cmnd;
    wire [7:0]  trk2_level;
    wire [30:0] trk2_energy;

    localparam [7:0] PITCH_LEVEL_THR = 8'd120;

    // 7812.5 samples/s/channel: p=192*log2(f/61.03515625).
    // Fs halving requires -192 Q4, not +192; low-tau normalization is
    // handled inside pitch_tracker without narrowing the child's range.
    pitch_tracker #(
        .PITCH_Q4_ADJ(AUDIO_PITCH_Q4_ADJ),
        .TMIN(AUDIO_CHILD_TMIN),
        .TMAX(AUDIO_CHILD_TMAX)
    ) u_trk (
        .clk(video_clk), .rst_n(child_rst_n),
        .sample_valid(single_mic_mode ? child_sample_valid : fe_valid), .sample(fe_sample),
        .trigger(frame_start && !trk_busy),
        .level_thr(PITCH_LEVEL_THR),
        .result_valid(trk_valid), .voiced(trk_voiced),
        .pitch_q4(trk_pitch), .tau_q4(trk_tau), .cmnd_star(trk_cmnd),
        .level(trk_level), .energy(trk_energy),
        .used_threshold(trk_used_thr), .silent(trk_silent), .busy(trk_busy), .ready(child_ready)
    );

    pitch_tracker #(
        .W(192), .PITCH_Q4_ADJ(AUDIO_PITCH_Q4_ADJ), .TMIN(AUDIO_CHILD_TMIN), .TMAX(AUDIO_CHILD_TMAX)
    ) u_trk_hi (
        .clk(video_clk), .rst_n(child_rst_n),
        .sample_valid(single_mic_mode ? child_sample_valid : fe_valid), .sample(fe_sample),
        // R83: skip the short window when the main tracker's CMND is good
        // (the standard window already matches well -- running the short
        // window is wasted computation for low-F0 children); P1: also skip
        // it while the main tracker skipped a silent window
        .trigger(frame_start && !trk2_busy && !trk_silent && (trk_cmnd > 13'd600)),
        .level_thr(PITCH_LEVEL_THR),
        .result_valid(trk2_valid), .voiced(trk2_voiced),
        .pitch_q4(trk2_pitch), .tau_q4(trk2_tau), .cmnd_star(trk2_cmnd),
        .level(trk2_level), .energy(trk2_energy),
        .used_threshold(trk2_used_thr), .silent(trk2_silent), .busy(trk2_busy)
    );

    reg        trk2_seen;
    reg        win2_voiced;
    reg [9:0]  win2_pitch;
    reg [11:0] win2_tau;
    reg [7:0]  win2_level;
    reg [12:0] win2_cmnd;
    always @(posedge video_clk or negedge child_rst_n) begin
        if (!child_rst_n) begin
            trk2_seen <= 1'b0;
            win2_voiced <= 1'b0; win2_pitch <= 10'd0; win2_tau <= 12'd0;
            win2_level <= 8'd0; win2_cmnd <= 13'h1fff;
        end else begin
            if (frame_start)
                trk2_seen <= 1'b0;
            if (trk2_valid) begin
                trk2_seen   <= 1'b1;
                win2_voiced <= trk2_voiced;
                win2_pitch  <= trk2_pitch;
                win2_tau    <= trk2_tau;
                win2_level  <= trk2_level;
                win2_cmnd   <= trk2_cmnd;
            end
        end
    end

    wire        f_voiced;
    wire [9:0]  f_pitch;
    wire [11:0] f_tau;
    wire [7:0]  f_level;
    wire use_hi = trk2_seen && (win2_cmnd < trk_cmnd);
    assign f_voiced = use_hi ? win2_voiced : trk_voiced;
    assign f_pitch  = use_hi ? win2_pitch  : trk_pitch;
    assign f_tau    = use_hi ? win2_tau    : trk_tau;
    assign f_level  = use_hi ? win2_level  : trk_level;

    // ================================================================ player 2 pitch chain (ch3)
    // ch3 streams at 7.8 kS/s (single hard ADC time-muxed); the tracker
    // window retunes to keep the 24.6 ms span (W=192) and the 75..488 Hz
    // F0 range (TMIN=16, TMAX=101); PITCH_Q4_ADJ=192 restores the absolute
    // pitch scale after the R81 rate halving (see the child trackers).
    wire trk3_valid, trk3_voiced, trk3_used_thr, trk3_busy, trk3_silent;
    wire [9:0]  trk3_pitch;
    wire [11:0] trk3_tau;
    wire [12:0] trk3_cmnd;
    wire [7:0]  trk3_level;
    wire [30:0] trk3_energy;

    pitch_tracker #(
        .W(192), .TMIN(AUDIO_TEACHER_TMIN), .TMAX(AUDIO_TEACHER_TMAX),
        .PITCH_Q4_ADJ(AUDIO_PITCH_Q4_ADJ)
    ) u_trk_p2 (
        .clk(video_clk), .rst_n(teacher_rst_n),
        .sample_valid(single_mic_mode ? teacher_sample_valid : fe2_valid),
        .sample(single_mic_mode ? mic_sample : fe2_sample),
        .trigger(frame_start && !trk3_busy),
        .level_thr(PITCH_LEVEL_THR),
        .result_valid(trk3_valid), .voiced(trk3_voiced),
        .pitch_q4(trk3_pitch), .tau_q4(trk3_tau), .cmnd_star(trk3_cmnd),
        .level(trk3_level), .energy(trk3_energy),
        .used_threshold(trk3_used_thr), .silent(trk3_silent), .busy(trk3_busy), .ready(teacher_ready)
    );

    // ================================================================ diagnostic spectral chain
    wire        agc_ovf;
    wire [3:0]  f1_band, f2_band;
    wire [7:0]  jitter_c, shimmer_c;
    wire [2:0]  nb_tone;
    wire        nb_ready;
    wire [287:0] diag_bands;
    wire         diag_bands_valid;
    generate if (DIAG != 0) begin : g_diag
        // ONE shared 36-band core alternates windows between the players
        // (30 Hz spectral updates each) -- a second instance would exceed the
        // 29-DSP device limit.
        // DIAG samples one explicit channel (CH2 child). Alternating the
        // source every 130 samples mixed two microphones in an N=260 window.
        reg [8:0] diag_sample_count;
        wire diag_window_tick=fe_valid && diag_sample_count==9'd259;
        always @(posedge video_clk or negedge video_rst_n) begin
            if (!video_rst_n) diag_sample_count<=0;
            else if(fe_valid) diag_sample_count<=diag_window_tick?9'd0:diag_sample_count+1'b1;
        end
        wire        g_valid = fe_valid;
        wire signed [15:0] g_sample = fe_sample;

        wire signed [15:0] agc_sample;
        // audit P1-2: TIME_MUX=1 halves the per-channel rate to 130
        // samples/frame, so the AGC calibration halves with it
        agc_tap #(.ACC_TARGET(6100)) u_agc (
            .clk(video_clk), .rst_n(video_rst_n),
            .sample_valid(g_valid), .sample(g_sample),
            .frame_tick(diag_window_tick),
            .agc_sample(agc_sample), .agc_ovf(agc_ovf)
        );

        // ================================================================ 36-band spectral
        wire [287:0] band_energy;
        wire         bands_valid;
        goertzel_sband #(.N(260)) u_goertzel (
            .clk(video_clk), .rst_n(video_rst_n),
            .sample_valid(g_valid), .sample(agc_sample),
            .frame_tick(diag_window_tick),
            .acc_freeze(1'b0),
            .bands(band_energy), .bands_valid(bands_valid)
        );

        // NB consumes the old-8 band energies, same physical bands and order
        // as its training features (k = 4,7,11,17,26,39,59,89 -> indices
        // 1,4,8,14,20,25,30,34) -- constants stay valid without retraining.
        // registered: breaks the 36:1 comb mapping off bands_reg; NB consumes
        // bands on frame_valid (tracker result, ~6.6 ms after bands_valid), so
        // the one-frame pipeline is timing-safe
        reg [63:0] nb_bands;
        always @(posedge video_clk) begin
            if (bands_valid) begin
                nb_bands <= {band_energy[34*8 +: 8], band_energy[30*8 +: 8],
                             band_energy[25*8 +: 8], band_energy[20*8 +: 8],
                             band_energy[14*8 +: 8], band_energy[8*8  +: 8],
                             band_energy[4*8  +: 8], band_energy[1*8  +: 8]};
            end
        end

        // ================================================================ formant picks
        formant_picker u_formant (
            .clk(video_clk), .rst_n(video_rst_n),
            .bands_valid(bands_valid), .bands(band_energy),
            .voiced(f_voiced),
            .f1_band(f1_band), .f2_band(f2_band)
        );

        // ================================================================ cycle-level voice quality
        wire [3:0] jitter_f, shimmer_f;
        vq_cycle #(.UV_RESET(24)) u_vq (
            .clk(video_clk), .rst_n(video_rst_n),
            .sample_valid(fe_valid), .sample(fe_sample),
            .frame_valid(trk_valid), .voiced(f_voiced),
            .jitter_c(jitter_c), .shimmer_c(shimmer_c),
            .jitter_f(jitter_f), .shimmer_f(shimmer_f)
        );

        // ================================================================ NB fallback (player 1)
        // Legacy NB constants were trained with another rate/band contract.
        // Raw diagnostic spectra remain available; no validity is fabricated.
        assign nb_tone=3'd0;
        assign nb_ready=1'b0;
        assign diag_bands = band_energy;
        assign diag_bands_valid = bands_valid;
    end else begin : g_nodiag
        // product bit: link fields the chain fed are sent as "no data"
        assign agc_ovf = 1'b0;
        assign f1_band = 4'd0;  assign f2_band = 4'd0;
        assign jitter_c = 8'd0; assign shimmer_c = 8'd0;
        assign nb_tone = 3'd0;  assign nb_ready = 1'b0;
        assign diag_bands = 288'd0;
        assign diag_bands_valid = 1'b0;
    end endgenerate

    // R81b: the p2 NB instance was CUT -- with it the design hit 4952
    // mslices against the 4900 device limit (PHY-9009). Player 2's tone
    // verdict moves to Board B's LUT when the dual-player game lands; the
    // link byte b11 already carries the field (sent as 0 = no verdict).

    // R83b: DTW matcher REMOVED -- routing congestion (PHY-8023 on the DP
    // mux at 100% DSP + 78.7% LUT) and standalone accuracy 26.67% (near
    // random) made it unjustifiable. The NB cascade (LUT->NB, 86.58%)
    // never reaches the DTW vote. Code retained in board_a/src/dtw_matcher.v
    // for future evaluation with real-device data; packer's dtw_byte input
    // is tied to 8'h00 (dtw_ready=0, dtw_tone=0).

    // ================================================================ teacher curve (docs/14 s2)
    // The ch3 teacher channel's finished utterances become 16-point shapes;
    // the latest one rides the packer's b11..b14 carousel to Board B, which
    // draws it as the target mountain while the teacher demo is on.
    wire         tc_done;
    wire [6:0]   tc_n;
    wire [9:0]   tc_mean;
    wire [127:0] tc_off;
    wire tc_arm, tc_cancel, tc_armed, link_demo_armed;
    wire [127:0] tch_demo;
    // DIAG bit: no teacher curve -- with it the diag build no longer routed
    // (PHY-8023 at the Goertzel 36:1 mux, seeds 1/2/3/5, 2026-10-02); data
    // collection needs only the A->B features and the raw PC stream
    generate if (DIAG == 0) begin : g_tc
        contour_capture u_tch (
            .clk(video_clk), .rst_n(video_rst_n),
            .arm(tc_arm), .cancel(tc_cancel || (single_mic_mode && mic_changed)), .armed(tc_armed),
            .frame_valid(trk3_valid && teacher_publish), .voiced(trk3_voiced), .pitch_q4(trk3_pitch),
            .done(tc_done), .n_out(tc_n), .mean_out(tc_mean), .off_flat(tc_off)
        );
    end else begin : g_notc
        assign tc_done = 1'b0; assign tc_n = 7'd0;
        assign tc_mean = 10'd0; assign tc_off = 128'd0; assign tc_armed = 1'b0;
    end endgenerate

    // SW1, synchronised and debounced (20 ms stable)
    reg [1:0]  dsw_s;
    reg [18:0] dsw_cnt;
    reg        demo_en;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            dsw_s <= 2'b00; dsw_cnt <= 19'd0; demo_en <= 1'b0;
        end else begin
            dsw_s <= {dsw_s[0], demo_sw};
            if (dsw_s[1] == demo_en)
                dsw_cnt <= 19'd0;
            else if (dsw_cnt == 19'd499999) begin
                demo_en <= dsw_s[1];
                dsw_cnt <= 19'd0;
            end else
                dsw_cnt <= dsw_cnt + 1'b1;
        end
    end

    // SW2 (V8 F5), same debounce
    reg [1:0]  ssw_s;
    reg [18:0] ssw_cnt;
    reg        scope_en;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            ssw_s <= 2'b00; ssw_cnt <= 19'd0; scope_en <= 1'b0;
        end else begin
            ssw_s <= {ssw_s[0], scope_sw};
            if (ssw_s[1] == scope_en)
                ssw_cnt <= 19'd0;
            else if (ssw_cnt == 19'd499999) begin
                scope_en <= ssw_s[1];
                ssw_cnt <= 19'd0;
            end else
                ssw_cnt <= ssw_cnt + 1'b1;
        end
    end

    // V8 F5: every other video frame closes a spectrum window. At 7812.5
    // S/s that is exactly the 260-sample Hann window goertzel_8band wants.
    reg scope_window_tick;
    reg scope_window_phase;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            scope_window_tick <= 1'b0; scope_window_phase <= 1'b0;
        end else begin
            scope_window_tick <= frame_start && scope_window_phase;
            if (frame_start) scope_window_phase <= ~scope_window_phase;
        end
    end

    // ================================================================ PC stream (raw + spectral)
    // R83: suppress raw samples after 8 consecutive unvoiced frames --
    // the PC parser syncs on A5 markers so the sample gap is transparent;
    // spectral frames continue (noise floor data for calibration)
    reg [3:0] sil_cnt;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n)              sil_cnt <= 4'd0;
        else if (frame_start) begin
            if (f_voiced)              sil_cnt <= 4'd0;
            else if (sil_cnt < 4'd15)  sil_cnt <= sil_cnt + 1'b1;
        end
    end
    wire stream_suppress = (sil_cnt >= 4'd8);

    generate if (DIAG != 0) begin : g_stream
        stream_uart #(.CLKS_PER_BIT(27), .NBANDS(36)) u_stream (
            .clk(video_clk), .rst_n(video_rst_n),
            .sample_valid(fe_valid), .sample(fe_sample),
            .bands_valid(diag_bands_valid), .bands(diag_bands),
            .stream_tx(stream_tx)
        );
    end else begin : g_nostream
        assign stream_tx = 1'b1;                // UART idle on the CH340
    end endgenerate

    // DIAG is a separate diagnostic firmware; it is not a PRODUCT v7 peer.
    generate if (DIAG != 0) begin : g_diag_packer
    feature_packer #(.CLKS_PER_BIT(27)) u_packer (
        .clk(video_clk), .rst_n(video_rst_n),
        .frame_valid(trk_valid),
        .voiced(f_voiced),
        .pitch_q4(f_pitch),
        .level(f_level),
        .tau_q4(f_tau),
        .f1_band(f1_band),
        .f2_band(f2_band),
        .jitter_c(jitter_c),
        .shimmer_c(shimmer_c),
        .nb_byte({nb_ready, 1'b0, nb_tone, 3'b000}),
        .dtw_byte(8'h00),                   // DTW removed (see above)
        .clip_flag(fe_clip),
        .agc_ovf(agc_ovf),
        .v2_valid(1'b1),                    // ch3 chain live (R81)
        .voiced2(trk3_voiced),
        .pitch_q42(trk3_pitch),
        .level2(trk3_level),
        .tau_q42(trk3_tau),
        .demo_en(demo_en),
        .tc_valid(1'b0),
        .tc_seq(4'd0),
        .tc_msg(144'd0),
        .uart_tx(uart_tx)
    );
    end endgenerate

    // ================================================================ B -> A return link (docs/14 s3)
    wire        b_link_up, b_tch_used, b_teacher_on, b_teacher_waiting, b_res_new, b_short;
    wire [2:0]  b_mode, b_phase, b_target, b_tone;
    wire [1:0]  b_q, b_eff, b_stars;
    wire [15:0] b_seq;
    wire [6:0]  b_score, b_n;
    wire [127:0] b_shape;
    generate if (DIAG == 0) begin : g_brx       // only the console consumes it
        v7_link_a #(.CLKS_PER_BIT(27), .SINGLE_MIC(SINGLE_MIC)) u_link (
            .clk(video_clk), .rst_n(video_rst_n), .rx(uart_rx),
            .tx(uart_tx), .feature_valid(single_mic_mode ? frame_start : trk_valid),
            .mic_teacher(mic_teacher),.mic_ready(mic_ready),
            .child_voiced(f_voiced && child_publish), .child_pitch(f_pitch), .child_level(child_publish ? f_level : 8'd0),
            .teacher_voiced(trk3_voiced && teacher_publish), .teacher_pitch(trk3_pitch), .teacher_level(teacher_publish ? trk3_level : 8'd0),
            .teacher_preference(demo_en),
            .capture_arm(tc_arm), .capture_cancel(tc_cancel), .capture_armed(tc_armed),
            .capture_done(tc_done), .capture_n(tc_n), .capture_mean(tc_mean), .capture_shape(tc_off),
            .demo_armed(link_demo_armed), .demo_shape(tch_demo), .protocol_error(),
            .link_up(b_link_up), .mode(b_mode), .phase(b_phase), .q_idx(b_q),
            .eff_diff(b_eff), .tch_used(b_tch_used), .teacher_on(b_teacher_on),
            .teacher_waiting(b_teacher_waiting),
            .res_new(b_res_new), .res_event(b_seq), .target(b_target), .tone(b_tone),
            .stars(b_stars), .too_short(b_short), .score(b_score), .n_points(b_n),
            .shape(b_shape)
        );
    end else begin : g_nobrx
        assign b_link_up = 1'b0; assign b_tch_used = 1'b0; assign b_teacher_on = 1'b0;
        assign b_teacher_waiting=1'b0;
        assign b_res_new = 1'b0; assign b_short = 1'b0;
        assign b_mode = 3'd0; assign b_phase = 3'd0; assign b_target = 3'd0; assign b_tone = 3'd0;
        assign b_q = 2'd0; assign b_eff = 2'd0; assign b_stars = 2'd0; assign b_seq = 16'd0;
        assign b_score = 7'd0; assign b_n = 7'd0; assign b_shape = 128'd0;
        assign tc_arm=1'b0; assign tc_cancel=1'b1; assign link_demo_armed=1'b0; assign tch_demo=128'd0;
    end endgenerate

    // ================================================================ teacher console (docs/14 s4)
    // tch_demo belongs to an armed request. Actual use is confirmed by B's
    // status/result tch_used; preference SW1 alone never implies acceptance.

    generate if (DIAG == 0) begin : g_con
        // ---- training-record journal (docs/14 s5, S6): power-on replay
        // into the console's progress bars, then one flash record per result
        wire        jr_load, jr_short, jr_ready, jr_error;
        wire [1:0]  jr_error_kind;
        wire [6:0]  jr_score;
        wire [1:0]  jr_stars;
        training_journal u_journal (
            .clk(video_clk), .rst_n(video_rst_n),
            .res_new(b_res_new), .res_short(b_short), .res_score(b_score),
            .res_stars(b_stars), .res_target(b_target), .res_tone(b_tone),
            .b_mode(b_mode), .b_q(b_q), .b_tch_used(b_tch_used),
            .b_teacher_on(b_teacher_on), .res_shape(b_shape),
            .hist_load(jr_load), .hist_score(jr_score),
            .hist_stars(jr_stars), .hist_short(jr_short),
            .hist_ready(jr_ready), .journal_error(jr_error), .journal_error_kind(jr_error_kind),
            .spi_cs_n(flash_cs_n), .spi_sclk(flash_sclk),
            .spi_mosi(flash_mosi), .spi_miso(flash_miso),
            .spi_wp_n(flash_wp_n), .spi_hold_n(flash_hold_n)
        );

        wire        cv_user, cv_valid, cv_last;
        wire [23:0] cv_data;
        teacher_console #(.SINGLE_MIC(SINGLE_MIC)) u_console (
            .clk(video_clk), .rst_n(video_rst_n),
            .journal_error(jr_error), .journal_error_kind(jr_error_kind), .demo_armed(link_demo_armed),
            .mic_teacher(mic_teacher), .mic_ready(mic_ready), .teacher_tick(trk3_valid && teacher_publish),
            .frame_tick(trk_valid && child_publish), .child_v(f_voiced), .child_p(f_pitch),
            .teacher_v(trk3_voiced), .teacher_p(trk3_pitch), .demo_en(demo_en),
            .b_link_up(b_link_up), .b_mode(b_mode), .b_phase(b_phase), .b_q(b_q),
            .b_teacher_on(b_teacher_waiting),
            .res_new(b_res_new), .res_target(b_target), .res_stars(b_stars),
            .res_short(b_short), .res_score(b_score), .res_tch_used(b_tch_used),
            .res_shape(b_shape), .tch_shape(tch_demo),
            .hist_load(jr_load), .hist_short(jr_short),
            .hist_score(jr_score), .hist_stars(jr_stars),
            .replay_busy(~jr_ready),
            .axis_user(cv_user), .axis_valid(cv_valid), .axis_last(cv_last),
            .axis_data(cv_data)
        );

        // V8 F5: scope page. Two register stages on the stream either way,
        // the console itself is untouched.
        wire        sc_user, sc_valid, sc_last;
        wire [23:0] sc_data;
        // SPEC_MODE 0: waveforms only, two full-height traces. One 8-band
        // datapath (SPEC_MODE 1, selected by SW1) placed and routed at
        // mslice 4636/4900 but left the whole device without hold margin
        // (23 endpoints at -0.061 ns, spread across the console, the HDMI
        // core and the tracker -- this board was at HWNS +0.004 before F5).
        // The child screen already carries a 16-band spectrum of the real
        // HDMI PCM, and the scoring criterion asks for spectrum OR waveform.
        console_scope_v8 #(.SINGLE_MIC(SINGLE_MIC), .SPEC_MODE(0), .CH_MID(105), .TC_MID(225), .AMP(55)) u_scope (
            .clk(video_clk), .rst_n(video_rst_n), .enable(scope_en),
            .spec_sel(demo_en),
            .sample_valid(single_mic_mode ? child_sample_valid : fe_valid), .child_sample(fe_sample),
            .sample_valid_b(single_mic_mode ? teacher_sample_valid : fe2_valid),
            .teacher_sample(single_mic_mode ? mic_sample : fe2_sample),
            .window_tick(scope_window_tick),
            .voice_gate_c_i(trk_voiced), .voice_gate_t_i(trk3_voiced),
            .in_user(cv_user), .in_valid(cv_valid), .in_last(cv_last),
            .in_data(cv_data),
            .out_user(sc_user), .out_valid(sc_valid), .out_last(sc_last),
            .out_data(sc_data),
            .child_bands(), .teacher_bands()
        );

        // silent 48 kHz audio clock for the HDMI core's ACR packets (same core
        // configuration as Board B; the console carries no sound)
        reg [15:0] aud_acc;
        reg        aud_tick;
        always @(posedge video_clk or negedge video_rst_n) begin
            if (!video_rst_n) begin
                aud_acc <= 16'd0; aud_tick <= 1'b0;
            end else if (aud_acc + 16'd48 >= 16'd25000) begin
                aud_acc <= aud_acc + 16'd48 - 16'd25000; aud_tick <= 1'b1;
            end else begin
                aud_acc <= aud_acc + 16'd48; aud_tick <= 1'b0;
            end
        end
        wire        acr_valid;
        wire [19:0] acr_cts, acr_n;
        audio_arc_calculate #(.ACR_N(6144)) u_audio_acr (
            .I_clk(video_clk), .I_rst(~video_rst_n),
            .I_audio_valid(aud_tick), .O_acr_valid(acr_valid),
            .O_acr_cts(acr_cts), .O_acr_n(acr_n)
        );

        wire [9:0] hdmi_tmds_ch0, hdmi_tmds_ch1, hdmi_tmds_ch2, hdmi_tmds_clk;
        wire       hdmi_video_locked;
        wire       cv_ready;
        hdmi_1_4b_transmitter_core_wrapper #(
            .DEVICE("EG"),
            .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
            .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
            .VIDEO_VIC(1), .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"),
            .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
        ) u_hdmi14_core (
            .I_pixel_clk(video_clk), .I_rst(~video_rst_n),
            .I_edid_read_trig(1'b0),
            .O_edid_read_valid(), .O_edid_read_data(),
            .I_axis_s_user(sc_user),
            .I_axis_s_valid(sc_valid), .I_axis_s_last(sc_last),
            .I_axis_s_data(sc_data), .O_axis_s_ready(cv_ready),
            .I_audio_valid(aud_tick),
            .I_audio_left_data(24'd0), .I_audio_right_data(24'd0),
            .I_acr_valid(acr_valid), .I_acr_cts(acr_cts), .I_acr_n(acr_n),
            .O_video_locked(hdmi_video_locked),
            .O_ddc_scl(), .IO_ddc_sda(),
            .O_ch0_tmds_data(hdmi_tmds_ch0), .O_ch1_tmds_data(hdmi_tmds_ch1),
            .O_ch2_tmds_data(hdmi_tmds_ch2), .O_clk_tmds_data(hdmi_tmds_clk)
        );
        hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy (
            .I_pixel_clk(video_clk), .I_serial_clk(pixel_clk_5x),
            .I_rst(~video_rst_n),
            .I_tmds_channel_0(hdmi_tmds_ch0), .I_tmds_channel_1(hdmi_tmds_ch1),
            .I_tmds_channel_2(hdmi_tmds_ch2), .I_tmds_channel_clk(hdmi_tmds_clk),
            .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P),
            .O_tmds_ch2_p(HDMI_D2_P), .O_tmds_clk_p(HDMI_CLK_P)
        );
    end else begin : g_nocon
        // DIAG bit: no console, no journal -- the data flash stays in
        // standby (CS high) and the pins idle
        assign HDMI_CLK_P = 1'b0; assign HDMI_D0_P = 1'b0;
        assign HDMI_D1_P = 1'b0;  assign HDMI_D2_P = 1'b0;
        assign flash_cs_n = 1'b1; assign flash_sclk = 1'b0;
        assign flash_mosi = 1'b0; assign flash_wp_n = 1'b1;
        assign flash_hold_n = 1'b1;
    end endgenerate

    // ================================================================ LEDs
    reg led_voiced_d;
    always @(posedge video_clk or negedge video_rst_n) begin
        if (!video_rst_n)          led_voiced_d <= 1'b0;
        else if (trk_valid)        led_voiced_d <= f_voiced;
    end

    assign led[0] = pll_lock;
    assign led[1] = led_voiced_d;
    assign led[2] = b_link_up;              // Board B return packets arriving
    assign led[3] = single_mic_mode ? fe_clip : (fe_clip | fe2_clip);     // either mic clipping

endmodule
