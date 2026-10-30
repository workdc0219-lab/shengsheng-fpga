`timescale 1ns/1ps

// P0 board-mounted buzzer feedback (docs/08 section 5): the training game
// beeps right/wrong directly on the board speaker, no HDMI audio needed.
//
//   kind = 1  correct  -> C6, 1046 Hz, 200 ms
//   kind = 0  wrong    -> G4,  392 Hz, 120 ms
//
// The event source lives in the video domain (the top derives beep_start and
// beep_kind from sc_valid/sc_stars); the square-wave generator and the beep
// duration counter run on sys_clk (50 MHz). Per the house CDC rule
// (sync_2ff header: never 2FF a single-cycle pulse) the video-domain event
// is converted to a toggle on evt_clk, 2FF-synchronised into sys_clk and
// edge-detected there -- the same pattern the top already uses for the
// game's goto requests. beep_kind is a multi-cycle-stable level around the
// event and crosses through a plain per-bit 2FF; by the time the toggled
// event is detected its synchronised copy has long settled, so the kind is
// sampled correctly. Tone half-period dividers: 50000000/(2*1046) ~ 23899,
// 50000000/(2*392) ~ 63776.
module buzzer_feedback #(
    parameter integer DIV_RIGHT   = 23899,   // half period, 1046.1 Hz at 50 MHz
    parameter integer DIV_WRONG   = 63776,   // half period,  392.0 Hz at 50 MHz
    parameter integer CLKS_PER_MS = 50000,
    parameter integer DUR_MS_RIGHT = 200,
    parameter integer DUR_MS_WRONG = 120
) (
    input  wire clk,          // sys_clk, 50 MHz (tone generator domain)
    input  wire rst_n,        // sys-domain reset (ctrl_rst_n)
    input  wire evt_clk,      // video_clk, 25 MHz (event pulse domain)
    input  wire evt_rst_n,    // reset for the event domain (pix_rst_n)
    input  wire beep_start,   // 1-clk pulse in evt_clk
    input  wire beep_kind,    // 0 = wrong (G4), 1 = right (C6), stable at event
    output reg  spk           // board buzzer (H11), low when idle
);
    // ---- video-domain side: event pulse -> toggle ----
    reg evt_toggle, evt_kind;
    always @(posedge evt_clk or negedge evt_rst_n) begin
        if (!evt_rst_n) begin
            evt_toggle <= 1'b0;
            evt_kind <= 1'b0;
        end else if (beep_start) begin
            evt_toggle <= ~evt_toggle;
            evt_kind <= beep_kind;
        end
    end

    // ---- sys-domain side: 2FF + edge detect, kind sampling, tone gen ----
    reg [1:0]  evt_sync;
    reg        evt_prev;
    reg        kind_meta, kind_sync;
    reg        playing;
    reg [23:0] half_div;
    reg [23:0] half_cnt;
    reg [19:0] ms_cnt;
    reg [15:0] ms_left;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            evt_sync  <= 2'b00;
            evt_prev  <= 1'b0;
            kind_meta <= 1'b0;
            kind_sync <= 1'b0;
            playing   <= 1'b0;
            half_div  <= DIV_WRONG;
            half_cnt  <= 24'd0;
            ms_cnt    <= 20'd0;
            ms_left   <= 16'd0;
            spk       <= 1'b0;
        end else begin
            evt_sync  <= {evt_sync[0], evt_toggle};
            kind_meta <= evt_kind;
            kind_sync <= kind_meta;
            evt_prev  <= evt_sync[1];

            if (evt_sync[1] ^ evt_prev) begin
                // fresh event: latch the (already settled) kind, start/restart
                playing   <= 1'b1;
                ms_cnt    <= 20'd0;
                ms_left   <= kind_sync ? DUR_MS_RIGHT[15:0] : DUR_MS_WRONG[15:0];
                half_cnt  <= 24'd0;
                half_div  <= kind_sync ? DIV_RIGHT[23:0] : DIV_WRONG[23:0];
                spk       <= 1'b1;
            end else if (playing) begin
                if (ms_cnt == CLKS_PER_MS - 1) begin
                    ms_cnt <= 20'd0;
                    if (ms_left <= 16'd1)
                        playing <= 1'b0;    // beep finished; spk clears below
                    else
                        ms_left <= ms_left - 16'd1;
                end else begin
                    ms_cnt <= ms_cnt + 20'd1;
                end
                if (half_cnt == half_div - 24'd1) begin
                    half_cnt <= 24'd0;
                    spk      <= ~spk;
                end else begin
                    half_cnt <= half_cnt + 24'd1;
                end
            end else begin
                spk <= 1'b0;
            end
        end
    end
endmodule
