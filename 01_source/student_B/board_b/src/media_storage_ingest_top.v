`timescale 1ns/1ps

module media_storage_ingest_top #(
    parameter integer SPI_CLK_DIV = 4,
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480,

    parameter integer ADDR_WIDTH = 21,
    parameter integer FIFO_DEPTH = 512,
    parameter integer STALL_TIMEOUT = 65535,
    parameter integer ALLOW_2X_SOURCE = 0,
    parameter integer INIT_STARTUP_DELAY_CYCLES = 5000000,
    parameter integer INIT_SPI_CLK_DIV = 64,
    parameter integer READ_SPI_CLK_DIV = SPI_CLK_DIV,
    parameter integer ACMD41_TIMEOUT_CYCLES = 60000000,
    parameter integer TOKEN_TIMEOUT_CYCLES = 5000000
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output wire                  busy,
    output reg                   done,
    output reg  [2:0]            error_stage,
    output reg  [7:0]            error_code,
    output reg  [7:0]            error_detail,
    output wire                  card_ready,
    output wire                  card_high_capacity,
    output wire [3:0]            resource_valid,
    output wire [3:0]            image_complete,
    // F6: which slots were skipped, and whether the card is unusable at all
    // (init/scan failed, or not one image survived).
    output wire [3:0]            image_failed,
    output reg                   load_fatal,
    output wire [3:0]            image_scale_2x,
    input  wire [2:0]            diagnostic_select,
    output wire [31:0]           diagnostic_data,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data,
    output wire                  sd_cs_n,
    output wire                  sd_sclk,
    output wire                  sd_mosi,
    input  wire                  sd_miso
);
    // audit guard (2026-10-03): media_sdram_write_cdc drains the write FIFO
    // in fixed BURST_SIZE=128-word blocks, so a producer word count that is
    // not a multiple of 128 would strand the frame tail in the FIFO and
    // never assert dst_idle. The loader chain validates exact counts, but
    // this elaboration gate keeps the CDC contract explicit (both source
    // resolutions allowed by ALLOW_2X_SOURCE reduce to 640x480 = 307200).
    initial begin
        if ((IMAGE_WIDTH * IMAGE_HEIGHT) % 128 != 0) begin
            $display("INGEST_CONFIG_ERROR IMAGE_WIDTH*HEIGHT=%0d is not a multiple of the write-CDC 128-word burst",
                     IMAGE_WIDTH * IMAGE_HEIGHT);
            $finish;
        end
    end

    localparam ST_IDLE = 2'd0;
    localparam ST_INIT = 2'd1;
    localparam ST_INGEST = 2'd2;
    localparam ERR_STAGE_NONE = 3'd0;
    localparam ERR_STAGE_INIT = 3'd1;
    localparam ERR_STAGE_INGEST = 3'd2;

    reg [1:0] state;
    reg init_start;
    reg ingest_start;
    wire init_done;
    wire [7:0] init_error;
    wire service_sector_req;
    wire [31:0] service_sector_lba;
    wire service_sector_busy;
    wire service_sector_done;
    wire service_sector_valid;
    wire [7:0] service_sector_byte;
    wire [8:0] service_sector_byte_index;
    wire [7:0] service_sector_error;
    wire ingest_done;
    wire [7:0] ingest_error;
    wire [7:0] ingest_detail_error;
    wire ingest_fatal;

    assign busy = state != ST_IDLE;

    sd_media_service #(.SPI_CLK_DIV(SPI_CLK_DIV),
                       .INIT_SPI_CLK_DIV(INIT_SPI_CLK_DIV),
                       .READ_SPI_CLK_DIV(READ_SPI_CLK_DIV),
                       .ACMD41_TIMEOUT_CYCLES(ACMD41_TIMEOUT_CYCLES),
                       .TOKEN_TIMEOUT_CYCLES(TOKEN_TIMEOUT_CYCLES),
                       .INIT_STARTUP_DELAY_CYCLES(INIT_STARTUP_DELAY_CYCLES))
        u_sd_service (
        .clk(clk), .rst_n(rst_n), .init_start(init_start), .init_busy(),
        .init_done(init_done), .init_ready(card_ready), .init_error(init_error),
        .card_high_capacity(card_high_capacity), .card_ocr(), .owner_reader(),
        .sector_req(service_sector_req), .sector_lba(service_sector_lba),
        .sector_busy(service_sector_busy), .sector_done(service_sector_done),
        .sector_valid(service_sector_valid), .sector_byte(service_sector_byte),
        .sector_byte_index(service_sector_byte_index),
        .sector_error(service_sector_error), .sd_cs_n(sd_cs_n),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    media_ingest_frontend #(
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
        .STALL_TIMEOUT(STALL_TIMEOUT), .ALLOW_2X_SOURCE(ALLOW_2X_SOURCE)
    ) u_ingest_frontend (
        .clk(clk), .rst_n(rst_n), .start(ingest_start), .busy(),
        .done(ingest_done), .ingest_error(ingest_error),
        .ingest_detail_error(ingest_detail_error), .current_image(),
        .resource_valid(resource_valid), .image_complete(image_complete),
        .image_failed(image_failed), .ingest_fatal(ingest_fatal),
        .image_scale_2x(image_scale_2x),
        .diagnostic_select(diagnostic_select), .diagnostic_data(diagnostic_data),
        .reader_req(service_sector_req), .reader_lba(service_sector_lba),
        .reader_busy(service_sector_busy), .reader_valid(service_sector_valid),
        .reader_byte(service_sector_byte),
        .reader_byte_index(service_sector_byte_index),
        .reader_done(service_sector_done), .reader_error(service_sector_error),
        .controller_init_done(controller_init_done),
        .controller_busy(controller_busy), .refresh_active(refresh_active),
        .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
        .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            init_start <= 1'b0;
            ingest_start <= 1'b0;
            done <= 1'b0;
            error_stage <= ERR_STAGE_NONE;
            error_code <= 8'd0;
            error_detail <= 8'd0;
            load_fatal <= 1'b0;
        end else begin
            init_start <= 1'b0;
            ingest_start <= 1'b0;
            done <= 1'b0;
            case (state)
                ST_IDLE: if (start) begin
                    error_stage <= ERR_STAGE_NONE;
                    error_code <= 8'd0;
                    error_detail <= 8'd0;
                    load_fatal <= 1'b0;
                    init_start <= 1'b1;
                    state <= ST_INIT;
                end
                ST_INIT: if (init_done) begin
                    if (!card_ready || init_error != 0) begin
                        error_stage <= ERR_STAGE_INIT;
                        error_code <= init_error;
                        error_detail <= init_error;
                        load_fatal <= 1'b1;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        ingest_start <= 1'b1;
                        state <= ST_INGEST;
                    end
                end
                ST_INGEST: if (ingest_done) begin
                    if (ingest_error != 0) begin
                        error_stage <= ERR_STAGE_INGEST;
                        error_code <= ingest_error;
                        error_detail <= ingest_detail_error;
                    end
                    // F6: only a dead volume or an empty playlist is fatal;
                    // single skipped images leave the player usable.
                    if (ingest_fatal || image_complete == 4'd0)
                        load_fatal <= 1'b1;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
