`timescale 1ns/1ps
// V8 F5: teacher-screen scope page (scoring extension 5, audio visualisation).
//
// Sits on the AXI-stream between teacher_console and the HDMI core, so the
// console's own pixel pipeline is untouched: with enable low every beat is
// passed through after two register stages. With enable high the live panel
// (the 10 s pitch view) is replaced by
//
//   y  50..108  child mic waveform   (orange, +-AMP px around CH_MID)
//   y 112..170  teacher mic waveform (blue)
//   y 176..285  8-band spectrum of the mic spec_sel picks (SPEC_MODE=1) or
//               of both mics (SPEC_MODE=2, does not fit beside the console)
//
// One column per sample pair at 7812.5 S/s, so a sweep is 608/7812.5 =
// 77.8 ms and the trace scrolls left like the pitch panel above it. The
// spectrum comes from two goertzel_8band instances closed every other video
// frame: at this sample rate 260 samples is exactly 33.3 ms, so the Hann
// window is used whole and the band centres land at 120..2674 Hz.
module console_scope_v8 #(
    parameter integer SINGLE_MIC = 0,
    parameter integer COLS = 608,
    parameter integer X0 = 16,
    parameter integer CH_MID = 79,
    parameter integer TC_MID = 141,
    parameter integer AMP = 28,
    parameter integer SPEC_TOP = 176,
    parameter integer SPEC_BASE = 285,
    // 2 = a spectrum per mic (two goertzel_8band, +1445 mslices: PHY-9009
    // next to the console), 1 = one instance on the mic spec_sel selects,
    // 0 = waveforms only
    parameter integer SPEC_MODE = 1,
    parameter integer BARS = (SPEC_MODE == 2) ? 16 : 8,
    parameter integer BAR_PITCH = COLS / BARS,
    parameter integer BAR_W = BAR_PITCH - 6
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    // both channels arrive on the same time-muxed front end
    input  wire        sample_valid,
    input  wire signed [15:0] child_sample,
    input  wire        sample_valid_b,
    input  wire signed [15:0] teacher_sample,
    input  wire        window_tick,      // closes a spectrum window (30 Hz)
    input  wire        spec_sel,         // SPEC_MODE=1: 0 = child, 1 = teacher
    // Q6 (2026-10-25): display gating from the PITCH TRACKER's voiced
    // decision -- the one voice/noise discriminator this system has proven
    // on hardware (PITCH_LEVEL_THR never false-triggers recording). The
    // amplitude-domain gate of Q4/Q5 pinned idle perfectly but could not
    // separate speech from noise because the display source's SNR is
    // compressed; the tracker sees the right signal. High = voice present.
    input  wire        voice_gate_c_i,
    input  wire        voice_gate_t_i,
    input  wire        in_user,
    input  wire        in_valid,
    input  wire        in_last,
    input  wire [23:0] in_data,
    output wire        out_user,
    output wire        out_valid,
    output wire        out_last,
    output wire [23:0] out_data,
    output wire [63:0] child_bands,
    output wire [63:0] teacher_bands
);
    `include "ui_config.vh"
    localparam [23:0] COL_CHILD = UI_CHILD_CURVE;
    localparam [23:0] COL_TCH   = UI_REFERENCE_CURVE;
    localparam [23:0] COL_GRID  = UI_TEACHER_GRID;
    localparam [23:0] COL_BG    = UI_TEACHER_PANEL;

    // ------------------------------------------------------------ sample store
    // {child[7:0], teacher[7:0]}, one entry per column, signed around 0
    reg [7:0] child_wave [0:1023];
    reg [7:0] teacher_wave [0:1023];
    reg [9:0] teacher_wp, teacher_wp_frame;
    integer wi;
    initial for(wi=0;wi<1024;wi=wi+1)begin child_wave[wi]=0;teacher_wave[wi]=0;end
    reg [9:0]  wp;
    reg [9:0]  wp_frame;                  // latched per frame: no tearing
    reg signed [7:0] tch_hold;

    function signed [7:0] scale_sample;   // +-16384 -> +-AMP, clamped
        input signed [15:0] s;
        reg signed [16:0] extended_sample;
        reg [16:0] magnitude;
        reg signed [16:0] shifted;
        begin
            // Display quantization only: truncate magnitude toward zero on
            // both polarities. The former arithmetic shift mapped -1..-511
            // to -1 pixel but +1..+511 to 0, creating asymmetric idle jitter.
            // Q3 (2026-10-25): dead-band doubled to |s|<1024 for noisier rooms;
            // still display-only -- ADC/pitch/capture/scoring samples untouched.
            // Extend before negating so -32768 is handled without overflow.
            // ADC, pitch/VAD, capture and scoring retain the original samples.
            extended_sample = {s[15], s};
            magnitude = s[15] ? -extended_sample : extended_sample;
            shifted = s[15] ? -$signed(magnitude >> 10) : $signed(magnitude >> 10);
            if (shifted > AMP) scale_sample = AMP[7:0];
            else if (shifted < -AMP) scale_sample = -AMP[7:0];
            else scale_sample = shifted[7:0];
        end
    endfunction

    // ===== Q4 adaptive display denoising (2026-10-25, display-only) =====
    // FIR smoothing + noise-floor gate with boot clamp. The floor tracks
    // the amplitude envelope ONLY while the gate is closed (speech cannot
    // inflate it) and starts learning before any gating (256-sample boot
    // clamp), so cold-start noise cannot open the gate on a still-low
    // floor. Gate opens after 3 consecutive samples above floor*2, closes
    // after 8 below (speech zero-crossings cannot flap it). Open gate
    // shows the 4-tap moving average through the unchanged Q3 quantizer;
    // below floor*5/4 (gate closed) the display pins to zero. ADC, pitch/
    // VAD, capture and scoring keep the raw samples -- display path only.
    localparam [15:0] NF_MIN = 16'd300;
    reg signed [15:0] d1_t, d2_t, d3_t, d4_t, d1_c, d2_c, d3_c, d4_c;
    reg signed [17:0] sm_t, sm_c;          // 4-sample sum = average*4
    reg [15:0] nf_t, nf_c;                 // adaptive noise floors
    reg signed [4:0] gc_t, gc_c;           // gate counter (+high, -low)
    reg vg_t, vg_c;
    reg [7:0] boot_t, boot_c;              // floor-learning clamp after reset
    reg [11:0] dec_t, dec_c;               // slow floor decay divider
    wire [15:0] abs_t = teacher_sample[15] ? (-teacher_sample) : teacher_sample;
    wire [15:0] abs_c = child_sample[15]  ? (-child_sample)  : child_sample;
    wire quiet_zero_t = !vg_t && (abs_t < nf_t + (nf_t >> 2));
    wire quiet_zero_c = !vg_c && (abs_c < nf_c + (nf_c >> 2));
    // voice-gated display gain x4 (Q5): speech is big and clear once the
    // gate opens; silence and sub-floor noise stay pinned at zero.
    wire signed [17:0] disp_amp_t = {{2{sm_t[17]}}, sm_t[17:2]} <<< 2;
    wire signed [17:0] disp_amp_c = {{2{sm_c[17]}}, sm_c[17:2]} <<< 2;
    // 0.5 s hangover so the trace does not flicker between words.
    // The tracker's voiced flags are pipelined once here: their direct
    // fanout into the display logic created sub-ns paths that failed hold
    // at two placement seeds (gate timing is frame-scale; one clock of
    // latency is immaterial).
    reg vg_c_q, vg_t_q;
    reg [5:0] hang_c, hang_t;
    wire signed [7:0] disp_t = (hang_t != 6'd0) ? scale_sample(disp_amp_t[17:2]) :
                               quiet_zero_t ? 8'sd0 : scale_sample(sm_t[17:2]);
    wire signed [7:0] disp_c = (hang_c != 6'd0) ? scale_sample(disp_amp_c[17:2]) :
                               quiet_zero_c ? 8'sd0 : scale_sample(sm_c[17:2]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_t<=0; d2_t<=0; d3_t<=0; d4_t<=0; d1_c<=0; d2_c<=0; d3_c<=0; d4_c<=0;
            sm_t<=18'sd0; sm_c<=18'sd0;
            nf_t<=NF_MIN; nf_c<=NF_MIN;
            gc_t<=5'sd0; gc_c<=5'sd0;
            vg_t<=1'b0; vg_c<=1'b0;
            boot_t<=8'd255; boot_c<=8'd255;
            dec_t<=12'd0; dec_c<=12'd0;
        end else begin
            if (sample_valid_b) begin
                d1_t<=teacher_sample; d2_t<=d1_t; d3_t<=d2_t; d4_t<=d3_t;
                sm_t <= {{2{teacher_sample[15]}},teacher_sample}
                      + {{2{d1_t[15]}},d1_t} + {{2{d2_t[15]}},d2_t}
                      + {{2{d3_t[15]}},d3_t};
                if (boot_t != 8'd0) begin
                    boot_t <= boot_t - 8'd1;
                    gc_t <= 5'sd0; vg_t <= 1'b0;
                    if (abs_t > nf_t) nf_t <= nf_t + ((abs_t - nf_t) >> 3);
                end else begin
                    if (!vg_t) begin
                        if (abs_t > nf_t)
                            nf_t <= nf_t + ((abs_t - nf_t) >> 8);
                        else if (dec_t == 12'd0 && nf_t > NF_MIN)
                            nf_t <= nf_t - 16'd1;
                    end
                    if (abs_t > nf_t + (nf_t >> 2))
                        gc_t <= (gc_t >= 5'sd4)  ? 5'sd4  : gc_t + 5'sd1;
                    else if (abs_t < nf_t - (nf_t >> 2))
                        gc_t <= (gc_t <= -5'sd9) ? -5'sd9 : gc_t - 5'sd1;
                    // 1.0x..1.25x band holds the counter: hysteresis gap
                    vg_t <= (gc_t >= 5'sd2) ? 1'b1 :
                            (gc_t <= -5'sd8) ? 1'b0  : vg_t;
                end
                dec_t <= (dec_t == 12'd4095) ? 12'd0 : dec_t + 12'd1;
            end
            if (sample_valid) begin
                d1_c<=child_sample; d2_c<=d1_c; d3_c<=d2_c; d4_c<=d3_c;
                sm_c <= {{2{child_sample[15]}},child_sample}
                      + {{2{d1_c[15]}},d1_c} + {{2{d2_c[15]}},d2_c}
                      + {{2{d3_c[15]}},d3_c};
                if (boot_c != 8'd0) begin
                    boot_c <= boot_c - 8'd1;
                    gc_c <= 5'sd0; vg_c <= 1'b0;
                    if (abs_c > nf_c) nf_c <= nf_c + ((abs_c - nf_c) >> 3);
                end else begin
                    if (!vg_c) begin
                        if (abs_c > nf_c)
                            nf_c <= nf_c + ((abs_c - nf_c) >> 8);
                        else if (dec_c == 12'd0 && nf_c > NF_MIN)
                            nf_c <= nf_c - 16'd1;
                    end
                    if (abs_c > nf_c + (nf_c >> 2))
                        gc_c <= (gc_c >= 5'sd4)  ? 5'sd4  : gc_c + 5'sd1;
                    else if (abs_c < nf_c - (nf_c >> 2))
                        gc_c <= (gc_c <= -5'sd9) ? -5'sd9 : gc_c - 5'sd1;
                    vg_c <= (gc_c >= 5'sd2) ? 1'b1 :
                            (gc_c <= -5'sd8) ? 1'b0  : vg_c;
                end
                dec_c <= (dec_c == 12'd4095) ? 12'd0 : dec_c + 12'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 10'd0; teacher_wp<=0;
            tch_hold <= 8'sd0;
            hang_c <= 6'd0; hang_t <= 6'd0; vg_c_q <= 1'b0; vg_t_q <= 1'b0;
        end else begin
            if (sample_valid_b) begin
                tch_hold <= disp_t;
                teacher_wp <= (teacher_wp == COLS-1) ? 0 : teacher_wp+1'b1;
            end
            if (sample_valid)
                wp <= (wp == COLS - 1) ? 10'd0 : wp + 1'b1;
            vg_c_q <= voice_gate_c_i; vg_t_q <= voice_gate_t_i;
            if (vg_c_q) hang_c <= 6'd30;
            else if (window_tick && hang_c != 6'd0) hang_c <= hang_c - 6'd1;
            if (vg_t_q) hang_t <= 6'd30;
            else if (window_tick && hang_t != 6'd0) hang_t <= hang_t - 6'd1;
        end
    end

    // RAM port logic outside the reset process so TD infers block RAM
    reg [15:0] wave_q;
    always @(posedge clk) begin
        if (sample_valid) child_wave[wp] <= disp_c;
        if (SINGLE_MIC != 0) begin
            if(sample_valid_b) teacher_wave[teacher_wp] <= disp_t;
        end else if(sample_valid) teacher_wave[wp] <= tch_hold;
        wave_q <= {child_wave[rd_addr], teacher_wave[(SINGLE_MIC != 0) ? teacher_rd_addr : rd_addr]};
    end

    // ------------------------------------------------------------ spectrum
    generate
        if (SPEC_MODE == 2) begin : g_spec_both
            goertzel_8band #(.N(260)) u_spec_child (
                .clk(clk), .rst_n(rst_n), .sample_valid(sample_valid),
                .sample(child_sample), .frame_tick(window_tick),
                .bands(child_bands), .bands_valid()
            );
            goertzel_8band #(.N(260)) u_spec_teacher (
                .clk(clk), .rst_n(rst_n), .sample_valid(sample_valid_b),
                .sample(teacher_sample), .frame_tick(window_tick),
                .bands(teacher_bands), .bands_valid()
            );
        end else if (SPEC_MODE == 1) begin : g_spec_one
            // one datapath, switched to whichever mic is on display
            wire [63:0] sel_bands;
            goertzel_8band #(.N(260)) u_spec (
                .clk(clk), .rst_n(rst_n),
                .sample_valid(spec_sel ? sample_valid_b : sample_valid),
                .sample(spec_sel ? teacher_sample : child_sample),
                .frame_tick(window_tick),
                .bands(sel_bands), .bands_valid()
            );
            assign child_bands = spec_sel ? 64'd0 : sel_bands;
            assign teacher_bands = spec_sel ? sel_bands : 64'd0;
        end else begin : g_spec_none
            assign child_bands = 64'd0;
            assign teacher_bands = 64'd0;
        end
    endgenerate
    // latched once per frame, so a window closing mid-screen cannot tear
    reg [63:0] ch_bands_f, tc_bands_f;

    // ------------------------------------------------------------ raster position
    // The console drives a free-running stream: one beat per active pixel,
    // in_user marks the first pixel of a frame, in_last the last of a line.
    reg [9:0] px;
    reg [9:0] py;
    wire [9:0] cur_x = in_user ? 10'd0 : px;
    wire [9:0] cur_y = in_user ? 10'd0 : py;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px <= 10'd0; py <= 10'd0;
            wp_frame <= 10'd0; teacher_wp_frame<=0;
            ch_bands_f <= 64'd0; tc_bands_f <= 64'd0;
        end else if (in_valid) begin
            if (in_last) begin
                px <= 10'd0;
                py <= cur_y + 1'b1;
            end else begin
                px <= cur_x + 1'b1;
                py <= cur_y;
            end
            if (in_user) begin
                wp_frame <= wp; teacher_wp_frame <= teacher_wp;
                ch_bands_f <= child_bands;
                tc_bands_f <= teacher_bands;
            end
        end
    end

    // scrolling column lookup: display column 0 is the oldest sample. The
    // address is combinational, so wave_q lines up with the stage 1 beat.
    wire [10:0] col_raw = {1'b0, wp_frame} + ({1'b0, cur_x} - X0);
    wire [10:0] col_wrap = (col_raw >= COLS) ? (col_raw - COLS) : col_raw;
    wire [9:0] rd_addr = col_wrap[9:0];
    wire [10:0] teacher_col={1'b0,teacher_wp_frame}+({1'b0,cur_x}-X0);
    wire [9:0] teacher_rd_addr=(teacher_col>=COLS)?teacher_col-COLS:teacher_col[9:0];

    // bar position tracks the input beat
    localparam integer BARP_BITS = $clog2(BAR_PITCH);
    reg [3:0] bar_i;   // only BARS of these are used
    reg [BARP_BITS-1:0] bar_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bar_i <= 4'd0; bar_p <= 0;
        end else if (in_valid) begin
            if (cur_x == X0 - 1 || in_last) begin
                bar_i <= 4'd0; bar_p <= 0;
            end else if (bar_p == BAR_PITCH - 1) begin
                bar_p <= 0;
                bar_i <= bar_i + 1'b1;
            end else begin
                bar_p <= bar_p + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ stage 1
    reg        s1_valid, s1_user, s1_last;
    reg [23:0] s1_data;
    reg [9:0]  s1_x, s1_y;
    reg [3:0]  s1_bar_i;
    reg [BARP_BITS-1:0] s1_bar_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0; s1_user <= 1'b0; s1_last <= 1'b0;
            s1_data <= 24'd0; s1_x <= 10'd0; s1_y <= 10'd0;
            s1_bar_i <= 4'd0; s1_bar_p <= 0;
        end else begin
            s1_valid <= in_valid;
            s1_user <= in_user;
            s1_last <= in_last;
            s1_data <= in_data;
            s1_x <= cur_x;
            s1_y <= cur_y;
            s1_bar_i <= bar_i;
            s1_bar_p <= bar_p;
        end
    end

    // ------------------------------------------------------------ render (stage 1)
    localparam integer PANEL_TOP = 46;
    localparam integer PANEL_BOT = 285;
    wire signed [7:0] cv = $signed(wave_q[15:8]);
    wire signed [7:0] tv = $signed(wave_q[7:0]);
    // previous display column, so the trace is a connected line and not dots
    reg signed [7:0] cv_prev, tv_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cv_prev <= 8'sd0; tv_prev <= 8'sd0;
        end else if (s1_valid) begin
            cv_prev <= cv;
            tv_prev <= tv;
        end
    end
    wire first_col = s1_x == X0;
    wire signed [7:0] cv_a = first_col ? cv : cv_prev;
    wire signed [7:0] tv_a = first_col ? tv : tv_prev;
    // screen y grows downward, so a positive sample is a smaller y
    wire signed [10:0] ch_hi = CH_MID - ((cv > cv_a) ? cv : cv_a);
    wire signed [10:0] ch_lo = CH_MID - ((cv > cv_a) ? cv_a : cv);
    wire signed [10:0] tc_hi = TC_MID - ((tv > tv_a) ? tv : tv_a);
    wire signed [10:0] tc_lo = TC_MID - ((tv > tv_a) ? tv_a : tv);
    wire [10:0] y_s = {1'b0, s1_y};
    wire in_panel_x = (s1_x >= X0) && (s1_x < X0 + COLS);
    wire in_panel = enable && in_panel_x &&
                    (s1_y >= PANEL_TOP) && (s1_y <= PANEL_BOT);
    wire ch_trace = $signed(y_s) >= ch_hi && $signed(y_s) <= ch_lo;
    wire tc_trace = $signed(y_s) >= tc_hi && $signed(y_s) <= tc_lo;
    wire ch_mid_line = s1_y == CH_MID;
    wire tc_mid_line = s1_y == TC_MID;

    // spectrum bars. SPEC_MODE 2: child 0..7 then teacher 8..15.
    // SPEC_MODE 1: eight bars of the selected mic across the whole panel.
    wire bar_is_teacher = (SPEC_MODE == 2) ? s1_bar_i[3] : spec_sel;
    wire [7:0] eq_sel = bar_is_teacher ? tc_bands_f[{s1_bar_i[2:0], 3'b000} +: 8]
                                       : ch_bands_f[{s1_bar_i[2:0], 3'b000} +: 8];
    // 0..255 -> 0..103 px with shifts only (x13 >> 5)
    wire [11:0] bar_scaled = {1'b0, eq_sel, 3'b000} + {2'b00, eq_sel, 2'b00} +
                             {4'b0000, eq_sel};
    wire [6:0] bar_h = bar_scaled[11:5];
    wire in_bar_x = s1_bar_p < BAR_W;
    wire bar_fill = (SPEC_MODE != 0) && in_bar_x && (s1_y <= SPEC_BASE) &&
                    (s1_y > SPEC_BASE - bar_h);
    wire spec_base_line = s1_y == SPEC_BASE;
    wire spec_region = (SPEC_MODE != 0) &&
                       (s1_y >= SPEC_TOP) && (s1_y <= SPEC_BASE);

    wire [23:0] scope_rgb =
        spec_region ? (bar_fill ? (bar_is_teacher ? COL_TCH : COL_CHILD) :
                       spec_base_line ? COL_GRID : COL_BG) :
        ch_trace ? COL_CHILD :
        tc_trace ? COL_TCH :
        (ch_mid_line || tc_mid_line) ? COL_GRID : COL_BG;

    // The stream leaves through logic, not through a flop one hop from the
    // HDMI core: a zero-logic register-to-register hop there loses to clock
    // skew on this device (14 hold endpoints at -0.07 ns on the first build).
    // All four outputs come off the same stage, so they stay in step.
    assign out_valid = s1_valid;
    assign out_user = s1_user;
    assign out_last = s1_last;
    assign out_data = in_panel ? scope_rgb : s1_data;
endmodule

