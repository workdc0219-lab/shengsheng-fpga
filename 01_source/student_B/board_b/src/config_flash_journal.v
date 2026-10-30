`timescale 1ns/1ps

module config_flash_journal #(
    parameter integer CLK_DIV = 2,
    parameter integer CS_HIGH_CYCLES = 3,
    parameter integer POLL_INTERVAL_CYCLES = 5000,
    parameter [31:0] ERASE_TIMEOUT_CYCLES = 32'd250000000,
    parameter [31:0] PROGRAM_TIMEOUT_CYCLES = 32'd5000000,
    parameter [23:0] SLOT0_ADDRESS = 24'h001000,
    parameter [23:0] SLOT1_ADDRESS = 24'h002000,
    parameter [23:0] ALLOWED_BASE = 24'h001000,
    parameter [23:0] ALLOWED_LIMIT = 24'h003000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         busy,
    output reg         load_done,
    output reg         save_done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         request_dropped,
    output wire        config_valid,
    output wire [31:0] active_version,
    output wire [31:0] active_period,
    output wire [7:0]  active_volume,
    output wire [7:0]  active_mode,
    output wire        slot0_present_out,
    output wire        slot1_present_out,
    output wire [95:0] slot0_raw,
    output wire [95:0] slot1_raw,
    output wire        spi_cs_n,
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_wp_n,
    output wire        spi_hold_n
);
    localparam [3:0] ST_IDLE          = 4'd0;
    localparam [3:0] ST_READ0_ISSUE   = 4'd1;
    localparam [3:0] ST_READ0_WAIT    = 4'd2;
    localparam [3:0] ST_READ1_ISSUE   = 4'd3;
    localparam [3:0] ST_READ1_WAIT    = 4'd4;
    localparam [3:0] ST_LOAD_PULSE    = 4'd5;
    localparam [3:0] ST_LOAD_WAIT     = 4'd6;
    localparam [3:0] ST_SAVE_PULSE    = 4'd7;
    localparam [3:0] ST_RECORD_WAIT   = 4'd8;
    localparam [3:0] ST_WRITE_ISSUE   = 4'd9;
    localparam [3:0] ST_WRITE_WAIT    = 4'd10;

    reg [3:0] state;
    reg reload_after_save;
    reg slot0_present;
    reg slot1_present;
    reg [95:0] slot0_data;
    reg [95:0] slot1_data;
    reg [31:0] save_period_latched;
    reg [7:0] save_volume_latched;
    reg [7:0] save_mode_latched;
    reg journal_load_start;
    reg journal_save_start;
    wire journal_load_done;
    wire record_ready;
    wire target_slot;
    wire [31:0] record_version;
    wire [31:0] record_period;
    wire [7:0] record_volume;
    wire [7:0] record_mode;
    wire [15:0] record_crc;
    reg flash_start;
    reg flash_write;
    reg [23:0] flash_address;
    reg [95:0] flash_write_data;
    wire flash_busy;
    wire flash_done;
    wire flash_error;
    wire [3:0] flash_error_code;
    wire [95:0] flash_read_data;
    wire flash_request_dropped;

    initial begin
        if (SLOT0_ADDRESS[11:0] != 12'd0 || SLOT1_ADDRESS[11:0] != 12'd0 ||
            ALLOWED_BASE[11:0] != 12'd0 || ALLOWED_LIMIT[11:0] != 12'd0 ||
            SLOT1_ADDRESS <= SLOT0_ADDRESS || ALLOWED_LIMIT <= ALLOWED_BASE ||
            SLOT0_ADDRESS < ALLOWED_BASE || SLOT1_ADDRESS < ALLOWED_BASE ||
            SLOT0_ADDRESS + 24'h001000 > ALLOWED_LIMIT ||
            SLOT1_ADDRESS + 24'h001000 > ALLOWED_LIMIT) begin
            $display("CONFIG_FLASH_JOURNAL_CONFIG_ERROR invalid slot addresses");
            $finish;
        end
    end

    assign slot0_present_out = slot0_present;
    assign slot1_present_out = slot1_present;
    assign slot0_raw = slot0_data;
    assign slot1_raw = slot1_data;

    config_journal u_journal (
        .clk(clk), .rst_n(rst_n), .load_start(journal_load_start),
        .slot0_present(slot0_present), .slot0_version(slot0_data[95:64]),
        .slot0_period(slot0_data[63:32]), .slot0_volume(slot0_data[31:24]),
        .slot0_mode(slot0_data[23:16]), .slot0_crc(slot0_data[15:0]),
        .slot1_present(slot1_present), .slot1_version(slot1_data[95:64]),
        .slot1_period(slot1_data[63:32]), .slot1_volume(slot1_data[31:24]),
        .slot1_mode(slot1_data[23:16]), .slot1_crc(slot1_data[15:0]),
        .load_done(journal_load_done), .config_valid(config_valid),
        .active_version(active_version), .active_period(active_period),
        .active_volume(active_volume), .active_mode(active_mode),
        .save_start(journal_save_start), .save_period(save_period_latched),
        .save_volume(save_volume_latched), .save_mode(save_mode_latched),
        .record_ready(record_ready), .target_slot(target_slot),
        .record_version(record_version), .record_period(record_period),
        .record_volume(record_volume), .record_mode(record_mode),
        .record_crc(record_crc)
    );

    w25q64_record_store #(
        .CLK_DIV(CLK_DIV), .CS_HIGH_CYCLES(CS_HIGH_CYCLES),
        .POLL_INTERVAL_CYCLES(POLL_INTERVAL_CYCLES),
        .ERASE_TIMEOUT_CYCLES(ERASE_TIMEOUT_CYCLES),
        .PROGRAM_TIMEOUT_CYCLES(PROGRAM_TIMEOUT_CYCLES),
        .ALLOWED_BASE(ALLOWED_BASE), .ALLOWED_LIMIT(ALLOWED_LIMIT)
    ) u_store (
        .clk(clk), .rst_n(rst_n), .start(flash_start), .op_write(flash_write),
        .address(flash_address), .write_data(flash_write_data),
        .busy(flash_busy), .done(flash_done), .error(flash_error),
        .error_code(flash_error_code), .read_data(flash_read_data),
        .request_dropped(flash_request_dropped), .spi_cs_n(spi_cs_n),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .spi_wp_n(spi_wp_n), .spi_hold_n(spi_hold_n)
    );

    task finish_with_flash_error;
        input [3:0] phase;
        begin
            busy       <= 1'b0;
            error      <= 1'b1;
            error_code <= {phase,flash_error_code};
            if (reload_after_save)
                save_done <= 1'b1;
            else
                load_done <= 1'b1;
            state <= ST_IDLE;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            reload_after_save   <= 1'b0;
            slot0_present       <= 1'b0;
            slot1_present       <= 1'b0;
            slot0_data          <= 96'd0;
            slot1_data          <= 96'd0;
            save_period_latched <= 32'd0;
            save_volume_latched <= 8'd0;
            save_mode_latched   <= 8'd0;
            journal_load_start  <= 1'b0;
            journal_save_start  <= 1'b0;
            flash_start         <= 1'b0;
            flash_write         <= 1'b0;
            flash_address       <= SLOT0_ADDRESS;
            flash_write_data    <= 96'd0;
            busy                <= 1'b0;
            load_done           <= 1'b0;
            save_done           <= 1'b0;
            error               <= 1'b0;
            error_code          <= 8'd0;
            request_dropped     <= 1'b0;
        end else begin
            load_done          <= 1'b0;
            save_done          <= 1'b0;
            error              <= 1'b0;
            request_dropped    <= 1'b0;
            journal_load_start <= 1'b0;
            journal_save_start <= 1'b0;
            flash_start        <= 1'b0;

            if ((load_start || save_start) && busy)
                request_dropped <= 1'b1;
            if (flash_request_dropped)
                request_dropped <= 1'b1;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (load_start) begin
                        busy              <= 1'b1;
                        error_code        <= 8'd0;
                        reload_after_save <= 1'b0;
                        state             <= ST_READ0_ISSUE;
                    end else if (save_start) begin
                        busy                <= 1'b1;
                        error_code          <= 8'd0;
                        save_period_latched <= save_period;
                        save_volume_latched <= save_volume;
                        save_mode_latched   <= save_mode;
                        reload_after_save   <= 1'b1;
                        state               <= ST_SAVE_PULSE;
                    end
                end
                ST_READ0_ISSUE: begin
                    flash_write   <= 1'b0;
                    flash_address <= SLOT0_ADDRESS;
                    flash_start   <= 1'b1;
                    state         <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (flash_done) begin
                    if (flash_error) begin
                        finish_with_flash_error(4'h1);
                    end else begin
                        slot0_data    <= flash_read_data;
                        slot0_present <= flash_read_data != {96{1'b1}};
                        state         <= ST_READ1_ISSUE;
                    end
                end
                ST_READ1_ISSUE: begin
                    flash_write   <= 1'b0;
                    flash_address <= SLOT1_ADDRESS;
                    flash_start   <= 1'b1;
                    state         <= ST_READ1_WAIT;
                end
                ST_READ1_WAIT: if (flash_done) begin
                    if (flash_error) begin
                        finish_with_flash_error(4'h2);
                    end else begin
                        slot1_data    <= flash_read_data;
                        slot1_present <= flash_read_data != {96{1'b1}};
                        state         <= ST_LOAD_PULSE;
                    end
                end
                ST_LOAD_PULSE: begin
                    journal_load_start <= 1'b1;
                    state <= ST_LOAD_WAIT;
                end
                ST_LOAD_WAIT: if (journal_load_done) begin
                    busy <= 1'b0;
                    if (reload_after_save)
                        save_done <= 1'b1;
                    else
                        load_done <= 1'b1;
                    state <= ST_IDLE;
                end
                ST_SAVE_PULSE: begin
                    journal_save_start <= 1'b1;
                    state <= ST_RECORD_WAIT;
                end
                ST_RECORD_WAIT: if (record_ready) begin
                    flash_address    <= target_slot ? SLOT1_ADDRESS : SLOT0_ADDRESS;
                    flash_write_data <= {record_version,record_period,record_volume,record_mode,record_crc};
                    state            <= ST_WRITE_ISSUE;
                end
                ST_WRITE_ISSUE: begin
                    flash_write <= 1'b1;
                    flash_start <= 1'b1;
                    state       <= ST_WRITE_WAIT;
                end
                ST_WRITE_WAIT: if (flash_done) begin
                    if (flash_error) begin
                        busy       <= 1'b0;
                        error      <= 1'b1;
                        error_code <= {4'h3,flash_error_code};
                        save_done  <= 1'b1;
                        state      <= ST_IDLE;
                    end else begin
                        state <= ST_READ0_ISSUE;
                    end
                end
                default: begin
                    busy       <= 1'b0;
                    error      <= 1'b1;
                    error_code <= 8'hff;
                    state      <= ST_IDLE;
                end
            endcase
        end
    end
endmodule


