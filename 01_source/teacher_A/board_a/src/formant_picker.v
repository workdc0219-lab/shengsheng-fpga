`timescale 1ns/1ps
// Formant peak picker over the 36-band grid (docs/10 §1, R81).
//
// F1 = strongest band in 240..1200 Hz (grid indices 1..17, k=4..20),
// F2 = strongest band in 1322..2524 Hz (indices 18..26), F2 index > F1.
// Only meaningful on voiced frames; the packer latches the last voiced
// frame's picks.
//
// R81 timing fix: the original combinational double peak-scan off the
// bands register was a 44 ns cone (4 setup violations). This version
// scans ONE band per clock behind an input register -- 18 clocks after
// bands_valid the picks are stable, and the comb path per cycle is a
// single 8-bit compare.
module formant_picker (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bands_valid,     // 1-clk per frame from goertzel
    input  wire [287:0] bands,          // 36 x e_q, band k in [8k+7:8k]
    input  wire        voiced,
    output reg  [3:0]  f1_band,         // 0 = none
    output reg  [3:0]  f2_band
);
    // ---------------- input register (breaks the goertzel->scan edge) ----
    reg [287:0] bands_q;
    reg         scan_en;                 // scanning bands_q
    reg         scan_voiced;
    reg [5:0]   scan_k;                  // current band 1..26
    reg [3:0]   f1_run, f2_run;          // running picks
    reg [7:0]   f1_val, f2_val;          // running peak values
    reg [7:0]   b_left;                  // previous band value (left neighbour)
    reg [1:0]   phase;                   // 0 idle, 1 f1 range, 2 f2 range

    wire [7:0] b_cur = bands_q[scan_k*8 +: 8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bands_q <= 288'd0;
            scan_en <= 1'b0; scan_voiced <= 1'b0; scan_k <= 6'd0;
            f1_run <= 4'd0; f2_run <= 4'd0;
            f1_val <= 8'd0; f2_val <= 8'd0;
            b_left <= 8'd0; phase <= 2'd0;
            f1_band <= 4'd0; f2_band <= 4'd0;
        end else begin
            // latch + start a scan on every frame (voiced checked at commit)
            if (bands_valid) begin
                bands_q    <= bands;
                scan_en    <= 1'b1;
                scan_voiced<= voiced;
                scan_k     <= 6'd1;
                phase      <= 2'd1;
                f1_run     <= 4'd0; f2_run <= 4'd0;
                f1_val     <= 8'd0; f2_val <= 8'd0;
                b_left     <= bands[7:0];          // band 0 as left neighbour
            end else if (scan_en) begin
                // local maximum vs left (b_left) and right (next band reg)
                if (phase == 2'd1) begin
                    if (b_cur > f1_val && b_cur > b_left &&
                        b_cur > bands_q[(scan_k + 1)*8 +: 8]) begin
                        f1_val <= b_cur;
                        f1_run <= scan_k[3:0];
                    end
                    if (scan_k == 6'd17) begin
                        phase <= 2'd2;
                        scan_k <= 6'd18;
                        b_left <= bands_q[17*8 +: 8];
                    end else begin
                        b_left <= b_cur;
                        scan_k <= scan_k + 1'b1;
                    end
                end else begin // phase 2: indices 18..26
                    if (b_cur > f2_val && b_cur > b_left &&
                        b_cur > bands_q[(scan_k + 1)*8 +: 8]) begin
                        f2_val <= b_cur;
                        f2_run <= scan_k[3:0];
                    end
                    if (scan_k == 6'd26) begin
                        scan_en <= 1'b0;
                        if (scan_voiced) begin
                            f1_band <= f1_run;
                            f2_band <= f2_run;
                        end
                    end else begin
                        b_left <= b_cur;
                        scan_k <= scan_k + 1'b1;
                    end
                end
            end
        end
    end
endmodule
