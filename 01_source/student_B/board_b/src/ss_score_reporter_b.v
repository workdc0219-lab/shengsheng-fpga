`timescale 1ns/1ps

// Board-B v5 variant of ss_score_reporter (the single-board original stays
// untouched, docs/08 section 6). Every finished scorer utterance still emits
// one line, but the v5 link no longer carries the 8 Goertzel band energies
// (the full spectrum travels the separate A->PC stream, docs/10 section 3),
// so the tail fields change:
//
//     SCORE <mode> <tone> <score> <stars>,N=<n>,D=<d>,F=<f1><f2><CR><LF>
//
//   N=  one hex character: the NB fallback verdict nb_tone[2:0] that fed the
//       scorer's cascade (0 = NB abstained / no hold)
//   D=  one hex character: the DTW template verdict dtw_tone[2:0]
//   F=  two hex characters: f1_band then f2_band (formant band indices,
//       docs/10 section 3 byte b3)
// The "SCORE <mode> <tone> <score> <stars>" prefix and the \015\012 ending
// are byte-identical to the v2 reporter.
//
// One line is 30 bytes at 115200-8N1 (~2.6 ms) -- still far below the
// inter-utterance gap, and the 6-bit send index (0..63) still covers it, so
// no buffer widening was needed for the shorter message. The same one-deep
// pending latch as before protects back-to-back result_valid pulses, and the
// pending payload carries the new fields too, so the LAST event always wins
// intact. Verilog has no \r escape: CR/LF are emitted with the octal escapes
// \015\012 exactly like the original reporter.
module ss_score_reporter_b #(
    parameter integer CLKS_PER_BIT = 217        // 25 MHz / 217 = 115207 baud
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       score_event,              // tone_scorer result_valid
    input  wire [2:0] mode,                     // game mode at the result
    input  wire [2:0] tone,                     // sc_target at the result
    input  wire [6:0] score,                    // sc_score, 0..100
    input  wire [1:0] stars,                    // sc_stars, 0..3
    input  wire [2:0] nb_tone,                  // v5 NB verdict from uart_rx_feature
    input  wire [2:0] dtw_tone,                 // v5 DTW verdict from uart_rx_feature
    input  wire [3:0] f1_band,                  // v5 formant band 1
    input  wire [3:0] f2_band,                  // v5 formant band 2
    output wire       uart_tx
);
    localparam [7:0] CR = 8'h0d;
    localparam [7:0] LF = 8'h0a;

    // message layout: "SCORE m t ddd s,N=<n>,D=<d>,F=<f1><f2>\r\n" -> 30 bytes
    localparam integer MSG_LEN = 30;

    reg [7:0] mode_q, tone_q, score_q, stars_q;
    reg [3:0] nb_l, dtw_l, f1_l, f2_l;
    reg [7:0] pend_mode, pend_tone, pend_score, pend_stars;
    reg [3:0] pend_nb, pend_dtw, pend_f1, pend_f2;
    reg pend;
    reg [5:0] send_index;
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

    function [7:0] hexc;
        input [3:0] v;
        begin
            hexc = (v < 4'd10) ? (8'h30 + {4'b0, v}) : (8'h37 + {4'b0, v});
        end
    endfunction

    function [7:0] char_of;
        input [5:0] idx;
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
                15: char_of = ",";
                16: char_of = "N";
                17: char_of = "=";
                18: char_of = hexc(nb_l);
                19: char_of = ",";
                20: char_of = "D";
                21: char_of = "=";
                22: char_of = hexc(dtw_l);
                23: char_of = ",";
                24: char_of = "F";
                25: char_of = "=";
                26: char_of = hexc(f1_l);
                27: char_of = hexc(f2_l);
                28: char_of = CR;
                29: char_of = LF;
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
            nb_l <= 4'd0; dtw_l <= 4'd0; f1_l <= 4'd0; f2_l <= 4'd0;
            pend_mode <= 8'd0; pend_tone <= 8'd0;
            pend_score <= 8'd0; pend_stars <= 8'd0;
            pend_nb <= 4'd0; pend_dtw <= 4'd0; pend_f1 <= 4'd0; pend_f2 <= 4'd0;
            pend <= 1'b0;
            send_index <= 6'd0;
            tx_start_r <= 1'b0;
        end else begin
            case (state)
            ST_IDLE: begin
                tx_start_r <= 1'b0;
                send_index <= 6'd0;
                if (score_event) begin
                    mode_q <= {5'd0, mode};
                    tone_q <= {5'd0, tone};
                    score_q <= {1'b0, score};
                    stars_q <= {6'd0, stars};
                    nb_l <= {1'b0, nb_tone};
                    dtw_l <= {1'b0, dtw_tone};
                    f1_l <= f1_band;
                    f2_l <= f2_band;
                    state <= ST_SEND;
                end else if (pend) begin
                    mode_q <= pend_mode;
                    tone_q <= pend_tone;
                    score_q <= pend_score;
                    stars_q <= pend_stars;
                    nb_l <= pend_nb;
                    dtw_l <= pend_dtw;
                    f1_l <= pend_f1;
                    f2_l <= pend_f2;
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
                    pend_nb <= {1'b0, nb_tone};
                    pend_dtw <= {1'b0, dtw_tone};
                    pend_f1 <= f1_band;
                    pend_f2 <= f2_band;
                    pend <= 1'b1;
                end
                if (tx_done)
                    send_index <= send_index + 1'b1;
                if (send_index >= MSG_LEN) begin
                    tx_start_r <= 1'b0;
                    send_index <= 6'd0;
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
