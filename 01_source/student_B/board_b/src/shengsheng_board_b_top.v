`timescale 1ns/1ps

// ShengSheng speech-training screen top, BOARD B of the R78 dual-board
// architecture (docs/01). Built on the ProMax player: TF/FAT32/BMP ingest,
// SDRAM frame store, HDMI video+audio, fades/wipes, 2:1 scaling, OSD, plus
// tone scorer, model-voice synthesiser, training game and training-screen
// overlay.
//
// Board role split: the microphone front end and the YIN pitch tracker moved
// to Board A (board_a/src/shengsheng_board_a_top.v), which streams one
// 15-byte v5 dual-player feature frame per video frame over 921600-8N1
// (feature_packer v5, docs/10 section 3).
// This board decodes them with uart_rx_feature and feeds the rebuilt
// {voiced, pitch_q4, level} into the scorer and game in place of the single
// board's trk_* signals. Tone classification happens INSIDE the Board-B
// tone_scorer: its per-utterance features (f_rng/f_delta/f_dip/f_tail/
// argmin, bit-exact with the golden model the LUT was trained on) address
// the trained 32768-entry lookup_classifier, and a LUT abstain now cascades
// LUT -> NB -> DTW. Rebuilding the features anywhere else -- e.g. from the
// raw pitch stream -- would use a different feature definition than training
// did and silently misclassify. The score UART TX to the PC keeps 115200 and
// uses the v5 reporter variant with the N=/D=/F= verdict/formant fields
// (ss_score_reporter_b).
//
// Controls
//   KEY2 short   display: next picture      training: next question
//   KEY2 hold 1s display: transition style (rotate -> fade -> push up -> push down)
//   KEY3 short   display: auto slideshow    training: replay the model voice
//   KEY3 hold 1s cycle modes: display -> tone climb -> balloon -> train -> cards
//   KEY4 short   volume ladder              KEY4 hold 1s  period / difficulty
//                (display mode with SW3 up: picture contrast 50..150 %)
//   SW1/SW2 brightness, SW3 high contrast, SW4 teacher mode
// Any adjustment raises the V8 parameter panel (osd_param_panel_v8) for 3 s.
// Display mode also shows the V8 caption layer (osd_caption_layer_v8):
// picture title, running time and a scrolling slogan band.
// CUT 2026-10-17 (spec_cut_20261017): the live 16-band spectrum of the music
// (spectrum_analyzer_v8 -> osd_spectrum_v8) is removed to buy pixel-chain
// headroom; the audio path that fed it (pcm_media_music_v8 -> the HDMI audio
// packetiser) is untouched and still plays.
// The music itself is pcm_media_music_v8: each picture's
// V7 melody over a bass/pad chord and a short noise hat.
// Settings start from defaults at power-up (volume 192, 5 s period = medium
// difficulty, auto slideshow on). The ProMax Flash persistence block was
// removed to make room for the speech-training logic (R69).
module shengsheng_board_b_top (
    input  wire       sys_clk,
    input  wire       sys_rst_n,
    input  wire       key2_n,
    input  wire       key3_n,
    input  wire       key4_n,
    input  wire [3:0] sw,
    input  wire       uart_rx_i,          // 921600-8N1 v6 feature stream from Board A (J2-2)
    output wire       link_tx_o,          // 921600-8N1 return packets to Board A (J2-1)
    output wire       uart_tx_o,
    output wire       sd_cs_n,
    output wire       sd_sclk,
    output wire       sd_mosi,
    input  wire       sd_miso,
    input  wire       flash_miso,
    output wire       flash_cs_n,
    output wire       flash_sclk,
    output wire       flash_mosi,
    output wire       flash_wp_n,
    output wire       flash_hold_n,
    output wire       HDMI_CLK_P,
    output wire       HDMI_D2_P,
    output wire       HDMI_D1_P,
    output wire       HDMI_D0_P,
    output wire [3:0] led,
    // P0 board-mounted peripherals (docs/08 section 5)
    output wire [7:0] seg_led,
    output wire [7:0] seg_sel,
    output wire       spk
);
    // U33 data Flash is unused on B. Never leave active-low control pins
    // floating; teacher-side journal owns persistence on A only.
    assign flash_cs_n=1'b1;
    assign flash_sclk=1'b0;
    assign flash_mosi=1'b1;
    assign flash_wp_n=1'b1;
    assign flash_hold_n=1'b1;
    // PITCH_LEVEL_THR lived here in the single-board build as the YIN gating
    // threshold; the level gate now runs on Board A next to the tracker.

    wire pixel_clk_5x_feedback;
    wire pixel_clk_5x;
    wire pixel_clk;
    wire mem_clk;
    wire mem_clk_shift;
    wire mem_locked;
    sys_pll_promax_40 u_mem_pll (
        .refclk(sys_clk), .reset(~sys_rst_n),
        .clk0_out(pixel_clk_5x_feedback), .clk1_out(mem_clk),
        .clk2_out(mem_clk_shift), .clk3_out(pixel_clk),
        .clk4_out(pixel_clk_5x),
        .locked(mem_locked)
    );
    wire video_locked = mem_locked;

    wire mem_rst_n;
    wire pix_rst_n;
    wire pix_5x_rst_n;
    wire ctrl_rst_n;
    reset_sync u_mem_reset (
        .clk(mem_clk), .ext_rst_n(sys_rst_n & mem_locked),
        .rst_n_sync(mem_rst_n)
    );
    reset_sync u_pix_reset (
        .clk(pixel_clk), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(pix_rst_n)
    );
    reset_sync u_pix_5x_reset (
        .clk(pixel_clk_5x), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(pix_5x_rst_n)
    );
    reset_sync u_ctrl_reset (
        .clk(sys_clk), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(ctrl_rst_n)
    );

    // ------------------------------------------------------ SDRAM + ingest
    wire sdram_init_done;
    wire sdram_refresh_active;
    wire sdram_busy;
    wire ingest_app_wr_en_sys;
    wire [20:0] ingest_app_wr_addr_sys;
    wire [3:0] ingest_app_wr_mask_sys;
    wire [31:0] ingest_app_wr_data_sys;
    wire sdram_app_wr_en;
    wire [20:0] sdram_app_wr_addr;
    wire [3:0] sdram_app_wr_mask;
    wire [31:0] sdram_app_wr_data;
    wire player_app_rd_en;
    wire [20:0] player_app_rd_addr;
    wire sdram_rd_valid;
    wire [31:0] sdram_rd_data;

    sdram u_sdram (
        .Clk(mem_clk), .Clk_sft(mem_clk_shift), .Rst(~mem_rst_n),
        .Sdr_init_done(sdram_init_done),
        .Sdr_init_ref_vld(sdram_refresh_active), .Sdr_busy(sdram_busy),
        .App_wr_en(sdram_app_wr_en), .App_wr_addr(sdram_app_wr_addr),
        .App_wr_dm(sdram_app_wr_mask), .App_wr_din(sdram_app_wr_data),
        .App_rd_en(player_app_rd_en), .App_rd_addr(player_app_rd_addr),
        .Sdr_rd_en(sdram_rd_valid), .Sdr_rd_dout(sdram_rd_data)
    );

    wire sdram_init_done_sys;
    wire sdram_busy_sys;
    wire sdram_refresh_sys;
    sync_2ff u_sdram_init_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(sdram_init_done), .sync_out(sdram_init_done_sys)
    );
    sync_2ff u_sdram_busy_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(sdram_busy), .sync_out(sdram_busy_sys)
    );
    sync_2ff u_sdram_refresh_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(sdram_refresh_active), .sync_out(sdram_refresh_sys)
    );

    reg ingest_start;
    reg ingest_started;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            ingest_start <= 1'b0;
            ingest_started <= 1'b0;
        end else begin
            ingest_start <= 1'b0;
            if (sdram_init_done_sys && !ingest_started) begin
                ingest_start <= 1'b1;
                ingest_started <= 1'b1;
            end
        end
    end

    wire ingest_busy;
    wire ingest_done;
    wire [2:0] ingest_error_stage;
    wire [7:0] ingest_error_code;
    wire [7:0] ingest_error_detail;
    wire card_ready;
    wire card_high_capacity;
    wire [3:0] resource_valid;
    wire [3:0] image_complete;
    wire [3:0] image_failed;
    wire storage_load_fatal;
    wire [3:0] image_scale_2x;
    reg [3:0] sw_stable;
    wire write_cdc_full;
    wire write_cdc_overflow;
    wire write_cdc_idle_mem;
    media_storage_ingest_top #(
        .ALLOW_2X_SOURCE(1)
    ) u_storage_ingest (
        .clk(sys_clk), .rst_n(ctrl_rst_n), .start(ingest_start),
        .busy(ingest_busy), .done(ingest_done),
        .error_stage(ingest_error_stage), .error_code(ingest_error_code),
        .error_detail(ingest_error_detail), .card_ready(card_ready),
        .card_high_capacity(card_high_capacity),
        .resource_valid(resource_valid), .image_complete(image_complete),
        .image_failed(image_failed), .load_fatal(storage_load_fatal),
        .image_scale_2x(image_scale_2x),
        .diagnostic_select(3'd0), .diagnostic_data(),
        .controller_init_done(sdram_init_done_sys && !write_cdc_full),
        .controller_busy(sdram_busy_sys), .refresh_active(sdram_refresh_sys),
        .app_wr_en(ingest_app_wr_en_sys),
        .app_wr_addr(ingest_app_wr_addr_sys),
        .app_wr_mask(ingest_app_wr_mask_sys),
        .app_wr_data(ingest_app_wr_data_sys),
        .sd_cs_n(sd_cs_n), .sd_sclk(sd_sclk),
        .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    media_sdram_write_cdc u_write_cdc (
        .src_clk(sys_clk), .src_rst_n(ctrl_rst_n),
        .src_wr_en(ingest_app_wr_en_sys),
        .src_wr_addr(ingest_app_wr_addr_sys),
        .src_wr_mask(ingest_app_wr_mask_sys),
        .src_wr_data(ingest_app_wr_data_sys),
        .src_full(write_cdc_full), .src_overflow(write_cdc_overflow),
        .dst_clk(mem_clk), .dst_rst_n(mem_rst_n),
        .dst_app_wr_en(sdram_app_wr_en),
        .dst_app_wr_addr(sdram_app_wr_addr),
        .dst_app_wr_mask(sdram_app_wr_mask),
        .dst_app_wr_data(sdram_app_wr_data),
        .dst_idle(write_cdc_idle_mem)
    );

    reg ingest_finished_sys;
    reg storage_error_source_sys;
    // F6: a card that lost one picture is degraded, not broken. The player
    // runs on whatever loaded; this flag only drives the status readout.
    reg media_partial_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            ingest_finished_sys <= 1'b0;
            storage_error_source_sys <= 1'b0;
            media_partial_sys <= 1'b0;
        end else begin
            if (write_cdc_overflow)
                storage_error_source_sys <= 1'b1;
            if (ingest_done) begin
                ingest_finished_sys <= 1'b1;
                if (storage_load_fatal || image_complete == 4'd0)
                    storage_error_source_sys <= 1'b1;
                else if (ingest_error_stage != 0 || ingest_error_code != 0 ||
                         image_failed != 4'd0 || image_complete != 4'hf)
                    media_partial_sys <= 1'b1;
            end
        end
    end

    wire ingest_finished_mem;
    wire storage_error_source_mem;
    wire [3:0] image_complete_mem;
    sync_2ff u_ingest_finished_mem (
        .clk(mem_clk), .rst_n(mem_rst_n),
        .async_in(ingest_finished_sys), .sync_out(ingest_finished_mem)
    );
    sync_2ff u_storage_error_source_mem (
        .clk(mem_clk), .rst_n(mem_rst_n),
        .async_in(storage_error_source_sys),
        .sync_out(storage_error_source_mem)
    );
    genvar image_mem_bit;
    generate
        for (image_mem_bit = 0; image_mem_bit < 4;
             image_mem_bit = image_mem_bit + 1) begin : g_image_mem_sync
            sync_2ff u_sync (
                .clk(mem_clk), .rst_n(mem_rst_n),
                .async_in(image_complete[image_mem_bit]),
                .sync_out(image_complete_mem[image_mem_bit])
            );
        end
    endgenerate

    reg player_enable_mem;
    reg storage_error_mem;
    reg [4:0] write_drain_count_mem;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            player_enable_mem <= 1'b0;
            storage_error_mem <= 1'b0;
            write_drain_count_mem <= 0;
        end else if (ingest_finished_mem && !player_enable_mem &&
                     !storage_error_mem) begin
            // F6: start on any non-empty playlist; empty banks stay black and
            // media_player_control skips them.
            if (storage_error_source_mem || image_complete_mem == 4'd0) begin
                storage_error_mem <= 1'b1;
            end else if (!write_cdc_idle_mem) begin
                write_drain_count_mem <= 0;
            end else if (write_drain_count_mem == 5'd31) begin
                player_enable_mem <= 1'b1;
            end else begin
                write_drain_count_mem <= write_drain_count_mem + 1'b1;
            end
        end
    end

    // ------------------------------------------------------ keys, switches, config
    wire key2_press;
    wire key2_long_press;
    wire key3_press;
    wire key3_long_press;
    wire config_save_event;
    wire config_save_locked;
    wire auto_enabled;
    // subtitle: 「声声:看见自己的声音」 (glyph tokens 0x80..0x86, see tools/shengsheng/make_cn16.py)
    localparam [95:0] DEFAULT_SUBTITLE_TEXT = {8'h00,8'h00,8'h86,8'h80,8'h85,8'h84,8'h83,8'h82,8'h81,8'h3a,8'h80,8'h80};
    wire [95:0] subtitle_text_sys = DEFAULT_SUBTITLE_TEXT;
    wire [5:0] subtitle_length_sys = 6'd10;
    // The scrolling slogan duplicated the brand phrase the training overlay
    // already renders in the top band. Dropping it removes the nine 16x16
    // glyph tables from promax_text_overlay, which was the cheapest ~10% of
    // that module; the parameter line below is kept.
    wire subtitle_enable_sys = 1'b0;

    dual_key_chord_router #(
        .DEBOUNCE_CYCLES(1000000),
        .HOLD_CYCLES(100000000),
        .KEY3_LONG_CYCLES(50000000),
        .KEY2_LONG_CYCLES(50000000)
    ) u_key_router (
        .clk(sys_clk), .rst_n(ctrl_rst_n), .save_enabled(1'b0),
        .key2_n(key2_n), .key3_n(key3_n), .key2_event(key2_press),
        .key3_event(key3_press), .key3_long_event(key3_long_press),
        .key2_long_event(key2_long_press),
        .save_event(config_save_event),
        .save_locked(config_save_locked), .key2_stable_n(),
        .key3_stable_n()
    );

    // mode: 0 display, 1 tone climb, 2 balloon, 3 loudness train, 4 cards
    reg [2:0] mode_sys;
    reg mode_toggle;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            mode_sys <= 3'd0;
            mode_toggle <= 1'b0;
        end else if (key3_long_press) begin
            mode_sys <= (mode_sys == 3'd5) ? 3'd0 : mode_sys + 1'b1;
            mode_toggle <= ~mode_toggle;
        end
    end
    wire display_mode_sys = (mode_sys == 3'd0);

    // board switches (manual: up = 1), debounced by a 2FF + 20 ms agree filter
    reg [1:0] sw_s1, sw_s2;
    reg [3:0] sw_meta, sw_sync;
    reg [19:0] sw_count;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            sw_meta <= 4'd0; sw_sync <= 4'd0; sw_stable <= 4'd0; sw_count <= 20'd0;
        end else begin
            sw_meta <= sw;
            sw_sync <= sw_meta;
            if (sw_sync == sw_stable)
                sw_count <= 20'd0;
            else if (sw_count == 20'd999999) begin
                sw_stable <= sw_sync;
                sw_count <= 20'd0;
            end else
                sw_count <= sw_count + 1'b1;
        end
    end
    wire [1:0] brightness_level = sw_stable[1:0];
    wire high_contrast_sys = sw_stable[2];
    wire teacher_sys = sw_stable[3];

    function [7:0] brightness_value;
        input [1:0] level;
        begin
            case (level)
                2'd0: brightness_value = 8'd255;
                2'd1: brightness_value = 8'd192;
                2'd2: brightness_value = 8'd128;
                default: brightness_value = 8'd64;
            endcase
        end
    endfunction
    wire [7:0] brightness_sys = brightness_value(brightness_level);
    reg [1:0] brightness_level_q;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            brightness_level_q <= 2'd0;
        else
            brightness_level_q <= brightness_level;
    end
    wire bright_evt = (brightness_level != brightness_level_q);
    // V8: flipping SW3 in display mode shows what the KEY4 short press now
    // adjusts -- the contrast level (SW3 up) or the volume (SW3 down)
    reg high_contrast_q;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            high_contrast_q <= 1'b0;
        else
            high_contrast_q <= high_contrast_sys;
    end
    wire contrast_sel_evt = (high_contrast_sys != high_contrast_q) && display_mode_sys;

    reg [7:0] config_volume;            // live settings, see below
    reg [31:0] config_period_ms;
    wire menu_cfg_valid;
    wire [31:0] menu_cfg_period;
    wire [7:0] menu_cfg_volume;
    wire menu_evt;
    wire [1:0] menu_kind;
    wire [1:0] base_difficulty_sys;
    wire [2:0] contrast_sys;

    param_menu_controller #(
        .CLKS_PER_MS(50000),
        .ENABLE_CONTRAST(1)
    ) u_param_menu (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .key4_n(key4_n), .service_ready(1'b1),
        .training_mode(!display_mode_sys), .difficulty(base_difficulty_sys),
        .live_volume(config_volume), .live_period_ms(config_period_ms),
        .contrast_select(high_contrast_sys && display_mode_sys),
        .contrast(contrast_sys),
        .cfg_update_valid(menu_cfg_valid),
        .cfg_period_ms(menu_cfg_period), .cfg_volume(menu_cfg_volume),
        .menu_event(menu_evt), .menu_kind(menu_kind), .menu_level()
    );

    // KEY2/KEY3 short presses belong to the slideshow only in display mode
    wire key2_display = key2_press && display_mode_sys;
    // a long KEY2 press in training still means "next question"
    wire key2_any = key2_press || (key2_long_press && !display_mode_sys);
    wire style_evt = key2_long_press && display_mode_sys;

    // V8 transition style, cycled by a long KEY2 press in display mode:
    // 3 rotate (default) -> 0 classic fade/wipe -> 1 push up -> 2 push down.
    // The step counter crosses into the pixel domain Gray-coded, so a change
    // never shows an intermediate style.
    reg [1:0] style_step_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            style_step_sys <= 2'd0;
        else if (style_evt)
            style_step_sys <= style_step_sys + 1'b1;
    end
    wire [1:0] style_gray_sys = style_step_sys ^ (style_step_sys >> 1);
    wire key3_display = key3_press && display_mode_sys;

    // live settings (no Flash persistence): volume and period ladders from
    // the KEY4 menu, plus a one-shot boot apply of the default period and
    // auto slideshow into the player control
    reg boot_apply_done;
    reg config_apply_valid;
    reg boot_auto_apply;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            config_volume <= 8'd192;
            config_period_ms <= 32'd5000;
            boot_apply_done <= 1'b0;
            config_apply_valid <= 1'b0;
            boot_auto_apply <= 1'b0;
        end else begin
            config_apply_valid <= 1'b0;
            boot_auto_apply <= 1'b0;
            if (!boot_apply_done) begin
                boot_apply_done <= 1'b1;
                config_apply_valid <= 1'b1;
                boot_auto_apply <= 1'b1;
            end else if (menu_cfg_valid) begin
                config_volume <= menu_cfg_volume;
                config_period_ms <= menu_cfg_period;
                config_apply_valid <= 1'b1;
            end
        end
    end
    wire [31:0] config_period_cycles =
        (config_period_ms >= 32'd20000) ? 32'd1500000000 :
        (config_period_ms >= 32'd7500)  ? 32'd500000000 :
        (config_period_ms >= 32'd3500)  ? 32'd250000000 : 32'd100000000;
    // Only the explicit boot pulse applies the default autoplay state. The
    // delayed menu configuration pulse must never resume a paused slideshow.

    // F3 badge display/persistence is DEFERRED (docs/19 D8): with F1+F2 the
    // place gate sits at ~4938 of 4900 mslices and neither the U33 journal
    // nor the medal row fits. The verified library units stay in the repo
    // (badge_journal.v + ss_badge_rom.v, both TB'd) for the board revision
    // or device change that frees the budget.

    // parameter line floats for 3 s after any adjustment (always on in teacher mode)
    reg [27:0] param_show_count;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            param_show_count <= 28'd0;
        else if (menu_evt || bright_evt || style_evt || contrast_sel_evt)
            param_show_count <= 28'd150000000;
        else if (param_show_count != 28'd0)
            param_show_count <= param_show_count - 1'b1;
    end
    wire param_recent_sys = (param_show_count != 28'd0);

    // V8 panel: which parameter changed last. The kind and the contrast
    // level are a held bus; panel_toggle_sys flips one clock after they
    // settle and the pixel domain samples them on the synchronised edge.
    reg [2:0] panel_kind_sys;
    reg panel_toggle_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            panel_kind_sys <= 3'd0;
            panel_toggle_sys <= 1'b0;
        end else begin
            if (style_evt)
                panel_kind_sys <= 3'd4;
            else if (menu_evt)
                panel_kind_sys <= (menu_kind == 2'd0) ? 3'd2 :
                                  (menu_kind == 2'd1) ? 3'd3 :
                                  (menu_kind == 2'd2) ? 3'd5 : 3'd1;
            else if (bright_evt)
                panel_kind_sys <= 3'd0;
            else if (contrast_sel_evt)
                panel_kind_sys <= high_contrast_sys ? 3'd1 : 3'd2;
            if (style_evt || menu_evt || bright_evt || contrast_sel_evt)
                panel_toggle_sys <= ~panel_toggle_sys;
        end
    end

    wire [3:0] image_complete_sys;
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1) begin : g_image_sync
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(image_complete[bit_index]),
                .sync_out(image_complete_sys[bit_index])
            );
        end
    endgenerate

    // F6: if PIC1 was skipped its bank is black, so step the playlist once
    // when ingest finishes -- the first thing on screen is then a real image.
    // The delay lets the per-bit image_complete synchronisers settle.
    reg [3:0] media_kick_wait;
    reg media_kick_done;
    reg media_kick_pulse;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            media_kick_wait <= 4'd0;
            media_kick_done <= 1'b0;
            media_kick_pulse <= 1'b0;
        end else begin
            media_kick_pulse <= 1'b0;
            if (!media_kick_done && ingest_finished_sys) begin
                if (media_kick_wait == 4'd8) begin
                    media_kick_done <= 1'b1;
                    if (!image_complete_sys[0] && image_complete_sys != 4'd0)
                        media_kick_pulse <= 1'b1;
                end else begin
                    media_kick_wait <= media_kick_wait + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------ video pipeline
    wire video_clk;
    wire video_hs;
    wire video_vs;
    wire video_de;
    wire [23:0] video_rgb;
    wire [9:0] video_x;
    wire [1:0] active_index;
    wire [1:0] pending_index;
    wire frame_start;
    wire reader_busy;
    wire reader_underflow;
    wire [7:0] video_error;

    wire [7:0] brightness_pix;
    genvar bright_bit;
    generate
        for (bright_bit = 0; bright_bit < 8; bright_bit = bright_bit + 1) begin : g_bright_sync
            sync_2ff u_sync (
                .clk(pixel_clk), .rst_n(pix_rst_n),
                .async_in(brightness_sys[bright_bit]),
                .sync_out(brightness_pix[bright_bit])
            );
        end
    endgenerate

    wire [1:0] style_gray_pix;
    sync_2ff u_style_sync0 (
        .clk(pixel_clk), .rst_n(pix_rst_n), .async_in(style_gray_sys[0]), .sync_out(style_gray_pix[0])
    );
    sync_2ff u_style_sync1 (
        .clk(pixel_clk), .rst_n(pix_rst_n), .async_in(style_gray_sys[1]), .sync_out(style_gray_pix[1])
    );
    // step 0..3 -> style 3, 0, 1, 2
    wire [1:0] style_step_pix = {style_gray_pix[1], style_gray_pix[1] ^ style_gray_pix[0]};
    wire [1:0] slide_style_pix = style_step_pix - 1'b1;

    reg [2:0] panel_t_pix;
    reg [2:0] panel_kind_pix;
    reg [2:0] contrast_pix;
    always @(posedge pixel_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            panel_t_pix <= 3'd0; panel_kind_pix <= 3'd0; contrast_pix <= 3'd2;
        end else begin
            panel_t_pix <= {panel_t_pix[1:0], panel_toggle_sys};
            if (panel_t_pix[2] ^ panel_t_pix[1]) begin
                panel_kind_pix <= panel_kind_sys;
                contrast_pix <= contrast_sys;
            end
        end
    end

    // goto requests from the game (video domain) enter the control domain as
    // a toggle; the index is held stable until the next toggle
    reg goto_toggle_video;
    reg [1:0] goto_index_video;
    reg goto_s1, goto_s2, goto_s3;
    reg goto_valid_sys;
    reg [1:0] goto_index_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            goto_s1 <= 1'b0; goto_s2 <= 1'b0; goto_s3 <= 1'b0;
            goto_valid_sys <= 1'b0; goto_index_sys <= 2'd0;
        end else begin
            goto_s1 <= goto_toggle_video;
            goto_s2 <= goto_s1;
            goto_s3 <= goto_s2;
            goto_valid_sys <= goto_s2 ^ goto_s3;
            if (goto_s2 ^ goto_s3)
                goto_index_sys <= goto_index_video;
        end
    end

    media_video_pipeline #(
        .FADE_FRAMES(16),
        .ENABLE_GOTO(1),
        .ENABLE_SLIDE(1),
        .ENABLE_CONTRAST(1)
    ) u_video (
        .brightness(brightness_pix),
        .contrast(contrast_pix),
        .slide_style(slide_style_pix), .slide_busy(),
        .ctrl_clk(sys_clk), .ctrl_rst_n(ctrl_rst_n),
        .next_event(key2_display || media_kick_pulse),
        .toggle_auto_event(key3_display),
        .period_cfg_valid(config_apply_valid),
        .period_cfg_cycles(config_period_cycles),
        .auto_cfg_valid(boot_auto_apply),
        .auto_cfg_enabled(1'b1),
        .image_complete(image_complete_sys),
        .goto_valid(goto_valid_sys), .goto_index(goto_index_sys),
        .auto_hold(!display_mode_sys),
        .player_enable(player_enable_mem), .mem_clk(mem_clk),
        .mem_rst_n(mem_rst_n), .controller_init_done(sdram_init_done),
        .controller_busy(sdram_busy), .refresh_active(sdram_refresh_active),
        .app_rd_en(player_app_rd_en), .app_rd_addr(player_app_rd_addr),
        .sdram_rd_valid(sdram_rd_valid), .sdram_rd_data(sdram_rd_data),
        .pix_clk(pixel_clk), .pix_rst_n(pix_rst_n),
        .video_clk(video_clk), .video_hs(video_hs),
        .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb), .video_x(video_x),
        .active_index(active_index),
        .pending_index(pending_index), .auto_enabled(auto_enabled),
        .frame_start(frame_start), .reader_busy(reader_busy),
        .reader_underflow(reader_underflow), .video_error(video_error)
    );

    // slow control values into the video domain
    wire [1:0] active_index_video;
    wire [7:0] volume_video;
    wire [31:0] period_video;
    genvar media_bit;
    generate
        for (media_bit = 0; media_bit < 2; media_bit = media_bit + 1) begin : g_media_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(active_index[media_bit]),
                .sync_out(active_index_video[media_bit])
            );
        end
    endgenerate
    genvar period_bit;
    generate
        for (period_bit = 0; period_bit < 32; period_bit = period_bit + 1) begin : g_period_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(config_period_ms[period_bit]),
                .sync_out(period_video[period_bit])
            );
        end
    endgenerate
    generate
        for (media_bit = 0; media_bit < 8; media_bit = media_bit + 1) begin : g_volume_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(config_volume[media_bit]),
                .sync_out(volume_video[media_bit])
            );
        end
    endgenerate
    wire teacher_video, high_contrast_video, param_recent_video;
    sync_2ff u_teacher_sync (
        .clk(video_clk), .rst_n(pix_rst_n), .async_in(teacher_sys), .sync_out(teacher_video)
    );
    sync_2ff u_contrast_sync (
        .clk(video_clk), .rst_n(pix_rst_n), .async_in(high_contrast_sys),
        .sync_out(high_contrast_video)
    );
    sync_2ff u_param_sync (
        .clk(video_clk), .rst_n(pix_rst_n), .async_in(param_recent_sys),
        .sync_out(param_recent_video)
    );

    // mode and key events into the video domain (toggle + held bus)
    reg key2_toggle, key3_toggle;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            key2_toggle <= 1'b0; key3_toggle <= 1'b0;
        end else begin
            if (key2_any && !display_mode_sys) key2_toggle <= ~key2_toggle;
            if (key3_press && !display_mode_sys) key3_toggle <= ~key3_toggle;
        end
    end
    reg [2:0] mode_t_v, key2_t_v, key3_t_v;
    reg [2:0] mode_video;
    reg key_next_video, key_replay_video;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            mode_t_v <= 3'd0; key2_t_v <= 3'd0; key3_t_v <= 3'd0;
            mode_video <= 3'd0; key_next_video <= 1'b0; key_replay_video <= 1'b0;
        end else begin
            mode_t_v <= {mode_t_v[1:0], mode_toggle};
            key2_t_v <= {key2_t_v[1:0], key2_toggle};
            key3_t_v <= {key3_t_v[1:0], key3_toggle};
            if (mode_t_v[2] ^ mode_t_v[1])
                mode_video <= mode_sys;
            key_next_video <= key2_t_v[2] ^ key2_t_v[1];
            key_replay_video <= key3_t_v[2] ^ key3_t_v[1];
        end
    end
    // Atomic held-bus update: synchronize the event toggle, then sample the
    // independent difficulty after two settling clocks (never derive it from period).
    reg difficulty_toggle_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if(!ctrl_rst_n) difficulty_toggle_sys<=0;
        else if(menu_evt && menu_kind==2) difficulty_toggle_sys<=~difficulty_toggle_sys;
    end
    reg [2:0] difficulty_event_sync;
    reg [1:0] difficulty_video;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) begin difficulty_event_sync<=0; difficulty_video<=2'd1; end
        else begin
            difficulty_event_sync<={difficulty_event_sync[1:0],difficulty_toggle_sys};
            if(difficulty_event_sync[2]^difficulty_event_sync[1]) difficulty_video<=base_difficulty_sys;
        end
    end

    // ------------------------------------------------------ status and errors
    // audit note: three of the four audio fault sources are hardwired to 0
    // because the encrypted HDMI core's internal audio state is not visible
    // to user RTL. Only tone FIFO overflow is real. The audio_fault_sys LED
    // bit (4'hd) is therefore a tone-overflow-only indicator in practice.
    wire audio_sequence_error = 1'b0;        // encrypted core internal
    wire audio_tone_overflow;                // real: pcm_media_music_v8 FIFO
    wire audio_pcm_contract_error = 1'b0;    // encrypted core internal
    wire audio_phy_phase_error = 1'b0;       // encrypted core internal
    wire audio_blip_active;
    wire pcm_tap_valid;
    wire signed [15:0] pcm_tone_left;
    wire signed [15:0] pcm_tone_right;
    wire player_enable_sys;
    wire storage_error_sys;
    wire video_fault_sys;
    wire audio_fault_sys;
    wire [3:0] video_error_low_sys;
    wire video_error_reader_class_sys;

    wire [7:0] reported_error = storage_error_sys ? 8'hfe :
                                 video_fault_sys ?
                                     {2'b01, video_error_reader_class_sys,
                                      ~video_error_reader_class_sys,
                                      video_error_low_sys} :
                                 // F6: degraded card, player still running
                                 media_partial_sys ? 8'hfd :
                                 8'd0;

    wire auto_enabled_video;
    wire [7:0] reported_error_video;
    sync_2ff u_auto_osd_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(auto_enabled), .sync_out(auto_enabled_video)
    );
    genvar osd_bit;
    generate
        for (osd_bit = 0; osd_bit < 8; osd_bit = osd_bit + 1) begin : g_osd_err
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(reported_error[osd_bit]),
                .sync_out(reported_error_video[osd_bit])
            );
        end
    endgenerate

    // Detected-tone readout for teacher mode. sc_tone is produced in the
    // video_clk domain by tone_scorer, so it needs the same 2-flop treatment
    // the error code gets. It is a 3-bit code that only changes between
    // attempts, so a plain sync_2ff per bit is sufficient -- there is no
    // multi-bit coherency requirement here (worst case one frame shows a
    // mix of the old and new digit, which the next frame corrects).
    //
    // Declared here rather than next to the scorer instantiation so that the
    // OSD wiring below reads top-down. This is the ONLY consumer of sc_tone;
    // before this the signal was declared and connected but never read, so
    // the classifier's decision never reached any observable output.
    //
    // Note this deliberately has NO consumer in child mode: the tone digit
    // is a bench instrument, not part of the learner-facing design.
    wire [2:0] sc_tone;
    wire [2:0] sc_tone_video;
    genvar tone_bit;
    generate
        for (tone_bit = 0; tone_bit < 3; tone_bit = tone_bit + 1) begin : g_osd_tone
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(sc_tone[tone_bit]),
                .sync_out(sc_tone_video[tone_bit])
            );
        end
    endgenerate

    // status OSD (teacher mode only), just below the top text band
    wire [23:0] video_rgb_osd_raw;
    osd_overlay_24 #(.OSD_X(8), .OSD_Y(48)) u_osd (
        .clk(video_clk), .rst_n(pix_rst_n),
        .vsync(video_vs), .de(video_de),
        .rgb_in(video_rgb), .pixel_x(video_x),
        .active_index(active_index_video), .auto_enabled(auto_enabled_video),
        .error_code(reported_error_video),
        .tone_code(sc_tone_video),
        .rgb_out(video_rgb_osd_raw), .de_out(), .osd_active()
    );
    // Fatal media faults must be visible even with SW4 down.
    wire [23:0] video_rgb_osd = (teacher_video || reported_error_video == 8'hfe) ?
                               video_rgb_osd_raw : video_rgb;

    // V8 area relief (2026-10-17, areacut_20261017): the SW4 ASCII parameter
    // line + scrolling slogan layer (promax_text_overlay) is bypassed.
    //
    // WHY THIS IS ALIGNMENT-SAFE (no补拍 needed, and deliberately NO shift
    // register added): promax_text_overlay.v:335-336 drives
    //     assign rgb_out = overlay_active ? ... : rgb_in;
    // which is a purely COMBINATIONAL 24-bit mux of rgb_in. Its only clocked
    // logic (line_y/de_q/vs_q and the frame-latched parameters) generates the
    // overlay PATTERN; it never delays rgb_in. The layer therefore inserts
    // exactly 0 video_clk beats. The geometry nets were never routed through
    // it either: the instance consumed video_vs/video_de/video_x straight from
    // u_video (lines 877-879 below) and u_ss_overlay still takes the very same
    // undelayed video_vs/video_de/video_x -- so deleting the mux cannot shift
    // a pixel. This is NOT the cp_* shape (there the bypassed caption layer
    // DID emit its own vs/de/x and the pair had to be re-taken from one
    // stage); here nothing downstream reads a layer-local vs/de/x, so a bare
    // pass-through is the exact 0-beat equivalent. osd_overlay_24 is the same
    // shape (osd_overlay_24.v:78-82, rgb_out combinational, de_out = de) and
    // is deliberately KEPT: it only costs 40 LUT and it is the one layer that
    // still paints a fatal media fault for a CHILD (SW4 down).
    //
    // SINGLE DECLARATION POINT ON PURPOSE (the cp_* HDL-5333/HDL-5007 accident
    // was a second `wire cp_vs = ...` after `wire cp_vs;`, which TD silently
    // ignored and the netlist lost its driver). This `wire ... = ...` is the
    // one and only declaration/assignment of video_rgb_text in the design;
    // do not add a bare `wire [23:0] video_rgb_text;` anywhere.
    //
    // The subtitle_text/length/enable CDC chain and the image_scale_2x syncs
    // above are left instantiated: they are unloaded now (TD prunes them) and
    // sim/tb_media_to_axi_v7.v:161 probes dut.subtitle_enable_video directly.
    wire [23:0] video_rgb_text = video_rgb_osd;
    wire [95:0] subtitle_text_video;
    wire [5:0] subtitle_length_video;
    wire subtitle_enable_video;
    wire [3:0] image_scale_2x_video;
    genvar scale_bit;
    generate
        for (scale_bit = 0; scale_bit < 4; scale_bit = scale_bit + 1) begin : g_scale_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(image_scale_2x[scale_bit]),
                .sync_out(image_scale_2x_video[scale_bit])
            );
        end
    endgenerate
    wire active_source_scale_2x = image_scale_2x_video[active_index_video];
    subtitle_frame_commit u_subtitle_frame_commit (
        .src_clk(sys_clk), .src_rst_n(ctrl_rst_n),
        .src_commit(1'b0),
        .src_text(subtitle_text_sys),
        .src_length(subtitle_length_sys),
        .src_enable(subtitle_enable_sys),
        .dst_clk(video_clk), .dst_rst_n(pix_rst_n),
        .frame_start(frame_start),
        .dst_text(subtitle_text_video),
        .dst_length(subtitle_length_video),
        .dst_enable(subtitle_enable_video)
    );
    wire training_video;
    // u_promax_text removed here (area relief, 2026-10-17): see the block
    // comment at the video_rgb_text declaration above. board_b/src/
    // promax_text_overlay.v stays on disk and stays in run_td.tcl /
    // run_td.ps1, because sim/tb_child_param_text_v7.v still instantiates the
    // module directly; an uninstantiated source file costs nothing.
    // video_rgb_text is driven ONLY by its declarative assignment, so this
    // removal cannot leave the net undriven.

    // ------------------------------------------------------ feature link (Board A)
    // Board A owns the ADC front end and the YIN pitch tracker and streams
    // one 15-byte v5 feature frame per video frame at 921600-8N1 (docs/10
    // section 3). uart_rx_feature (board_b/src/uart_rx_feature.v) rebuilds
    // {voiced, pitch_q4, level} plus the v5 payload (formant bands, cycle-
    // level VQ, NB/DTW verdicts, link status and the player-2 features);
    // feat_* plays exactly the role trk_* played in the single-board build.
    // Both boards run video_clk at 25 MHz, so the 921600 link uses
    // CLKS_PER_BIT = 27. The PC score UART below stays at 115200.
    wire feat_valid;
    wire single_mic,mic_teacher,mic_ready,mic_transition;
    wire mic_child_allowed=!single_mic || (!mic_teacher && mic_ready);
    wire feat_voiced;
    wire [9:0] feat_pitch_q4;
    wire [7:0] feat_level;
    wire [3:0] feat_tau_hi;
    wire [3:0] feat_f1_band;
    wire [3:0] feat_f2_band;
    wire [7:0] feat_jitter_c;
    wire [7:0] feat_shimmer_c;
    wire feat_nb_valid;
    wire [2:0] feat_nb_tone;
    wire feat_dtw_ready;
    wire [2:0] feat_dtw_tone;
    wire feat_clip_flag;
    wire feat_agc_ovf;
    // spec_cut_20261017: the teacher-channel live features (u_link outputs
    // teacher_voiced / teacher_pitch / teacher_level / tch_n, plus the already
    // unconnected protocol_error) have no reader in this top -- proven by the
    // direction-aware fan-out audit in build/v8/t5/deadarith_20261017/NOTES.md
    // table A (27 FF total). Those port connections are now empty and the dead
    // top-level wires are gone; module ports and v7_link_b.v are untouched.
    wire [3:0] p2_tau_hi;
    // v6 teacher demo (docs/14)
    wire feat_demo_en, feat_link_up, tch_ok;
    wire [3:0] tch_seq;
    wire [127:0] tch_off;
    wire teacher_on = feat_link_up && feat_demo_en;
    wire tch_armed, demo_request, demo_cancel, sc_cancel;
    // PRODUCT has no NB/DTW classification. Zero means invalid, not a
    // recognized target tone. These legacy diagnostics stay visibly empty.
    assign feat_tau_hi=0; assign feat_f1_band=0; assign feat_f2_band=0;
    assign feat_jitter_c=0; assign feat_shimmer_c=0;
    assign feat_nb_valid=0; assign feat_nb_tone=0;
    assign feat_dtw_ready=0; assign feat_dtw_tone=0;
    assign feat_clip_flag=0; assign feat_agc_ovf=0; assign p2_tau_hi=0; assign tch_seq=0;

    // teacher mode: live waveform. The microphone is on Board A, so the
    // closest signal this board receives is the streamed 8-bit level; it is
    // zero-order-held here (one tap per video frame, doubled into both bytes
    // of the 16-bit tap) and draws the remote voice's loudness envelope.
    wire [23:0] video_rgb_wave = video_rgb_text;

    wire sc_arm, sc_enable, sc_valid, sc_short, sc_pv, sc_active;
    wire eligible_result,accepted_result;
    reg [2:0] result_mode_q;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if(!pix_rst_n) result_mode_q<=0;
        else result_mode_q<=mode_video;
    end
    wire [2:0] sc_target, sc_hint;
    wire [6:0] sc_n, sc_score, sc_pi;
    wire [1:0] sc_stars;
    wire [9:0] sc_mean, sc_pval;
    wire [159:0] sc_bins;
    // R82 adaptive difficulty from the game. It was used here undeclared (an
    // implicit 1-bit net, truncating the value) and the scorer still read
    // difficulty_video, contrary to docs/06 R82; the scorer latches it on arm
    // (GUARD), after FEED has updated it, so one question sees one value.
    wire [1:0] eff_diff;
    tone_scorer #(.ENABLE_CLASSIFIER(0)) u_scorer (
        .clk(video_clk), .rst_n(pix_rst_n), .arm(sc_arm), .cancel(sc_cancel || !feat_link_up || mic_transition || !mic_child_allowed), .target(sc_target),
        .difficulty(eff_diff), .enable(sc_enable), .frame_valid(feat_valid),
        .voiced(feat_voiced), .pitch_q4(feat_pitch_q4),
        .nb_valid(feat_nb_valid), .nb_tone(feat_nb_tone),
        .dtw_valid(feat_dtw_ready), .dtw_tone(feat_dtw_tone),
        .result_valid(sc_valid),
        .n_points(sc_n), .too_short(sc_short), .tone(sc_tone), .score(sc_score),
        .stars(sc_stars), .hint(sc_hint), .mean_q4(sc_mean), .bins_flat(sc_bins),
        .point_valid(sc_pv), .point_index(sc_pi), .point_value(sc_pval),
        .active(sc_active)
    );

    // ------------------------------------------------------ sound
    pcm_media_music_v8 u_media_tone (
        .clk(video_clk), .rst_n(pix_rst_n),
        .media_id(active_index_video), .volume(volume_video),
        .sample_valid(pcm_tap_valid), .sample_ready(1'b1),
        .sample_left(pcm_tone_left), .sample_right(pcm_tone_right),
        .overflow(audio_tone_overflow), .blip_active(audio_blip_active)
    );
    wire syn_cmd_valid, syn_playing, syn_done;
    wire [2:0] syn_cmd_mode, syn_cmd_tone;
    wire [7:0] syn_progress;
    wire signed [15:0] syn_sample;
    voice_model_synth u_synth (
        .clk(video_clk), .rst_n(pix_rst_n), .tick(pcm_tap_valid),
        .cmd_valid(syn_cmd_valid), .cmd_mode(syn_cmd_mode), .cmd_tone(syn_cmd_tone),
        .volume(volume_video), .sample_out(syn_sample), .playing(syn_playing),
        .progress(syn_progress), .done(syn_done)
    );
    // display mode keeps the per-picture melody; training uses the model voice
    wire signed [15:0] pcm_program_left = training_video ? syn_sample : pcm_tone_left;
    wire signed [15:0] pcm_program_right = training_video ? syn_sample : pcm_tone_right;
    // D3 same-bit comparison: SW4+SW2, media only. Production music keeps
    // running; sample-valid, ACR, HDMI and serial PHY are shared unchanged.
    wire diagnostic_sw2_video;
    sync_2ff u_d3_switch_sync (.clk(video_clk), .rst_n(pix_rst_n),
        .async_in(sw_stable[1]), .sync_out(diagnostic_sw2_video));
    wire diagnostic_audio_reference = teacher_video && diagnostic_sw2_video && !training_video;
    wire diagnostic_audio_reference_sys;
    sync_2ff u_d3_mode_readback (.clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(diagnostic_audio_reference), .sync_out(diagnostic_audio_reference_sys));
    wire signed [15:0] pcm_reference;
    audio_reference_d3 u_audio_reference (
        .clk(video_clk), .rst_n(pix_rst_n),
        .sample_valid(pcm_tap_valid), .sample(pcm_reference)
    );
    wire signed [15:0] pcm_left = diagnostic_audio_reference ? pcm_reference : pcm_program_left;
    wire signed [15:0] pcm_right = diagnostic_audio_reference ? pcm_reference : pcm_program_right;

    // ------------------------------------------------------ training game + overlay
    wire goto_valid_video;
    wire [1:0] goto_index_game;
    wire panel_show, child_show, ball_show, balloon_show, train_show, meter_ok, card_show;
    wire [9:0] target_reveal, train_x;
    wire [8:0] ball_col;
    wire [7:0] ball_y, balloon_r, meter_level, win_lo, win_hi;
    wire [1:0] card_index, s3_class;
    wire [5:0] s0_id, s1_id, s3_id;
    wire [47:0] s2_cells;
    wire cmd_valid, cmd_ready, cmd_buf, cmd_vis;
    wire [8:0] cmd_x0;
    wire [3:0] cmd_log2n;
    wire [7:0] cmd_y0, cmd_y1;
    // R73 game -> overlay: three-star celebration and the LISTEN level bar
    wire celebrate, listen_meter;
    wire [2:0] game_phase;
    // Every result consumer uses the same acceptance boundary as the game.
    // A same-cycle replay/next/mode change must not log, export or beep an
    // abandoned utterance even before scorer.cancel is registered.
    assign eligible_result=sc_valid && !sc_cancel && !mic_transition && mic_child_allowed &&
        (mode_video==1 || mode_video==4) && game_phase==3 &&
        mode_video==result_mode_q && !key_next_video && !key_replay_video;
    assign accepted_result=eligible_result && feat_link_up;
    wire tch_used;
    // audit F1/F2: session summary + voice discovery signals
    wire [7:0]  disc_radius;
    wire [2:0]  disc_hue;
    wire [7:0]  sess_q;
    wire [7:0]  sess_star;
    wire        summary_show;
    wire        discover_show;
    shengsheng_game #(.ENABLE_SINGLE_MIC(1)) u_game (
        .single_mic(single_mic),.mic_teacher(mic_teacher),.mic_ready(mic_ready),.mic_transition(mic_transition),
        .clk(video_clk), .rst_n(pix_rst_n), .mode(mode_video),
        .ui_tick(frame_start), .link_up(feat_link_up), .tch_armed(tch_armed),
        .sc_cancel(sc_cancel), .demo_request(demo_request), .demo_cancel(demo_cancel),
        .key_next(key_next_video), .key_replay(key_replay_video),
        .difficulty(difficulty_video), .active_index(active_index_video),
        .trk_valid(feat_valid), .trk_voiced(feat_voiced), .trk_pitch(feat_pitch_q4),
        .trk_level(feat_level),
        .sc_valid(sc_valid),
        .sc_active(sc_active), .sc_short(sc_short),
        .disc_radius_o(disc_radius), .disc_hue_o(disc_hue),
        .sess_q_o(sess_q), .sess_star_o(sess_star), .sc_score(sc_score), .sc_stars(sc_stars),
        .sc_hint(sc_hint), .sc_mean(sc_mean), .sc_bins(sc_bins), .sc_point_valid(sc_pv),
        .sc_point_index(sc_pi), .sc_point_value(sc_pval), .sc_arm(sc_arm),
        .sc_target(sc_target), .sc_enable(sc_enable),
        .syn_playing(syn_playing), .syn_progress(syn_progress), .syn_done(syn_done),
        .syn_cmd_valid(syn_cmd_valid), .syn_cmd_mode(syn_cmd_mode), .syn_cmd_tone(syn_cmd_tone),
        .goto_valid(goto_valid_video), .goto_index(goto_index_game), .training(training_video),
        .celebrate(celebrate), .listen_meter(listen_meter),
        .eff_diff(eff_diff),
        .panel_show(panel_show), .child_show(child_show), .target_reveal(target_reveal),
        .ball_show(ball_show), .ball_col(ball_col), .ball_y(ball_y),
        .balloon_show(balloon_show), .balloon_r(balloon_r), .train_show(train_show),
        .train_x(train_x), .meter_level(meter_level), .win_lo(win_lo), .win_hi(win_hi),
        .meter_ok(meter_ok), .card_show(card_show), .card_index(card_index),
        .s0_id(s0_id), .s1_id(s1_id), .s2_cells(s2_cells), .s3_id(s3_id), .s3_class(s3_class),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_buf(cmd_buf), .cmd_x0(cmd_x0),
        .cmd_log2n(cmd_log2n), .cmd_y0(cmd_y0), .cmd_y1(cmd_y1), .cmd_vis(cmd_vis),
        .teacher_on(teacher_on), .tch_new(tch_ok), .tch_off(tch_off),
        .phase_o(game_phase), .tch_used(tch_used),
        .summary_show(summary_show), .discover_show(discover_show)
    );

    // B -> A return packets (docs/14 section 3): every scored result plus a
    // status heartbeat every 8 frames, for the teacher console on Board A
    v7_link_b #(.CLKS_PER_BIT(27), .ALLOW_SINGLE_MIC(1)) u_link (
        .single_mic(single_mic),.mic_teacher(mic_teacher),.mic_ready(mic_ready),.mic_transition(mic_transition),
        .clk(video_clk), .rst_n(pix_rst_n), .rx(uart_rx_i), .tx(link_tx_o), .frame_tick(frame_start),
        // Card text changes with card_index before INTRO updates sc_target.
        .mode(mode_video), .phase(game_phase),
        .q_idx((mode_video == 3'd4) ? card_index : (sc_target[1:0] + 2'd3)),
        .eff_diff(eff_diff), .tch_used(tch_used), .summary(summary_show),
        .demo_request(demo_request), .demo_cancel(demo_cancel), .protocol_error(),
        .sc_valid(eligible_result), .target(sc_target), .sc_hint(sc_hint),
        .sc_stars(sc_stars), .sc_short(sc_short), .sc_score(sc_score),
        .sc_n(sc_n), .sc_mean(sc_mean), .sc_bins(sc_bins),
        .link_up(feat_link_up), .feat_valid(feat_valid), .feat_voiced(feat_voiced),
        .feat_pitch(feat_pitch_q4), .feat_level(feat_level),
        .teacher_preference(feat_demo_en),
        .teacher_voiced(), .teacher_pitch(), .teacher_level(),
        .tch_armed(tch_armed), .tch_new(tch_ok), .tch_n(), .tch_shape(tch_off)
    );
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            goto_toggle_video <= 1'b0;
            goto_index_video <= 2'd0;
        end else if (goto_valid_video) begin
            goto_toggle_video <= ~goto_toggle_video;
            goto_index_video <= goto_index_game;
        end
    end

    wire ov_vs, ov_de;
    wire [9:0] ov_x;
    wire [23:0] ov_rgb;
    shengsheng_overlay u_ss_overlay (
        .clk(video_clk), .rst_n(pix_rst_n), .vsync(video_vs), .de(video_de),
        .pixel_x(video_x), .rgb_in(video_rgb_wave),
        .vsync_out(ov_vs), .de_out(ov_de), .pixel_x_out(ov_x), .rgb_out(ov_rgb),
        .enable(1'b1), .high_contrast(high_contrast_video),
        .summary_show(summary_show),
        .discover_show(discover_show),
        .disc_radius(disc_radius),
        .disc_hue(disc_hue),
        .sess_q(sess_q),
        .sess_star(sess_star),
        .panel_show(panel_show), .child_show(child_show), .target_reveal(target_reveal),
        .ball_show(ball_show), .ball_col(ball_col), .ball_y(ball_y),
        .balloon_show(balloon_show), .balloon_r(balloon_r), .train_show(train_show),
        .train_x(train_x), .meter_level(meter_level), .win_lo(win_lo), .win_hi(win_hi),
        .meter_ok(meter_ok), .card_show(card_show), .card_index(card_index),
        .celebrate(celebrate), .listen_meter(listen_meter),
        .s0_id(s0_id), .s1_id(s1_id), .s2_cells(s2_cells), .s3_id(s3_id), .s3_class(s3_class),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_buf(cmd_buf), .cmd_x0(cmd_x0),
        .cmd_log2n(cmd_log2n), .cmd_y0(cmd_y0), .cmd_y1(cmd_y1), .cmd_vis(cmd_vis)
    );

    // V8 area relief (2026-10-17, spec_cut_20261017): extension item 5 (the
    // 16-band music spectrum drawn top centre in display mode) is cut -- both
    // the drawing layer osd_spectrum_v8 (u_spectrum_bars: 574 LE / 360+60 LUT /
    // 361 FF / 0 DSP / 0 BRAM, phy.area.06624843 row 271) and its producer
    // spectrum_analyzer_v8 (u_spectrum: 813 LE / 730+72 LUT / 435 FF / 1 BRAM /
    // 1 DSP, row 270). Fan-out evidence for the producer: `heights` drove ONLY
    // u_spectrum_bars, `heights_valid` was already unconnected, `overrun` fed
    // only the audio-fault synchroniser below (now dropped, it can never be
    // set again), and `display_layers_video` + its source CDC stage
    // u_player_enable_video had no other reader either.
    //
    // LATENCY: osd_spectrum_v8 delayed vsync / de / pixel_x / rgb by EXACTLY
    // TWO CLOCKS -- stage A samples the four inputs (osd_spectrum_v8.v:181-190)
    // and stage B registers them out (osd_spectrum_v8.v:198-204), with reset
    // defaults vsync=1, de=0, x=0, rgb=0. The layer was NOT a 0-beat pass
    // through (unlike u_promax_text / u_osd, see areacut_20261017), so the same
    // two register stages must come back or cp_* / u_param_panel / the AXI
    // framer would all run two clocks early. 72 FF replace 399 LUT + 380 FF.
    reg        s1_vs, s1_de;
    reg [9:0]  s1_x;
    reg [23:0] s1_rgb;
    reg        sp_vs, sp_de;
    reg [9:0]  sp_x;
    reg [23:0] sp_rgb;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            s1_vs <= 1'b1; s1_de <= 1'b0; s1_x <= 10'd0; s1_rgb <= 24'd0;
            sp_vs <= 1'b1; sp_de <= 1'b0; sp_x <= 10'd0; sp_rgb <= 24'd0;
        end else begin
            s1_vs <= ov_vs; s1_de <= ov_de; s1_x <= ov_x; s1_rgb <= ov_rgb;
            sp_vs <= s1_vs; sp_de <= s1_de; sp_x <= s1_x; sp_rgb <= s1_rgb;
        end
    end

    // V8 area relief (2026-10-16): the caption / title layer (extension item 1)
    // is bypassed to free mslice headroom. The bypass keeps cp_* paired -- x and
    // rgb come from the same source stage -- so the downstream parameter panel
    // geometry is unchanged.
    wire cp_vs, cp_de;
    wire [9:0] cp_x;
    wire [23:0] cp_rgb;
    assign cp_vs  = sp_vs;
    assign cp_de  = sp_de;
    assign cp_x   = sp_x;
    assign cp_rgb = sp_rgb;

    // V8 parameter panel, after the caption layer (another two clocks)
    wire pn_vs, pn_de;
    wire [9:0] pn_x;
    wire [23:0] pn_rgb;
    osd_param_panel_v8 u_param_panel (
        .clk(video_clk), .rst_n(pix_rst_n),
        .vsync(cp_vs), .de(cp_de), .pixel_x(cp_x), .rgb_in(cp_rgb),
        .show(param_recent_video), .picture(active_index_video), .kind(panel_kind_pix),
        .brightness(brightness_pix), .contrast(contrast_pix),
        .volume(volume_video), .period_ms(period_video),
        .style(slide_style_pix), .difficulty(difficulty_video),
        .vsync_out(pn_vs), .de_out(pn_de), .pixel_x_out(pn_x), .rgb_out(pn_rgb)
    );

    // ------------------------------------------------------ HDMI
    // The overlay and the panel delay RGB, DE, VSYNC and X together, so the
    // AXI-stream framing below is built from the delayed copies.
    reg axis_frame_armed;
    reg axis_vsync_q;
    reg pn_de_q;
    // REVERTED (2026-10-17): registering these four channels made the encrypted
    // core stop locking (hardware read b1F000E4, hdmi_video_locked=0) while
    // fix_hold's work grew from 156 feed-throughs/124 nets to 253/210 -- the
    // delay-insertion-then-broken-handshake failure the SDC comment records from
    // 2026-08-22. Do not re-attempt a register stage here without first buying
    // real area headroom; see docs/V8_02 2026-10-17 and docs/V8_04 pit 20.
    wire axis_video_user = pn_de && axis_frame_armed;
    wire axis_video_valid = pn_de;
    wire axis_video_last = pn_de && pn_x == 10'd639;
    // Same-image-build isolation: SW4+SW3 substitutes the diagnostic pattern
    // only at the final AXI input; SD/SDRAM, overlays and audio keep running.
    wire diagnostic_gray_video = teacher_video && high_contrast_video;
    // ---------------------------------------------------------------
    // V8 T5 diagnostic (2026-10-18): SW3+SW4 used to force 24'h808080 (uniform
    // gray). Gray can only say "something is wrong here"; a POSITION-CODED
    // staircase says WHAT is wrong.
    //
    // Each pixel carries its own column number as three visible staircases --
    // one per colour channel -- so a corrupted pixel can be decoded from a
    // PHOTOGRAPH by counting steps, not by measuring absolute brightness (which
    // camera gamma and white balance would ruin).
    //
    //     R = pn_x[9:7] << 5   -> x / 128,   8 steps of 32, 128 px wide
    //     G = pn_x[6:3] << 4   -> (x/8)%16, 16 steps of 16,  32 px wide
    //     B = pn_x[2:0] << 5   -> x % 8,     8 steps of 32,   4 px wide
    //
    // Decode:  x = (R/32)*128 + (G/16)*8 + (B/32)
    // (R,G,B) is unique for every x in 0..639, and the finest step is 4 px, so
    // a 2-4 px wide stripe still lands on a readable step.
    //
    // How to read the photo, at a stripe of column c:
    //   decoded x == c - k (small k) -> pixel dropped/duplicated: position slip
    //   decoded x unrelated to c     -> the VALUE is corrupt: bit flip / stuck
    //                                   bit / foreign data on the AXI bus
    //   whole stripe shows one level -> a constant was inserted
    //
    // Why not the D1 8x80 colour bars: inside one bar every column has the same
    // colour, so x-k and x are indistinguishable, and the stripes are only
    // 2-4 px wide. Why not a smooth ramp: absolute levels do not survive a
    // camera. Staircases do, because you count edges.
    //
    // Pure wiring: 0 LUT, 0 FF. Single declaration point -- the 2026-10-17
    // cp_* duplicate-declaration bug cut the whole OSD chain, so never add a
    // second declaration of a name used here.
    wire [23:0] axis_video_data = diagnostic_gray_video
                                ? {pn_x[9:7], 5'b00000,
                                   pn_x[6:3], 4'b0000,
                                   pn_x[2:0], 5'b00000}
                                : pn_rgb;
    wire axis_video_ready;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            axis_frame_armed <= 1'b1;
            axis_vsync_q <= 1'b1;
            pn_de_q <= 1'b0;
        end else begin
            axis_vsync_q <= pn_vs;
            pn_de_q <= pn_de;
            if (axis_vsync_q != pn_vs)
                axis_frame_armed <= 1'b1;
            // V8 fix (2026-10-16): follow the official golden framer
            // (2026_topic1_dual_board/dependencies/video_rgb_to_axis_640x480.v
            // :44-51) and clear the frame arm UNCONDITIONALLY at the first
            // pixel of a line. The previous version gated this on
            // axis_video_ready; if the core deasserted ready at that instant,
            // the arm stayed set forever, holding axis_video_user (SOF) high on
            // every pixel, so the core never saw a frame boundary and never
            // locked -- a bistable failure that explains the intermittent
            // no-signal builds. The golden does not consult ready at all.
            if (pn_de && !pn_de_q && axis_frame_armed)
                axis_frame_armed <= 1'b0;
        end
    end

    // V8 T5 diagnostic (2026-10-17): self-check the framing alignment that the
    // core samples. Observational only -- it does not gate any data path.
    // check1: a pixel is offered while the core says it is not ready (loss channel)
    // check2: EOL is asserted at a position other than the 640th active pixel of the
    //         line (a one-beat EOL/DE misalignment; ready_probe T6B reproduced the
    //         observed fixed-column, full-height, content-independent loss with
    //         exactly this perturbation, and the product has only a 1-beat margin
    //         because de ends at x=639 while the core's ready window starts at 640).
    reg frame_viol_notready;
    reg frame_viol_eolpos;
    reg [9:0] frame_line_pix;
    reg frame_de_q;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            frame_viol_notready <= 1'b0;
            frame_viol_eolpos   <= 1'b0;
            frame_line_pix      <= 10'd0;
            frame_de_q          <= 1'b0;
        end else begin
            frame_de_q <= axis_video_valid;
            // Count the same valid that drives axis_video_last, so the two stay
            // aligned if the framing is ever re-pipelined. Seeded with 1 because
            // the register is visible one pixel late -- it then holds 639 during
            // the 640th active pixel, which is where axis_video_last must fall.
            if (axis_video_valid && !frame_de_q)
                frame_line_pix <= 10'd1;
            else if (axis_video_valid && frame_line_pix != 10'd640)
                frame_line_pix <= frame_line_pix + 10'd1;
            if (axis_video_valid && !axis_video_ready)
                frame_viol_notready <= 1'b1;
            if (axis_video_last && frame_line_pix != 10'd639)
                frame_viol_eolpos <= 1'b1;
        end
    end
    wire frame_viol_notready_sys;
    wire frame_viol_eolpos_sys;
    sync_2ff u_frame_viol_notready_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(frame_viol_notready), .sync_out(frame_viol_notready_sys)
    );
    sync_2ff u_frame_viol_eolpos_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(frame_viol_eolpos), .sync_out(frame_viol_eolpos_sys)
    );

    wire acr_valid;
    wire [19:0] acr_cts;
    wire [19:0] acr_n;
    // f1 (2026-10-25): one video_clk register stage on EVERY audio/ACR line
    // into the encrypted HDMI core. The source chains (pcm mux, ACR module)
    // had long combinational paths ending on core input pins the STA cannot
    // see (the encrypted core publishes no input timing arcs) -- the layout
    // roulette decides them. A single register each gives the router short,
    // uniform paths. Audio-side only: the AXI video stream is untouched
    // (registering those four channels broke core lock on 2026-10-17).
    reg        core_pcm_valid = 1'b0;
    reg signed [15:0] core_pcm_left = 16'sd0, core_pcm_right = 16'sd0;
    reg        core_acr_valid = 1'b0;
    reg [19:0] core_acr_cts = 20'd0, core_acr_n = 20'd0;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            core_pcm_valid <= 1'b0;
            core_pcm_left <= 16'sd0; core_pcm_right <= 16'sd0;
            core_acr_valid <= 1'b0;
            core_acr_cts <= 20'd0; core_acr_n <= 20'd0;
        end else begin
            core_pcm_valid <= pcm_tap_valid;
            core_pcm_left  <= pcm_left;
            core_pcm_right <= pcm_right;
            core_acr_valid <= acr_valid;
            core_acr_cts   <= acr_cts;
            core_acr_n     <= acr_n;
        end
    end
    audio_arc_calculate #(.ACR_N(6144)) u_audio_acr (
        .I_clk(video_clk), .I_rst(~pix_rst_n),
        .I_audio_valid(pcm_tap_valid), .O_acr_valid(acr_valid),
        .O_acr_cts(acr_cts), .O_acr_n(acr_n)
    );

    wire [9:0] hdmi_tmds_ch0;
    wire [9:0] hdmi_tmds_ch1;
    wire [9:0] hdmi_tmds_ch2;
    wire [9:0] hdmi_tmds_clk;
    wire hdmi_video_locked;
    wire hdmi_ddc_scl_unused;
    wire hdmi_ddc_sda_unused;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),
        .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
        .VIDEO_VIC(1), .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"),
        .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
    ) u_hdmi14_core (
        .I_pixel_clk(video_clk), .I_rst(~pix_rst_n),
        .I_edid_read_trig(1'b0),
        .O_edid_read_valid(), .O_edid_read_data(),
        .I_axis_s_user(axis_video_user),
        .I_axis_s_valid(axis_video_valid), .I_axis_s_last(axis_video_last),
        .I_axis_s_data(axis_video_data), .O_axis_s_ready(axis_video_ready),
        .I_audio_valid(core_pcm_valid),
        .I_audio_left_data({core_pcm_left, 8'h00}),
        .I_audio_right_data({core_pcm_right, 8'h00}),
        .I_acr_valid(core_acr_valid), .I_acr_cts(core_acr_cts), .I_acr_n(core_acr_n),
        .O_video_locked(hdmi_video_locked),
        .O_ddc_scl(hdmi_ddc_scl_unused),
        .IO_ddc_sda(hdmi_ddc_sda_unused),
        .O_ch0_tmds_data(hdmi_tmds_ch0),
        .O_ch1_tmds_data(hdmi_tmds_ch1),
        .O_ch2_tmds_data(hdmi_tmds_ch2),
        .O_clk_tmds_data(hdmi_tmds_clk)
    );

    hdmi_phy_wrapper #(.DEVICE("EG")) u_hdmi_phy (
        .I_pixel_clk(video_clk), .I_serial_clk(pixel_clk_5x),
        // Release the ODDR/shift-register reset in its own serial domain.
        // The pixel reset arrives too late for the next serial edge (+2 ns).
        .I_rst(~pix_5x_rst_n),
        .I_tmds_channel_0(hdmi_tmds_ch0),
        .I_tmds_channel_1(hdmi_tmds_ch1),
        .I_tmds_channel_2(hdmi_tmds_ch2),
        .I_tmds_channel_clk(hdmi_tmds_clk),
        .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P),
        .O_tmds_ch2_p(HDMI_D2_P), .O_tmds_clk_p(HDMI_CLK_P)
    );

    // ------------------------------------------------------ status to sys domain
    wire hdmi_video_locked_sys;
    sync_2ff u_hdmi_video_locked_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(hdmi_video_locked), .sync_out(hdmi_video_locked_sys)
    );
    sync_2ff u_player_enable_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(player_enable_mem), .sync_out(player_enable_sys)
    );
    sync_2ff u_storage_error_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(storage_error_mem), .sync_out(storage_error_sys)
    );
    sync_2ff u_video_fault_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(video_error != 0), .sync_out(video_fault_sys)
    );
    // spec_cut_20261017: spectrum_analyzer_v8.overrun used to be the fifth term
    // here. The analyser is removed, so that term is a permanent 0 and is
    // dropped; the four real audio faults are unchanged.
    sync_2ff u_audio_fault_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(audio_sequence_error || audio_tone_overflow ||
                  audio_pcm_contract_error || audio_phy_phase_error),
        .sync_out(audio_fault_sys)
    );

    genvar error_bit_index;
    generate
        for (error_bit_index = 0; error_bit_index < 4;
             error_bit_index = error_bit_index + 1) begin : g_video_error_sync
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(video_error[error_bit_index]),
                .sync_out(video_error_low_sys[error_bit_index])
            );
        end
    endgenerate
    sync_2ff u_video_error_class_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(video_error[5]),
        .sync_out(video_error_reader_class_sys)
    );

    // picture index pixel -> sys, gray-coded (R64)
    wire [1:0] active_index_gray = active_index ^ {1'b0, active_index[1]};
    wire [1:0] active_index_gray_sys;
    genvar uart_bit;
    generate
        for (uart_bit = 0; uart_bit < 2; uart_bit = uart_bit + 1) begin : g_media_sys
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(active_index_gray[uart_bit]),
                .sync_out(active_index_gray_sys[uart_bit])
            );
        end
    endgenerate
    wire [1:0] active_index_sys =
        active_index_gray_sys ^ {1'b0, active_index_gray_sys[1]};

    reg [1:0] active_index_sys_q;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            active_index_sys_q <= 2'd0;
        else
            active_index_sys_q <= active_index_sys;
    end
    wire switch_evt = (active_index_sys != active_index_sys_q);

    // Stage E: the ProMax status reporter stayed removed (LUTs), but the
    // training-record export from docs/49 stage E is wired in its place: one
    // "SCORE <mode> <tone> <score> <stars>,N=..,D=..,F=.." line per finished
    // utterance on the D12 pin, 115200-8N1. The v5 variant (docs/10 section
    // 3) appends the NB and DTW verdicts that fed the scorer's cascade plus
    // the formant band indices from the feature link -- this is the PC-side
    // collection port. A PC script (tools/shengsheng/score_session_logger.py)
    // stores the CSV and draws the progress curve the Flash version would
    // have shown on screen.
    ss_score_reporter_b #(.CLKS_PER_BIT(217)) u_score_uart (
        .clk(video_clk), .rst_n(pix_rst_n),
        .score_event(accepted_result), .mode(mode_video), .tone(sc_tone),
        .score(sc_score), .stars(sc_stars),
        .nb_tone(feat_nb_tone), .dtw_tone(feat_dtw_tone),
        .f1_band(feat_f1_band), .f2_band(feat_f2_band), .uart_tx(uart_tx_o)
    );

    // ------------------------------------------------------ P0 board peripherals
    // docs/08 section 5: the previously idle on-board seven-segment display
    // and buzzer. Both run their scanner/generator on sys_clk and take the
    // slow video-domain values through 2FF synchronisers (inside the display
    // module; a toggle synchroniser inside the buzzer for the event pulse).
    // Display D7..D0 = {level% tens, level% ones, mode, tone, stars,
    // score hundreds/tens/ones}.
    // SW4: B S C F EE I H, all hexadecimal; EE is the full video error.
    // S={storage_fatal,audio_fault,video_fault,player_enabled}; C/F=bank masks;
    // EE=00, 5x control or 6x reader; I={PLL,SDRAM_ready,card_ready,ingest_busy};
    // H={HDMI_locked,ingest_started,write_FIFO_full,write_FIFO_overflow}.
    // This remains readable when the HDMI image is unusable. Counter pages
    // are omitted for area; SW4 down retains the normal/fatal display.
    // SW4: B S C F EE I H, all hexadecimal; EE is the full video error.
    // Leading digit is the framing self-check code (diagnostic, 2026-10-17):
    //   B = no violation, C = EOL not at the 640th active pixel (one-beat
    //   EOL/DE misalignment), D = pixel offered while axis_video_ready low.
    // C takes priority because it is the reproduced failure mode.
    wire [3:0] frame_check_code = frame_viol_eolpos_sys ? 4'hc :
                                  (frame_viol_notready_sys ? 4'hd : 4'hb);
    wire [31:0] board_status_hex = {frame_check_code,
        storage_error_sys, audio_fault_sys, video_fault_sys, player_enable_sys,
        image_complete, image_failed,
        (video_fault_sys ? {2'b01, video_error_reader_class_sys,
                           ~video_error_reader_class_sys} : 4'h0),
        video_error_low_sys,
        mem_locked, sdram_init_done_sys, card_ready, ingest_busy,
        hdmi_video_locked_sys, ingest_started, write_cdc_full, write_cdc_overflow};
    // D2: system-domain tag remains readable without a pixel snapshot.
    wire [31:0] audio_probe_d4_status;
    audio_probe_d4 u_audio_probe_d4 (
        .sys_clk(sys_clk), .sys_rst_n(ctrl_rst_n),
        .pix_clk(video_clk), .pix_rst_n(pix_rst_n),
        .pcm_valid(pcm_tap_valid), .acr_valid(acr_valid),
        .acr_cts(acr_cts),
        .status_sys(audio_probe_d4_status)
    );
    wire [31:0] diagnostic_page = sw_stable[0] ? audio_probe_d4_status : board_status_hex;
    seven_seg_display #(.CLKS_PER_DIGIT(50000)) u_seg7 (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .score(sc_score), .stars(sc_stars), .tone(sc_tone),
        .mode(mode_video), .level(feat_level),
        // Fatal storage layout (hex): E, stage, code[7:0], detail[7:0],
        // failed-bank mask, complete-bank mask. Normal training is unchanged.
        .diagnostic_valid(storage_error_sys || teacher_sys),
        // SW4 exposes live status even when HDMI and the error path are silent.
        .diagnostic_data(teacher_sys ? diagnostic_page : {4'he, 1'b0, ingest_error_stage, ingest_error_code,
                          ingest_error_detail, image_failed, image_complete}),
        .seg_led(seg_led), .seg_sel(seg_sel)
    );

    // Buzzer events come straight from the scorer verdict: 2+ stars beep the
    // correct C6, 0/1 stars the wrong G4.
    reg beep_start_v;
    reg beep_kind_v;
    always @(posedge video_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            beep_start_v <= 1'b0;
            beep_kind_v  <= 1'b0;
        end else begin
            beep_start_v <= accepted_result;
            if (accepted_result)
                beep_kind_v <= (sc_stars >= 2'd2);
        end
    end
    buzzer_feedback #(
        .DIV_RIGHT(23899), .DIV_WRONG(63776),
        .CLKS_PER_MS(50000), .DUR_MS_RIGHT(200), .DUR_MS_WRONG(120)
    ) u_buzzer (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .evt_clk(video_clk), .evt_rst_n(pix_rst_n),
        .beep_start(beep_start_v), .beep_kind(beep_kind_v),
        .spk(spk)
    );

    // LEDs: fault codes first, then {mode==training, auto, bank}
    assign led = storage_error_sys ? 4'hf :
                 audio_fault_sys ? 4'hd :
                 video_fault_sys ? video_error_low_sys :
                 // audit P2-4: gray-decoded copy, not the raw pix-domain index
                 player_enable_sys ? {!display_mode_sys, auto_enabled, active_index_sys} :
                 {1'b0, 1'b0, &image_complete_sys,
                  mem_locked & video_locked};

endmodule
