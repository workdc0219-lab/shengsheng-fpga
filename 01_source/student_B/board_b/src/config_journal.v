`timescale 1ns/1ps

module config_journal (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        slot0_present,
    input  wire [31:0] slot0_version,
    input  wire [31:0] slot0_period,
    input  wire [7:0]  slot0_volume,
    input  wire [7:0]  slot0_mode,
    input  wire [15:0] slot0_crc,
    input  wire        slot1_present,
    input  wire [31:0] slot1_version,
    input  wire [31:0] slot1_period,
    input  wire [7:0]  slot1_volume,
    input  wire [7:0]  slot1_mode,
    input  wire [15:0] slot1_crc,
    output reg         load_done,
    output reg         config_valid,
    output reg  [31:0] active_version,
    output reg  [31:0] active_period,
    output reg  [7:0]  active_volume,
    output reg  [7:0]  active_mode,
    output reg         active_slot,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         record_ready,
    output reg         target_slot,
    output reg  [31:0] record_version,
    output reg  [31:0] record_period,
    output reg  [7:0]  record_volume,
    output reg  [7:0]  record_mode,
    output reg  [15:0] record_crc
);
    function [15:0] crc16_chunk40;
        input [15:0] crc_in;
        input [39:0] payload;
        integer i;
        reg [15:0] crc;
        begin
            crc = crc_in;
            for (i = 39; i >= 0; i = i - 1) begin
                if (crc[15] ^ payload[i])
                    crc = {crc[14:0],1'b0} ^ 16'h1021;
                else
                    crc = {crc[14:0],1'b0};
            end
            crc16_chunk40 = crc;
        end
    endfunction

    function version_newer;
        input [31:0] candidate;
        input [31:0] reference;
        reg [31:0] delta;
        begin
            delta = candidate - reference;
            version_newer = (candidate != reference) && !delta[31];
        end
    endfunction

    reg [1:0] load_phase;
    reg save_pending;
    reg slot0_present_q;
    reg slot1_present_q;
    reg [31:0] slot0_version_q;
    reg [31:0] slot1_version_q;
    reg [31:0] slot0_period_q;
    reg [31:0] slot1_period_q;
    reg [7:0] slot0_volume_q;
    reg [7:0] slot1_volume_q;
    reg [7:0] slot0_mode_q;
    reg [7:0] slot1_mode_q;
    reg [15:0] slot0_crc_q;
    reg [15:0] slot1_crc_q;
    reg [15:0] slot0_crc_mid;
    reg [15:0] slot1_crc_mid;
    reg [15:0] slot0_crc_calc;
    reg [15:0] slot1_crc_calc;
    reg [15:0] save_crc_mid;

    wire slot0_good = slot0_present_q && slot0_crc_q == slot0_crc_calc;
    wire slot1_good = slot1_present_q && slot1_crc_q == slot1_crc_calc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_done<=0; config_valid<=0; active_version<=0; active_period<=0;
            active_volume<=0; active_mode<=0; active_slot<=0;
            record_ready<=0; target_slot<=0;
            record_version<=0; record_period<=0; record_volume<=0; record_mode<=0;
            record_crc<=0;
            load_phase<=0; save_pending<=0;
            slot0_present_q<=0; slot1_present_q<=0;
            slot0_version_q<=0; slot1_version_q<=0;
            slot0_period_q<=0; slot1_period_q<=0;
            slot0_volume_q<=0; slot1_volume_q<=0;
            slot0_mode_q<=0; slot1_mode_q<=0;
            slot0_crc_q<=0; slot1_crc_q<=0;
            slot0_crc_mid<=0; slot1_crc_mid<=0;
            slot0_crc_calc<=0; slot1_crc_calc<=0; save_crc_mid<=0;
        end else begin
            load_done<=0;
            record_ready<=0;
            if(load_start) begin
                load_phase<=1;
                slot0_present_q<=slot0_present;
                slot1_present_q<=slot1_present;
                slot0_version_q<=slot0_version;
                slot1_version_q<=slot1_version;
                slot0_period_q<=slot0_period;
                slot1_period_q<=slot1_period;
                slot0_volume_q<=slot0_volume;
                slot1_volume_q<=slot1_volume;
                slot0_mode_q<=slot0_mode;
                slot1_mode_q<=slot1_mode;
                slot0_crc_q<=slot0_crc;
                slot1_crc_q<=slot1_crc;
                slot0_crc_mid<=crc16_chunk40(16'hffff,{slot0_version,slot0_period[31:24]});
                slot1_crc_mid<=crc16_chunk40(16'hffff,{slot1_version,slot1_period[31:24]});
            end else if(load_phase==1) begin
                load_phase<=2;
                slot0_crc_calc<=crc16_chunk40(slot0_crc_mid,{slot0_period_q[23:0],slot0_volume_q,slot0_mode_q});
                slot1_crc_calc<=crc16_chunk40(slot1_crc_mid,{slot1_period_q[23:0],slot1_volume_q,slot1_mode_q});
            end else if(load_phase==2) begin
                load_phase<=0;
                load_done<=1;
                if(slot0_good && (!slot1_good || !version_newer(slot1_version_q,slot0_version_q))) begin
                    config_valid<=1; active_version<=slot0_version_q; active_period<=slot0_period_q;
                    active_volume<=slot0_volume_q; active_mode<=slot0_mode_q; active_slot<=1'b0;
                end else if(slot1_good) begin
                    config_valid<=1; active_version<=slot1_version_q; active_period<=slot1_period_q;
                    active_volume<=slot1_volume_q; active_mode<=slot1_mode_q; active_slot<=1'b1;
                end else begin
                    config_valid<=0; active_version<=0; active_period<=0;
                    active_volume<=0; active_mode<=0; active_slot<=1'b0;
                end
            end
            if(save_start) begin
                target_slot <= config_valid ? ~active_slot : 1'b0;
                record_version <= active_version + 1'b1;
                record_period <= save_period;
                record_volume <= save_volume;
                record_mode <= save_mode;
                save_crc_mid <= crc16_chunk40(16'hffff,{active_version + 1'b1,save_period[31:24]});
                save_pending <= 1'b1;
            end else if(save_pending) begin
                save_pending <= 1'b0;
                record_crc <= crc16_chunk40(save_crc_mid,{record_period[23:0],record_volume,record_mode});
                record_ready <= 1'b1;
            end
        end
    end
endmodule
