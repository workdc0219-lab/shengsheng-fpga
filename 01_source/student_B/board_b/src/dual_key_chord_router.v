`timescale 1ns/1ps

module dual_key_chord_router #(
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter integer HOLD_CYCLES = 100000000,
    // KEY3 held alone for this long, then released, emits key3_long_event
    // (brightness ladder) instead of the single-click auto toggle.
    parameter integer KEY3_LONG_CYCLES = 50000000,
    // V8: KEY2 held alone for this long, then released, emits key2_long_event
    // instead of key2_event. 0 keeps the V7 behaviour (every release is a
    // short press). Shares the KEY3 hold counter; the two states are exclusive.
    parameter integer KEY2_LONG_CYCLES = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire save_enabled,
    input  wire key2_n,
    input  wire key3_n,
    output reg  key2_event,
    output reg  key3_event,
    output reg  key3_long_event,
    output reg  key2_long_event,
    output wire save_event,
    output wire save_locked,
    output wire key2_stable_n,
    output wire key3_stable_n
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_KEY2 = 2'd1;
    localparam [1:0] ST_KEY3 = 2'd2;
    localparam [1:0] ST_CHORD = 2'd3;

    reg [1:0] state;
    reg save_armed;
    wire guard_trigger;
    reg [31:0] key3_hold_count;
    reg key3_long_marked;

    initial begin
        if (DEBOUNCE_CYCLES < 1 || HOLD_CYCLES < 1) begin
            $display("DUAL_KEY_CHORD_ROUTER_CONFIG_ERROR invalid timing parameter");
            $finish;
        end
    end

    dual_key_long_hold_guard #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .HOLD_CYCLES(HOLD_CYCLES)
    ) u_guard (
        .clk(clk), .rst_n(rst_n),
        .enabled(save_enabled && save_armed && state == ST_CHORD),
        .key2_n(key2_n), .key3_n(key3_n), .trigger(guard_trigger),
        .locked(save_locked), .key2_stable_n(key2_stable_n),
        .key3_stable_n(key3_stable_n)
    );

    assign save_event = guard_trigger;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            save_armed <= 1'b0;
            key2_event <= 1'b0;
            key3_event <= 1'b0;
            key3_long_event <= 1'b0;
            key2_long_event <= 1'b0;
            key3_hold_count <= 32'd0;
            key3_long_marked <= 1'b0;
        end else begin
            key2_event <= 1'b0;
            key3_event <= 1'b0;
            key3_long_event <= 1'b0;
            key2_long_event <= 1'b0;

            if (!save_enabled)
                save_armed <= 1'b0;
            else if (key2_stable_n && key3_stable_n)
                save_armed <= 1'b1;

            case (state)
                ST_IDLE: begin
                    if (!key2_stable_n && !key3_stable_n)
                        state <= ST_CHORD;
                    else if (!key2_stable_n) begin
                        state <= ST_KEY2;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                    end
                    else if (!key3_stable_n) begin
                        state <= ST_KEY3;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                    end
                end
                ST_KEY2: begin
                    if (!key2_stable_n && !key3_stable_n) begin
                        state <= ST_CHORD;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                    end else if (key2_stable_n) begin
                        if (KEY2_LONG_CYCLES != 0 && key3_long_marked)
                            key2_long_event <= 1'b1;
                        else
                            key2_event <= 1'b1;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                        state <= key3_stable_n ? ST_IDLE : ST_KEY3;
                    end else if (KEY2_LONG_CYCLES != 0 && key3_hold_count < KEY2_LONG_CYCLES) begin
                        key3_hold_count <= key3_hold_count + 1'b1;
                        if (key3_hold_count == KEY2_LONG_CYCLES - 1)
                            key3_long_marked <= 1'b1;
                    end
                end
                ST_KEY3: begin
                    if (!key2_stable_n && !key3_stable_n) begin
                        // KEY2 joining cancels the long-press ladder and
                        // hands the pair to the save chord.
                        state <= ST_CHORD;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                    end else if (key3_stable_n) begin
                        if (key3_long_marked)
                            key3_long_event <= 1'b1;
                        else
                            key3_event <= 1'b1;
                        key3_hold_count <= 32'd0;
                        key3_long_marked <= 1'b0;
                        state <= key2_stable_n ? ST_IDLE : ST_KEY2;
                    end else if (key3_hold_count < KEY3_LONG_CYCLES) begin
                        key3_hold_count <= key3_hold_count + 1'b1;
                        if (key3_hold_count == KEY3_LONG_CYCLES - 1)
                            key3_long_marked <= 1'b1;
                    end
                end
                ST_CHORD: begin
                    if (key2_stable_n && key3_stable_n)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
            end
    end
endmodule
