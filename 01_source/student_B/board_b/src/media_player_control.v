`timescale 1ns/1ps

module media_player_control #(
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000,
    // 1 enables goto_active/goto_index/auto_hold (ShengSheng scene control).
    // 0 ignores those ports entirely, so existing instances that leave them
    // unconnected behave bit-exactly as before.
    parameter integer ENABLE_GOTO = 0
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        next_event,
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [3:0]  image_complete,
    input  wire        goto_active,         // next_event selects goto_index
    input  wire [1:0]  goto_index,
    input  wire        auto_hold,           // pause the slideshow timer
    output reg         auto_enabled,
    output reg  [31:0] active_period_cycles,
    output reg  [1:0]  pending_index,
    output reg  [7:0]  control_error,
    output wire        request_busy,
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        frame_start,
    output reg  [1:0]  active_index,
    output reg         index_commit
);
    localparam ERR_NONE = 8'h00;
    localparam ERR_PERIOD_RANGE = 8'h51;
    localparam ERR_REQUEST_BUSY = 8'h52;
    localparam ERR_NO_RESOURCE = 8'h53;

    reg [31:0] auto_counter;
    reg [1:0] sys_current_index;
    reg request_toggle;
    reg ack_toggle_pix;
    reg ack_sync1, ack_sync2;
    reg [1:0] index_sync1, index_sync2;
    reg req_sync1, req_sync2;
    reg req_seen_pix;
    reg index_settle;
    reg [1:0] requested_index_pix;
    reg commit_pending_pix;

    assign request_busy = request_toggle != ack_sync2;
    wire goto_en = (ENABLE_GOTO != 0) && goto_active;
    wire hold_en = (ENABLE_GOTO != 0) && auto_hold;

    function [2:0] next_available;
        input [1:0] current;
        input [3:0] complete;
        integer step;
        reg [1:0] candidate;
        begin
            next_available = {1'b0, current};
            for (step = 1; step <= 4; step = step + 1) begin
                candidate = current + step[1:0];
                if (!next_available[2] && complete[candidate])
                    next_available = {1'b1, candidate};
            end
        end
    endfunction

    task issue_next_request;
        input use_goto;
        reg [2:0] selected;
        begin
            if (use_goto && image_complete[goto_index])
                selected = {1'b1, goto_index};
            else
                selected = next_available(sys_current_index, image_complete);
            if (request_busy) begin
                control_error <= ERR_REQUEST_BUSY;
            end else if (!selected[2]) begin
                // R7-A3-F2: wait a full period before retrying -- the old
                // code kept the counter armed and re-errored every cycle
                control_error <= ERR_NO_RESOURCE;
                auto_counter <= 32'd0;
            end else begin
                control_error <= ERR_NONE;   // R7-A3-F2: status, not latch
                pending_index <= selected[1:0];
                request_toggle <= ~request_toggle;
                auto_counter <= 32'd0;
            end
        end
    endtask

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            auto_enabled <= 1'b0;
            active_period_cycles <= DEFAULT_PERIOD_CYCLES;
            pending_index <= 2'd0;
            control_error <= ERR_NONE;
            auto_counter <= 32'd0;
            sys_current_index <= 2'd0;
            request_toggle <= 1'b0;
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle_pix;
            ack_sync2 <= ack_sync1;
            if (!request_busy)
                sys_current_index <= pending_index;

            if (period_cfg_valid) begin
                if (period_cfg_cycles < MIN_PERIOD_CYCLES ||
                    period_cfg_cycles > MAX_PERIOD_CYCLES) begin
                    control_error <= ERR_PERIOD_RANGE;
                end else begin
                    active_period_cycles <= period_cfg_cycles;
                    auto_counter <= 32'd0;
                end
            end

            if (auto_cfg_valid) begin
                auto_enabled <= auto_cfg_enabled;
                auto_counter <= 32'd0;
            end

            if (toggle_auto_event) begin
                auto_enabled <= ~auto_enabled;
                auto_counter <= 32'd0;
            end

            if (next_event) begin
                issue_next_request(goto_en);
            end else if (auto_enabled && !hold_en) begin
                if (request_busy)
                    auto_counter <= 32'd0;
                else if (auto_counter >= active_period_cycles - 1'b1)
                    issue_next_request(1'b0);
                else
                    auto_counter <= auto_counter + 1'b1;
            end else begin
                auto_counter <= 32'd0;
            end
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            index_sync1 <= 2'd0;
            index_sync2 <= 2'd0;
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            req_seen_pix <= 1'b0;
            requested_index_pix <= 2'd0;
            index_settle <= 1'b1;
            commit_pending_pix <= 1'b0;
            active_index <= 2'd0;
            index_commit <= 1'b0;
            ack_toggle_pix <= 1'b0;
        end else begin
            index_sync1 <= pending_index;
            index_sync2 <= index_sync1;
            req_sync1 <= request_toggle;
            req_sync2 <= req_sync1;
            index_commit <= 1'b0;

            // audit hardening: pending_index (2 bit) rides its own 2FF
            // chain next to the request toggle, so at the detect edge
            // index_sync2 may still be the previous image. pending_index
            // only changes with a request (>=20 ms apart), so sampling the
            // index ONE CYCLE after the detect guarantees both chains have
            // resolved -- before this, the capture could park a stale index
            // for the whole pending window.
            if (req_sync2 != req_seen_pix && !commit_pending_pix) begin
                req_seen_pix <= req_sync2;
                index_settle <= 1'b0;
                commit_pending_pix <= 1'b1;
            end else if (commit_pending_pix && !index_settle) begin
                index_settle <= 1'b1;
                requested_index_pix <= index_sync2;
            end

            if (frame_start && commit_pending_pix && index_settle) begin
                active_index <= requested_index_pix;
                index_commit <= 1'b1;
                commit_pending_pix <= 1'b0;
                ack_toggle_pix <= req_seen_pix;
            end
        end
    end
endmodule
