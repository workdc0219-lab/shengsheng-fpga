`timescale 1ns/1ps

// Board B UART feature receiver v6: unpacks the 15-byte feature frames that
// Board A's feature_packer v6 streams at 921600-8N1, one frame per video
// frame (docs/14 section 2; bytes b0..b6 and b8..b10 are v5, docs/10 s3).
// v6: b7[5] carries demo_en (A-board SW1) and b11..b14 carry the teacher-
// curve carousel, assembled here into tch_off/tch_n with a tch_ok pulse. Supersedes the 12-byte v2 decoder
// (docs/08 section 2): the 8 Goertzel band bytes are gone (the full spectrum
// now travels the separate A->PC stream), replaced by formant bands, cycle-
// level VQ, the DTW verdict and a second player's features.
//
// Frame format (source: docs/10 section 3, board_a/src/feature_packer.v v5):
//   b0      [7]=1 sync | [6]=voiced | [5:0]=pitch_q4[9:4]   (player 1)
//   b1      [7:4]=pitch_q4[3:0] | [3:0]=level[7:4]
//   b2      [7:4]=level[3:0]    | [3:0]=tau_q4[11:8]
//   b3      [7:4]=f2_band[3:0]  | [3:0]=f1_band[3:0]  (formant band indices)
//   b4      [7:4]=jitter_c[7:4] | [3:0]=shimmer_c[7:4] (cycle-level VQ, high)
//   b5      {nb_ready, nb_tone[2:0], dtw_ready, dtw_tone[2:0]}
//   b6      {jitter_c[3:0], shimmer_c[3:0]}             (VQ low nibbles)
//   b7      {clip_flag, agc_ovf, reserved[5:0]}
//   b7      [5]=demo_en (v6)
//   b8..b10 teacher (ch3) live b0', b1', b2' (p2_* outputs, unused on B)
//   b11     {tc_valid, tc_seq[3:0], tc_chunk[2:0]}
//   b12..14 msg[tc_chunk*3 + 0..2] of the 18-byte teacher-curve message
// i.e. pitch_q4 = {b0[5:0], b1[7:4]}, level = {b1[3:0], b2[7:4]},
//      jitter_c = {b4[7:4], b6[7:4]}, shimmer_c = {b4[3:0], b6[3:0]}.
//
// All feature outputs (including the v2-era voiced/pitch/level/tau_hi) are
// committed together on the byte-14 edge; feat_valid pulses for exactly one
// clock per frame, as before.
//
// Framing: only byte 0 carries the player-1 sync bit, so the receiver scans
// for a byte with bit7=1 to (re)align. The 14 payload bytes are consumed
// unconditionally: their bit7 can legitimately be 1 (pitch msbs, b5's
// nb_ready, b8's player-2 sync), so bit7 cannot be used to resynchronise
// mid-frame. A lost or corrupted byte therefore costs at most one garbage
// frame before the next byte0 realigns; an idle timeout (>> the 16.7 ms
// frame period, so it never trips on a healthy link) covers drop-outs and
// partial frames. Framing errors from uart_rx_byte never assert valid, so
// they desynchronise by one byte and self-heal the same way.
module uart_rx_feature #(
    parameter integer CLKS_PER_BIT = 27,         // 25 MHz / 27 = 925926 baud (921600-8N1)
    parameter integer IDLE_TIMEOUT = (1 << 21)   // ~84 ms at 25 MHz; one 15-byte
                                                 // frame is 4050 clks at 921600
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       uart_rx,
    // one 1-clk pulse per received frame, with the unpacked features
    output reg        feat_valid,
    output reg        feat_voiced,
    output reg  [9:0] feat_pitch_q4,
    output reg  [7:0] feat_level,
    output reg  [3:0] tau_hi,                    // tau_q4[11:8] (player 1)
    // v5 payload (docs/10 section 3)
    output reg  [3:0] f1_band,                   // b3[3:0], formant band index
    output reg  [3:0] f2_band,                   // b3[7:4]
    output reg  [7:0] jitter_c,                  // {b4[7:4], b6[7:4]}
    output reg  [7:0] shimmer_c,                 // {b4[3:0], b6[3:0]}
    output reg        nb_valid,                  // b5[7]: A-board NB hold
    output reg  [2:0] nb_tone,                   // b5[6:4]: NB fallback tone
    output reg        dtw_ready,                 // b5[3]: A-board DTW hold
    output reg  [2:0] dtw_tone,                  // b5[2:0]: DTW verdict
    output reg        clip_flag,                 // b7[7]
    output reg        agc_ovf,                   // b7[6]
    // teacher channel live features (b8..b10; not consumed on B)
    output reg        p2_voiced,
    output reg  [9:0] p2_pitch_q4,
    output reg  [7:0] p2_level,
    output reg  [3:0] p2_tau_hi,
    // v6 (docs/14 section 2)
    output reg        demo_en,                   // b7[5]: A-board SW1
    output reg        link_up,                   // a frame within IDLE_TIMEOUT
    output reg        tch_ok,                    // 1-clk: new checked teacher curve
    output reg  [3:0] tch_seq,
    output reg  [6:0] tch_n,
    output reg  [127:0] tch_off                  // 16 x signed 8, [k*8 +: 8]
);
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rx(uart_rx), .data(rx_data), .valid(rx_valid),
        .framing_error()
    );

    localparam [1:0] ST_B0   = 2'd0;   // scanning for the byte0 sync bit
    localparam [1:0] ST_BODY = 2'd1;   // byte0 latched, counting bytes 1..14

    reg [1:0]  state;
    reg [3:0]  bidx;                   // byte index within the frame, 0..14
    reg [15:0] gap_cnt;                // audit P1: idle-run length before a sync is trusted
    reg [7:0]  tch_ck;                 // audit P2: last published curve checksum (dedup)
    reg [7:0]  tc_hdr;                 // b11
    reg [7:0]  tc_b0, tc_b1;           // b12, b13
    // carousel assembly (docs/14 section 2): start on chunk 0, chunks must
    // follow 1..5 under one seq, msg[17] = ~sum(msg[0..16])
    reg        asm_on;
    reg [3:0]  asm_seq;
    reg [2:0]  asm_next;
    reg [7:0]  asm_sum;
    reg [143:0] asm_buf;
    reg        pub_valid;
    wire       hv     = tc_hdr[7];
    wire [3:0] hseq   = tc_hdr[6:3];
    wire [2:0] hchunk = tc_hdr[2:0];
    wire [7:0] sum5   = asm_sum + tc_b0 + tc_b1;
    reg [7:0]  b0, b1, b2;             // player-1 bytes held until commit
    reg [3:0]  jit_hi, shm_hi;         // b4 nibbles, combined with b6
    reg [5:0]  p2_pit_hi;              // b8[5:0] = p2 pitch_q4[9:4]
    reg [3:0]  p2_pit_lo;              // b9[7:4] = p2 pitch_q4[3:0]
    reg [3:0]  p2_lvl_hi;              // b9[3:0] = p2 level[7:4]
    reg [31:0] idle_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_B0;
            bidx          <= 4'd0;
            b0            <= 8'd0;
            b1            <= 8'd0;
            b2            <= 8'd0;
            jit_hi        <= 4'd0;
            shm_hi        <= 4'd0;
            p2_pit_hi     <= 6'd0;
            p2_pit_lo     <= 4'd0;
            p2_lvl_hi     <= 4'd0;
            idle_cnt      <= 32'd0;
            feat_valid    <= 1'b0;
            feat_voiced   <= 1'b0;
            feat_pitch_q4 <= 10'd0;
            feat_level    <= 8'd0;
            tau_hi        <= 4'd0;
            f1_band       <= 4'd0;
            f2_band       <= 4'd0;
            jitter_c      <= 8'd0;
            shimmer_c     <= 8'd0;
            nb_valid      <= 1'b0;
            nb_tone       <= 3'd0;
            dtw_ready     <= 1'b0;
            dtw_tone      <= 3'd0;
            clip_flag     <= 1'b0;
            agc_ovf       <= 1'b0;
            p2_voiced     <= 1'b0;
            p2_pitch_q4   <= 10'd0;
            p2_level      <= 8'd0;
            p2_tau_hi     <= 4'd0;
            demo_en       <= 1'b0;
            link_up       <= 1'b0;
            tch_ok        <= 1'b0;
            tch_seq       <= 4'd0;
            tch_n         <= 7'd0;
            tch_off       <= 128'd0;
            tc_hdr        <= 8'd0;
            tc_b0         <= 8'd0;
            tc_b1         <= 8'd0;
            asm_on        <= 1'b0;
            asm_seq       <= 4'd0;
            asm_next      <= 3'd0;
            asm_sum       <= 8'd0;
            asm_buf       <= 144'd0;
            pub_valid     <= 1'b0;
            gap_cnt       <= 16'hffff;
            tch_ck        <= 8'h00;
        end else begin
            feat_valid <= 1'b0;
            tch_ok     <= 1'b0;
            idle_cnt   <= idle_cnt + 1'b1;
            if (gap_cnt != 16'hffff)
                gap_cnt  <= gap_cnt + 1'b1;

            if (rx_valid) begin
                idle_cnt <= 32'd0;
                gap_cnt  <= 16'd0;   // audit P1: any byte shortens the idle run
                case (state)
                ST_B0: begin
                    b0 <= rx_data;
                    // audit P1: the frame body contains bytes with bit7=1
                    // (b8), so an unqualified bit7 scan can lock onto b8 and
                    // stay locked forever (15-byte frames land back on the
                    // same offset -- head comment's "self-healing" claim was
                    // wrong). Real frame starts follow >=15 ms of idle; the
                    // 2700-clk (27 us) idle requirement rejects every
                    // intra-frame and dropped-byte misalignment.
                    if (rx_data[7] && gap_cnt >= 16'd2700) begin
                        bidx  <= 4'd1;
                        state <= ST_BODY;
                    end
                    // else: keep scanning (byte0 of a frame we already
                    // consumed, padding, or line noise)
                end
                ST_BODY: begin
                    case (bidx)
                    4'd1: b1 <= rx_data;
                    4'd2: b2 <= rx_data;
                    4'd3: begin
                        f2_band <= rx_data[7:4];
                        f1_band <= rx_data[3:0];
                    end
                    4'd4: begin
                        jit_hi <= rx_data[7:4];
                        shm_hi <= rx_data[3:0];
                    end
                    4'd5: begin
                        // {nb_ready, nb_tone[2:0], dtw_ready, dtw_tone[2:0]}
                        nb_valid  <= rx_data[7];
                        nb_tone   <= rx_data[6:4];
                        dtw_ready <= rx_data[3];
                        dtw_tone  <= rx_data[2:0];
                    end
                    4'd6: begin
                        jitter_c  <= {jit_hi, rx_data[7:4]};
                        shimmer_c <= {shm_hi, rx_data[3:0]};
                    end
                    4'd7: begin
                        clip_flag <= rx_data[7];
                        agc_ovf   <= rx_data[6];
                        demo_en   <= rx_data[5];
                    end
                    4'd8: begin
                        // player-2 b0': [7] sync (position-fixed, not scanned),
                        // [6] voiced, [5:0] pitch_q4[9:4]
                        p2_voiced <= rx_data[6];
                        p2_pit_hi <= rx_data[5:0];
                    end
                    4'd9: begin
                        p2_pit_lo <= rx_data[7:4];
                        p2_lvl_hi <= rx_data[3:0];
                    end
                    4'd10: begin
                        p2_pitch_q4 <= {p2_pit_hi, p2_pit_lo};
                        p2_level    <= {p2_lvl_hi, rx_data[7:4]};
                        p2_tau_hi   <= rx_data[3:0];
                    end
                    4'd11: tc_hdr <= rx_data;
                    4'd12: tc_b0  <= rx_data;
                    4'd13: tc_b1  <= rx_data;
                    default: begin // 4'd14: last byte, commit the whole frame
                        // carousel step: this chunk = {tc_b0, tc_b1, rx_data}
                        if (!hv) begin
                            asm_on <= 1'b0;
                        end else if (hchunk == 3'd0) begin
                            asm_on   <= 1'b1;
                            asm_seq  <= hseq;
                            asm_next <= 3'd1;
                            asm_buf[23:0] <= {rx_data, tc_b1, tc_b0};
                            asm_sum  <= tc_b0 + tc_b1 + rx_data;
                        end else if (asm_on && hchunk == asm_next && hseq == asm_seq) begin
                            if (hchunk == 3'd5) begin
                                // msg[15] = tc_b0, msg[16] = tc_b1, msg[17] = rx_data
                                asm_on <= 1'b0;
                                // audit P2: dedup key includes the curve
                                // checksum -- tc_seq wraps every 16 curves
                                if (~sum5 == rx_data &&
                                    (!pub_valid || hseq != tch_seq ||
                                     tch_ck != rx_data)) begin
                                    pub_valid <= 1'b1;
                                    tch_ok    <= 1'b1;
                                    tch_ck    <= rx_data;
                                    tch_seq   <= hseq;
                                    tch_n     <= tc_b1[6:0];
                                    tch_off   <= {tc_b0, asm_buf[119:0]};
                                end
                            end else begin
                                asm_buf[hchunk*24 +: 24] <= {rx_data, tc_b1, tc_b0};
                                asm_sum  <= asm_sum + tc_b0 + tc_b1 + rx_data;
                                asm_next <= asm_next + 1'b1;
                            end
                        end else begin
                            asm_on <= 1'b0;
                        end
                        link_up       <= 1'b1;
                        feat_voiced   <= b0[6];
                        feat_pitch_q4 <= {b0[5:0], b1[7:4]};
                        feat_level    <= {b1[3:0], b2[7:4]};
                        tau_hi        <= b2[3:0];
                        feat_valid    <= 1'b1;
                        state         <= ST_B0;
                    end
                    endcase
                    if (bidx != 4'd14)
                        bidx <= bidx + 4'd1;
                end
                default: state <= ST_B0;
                endcase
            end else if (idle_cnt == IDLE_TIMEOUT - 1) begin
                // no byte for ~84 ms: abandon a half-received frame
                state   <= ST_B0;
                link_up <= 1'b0;
            end
        end
    end
endmodule
