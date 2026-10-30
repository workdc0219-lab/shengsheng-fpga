`timescale 1ns/1ps

module w25q64_record_store #(
    parameter integer RECORD_BYTES = 12,
    parameter integer CLK_DIV = 2,
    parameter integer CS_HIGH_CYCLES = 3,
    parameter integer POLL_INTERVAL_CYCLES = 5000,
    parameter [31:0] ERASE_TIMEOUT_CYCLES = 32'd250000000,
    parameter [31:0] PROGRAM_TIMEOUT_CYCLES = 32'd5000000,
    parameter [23:0] ALLOWED_BASE = 24'h001000,
    parameter [23:0] ALLOWED_LIMIT = 24'h003000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        op_write,
    input  wire [23:0] address,
    input  wire [RECORD_BYTES*8-1:0] write_data,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [3:0]  error_code,
    output reg  [RECORD_BYTES*8-1:0] read_data,
    output reg         request_dropped,
    output reg         spi_cs_n,
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_wp_n,
    output wire        spi_hold_n
);
    localparam [3:0] ERR_NONE          = 4'd0;
    localparam [3:0] ERR_OUT_OF_RANGE  = 4'd1;
    localparam [3:0] ERR_NOT_ALIGNED   = 4'd2;
    localparam [3:0] ERR_ERASE_WEL     = 4'd3;
    localparam [3:0] ERR_ERASE_TIMEOUT = 4'd4;
    localparam [3:0] ERR_PROGRAM_WEL   = 4'd5;
    localparam [3:0] ERR_PROG_TIMEOUT  = 4'd6;
    localparam [3:0] ERR_VERIFY        = 4'd7;
    localparam [3:0] ERR_ERASE_NO_WIP  = 4'd8;
    localparam [3:0] ERR_PROG_NO_WIP   = 4'd9;
    localparam [3:0] ERR_PROTECTED     = 4'd10;
    localparam [3:0] ERR_BUSY_TIMEOUT  = 4'd11;

    localparam [5:0] ST_IDLE            = 6'd0;
    localparam [5:0] ST_WREN_ISSUE      = 6'd1;
    localparam [5:0] ST_WREN_WAIT       = 6'd2;
    localparam [5:0] ST_WEL_CMD_ISSUE   = 6'd3;
    localparam [5:0] ST_WEL_CMD_WAIT    = 6'd4;
    localparam [5:0] ST_WEL_DATA_ISSUE  = 6'd5;
    localparam [5:0] ST_WEL_DATA_WAIT   = 6'd6;
    localparam [5:0] ST_ERASE_CMD_ISSUE = 6'd7;
    localparam [5:0] ST_ERASE_CMD_WAIT  = 6'd8;
    localparam [5:0] ST_ERASE_ADR_ISSUE = 6'd9;
    localparam [5:0] ST_ERASE_ADR_WAIT  = 6'd10;
    localparam [5:0] ST_POLL_CMD_ISSUE  = 6'd11;
    localparam [5:0] ST_POLL_CMD_WAIT   = 6'd12;
    localparam [5:0] ST_POLL_DAT_ISSUE  = 6'd13;
    localparam [5:0] ST_POLL_DAT_WAIT   = 6'd14;
    localparam [5:0] ST_PROG_CMD_ISSUE  = 6'd15;
    localparam [5:0] ST_PROG_CMD_WAIT   = 6'd16;
    localparam [5:0] ST_PROG_ADR_ISSUE  = 6'd17;
    localparam [5:0] ST_PROG_ADR_WAIT   = 6'd18;
    localparam [5:0] ST_PROG_DAT_ISSUE  = 6'd19;
    localparam [5:0] ST_PROG_DAT_WAIT   = 6'd20;
    localparam [5:0] ST_READ_CMD_ISSUE  = 6'd21;
    localparam [5:0] ST_READ_CMD_WAIT   = 6'd22;
    localparam [5:0] ST_READ_ADR_ISSUE  = 6'd23;
    localparam [5:0] ST_READ_ADR_WAIT   = 6'd24;
    localparam [5:0] ST_READ_DAT_ISSUE  = 6'd25;
    localparam [5:0] ST_READ_DAT_WAIT   = 6'd26;
    localparam [5:0] ST_CS_HIGH_WAIT    = 6'd27;
    localparam [5:0] ST_POLL_INTERVAL   = 6'd28;
    localparam [5:0] ST_COMPLETE_OK     = 6'd29;
    localparam [5:0] ST_COMPLETE_ERROR  = 6'd30;

    reg [5:0] state;
    reg [23:0] address_latched;
    reg op_write_latched;
    reg [RECORD_BYTES*8-1:0] write_data_latched;
    reg [RECORD_BYTES*8-1:0] record_shift;
    reg [7:0] byte_index;
    reg [1:0] address_index;
    reg [31:0] poll_elapsed_count;
    reg [31:0] poll_timeout_limit;
    reg [31:0] poll_interval_count;
    reg [31:0] cs_high_count;
    reg [5:0] cs_gap_return_state;
    reg wel_for_program;
    reg poll_for_program;
    reg preflight_poll;
    reg poll_active;
    reg saw_wip_high;
    reg verify_read;
    reg byte_start;
    reg [7:0] byte_tx;
    reg [3:0] pending_error_code;
    wire byte_busy;
    wire byte_done;
    wire [7:0] byte_rx;
    wire address_allowed;

    initial begin
        if (RECORD_BYTES < 1 || RECORD_BYTES > 256 ||
            CLK_DIV < 2 || CS_HIGH_CYCLES < 1 || POLL_INTERVAL_CYCLES < 1 ||
            ERASE_TIMEOUT_CYCLES < 1 || PROGRAM_TIMEOUT_CYCLES < 1 ||
            ALLOWED_BASE[11:0] != 12'd0 || ALLOWED_LIMIT[11:0] != 12'd0 ||
            ALLOWED_LIMIT <= ALLOWED_BASE) begin
            $display("W25Q64_RECORD_STORE_CONFIG_ERROR invalid timing or protected window parameter");
            $finish;
        end
    end

    assign spi_wp_n = 1'b1;
    assign spi_hold_n = 1'b1;
    assign address_allowed = (address >= ALLOWED_BASE) &&
                             ({1'b0,address} + RECORD_BYTES - 1 < {1'b0,ALLOWED_LIMIT});

    spi_byte_engine #(.CLK_DIV(CLK_DIV)) u_byte_engine (
        .clk(clk), .rst_n(rst_n), .start(byte_start), .tx_byte(byte_tx),
        .miso(spi_miso), .busy(byte_busy), .done(byte_done),
        .rx_byte(byte_rx), .sclk(spi_sclk), .mosi(spi_mosi)
    );

    function [7:0] address_byte;
        input [23:0] value;
        input [1:0] index;
        begin
            case (index)
                2'd0: address_byte = value[23:16];
                2'd1: address_byte = value[15:8];
                default: address_byte = value[7:0];
            endcase
        end
    endfunction

    task finish_error;
        input [3:0] code;
        begin
            pending_error_code <= code;
            poll_active         <= 1'b0;
            spi_cs_n            <= 1'b1;
            cs_high_count       <= 32'd0;
            cs_gap_return_state <= ST_COMPLETE_ERROR;
            state               <= ST_CS_HIGH_WAIT;
        end
    endtask

    task finish_success;
        begin
            poll_active         <= 1'b0;
            spi_cs_n            <= 1'b1;
            cs_high_count       <= 32'd0;
            cs_gap_return_state <= ST_COMPLETE_OK;
            state               <= ST_CS_HIGH_WAIT;
        end
    endtask

    task begin_cs_gap;
        input [5:0] return_state;
        begin
            spi_cs_n           <= 1'b1;
            cs_high_count      <= 32'd0;
            cs_gap_return_state<= return_state;
            state              <= ST_CS_HIGH_WAIT;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            address_latched    <= 24'd0;
            op_write_latched   <= 1'b0;
            write_data_latched <= {RECORD_BYTES*8{1'b0}};
            record_shift       <= {RECORD_BYTES*8{1'b0}};
            byte_index         <= 4'd0;
            address_index      <= 2'd0;
            poll_elapsed_count <= 32'd0;
            poll_timeout_limit <= 32'd0;
            poll_interval_count<= 32'd0;
            cs_high_count      <= 32'd0;
            cs_gap_return_state<= ST_IDLE;
            wel_for_program    <= 1'b0;
            poll_for_program   <= 1'b0;
            preflight_poll     <= 1'b0;
            poll_active        <= 1'b0;
            saw_wip_high       <= 1'b0;
            verify_read        <= 1'b0;
            byte_start         <= 1'b0;
            byte_tx            <= 8'hff;
            pending_error_code <= ERR_NONE;
            busy               <= 1'b0;
            done               <= 1'b0;
            error              <= 1'b0;
            error_code         <= ERR_NONE;
            read_data          <= {RECORD_BYTES*8{1'b0}};
            request_dropped    <= 1'b0;
            spi_cs_n           <= 1'b1;
        end else begin
            done            <= 1'b0;
            error           <= 1'b0;
            request_dropped <= 1'b0;
            byte_start      <= 1'b0;

            if (poll_active)
                poll_elapsed_count <= poll_elapsed_count + 1'b1;

            if (start && busy)
                request_dropped <= 1'b1;

            case (state)
                ST_IDLE: begin
                    busy     <= 1'b0;
                    spi_cs_n <= 1'b1;
                    if (start) begin
                        error_code <= ERR_NONE;
                        if (!address_allowed) begin
                            done       <= 1'b1;
                            error      <= 1'b1;
                            error_code <= ERR_OUT_OF_RANGE;
                        end else if (op_write && address[11:0] != 12'd0) begin
                            done       <= 1'b1;
                            error      <= 1'b1;
                            error_code <= ERR_NOT_ALIGNED;
                        end else begin
                            busy               <= 1'b1;
                            address_latched    <= address;
                            op_write_latched   <= op_write;
                            write_data_latched <= write_data;
                            record_shift       <= write_data;
                            read_data          <= {RECORD_BYTES*8{1'b0}};
                            verify_read        <= op_write;
                            wel_for_program    <= 1'b0;
                            poll_for_program   <= 1'b0;
                            preflight_poll     <= 1'b1;
                            poll_active        <= 1'b1;
                            saw_wip_high       <= 1'b0;
                            poll_elapsed_count <= 32'd0;
                            poll_timeout_limit <= ERASE_TIMEOUT_CYCLES;
                            poll_interval_count<= 32'd0;
                            state <= ST_POLL_CMD_ISSUE;
                        end
                    end
                end

                ST_WREN_ISSUE: begin
                    spi_cs_n  <= 1'b0;
                    byte_tx   <= 8'h06;
                    byte_start<= 1'b1;
                    state     <= ST_WREN_WAIT;
                end
                ST_WREN_WAIT: if (byte_done) begin
                    begin_cs_gap(ST_WEL_CMD_ISSUE);
                end

                ST_WEL_CMD_ISSUE: begin
                    spi_cs_n   <= 1'b0;
                    byte_tx    <= 8'h05;
                    byte_start <= 1'b1;
                    state      <= ST_WEL_CMD_WAIT;
                end
                ST_WEL_CMD_WAIT: if (byte_done)
                    state <= ST_WEL_DATA_ISSUE;
                ST_WEL_DATA_ISSUE: begin
                    byte_tx    <= 8'hff;
                    byte_start <= 1'b1;
                    state      <= ST_WEL_DATA_WAIT;
                end
                ST_WEL_DATA_WAIT: if (byte_done) begin
                    if (!byte_rx[1]) begin
                        if (wel_for_program)
                            finish_error(ERR_PROGRAM_WEL);
                        else
                            finish_error(ERR_ERASE_WEL);
                    end else if (wel_for_program) begin
                        address_index <= 2'd0;
                        begin_cs_gap(ST_PROG_CMD_ISSUE);
                    end else begin
                        address_index <= 2'd0;
                        begin_cs_gap(ST_ERASE_CMD_ISSUE);
                    end
                end

                ST_ERASE_CMD_ISSUE: begin
                    spi_cs_n   <= 1'b0;
                    byte_tx    <= 8'h20;
                    byte_start <= 1'b1;
                    state      <= ST_ERASE_CMD_WAIT;
                end
                ST_ERASE_CMD_WAIT: if (byte_done)
                    state <= ST_ERASE_ADR_ISSUE;
                ST_ERASE_ADR_ISSUE: begin
                    byte_tx    <= address_byte(address_latched,address_index);
                    byte_start <= 1'b1;
                    state      <= ST_ERASE_ADR_WAIT;
                end
                ST_ERASE_ADR_WAIT: if (byte_done) begin
                    if (address_index == 2'd2) begin
                        poll_for_program <= 1'b0;
                        preflight_poll   <= 1'b0;
                        poll_active      <= 1'b1;
                        saw_wip_high     <= 1'b0;
                        poll_elapsed_count <= 32'd0;
                        poll_timeout_limit <= ERASE_TIMEOUT_CYCLES;
                        poll_interval_count <= 32'd0;
                        begin_cs_gap(ST_POLL_CMD_ISSUE);
                    end else begin
                        address_index <= address_index + 1'b1;
                        state <= ST_ERASE_ADR_ISSUE;
                    end
                end

                ST_POLL_CMD_ISSUE: begin
                    spi_cs_n   <= 1'b0;
                    byte_tx    <= 8'h05;
                    byte_start <= 1'b1;
                    state      <= ST_POLL_CMD_WAIT;
                end
                ST_POLL_CMD_WAIT: if (byte_done)
                    state <= ST_POLL_DAT_ISSUE;
                ST_POLL_DAT_ISSUE: begin
                    byte_tx    <= 8'hff;
                    byte_start <= 1'b1;
                    state      <= ST_POLL_DAT_WAIT;
                end
                ST_POLL_DAT_WAIT: if (byte_done) begin
                    if (preflight_poll) begin
                        if (!byte_rx[0]) begin
                            poll_active <= 1'b0;
                            preflight_poll <= 1'b0;
                            if (op_write_latched && byte_rx[4:2] != 3'b000)
                                finish_error(ERR_PROTECTED);
                            else if (op_write_latched)
                                begin_cs_gap(ST_WREN_ISSUE);
                            else
                                begin_cs_gap(ST_READ_CMD_ISSUE);
                        end else begin
                            poll_interval_count <= 32'd0;
                            begin_cs_gap(ST_POLL_INTERVAL);
                        end
                    end else if (!byte_rx[0]) begin
                        poll_active <= 1'b0;
                        if (!saw_wip_high) begin
                            if (poll_for_program)
                                finish_error(ERR_PROG_NO_WIP);
                            else
                                finish_error(ERR_ERASE_NO_WIP);
                        end else if (poll_for_program) begin
                            byte_index  <= 4'd0;
                            read_data   <= {RECORD_BYTES*8{1'b0}};
                            verify_read <= 1'b1;
                            record_shift <= write_data_latched;
                            begin_cs_gap(ST_READ_CMD_ISSUE);
                        end else begin
                            wel_for_program <= 1'b1;
                            begin_cs_gap(ST_WREN_ISSUE);
                        end
                    end else begin
                        saw_wip_high <= 1'b1;
                        poll_interval_count <= 32'd0;
                        begin_cs_gap(ST_POLL_INTERVAL);
                    end
                end

                ST_PROG_CMD_ISSUE: begin
                    spi_cs_n   <= 1'b0;
                    byte_tx    <= 8'h02;
                    byte_start <= 1'b1;
                    state      <= ST_PROG_CMD_WAIT;
                end
                ST_PROG_CMD_WAIT: if (byte_done)
                    state <= ST_PROG_ADR_ISSUE;
                ST_PROG_ADR_ISSUE: begin
                    byte_tx    <= address_byte(address_latched,address_index);
                    byte_start <= 1'b1;
                    state      <= ST_PROG_ADR_WAIT;
                end
                ST_PROG_ADR_WAIT: if (byte_done) begin
                    if (address_index == 2'd2) begin
                        byte_index <= 4'd0;
                        record_shift <= write_data_latched;
                        state <= ST_PROG_DAT_ISSUE;
                    end else begin
                        address_index <= address_index + 1'b1;
                        state <= ST_PROG_ADR_ISSUE;
                    end
                end
                ST_PROG_DAT_ISSUE: begin
                    byte_tx    <= record_shift[RECORD_BYTES*8-1 -: 8];
                    byte_start <= 1'b1;
                    state      <= ST_PROG_DAT_WAIT;
                end
                ST_PROG_DAT_WAIT: if (byte_done) begin
                    record_shift <= {record_shift[RECORD_BYTES*8-9:0],8'd0};
                    if (byte_index + 1 >= RECORD_BYTES) begin
                        poll_for_program <= 1'b1;
                        preflight_poll   <= 1'b0;
                        poll_active      <= 1'b1;
                        saw_wip_high     <= 1'b0;
                        poll_elapsed_count <= 32'd0;
                        poll_timeout_limit <= PROGRAM_TIMEOUT_CYCLES;
                        poll_interval_count <= 32'd0;
                        begin_cs_gap(ST_POLL_CMD_ISSUE);
                    end else begin
                        byte_index <= byte_index + 1'b1;
                        state <= ST_PROG_DAT_ISSUE;
                    end
                end

                ST_READ_CMD_ISSUE: begin
                    spi_cs_n   <= 1'b0;
                    byte_tx    <= 8'h03;
                    byte_start <= 1'b1;
                    state      <= ST_READ_CMD_WAIT;
                end
                ST_READ_CMD_WAIT: if (byte_done) begin
                    address_index <= 2'd0;
                    state <= ST_READ_ADR_ISSUE;
                end
                ST_READ_ADR_ISSUE: begin
                    byte_tx    <= address_byte(address_latched,address_index);
                    byte_start <= 1'b1;
                    state      <= ST_READ_ADR_WAIT;
                end
                ST_READ_ADR_WAIT: if (byte_done) begin
                    if (address_index == 2'd2) begin
                        byte_index <= 4'd0;
                        state <= ST_READ_DAT_ISSUE;
                    end else begin
                        address_index <= address_index + 1'b1;
                        state <= ST_READ_ADR_ISSUE;
                    end
                end
                ST_READ_DAT_ISSUE: begin
                    byte_tx    <= 8'hff;
                    byte_start <= 1'b1;
                    state      <= ST_READ_DAT_WAIT;
                end
                ST_READ_DAT_WAIT: if (byte_done) begin
                    read_data <= {read_data[RECORD_BYTES*8-9:0],byte_rx};
                    if (verify_read && byte_rx != record_shift[RECORD_BYTES*8-1 -: 8]) begin
                        finish_error(ERR_VERIFY);
                    end else if (byte_index + 1 >= RECORD_BYTES) begin
                        finish_success();
                    end else begin
                        if (verify_read)
                            record_shift <= {record_shift[RECORD_BYTES*8-9:0],8'd0};
                        byte_index <= byte_index + 1'b1;
                        state <= ST_READ_DAT_ISSUE;
                    end
                end
                ST_CS_HIGH_WAIT: begin
                    spi_cs_n <= 1'b1;
                    if (cs_high_count + 1 >= CS_HIGH_CYCLES) begin
                        cs_high_count <= 32'd0;
                        state <= cs_gap_return_state;
                    end else begin
                        cs_high_count <= cs_high_count + 1'b1;
                    end
                end
                ST_POLL_INTERVAL: begin
                    spi_cs_n <= 1'b1;
                    if (poll_elapsed_count >= poll_timeout_limit) begin
                        if (preflight_poll)
                            finish_error(ERR_BUSY_TIMEOUT);
                        else if (poll_for_program)
                            finish_error(ERR_PROG_TIMEOUT);
                        else
                            finish_error(ERR_ERASE_TIMEOUT);
                    end else if (poll_interval_count + 1 >= POLL_INTERVAL_CYCLES) begin
                        poll_interval_count <= 32'd0;
                        state <= ST_POLL_CMD_ISSUE;
                    end else begin
                        poll_interval_count <= poll_interval_count + 1'b1;
                    end
                end
                ST_COMPLETE_OK: begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    error      <= 1'b0;
                    error_code <= ERR_NONE;
                    state      <= ST_IDLE;
                end
                ST_COMPLETE_ERROR: begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    error      <= 1'b1;
                    error_code <= pending_error_code;
                    state      <= ST_IDLE;
                end
                default: finish_error(ERR_VERIFY);
            endcase
        end
    end
endmodule
