`timescale 1ns/1ps

// Board B lookup classifier: replaces the rule cascade with a trained
// lookup table. R76 dual-board architecture.
//
// The classifier takes 5 features (each quantised to 3 bits) and produces
// a tone classification (1..4, 0 = abstain) from a 32768 x 3 bit lookup
// table stored in BRAM (~13 BRAM9k; docs/03 resource plan).
//
// Feature quantisation (from golden model analysis of 1418-clip corpus):
//   rng       [2:0] : 0=<24, 1=<48, 2=<96, 3=<192, 4=<384, 5=<768, 6=else, 7=X
//   delta     [2:0] : signed, 0=<-192, 1=<-96, 2=<-48, 3=<0, 4=<48, 5=<96, 6=<192, 7=else
//   dip       [2:0] : 0=<6, 1=<12, 2=<24, 3=<48, 4=<96, 5=<192, 6=else, 7=X
//   tail_rise [2:0] : same scale as dip
//   argmin    [2:0] : 0=<2, 1=<4, 2=<6, 3=<8, 4=<10, 5=<12, 6=<14, 7=else
//
// Address = {rng[2:0], delta[2:0], dip[2:0], tail[2:0], argmin[2:0]} = 15 bits
// Table: 32768 × 8 bit = 32 KB → 29 BRAM9k
// Table content: trained offline from 1418-clip corpus (Python golden → .hex)
//
// The table is loaded from a .hex file at synthesis time (initial block).
// Training script: tools/train_classifier.py (generates the .hex file).
module lookup_classifier #(
    parameter HEX_FILE = "classifier_lut.hex"
) (
    input  wire       clk,
    input  wire       rst_n,
    // feature inputs (from UART RX, one set per utterance)
    input  wire       feat_valid,          // 1-clk pulse when features are ready
    input  wire [11:0] rng,                // Q4 peak-to-peak
    input  wire signed [11:0] delta,       // Q4 end minus start
    input  wire [11:0] dip,                // Q4 dip depth
    input  wire [11:0] tail_rise,          // Q4 tail rise
    input  wire [3:0] argmin,              // argmin bin index (0..15)
    // classification output
    output reg        result_valid,
    output reg  [2:0] tone,                // 1..4 (0 = indeterminate)
    output reg  [1:0] confidence           // 0..3 (higher = more certain)
);
    // ---- feature quantisation ----
    // Each 12-bit feature is quantised to 3 bits using a logarithmic scale.
    // The quantisation boundaries are chosen to match the actual feature
    // distributions observed in the 1418-clip corpus (see R77 §2).

    function [2:0] quant_rng;
        input [11:0] v;
        begin
            if      (v < 12'd24)   quant_rng = 3'd0;
            else if (v < 12'd48)   quant_rng = 3'd1;
            else if (v < 12'd96)   quant_rng = 3'd2;
            else if (v < 12'd192)  quant_rng = 3'd3;
            else if (v < 12'd384)  quant_rng = 3'd4;
            else if (v < 12'd768)  quant_rng = 3'd5;
            else                   quant_rng = 3'd6;
        end
    endfunction

    function [2:0] quant_delta;
        input signed [11:0] v;
        begin
            if      (v < -12'sd192)  quant_delta = 3'd0;
            else if (v < -12'sd96)   quant_delta = 3'd1;
            else if (v < -12'sd48)   quant_delta = 3'd2;
            else if (v < 12'sd0)     quant_delta = 3'd3;
            else if (v < 12'sd48)    quant_delta = 3'd4;
            else if (v < 12'sd96)    quant_delta = 3'd5;
            else if (v < 12'sd192)   quant_delta = 3'd6;
            else                     quant_delta = 3'd7;
        end
    endfunction

    function [2:0] quant_dip;
        input [11:0] v;
        begin
            if      (v < 12'd6)    quant_dip = 3'd0;
            else if (v < 12'd12)   quant_dip = 3'd1;
            else if (v < 12'd24)   quant_dip = 3'd2;
            else if (v < 12'd48)   quant_dip = 3'd3;
            else if (v < 12'd96)   quant_dip = 3'd4;
            else if (v < 12'd192)  quant_dip = 3'd5;
            else                   quant_dip = 3'd6;
        end
    endfunction

    function [2:0] quant_tail;
        input [11:0] v;
        begin
            if      (v < 12'd6)    quant_tail = 3'd0;
            else if (v < 12'd12)   quant_tail = 3'd1;
            else if (v < 12'd24)   quant_tail = 3'd2;
            else if (v < 12'd48)   quant_tail = 3'd3;
            else if (v < 12'd96)   quant_tail = 3'd4;
            else if (v < 12'd192)  quant_tail = 3'd5;
            else                   quant_tail = 3'd6;
        end
    endfunction

    function [2:0] quant_argmin;
        input [3:0] v;
        begin
            if      (v < 4'd2)   quant_argmin = 3'd0;
            else if (v < 4'd4)   quant_argmin = 3'd1;
            else if (v < 4'd6)   quant_argmin = 3'd2;
            else if (v < 4'd8)   quant_argmin = 3'd3;
            else if (v < 4'd10)  quant_argmin = 3'd4;
            else if (v < 4'd12)  quant_argmin = 3'd5;
            else if (v < 4'd14)  quant_argmin = 3'd6;
            else                 quant_argmin = 3'd7;
        end
    endfunction

    // ---- address computation ----
    wire [2:0] q_rng   = quant_rng(rng);
    wire [2:0] q_delta = quant_delta(delta);
    wire [2:0] q_dip   = quant_dip(dip);
    wire [2:0] q_tail  = quant_tail(tail_rise);
    wire [2:0] q_arg   = quant_argmin(argmin);

    wire [14:0] lut_addr = {q_rng, q_delta, q_dip, q_tail, q_arg};

    // ---- lookup table BRAM ----
    // 32768 x 3 bit = 12 KB -> ~13 BRAM9k. The stored value is the tone
    // (0 = abstain, 1..4). Confidence lives only in the training report:
    // storing it would push the table to 5 bits/entry (~18 BRAM) and Board B
    // past its 64 BRAM9k budget (docs/03 plans exactly this 3-bit form).
    // Content: trained offline (tools/train_classifier.py), loaded from the
    // .hex at synthesis. For TD the hex must sit in the TD project directory.
    reg [2:0] lut [0:32767];
    initial begin
        $readmemh(HEX_FILE, lut);
    end

    reg [2:0] lut_q;
    always @(posedge clk) begin
        if (!rst_n)
            lut_q <= 3'd0;
        else
            lut_q <= lut[lut_addr];
    end

    // ---- output decode ----
    //
    // Two-stage aligner. Cycle N: feat_valid=1, the feature registers are
    // stable, lut_addr is correct and lut_q loads at the N -> N+1 edge.
    // Cycle N+1: lut_q holds the lookup result; feat_pending latches it into
    // tone. Cycle N+2: result_valid pulses WITH the matching tone -- same
    // edge, no skew. An earlier draft pulsed result_valid one cycle before
    // tone updated (the consumer read the previous utterance's tone) and
    // also re-assigned tone from lut_q every idle cycle (tone tracked
    // whatever was on the address wires); both are fixed by gating every
    // capture on feat_pending.
    reg feat_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feat_pending <= 1'b0;
            result_valid <= 1'b0;
            tone         <= 3'd0;
            confidence   <= 2'd0;
        end else begin
            feat_pending <= feat_valid;
            result_valid <= feat_pending;
            if (feat_pending) begin
                tone       <= lut_q;
                confidence <= 2'd0;        // not stored in the 3-bit table
            end
        end
    end
endmodule
