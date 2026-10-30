`timescale 1ns/1ps
// All public fields commit on one CRC-verified edge. Partial packets cannot
// leak into game state. Inter-byte silence/framing errors discard staging.
module v7_packet_rx #(
    parameter integer CLKS_PER_BIT=27,
    parameter integer GAP_CLOCKS=CLKS_PER_BIT*40
)(
    input wire clk,rst_n,flush,rx,
    output reg valid,
    output reg [7:0] kind,
    output reg [5:0] length,
    output reg [15:0] session,packet_seq,question,
    output reg [255:0] payload,
    output reg packet_error, version_error
);
    `include "v7_defs.vh"
    wire [7:0] data;
    wire byte_valid,framing_error;
    uart_rx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_byte(
        .clk(clk),.rst_n(rst_n && !flush),.rx(rx),.data(data),
        .valid(byte_valid),.framing_error(framing_error));
    reg [1:0] state;
    reg [5:0] index,len;
    reg [7:0] ver,ty,crc_lo;
    reg [15:0] sid,seq,qid,crc;
    reg [255:0] body;
    reg [15:0] gap;
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
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=0; index<=0; len<=0; ver<=0; ty<=0; crc_lo<=0;
            sid<=0; seq<=0; qid<=0; crc<=16'hFFFF; body<=0; gap<=0;
            valid<=0; kind<=0; length<=0; session<=0; packet_seq<=0; question<=0;
            payload<=0; packet_error<=0; version_error<=0;
        end else if(flush) begin
            state<=0; index<=0; gap<=0; valid<=0; packet_error<=0; version_error<=0;
        end else begin
            valid<=0; packet_error<=0; version_error<=0;
            if(state!=0 && !byte_valid) begin
                if(gap>=GAP_CLOCKS-1) begin state<=0; gap<=0; packet_error<=1; end
                else gap<=gap+1'b1;
            end
            if(framing_error) begin state<=0; packet_error<=1; end
            else if(byte_valid) begin
                gap<=0;
                case(state)
                    0: if(data==8'hA5) state<=1;
                    1: begin
                        if(data==8'h5A) begin state<=2; index<=2; len<=0; crc<=16'hFFFF; body<=0; end
                        else if(data!=8'hA5) state<=0;
                    end
                    2: begin
                        if(index<=10 || index<11+len) crc<=crc_next(crc,data);
                        case(index)
                            2: ver<=data;
                            3: ty<=data;
                            4: begin
                                len<=data[5:0];
                                if(data>32 || !v7_length_ok(ty,data[5:0])) begin state<=0; packet_error<=1; end
                            end
                            5: sid[7:0]<=data; 6: sid[15:8]<=data;
                            7: seq[7:0]<=data; 8: seq[15:8]<=data;
                            9: qid[7:0]<=data; 10: qid[15:8]<=data;
                            default: begin
                                if(index==11+len) crc_lo<=data;
                                else if(index==12+len) begin
                                    state<=0;
                                    if({data,crc_lo}==crc && ver==V7_VERSION) begin
                                        valid<=1; kind<=ty; length<=len; session<=sid;
                                        packet_seq<=seq; question<=qid; payload<=body;
                                    end else begin
                                        packet_error<=1;
                                        if(ver!=V7_VERSION) version_error<=1;
                                    end
                                end else body[(index-11)*8 +:8]<=data;
                            end
                        endcase
                        index<=index+1'b1;
                    end
                    default: state<=0;
                endcase
            end
        end
    end
endmodule
