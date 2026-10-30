`timescale 1ns/1ps

module sd_spi_command #(
    parameter integer MAX_RESPONSE_BYTES = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [5:0]  cmd_index,
    input  wire [31:0] cmd_argument,
    input  wire [7:0]  cmd_crc,
    input  wire [2:0]  extra_response_bytes,
    output wire        busy,
    output reg         done,
    output reg         response_timeout,
    output reg  [7:0]  r1,
    output reg  [31:0] response_data,
    output reg         cs_n,
    output reg         byte_start,
    output reg  [7:0]  byte_tx,
    input  wire        byte_busy,
    input  wire        byte_done,
    input  wire [7:0]  byte_rx
);

    localparam ST_IDLE       = 4'd0;
    localparam ST_PRE_REQ    = 4'd1;
    localparam ST_PRE_WAIT   = 4'd2;
    localparam ST_CMD_REQ    = 4'd3;
    localparam ST_CMD_WAIT   = 4'd4;
    localparam ST_RESP_REQ   = 4'd5;
    localparam ST_RESP_WAIT  = 4'd6;
    localparam ST_EXTRA_REQ  = 4'd7;
    localparam ST_EXTRA_WAIT = 4'd8;
    localparam ST_POST_REQ   = 4'd9;
    localparam ST_POST_WAIT  = 4'd10;

    reg [3:0] state;
    reg [5:0] cmd_index_latched;
    reg [31:0] cmd_argument_latched;
    reg [7:0] cmd_crc_latched;
    reg [2:0] extra_count_latched;
    reg [2:0] byte_index;
    reg [2:0] extra_index;
    integer response_poll_count;

    assign busy = (state != ST_IDLE);

    function [7:0] command_byte;
        input [2:0] index;
        begin
            case (index)
                3'd0: command_byte = {2'b01, cmd_index_latched};
                3'd1: command_byte = cmd_argument_latched[31:24];
                3'd2: command_byte = cmd_argument_latched[23:16];
                3'd3: command_byte = cmd_argument_latched[15:8];
                3'd4: command_byte = cmd_argument_latched[7:0];
                default: command_byte = cmd_crc_latched;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                 <= ST_IDLE;
            cmd_index_latched     <= 6'd0;
            cmd_argument_latched  <= 32'd0;
            cmd_crc_latched       <= 8'hff;
            extra_count_latched   <= 3'd0;
            byte_index            <= 3'd0;
            extra_index           <= 3'd0;
            response_poll_count   <= 0;
            done                  <= 1'b0;
            response_timeout      <= 1'b0;
            r1                    <= 8'hff;
            response_data         <= 32'd0;
            cs_n                  <= 1'b1;
            byte_start            <= 1'b0;
            byte_tx               <= 8'hff;
        end else begin
            done       <= 1'b0;
            byte_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    cs_n <= 1'b1;
                    if (start) begin
                        cmd_index_latched    <= cmd_index;
                        cmd_argument_latched <= cmd_argument;
                        cmd_crc_latched      <= cmd_crc;
                        extra_count_latched  <= extra_response_bytes;
                        byte_index           <= 3'd0;
                        extra_index          <= 3'd0;
                        response_poll_count  <= 0;
                        response_timeout     <= 1'b0;
                        r1                   <= 8'hff;
                        response_data        <= 32'd0;
                        state                <= ST_PRE_REQ;
                    end
                end

                ST_PRE_REQ: begin
                    cs_n <= 1'b1;
                    if (!byte_busy) begin
                        byte_tx    <= 8'hff;
                        byte_start <= 1'b1;
                        state      <= ST_PRE_WAIT;
                    end
                end

                ST_PRE_WAIT: begin
                    if (byte_done) begin
                        cs_n  <= 1'b0;
                        byte_tx <= command_byte(3'd0);
                        state <= ST_CMD_REQ;
                    end
                end

                ST_CMD_REQ: begin
                    if (!byte_busy) begin
                        byte_start <= 1'b1;
                        state      <= ST_CMD_WAIT;
                    end
                end

                ST_CMD_WAIT: begin
                    if (byte_done) begin
                        if (byte_index == 3'd5) begin
                            byte_tx <= 8'hff;
                            state <= ST_RESP_REQ;
                        end else begin
                            byte_index <= byte_index + 1'b1;
                            byte_tx    <= command_byte(byte_index + 1'b1);
                            state      <= ST_CMD_REQ;
                        end
                    end
                end

                ST_RESP_REQ: begin
                    if (!byte_busy) begin
                        byte_tx    <= 8'hff;
                        byte_start <= 1'b1;
                        state      <= ST_RESP_WAIT;
                    end
                end

                ST_RESP_WAIT: begin
                    if (byte_done) begin
                        if (!byte_rx[7]) begin
                            r1 <= byte_rx;
                            if (extra_count_latched == 0)
                                state <= ST_POST_REQ;
                            else
                                state <= ST_EXTRA_REQ;
                        end else if (response_poll_count == MAX_RESPONSE_BYTES-1) begin
                            response_timeout <= 1'b1;
                            state <= ST_POST_REQ;
                        end else begin
                            response_poll_count <= response_poll_count + 1;
                            state <= ST_RESP_REQ;
                        end
                    end
                end

                ST_EXTRA_REQ: begin
                    if (!byte_busy) begin
                        byte_tx    <= 8'hff;
                        byte_start <= 1'b1;
                        state      <= ST_EXTRA_WAIT;
                    end
                end

                ST_EXTRA_WAIT: begin
                    if (byte_done) begin
                        response_data <= {response_data[23:0], byte_rx};
                        if (extra_index == extra_count_latched-1) begin
                            state <= ST_POST_REQ;
                        end else begin
                            extra_index <= extra_index + 1'b1;
                            state <= ST_EXTRA_REQ;
                        end
                    end
                end

                ST_POST_REQ: begin
                    cs_n <= 1'b1;
                    if (!byte_busy) begin
                        byte_tx    <= 8'hff;
                        byte_start <= 1'b1;
                        state      <= ST_POST_WAIT;
                    end
                end

                ST_POST_WAIT: begin
                    if (byte_done) begin
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
