`timescale 1ns/1ps

// Read-only identity and protection gate used before the write-capable owner
// receives the physical SPI pins.
module w25q64_preflight_reader #(
    parameter integer SPI_CLK_DIV = 4,
    parameter integer STARTUP_CYCLES = 1024,
    parameter integer WAKE_CYCLES = 200,
    parameter integer CS_HIGH_CYCLES = 3,
    parameter [23:0] EXPECTED_JEDEC_ID = 24'hef4017
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        flash_miso,
    output reg         flash_cs_n,
    output wire        flash_sclk,
    output wire        flash_mosi,
    output wire        flash_wp_n,
    output wire        flash_hold_n,
    output reg         busy,
    output reg         done,
    output reg         accepted,
    output reg         error,
    output reg  [3:0]  error_code,
    output reg  [23:0] jedec_id,
    output reg  [7:0]  status1,
    output reg  [7:0]  status2,
    output reg  [7:0]  status3
);
    localparam [4:0] ST_IDLE         = 5'd0;
    localparam [4:0] ST_STARTUP      = 5'd1;
    localparam [4:0] ST_WAKE_ISSUE   = 5'd2;
    localparam [4:0] ST_WAKE_WAIT    = 5'd3;
    localparam [4:0] ST_WAKE_DELAY   = 5'd4;
    localparam [4:0] ST_ID_CMD_ISSUE = 5'd5;
    localparam [4:0] ST_ID_CMD_WAIT  = 5'd6;
    localparam [4:0] ST_ID_DAT_ISSUE = 5'd7;
    localparam [4:0] ST_ID_DAT_WAIT  = 5'd8;
    localparam [4:0] ST_ST_CMD_ISSUE = 5'd9;
    localparam [4:0] ST_ST_CMD_WAIT  = 5'd10;
    localparam [4:0] ST_ST_DAT_ISSUE = 5'd11;
    localparam [4:0] ST_ST_DAT_WAIT  = 5'd12;
    localparam [4:0] ST_CS_GAP       = 5'd13;
    localparam [4:0] ST_COMPLETE     = 5'd14;

    localparam [3:0] ERR_NONE     = 4'd0;
    localparam [3:0] ERR_ID       = 4'd1;
    localparam [3:0] ERR_BUSY_WEL = 4'd2;
    localparam [3:0] ERR_BP       = 4'd3;
    localparam [3:0] ERR_CMP      = 4'd4;

    reg [4:0] state;
    reg [4:0] gap_return_state;
    reg [31:0] delay_count;
    reg [1:0] id_index;
    reg [1:0] status_index;
    reg spi_start;
    reg [7:0] spi_tx_byte;
    wire spi_busy;
    wire spi_done;
    wire [7:0] spi_rx_byte;

    assign flash_wp_n = 1'b1;
    assign flash_hold_n = 1'b1;

    initial begin
        if (SPI_CLK_DIV < 2 || STARTUP_CYCLES < 1 || WAKE_CYCLES < 1 ||
            CS_HIGH_CYCLES < 1) begin
            $display("W25Q64_PREFLIGHT_CONFIG_ERROR invalid timing parameter");
            $finish;
        end
    end

    spi_byte_engine #(.CLK_DIV(SPI_CLK_DIV)) u_spi_byte_engine (
        .clk(clk), .rst_n(rst_n), .start(spi_start), .tx_byte(spi_tx_byte),
        .miso(flash_miso), .busy(spi_busy), .done(spi_done),
        .rx_byte(spi_rx_byte), .sclk(flash_sclk), .mosi(flash_mosi)
    );

    function [7:0] status_command;
        input [1:0] index;
        begin
            case (index)
                2'd0: status_command = 8'h05;
                2'd1: status_command = 8'h35;
                default: status_command = 8'h15;
            endcase
        end
    endfunction

    task begin_gap;
        input [4:0] return_state;
        begin
            flash_cs_n <= 1'b1;
            delay_count <= 32'd0;
            gap_return_state <= return_state;
            state <= ST_CS_GAP;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            gap_return_state <= ST_IDLE;
            delay_count <= 32'd0;
            id_index <= 2'd0;
            status_index <= 2'd0;
            spi_start <= 1'b0;
            spi_tx_byte <= 8'hff;
            flash_cs_n <= 1'b1;
            busy <= 1'b0;
            done <= 1'b0;
            accepted <= 1'b0;
            error <= 1'b0;
            error_code <= ERR_NONE;
            jedec_id <= 24'd0;
            status1 <= 8'd0;
            status2 <= 8'd0;
            status3 <= 8'd0;
        end else begin
            spi_start <= 1'b0;
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    flash_cs_n <= 1'b1;
                    if (start) begin
                        busy <= 1'b1;
                        accepted <= 1'b0;
                        error <= 1'b0;
                        error_code <= ERR_NONE;
                        jedec_id <= 24'd0;
                        status1 <= 8'd0;
                        status2 <= 8'd0;
                        status3 <= 8'd0;
                        delay_count <= 32'd0;
                        state <= ST_STARTUP;
                    end
                end
                ST_STARTUP: begin
                    if (delay_count + 1 >= STARTUP_CYCLES) begin
                        delay_count <= 32'd0;
                        state <= ST_WAKE_ISSUE;
                    end else delay_count <= delay_count + 1'b1;
                end
                ST_WAKE_ISSUE: if (!spi_busy) begin
                    flash_cs_n <= 1'b0;
                    spi_tx_byte <= 8'hab;
                    spi_start <= 1'b1;
                    state <= ST_WAKE_WAIT;
                end
                ST_WAKE_WAIT: if (spi_done) begin
                    flash_cs_n <= 1'b1;
                    delay_count <= 32'd0;
                    state <= ST_WAKE_DELAY;
                end
                ST_WAKE_DELAY: begin
                    if (delay_count + 1 >= WAKE_CYCLES) begin
                        delay_count <= 32'd0;
                        state <= ST_ID_CMD_ISSUE;
                    end else delay_count <= delay_count + 1'b1;
                end
                ST_ID_CMD_ISSUE: if (!spi_busy) begin
                    flash_cs_n <= 1'b0;
                    spi_tx_byte <= 8'h9f;
                    spi_start <= 1'b1;
                    state <= ST_ID_CMD_WAIT;
                end
                ST_ID_CMD_WAIT: if (spi_done) begin
                    id_index <= 2'd0;
                    state <= ST_ID_DAT_ISSUE;
                end
                ST_ID_DAT_ISSUE: if (!spi_busy) begin
                    spi_tx_byte <= 8'h00;
                    spi_start <= 1'b1;
                    state <= ST_ID_DAT_WAIT;
                end
                ST_ID_DAT_WAIT: if (spi_done) begin
                    case (id_index)
                        2'd0: jedec_id[23:16] <= spi_rx_byte;
                        2'd1: jedec_id[15:8] <= spi_rx_byte;
                        default: jedec_id[7:0] <= spi_rx_byte;
                    endcase
                    if (id_index == 2'd2) begin
                        status_index <= 2'd0;
                        begin_gap(ST_ST_CMD_ISSUE);
                    end else begin
                        id_index <= id_index + 1'b1;
                        state <= ST_ID_DAT_ISSUE;
                    end
                end
                ST_ST_CMD_ISSUE: if (!spi_busy) begin
                    flash_cs_n <= 1'b0;
                    spi_tx_byte <= status_command(status_index);
                    spi_start <= 1'b1;
                    state <= ST_ST_CMD_WAIT;
                end
                ST_ST_CMD_WAIT: if (spi_done)
                    state <= ST_ST_DAT_ISSUE;
                ST_ST_DAT_ISSUE: if (!spi_busy) begin
                    spi_tx_byte <= 8'h00;
                    spi_start <= 1'b1;
                    state <= ST_ST_DAT_WAIT;
                end
                ST_ST_DAT_WAIT: if (spi_done) begin
                    case (status_index)
                        2'd0: status1 <= spi_rx_byte;
                        2'd1: status2 <= spi_rx_byte;
                        default: status3 <= spi_rx_byte;
                    endcase
                    if (status_index == 2'd2)
                        begin_gap(ST_COMPLETE);
                    else begin
                        status_index <= status_index + 1'b1;
                        begin_gap(ST_ST_CMD_ISSUE);
                    end
                end
                ST_CS_GAP: begin
                    flash_cs_n <= 1'b1;
                    if (delay_count + 1 >= CS_HIGH_CYCLES) begin
                        delay_count <= 32'd0;
                        state <= gap_return_state;
                    end else delay_count <= delay_count + 1'b1;
                end
                ST_COMPLETE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    accepted <= (jedec_id == EXPECTED_JEDEC_ID) &&
                                (status1[1:0] == 2'b00) &&
                                (status1[4:2] == 3'b000) && !status2[6];
                    error <= !((jedec_id == EXPECTED_JEDEC_ID) &&
                               (status1[1:0] == 2'b00) &&
                               (status1[4:2] == 3'b000) && !status2[6]);
                    if (jedec_id != EXPECTED_JEDEC_ID)
                        error_code <= ERR_ID;
                    else if (status1[1:0] != 2'b00)
                        error_code <= ERR_BUSY_WEL;
                    else if (status1[4:2] != 3'b000)
                        error_code <= ERR_BP;
                    else if (status2[6])
                        error_code <= ERR_CMP;
                    else
                        error_code <= ERR_NONE;
                    state <= ST_IDLE;
                end
                default: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    accepted <= 1'b0;
                    error <= 1'b1;
                    error_code <= 4'hf;
                    flash_cs_n <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

