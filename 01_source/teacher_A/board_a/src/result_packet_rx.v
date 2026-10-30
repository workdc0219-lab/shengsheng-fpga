`timescale 1ns/1ps
// Board A receiver for Board B's 24-byte return packet (docs/14 section 3).
// Scans for A5 5A, collects 22 more bytes, accepts the packet only if
// p23 == ~(p2 + ... + p22). Every accepted packet refreshes the status
// outputs; the result outputs (and the res_new pulse) update only when the
// packet's res_seq differs from the last accepted one -- that is the rule
// that keeps a packet straddling a new result from being used. res_seq 0
// means "no result yet" (Board B counts 1..15 and skips 0 on wrap).
// b_link_up falls after LINK_TIMEOUT clocks without an accepted packet.
module result_packet_rx #(
    parameter integer CLKS_PER_BIT = 27,
    parameter integer LINK_TIMEOUT = 12500000          // 0.5 s at 25 MHz
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         rx,
    output reg          b_link_up,
    output reg  [2:0]   mode,
    output reg  [2:0]   phase,
    output reg  [1:0]   q_idx,
    output reg  [1:0]   eff_diff,
    output reg          tch_used,
    output reg          teacher_on,
    output reg          res_new,        // 1-clk: a new result below
    output reg  [3:0]   res_seq,
    output reg  [2:0]   target,
    output reg  [2:0]   tone,
    output reg  [1:0]   stars,
    output reg          too_short,
    output reg  [6:0]   score,
    output reg  [6:0]   n_points,
    output reg  [127:0] shape          // 16 x signed 8, [k*8 +: 8]
);
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(rx), .data(rx_data), .valid(rx_valid),
        .framing_error()
    );

    reg [1:0]   hdr;                    // 0: want A5, 1: want 5A, 2: body
    reg [4:0]   idx;                    // body byte index 2..23
    reg [7:0]   sum;
    reg [7:0]   b2, b3, b4, b5, b6;
    reg [127:0] body_shape;
    reg         seen_any;
    reg [23:0]  idle;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hdr <= 2'd0; idx <= 5'd0; sum <= 8'd0;
            b2 <= 8'd0; b3 <= 8'd0; b4 <= 8'd0; b5 <= 8'd0; b6 <= 8'd0;
            body_shape <= 128'd0; seen_any <= 1'b0; idle <= 24'd0;
            b_link_up <= 1'b0; mode <= 3'd0; phase <= 3'd0; q_idx <= 2'd0;
            eff_diff <= 2'd0; tch_used <= 1'b0; teacher_on <= 1'b0;
            res_new <= 1'b0; res_seq <= 4'd0; target <= 3'd0; tone <= 3'd0;
            stars <= 2'd0; too_short <= 1'b0; score <= 7'd0; n_points <= 7'd0;
            shape <= 128'd0;
        end else begin
            res_new <= 1'b0;
            if (idle == LINK_TIMEOUT - 1)
                b_link_up <= 1'b0;
            else
                idle <= idle + 1'b1;
            if (rx_valid) begin
                case (hdr)
                2'd0: if (rx_data == 8'hA5) hdr <= 2'd1;
                2'd1: begin
                    if (rx_data == 8'h5A) begin
                        hdr <= 2'd2; idx <= 5'd2; sum <= 8'd0;
                    end else if (rx_data != 8'hA5)
                        hdr <= 2'd0;
                end
                default: begin
                    if (idx != 5'd23)
                        sum <= sum + rx_data;
                    case (idx)
                        5'd2: b2 <= rx_data;
                        5'd3: b3 <= rx_data;
                        5'd4: b4 <= rx_data;
                        5'd5: b5 <= rx_data;
                        5'd6: b6 <= rx_data;
                        5'd23: ;
                        default: body_shape[(idx - 5'd7)*8 +: 8] <= rx_data;
                    endcase
                    if (idx == 5'd23) begin
                        hdr <= 2'd0;
                        if (rx_data == ~sum) begin
                            idle <= 24'd0;
                            b_link_up <= 1'b1;
                            {mode, phase, q_idx} <= b2;
                            {eff_diff, tch_used, teacher_on} <= b3[3:0];
                            seen_any <= 1'b1;
                            // res_seq 0 = "no result yet" (B counts 1..15)
                            if (b3[7:4] != res_seq) begin
                                res_seq <= b3[7:4];
                                if (b3[7:4] != 4'd0) begin
                                    {target, tone, stars} <= b4;
                                    {too_short, score} <= b5;
                                    n_points <= b6[6:0];
                                    shape <= body_shape;
                                    // the first packet after A boots shows an
                                    // old result: displayed, not re-recorded
                                    res_new <= seen_any;
                                end
                            end
                        end
                    end else
                        idx <= idx + 1'b1;
                end
                endcase
            end
        end
    end
endmodule
