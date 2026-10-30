`timescale 1ns/1ps

module media_ingest_frontend #(
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480,
    parameter integer ADDR_WIDTH = 21,
    parameter integer FIFO_DEPTH = 512,
    parameter integer STALL_TIMEOUT = 65535,
    parameter integer ALLOW_2X_SOURCE = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output wire                  busy,
    output wire                  done,
    output wire [7:0]            ingest_error,
    output wire [7:0]            ingest_detail_error,
    output wire [1:0]            current_image,
    output wire [3:0]            resource_valid,
    output wire [3:0]            image_complete,
    output wire [3:0]            image_failed,
    output wire                  ingest_fatal,
    output wire [3:0]            image_scale_2x,
    input  wire [2:0]            diagnostic_select,
    output wire [31:0]           diagnostic_data,
    output wire                  reader_req,
    output wire [31:0]           reader_lba,
    input  wire                  reader_busy,
    input  wire                  reader_valid,
    input  wire [7:0]            reader_byte,
    input  wire [8:0]            reader_byte_index,
    input  wire                  reader_done,
    input  wire [7:0]            reader_error,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data
);
    wire replay_busy;
    wire replay_valid;
    wire [7:0] replay_byte;
    wire [8:0] replay_byte_index;
    wire replay_done;
    wire [7:0] replay_error;
    wire ingest_sector_req;
    wire [31:0] ingest_sector_lba;
    wire ingest_busy;

    assign busy = ingest_busy || replay_busy;

    sd_sector_replay_buffer u_sector_replay (
        .clk(clk), .rst_n(rst_n),
        .sector_req(ingest_sector_req), .sector_lba(ingest_sector_lba),
        .sector_busy(replay_busy), .sector_valid(replay_valid),
        .sector_byte(replay_byte), .sector_byte_index(replay_byte_index),
        .sector_done(replay_done), .sector_error(replay_error),
        .reader_req(reader_req), .reader_lba(reader_lba),
        .reader_busy(reader_busy), .reader_valid(reader_valid),
        .reader_byte(reader_byte), .reader_byte_index(reader_byte_index),
        .reader_done(reader_done), .reader_error(reader_error)
    );

    media_ingest_pipeline #(
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
        .STALL_TIMEOUT(STALL_TIMEOUT), .ALLOW_2X_SOURCE(ALLOW_2X_SOURCE)
    ) u_ingest_pipeline (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(ingest_busy), .done(done),
        .ingest_error(ingest_error), .ingest_detail_error(ingest_detail_error),
        .current_image(current_image),
        .resource_valid(resource_valid), .image_complete(image_complete),
        .image_failed(image_failed), .ingest_fatal(ingest_fatal),
        .image_scale_2x(image_scale_2x),
        .diagnostic_select(diagnostic_select), .diagnostic_data(diagnostic_data),
        .sector_req(ingest_sector_req), .sector_lba(ingest_sector_lba),
        .sector_busy(replay_busy), .sector_valid(replay_valid),
        .sector_byte(replay_byte), .sector_byte_index(replay_byte_index),
        .sector_done(replay_done), .sector_error(replay_error),
        .controller_init_done(controller_init_done), .controller_busy(controller_busy),
        .refresh_active(refresh_active), .app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr), .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data)
    );
endmodule
