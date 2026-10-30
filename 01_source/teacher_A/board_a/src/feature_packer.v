`timescale 1ns/1ps

// Board A feature packer v6: 15-byte frames at 921600-8N1 (docs/14 section
// 2). v6 keeps every byte Board B consumes bit-identical to v5 (docs/10
// section 3) and reuses the bytes it never read:
//
//  b0  [7]=1 sync | [6] voiced | [5:0] pitch_q4[9:4]     (child, ch2)
//  b1  [7:4] pitch_q4[3:0] | [3:0] level[7:4]
//  b2  [7:4] level[3:0]    | [3:0] tau_q4[11:8]
//  b3  [7:4] f2_band[3:0]  | [3:0] f1_band[3:0]
//  b4  [7:4] jitter_c[7:4] | [3:0] shimmer_c[7:4]
//  b5  {nb_ready, nb_tone[2:0], dtw_ready, dtw_tone[2:0]}
//  b6  [7:4] jitter_c[3:0] | [3:0] shimmer_c[3:0]
//  b7  {clip, agc_ovf, demo_en, 5'b0}                   (v6: demo_en)
//  b8  {1, v2, p2[9:4]}                                  (teacher, ch3)
//  b9  {p2[3:0], l2[7:4]}
//  b10 {l2[3:0], tau2_hi}
//  b11 {tc_valid, tc_seq[3:0], tc_chunk[2:0]}            (v6 carousel)
//  b12..b14 tc_msg[tc_chunk*3 + 0..2]
// The 18-byte teacher-curve message rotates one chunk per frame (chunk
// 0..5), so a whole curve crosses the link every 6 frames (100 ms) and is
// repeated until the next one replaces it. 15 bytes x 60 fps = 9.8% line.
module feature_packer #(
    parameter integer CLKS_PER_BIT = 27         // 25 MHz / 27 ~ 925926
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_valid,
    input  wire       voiced,
    input  wire [9:0] pitch_q4,
    input  wire [7:0] level,
    input  wire [11:0] tau_q4,
    input  wire [3:0] f1_band,
    input  wire [3:0] f2_band,
    input  wire [7:0] jitter_c,
    input  wire [7:0] shimmer_c,
    input  wire [7:0] nb_byte,                 // {nb_ready, 1'b0, nb_tone[2:0], 3'b0}
    input  wire [7:0] dtw_byte,                // {dtw_ready, 1'b0, dtw_tone[2:0], 3'b0}
    input  wire       clip_flag,
    input  wire       agc_ovf,
    input  wire       v2_valid,                // 0: player-2 bytes = silence
    input  wire       voiced2,
    input  wire [9:0] pitch_q42,
    input  wire [7:0] level2,
    input  wire [11:0] tau_q42,
    input  wire       demo_en,                 // A-board SW1: teacher demo on
    input  wire       tc_valid,                // a teacher curve exists
    input  wire [3:0] tc_seq,                  // +1 per new curve
    input  wire [143:0] tc_msg,                // msg byte i at [i*8 +: 8]
    output wire       uart_tx
);
    wire tx_busy, tx_done;
    reg  tx_start;
    reg  [7:0] tx_data;

    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .start(tx_start), .data(tx_data),
        .tx(uart_tx), .busy(tx_busy), .done(tx_done)
    );

    localparam [1:0] ST_IDLE = 2'd0, ST_WAIT = 2'd1, ST_SEND = 2'd2;
    reg [1:0]  state;
    reg [3:0]  byte_idx;
    reg        vcd;
    reg [9:0]  pitch_q;
    reg [7:0]  lvl;
    reg [3:0]  tau_hi;
    reg [3:0]  f1b, f2b;
    reg [7:0]  jc, sc;
    reg [7:0]  nbb, dtwb;
    reg        clp, agc;
    reg        v2v, v2c;
    reg [9:0]  p2q;
    reg [7:0]  p2l;
    reg [3:0]  p2tau;
    reg        dem;
    reg        tcv;
    reg [3:0]  tcs;
    reg [2:0]  chunk;                          // carousel position, 0..5
    reg [23:0] tcb;                            // the chunk's three bytes

    wire [2:0] next_chunk = (chunk >= 3'd5) ? 3'd0 : chunk + 1'b1;

    reg [7:0] pack_b [0:14];
    always @* begin
        pack_b[0]  = {1'b1, vcd, pitch_q[9:4]};
        pack_b[1]  = {pitch_q[3:0], lvl[7:4]};
        pack_b[2]  = {lvl[3:0], tau_hi};
        pack_b[3]  = {f2b, f1b};
        pack_b[4]  = {jc[7:4], sc[7:4]};
        pack_b[5]  = {nbb[7], nbb[5:3], dtwb[7], dtwb[5:3]};
        pack_b[6]  = {jc[3:0], sc[3:0]};
        pack_b[7]  = {clp, agc, dem, 5'b0};
        pack_b[8]  = {1'b1, v2v & v2c, p2q[9:4]};
        pack_b[9]  = {p2q[3:0], p2l[7:4]};
        pack_b[10] = {p2l[3:0], p2tau};
        pack_b[11] = {tcv, tcs, chunk};
        pack_b[12] = tcb[7:0];
        pack_b[13] = tcb[15:8];
        pack_b[14] = tcb[23:16];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; byte_idx <= 4'd0;
            vcd <= 1'b0; pitch_q <= 10'd0; lvl <= 8'd0; tau_hi <= 4'd0;
            f1b <= 4'd0; f2b <= 4'd0; jc <= 8'd0; sc <= 8'd0;
            nbb <= 8'd0; dtwb <= 8'd0; clp <= 1'b0; agc <= 1'b0;
            v2v <= 1'b0; v2c <= 1'b0; p2q <= 10'd0; p2l <= 8'd0;
            p2tau <= 4'd0;
            dem <= 1'b0; tcv <= 1'b0; tcs <= 4'd0; chunk <= 3'd5; tcb <= 24'd0;
            tx_start <= 1'b0; tx_data <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            case (state)
            ST_IDLE, ST_WAIT: begin
                if (frame_valid) begin
                    vcd <= voiced;  pitch_q <= pitch_q4; lvl <= level;
                    tau_hi <= tau_q4[11:8];
                    f1b <= f1_band; f2b <= f2_band;
                    jc <= jitter_c; sc <= shimmer_c;
                    nbb <= nb_byte; dtwb <= dtw_byte;
                    clp <= clip_flag; agc <= agc_ovf;
                    v2v <= v2_valid; v2c <= voiced2;
                    p2q <= pitch_q42; p2l <= level2; p2tau <= tau_q42[11:8];
                    dem <= demo_en;
                    tcv <= tc_valid; tcs <= tc_seq;
                    chunk <= (chunk >= 3'd5) ? 3'd0 : chunk + 1'b1;
                    tcb <= tc_valid ? tc_msg[next_chunk*24 +: 24] : 24'd0;
                    byte_idx <= 4'd0;
                    state <= ST_SEND;
                end
            end
            ST_SEND: begin
                if (!tx_busy && !tx_start && !tx_done) begin
                    tx_data  <= pack_b[byte_idx];
                    tx_start <= 1'b1;
                end else if (tx_done) begin
                    if (byte_idx == 4'd14)
                        state <= ST_WAIT;
                    else
                        byte_idx <= byte_idx + 1'b1;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
