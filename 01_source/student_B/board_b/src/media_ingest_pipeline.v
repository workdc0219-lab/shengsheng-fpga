`timescale 1ns/1ps

module media_ingest_pipeline #(
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
    output reg                   done,
    output reg  [7:0]            ingest_error,
    output reg  [7:0]            ingest_detail_error,
    output reg  [1:0]            current_image,
    output wire [3:0]            resource_valid,
    output wire [3:0]            image_complete,
    // F6: per-slot load failure. A set bit means that image was skipped; the
    // other slots still load and its bank reads back black.
    output reg  [3:0]            image_failed,
    // F6: the volume itself is unusable (no FAT32, no resource at all), so
    // nothing can be shown. Per-image failures are not fatal.
    output reg                   ingest_fatal,
    output reg  [3:0]            image_scale_2x,
    input  wire [2:0]            diagnostic_select,
    output wire [31:0]           diagnostic_data,

    output wire                  sector_req,
    output wire [31:0]           sector_lba,
    input  wire                  sector_busy,
    input  wire                  sector_valid,
    input  wire [7:0]            sector_byte,
    input  wire [8:0]            sector_byte_index,
    input  wire                  sector_done,
    input  wire [7:0]            sector_error,

    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data
);
    localparam integer IMAGE_WORDS = IMAGE_WIDTH * IMAGE_HEIGHT;
    localparam ERR_NONE   = 8'h00;
    localparam ERR_SCAN   = 8'h80;
    localparam ERR_FILE   = 8'h82;
    localparam ERR_BMP    = 8'h83;
    localparam ERR_MEMORY = 8'h84;
    localparam ERR_MISSING = 8'h85;   // F6: this slot has no file on the card

    localparam ST_IDLE      = 3'd0;
    localparam ST_SCAN      = 3'd1;
    localparam ST_FILE_START= 3'd2;
    localparam ST_FILL      = 3'd3;
    localparam ST_FILE      = 3'd4;
    localparam ST_SKIP      = 3'd5;
    localparam ST_FAIL_WAIT = 3'd6;

    reg [2:0] state;
    reg scan_start;
    reg file_start;
    reg load_start;
    // F6: bmp_error holds the previous image's code until the decoder sees
    // file_start. The loader is already active (pre-filling the bank) by
    // then, so it must not see the stale code.
    reg decode_armed;

    wire scan_busy;
    wire scan_done;
    wire [7:0] scan_error;
    wire [7:0] sectors_per_cluster;
    wire [31:0] fat_start_lba;
    wire [31:0] data_start_lba;
    wire [31:0] max_cluster;
    wire [31:0] resource0_cluster, resource1_cluster;
    wire [31:0] resource2_cluster, resource3_cluster;
    wire [31:0] resource0_size, resource1_size;
    wire [31:0] resource2_size, resource3_size;
    wire scan_sector_req;
    wire [31:0] scan_sector_lba;

    wire file_busy;
    wire file_done;
    wire file_valid;
    wire [7:0] file_byte;
    wire [31:0] file_byte_offset;
    wire [7:0] file_error;
    wire file_sector_req;
    wire [31:0] file_sector_lba;
    wire [31:0] selected_cluster;
    wire [31:0] selected_size;

    wire pixel_valid;
    wire [23:0] pixel_rgb;
    wire frame_commit;
    wire bmp_done;
    wire [7:0] bmp_error;
    wire source_scale_2x;
    wire load_busy;
    wire load_done;
    wire pixels_ready;
    wire [7:0] memory_error;

    assign busy = state != ST_IDLE;
    assign sector_req = scan_sector_req | file_sector_req;
    assign sector_lba = scan_sector_req ? scan_sector_lba : file_sector_lba;

    assign selected_cluster = current_image == 2'd0 ? resource0_cluster :
                              current_image == 2'd1 ? resource1_cluster :
                              current_image == 2'd2 ? resource2_cluster : resource3_cluster;
    assign selected_size = current_image == 2'd0 ? resource0_size :
                           current_image == 2'd1 ? resource1_size :
                           current_image == 2'd2 ? resource2_size : resource3_size;

    // F6: a card with only some of the four pictures still plays; the empty
    // slots come back black and are skipped by the playlist.
    fat32_volume_scanner #(.ALLOW_PARTIAL_SET(1)) u_volume_scanner (
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start), .scan_busy(scan_busy),
        .scan_done(scan_done), .fs_error(scan_error), .partition_lba(),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .resource_valid(resource_valid),
        .resource0_cluster(resource0_cluster), .resource1_cluster(resource1_cluster),
        .resource2_cluster(resource2_cluster), .resource3_cluster(resource3_cluster),
        .resource0_size(resource0_size), .resource1_size(resource1_size),
        .resource2_size(resource2_size), .resource3_size(resource3_size),
        .sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );

    fat32_file_streamer u_file_streamer (
        .clk(clk), .rst_n(rst_n), .file_start(file_start),
        .first_cluster(selected_cluster), .file_size(selected_size),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(file_busy), .file_done(file_done), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_byte_offset), .fs_error(file_error),
        .sector_req(file_sector_req), .sector_lba(file_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );

    wire bmp_top_down;   // R7-A3-F1: orientation from the BMP header
    // F6 step 2: geometry of the decoded image inside the bank
    localparam integer W_BITS = $clog2(IMAGE_WIDTH + 1);
    localparam integer H_BITS = $clog2(IMAGE_HEIGHT + 1);
    wire [W_BITS-1:0] bmp_out_width;
    wire [H_BITS-1:0] bmp_out_height;
    wire [W_BITS-1:0] bmp_x_offset;
    wire [W_BITS-1:0] bmp_x_end;
    wire [H_BITS-1:0] bmp_y_offset;
    bmp24_decoder #(
        .EXPECTED_WIDTH(IMAGE_WIDTH), .EXPECTED_HEIGHT(IMAGE_HEIGHT),
        .ALLOW_2X_SOURCE(ALLOW_2X_SOURCE), .ALLOW_ANY_SIZE(1)
    ) u_bmp_decoder (
        .clk(clk), .rst_n(rst_n), .file_start(file_start), .file_size(selected_size),
        .file_valid(file_valid), .file_byte(file_byte), .file_byte_offset(file_byte_offset),
        .file_end(file_done), .upstream_error(file_error), .header_accepted(),
        .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .pixel_x(), .pixel_y(),
        .frame_commit(frame_commit), .bmp_done(bmp_done), .bmp_error(bmp_error),
        .top_down(bmp_top_down), .pixel_offset(), .row_stride(),
        .source_scale_2x(source_scale_2x),
        .out_width(bmp_out_width), .out_height(bmp_out_height),
        .x_offset(bmp_x_offset), .x_end(bmp_x_end), .y_offset(bmp_y_offset)
    );

    media_frame_loader #(
        .ADDR_WIDTH(ADDR_WIDTH), .IMAGE_WORDS(IMAGE_WORDS),
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .FIFO_DEPTH(FIFO_DEPTH), .STALL_TIMEOUT(STALL_TIMEOUT),
        .ENABLE_PREFILL(1), .ENABLE_ANY_SIZE(1)
    ) u_frame_loader (
        .clk(clk), .rst_n(rst_n), .load_start(load_start), .image_index(current_image),
        .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .frame_commit(frame_commit),
        .decode_error(decode_armed ? bmp_error : 8'h00), .top_down(bmp_top_down),
        .out_height(bmp_out_height),
        .x_offset(bmp_x_offset), .x_end(bmp_x_end), .y_offset(bmp_y_offset),
        .load_busy(load_busy), .load_done(load_done), .pixels_ready(pixels_ready),
        .image_complete(image_complete), .memory_error(memory_error),
        .diagnostic_select(diagnostic_select), .diagnostic_data(diagnostic_data),
        .controller_init_done(controller_init_done), .controller_busy(controller_busy),
        .refresh_active(refresh_active), .app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr), .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data)
    );

    // F6: remember that this slot failed and keep the first failure as the
    // reported code, then let the card carry on with the other images.
    task note_failure;
        input [7:0] code;
        input [7:0] detail;
        begin
            image_failed[current_image] <= 1'b1;
            if (ingest_error == ERR_NONE) begin
                ingest_error <= code;
                ingest_detail_error <= detail;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;
            ingest_error <= ERR_NONE;
            ingest_detail_error <= ERR_NONE;
            current_image <= 2'd0;
            image_scale_2x <= 4'd0;
            image_failed <= 4'd0;
            ingest_fatal <= 1'b0;
            decode_armed <= 1'b0;
        end else begin
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;

            // armed from the second cycle of ST_FILE, i.e. once the decoder
            // has consumed file_start and cleared its own error
            if (state == ST_FILE) begin
                if (!file_start)
                    decode_armed <= 1'b1;
            end else begin
                decode_armed <= 1'b0;
            end

            case (state)
                ST_IDLE: if (start) begin
                    ingest_error <= ERR_NONE;
                    ingest_detail_error <= ERR_NONE;
                    current_image <= 2'd0;
                    image_scale_2x <= 4'd0;
                    image_failed <= 4'd0;
                    ingest_fatal <= 1'b0;
                    scan_start <= 1'b1;
                    state <= ST_SCAN;
                end
                ST_SCAN: if (scan_done) begin
                    if (scan_error != 0) begin
                        // no volume, no directory: nothing to skip to
                        ingest_error <= ERR_SCAN;
                        ingest_detail_error <= scan_error;
                        ingest_fatal <= 1'b1;
                        image_failed <= 4'hf;
                        state <= ST_FAIL_WAIT;
                    end else begin
                        current_image <= 2'd0;
                        state <= ST_FILE_START;
                    end
                end
                ST_FILE_START: begin
                    load_start <= 1'b1;
                    state <= ST_FILL;
                end
                // F6: the loader blacks out the bank before it accepts a
                // pixel, so the file may only start once pixels_ready is up.
                ST_FILL: if (pixels_ready) begin
                    file_start <= 1'b1;
                    state <= ST_FILE;
                end else if (load_done) begin
                    // the fill itself failed (write stall): skip this slot
                    note_failure(ERR_MEMORY, memory_error);
                    state <= ST_SKIP;
                end
                ST_FILE: if (load_done) begin
                    if (!resource_valid[current_image]) begin
                        note_failure(ERR_FILE, ERR_MISSING);
                        state <= ST_SKIP;
                    end else if (file_error != 0) begin
                        note_failure(ERR_FILE, file_error);
                        state <= ST_SKIP;
                    end else if (bmp_error != 0) begin
                        note_failure(ERR_BMP, bmp_error);
                        state <= ST_SKIP;
                    end else if (memory_error != 0) begin
                        note_failure(ERR_MEMORY, memory_error);
                        state <= ST_SKIP;
                    end else if (current_image == 2'd3) begin
                        image_scale_2x[current_image] <= source_scale_2x;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        image_scale_2x[current_image] <= source_scale_2x;
                        current_image <= current_image + 1'b1;
                        state <= ST_FILE_START;
                    end
                end
                // F6: one bad image no longer aborts the card. Let the file
                // streamer and the loader go quiet, then take the next slot.
                ST_SKIP: if (!file_busy && !load_busy) begin
                    if (current_image == 2'd3) begin
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        current_image <= current_image + 1'b1;
                        state <= ST_FILE_START;
                    end
                end
                ST_FAIL_WAIT: if (!scan_busy && !file_busy && !load_busy) begin
                    done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
