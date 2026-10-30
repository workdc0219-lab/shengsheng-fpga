`timescale 1ns/1ps

module spi_byte_engine #(
    parameter integer CLK_DIV = 2
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] tx_byte,
    input  wire       miso,
    output reg        busy,
    output reg        done,
    output reg  [7:0] rx_byte,
    output reg        sclk,
    output reg        mosi
);
    localparam ST_IDLE = 2'd0;
    localparam ST_RUN  = 2'd1;
    localparam ST_END  = 2'd2;
    localparam integer DIV_BITS = (CLK_DIV <= 2) ? 1 : $clog2(CLK_DIV);

    reg [1:0] state;
    reg [DIV_BITS-1:0] div_count;
    reg [2:0] bit_count;
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;

    initial begin
        if (CLK_DIV < 2) begin
            $display("SPI_BYTE_ENGINE_CONFIG_ERROR CLK_DIV must be at least 2");
            $finish;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            div_count <= {DIV_BITS{1'b0}};
            bit_count <= 3'd0;
            tx_shift  <= 8'hff;
            rx_shift  <= 8'h00;
            rx_byte   <= 8'h00;
            busy      <= 1'b0;
            done      <= 1'b0;
            sclk      <= 1'b0;
            mosi      <= 1'b1;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy      <= 1'b0;
                    sclk      <= 1'b0;
                    div_count <= {DIV_BITS{1'b0}};
                    bit_count <= 3'd0;
                    if (start) begin
                        busy     <= 1'b1;
                        tx_shift <= tx_byte;
                        rx_shift <= 8'h00;
                        mosi     <= tx_byte[7];
                        state    <= ST_RUN;
                    end
                end
                ST_RUN: begin
                    busy <= 1'b1;
                    if (!sclk && div_count == 0 && bit_count != 0)
                        mosi <= tx_shift[7];
                    if (div_count == CLK_DIV-1) begin
                        div_count <= {DIV_BITS{1'b0}};
                        if (!sclk) begin
                            sclk     <= 1'b1;
                            rx_shift <= {rx_shift[6:0], miso};
                            if (bit_count == 3'd7)
                                rx_byte <= {rx_shift[6:0], miso};
                        end else begin
                            sclk <= 1'b0;
                            if (bit_count == 3'd7) begin
                                state <= ST_END;
                            end else begin
                                bit_count <= bit_count + 1'b1;
                                tx_shift  <= {tx_shift[6:0], 1'b0};
                            end
                        end
                    end else begin
                        div_count <= div_count + 1'b1;
                    end
                end
                ST_END: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    sclk  <= 1'b0;
                    mosi  <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
