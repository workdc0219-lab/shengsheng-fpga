`timescale 1ns/1ps

// Stage E: training-record export over the board UART (the degraded P5 --
// Flash persistence was removed for resources, see docs/39 section 4 and
// docs/49). Every finished scorer utterance (result_valid pulse, including
// too-short attempts, which arrive with score 0 / stars 0) emits one line:
//
//     SCORE <mode> <tone> <score> <stars><CR><LF>
//
//   mode  1..4  (tone climb / balloon / train / card -- only 1 and 4 can
//               produce scorer results, but the field carries whatever the
//               game was in when the result landed)
//   tone  1..4  the asked syllable's tone (the scorer's target)
//   score 000..100, three zero-padded decimal digits
//   stars 0..3
//
// One line is 17 bytes at 115200-8N1 (~1.5 ms) and the game cannot start a
// new utterance while the previous one is being graded, but a one-deep
// pending latch is kept anyway so a back-to-back pulse can never be lost:
// a pulse during transmission overwrites the pending payload, so the LAST
// event always wins and none is silently swallowed by the FSM.
//
// The score digits are plain divide-by-constant arithmetic ((v*205)>>11 is
// exact for v/10 up to 104) -- no divider, no hex, so the log reads directly
// in a terminal. Same uart_tx_byte instance style as uart_status_reporter.
module ss_score_reporter #(
    parameter integer CLKS_PER_BIT = 217        // 25 MHz / 217 = 115207 baud
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       score_event,              // tone_scorer result_valid
    input  wire [2:0] mode,                     // game mode at the result
    input  wire [2:0] tone,                     // sc_target at the result
    input  wire [6:0] score,                    // sc_score, 0..100
    input  wire [1:0] stars,                    // sc_stars, 0..3
    output wire       uart_tx
);
    localparam [7:0] CR = 8'h0d;
    localparam [7:0] LF = 8'h0a;

    // message layout: "SCORE m t ddd s\r\n" -> 17 bytes, indices 0..16
    localparam integer MSG_LEN = 17;

    reg [7:0] mode_q, tone_q, score_q, stars_q;
    reg [7:0] pend_mode, pend_tone, pend_score, pend_stars;
    reg pend;
    reg [4:0] send_index;
    reg tx_start_r;
    reg [1:0] state;
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SEND = 2'd1;

    // score 0..100 in three decimal digits (latched value)
    wire       is100  = (score_q == 7'd100);
    wire [6:0] sub100 = is100 ? 7'd0 : score_q;
    wire [14:0] tens_pr = sub100 * 13'd205;           // 99*205 = 20295 < 2^15
    wire [3:0] tens    = tens_pr[14:11];              // sub100/10, exact here
    wire [3:0] ones    = sub100 - ((tens << 3) + (tens << 1));  // <= 9
    wire [3:0] hund    = is100 ? 4'd1 : 4'd0;

    function [7:0] digit;
        input [3:0] v;
        begin
            digit = 8'h30 + {4'b0, v};
        end
    endfunction

    function [7:0] char_of;
        input [4:0] idx;
        begin
            case (idx)
                0: char_of = "S";
                1: char_of = "C";
                2: char_of = "O";
                3: char_of = "R";
                4: char_of = "E";
                5: char_of = " ";
                6: char_of = digit(mode_q[3:0]);
                7: char_of = " ";
                8: char_of = digit(tone_q[3:0]);
                9: char_of = " ";
                10: char_of = digit(hund);
                11: char_of = digit(tens);
                12: char_of = digit(ones);
                13: char_of = " ";
                14: char_of = digit(stars_q);
                15: char_of = CR;
                16: char_of = LF;
                default: char_of = 8'h00;
            endcase
        end
    endfunction

    wire tx_busy;
    wire tx_done;

    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .start(tx_start_r), .data(char_of(send_index)),
        .tx(uart_tx), .busy(tx_busy), .done(tx_done)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            mode_q <= 8'd0; tone_q <= 8'd0; score_q <= 8'd0; stars_q <= 8'd0;
            pend_mode <= 8'd0; pend_tone <= 8'd0;
            pend_score <= 8'd0; pend_stars <= 8'd0;
            pend <= 1'b0;
            send_index <= 5'd0;
            tx_start_r <= 1'b0;
        end else begin
            case (state)
            ST_IDLE: begin
                tx_start_r <= 1'b0;
                send_index <= 5'd0;
                if (score_event) begin
                    mode_q <= {5'd0, mode};
                    tone_q <= {5'd0, tone};
                    score_q <= {1'b0, score};
                    stars_q <= {6'd0, stars};
                    state <= ST_SEND;
                end else if (pend) begin
                    mode_q <= pend_mode;
                    tone_q <= pend_tone;
                    score_q <= pend_score;
                    stars_q <= pend_stars;
                    pend <= 1'b0;
                    state <= ST_SEND;
                end
            end
            ST_SEND: begin
                if (score_event && !pend) begin
                    pend_mode <= {5'd0, mode};
                    pend_tone <= {5'd0, tone};
                    pend_score <= {1'b0, score};
                    pend_stars <= {6'd0, stars};
                    pend <= 1'b1;
                end
                if (tx_done)
                    send_index <= send_index + 1'b1;
                if (send_index >= MSG_LEN) begin
                    tx_start_r <= 1'b0;
                    send_index <= 5'd0;
                    state <= ST_IDLE;
                end else if (!tx_busy && !tx_start_r && !tx_done) begin
                    tx_start_r <= 1'b1;
                end else begin
                    tx_start_r <= 1'b0;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
