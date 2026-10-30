`timescale 1ns/1ps
// Atomic framed transmitter. Snapshot accepted only when ready; no live
// application register is consulted until the next acceptance.
module v7_packet_tx #(
    parameter integer CLKS_PER_BIT = 27
)(
    input wire clk, rst_n, flush, send,
    input wire [7:0] kind,
    input wire [5:0] length,
    input wire [15:0] session, packet_seq, question,
    input wire [255:0] payload,
    output wire tx, ready,
    output reg done
);
    `include "v7_defs.vh"
    reg active, byte_start;
    reg [5:0] index, len;
    reg [7:0] ty, byte_data;
    reg [15:0] sid, seq, qid, crc;
    reg [255:0] body;
    wire byte_busy, byte_done;
    assign ready = !active && !byte_busy && !byte_start;
    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_byte (
        .clk(clk),.rst_n(rst_n && !flush),.start(byte_start),.data(byte_data),
        .tx(tx),.busy(byte_busy),.done(byte_done));
    function [15:0] crc_next;
        input [15:0] old_crc;
        input [7:0] value;
        reg [15:0] c;
        integer k;
        begin
            c=old_crc ^ {value,8'b0};
            for(k=0;k<8;k=k+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_next=c;
        end
    endfunction
    reg [7:0] current;
    always @* begin
        case(index)
            0: current=8'hA5; 1: current=8'h5A;
            2: current=V7_VERSION; 3: current=ty; 4: current={2'b0,len};
            5: current=sid[7:0]; 6: current=sid[15:8];
            7: current=seq[7:0]; 8: current=seq[15:8];
            9: current=qid[7:0]; 10: current=qid[15:8];
            default: begin
                if(index==11+len) current=crc[7:0];
                else if(index==12+len) current=crc[15:8];
                else current=body[(index-11)*8 +:8];
            end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active<=0; byte_start<=0; done<=0; index<=0; len<=0;
            ty<=0; byte_data<=0; sid<=0; seq<=0; qid<=0; crc<=16'hFFFF; body<=0;
        end else if(flush) begin
            active<=0; byte_start<=0; done<=0; index<=0; crc<=16'hFFFF;
        end else begin
            byte_start<=0; done<=0;
            if(send && ready && length<=32 && v7_length_ok(kind,length)) begin
                active<=1; index<=0; len<=length; ty<=kind; sid<=session;
                seq<=packet_seq; qid<=question; body<=payload; crc<=16'hFFFF;
            end else if(active) begin
                if(!byte_busy && !byte_start && !byte_done) begin
                    byte_data<=current; byte_start<=1;
                    if(index>=2 && index<11+len) crc<=crc_next(crc,current);
                end else if(byte_done) begin
                    if(index==12+len) begin active<=0; done<=1; end
                    else index<=index+1'b1;
                end
            end
        end
    end
endmodule
