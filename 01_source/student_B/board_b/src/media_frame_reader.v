`timescale 1ns/1ps

module media_frame_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 8,
    parameter integer BURST_SIZE = 128,
    parameter integer BURST_GAP_CYCLES = 12,
    parameter integer MAX_INFLIGHT_BURSTS = 2,
    parameter integer DIAG_RETURN_PATTERN = 0,
    parameter integer DIAG_SYNTH_STREAM = 0,
    // V8 push-slide: 1 adds the two-segment frame read (old bank rows
    // followed by new bank rows, or the reverse) and delays the per-frame
    // request capture by one pixel clock so the transition FSM can publish
    // the slide offset decided on the commit edge. 0 keeps V7 bit-exact.
    parameter integer ENABLE_SLIDE = 0,
    parameter integer IMAGE_WIDTH = 640
) (
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,

    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  frame_start,
    input  wire [1:0]            active_index,
    // slide request, pixel domain, stable from one cycle after frame_start
    input  wire                  slide_active,
    input  wire [1:0]            slide_old_index,
    input  wire [8:0]            slide_rows,     // rows of the incoming image
    input  wire                  slide_dir,      // 0: new enters from the bottom
    input  wire                  pixel_consume,
    output wire [23:0]           pixel_rgb,
    output wire                  pixel_valid,
    output reg                   underflow,

    output reg                   reader_busy,
    output reg                   frame_read_done,
    output reg  [1:0]            reader_index,
    output reg  [7:0]            reader_error
);
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FRAME_OVERRUN = 8'h61;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h62;
    localparam [7:0] ERR_UNDERFLOW     = 8'h63;
    localparam [7:0] ERR_SHORT_FRAME   = 8'h64;
    localparam integer FIFO_COUNT_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam integer BURST_COUNT_W =
        (BURST_SIZE < 2) ? 1 : $clog2(BURST_SIZE + 1);
    localparam integer INFLIGHT_COUNT_W =
        (MAX_INFLIGHT_BURSTS * BURST_SIZE < 2) ? 1 :
        $clog2(MAX_INFLIGHT_BURSTS * BURST_SIZE + 1);

    reg request_pending_pix;
    reg request_toggle_pix;
    reg [1:0] request_index_pix;
    reg request_delay_pix;
    reg [12:0] request_slide_pix;           // {active, dir, old[1:0], rows[8:0]}
    reg frame_armed_pix;
    reg [ADDR_WIDTH:0] consumed_count_pix;

    reg request_sync1_mem;
    reg request_sync2_mem;
    reg request_seen_mem;
    reg [1:0] index_sync1_mem;
    reg [1:0] index_sync2_mem;
    reg reload_pending_mem;
    reg reload_settle_mem;
    reg [1:0] reload_index_mem;
    reg [12:0] slide_sync1_mem;
    reg [12:0] slide_sync2_mem;
    reg [12:0] reload_slide_mem;
    reg [ADDR_WIDTH-1:0] reload_off_mem;    // rows * IMAGE_WIDTH
    // Frame read in up to two linear segments. The first word of the frame
    // is read from cur_base_mem + 0; after word split_m1 the base switches to
    // segb_adj_mem, which is pre-biased by -split so the issued counter needs
    // no subtraction. A plain frame never matches split_m1 (all ones).
    reg [ADDR_WIDTH-1:0] cur_base_mem;
    reg [ADDR_WIDTH-1:0] segb_adj_mem;
    reg [ADDR_WIDTH:0]   split_m1_mem;
    reg [2:0] fifo_reset_count_mem;
    reg [ADDR_WIDTH:0] issued_count_mem;
    reg [ADDR_WIDTH:0] returned_count_mem;
    reg [INFLIGHT_COUNT_W-1:0] inflight_count_mem;
    reg inflight_empty_mem /* fehdl keep="true" */;
    reg burst_active_mem;
    reg [BURST_COUNT_W-1:0] burst_issued_mem;
    reg [BURST_COUNT_W-1:0] burst_target_mem;
    reg [7:0] burst_gap_count_mem;
    reg [ADDR_WIDTH:0] diag_written_count_mem;
    reg [9:0] diag_column_mem;
    reg [23:0] diag_rgb_mem;
    reg [1:0] fifo_release_mem;
    reg [1:0] fifo_release_pix;

    wire fifo_reset_request = !mem_rst_n || !pix_rst_n ||
                              (fifo_reset_count_mem != 0);
    wire fifo_reset = fifo_reset_request ||
                      !fifo_release_mem[1] || !fifo_release_pix[1];
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire [FIFO_COUNT_W-1:0] fifo_wrusedw;
    wire [31:0] fifo_raw_data;
    wire fifo_raw_valid;
    wire fifo_raw_read_en;
    wire prefetch_valid;
    wire [31:0] prefetch_data;
    wire pixel_pop = pixel_consume && prefetch_valid;
    wire [ADDR_WIDTH:0] inflight_words =
        {{(ADDR_WIDTH+1-INFLIGHT_COUNT_W){1'b0}}, inflight_count_mem};
    wire final_return = returned_count_mem == IMAGE_WORDS - 1;
    wire [ADDR_WIDTH+1:0] reserved_words =
        {{(ADDR_WIDTH+2-FIFO_COUNT_W){1'b0}}, fifo_wrusedw} +
        {{1{1'b0}}, inflight_words};
    localparam integer FULL_BURSTS_ONLY = (IMAGE_WORDS % BURST_SIZE) == 0;
    wire [ADDR_WIDTH:0] remaining_words = IMAGE_WORDS - issued_count_mem;
    wire [ADDR_WIDTH:0] next_burst_words =
        FULL_BURSTS_ONLY ? BURST_SIZE :
        ((remaining_words > BURST_SIZE) ? BURST_SIZE : remaining_words);
    wire [ADDR_WIDTH+2:0] reserved_after_burst =
        {{1{1'b0}}, reserved_words} + {{2{1'b0}}, next_burst_words};
    wire inflight_window_ok = (MAX_INFLIGHT_BURSTS == 1) ?
        inflight_empty_mem :
        ((inflight_words + next_burst_words) <=
         (MAX_INFLIGHT_BURSTS * BURST_SIZE));
    wire fifo_reservation_ok =
        reserved_after_burst <= (FIFO_DEPTH - FIFO_MARGIN);
    reg inflight_window_ok_q;
    reg fifo_reservation_ok_q;
    wire start_burst = !DIAG_SYNTH_STREAM && reader_busy && controller_init_done &&
                       fifo_reset_count_mem == 0 && !burst_active_mem &&
                       burst_gap_count_mem == 0 &&
                       issued_count_mem != IMAGE_WORDS &&
                       inflight_window_ok_q && fifo_reservation_ok_q;
    wire issue_allowed = !DIAG_SYNTH_STREAM && reader_busy && burst_active_mem;
    wire diag_stream_write = DIAG_SYNTH_STREAM && reader_busy &&
                             !fifo_reset && !fifo_full;
    wire fifo_write_enable = DIAG_SYNTH_STREAM ? diag_stream_write :
                             (sdram_rd_valid && !fifo_reset && !fifo_full);
    wire [31:0] fifo_write_data = (DIAG_RETURN_PATTERN || DIAG_SYNTH_STREAM) ?
                                  {8'h00, diag_rgb_mem} : sdram_rd_data;

    always @* begin
        if (diag_column_mem < 10'd80)
            diag_rgb_mem = 24'hffffff;
        else if (diag_column_mem < 10'd160)
            diag_rgb_mem = 24'hffff00;
        else if (diag_column_mem < 10'd240)
            diag_rgb_mem = 24'h00ffff;
        else if (diag_column_mem < 10'd320)
            diag_rgb_mem = 24'h00ff00;
        else if (diag_column_mem < 10'd400)
            diag_rgb_mem = 24'hff00ff;
        else if (diag_column_mem < 10'd480)
            diag_rgb_mem = 24'hff0000;
        else if (diag_column_mem < 10'd560)
            diag_rgb_mem = 24'h0000ff;
        else
            diag_rgb_mem = 24'h000000;
    end

    function [ADDR_WIDTH-1:0] bank_base;
        input [1:0] index;
        begin
            case (index)
                2'd0: bank_base = {ADDR_WIDTH{1'b0}};
                2'd1: bank_base = IMAGE_WORDS;
                2'd2: bank_base = IMAGE_WORDS * 2;
                default: bank_base = IMAGE_WORDS * 3;
            endcase
        end
    endfunction

    // Delay the request by one pixel clock so media_player_control can commit
    // active_index on the frame_start edge before this module captures it.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_pending_pix <= 1'b0;
            request_toggle_pix <= 1'b0;
            request_index_pix <= 2'd0;
            request_delay_pix <= 1'b0;
            request_slide_pix <= 13'd0;
            frame_armed_pix <= 1'b0;
            consumed_count_pix <= 0;
            underflow <= 1'b0;
            fifo_release_pix <= 2'b00;
        end else begin
            if (fifo_reset_request)
                fifo_release_pix <= 2'b00;
            else
                fifo_release_pix <= {fifo_release_pix[0], 1'b1};

            if (frame_start) begin
                if (frame_armed_pix && consumed_count_pix != IMAGE_WORDS) begin
                    underflow <= 1'b1;
                end
                consumed_count_pix <= 0;
                request_pending_pix <= 1'b1;
            end else if (request_pending_pix) begin
                if (ENABLE_SLIDE != 0 && !request_delay_pix) begin
                    request_delay_pix <= 1'b1;
                end else begin
                    request_index_pix <= active_index;
                    request_slide_pix <= (ENABLE_SLIDE != 0) ?
                        {slide_active, slide_dir, slide_old_index, slide_rows} : 13'd0;
                    request_toggle_pix <= ~request_toggle_pix;
                    request_pending_pix <= 1'b0;
                    request_delay_pix <= 1'b0;
                    frame_armed_pix <= 1'b1;
                end
            end

            if (pixel_consume) begin
                if (prefetch_valid)
                    consumed_count_pix <= consumed_count_pix + 1'b1;
                else if (frame_armed_pix)
                    underflow <= 1'b1;
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            request_sync1_mem <= 1'b0;
            request_sync2_mem <= 1'b0;
            request_seen_mem <= 1'b0;
            index_sync1_mem <= 2'd0;
            index_sync2_mem <= 2'd0;
            reload_pending_mem <= 1'b0;
            reload_settle_mem <= 1'b1;
            reload_index_mem <= 2'd0;
            slide_sync1_mem <= 13'd0;
            slide_sync2_mem <= 13'd0;
            reload_slide_mem <= 13'd0;
            reload_off_mem <= {ADDR_WIDTH{1'b0}};
            cur_base_mem <= {ADDR_WIDTH{1'b0}};
            segb_adj_mem <= {ADDR_WIDTH{1'b0}};
            split_m1_mem <= {(ADDR_WIDTH+1){1'b1}};
            fifo_reset_count_mem <= 3'd0;
            issued_count_mem <= 0;
            returned_count_mem <= 0;
            inflight_count_mem <= 0;
            inflight_empty_mem <= 1'b1;
            burst_active_mem <= 1'b0;
            burst_issued_mem <= 0;
            burst_target_mem <= 0;
            burst_gap_count_mem <= 0;
            diag_written_count_mem <= 0;
            diag_column_mem <= 0;
            fifo_release_mem <= 2'b00;
            inflight_window_ok_q <= 1'b1;
            fifo_reservation_ok_q <= 1'b1;
            app_rd_en <= 1'b0;
            app_rd_addr <= 0;
            reader_busy <= 1'b0;
            frame_read_done <= 1'b0;
            reader_index <= 2'd0;
            reader_error <= ERR_NONE;
        end else begin
            if (fifo_reset_request)
                fifo_release_mem <= 2'b00;
            else
                fifo_release_mem <= {fifo_release_mem[0], 1'b1};

            request_sync1_mem <= request_toggle_pix;
            request_sync2_mem <= request_sync1_mem;
            index_sync1_mem <= request_index_pix;
            index_sync2_mem <= index_sync1_mem;
            slide_sync1_mem <= request_slide_pix;
            slide_sync2_mem <= slide_sync1_mem;
            app_rd_en <= 1'b0;
            frame_read_done <= 1'b0;
            inflight_window_ok_q <= inflight_window_ok;
            fifo_reservation_ok_q <= fifo_reservation_ok;

            if (fifo_reset_count_mem != 0)
                fifo_reset_count_mem <= fifo_reset_count_mem - 1'b1;
            if (burst_gap_count_mem != 0)
                burst_gap_count_mem <= burst_gap_count_mem - 1'b1;

            case ({issue_allowed, sdram_rd_valid})
                2'b10: begin
                    inflight_count_mem <= inflight_count_mem + 1'b1;
                    inflight_empty_mem <= 1'b0;
                end
                2'b01: begin
                    if (!inflight_empty_mem) begin
                        inflight_count_mem <= inflight_count_mem - 1'b1;
                        if (inflight_count_mem == 1)
                            inflight_empty_mem <= 1'b1;
                    end
                end
                default: begin
                    inflight_count_mem <= inflight_count_mem;
                    inflight_empty_mem <= inflight_empty_mem;
                end
            endcase

            // audit hardening: same multi-bit CDC skew guard as
            // media_player_control -- request_index_pix rides its own 2FF
            // chain, so reload_index_mem is sampled one cycle AFTER the
            // toggle detect (request_index_pix is stable for a whole frame).
            if (request_sync2_mem != request_seen_mem) begin
                request_seen_mem <= request_sync2_mem;
                reload_pending_mem <= 1'b1;
                reload_settle_mem <= 1'b0;
                if (reader_busy || !inflight_empty_mem) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    // clear the counters too: the abandoned frame's inflight
                    // tail must not be able to trip final_return (the reload
                    // below re-clears them anyway)
                    issued_count_mem <= 0;
                    returned_count_mem <= 0;
                    reader_error <= ERR_FRAME_OVERRUN;
                end
            end else if (reload_pending_mem && !reload_settle_mem) begin
                reload_settle_mem <= 1'b1;
                reload_index_mem <= index_sync2_mem;
                // same settle rule as the index: the slide bus rode its own
                // 2FF chain and is stable for the whole frame
                reload_slide_mem <= slide_sync2_mem;
                // 640 = 512 + 128 as shift-add, so the slide costs no DSP
                reload_off_mem <= (IMAGE_WIDTH == 640) ?
                    ({slide_sync2_mem[8:0], 9'd0} + {slide_sync2_mem[8:0], 7'd0}) :
                    slide_sync2_mem[8:0] * IMAGE_WIDTH;
            end

            if (reload_pending_mem && reload_settle_mem && inflight_empty_mem) begin
                reload_pending_mem <= 1'b0;
                reader_index <= reload_index_mem;
                if (!reload_slide_mem[12] || reload_slide_mem[8:0] == 9'd0) begin
                    cur_base_mem <= bank_base(reload_slide_mem[12] ?
                                              reload_slide_mem[10:9] : reload_index_mem);
                    split_m1_mem <= {(ADDR_WIDTH+1){1'b1}};
                end else if (!reload_slide_mem[11]) begin
                    // push up: old rows [k,H) on top, then new rows [0,k)
                    cur_base_mem <= bank_base(reload_slide_mem[10:9]) + reload_off_mem;
                    segb_adj_mem <= bank_base(reload_index_mem) - IMAGE_WORDS + reload_off_mem;
                    split_m1_mem <= IMAGE_WORDS - 1 - reload_off_mem;
                end else begin
                    // push down: new rows [H-k,H) on top, then old rows [0,H-k)
                    cur_base_mem <= bank_base(reload_index_mem) + IMAGE_WORDS - reload_off_mem;
                    segb_adj_mem <= bank_base(reload_slide_mem[10:9]) - reload_off_mem;
                    split_m1_mem <= reload_off_mem - 1'b1;
                end
                issued_count_mem <= 0;
                returned_count_mem <= 0;
                inflight_count_mem <= 0;
                inflight_empty_mem <= 1'b1;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                diag_written_count_mem <= 0;
                diag_column_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                reader_busy <= 1'b1;
                reader_error <= ERR_NONE;
            end

            if (start_burst) begin
                burst_active_mem <= 1'b1;
                burst_issued_mem <= 0;
                burst_target_mem <= next_burst_words[BURST_COUNT_W-1:0];
            end

            if (issue_allowed) begin
                app_rd_en <= 1'b1;
                app_rd_addr <= cur_base_mem + issued_count_mem[ADDR_WIDTH-1:0];
                if (issued_count_mem == split_m1_mem)
                    cur_base_mem <= segb_adj_mem;
                issued_count_mem <= issued_count_mem + 1'b1;
                burst_issued_mem <= burst_issued_mem + 1'b1;
                if (burst_issued_mem + 1'b1 == burst_target_mem) begin
                    burst_active_mem <= 1'b0;
                    burst_gap_count_mem <= BURST_GAP_CYCLES;
                end
            end

            if (!DIAG_SYNTH_STREAM && sdram_rd_valid) begin
                returned_count_mem <= returned_count_mem + 1'b1;
                if (fifo_full) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FIFO_OVERFLOW;
                end else if (final_return) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end

            if (DIAG_SYNTH_STREAM && diag_stream_write) begin
                diag_written_count_mem <= diag_written_count_mem + 1'b1;
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
                if (diag_written_count_mem == IMAGE_WORDS - 1) begin
                    reader_busy <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end else if (!DIAG_SYNTH_STREAM && DIAG_RETURN_PATTERN &&
                         sdram_rd_valid) begin
                diag_column_mem <= (diag_column_mem == 10'd639) ?
                                   10'd0 : diag_column_mem + 1'b1;
            end
        end
    end

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(FIFO_COUNT_W), .ADDR_WIDTH_R(FIFO_COUNT_W),
        .AL_FULL_NUM(FIFO_DEPTH-FIFO_MARGIN), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_read_fifo (
        .rst(fifo_reset), .clkw(mem_clk), .clkr(pix_clk),
        .we(fifo_write_enable), .di(fifo_write_data),
        .re(fifo_raw_read_en), .dout(fifo_raw_data), .valid(fifo_raw_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_almost_full), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw()
    );

    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(pix_clk), .rst(fifo_reset), .raw_empty(fifo_empty),
        .raw_valid(fifo_raw_valid), .raw_data(fifo_raw_data),
        .raw_read_en(fifo_raw_read_en), .consume(pixel_pop),
        .out_valid(prefetch_valid), .out_empty(), .out_data(prefetch_data)
    );

    assign pixel_rgb = prefetch_data[23:0];
    assign pixel_valid = prefetch_valid;

    // NOTE: `underflow` is INTENTIONALLY sticky (cleared only by reset):
    // it latches a real display fault for the operator's 0x63 readout, and
    // the pressure negative-tests (tb_media_frame_reader_pressure,
    // retrospectives R37/R41) use the sticky flag as their acceptance
    // criterion. Do not auto-clear it. (audit: empty always block removed)

endmodule
