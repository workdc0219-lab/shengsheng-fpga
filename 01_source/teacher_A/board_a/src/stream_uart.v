`timescale 1ns/1ps
// Raw-audio + spectral stream to PC (docs/10 §8, R81; the P3 dataset
// flywheel).
//
// Wire format at 921600-8N1 (38% utilisation):
//   continuous: 2 bytes LE per 15.625 kHz sample (31.25 KB/s)
//   per video frame: sync 8'hA5 8'h5A 8'hA5 8'h5A + 36 band e_q bytes
//
// S9 (docs/17, 2026-10-03): the marker used to be ONE 0xA5 byte and bursts
// could split a sample pair (burst latch allowed at raw_ph == 2). Both were
// wrong once the frontend's DC-removal x16 gain is accounted for: samples
// are full-range signed, so a sample byte can be 0xA5 and a lone-marker
// parser loses sync constantly. The 4-byte sync cannot occur inside sample
// data (it would need two consecutive samples of exactly 0x5AA5), bursts
// now latch only at a pair boundary (raw_ph == 0), and 40 is even, so
// consuming a burst preserves sample-pair phase -- the parser self-heals at
// every burst. Samples arriving while a pair or burst is pending are
// dropped by design (measured 0-2, mean ~1 per burst: tb drives 780,
// RTL accepts 777; invisible to the 16-bin contour).
//
// Writer: strict priority -- a latched spectral burst (40 bytes) drains
// before pending raw bytes; the 64-byte ring absorbs the burst (pushes
// stall while full).
module stream_uart #(
    parameter integer CLKS_PER_BIT = 27,
    parameter integer NBANDS = 36
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,
    input  wire signed [15:0] sample,
    input  wire               bands_valid,
    input  wire [287:0]       bands,
    output wire               stream_tx
);
    // ---------------- 64-byte ring ----------------
    reg [7:0]  ring [0:63];
    reg [5:0]  wr_ptr, rd_ptr;
    wire       ring_empty = (wr_ptr == rd_ptr);
    wire       ring_full  = (wr_ptr == (rd_ptr ^ 6'h20));

    // ---------------- writer ----------------
    reg [15:0] sample_hold;
    reg [1:0]  raw_ph;                   // 0 none, 1 lo pending, 2 hi pending
    reg [6:0]  sp_ph;                    // 0 none, 1..4 sync, 5..40 bands
    reg [287:0] bands_hold;
    reg [7:0]  push_data;
    reg        push;

    always @* begin
        push = 1'b0; push_data = 8'd0;
        if (!ring_full) begin
            if (sp_ph != 7'd0) begin
                push    = 1'b1;
                case (sp_ph)
                    7'd1:    push_data = 8'hA5;
                    7'd2:    push_data = 8'h5A;
                    7'd3:    push_data = 8'hA5;
                    7'd4:    push_data = 8'h5A;
                    default: push_data = bands_hold[(sp_ph - 7'd5)*8 +: 8];
                endcase
            end else if (raw_ph == 2'd1) begin
                push = 1'b1; push_data = sample_hold[7:0];
            end else if (raw_ph == 2'd2) begin
                push = 1'b1; push_data = sample_hold[15:8];
            end
        end
    end

    // ---------------- reader ----------------
    reg [1:0]  tx_state;                 // 0 idle, 1 sending
    reg [3:0]  bit_cnt;
    reg [8:0]  clk_cnt;
    reg [7:0]  sh;
    reg        tx_reg;
    assign stream_tx = tx_reg;

    integer gi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 6'd0; rd_ptr <= 6'd0;
            sample_hold <= 16'd0; raw_ph <= 2'd0; sp_ph <= 7'd0;
            bands_hold <= 288'd0;
            tx_state <= 2'd0; bit_cnt <= 4'd0; clk_cnt <= 9'd0;
            sh <= 8'd0; tx_reg <= 1'b1;
            for (gi = 0; gi < 64; gi = gi + 1) ring[gi] <= 8'd0;
        end else begin
            // ---------- writer ----------
            // S9 fix: the latch must ARM the pair (raw_ph <= 1). The original
            // never assigned raw_ph anywhere but the push advance (1->2->0),
            // so samples never entered the ring and the wire carried only
            // the band bursts -- caught by tb_stream_uart, never on hardware
            // (the diag bit predates any board bring-up).
            if (sample_valid && raw_ph == 2'd0) begin
                sample_hold <= sample;
                raw_ph      <= 2'd1;
            end


            if (push) begin
                ring[wr_ptr] <= push_data;
                wr_ptr <= wr_ptr + 1'b1;
                if (sp_ph != 7'd0)
                    sp_ph <= (sp_ph == 7'd40) ? 7'd0 : sp_ph + 1'b1;
                else if (raw_ph == 2'd1)
                    raw_ph <= 2'd2;
                else
                    raw_ph <= 2'd0;
            end
            // burst latch ONLY at a pair boundary (S9, see header): splitting
            // a pending lo/hi pair would misphase the PC parser
            if (bands_valid && sp_ph == 7'd0 && raw_ph == 2'd0) begin
                bands_hold <= bands;
                sp_ph <= 7'd1;
            end

            // ---------- reader (1 byte per 10 x CLKS_PER_BIT clocks) ------
            // S9 audit fix: the original went straight from the last data
            // slot to state 0, whose start emission overwrote the stop bit
            // whenever the ring was non-empty (back-to-back bytes had NO
            // stop, plus a re-sent sh[0] 9th data bit) -- framing errors on
            // a real CH340. A dedicated stop state holds the line high one
            // full bit time before state 0 may emit the next start.
            case (tx_state)
            2'd0: begin
                tx_reg <= 1'b1;
                if (!ring_empty) begin
                    sh       <= ring[rd_ptr];
                    rd_ptr   <= rd_ptr + 1'b1;
                    tx_state <= 2'd1;
                    clk_cnt  <= 9'd0;
                    bit_cnt  <= 4'd0;
                    tx_reg   <= 1'b0;            // start bit
                end
            end
            2'd1: begin
                clk_cnt <= clk_cnt + 1'b1;
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 9'd0;
                    bit_cnt <= bit_cnt + 1'b1;
                    // event k fills slot k+1: k=0..7 -> d0..d7, k=8 -> the
                    // stop slot runs in the dedicated stop state below
                    if (bit_cnt == 4'd8) begin
                        tx_reg   <= 1'b1;
                        tx_state <= 2'd2;
                    end else begin
                        tx_reg <= sh[bit_cnt[2:0]];
                    end
                end
            end
            2'd2: begin                          // stop bit, one full bit
                clk_cnt <= clk_cnt + 1'b1;
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt  <= 9'd0;
                    tx_state <= 2'd0;
                end
            end
            default: tx_state <= 2'd0;
            endcase
        end
    end
endmodule
