`timescale 1ns/1ps

module promax_scale_line_buffer #(
    parameter integer DEPTH = 640,
    parameter integer ADDRESS_WIDTH = 10
) (
    input  wire                     clk,
    input  wire                     write_enable,
    input  wire [ADDRESS_WIDTH-1:0] write_address,
    input  wire [26:0]              write_data,
    input  wire                     read_enable,
    input  wire [ADDRESS_WIDTH-1:0] read_address,
    output reg  [26:0]              read_data
);
    reg [26:0] memory [0:DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;

    always @(posedge clk) begin
        if (write_enable)
            memory[write_address] <= write_data;
        if (read_enable)
            read_data <= memory[read_address];
    end
endmodule

module bmp24_decoder #(
    parameter integer EXPECTED_WIDTH = 640,
    parameter integer EXPECTED_HEIGHT = 480,
    parameter integer ALLOW_2X_SOURCE = 0,
    // F6 step 2: 1 accepts any source up to twice the output in each
    // direction. Anything larger than the output goes through the existing
    // 2x2 average; what is left is centred by the loader and the rest of the
    // bank stays black. 0 keeps the V7 exact-geometry rule.
    parameter integer ALLOW_ANY_SIZE = 0,
    // derived port widths, not meant to be overridden
    parameter integer W_BITS = $clog2(EXPECTED_WIDTH + 1),
    parameter integer H_BITS = $clog2(EXPECTED_HEIGHT + 1)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] file_size,
    input  wire        file_valid,
    input  wire [7:0]  file_byte,
    input  wire [31:0] file_byte_offset,
    input  wire        file_end,
    input  wire [7:0]  upstream_error,
    output reg         header_accepted,
    output reg         pixel_valid,
    output reg  [23:0] pixel_rgb,
    output reg  [15:0] pixel_x,
    output reg  [15:0] pixel_y,
    output reg         frame_commit,
    output reg         bmp_done,
    output reg  [7:0]  bmp_error,
    output reg         top_down,
    output reg  [31:0] pixel_offset,
    output wire [31:0] row_stride,
    output wire        source_scale_2x,
    // F6 step 2: geometry of the decoded image and where the loader has to
    // put it inside the bank. Constant full-frame values when
    // ALLOW_ANY_SIZE is 0.
    output reg  [W_BITS-1:0] out_width,
    output reg  [H_BITS-1:0] out_height,
    output reg  [W_BITS-1:0] x_offset,
    output reg  [W_BITS-1:0] x_end,
    output reg  [H_BITS-1:0] y_offset
);
    // widest source this instance will take, and the counters sized for it
    localparam integer SRC_W_MAX = EXPECTED_WIDTH * 2;
    localparam integer SRC_H_MAX = EXPECTED_HEIGHT * 2;
    localparam integer SW_BITS = $clog2(SRC_W_MAX + 1);
    localparam integer SH_BITS = $clog2(SRC_H_MAX + 1);
    localparam integer STRIDE_BITS = $clog2(SRC_W_MAX * 3 + 4);
    localparam ERR_NONE        = 8'h00;
    localparam ERR_SIGNATURE   = 8'h31;
    localparam ERR_DIMENSIONS  = 8'h32;
    localparam ERR_PLANES      = 8'h33;
    localparam ERR_BPP         = 8'h34;
    localparam ERR_COMPRESSION = 8'h35;
    localparam ERR_OFFSET      = 8'h36;
    localparam ERR_TRUNCATED   = 8'h37;
    localparam ERR_UPSTREAM    = 8'h38;
    localparam integer BASE_ROW_STRIDE = ((EXPECTED_WIDTH * 3 + 3) / 4) * 4;
    localparam integer DOUBLE_ROW_STRIDE = ((EXPECTED_WIDTH * 6 + 3) / 4) * 4;
    localparam integer BASE_DATA_BYTES = BASE_ROW_STRIDE * EXPECTED_HEIGHT;
    localparam integer DOUBLE_DATA_BYTES = DOUBLE_ROW_STRIDE * EXPECTED_HEIGHT * 2;

    reg [7:0] header [0:53];
    reg decode_enabled;
    // F6: the stream counters only ever hold source geometry, so they are
    // sized from it instead of the 32 bit header fields they come from.
    reg [STRIDE_BITS-1:0] byte_in_row;
    reg [SH_BITS-1:0] physical_row;
    reg [1:0] channel_phase;
    reg [7:0] blue_hold;
    reg [7:0] green_hold;
    reg [SW_BITS-1:0] x_count;
    reg [SW_BITS-1:0] source_width;
    reg [SH_BITS-1:0] source_height;
    reg [STRIDE_BITS-1:0] source_stride;
    reg [STRIDE_BITS-1:0] source_row_bytes;
    reg source_is_2x;
    reg [7:0] pair_red;
    reg [7:0] pair_green;
    reg [7:0] pair_blue;
    wire row_pair_write_enable;
    wire row_pair_read_enable;
    wire [9:0] row_pair_address;
    wire [26:0] row_pair_write_data;
    wire [26:0] row_pair_read_data;
    reg signature_ok_q;
    reg signed [31:0] parsed_height_q;
    reg [31:0] absolute_height_q;
    reg [31:0] parsed_width_q;
    reg [31:0] parsed_offset_q;
    reg [31:0] dib_size_q;
    reg [31:0] header_file_size_q;
    reg [15:0] planes_q;
    reg [15:0] bpp_q;
    reg [31:0] compression_q;

    assign source_scale_2x = source_is_2x;
    assign row_stride = {{(32-STRIDE_BITS){1'b0}}, source_stride};
    assign row_pair_address = x_count[SW_BITS-1:1];
    assign row_pair_write_data = {
        {1'b0, pair_red} + {1'b0, file_byte},
        {1'b0, pair_green} + {1'b0, green_hold},
        {1'b0, pair_blue} + {1'b0, blue_hold}
    };
    assign row_pair_write_enable = file_valid && decode_enabled &&
                                   file_byte_offset >= pixel_offset &&
                                   physical_row < source_height &&
                                   byte_in_row < source_row_bytes &&
                                   channel_phase == 2'd2 && source_is_2x &&
                                   !physical_row[0] && x_count[0];
    assign row_pair_read_enable = file_valid && decode_enabled &&
                                  file_byte_offset >= pixel_offset &&
                                  physical_row < source_height &&
                                  byte_in_row < source_row_bytes &&
                                  channel_phase == 2'd0 && source_is_2x &&
                                  physical_row[0] && !x_count[0];

    promax_scale_line_buffer #(
        .DEPTH(EXPECTED_WIDTH),
        .ADDRESS_WIDTH(10)
    ) u_scale_line_buffer (
        .clk(clk),
        .write_enable(row_pair_write_enable),
        .write_address(row_pair_address),
        .write_data(row_pair_write_data),
        .read_enable(row_pair_read_enable),
        .read_address(row_pair_address),
        .read_data(row_pair_read_data)
    );

    function [7:0] average_four;
        input [8:0] first_row_pair;
        input [7:0] second_row_first;
        input [7:0] second_row_second;
        reg [9:0] total;
        begin
            total = {1'b0, first_row_pair} +
                    {2'b00, second_row_first} +
                    {2'b00, second_row_second} + 10'd2;
            average_four = total[9:2];
        end
    endfunction

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {header[offset+1], header[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {header[offset+3], header[offset+2], header[offset+1], header[offset]};
        end
    endfunction

    // F6 step 2: oversize in either direction selects the 2x path, which is
    // why a source is capped at twice the output -- after halving it always
    // fits the bank, so nothing ever has to be cropped.
    wire geometry_ok = (ALLOW_ANY_SIZE != 0) ?
        (parsed_width_q >= 1 && parsed_width_q <= SRC_W_MAX &&
         absolute_height_q >= 1 && absolute_height_q <= SRC_H_MAX) :
        ((parsed_width_q == EXPECTED_WIDTH &&
          absolute_height_q == EXPECTED_HEIGHT) ||
         (ALLOW_2X_SOURCE != 0 &&
          parsed_width_q == EXPECTED_WIDTH*2 &&
          absolute_height_q == EXPECTED_HEIGHT*2));
    wire scale_two = (parsed_width_q > EXPECTED_WIDTH) ||
                     (absolute_height_q > EXPECTED_HEIGHT);
    wire [SW_BITS-1:0] src_w = parsed_width_q[SW_BITS-1:0];
    wire [SH_BITS-1:0] src_h = absolute_height_q[SH_BITS-1:0];
    wire [W_BITS-1:0] eff_width = scale_two ? src_w[SW_BITS-1:1] : src_w[W_BITS-1:0];
    wire [H_BITS-1:0] eff_height = scale_two ? src_h[SH_BITS-1:1] : src_h[H_BITS-1:0];
    wire [STRIDE_BITS-1:0] src_row_bytes = {src_w, 1'b0} + src_w;
    wire [STRIDE_BITS-1:0] src_row_round = src_row_bytes + 3;
    wire [STRIDE_BITS-1:0] src_stride = {src_row_round[STRIDE_BITS-1:2], 2'b00};
    localparam [W_BITS-1:0] FULL_WIDTH = EXPECTED_WIDTH;
    localparam [H_BITS-1:0] FULL_HEIGHT = EXPECTED_HEIGHT;

    task validate_header;
        begin
            if (!signature_ok_q) begin
                bmp_error <= ERR_SIGNATURE;
                decode_enabled <= 1'b0;
            end else if (!geometry_ok || dib_size_q < 40) begin
                bmp_error <= ERR_DIMENSIONS;
                decode_enabled <= 1'b0;
            end else if (planes_q != 1) begin
                bmp_error <= ERR_PLANES;
                decode_enabled <= 1'b0;
            end else if (bpp_q != 24) begin
                bmp_error <= ERR_BPP;
                decode_enabled <= 1'b0;
            end else if (compression_q != 0) begin
                bmp_error <= ERR_COMPRESSION;
                decode_enabled <= 1'b0;
            end else if (parsed_offset_q < 54 || parsed_offset_q >= file_size) begin
                bmp_error <= ERR_OFFSET;
                decode_enabled <= 1'b0;
            end else if (header_file_size_q > file_size) begin
                // F6: the "does the pixel array fit" pre-check needed a
                // stride x height product. A short file is caught at
                // file_end instead, by the physical row count.
                bmp_error <= ERR_TRUNCATED;
                decode_enabled <= 1'b0;
            end else begin
                header_accepted <= 1'b1;
                decode_enabled <= 1'b1;
                top_down <= parsed_height_q[31];
                pixel_offset <= parsed_offset_q;
                source_width <= src_w;
                source_height <= src_h;
                source_row_bytes <= src_row_bytes;
                source_stride <= src_stride;
                source_is_2x <= scale_two;
                out_width <= eff_width;
                out_height <= eff_height;
                x_offset <= (FULL_WIDTH - eff_width) >> 1;
                x_end <= ((FULL_WIDTH - eff_width) >> 1) + eff_width;
                y_offset <= (FULL_HEIGHT - eff_height) >> 1;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            header_accepted <= 1'b0;
            pixel_valid <= 1'b0;
            pixel_rgb <= 24'd0;
            pixel_x <= 16'd0;
            pixel_y <= 16'd0;
            frame_commit <= 1'b0;
            bmp_done <= 1'b0;
            bmp_error <= ERR_NONE;
            top_down <= 1'b0;
            pixel_offset <= 32'd0;
            decode_enabled <= 1'b0;
            byte_in_row <= 0;
            physical_row <= 0;
            channel_phase <= 2'd0;
            blue_hold <= 8'd0;
            green_hold <= 8'd0;
            x_count <= 0;
            source_width <= EXPECTED_WIDTH;
            source_height <= EXPECTED_HEIGHT;
            source_row_bytes <= EXPECTED_WIDTH*3;
            source_stride <= BASE_ROW_STRIDE;
            source_is_2x <= 1'b0;
            out_width <= FULL_WIDTH;
            out_height <= FULL_HEIGHT;
            x_offset <= 0;
            x_end <= FULL_WIDTH;
            y_offset <= 0;
            pair_red <= 8'd0;
            pair_green <= 8'd0;
            pair_blue <= 8'd0;
            signature_ok_q <= 1'b0;
            parsed_height_q <= 32'sd0;
            absolute_height_q <= 32'd0;
            parsed_width_q <= 32'd0;
            parsed_offset_q <= 32'd0;
            dib_size_q <= 32'd0;
            header_file_size_q <= 32'd0;
            planes_q <= 16'd0;
            bpp_q <= 16'd0;
            compression_q <= 32'd0;
        end else begin
            pixel_valid <= 1'b0;
            frame_commit <= 1'b0;
            bmp_done <= 1'b0;

            if (file_start) begin
                header_accepted <= 1'b0;
                bmp_error <= ERR_NONE;
                top_down <= 1'b0;
                pixel_offset <= 32'd0;
                decode_enabled <= 1'b0;
                byte_in_row <= 0;
                physical_row <= 0;
                channel_phase <= 2'd0;
                x_count <= 0;
                source_width <= EXPECTED_WIDTH;
                source_height <= EXPECTED_HEIGHT;
                source_row_bytes <= EXPECTED_WIDTH*3;
                source_stride <= BASE_ROW_STRIDE;
                source_is_2x <= 1'b0;
                out_width <= FULL_WIDTH;
                out_height <= FULL_HEIGHT;
                x_offset <= 0;
                x_end <= FULL_WIDTH;
                y_offset <= 0;
                pair_red <= 8'd0;
                pair_green <= 8'd0;
                pair_blue <= 8'd0;
                signature_ok_q <= 1'b0;
                parsed_height_q <= 32'sd0;
                absolute_height_q <= 32'd0;
                parsed_width_q <= 32'd0;
                parsed_offset_q <= 32'd0;
                dib_size_q <= 32'd0;
                header_file_size_q <= 32'd0;
                planes_q <= 16'd0;
                bpp_q <= 16'd0;
                compression_q <= 32'd0;
            end

            if (file_valid && file_byte_offset < 54)
                header[file_byte_offset] <= file_byte;

            if (file_valid && file_byte_offset == 2)
                signature_ok_q <= (header[0] == "B" && header[1] == "M");

            if (file_valid && file_byte_offset == 40) begin
                parsed_height_q <= le32(22);
                parsed_width_q <= le32(18);
                parsed_offset_q <= le32(10);
                dib_size_q <= le32(14);
                header_file_size_q <= le32(2);
                planes_q <= le16(26);
                bpp_q <= le16(28);
                compression_q <= le32(30);
            end

            if (file_valid && file_byte_offset == 41)
                absolute_height_q <= parsed_height_q[31] ?
                                     (~parsed_height_q + 1'b1) : parsed_height_q;

            if (file_valid && file_byte_offset == 52)
                validate_header();

            if (file_valid && decode_enabled && file_byte_offset >= pixel_offset &&
                physical_row < source_height) begin
                if (byte_in_row < source_row_bytes) begin
                    case (channel_phase)
                        2'd0: begin
                            blue_hold <= file_byte;
                            channel_phase <= 2'd1;
                        end
                        2'd1: begin
                            green_hold <= file_byte;
                            channel_phase <= 2'd2;
                        end
                        default: begin
                            if (!source_is_2x) begin
                                pixel_valid <= 1'b1;
                                pixel_rgb <= {file_byte, green_hold, blue_hold};
                                pixel_x <= x_count;
                                if (top_down)
                                    pixel_y <= physical_row;
                                else
                                    pixel_y <= out_height - 1 - physical_row;
                            end else if (!x_count[0]) begin
                                pair_red <= file_byte;
                                pair_green <= green_hold;
                                pair_blue <= blue_hold;
                            end else if (physical_row[0]) begin
                                pixel_valid <= 1'b1;
                                pixel_rgb <= {
                                    average_four(row_pair_read_data[26:18], pair_red, file_byte),
                                    average_four(row_pair_read_data[17:9], pair_green, green_hold),
                                    average_four(row_pair_read_data[8:0], pair_blue, blue_hold)
                                };
                                pixel_x <= x_count >> 1;
                                if (top_down)
                                    pixel_y <= physical_row >> 1;
                                else
                                    pixel_y <= out_height - 1 - (physical_row >> 1);
                            end
                            x_count <= x_count + 1'b1;
                            channel_phase <= 2'd0;
                        end
                    endcase
                end

                if (byte_in_row == source_stride - 1'b1) begin
                    byte_in_row <= 0;
                    physical_row <= physical_row + 1'b1;
                    channel_phase <= 2'd0;
                    x_count <= 0;
                end else begin
                    byte_in_row <= byte_in_row + 1'b1;
                end
            end

            if (file_end) begin
                bmp_done <= 1'b1;
                decode_enabled <= 1'b0;
                if (upstream_error != 0) begin
                    bmp_error <= ERR_UPSTREAM;
                // F6: "did every source row arrive" replaces the pixel-count
                // product, which is the same test without a multiplier
                end else if (bmp_error == ERR_NONE && header_accepted &&
                             physical_row == source_height) begin
                    frame_commit <= 1'b1;
                end else if (bmp_error == ERR_NONE) begin
                    bmp_error <= ERR_TRUNCATED;
                end
            end
        end
    end
endmodule
