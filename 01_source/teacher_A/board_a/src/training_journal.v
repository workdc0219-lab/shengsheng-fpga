`timescale 1ns/1ps
// Training-record journal on the on-board U33 data flash (W25Q64), docs/14 s5.
// Every accepted scoring result (res_new) appends one 16-byte record; at
// power-on the last records are read back and fed to the teacher console's
// progress bars oldest-first.
//
// Storage shape (w25q64_record_store erases a 4 KB sector before each write
// and verifies it by read-back): ONE record per 4 KB sector, NSLOT sectors
// in a round-robin ring. The 128 KB window sits directly below the
// single-board journal slots (0x7FE000/0x7FF000) at the top of the 8 MB
// data flash, and no command the store issues can touch anything outside
// [WIN_BASE, WIN_LIMIT): sector erase (0x20) + page program (0x02) +
// read (0x03) at checked addresses only, no chip/block erase, no
// status-register write.
//
// Record (16 B, byte 0 first on the SPI wire):
//   r0 8'hA5 magic           r1 seq (1..255, wraps skipping 0)
//   r2 {short, score[6:0]}   r3 {stars, target, tone}
//   r4 {mode, q_idx, tch_used, teacher_on, 0}
//   r5..r6 0                 r7 checksum = ~(sum of the other 15 bytes)
//   r8..r15 child 16-pt shape, 4 b/point: shape[k][7:4], two points per byte
// seq advances by +1 per record (255 -> 1). Boot validates the modulo-255
// half-range order, then replays EVERY valid survivor oldest-first; gaps
// never terminate replay. Duplicate/ambiguous sequence sets inhibit writes
// and latch journal_error instead of guessing which flash sector to erase.
module training_journal #(
    parameter [23:0] WIN_BASE  = 24'h7DE000,
    parameter [23:0] WIN_LIMIT = 24'h7FE000,
    parameter integer NSLOT = 32,
    // passthrough for simulation (real part polls the flash every 200 us)
    parameter integer POLL_INTERVAL_CYCLES = 5000
) (
    input  wire         clk,
    input  wire         rst_n,
    // scoring results (docs/14 s3 return packet)
    input  wire         res_new,
    input  wire         res_short,
    input  wire [6:0]   res_score,
    input  wire [1:0]   res_stars,
    input  wire [2:0]   res_target,
    input  wire [2:0]   res_tone,
    input  wire [2:0]   b_mode,
    input  wire [1:0]   b_q,
    input  wire         b_tch_used,
    input  wire         b_teacher_on,
    input  wire [127:0] res_shape,
    // console progress history, oldest first, 2 clocks between pulses
    output reg          hist_load,
    output reg  [6:0]   hist_score,
    output reg  [1:0]   hist_stars,
    output reg          hist_short,
    output reg          hist_ready,      // power-on load finished
    output reg          journal_error,   // sticky: a flash op failed
    output reg  [1:0]   journal_error_kind, // sticky first fault: 1=boot read, 2=write/queue, 3=ordering
    // SPI flash
    output wire         spi_cs_n,
    output wire         spi_sclk,
    output wire         spi_mosi,
    input  wire         spi_miso,
    output wire         spi_wp_n,
    output wire         spi_hold_n
);
    localparam [4:0] ST_BOOT=0, ST_LOAD=1, ST_LOAD_WAIT=2,
        ST_ORDER=3, ST_CANDIDATE=4, ST_COMPARE=5, ST_CANDIDATE_DONE=6,
        ST_VALIDATE=7, ST_REPLAY_INIT=8, ST_REPLAY_SCAN=9, ST_FEED=10,
        ST_FEED_GAP=11, ST_IDLE=12, ST_WR_LATCH=13, ST_ALLOC_INIT=14,
        ST_ALLOC_SCAN=15, ST_WR_START=16, ST_WR_WAIT=17;

    // slot table: {valid, short, seq[7:0], score[6:0], stars[1:0]}
    //              [18]    [17]   [16:9]     [8:2]       [1:0]
    reg [18:0] tbl [0:NSLOT-1];
    reg [5:0]  slot, scan;
    reg [4:0]  wr_slot, newest_slot, best_slot;
    reg [8:0]  n_valid, fed, age_limit;
    reg [7:0]  last_seq, w_seq, best_age;
    reg [5:0] candidate_count;
    reg candidate_ok, best_found, invalid_found, write_inhibit;
    reg [127:0] w_data;
    reg        pend, pend_short, w_short;
    reg [6:0]  pend_score, w_score;
    reg [1:0]  pend_stars, w_stars;
    reg [2:0]  pend_target, w_target, pend_tone, w_tone;
    reg [2:0]  pend_mode, w_mode;
    reg [1:0]  pend_q, w_q;
    reg        pend_tch, w_tch, pend_ton, w_ton;
    reg [127:0] pend_shape, w_shape;
    reg [4:0]  state;

    initial begin
        if (NSLOT < 1 || NSLOT > 32 ||
            WIN_LIMIT - WIN_BASE < NSLOT * 4096) begin
            $display("JOURNAL_CONFIG_ERROR invalid protected slot window");
            $finish;
        end
    end

    reg         start_op, op_write;
    reg [23:0]  op_addr;
    // store OUTPUTS must be nets (TD HDL-8007: no concurrent assignment
    // to a variable at an instantiation site)
    wire        op_done, op_error, op_busy;
    wire [127:0] rd_data;

    w25q64_record_store #(
        .RECORD_BYTES  (16),
        .CLK_DIV       (2),
        .ALLOWED_BASE  (WIN_BASE),
        .ALLOWED_LIMIT (WIN_LIMIT),
        .POLL_INTERVAL_CYCLES (POLL_INTERVAL_CYCLES)
    ) u_store (
        .clk(clk), .rst_n(rst_n),
        .start(start_op), .op_write(op_write), .address(op_addr),
        .write_data(w_data),
        .busy(op_busy), .done(op_done), .error(op_error),
        .error_code(), .read_data(rd_data), .request_dropped(),
        .spi_cs_n(spi_cs_n), .spi_sclk(spi_sclk), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_wp_n(spi_wp_n), .spi_hold_n(spi_hold_n)
    );

    function [7:0] succ;
        input [7:0] s;
        begin succ = (s == 8'hFF) ? 8'd1 : s + 8'd1; end
    endfunction

    // Distance backwards on 1..255 ring. No divider/modulo hardware.
    function [7:0] seq_age;
        input [7:0] newest;
        input [7:0] older;
        reg [8:0] distance;
        begin
            distance = {1'b0,newest} + 9'd255 - {1'b0,older};
            seq_age = (distance >= 9'd255) ? distance - 9'd255 : distance;
        end
    endfunction

    // checksum over the 15 non-r7 bytes. Bytes travel MSB-first: record
    // byte k lives at d[127-8k -: 8], so r7 is the LSB block with ic == 8.
    function [7:0] cksum;
        input [127:0] d;
        integer ic;
        reg [7:0] s;
        begin
            s = 8'd0;
            for (ic = 0; ic < 16; ic = ic + 1)
                if (ic != 8) s = s + d[ic*8 +: 8];
            cksum = s;
        end
    endfunction
    wire [7:0] rd_ck = ~cksum(rd_data);
    wire rd_ok = (rd_data[127:120] == 8'hA5) && (rd_data[119:112] != 8'd0) &&
                 (rd_ck == rd_data[71:64]);

    wire [7:0] compare_age = seq_age(tbl[slot[4:0]][16:9], tbl[scan[4:0]][16:9]);
    wire [7:0] scan_age = seq_age(last_seq, tbl[scan[4:0]][16:9]);
    // Diagnostic-only classification mirrors the existing error conditions.
    // It does not alter admission, allocation, SPI operations or records.
    // If faults coincide, boot-read/order precede queue/write; later faults
    // never overwrite the first nonzero class until reset.
    wire boot_read_error_event = state == ST_LOAD_WAIT && op_done && op_error;
    wire order_error_event =
        (state == ST_COMPARE && tbl[slot[4:0]][18] && tbl[scan[4:0]][18] &&
         scan != slot && compare_age == 0) ||
        (state == ST_VALIDATE && (candidate_count != 1 || write_inhibit));
    wire write_error_event = (state == ST_WR_WAIT && op_done && op_error) ||
                            (res_new && pend && state != ST_WR_LATCH);

    // child shape, 4 b/point: shape[k][7:4], two points per byte, byte 0
    // (points 1..0) first on the wire; shifts only, no variable-index writes
    function [63:0] nib_pack;
        input [127:0] shape;
        integer k;
        reg [63:0] acc;
        begin
            acc = 64'd0;
            for (k = 7; k >= 0; k = k - 1)
                acc = {acc[55:0], shape[((2*k+1)*8) + 7 -: 4],
                       shape[(2*k)*8 + 7 -: 4]};
            nib_pack = acc;
        end
    endfunction

    // record assembly: one single assignment (TD flags a re-assigned
    // part-select inside a comb block as a multiple driver, HDL-8007);
    // the checksum covers every byte except r7, so r7 is written last
    reg [127:0] w_body;
    always @* begin
        w_body = {8'hA5, w_seq, w_short, w_score,
                  w_stars, w_target, w_tone,
                  w_mode, w_q, w_tch, w_ton, 1'b0,
                  16'd0, 8'h00, nib_pack(w_shape)};
        w_data = {w_body[127:72], ~cksum(w_body), w_body[63:0]};
    end

    integer ir;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_BOOT; slot <= 6'd0; scan <= 6'd0;
            wr_slot <= 0; newest_slot <= 0; best_slot <= 0;
            n_valid <= 0; fed <= 0; last_seq <= 0; w_seq <= 0;
            age_limit <= 9'd256; best_age <= 0; candidate_count <= 0;
            candidate_ok <= 0; best_found <= 0; invalid_found <= 0;
            write_inhibit <= 0;
            hist_load <= 1'b0; hist_score <= 7'd0; hist_stars <= 2'd0;
            hist_short <= 1'b0; hist_ready <= 1'b0; journal_error <= 1'b0;
            journal_error_kind <= 2'd0;
            start_op <= 1'b0; op_write <= 1'b0; op_addr <= 24'd0;
            pend <= 1'b0; pend_short <= 1'b0; pend_score <= 7'd0;
            pend_stars <= 2'd0; pend_target <= 3'd0; pend_tone <= 3'd0;
            pend_mode <= 3'd0; pend_q <= 2'd0; pend_tch <= 1'b0;
            pend_ton <= 1'b0; pend_shape <= 128'd0;
            w_short <= 1'b0; w_score <= 7'd0; w_stars <= 2'd0;
            w_target <= 3'd0; w_tone <= 3'd0; w_mode <= 3'd0; w_q <= 2'd0;
            w_tch <= 1'b0; w_ton <= 1'b0; w_shape <= 128'd0;
            for (ir = 0; ir < NSLOT; ir = ir + 1) tbl[ir] <= 19'd0;
        end else begin
            start_op  <= 1'b0;
            hist_load <= 1'b0;
            if (journal_error_kind == 2'd0) begin
                if (boot_read_error_event) journal_error_kind <= 2'd1;
                else if (order_error_event) journal_error_kind <= 2'd3;
                else if (write_error_event) journal_error_kind <= 2'd2;
            end
            case (state)
            // ------------------------------------------------ power-on load
            ST_BOOT: begin
                slot <= 6'd0; n_valid <= 9'd0;
                state <= ST_LOAD;
            end
            ST_LOAD: begin
                op_addr  <= WIN_BASE + {slot[4:0], 12'd0};
                op_write <= 1'b0;
                start_op <= 1'b1;
                state    <= ST_LOAD_WAIT;
            end
            ST_LOAD_WAIT: if (op_done) begin
                if (!op_error && rd_ok) begin
                    tbl[slot[4:0]] <= {1'b1, rd_data[111], rd_data[119:112],
                                       rd_data[110:104], rd_data[103:102]};
                    n_valid <= n_valid + 1'b1;
                end else begin
                    tbl[slot[4:0]] <= 19'd0;
                    if (op_error) begin
                        journal_error <= 1'b1;
                        write_inhibit <= 1'b1;
                    end
                end
                if (slot == NSLOT - 1) begin
                    state <= ST_ORDER;
                end else begin
                    slot  <= slot + 1'b1;
                    state <= ST_LOAD;
                end
            end
            // ------------------------------------- order by seq and feed
            ST_ORDER: begin
                fed <= 9'd0;
                if (n_valid == 9'd0) begin
                    hist_ready <= 1'b1;
                    state      <= ST_IDLE;
                end else begin
                    slot <= 0;
                    candidate_count <= 0;
                    state <= ST_CANDIDATE;
                end
            end
            // A valid newest candidate has all other records in its preceding
            // 127 sequence positions. Duplicate seq makes ordering unsafe.
            ST_CANDIDATE: begin
                candidate_ok <= tbl[slot[4:0]][18];
                scan <= 0;
                state <= ST_COMPARE;
            end
            ST_COMPARE: begin
                if (tbl[scan[4:0]][18] && scan != slot &&
                    (compare_age == 0 || compare_age > 8'd127))
                    candidate_ok <= 1'b0;
                if (tbl[slot[4:0]][18] && tbl[scan[4:0]][18] &&
                    scan != slot && compare_age == 0) begin
                    journal_error <= 1'b1;
                    write_inhibit <= 1'b1;
                end
                if (scan == NSLOT-1) state <= ST_CANDIDATE_DONE;
                else scan <= scan + 1'b1;
            end
            ST_CANDIDATE_DONE: begin
                if (candidate_ok) begin
                    candidate_count <= candidate_count + 1'b1;
                    newest_slot <= slot[4:0];
                end
                if (slot == NSLOT-1) state <= ST_VALIDATE;
                else begin slot <= slot + 1'b1; state <= ST_CANDIDATE; end
            end
            ST_VALIDATE: begin
                if (candidate_count != 1 || write_inhibit) begin
                    journal_error <= 1'b1;
                    write_inhibit <= 1'b1;
                    hist_ready <= 1'b1;
                    state <= ST_IDLE;
                end else begin
                    last_seq <= tbl[newest_slot][16:9];
                    age_limit <= 9'd256;
                    state <= ST_REPLAY_INIT;
                end
            end
            ST_REPLAY_INIT: begin
                scan <= 0; best_found <= 0; best_age <= 0;
                state <= ST_REPLAY_SCAN;
            end
            ST_REPLAY_SCAN: begin
                if (tbl[scan[4:0]][18] && {1'b0,scan_age} < age_limit &&
                    (!best_found || scan_age > best_age)) begin
                    best_found <= 1'b1; best_age <= scan_age;
                    best_slot <= scan[4:0];
                end
                if (scan == NSLOT-1) state <= ST_FEED;
                else scan <= scan + 1'b1;
            end
            ST_FEED: begin
                if (!best_found) begin
                    hist_ready <= 1'b1;
                    state <= ST_IDLE;
                end else if (!res_new) begin     // never fight a live result
                    hist_score <= tbl[best_slot][8:2];
                    hist_stars <= tbl[best_slot][1:0];
                    hist_short <= tbl[best_slot][17];
                    hist_load  <= 1'b1;
                    age_limit <= {1'b0,best_age};
                    fed        <= fed + 1'b1;
                    state      <= ST_FEED_GAP;
                end
            end
            ST_FEED_GAP: begin
                if (fed == n_valid) begin
                    hist_ready <= 1'b1;
                    state <= ST_IDLE;
                end else
                    state <= ST_REPLAY_INIT;
            end
            // ------------------------------------------------------ append
            ST_IDLE: if (pend && !write_inhibit) state <= ST_WR_LATCH;
            ST_WR_LATCH: begin
                w_short <= pend_short; w_score <= pend_score;
                w_stars <= pend_stars; w_target <= pend_target;
                w_tone  <= pend_tone; w_mode <= pend_mode; w_q <= pend_q;
                w_tch   <= pend_tch; w_ton <= pend_ton; w_shape <= pend_shape;
                w_seq   <= (last_seq == 8'd0) ? 8'd1 : succ(last_seq);
                pend    <= 1'b0;
                state   <= ST_ALLOC_INIT;
            end
            ST_ALLOC_INIT: begin
                scan <= 0; invalid_found <= 0; best_found <= 0; best_age <= 0;
                state <= ST_ALLOC_SCAN;
            end
            // Re-evaluate allocation after EVERY append, not just at boot.
            // First known-invalid slot wins; a full ring overwrites oldest.
            ST_ALLOC_SCAN: begin
                if (!tbl[scan[4:0]][18]) begin
                    if (!invalid_found) begin
                        wr_slot <= scan[4:0]; invalid_found <= 1'b1;
                    end
                end else if (!invalid_found && (!best_found || scan_age > best_age)) begin
                    best_found <= 1'b1; best_age <= scan_age; wr_slot <= scan[4:0];
                end
                if (scan == NSLOT-1) state <= ST_WR_START;
                else scan <= scan + 1'b1;
            end
            ST_WR_START: begin
                op_addr  <= WIN_BASE + {wr_slot, 12'd0};
                op_write <= 1'b1;
                start_op <= 1'b1;
                state    <= ST_WR_WAIT;
            end
            ST_WR_WAIT: if (op_done) begin
                if (op_error) begin
                    journal_error <= 1'b1;
                    // Erase/program may have partially changed this sector.
                    // Never retain its pre-write RAM entry as authoritative.
                    tbl[wr_slot] <= 19'd0;
                end else begin
                    last_seq <= w_seq;
                    tbl[wr_slot] <= {1'b1,w_short,w_seq,w_score,w_stars};
                end
                state <= ST_IDLE;
            end
            default: state <= ST_IDLE;
            endcase
            // live result capture; AFTER the case so it wins over pend <= 0
            if (res_new) begin
                if (pend && state != ST_WR_LATCH) journal_error <= 1'b1;
                pend <= 1'b1; pend_short <= res_short; pend_score <= res_score;
                pend_stars <= res_stars; pend_target <= res_target;
                pend_tone <= res_tone; pend_mode <= b_mode; pend_q <= b_q;
                pend_tch <= b_tch_used; pend_ton <= b_teacher_on;
                pend_shape <= res_shape;
            end
        end
    end
endmodule
