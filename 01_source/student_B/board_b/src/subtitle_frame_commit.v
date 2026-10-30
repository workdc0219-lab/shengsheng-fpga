`timescale 1ns/1ps

module subtitle_frame_commit (
    input  wire         src_clk,
    input  wire         src_rst_n,
    input  wire         src_commit,
    input  wire [95:0] src_text,
    input  wire [5:0]   src_length,
    input  wire         src_enable,
    input  wire         dst_clk,
    input  wire         dst_rst_n,
    input  wire         frame_start,
    output reg  [95:0] dst_text,
    output reg  [5:0]   dst_length,
    output reg          dst_enable
);
    reg commit_toggle;
    reg commit_sync1;
    reg commit_sync2;
    reg commit_seen;
    reg dst_initialized;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)
            commit_toggle <= 1'b0;
        else if (src_commit)
            commit_toggle <= ~commit_toggle;
    end

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            commit_sync1 <= 0;
            commit_sync2 <= 0;
            commit_seen <= 0;
            dst_initialized <= 0;
            dst_text <= 0;
            dst_length <= 0;
            dst_enable <= 0;
        end else begin
            commit_sync1 <= commit_toggle;
            commit_sync2 <= commit_sync1;
            if (frame_start && (!dst_initialized || commit_sync2 != commit_seen)) begin
                dst_text <= src_text;
                dst_length <= src_length;
                dst_enable <= src_enable;
                commit_seen <= commit_sync2;
                dst_initialized <= 1'b1;
            end
        end
    end
endmodule
