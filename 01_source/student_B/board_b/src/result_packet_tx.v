`timescale 1ns/1ps
// Board B -> Board A return packet (docs/14 section 3): 24 bytes at
// 921600-8N1 on header J2-1. One packet right after every scored result and
// one every 8 video frames as a status heartbeat; both share the format:
//   p0 p1   A5 5A
//   p2      {mode[2:0], phase[2:0], q_idx[1:0]}
//   p3      {res_seq[3:0], eff_diff[1:0], tch_used, teacher_on}
//   p4      {target[2:0], tone[2:0], stars[1:0]}     last result
//   p5      {too_short, score[6:0]}
//   p6      {1'b0, n_points[6:0]}
//   p7..p22 child shape clamp(bins[k] - mean, +-127), signed 8
//   p23     ~(p2 + ... + p22)
// Status fields are sampled when a packet starts. The result fields are read
// straight from tone_scorer's output registers (held until its next result),
// only the target is latched here -- the game moves sc_target on to the next
// question. A result landing mid-packet can mix old and new fields in that
// one packet, but it still carries the OLD res_seq (snapshot at packet
// start); Board A takes result fields only on a res_seq change, and the very
// next packet carries the new seq with consistent data.
module result_packet_tx #(
    parameter integer CLKS_PER_BIT = 27
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         frame_tick,
    input  wire [2:0]   mode,
    input  wire [2:0]   phase,
    input  wire [1:0]   q_idx,
    input  wire [1:0]   eff_diff,
    input  wire         tch_used,
    input  wire         teacher_on,
    input  wire         sc_valid,
    input  wire [2:0]   sc_target,
    input  wire [2:0]   sc_tone,
    input  wire [1:0]   sc_stars,
    input  wire         sc_short,
    input  wire [6:0]   sc_score,
    input  wire [6:0]   sc_n,
    input  wire [9:0]   sc_mean,
    input  wire [159:0] sc_bins,
    output wire         tx
);
    wire tx_busy, tx_done;
    reg  tx_start;
    reg  [7:0] tx_data;
    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data),
        .tx(tx), .busy(tx_busy), .done(tx_done)
    );

    reg [3:0]   res_seq;
    reg [2:0]   r_target;
    // status snapshot for the packet in flight
    reg [7:0]   s_p2, s_p3;

    reg [2:0] hb_cnt;
    reg       pending;
    reg       sending;
    reg [4:0] idx;                          // byte index 0..23
    reg [7:0] sum;

    wire [3:0] bk = idx[3:0] - 4'd7;        // p7..p22 -> bin 0..15
    wire signed [11:0] sd = $signed({2'b00, sc_bins[bk*10 +: 10]}) - $signed({2'b00, sc_mean});
    wire [7:0] shape_b = (sd > 12'sd127) ? 8'd127 : (sd < -12'sd127) ? 8'h81 : sd[7:0];

    reg [7:0] cur;
    always @* begin
        case (idx)
            5'd0:  cur = 8'hA5;
            5'd1:  cur = 8'h5A;
            5'd2:  cur = s_p2;
            5'd3:  cur = s_p3;
            5'd4:  cur = {r_target, sc_tone, sc_stars};
            5'd5:  cur = {sc_short, sc_score};
            5'd6:  cur = {1'b0, sc_n};
            5'd23: cur = ~sum;
            default: cur = shape_b;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_seq <= 4'd0; r_target <= 3'd0; s_p2 <= 8'd0; s_p3 <= 8'd0;
            hb_cnt <= 3'd0; pending <= 1'b0; sending <= 1'b0; idx <= 5'd0;
            sum <= 8'd0; tx_start <= 1'b0; tx_data <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            if (sc_valid) begin
                res_seq <= (res_seq == 4'd15) ? 4'd1 : res_seq + 1'b1;   // 0 = none yet
                r_target <= sc_target;
                pending <= 1'b1;
            end
            if (frame_tick) begin
                hb_cnt <= hb_cnt + 1'b1;
                if (hb_cnt == 3'd7)
                    pending <= 1'b1;
            end
            if (!sending) begin
                if (pending && !sc_valid) begin
                    pending <= 1'b0;
                    sending <= 1'b1;
                    idx <= 5'd0;
                    sum <= 8'd0;
                    s_p2 <= {mode, phase, q_idx};
                    s_p3 <= {res_seq, eff_diff, tch_used, teacher_on};
                end
            end else if (!tx_busy && !tx_start && !tx_done) begin
                tx_data <= cur;
                tx_start <= 1'b1;
            end else if (tx_done) begin
                if (idx >= 5'd2 && idx <= 5'd22)
                    sum <= sum + cur;
                if (idx == 5'd23)
                    sending <= 1'b0;
                else
                    idx <= idx + 1'b1;
            end
        end
    end
endmodule
