`timescale 1ns/1ps
// Badge progress journal (F3) on the on-board U33 data flash (W25Q64) --
// the same data-flash part and pin row the teacher console uses on Board A
// (P8/N8/M9/P7/P9/R9, U33 data vs U39 config, see board_a constraints).
// Board B's v1 image never drove these pins (tied off in the top), so the
// whole part is free. Window [0x7FE000,0x800000): the two 4 KB sectors the
// docs already reserve for B-side persistence (docs/13 S6, single-board
// w25q_persistence slots).
//
// The build gate forced this journal to carry its own flash engine instead
// of the shared w25q64_record_store: the generic store's verify/timeout
// machinery cost ~900 LUT the 90%-full B board does not have (PHY-9009,
// mslices 5181 > 4900). What remains is a 12-byte-frame SPI sequencer
// (1 cmd + 3 addr + 8 payload) built on the shared spi_byte_engine, at
// sys_clk/4 = 12.5 MHz. Erase/program completion = fixed delay sized to
// the W25Q64 datasheet maxima (tSE 400 ms, tPP 3 ms) followed by TWO
// status polls: they cost nothing on the real part (the waits already
// cover the busy time) and keep the simulation model's busy counter
// coherent. No program verify, no WEL readback, no timeout error path:
// every op finishes by construction, even on an absent part (reads return
// garbage that fails validation). A part slower than the datasheet maxima
// simply loses this write, which the checksum on the NEXT boot detects
// and falls back to the other slot.
//
// Storage shape: ONE 8 B record per 4 KB sector, two slots in ping-pong
// (the record shrank from 16 B when the place gate showed the B board over
// the mslice limit -- the 64-bit payload halves the shift register; the
// 4 KB sector is paid either way). Record, byte 0 first on the wire (byte
// k of the 64-bit word is [63-8k -: 8]):
//   r0 8'hBD magic            r1 {1'b0, progress[6:0]}
//   r2..r3 version[15:0], big-endian, +1 per save
//   r4 checksum = ~(r0+r1+r2+r3)
//   r5..r7 0x00 reserved (second guard against a half-programmed page)
//
// Load: both slots are read once at power-on. A record is valid when magic,
// the progress guard bit and the checksum agree AND the reserved bytes are
// all zero; when both slots are valid the newer version wins (modular
// serial compare, the same rule config_journal uses -- consecutive saves
// differ by 1, so a 16-bit version can never misorder in a 2-slot ring).
// A power cut during a save leaves the target's checksum bad, so the
// previous slot still loads: a cut costs the last badge unlock at most.
//
// Save: the game pulses save_req when the progress word grows (it only
// ever grows: badges latch). Requests latch a pending word that is
// COALESCED -- a later request overwrites the pending word, because the
// newest word already includes every earlier unlock. The write goes to
// target_slot (blank part -> slot 0, the config_journal convention); the
// active pointer moves only after the program polls clear.
module badge_journal #(
    parameter [23:0] SLOT0_ADDRESS = 24'h7FE000,
    parameter [23:0] SLOT1_ADDRESS = 24'h7FF000,
    // fixed waits at 50 MHz sys_clk: 400 ms erase, 4 ms program
    parameter [25:0] ERASE_WAIT_CYCLES = 26'd20_000_000,
    parameter [25:0] PROG_WAIT_CYCLES  = 26'd200_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        save_req,       // 1-clk pulse; save_prog stable now
    input  wire [6:0]  save_prog,      // progress word to persist
    output reg         save_done,      // 1-clk: write attempt finished
    output reg         journal_error,  // sticky, always 0 today (see header)
    output reg         prog_valid,     // 1-clk: power-on load finished
    output reg  [6:0]  prog_out,       // persisted word, 0 when none valid
    // SPI flash (dedicated U33 pins); sclk/mosi come from the byte engine
    output reg         flash_cs_n,
    output wire        flash_sclk,
    output wire        flash_mosi,
    input  wire        flash_miso,
    output wire        flash_wp_n,
    output wire        flash_hold_n
);
    initial begin
        if (SLOT0_ADDRESS[11:0] != 12'd0 || SLOT1_ADDRESS[11:0] != 12'd0 ||
            SLOT1_ADDRESS - SLOT0_ADDRESS != 24'h001000 ||
            ERASE_WAIT_CYCLES < 26'd200 || PROG_WAIT_CYCLES < 26'd20) begin
            $display("BADGE_JOURNAL_CONFIG_ERROR slots must be distinct 4 KB sectors; waits must suit sys_clk");
            $finish;
        end
    end

    localparam [2:0] S_IDLE    = 3'd0;   // wait for work / start boot read
    localparam [2:0] S_FRAME   = 3'd1;   // shifting the current frame
    localparam [2:0] S_DECIDE  = 3'd2;   // frame done: next frame / validate
    localparam [2:0] S_EWAIT   = 3'd3;   // fixed sector-erase delay
    localparam [2:0] S_PWAIT   = 3'd4;   // fixed page-program delay
    localparam [2:0] S_CHOOSE  = 3'd5;   // boot: pick the winning slot
    localparam [2:0] S_SAVED   = 3'd6;   // save finished: report done

    localparam [2:0] OP_RD0    = 3'd0;   // 03+addr+16 rx : read slot 0
    localparam [2:0] OP_RD1    = 3'd1;   // same, slot 1
    localparam [2:0] OP_ERASE  = 3'd2;   // 20+addr, 4-byte frame
    localparam [2:0] OP_PROG   = 3'd3;   // 02+addr+16 tx from shift

    reg [2:0]  state;
    reg [2:0]  op_q;
    // frame byte 0: 0 = read 03, 1 = program 02, 2 = erase 20, 3 = WREN 06,
    // 4 = read status 05
    reg [2:0]  cmd_q;
    reg [1:0]  len_q;                    // 0:1 B, 1:4 B, 2:12 B, 3:2 B
    reg [4:0]  byte_idx;
    reg        byte_start, byte_run;
    reg [7:0]  byte_tx;
    wire       byte_busy, byte_done;
    wire [7:0] byte_rx;
    reg [23:0] frame_addr;
    reg        boot_done;
    reg        wr_phase;                 // 0 = erasing, 1 = programming
    reg [1:0]  poll_cnt;                 // fixed 2 status polls after a wait
    // payload register: TX source for OP_PROG, RX accumulator for the reads
    reg [63:0] shift;
    reg [25:0] wait_cnt;

    // the proven byte-level SPI primitive (the same engine the teacher
    // console's w25q64_record_store drives this flash model with; its MISO
    // sampling phase is the one both the model and the real part are
    // validated against -- an inline 4-phase sampler read the model's
    // byte-boundary reload one bit late and corrupted bytes 1 and 4)
    spi_byte_engine #(.CLK_DIV(2)) u_spi (
        .clk(clk), .rst_n(rst_n), .start(byte_start), .tx_byte(byte_tx),
        .miso(flash_miso), .busy(byte_busy), .done(byte_done),
        .rx_byte(byte_rx), .sclk(flash_sclk), .mosi(flash_mosi));
    // journal bookkeeping
    reg        pend, have_rec;
    reg [6:0]  pend_prog, w_prog;
    reg [15:0] w_ver;
    reg [15:0] active_ver;
    reg        active_slot;              // slot holding the newest record
    reg        slot0_v, slot1_v;
    reg [15:0] slot0_ver, slot1_ver;
    reg [6:0]  slot0_prog, slot1_prog;

    assign flash_wp_n   = 1'b1;
    assign flash_hold_n = 1'b1;

    // checksum over record bytes r0..r3 (byte k = [63-8k -: 8])
    function [7:0] cksum;
        input [63:0] d;
        begin
            cksum = ~(d[63:56] + d[55:48] + d[47:40] + d[39:32]);
        end
    endfunction

    // record assembly. The concatenation MUST be 64 bits (32 zero bits:
    // r4-placeholder + r5..r7) -- 56 bits would zero-extend on the LEFT
    // and shift the whole record one byte down the wire (this bug class
    // already bit once at 128 bits).
    reg [63:0] w_body;
    always @* w_body = {8'hBD, 1'b0, w_prog, w_ver, 32'd0};
    wire [7:0]  w_ck = cksum(w_body);   // cksum already returns ~sum

    // readback validation on the RX accumulator after the read. Byte
    // positions: r0=[63:56] r1=[55:48] r2=[47:40] r3=[39:32] r4=[31:24]
    // (checksum) r5..r7=[23:0]. The sum covers r0..r3 and compares against
    // r4 -- the first 8-byte cut summed r0..r2 and compared against r3,
    // which failed every boot read.
    reg [7:0] rd_ck;
    always @* rd_ck = ~(shift[63:56] + shift[55:48] + shift[47:40] + shift[39:32]);
    wire rd_valid = (shift[63:56] == 8'hBD) && !shift[55] &&
                    (shift[23:0] == 24'd0) && (rd_ck == shift[31:24]);

    // newer of two 16-bit versions, modular serial compare (config_journal)
    wire [15:0] vdelta = slot1_ver - slot0_ver;
    wire slot1_newer = slot1_v && (!slot0_v || (vdelta != 16'd0 && !vdelta[15]));

    // the slot this save writes: slot 0 when nothing valid is loaded (the
    // config_journal convention), otherwise the one NOT holding the newest
    wire target_slot = have_rec ? ~active_slot : 1'b0;
    wire [23:0] target_addr = target_slot ? SLOT1_ADDRESS : SLOT0_ADDRESS;

    wire frame_last_byte = (len_q == 2'd0) ? (byte_idx == 5'd0) :
                           (len_q == 2'd1) ? (byte_idx == 5'd3) :
                           (len_q == 2'd2) ? (byte_idx == 5'd11) :
                                             (byte_idx == 5'd1);
    wire data_phase = (len_q == 2'd2) && (byte_idx >= 5'd4);

    reg [7:0] cmd_byte;
    always @* begin
        case (cmd_q)
            3'd0:    cmd_byte = 8'h03;               // read data
            3'd1:    cmd_byte = 8'h02;               // page program
            3'd2:    cmd_byte = 8'h20;               // sector erase
            3'd4:    cmd_byte = 8'h05;               // read status
            default: cmd_byte = 8'h06;               // WREN
        endcase
    end
    reg [7:0] addr_byte;
    always @* begin
        case (byte_idx)
            5'd1:    addr_byte = frame_addr[23:16];
            5'd2:    addr_byte = frame_addr[15:8];
            default: addr_byte = frame_addr[7:0];
        endcase
    end
    // frame byte stream: command byte, address bytes, then the payload.
    // Read frames clock 0xFF dummies and accumulate byte_rx into the shift
    // register; program frames consume the shift register MSB-first.
    reg [7:0] byte_mux;
    always @* begin
        if (byte_idx == 5'd0)      byte_mux = cmd_byte;
        else if (byte_idx <= 5'd3) byte_mux = addr_byte;
        else if (cmd_q == 3'd1)    byte_mux = shift[63:56];   // tx consumes
        else                       byte_mux = 8'hFF;          // read dummy
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; op_q <= 3'd0; cmd_q <= 3'd0; len_q <= 2'd0;
            byte_idx <= 5'd0; byte_start <= 1'b0; byte_run <= 1'b0;
            byte_tx <= 8'hff; frame_addr <= SLOT0_ADDRESS;
            boot_done <= 1'b0; wr_phase <= 1'b0; poll_cnt <= 2'd0;
            shift <= 64'd0; wait_cnt <= 26'd0;
            flash_cs_n <= 1'b1;
            pend <= 1'b0; pend_prog <= 7'd0; have_rec <= 1'b0;
            w_prog <= 7'd0; w_ver <= 16'd0;
            active_ver <= 16'd0; active_slot <= 1'b0;
            slot0_v <= 1'b0; slot1_v <= 1'b0;
            slot0_ver <= 16'd0; slot1_ver <= 16'd0;
            slot0_prog <= 7'd0; slot1_prog <= 7'd0;
            save_done <= 1'b0; journal_error <= 1'b0;
            prog_valid <= 1'b0; prog_out <= 7'd0;
        end else begin
            save_done  <= 1'b0;
            prog_valid <= 1'b0;
            case (state)
            S_IDLE: begin
                flash_cs_n <= 1'b1;
                byte_idx   <= 5'd0;
                byte_start <= 1'b0;
                byte_run   <= 1'b0;
                if (pend) begin
                    // a save: WREN, erase, wait+polls, WREN, program,
                    // wait+polls
                    pend     <= 1'b0;
                    w_prog   <= pend_prog;
                    w_ver    <= active_ver + 16'd1;
                    op_q     <= OP_ERASE;
                    cmd_q    <= 3'd3;                     // WREN frame
                    len_q    <= 2'd0;
                    wr_phase <= 1'b0;
                    state    <= S_FRAME;
                end else if (!boot_done) begin
                    // one-shot boot: read slot 0, then slot 1
                    boot_done  <= 1'b1;
                    op_q       <= OP_RD0;
                    cmd_q      <= 3'd0;
                    len_q      <= 2'd2;
                    frame_addr <= SLOT0_ADDRESS;
                    state      <= S_FRAME;
                end
            end
            S_FRAME: begin
                // one spi_byte_engine byte per byte_idx; CS stays low across
                // the frame and rises after the last byte (the one-cycle
                // S_DECIDE gives >= 40 ns deselect, tSHSL 30 ns). Reads
                // accumulate byte_rx MSB-first into the shift register;
                // programs consume the shift MSB-first.
                if (!byte_run) begin
                    if (byte_idx == 5'd0)
                        flash_cs_n <= 1'b0;
                    byte_tx    <= byte_mux;
                    byte_start <= 1'b1;
                    byte_run   <= 1'b1;
                end else begin
                    byte_start <= 1'b0;
                    if (byte_done) begin
                        byte_run <= 1'b0;
                        if (data_phase)
                            shift <= {shift[55:0], byte_rx};
                        else if (cmd_q == 3'd1 && byte_idx >= 5'd4)
                            shift <= {shift[55:0], 1'b0};
                        if (frame_last_byte) begin
                            flash_cs_n <= 1'b1;
                            state      <= S_DECIDE;
                        end else begin
                            byte_idx <= byte_idx + 1'b1;
                        end
                    end
                end
            end
            S_DECIDE: begin
                byte_idx   <= 5'd0;
                byte_start <= 1'b0;
                byte_run   <= 1'b0;
                case (cmd_q)
                3'd3: begin // WREN done -> issue the erase or program frame
                    frame_addr <= target_addr;
                    if (wr_phase) begin
                        cmd_q <= 3'd1;
                        len_q <= 2'd2;
                        op_q  <= OP_PROG;
                        // checksum spliced at byte 4: {r0..r3, r4=ck, r5..r7}
                        shift <= {w_body[63:32], w_ck, w_body[23:0]};
                    end else begin
                        cmd_q <= 3'd2;
                        len_q <= 2'd1;
                    end
                    state <= S_FRAME;
                end
                3'd2: begin // erase frame done -> fixed wait
                    wait_cnt <= ERASE_WAIT_CYCLES;
                    state    <= S_EWAIT;
                end
                3'd1: begin // program frame done -> fixed wait
                    wait_cnt <= PROG_WAIT_CYCLES;
                    state    <= S_PWAIT;
                end
                3'd4: begin // status poll done: two fixed polls per wait
                    poll_cnt <= poll_cnt - 2'd1;
                    if (poll_cnt != 2'd0) begin
                        cmd_q  <= 3'd4;                   // poll again
                        len_q  <= 2'd3;
                        state  <= S_FRAME;
                    end else if (op_q == OP_PROG) begin
                        state <= S_SAVED;
                    end else begin
                        cmd_q <= 3'd3;                    // WREN -> program
                        len_q <= 2'd0;
                        state <= S_FRAME;
                    end
                end
                default: begin // read frame done: 8 payload bytes in shift
                    if (op_q == OP_RD0) begin
                        slot0_v    <= rd_valid;
                        slot0_ver  <= shift[47:32];
                        slot0_prog <= shift[54:48];
                        op_q       <= OP_RD1;
                        cmd_q      <= 3'd0;
                        len_q      <= 2'd2;
                        frame_addr <= SLOT1_ADDRESS;
                        state      <= S_FRAME;
                    end else begin
                        slot1_v    <= rd_valid;
                        slot1_ver  <= shift[47:32];
                        slot1_prog <= shift[54:48];
                        state      <= S_CHOOSE;
                    end
                end
                endcase
            end
            S_EWAIT: begin
                // erase delay elapsed -> bounded WIP polls, then WREN ->
                // the program frame
                if (wait_cnt == 26'd0) begin
                    wr_phase  <= 1'b1;                // next WREN -> program
                    poll_cnt  <= 2'd1;                // 2 poll frames
                    cmd_q     <= 3'd4;                // RDSR frame
                    len_q     <= 2'd3;
                    state     <= S_FRAME;
                end else begin
                    wait_cnt <= wait_cnt - 26'd1;
                end
            end
            S_PWAIT: begin
                // program delay elapsed -> bounded WIP polls, then report
                if (wait_cnt == 26'd0) begin
                    poll_cnt <= 2'd1;
                    cmd_q    <= 3'd4;                     // RDSR frame
                    len_q    <= 2'd3;
                    state    <= S_FRAME;
                end else begin
                    wait_cnt <= wait_cnt - 26'd1;
                end
            end
            S_CHOOSE: begin
                if (slot1_newer) begin
                    active_ver  <= slot1_ver;
                    active_slot <= 1'b1;
                    prog_out    <= slot1_prog;
                end else if (slot0_v) begin
                    active_ver  <= slot0_ver;
                    active_slot <= 1'b0;
                    prog_out    <= slot0_prog;
                end else begin
                    active_ver  <= 16'd0;
                    active_slot <= 1'b0;
                    prog_out    <= 7'd0;
                end
                have_rec   <= slot1_newer || slot0_v;
                prog_valid <= 1'b1;
                state      <= S_IDLE;
            end
            S_SAVED: begin
                // program polls cleared: the write is "committed" as far as
                // this journal models it (no verify -- see header)
                active_ver  <= active_ver + 16'd1;
                active_slot <= target_slot;
                have_rec    <= 1'b1;
                save_done   <= 1'b1;
                state       <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
            // live save capture; AFTER the case so it wins over pend <= 0.
            // Coalesce: the newest word supersedes any queued one, and a
            // request landing mid-write queues the FOLLOWING write.
            if (save_req) begin
                pend      <= 1'b1;
                pend_prog <= save_prog;
            end
        end
    end
endmodule
