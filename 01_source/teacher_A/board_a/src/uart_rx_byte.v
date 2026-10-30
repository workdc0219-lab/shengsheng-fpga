`timescale 1ns/1ps

module uart_rx_byte #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid,
    output reg        framing_error
);
    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_START = 3'd1;
    localparam [2:0] ST_DATA  = 3'd2;
    localparam [2:0] ST_STOP  = 3'd3;

    reg rx_meta;
    reg rx_sync;
    reg [2:0] state;
    reg [31:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift;

    initial begin
        if (CLKS_PER_BIT < 4) begin
            $display("UART_RX_BYTE_CONFIG_ERROR CLKS_PER_BIT must be >= 4");
            $finish;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            state <= ST_IDLE;
            count <= 32'd0;
            bit_index <= 3'd0;
            shift <= 8'd0;
            data <= 8'd0;
            valid <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            valid <= 1'b0;
            framing_error <= 1'b0;

            case (state)
                ST_IDLE: if (!rx_sync) begin
                    count <= 32'd0;
                    state <= ST_START;
                end
                ST_START: if (count + 1 >= CLKS_PER_BIT/2) begin
                    count <= 32'd0;
                    if (!rx_sync) begin
                        bit_index <= 3'd0;
                        state <= ST_DATA;
                    end else begin
                        state <= ST_IDLE;
                    end
                end else begin
                    count <= count + 1'b1;
                end
                ST_DATA: if (count + 1 >= CLKS_PER_BIT) begin
                    count <= 32'd0;
                    shift[bit_index] <= rx_sync;
                    if (bit_index == 3'd7)
                        state <= ST_STOP;
                    else
                        bit_index <= bit_index + 1'b1;
                end else begin
                    count <= count + 1'b1;
                end
                ST_STOP: if (count + 1 >= CLKS_PER_BIT) begin
                    count <= 32'd0;
                    state <= ST_IDLE;
                    if (rx_sync) begin
                        data <= shift;
                        valid <= 1'b1;
                    end else begin
                        framing_error <= 1'b1;
                    end
                end else begin
                    count <= count + 1'b1;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
