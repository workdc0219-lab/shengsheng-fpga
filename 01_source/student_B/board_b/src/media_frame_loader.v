`timescale 1ns/1ps

module media_frame_loader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480,
    parameter integer FIFO_DEPTH = 512,
    parameter integer BURST_SIZE = 128,
    parameter integer STALL_TIMEOUT = 65535,
    // F6: 1 pre-fills the whole target bank with black before the first
    // pixel is accepted. 0 keeps the V7 behaviour bit for bit.
    parameter integer ENABLE_PREFILL = 0,
    // F6 step 2: 1 places an image of out_width x out_height at
    // (x_offset, y_offset) inside the bank. 0 ignores those inputs and
    // always writes a full IMAGE_WIDTH x IMAGE_HEIGHT frame.
    parameter integer ENABLE_ANY_SIZE = 0,
    // derived port widths, not meant to be overridden
    parameter integer W_BITS = $clog2(IMAGE_WIDTH + 1),
    parameter integer H_BITS = $clog2(IMAGE_HEIGHT + 1)
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  load_start,
    input  wire [1:0]            image_index,
    input  wire                  pixel_valid,
    input  wire [23:0]           pixel_rgb,
    input  wire                  frame_commit,
    input  wire [7:0]            decode_error,
    input  wire                  top_down,     // R7-A3-F1: BMP orientation
    // F6 step 2: decoded geometry and where to centre it (ENABLE_ANY_SIZE)
    input  wire [H_BITS-1:0]     out_height,
    input  wire [W_BITS-1:0]     x_offset,
    input  wire [W_BITS-1:0]     x_end,
    input  wire [H_BITS-1:0]     y_offset,
    output wire                  load_busy,
    output reg                   load_done,
    // F6: the bank is pre-filled with black before any pixel is accepted, so
    // a skipped or letterboxed image shows black instead of whatever the bank
    // held. High once the fill is done; the caller starts the file only then.
    output wire                  pixels_ready,
    output reg  [3:0]            image_complete,
    output reg  [7:0]            memory_error,
    input  wire [2:0]            diagnostic_select,
    output wire [31:0]           diagnostic_data,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data
);
    localparam ERR_NONE          = 8'h00;
    localparam ERR_NOT_ACTIVE    = 8'h41;
    localparam ERR_FIFO_OVERFLOW = 8'h42;
    localparam ERR_PIXEL_COUNT   = 8'h43;
    localparam ERR_DECODE        = 8'h44;
    localparam ERR_SHORT_FRAME   = 8'h45;
    localparam ERR_WRITE_STALL   = 8'h46;

    localparam integer PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam [PTR_WIDTH:0] EFFECTIVE_BURST =
        (BURST_SIZE < FIFO_DEPTH) ? BURST_SIZE : FIFO_DEPTH;
    localparam [ADDR_WIDTH-1:0] BANK0_BASE = 0;
    localparam [ADDR_WIDTH-1:0] BANK1_BASE = IMAGE_WORDS;
    localparam [ADDR_WIDTH-1:0] BANK2_BASE = IMAGE_WORDS * 2;
    localparam [ADDR_WIDTH-1:0] BANK3_BASE = IMAGE_WORDS * 3;
    // audit P2: 4 banks must fit the SDRAM address space -- BANK3_BASE is a
    // truncated localparam, so an oversized IMAGE_WORDS would silently wrap
    initial begin
        if (IMAGE_WORDS * 4 > (1 << ADDR_WIDTH)) begin
            $display("LOADER_CONFIG_ERROR 4*IMAGE_WORDS=%0d exceeds the %0d-word SDRAM address space",
                     IMAGE_WORDS * 4, 1 << ADDR_WIDTH);
            $finish;
        end
        if (IMAGE_WIDTH < 1 || IMAGE_WIDTH > 1024 || IMAGE_HEIGHT < 1 ||
            IMAGE_HEIGHT > 512 || IMAGE_WIDTH * IMAGE_HEIGHT != IMAGE_WORDS) begin
            $display("LOADER_CONFIG_ERROR inconsistent image geometry");
            $finish;
        end
        // F6: a bottom-up image is written row by row in reverse, and the
        // controller only latches the start address of each burst, so a burst
        // must never straddle two bank rows.
        if (IMAGE_WIDTH % EFFECTIVE_BURST != 0) begin
            $display("LOADER_CONFIG_ERROR IMAGE_WIDTH=%0d is not a multiple of the %0d-word burst",
                     IMAGE_WIDTH, EFFECTIVE_BURST);
            $finish;
        end
    end

    reg active;
    reg [1:0] active_image;
    // F6 black pre-fill: pushes zero words through the same FIFO and the same
    // burst pacing as pixels, so the SDRAM write rate is unchanged. The fill
    // walks the identical address sequence a full image would, so the bank is
    // black everywhere a skipped, short or letterboxed image leaves a gap.
    reg fill_phase;
    wire fill_active = (ENABLE_PREFILL != 0) && fill_phase;
    reg commit_seen;
    localparam [W_BITS-1:0] FULL_WIDTH = IMAGE_WIDTH;
    localparam [H_BITS-1:0] FULL_HEIGHT = IMAGE_HEIGHT;
    // F6: counters sized from the geometry they count, not from the 32 bit
    // ports they used to mirror
    localparam integer CNT_BITS = $clog2(IMAGE_WORDS + 1);
    localparam integer STALL_BITS = $clog2(STALL_TIMEOUT + 1);
    reg [CNT_BITS-1:0] pixels_received;
    reg [CNT_BITS-1:0] pixels_written;
    // R7-A3-F1: stream position -> display row (bottom-up remap). The
    // decoder emits display pixels strictly in stream order, one row of
    // eff_width at a time, so the pop side can re-derive the row itself.
    reg [W_BITS-1:0] wr_col;
    reg [H_BITS-1:0] wr_row;
    // Read-only bench views. The counters stop at load_done; after an
    // all-images failure they describe the last attempted bank.
    assign diagnostic_data = diagnostic_select == 3'd1 ?
        {4'hc, {(28-CNT_BITS){1'b0}}, pixels_received} :
        diagnostic_select == 3'd2 ?
        {4'hd, {(28-CNT_BITS){1'b0}}, pixels_written} :
        diagnostic_select == 3'd3 ?
        {4'ha, {(12-H_BITS){1'b0}}, wr_row, 4'd0,
               {(12-W_BITS){1'b0}}, wr_col} :
        {4'hb, {(12-H_BITS){1'b0}}, out_height, 4'd0,
               {(12-W_BITS){1'b0}}, x_end};
    // F6 step 2: rows are always written full width, so every row is a whole
    // number of bursts and rows may be written in any order -- the inherited
    // controller only latches the burst start address. A smaller image is
    // centred by writing black in the margin columns instead of skipping
    // them, which keeps each burst gapless.
    wire placing = (ENABLE_ANY_SIZE != 0) && !fill_active;
    wire [H_BITS-1:0] eff_height = placing ? out_height : FULL_HEIGHT;
    wire [W_BITS-1:0] eff_x_offset = placing ? x_offset : {W_BITS{1'b0}};
    wire [W_BITS-1:0] eff_x_end = placing ? x_end : FULL_WIDTH;
    wire [H_BITS-1:0] eff_y_offset = placing ? y_offset : {H_BITS{1'b0}};
    wire [H_BITS-1:0] placed_row = top_down ? wr_row : (eff_height-1 - wr_row);
    wire [H_BITS-1:0] disp_row = fill_active ? wr_row :
                                 (eff_y_offset + placed_row);
    // inside the image on this row? margin beats write black and do not
    // touch the FIFO
    wire in_window = !placing ||
                     (wr_col >= eff_x_offset && wr_col < eff_x_end);
    // a burst that reaches into the image needs its words queued before it
    // starts, because it must not pause once it has
    wire window_touch = !placing ||
                        (wr_col < eff_x_end &&
                         (wr_col + EFFECTIVE_BURST) > eff_x_offset);
    reg [STALL_BITS-1:0] stall_count;
    // Keep the RAM itself and its synchronous read register out of the
    // asynchronous-reset control process so TD can infer block RAM.
    reg [31:0] fifo_mem [0:FIFO_DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [31:0] fifo_read_data;
    reg fifo_read_valid;
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [PTR_WIDTH:0] fifo_count;
    reg burst_active;
    reg [PTR_WIDTH:0] burst_remaining;
    wire pop_allowed;
    wire write_beat;
    wire push_allowed;
    wire start_burst;
    wire [PTR_WIDTH:0] next_burst_words;

    assign load_busy = active;
    // All IMAGE_WORDS zero words have been queued; what is left in the FIFO
    // may be a partial burst, so the tail is flushed like a commit.
    wire fill_push_done = fill_active && pixels_received == IMAGE_WORDS;
    wire fill_drained = fill_push_done && fifo_count == 0 && !burst_active;
    // The inherited controller consumes a continuous App_wr_en burst and
    // handles busy/refresh internally. Those status outputs are not per-word
    // ready signals and must not split an active write burst.
    // rows still owed to the bank (placing), or words still queued (V7 path
    // and the pre-fill)
    wire burst_has_work = placing ? (wr_row != eff_height) : (fifo_count != 0);
    assign start_burst = active && controller_init_done && !burst_active &&
                         burst_has_work &&
                         (!window_touch || fifo_count >= EFFECTIVE_BURST ||
                          commit_seen || fill_push_done);
    assign next_burst_words = (placing || fifo_count >= EFFECTIVE_BURST) ?
                              EFFECTIVE_BURST : fifo_count;
    // one gapless beat per burst word; only image columns consume the FIFO
    // controller_init_done also carries the bridge's burst-admission credit.
    // Once started, finish the burst using its reserved FIFO headroom.
    assign write_beat = active && burst_active &&
                        (!in_window || fifo_count != 0);
    assign pop_allowed = write_beat && in_window;
    // During the fill the producer is this module itself and has no deadline,
    // so a full FIFO just stalls it; only a real pixel arriving with no room
    // is an overflow.
    wire push_req = fill_active ? !fill_push_done : pixel_valid;
    assign push_allowed = active && push_req &&
                          (fifo_count < FIFO_DEPTH || pop_allowed);
    assign pixels_ready = active && !fill_active;

    // A pixel during the fill means the caller ignored pixels_ready: count it
    // as a pixel-count fault rather than silently dropping it.
    wire pixel_count_error = pixel_valid &&
                             (fill_active || pixels_received >= IMAGE_WORDS);
    wire pixel_room_error = pixel_valid && !fill_active && !push_allowed;
    // No file is streaming during the pre-fill, so decode_error still holds
    // the previous image's code: it must not abort this load.
    wire decode_fault = decode_error != 0 && !fill_active;
    // Exactly the original successful active-cycle branch. Error cycles
    // cannot modify/read FIFO memory even if the raw ready terms are true.
    wire memory_cycle_ok = rst_n && active && !decode_fault &&
                           !pixel_count_error && !pixel_room_error;
    always @(posedge clk) begin
        if (memory_cycle_ok && push_allowed)
            fifo_mem[wr_ptr] <= fill_active ? 32'd0 : {8'h00, pixel_rgb};
        if (memory_cycle_ok && pop_allowed)
            fifo_read_data <= fifo_mem[rd_ptr];
    end
    // Preserve reset-visible zero without asynchronously resetting the RAM
    // output register. A simultaneous same-address read/write is read-first.
    assign app_wr_data = fifo_read_valid ? fifo_read_data : 32'd0;

    function [ADDR_WIDTH-1:0] bank_base;
        input [1:0] index;
        begin
            case (index)
                2'd0: bank_base = BANK0_BASE;
                2'd1: bank_base = BANK1_BASE;
                2'd2: bank_base = BANK2_BASE;
                default: bank_base = BANK3_BASE;
            endcase
        end
    endfunction

    task fail_load;
        input [7:0] code;
        begin
            memory_error <= code;
            active <= 1'b0;
            fill_phase <= 1'b0;
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            active_image <= 2'd0;
            commit_seen <= 1'b0;
            pixels_received <= 0;
            pixels_written <= 0;
            stall_count <= 0;
            wr_ptr <= {PTR_WIDTH{1'b0}};
            rd_ptr <= {PTR_WIDTH{1'b0}};
            fifo_count <= {(PTR_WIDTH+1){1'b0}};
            burst_active <= 1'b0;
            burst_remaining <= 0;
            load_done <= 1'b0;
            image_complete <= 4'd0;
            memory_error <= ERR_NONE;
            app_wr_en <= 1'b0;
            app_wr_addr <= {ADDR_WIDTH{1'b0}};
            app_wr_mask <= 4'b0000;
            fifo_read_valid <= 1'b0;
            fill_phase <= 1'b0;
        end else begin
            load_done <= 1'b0;
            app_wr_en <= 1'b0;

            if (load_start && !active) begin
                active <= 1'b1;
                active_image <= image_index;
                fill_phase <= (ENABLE_PREFILL != 0);
                commit_seen <= 1'b0;
                pixels_received <= 0;
                pixels_written <= 0;
                wr_col <= 0;              // R7-A3-F1 stream row/col tracking
                wr_row <= 0;
                stall_count <= 0;
                wr_ptr <= {PTR_WIDTH{1'b0}};
                rd_ptr <= {PTR_WIDTH{1'b0}};
                fifo_count <= {(PTR_WIDTH+1){1'b0}};
                burst_active <= 1'b0;
                burst_remaining <= 0;
                memory_error <= ERR_NONE;
                case (image_index)
                    2'd0: image_complete[0] <= 1'b0;
                    2'd1: image_complete[1] <= 1'b0;
                    2'd2: image_complete[2] <= 1'b0;
                    default: image_complete[3] <= 1'b0;
                endcase
            end

            if (active) begin
                if (decode_fault) begin
                    fail_load(ERR_DECODE);
                end else if (pixel_count_error) begin
                    fail_load(ERR_PIXEL_COUNT);
                end else if (pixel_room_error) begin
                    fail_load(ERR_FIFO_OVERFLOW);
                end else begin
                    if (start_burst) begin
                        burst_active <= 1'b1;
                        burst_remaining <= next_burst_words;
                    end

                    if (push_allowed) begin
                        wr_ptr <= wr_ptr + 1'b1;
                        pixels_received <= pixels_received + 1'b1;
                    end

                    if (write_beat) begin
                        app_wr_en <= 1'b1;
                        // R7-A3-F1: the SDRAM row is the DISPLAY row, not
                        // the stream row -- a bottom-up BMP streams its
                        // bottom display row first. The decoder knows the
                        // orientation; the pop side re-derives the row from
                        // the stream position (640 px per display row in
                        // both scale paths, since the decoder decimates 2x
                        // sources before this point).
                        // F6 step 2: eff_x_offset centres a smaller image in
                        // the bank; the pre-filled black is what shows in the
                        // margin.
                        app_wr_addr <= bank_base(active_image) +
                                       (disp_row * IMAGE_WIDTH) + wr_col;
                        // margin beats publish zero instead of a FIFO word
                        fifo_read_valid <= in_window;
                        app_wr_mask <= 4'b0000;
                        if (in_window) begin
                            rd_ptr <= rd_ptr + 1'b1;
                            pixels_written <= pixels_written + 1'b1;
                        end
                        if (wr_col == FULL_WIDTH-1) begin
                            wr_col <= 0;
                            wr_row <= wr_row + 1'b1;
                        end else begin
                            wr_col <= wr_col + 1'b1;
                        end
                        stall_count <= 0;
                        if (burst_remaining == 1) begin
                            burst_active <= 1'b0;
                            burst_remaining <= 0;
                        end else begin
                            burst_remaining <= burst_remaining - 1'b1;
                        end
                    end else if (burst_active ||
                                 (fifo_count != 0 &&
                                  (commit_seen || fill_push_done ||
                                   fifo_count >= EFFECTIVE_BURST))) begin
                        if (stall_count == STALL_TIMEOUT)
                            fail_load(ERR_WRITE_STALL);
                        else
                            stall_count <= stall_count + 1'b1;
                    end else begin
                        stall_count <= 0;
                    end

                    case ({push_allowed, pop_allowed})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: fifo_count <= fifo_count;
                    endcase

                    // F6: the last fill word has reached the controller, so the
                    // bank is black. Restart the counters for the real image;
                    // pixels_ready goes high in the same cycle.
                    if (fill_drained) begin
                        fill_phase <= 1'b0;
                        pixels_received <= 0;
                        pixels_written <= 0;
                        wr_col <= 0;
                        wr_row <= 0;
                        stall_count <= 0;
                    end

                    if (frame_commit)
                        commit_seen <= 1'b1;

                    if (commit_seen && !fill_active && fifo_count == 0 &&
                        !pop_allowed && !burst_active) begin
                        // F6 step 2: a placed image is complete when the pop
                        // side has walked eff_height whole rows -- the same
                        // test as the old word count, without a product.
                        if (wr_row != eff_height || wr_col != 0 ||
                            pixels_received != pixels_written) begin
                            fail_load(ERR_SHORT_FRAME);
                        end else begin
                            case (active_image)
                                2'd0: image_complete[0] <= 1'b1;
                                2'd1: image_complete[1] <= 1'b1;
                                2'd2: image_complete[2] <= 1'b1;
                                default: image_complete[3] <= 1'b1;
                            endcase
                            active <= 1'b0;
                            load_done <= 1'b1;
                        end
                    end
                end
            end else if (pixel_valid) begin
                memory_error <= ERR_NOT_ACTIVE;
            end
        end
    end
endmodule
