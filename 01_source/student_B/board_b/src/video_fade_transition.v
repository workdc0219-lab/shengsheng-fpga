`timescale 1ns/1ps

// Crossfade controller for the single-read-port player. A manual next event
// runs the full fade-out -> black dwell -> fade-in sequence and only releases
// the switch request to media_player_control at the fully black frame, so the
// SDRAM never has to serve two frames at once. Automatic slideshow switches
// cannot be anticipated (media_player_control issues them internally), so the
// idle state follows index_commit with a fade-in from black instead.
// FADE_FRAMES = 0 bypasses the whole machine: next_event passes straight
// through and alpha stays 255, keeping the legacy regression suites green.
// R7-A3-F3: the alpha ramp and wipe step assume 256 and H_ACT divide
// evenly by FADE_FRAMES (G5-class elaboration guard, shipped value 16).
// V8 push slide (ENABLE_SLIDE=1): style 1/2 replace the fade with a 32-frame
// eased push. A manual request is released to the player at once; on the
// commit edge the FSM publishes {old index, rows of the new image, dir} and
// media_frame_reader reads the frame as two linear SDRAM segments. All four
// pictures stay resident, so no second frame buffer is needed. Style 3
// rotates classic -> push up -> push down per transition.
module video_fade_transition #(
    parameter integer FADE_FRAMES = 0,
    parameter integer ENABLE_SLIDE = 0,
    parameter integer V_ACT = 480
) (
    input  wire       ctrl_clk,
    input  wire       ctrl_rst_n,
    input  wire       next_event_in,
    output wire       next_event_out,
    output wire       fade_busy,
    // Ready includes the request toggle acknowledgement, not just the delayed
    // busy flag. Consecutive control pulses cannot cancel before pixel CDC.
    output wire       request_ready,

    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       player_active,
    input  wire       frame_start,
    input  wire       index_commit,
    input  wire [1:0] active_index,
    output wire [7:0] alpha_out,
    // Exact Q8 coefficient for the product pixel path: unity is 256, not 255.
    // alpha_out remains the legacy 8-bit observation interface (unity=255).
    output wire [8:0] alpha_q8_out,
    output wire       fade_active,
    // Wipe reveal: automatic slideshow switches recover with a left-to-right
    // reveal instead of an alpha ramp. wipe_active gates the pixel-domain
    // coordinate compare; ramp_out drives the reveal boundary counter.
    output wire       wipe_active,
    output wire [4:0] ramp_out,
    output wire [1:0] transition_kind,
    // V8 slide (pixel domain; ignored when ENABLE_SLIDE=0)
    input  wire [1:0] slide_style,     // 0 classic, 1 push up, 2 push down, 3 rotate
    output wire       slide_active,
    output wire [1:0] slide_old_index,
    output wire [8:0] slide_rows,
    output wire       slide_dir
);

    initial begin
        if (ENABLE_SLIDE != 0 && (FADE_FRAMES == 0 || V_ACT < 2 || V_ACT > 480)) begin
            $display("FADE_TRANSITION_CONFIG_ERROR slide needs FADE_FRAMES>0 and 2<=V_ACT<=480");
            $finish;
        end
        if (FADE_FRAMES < 0 || FADE_FRAMES > 16 || (FADE_FRAMES != 0 && 256 % FADE_FRAMES != 0)) begin
            $display("FADE_TRANSITION_CONFIG_ERROR FADE_FRAMES=%0d must be 0 or a divisor of 256 no greater than 16",
                     FADE_FRAMES);
            $finish;
        end
    end
    generate
        if (FADE_FRAMES == 0) begin : g_bypass
            assign next_event_out = next_event_in;
            assign fade_busy = 1'b0;
            assign request_ready = 1'b1;
            assign alpha_out = 8'd255;
            assign alpha_q8_out = 9'd256;
            assign fade_active = 1'b0;
            assign wipe_active = 1'b0;
            assign ramp_out = 5'd0;
            assign transition_kind = 2'd0;
            assign slide_active = 1'b0;
            assign slide_old_index = 2'd0;
            assign slide_rows = 9'd0;
            assign slide_dir = 1'b0;
        end else begin : g_fade
            // 256 % FADE_FRAMES must be zero so the ramp spans exactly 0..255.
            localparam integer STEP = 256 / FADE_FRAMES;
            // ramp holds FADE_FRAMES while unaligned, so it needs one more
            // value than a plain 0..FADE_FRAMES-1 counter.
            localparam integer CNT_W = (FADE_FRAMES <= 2) ? 2 : $clog2(FADE_FRAMES + 1);

            localparam [2:0] S_IDLE = 3'd0;
            localparam [2:0] S_OUT  = 3'd1;
            localparam [2:0] S_HOLD = 3'd2;
            localparam [2:0] S_IN   = 3'd3;
            localparam [2:0] S_SWAIT = 3'd4;   // slide: request released, wait commit
            localparam [2:0] S_SLIDE = 3'd5;   // slide: 32 eased frames

            // ---- shared registers (declared before both always blocks) ----
            reg req_toggle;
            reg ack_seen;
            reg commit_sync1, commit_sync2;
            reg busy_sync1, busy_sync2;
            reg seen_sync1, seen_sync2;

            // ---- pixel-domain sequencer ----
            reg [2:0] state;
            reg [CNT_W-1:0] ramp;
            // ---- V8 slide ----
            reg [1:0] shown_index;      // index displayed before this commit
            reg [1:0] rot;              // style-3 rotation position
            reg [4:0] sramp;
            reg s_active;
            reg s_dir;
            reg [1:0] s_old;
            reg [8:0] s_rows;
            wire [1:0] eff_style = (ENABLE_SLIDE == 0) ? 2'd0 :
                                   (slide_style == 2'd3) ? rot : slide_style;
            wire slide_pick = (eff_style == 2'd1) || (eff_style == 2'd2);
            // cubic ease-in-out of 480 rows; other heights (fast simulation
            // geometries) scale the table -- the conditional is on a
            // parameter, so the product build keeps the plain constant table
            function [8:0] slide_ease;
                input [4:0] t;
                reg [8:0] e480;
                begin
                    case (t)
                        5'd0: e480 = 9'd0;
                        5'd1: e480 = 9'd1;
                        5'd2: e480 = 9'd1;
                        5'd3: e480 = 9'd2;
                        5'd4: e480 = 9'd4;
                        5'd5: e480 = 9'd7;
                        5'd6: e480 = 9'd13;
                        5'd7: e480 = 9'd20;
                        5'd8: e480 = 9'd30;
                        5'd9: e480 = 9'd43;
                        5'd10: e480 = 9'd59;
                        5'd11: e480 = 9'd78;
                        5'd12: e480 = 9'd101;
                        5'd13: e480 = 9'd129;
                        5'd14: e480 = 9'd161;
                        5'd15: e480 = 9'd198;
                        5'd16: e480 = 9'd240;
                        5'd17: e480 = 9'd282;
                        5'd18: e480 = 9'd319;
                        5'd19: e480 = 9'd351;
                        5'd20: e480 = 9'd379;
                        5'd21: e480 = 9'd402;
                        5'd22: e480 = 9'd421;
                        5'd23: e480 = 9'd437;
                        5'd24: e480 = 9'd450;
                        5'd25: e480 = 9'd460;
                        5'd26: e480 = 9'd467;
                        5'd27: e480 = 9'd473;
                        5'd28: e480 = 9'd476;
                        5'd29: e480 = 9'd478;
                        5'd30: e480 = 9'd479;
                        5'd31: e480 = 9'd479;
                        default: e480 = 9'd479;
                    endcase
                    if (V_ACT == 480)
                        slide_ease = e480;
                    else if (t == 5'd0)
                        slide_ease = 9'd0;
                    else
                        slide_ease = ((e480 * V_ACT) / 480 == 0) ? 9'd1 :
                                     ((e480 * V_ACT) / 480 >= V_ACT) ? V_ACT - 1 :
                                     (e480 * V_ACT) / 480;
                end
            endfunction
            assign slide_active = s_active;
            assign slide_old_index = s_old;
            assign slide_rows = s_rows;
            assign slide_dir = s_dir;
            reg req_sync1, req_sync2, req_seen;
            reg commit_toggle;
            reg wipe_mode;
            reg [1:0] wipe_kind;

            wire fade_running = (state != S_IDLE);
            assign fade_active = fade_running;
            // ramp is CNT_W bits; zero-extend explicitly because an
            // out-of-range part select would read as X.
            assign ramp_out = {{(5-CNT_W){1'b0}}, ramp};
            assign wipe_active = (state == S_IN) && wipe_mode;
            assign transition_kind = wipe_kind;

            wire [CNT_W+8:0] ramp_alpha = ramp * STEP;
            wire [7:0] ramp_alpha8 = ramp_alpha[7:0];
            // ramp == FADE_FRAMES means the request arrived mid-frame and the
            // current frame must still display untouched full brightness; the
            // fade visibly starts with the next complete frame.
            wire unity_state = (state == S_IDLE) || (state == S_SWAIT) ||
                               (state == S_SLIDE) || ((state == S_IN) && wipe_mode);
            assign alpha_out = unity_state ? 8'd255 :
                               (state == S_HOLD)  ? 8'd0   :
                                (ramp == FADE_FRAMES) ? 8'd255 : ramp_alpha8;
            assign alpha_q8_out = unity_state ? 9'd256 :
                                 (state == S_HOLD) ? 9'd0 :
                                 (ramp == FADE_FRAMES) ? 9'd256 : {1'b0,ramp_alpha8};

            always @(posedge pix_clk or negedge pix_rst_n) begin
                if (!pix_rst_n) begin
                    state <= S_IDLE;
                    ramp <= {CNT_W{1'b0}};
                    req_sync1 <= 1'b0;
                    req_sync2 <= 1'b0;
                    req_seen <= 1'b0;
                    commit_toggle <= 1'b0;
                    wipe_mode <= 1'b0;
                    wipe_kind <= 2'd0;
                    shown_index <= 2'd0;
                    rot <= 2'd0;
                    sramp <= 5'd0;
                    s_active <= 1'b0;
                    s_dir <= 1'b0;
                    s_old <= 2'd0;
                    s_rows <= 9'd0;
                end else begin
                    req_sync1 <= req_toggle;
                    req_sync2 <= req_sync1;
                    // index_commit is registered with active_index, so on the
                    // commit cycle shown_index still holds the outgoing bank.
                    if (!index_commit)
                        shown_index <= active_index;

                    case (state)
                    S_IDLE: begin
                        if (req_sync2 != req_seen) begin
                            req_seen <= req_sync2;
                            if (player_active && slide_pick) begin
                                // no fade-out: hand the request to the player
                                // now and start the push on its commit edge
                                state <= S_SWAIT;
                                commit_toggle <= ~commit_toggle;
                            end else if (player_active) begin
                                state <= S_OUT;
                                ramp <= FADE_FRAMES[CNT_W-1:0];
                            end
                        end else if (index_commit && player_active && slide_pick) begin
                            state <= S_SLIDE;
                            sramp <= 5'd0;
                            s_active <= 1'b1;
                            s_dir <= (eff_style == 2'd2);
                            s_old <= shown_index;
                            s_rows <= 9'd0;
                        end else if (index_commit && player_active) begin
                            // Automatic slideshow switch: the old frame is
                            // already committed away; reveal the new one
                            // left-to-right instead of fading from black.
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b1;
                            wipe_kind <= active_index;
                        end
                    end
                    S_OUT: begin
                        if (frame_start) begin
                            if (ramp == 0) begin
                                state <= S_HOLD;
                                commit_toggle <= ~commit_toggle;
                            end else begin
                                ramp <= ramp - 1'b1;
                            end
                        end
                        // Track the request handshake even mid-fade so a
                        // second early event cannot desync req_seen.
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                    end
                    S_HOLD: begin
                        if (index_commit) begin
                            state <= S_IN;
                            ramp <= {CNT_W{1'b0}};
                            wipe_mode <= 1'b0;
                        end
                    end
                    S_IN: begin
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                        if (frame_start) begin
                            if (ramp >= FADE_FRAMES) begin  // audit P2: FADE_FRAMES-1 froze the last 6% alpha / last wipe columns
                                state <= S_IDLE;
                                rot <= (rot == 2'd2) ? 2'd0 : rot + 1'b1;
                            end else
                                ramp <= ramp + 1'b1;
                        end
                    end
                    S_SWAIT: begin
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                        if (!player_active) begin
                            state <= S_IDLE;
                        end else if (index_commit) begin
                            state <= S_SLIDE;
                            sramp <= 5'd0;
                            s_active <= 1'b1;
                            s_dir <= (eff_style == 2'd2);
                            s_old <= shown_index;
                            s_rows <= 9'd0;
                        end
                    end
                    S_SLIDE: begin
                        if (req_sync2 != req_seen)
                            req_seen <= req_sync2;
                        // rows update on frame_start; the reader samples the
                        // bus two pixel clocks later for the same frame
                        if (frame_start) begin
                            if (sramp == 5'd31) begin
                                state <= S_IDLE;
                                s_active <= 1'b0;
                                s_rows <= 9'd0;
                                rot <= (rot == 2'd2) ? 2'd0 : rot + 1'b1;
                            end else begin
                                sramp <= sramp + 1'b1;
                                s_rows <= slide_ease(sramp + 1'b1);
                            end
                        end
                    end
                    default: state <= S_IDLE;
                    endcase
                end
            end

            // ---- control-domain bookkeeping ----
            assign fade_busy = busy_sync2;
            assign request_ready = !busy_sync2 && (req_toggle == seen_sync2);
            assign next_event_out = (commit_sync2 != ack_seen);

            always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
                if (!ctrl_rst_n) begin
                    req_toggle <= 1'b0;
                    ack_seen <= 1'b0;
                    commit_sync1 <= 1'b0;
                    commit_sync2 <= 1'b0;
                    busy_sync1 <= 1'b0;
                    busy_sync2 <= 1'b0;
                    seen_sync1 <= 1'b0;
                    seen_sync2 <= 1'b0;
                end else begin
                    busy_sync1 <= fade_running;
                    busy_sync2 <= busy_sync1;
                    seen_sync1 <= req_seen;
                    seen_sync2 <= seen_sync1;
                    commit_sync1 <= commit_toggle;
                    commit_sync2 <= commit_sync1;
                    // Events during an active fade are dropped; the display
                    // is already transitioning and control cannot accept a
                    // second request before the black dwell anyway.
                    if (next_event_in && request_ready)
                        req_toggle <= ~req_toggle;
                    if (commit_sync2 != ack_seen)
                        ack_seen <= commit_sync2;
                end
            end
        end
    endgenerate
endmodule
