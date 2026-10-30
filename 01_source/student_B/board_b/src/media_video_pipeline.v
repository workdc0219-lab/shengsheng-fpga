`timescale 1ns/1ps

module media_video_pipeline #(
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 16,
    parameter integer H_ACT = 640,
    parameter integer H_FP = 16,
    parameter integer H_SYNC = 96,
    parameter integer H_BP = 48,
    parameter integer V_ACT = 480,
    parameter integer V_FP = 10,
    parameter integer V_SYNC = 2,
    parameter integer V_BP = 33,
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000,
    // Non-zero enables the fade-out/black/fade-in transition on manual
    // switches and a fade-in on automatic slideshow switches. Zero keeps the
    // legacy direct-switch behaviour for the existing regression suites.
    parameter integer FADE_FRAMES = 0,
    // 1 routes goto_valid/goto_index/auto_hold to the player control
    parameter integer ENABLE_GOTO = 0,
    // V8: 1 adds the push-slide transition (video_fade_transition +
    // two-segment media_frame_reader). 0 keeps the V7 pipeline bit-exact.
    parameter integer ENABLE_SLIDE = 0,
    // V8: 1 adds the five-level picture contrast stage (shift-add around
    // mid-grey, no DSP). 0 keeps the V7 pipeline bit-exact.
    parameter integer ENABLE_CONTRAST = 0
) (
    input  wire        ctrl_clk,
    input  wire        ctrl_rst_n,
    input  wire        next_event,
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [3:0]  image_complete,
    input  wire        goto_valid,          // ctrl domain pulse: fade to goto_index
    input  wire [1:0]  goto_index,
    input  wire        auto_hold,
    input  wire        player_enable,

    input  wire        mem_clk,
    input  wire        mem_rst_n,
    input  wire        controller_init_done,
    input  wire        controller_busy,
    input  wire        refresh_active,
    output wire        app_rd_en,
    output wire [20:0] app_rd_addr,
    input  wire        sdram_rd_valid,
    input  wire [31:0] sdram_rd_data,

    input  wire [7:0]  brightness,
    input  wire [2:0]  contrast,            // pix domain, 0..4 = 50..150 %, 2 = unity
    input  wire [1:0]  slide_style,         // pix domain: 0 fade, 1 up, 2 down, 3 rotate
    output wire        slide_busy,          // pix domain: push in progress
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    output wire        video_clk,
    output wire        video_hs,
    output wire        video_vs,
    output wire        video_de,
    output wire [23:0] video_rgb,
    output wire [9:0]  video_x,

    output wire [1:0]  active_index,
    output wire [1:0]  pending_index,
    output wire        auto_enabled,
    output wire        frame_start,
    output wire        reader_busy,
    output wire        reader_underflow,
    output wire [7:0]  video_error
);
    wire raw_hs;
    wire raw_vs;
    wire raw_de;
    wire [11:0] raw_x;
    wire [11:0] raw_y;
    localparam integer H_BLANK = H_FP + H_SYNC + H_BP;
    localparam integer V_BLANK = V_FP + V_SYNC + V_BP;
    wire [11:0] active_x = (raw_x >= H_BLANK) ? raw_x - H_BLANK : 12'd0;
    wire [11:0] active_y = (raw_y >= V_BLANK) ? raw_y - V_BLANK : 12'd0;
    reg raw_vs_q;
    reg [9:0] video_x_q;
    wire index_commit;
    wire [7:0] control_error;
    wire request_busy;
    wire [31:0] active_period_cycles;
    wire [23:0] reader_rgb;
    wire reader_pixel_valid;
    wire reader_done;
    wire [1:0] reader_index;
    wire [7:0] reader_error;
    wire player_enable_pix;
    reg [7:0] reader_error_pix1;
    reg [7:0] reader_error_pix2;
    reg [7:0] control_error_pix1;
    reg [7:0] control_error_pix2;
    // Contrast acts on picture pixels only: blank/invalid pixels stay black
    // and the fade multiply below still ramps to true black.
    wire [23:0] picture_rgb;
    generate
        if (ENABLE_CONTRAST == 0) begin : g_contrast_bypass
            assign picture_rgb = reader_rgb;
        end else begin : g_contrast
            // y = 128 + k * (x - 128), k = 1/2, 3/4, 1, 5/4, 3/2, clamped
            function [7:0] contrast_channel;
                input [7:0] x;
                input [2:0] level;
                reg signed [9:0] d;
                reg signed [10:0] y;
                begin
                    d = $signed({2'b00, x}) - 10'sd128;
                    case (level)
                        3'd0: y = (d >>> 1);
                        3'd1: y = (d >>> 1) + (d >>> 2);
                        3'd3: y = d + (d >>> 2);
                        3'd4: y = d + (d >>> 1);
                        default: y = d;
                    endcase
                    y = y + 11'sd128;
                    contrast_channel = (y < 0) ? 8'd0 : (y > 255) ? 8'd255 : y[7:0];
                end
            endfunction
            assign picture_rgb = {contrast_channel(reader_rgb[23:16], contrast),
                                  contrast_channel(reader_rgb[15:8], contrast),
                                  contrast_channel(reader_rgb[7:0], contrast)};
        end
    endgenerate
    wire [23:0] selected_rgb =
        (player_enable_pix && reader_pixel_valid && reader_error_pix2 == 0) ?
        picture_rgb : 24'h000000;

    sync_2ff u_player_enable_pix (
        .clk(pix_clk), .rst_n(pix_rst_n), .async_in(player_enable),
        .sync_out(player_enable_pix)
    );

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            reader_error_pix1 <= 8'd0;
            reader_error_pix2 <= 8'd0;
            control_error_pix1 <= 8'd0;
            control_error_pix2 <= 8'd0;
        end else begin
            reader_error_pix1 <= reader_error;
            reader_error_pix2 <= reader_error_pix1;
            control_error_pix1 <= control_error;
            control_error_pix2 <= control_error_pix1;
        end
    end

    video_timing_ctrl #(
        .H_ACT(H_ACT), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACT(V_ACT), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP),
        .ACTIVE_LAST(1)
    ) u_timing (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hsync(raw_hs),
        .vsync(raw_vs), .de(raw_de), .x(raw_x), .y(raw_y)
    );

    // Fade transition: manual switch requests are held until the display has
    // faded to black, then released to the control FSM at the frame boundary.
    // The bypass branch (FADE_FRAMES=0) wires next_event straight through so
    // legacy regression timing is unchanged.
    wire fade_next_event;
    wire fade_request_ready;
    wire fade_engine_ready;
    wire [8:0] fade_alpha;
    wire wipe_active;
    wire [4:0] wipe_ramp;
    wire [1:0] transition_kind;
    wire slide_active;
    wire [1:0] slide_old_index;
    wire [8:0] slide_rows;
    wire slide_dir;
    assign slide_busy = slide_active;
    // A goto request rides the normal manual-switch path (fade out, black,
    // fade in); the latched target is applied when the fade releases it.
    reg goto_pending;
    reg [1:0] goto_target;
    wire goto_req = (ENABLE_GOTO != 0) && goto_valid;
    // A previously accepted automatic request owns its pending frame commit.
    // Target latching and fade CDC consume the SAME acceptance event: a later
    // manual pulse cannot start fading a bank AUTO has yet to change.
    assign fade_request_ready = fade_engine_ready && !request_busy;
    wire manual_accept = (next_event || goto_req) && fade_request_ready;
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            goto_pending <= 1'b0;
            goto_target <= 2'd0;
        end else if (manual_accept) begin
            // The first accepted event owns its target until black commit.
            // Busy repeats must not turn a next into goto or retarget a goto.
            goto_pending <= goto_req;
            if (goto_req)
                goto_target <= goto_index;
        end else if (fade_next_event) begin
            goto_pending <= 1'b0;
        end
    end
    video_fade_transition #(.FADE_FRAMES(FADE_FRAMES), .ENABLE_SLIDE(ENABLE_SLIDE),
                            .V_ACT(V_ACT)) u_fade (
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(ctrl_rst_n),
        .next_event_in(manual_accept), .next_event_out(fade_next_event),
        .fade_busy(), .request_ready(fade_engine_ready),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .player_active(player_enable_pix), .frame_start(frame_start),
        .index_commit(index_commit), .active_index(active_index),
        .alpha_out(), .alpha_q8_out(fade_alpha), .fade_active(),
        .wipe_active(wipe_active), .ramp_out(wipe_ramp),
        .transition_kind(transition_kind),
        .slide_style(slide_style), .slide_active(slide_active),
        .slide_old_index(slide_old_index), .slide_rows(slide_rows),
        .slide_dir(slide_dir)
    );

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            raw_vs_q <= 1'b1;
        else
            raw_vs_q <= raw_vs;
    end
    assign frame_start = raw_vs_q && !raw_vs;

    // rgb_video_adapter registers hs/vs/de/rgb by one pixel. Register x in
    // parallel so the HDMI Data Island scheduler sees the coordinate belonging
    // to the same output character, rather than the next raw VTC position.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            video_x_q <= 10'd0;
        else
            video_x_q <= active_x[9:0];
    end
    assign video_x = video_x_q;

    media_player_control #(
        .DEFAULT_PERIOD_CYCLES(DEFAULT_PERIOD_CYCLES),
        .MIN_PERIOD_CYCLES(MIN_PERIOD_CYCLES),
        .MAX_PERIOD_CYCLES(MAX_PERIOD_CYCLES),
        .ENABLE_GOTO(ENABLE_GOTO)
    ) u_control (
        .sys_clk(ctrl_clk), .sys_rst_n(ctrl_rst_n),
        .next_event(fade_next_event), .toggle_auto_event(toggle_auto_event),
        .period_cfg_valid(period_cfg_valid),
        .period_cfg_cycles(period_cfg_cycles),
        .auto_cfg_valid(auto_cfg_valid),
        .auto_cfg_enabled(auto_cfg_enabled),
        .image_complete(image_complete),
        .goto_active((FADE_FRAMES == 0) ? goto_req : goto_pending),
        .goto_index((FADE_FRAMES == 0) ? goto_index : goto_target),
        // Manual commands win against expiry on the same control edge, and
        // no automatic commit may replace the old bank during fade-out.
        .auto_hold((ENABLE_GOTO != 0) && (auto_hold ||
                   ((FADE_FRAMES != 0) && (!fade_request_ready || next_event || goto_req)))),
        .auto_enabled(auto_enabled),
        .active_period_cycles(active_period_cycles),
        .pending_index(pending_index), .control_error(control_error),
        .request_busy(request_busy), .pix_clk(pix_clk),
        .pix_rst_n(pix_rst_n), .frame_start(frame_start),
        .active_index(active_index), .index_commit(index_commit)
    );

    media_frame_reader #(
        .ADDR_WIDTH(21), .IMAGE_WORDS(IMAGE_WORDS),
        .FIFO_DEPTH(FIFO_DEPTH), .FIFO_MARGIN(FIFO_MARGIN),
        .MAX_INFLIGHT_BURSTS(2), .DIAG_RETURN_PATTERN(0),
        .DIAG_SYNTH_STREAM(0), .ENABLE_SLIDE(ENABLE_SLIDE), .IMAGE_WIDTH(H_ACT)
    ) u_reader (
        .mem_clk(mem_clk), .mem_rst_n(mem_rst_n),
        .controller_init_done(controller_init_done && player_enable),
        .controller_busy(controller_busy), .refresh_active(refresh_active),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
        .sdram_rd_valid(sdram_rd_valid), .sdram_rd_data(sdram_rd_data),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .frame_start(frame_start && player_enable_pix), .active_index(active_index),
        .slide_active(slide_active), .slide_old_index(slide_old_index),
        .slide_rows(slide_rows), .slide_dir(slide_dir),
        .pixel_consume(raw_de && player_enable_pix), .pixel_rgb(reader_rgb),
        .pixel_valid(reader_pixel_valid), .underflow(reader_underflow),
        .reader_busy(reader_busy), .frame_read_done(reader_done),
        .reader_index(reader_index), .reader_error(reader_error)
    );

    // Fade multiplies the selected frame by the ramp alpha; an automatic
    // slideshow switch instead reveals the new frame left-to-right: pixels
    // right of the moving boundary stay black, the rest show full colour.
    // With FADE_FRAMES=0 the direct assignment keeps every pixel bit-identical
    // to the legacy path so strict regression comparisons still hold.
    wire [23:0] faded_rgb;
    generate
        if (FADE_FRAMES == 0) begin : g_fade_bypass
            assign faded_rgb = selected_rgb;
        end else begin : g_fade_mul
            // One final floor: floor(rgb * fade_q8 * brightness_q8 / 65536).
            // The four product switch gains are 256,192,128,64. Factor their
            // powers of two to avoid another bank of DSP multipliers, and
            // explicitly widen the 3*t sum for 75% so no MSB can truncate.
            function [7:0] apply_brightness;
                input [16:0] fade_product;
                input [7:0] gain;
                reg [18:0] triple_product;
                begin
                    triple_product = {2'b00,fade_product} + {1'b0,fade_product,1'b0};
                    case (gain)
                        8'd255: apply_brightness = fade_product[15:8];
                        8'd192: apply_brightness = triple_product[17:10];
                        8'd128: apply_brightness = fade_product[16:9];
                        8'd64:  apply_brightness = {1'b0,fade_product[16:10]};
                        default: apply_brightness = fade_product[15:8];
                    endcase
                end
            endfunction
            wire [16:0] fade_mul_r = selected_rgb[23:16] * fade_alpha;
            wire [16:0] fade_mul_g = selected_rgb[15:8] * fade_alpha;
            wire [16:0] fade_mul_b = selected_rgb[7:0] * fade_alpha;
            wire [23:0] alpha_rgb =
                {apply_brightness(fade_mul_r,brightness),
                 apply_brightness(fade_mul_g,brightness),
                 apply_brightness(fade_mul_b,brightness)};
            // Reveal boundary advances one H_ACT/FADE_FRAMES column step per
            // frame; the comparison uses the same raw_x that aligns with
            // selected_rgb at this point in the pipeline.
            localparam integer WIPE_STEP = H_ACT / FADE_FRAMES;
            wire [9:0] wipe_boundary = wipe_ramp * WIPE_STEP;
            wire [6:0] blind_x_boundary = wipe_ramp * 4;
            reg transition_pixel;
            always @* begin
                case (transition_kind)
                    2'd0: transition_pixel = active_x[9:0] < wipe_boundary;
                    2'd1: transition_pixel = active_x[9:0] >= H_ACT - wipe_boundary;
                    2'd2: transition_pixel = {1'b0, active_x[5:0]} < blind_x_boundary;
                    default: transition_pixel = (active_x[6] ^ active_y[6]) ?
                        ({1'b0, active_x[5:0]} < blind_x_boundary) :
                        ({1'b0, active_x[5:0]} >= 7'd64 - blind_x_boundary);
                endcase
            end
            assign faded_rgb = wipe_active ?
                (transition_pixel ? alpha_rgb : 24'h000000) :
                alpha_rgb;
        end
    endgenerate

    rgb_video_adapter u_video_adapter (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hs_in(raw_hs),
        // Keep the HDMI AXI stream alive while loading or after a card fault.
        // selected_rgb already blanks unavailable picture data. Suppressing DE
        // here prevented the encrypted HDMI core from acquiring any frame,
        // turning a storage error into the monitor's "no signal" message.
        .vs_in(raw_vs), .de_in(raw_de),
        .rgb_in(faded_rgb), .video_clk(video_clk),
        .video_hs(video_hs), .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb)
    );

    assign video_error = reader_error_pix2 != 0 ? reader_error_pix2 :
                         reader_underflow ? 8'h63 : control_error_pix2;
endmodule
