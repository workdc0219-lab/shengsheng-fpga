`timescale 1ns/1ps
// Diagnostic reference ONLY: 750 Hz sine if sample_valid is exactly 48 kHz.
// Phase advances on the SAME sample-valid consumed by the HDMI core. This
// intentionally does not bypass/test-fix the production sample cadence or ACR.
// Fixed peak amplitude 4096 (~1/8 full scale), independent of music volume.
module audio_reference_d3 (
    input wire clk, rst_n, sample_valid,
    output wire signed [15:0] sample
);
    `include "spectrum_v8_tables.vh"
    reg [5:0] phase;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) phase <= 0;
        else if (sample_valid) phase <= phase + 1'b1;
    wire signed [13:0] sine = f4_sine64(phase);
    assign sample = $signed(sine) >>> 1;
endmodule
