`timescale 1ns/1ps
// AGC tap for the SPECTRAL path (docs/10 §1, R81).
//
// Normalises the signal feeding goertzel_32band toward a target RMS so the
// band energies carry shape, not recording level, in noisy rooms. Feed-forward
// gain: every frame the mean |sample| is compared to the target and the gain
// BOOST-ONLY in practice (audit 2026-10-05): quiet inputs rail gain up// multiplies samples as a barrel shift (no multiplier).
//
// CRITICAL: this tap is NOT in the pitch-tracker path -- the tracker stays
// bit-exact with the golden model. Only the spectral/VQ features see AGC.
module agc_tap (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,
    input  wire signed [15:0] sample,      // raw front-end sample
    input  wire               frame_tick,   // 60 Hz gain update
    output wire signed [15:0] agc_sample,   // gain-shifted sample
    output wire               agc_ovf       // gain railed at max
);
    // TARGET is the per-frame mean|x| (full-scale units) the AGC holds.
    // CALIBRATION (audit P1-2): ACC_TARGET must equal
    //   TARGET/256 * SAMPLES_PER_FRAME
    // -- the original 6100 assumed 260 samples/frame; the DIAG build's
    // TIME_MUX=1 halves that to 130, so the top passes the halved values.
    parameter integer TARGET = 6000;
    parameter integer ACC_TARGET = 6100;

    reg [15:0] acc;                         // sum |x| >> 8
    reg [2:0]  gain;                        // shift left amount 0..7
    reg        gain_up;                     // 1: shift left, 0: right

    // audit P1-2: saturate the shifted result -- at gain 7 any |x|>=256
    // used to wrap 16-bit and feed sign-flipped garbage into the spectrum
    // 23 bits: 32767 << 7 = 4194176 must fit BEFORE the clamp -- the first
    // cut used 19 bits and wrapped for |s| >= 4096 at gain 7, defeating the
    // saturation for exactly the loud onsets it was protecting
    wire signed [22:0] agc_shifted = gain_up ? ($signed(sample) <<< gain)
                                             : ($signed(sample) >>> gain);
    assign agc_sample = (gain_up && agc_shifted > 23'sd32767)  ? 16'sd32767 :
                        (gain_up && agc_shifted < -23'sd32768) ? -16'sd32768 :
                        agc_shifted[15:0];
    assign agc_ovf = gain_up && (gain == 3'd7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= 16'd0; gain <= 3'd0; gain_up <= 1'b0;
        end else begin
            if (sample_valid)
                acc <= acc + {8'd0, (sample[15] ? (~sample[15:8] + 1'b1)
                                                : sample[15:8])};
            if (frame_tick) begin
                // audit note (2026-10-05): this bang-bang is BOOST-ONLY in
                // practice -- from gain_up=0/gain=0 a hot frame matches no
                // branch (attenuation never engages), and inside the
                // gain_up=0 region the two directions are inverted (hot =>
                // gain-1 = LOUDER). Net behavior: quiet inputs rail up to
                // x128 and stay there; loud inputs sit at unity. Bounded by
                // the 23-bit clamp, DIAG-only path. A real two-way AGC is a
                // redesign (docs/16 ledger) -- do not "fix" the branches
                // without re-deriving the whole loop.
                if (acc > ACC_TARGET + ACC_TARGET/4 && !gain_up && gain != 0)
                    gain <= gain - 1'b1;            // (inverted: actually louder)
                else if (acc > ACC_TARGET + ACC_TARGET/4 && gain_up)
                    gain_up <= 1'b0;                // cross down
                else if (acc < ACC_TARGET - ACC_TARGET/4) begin
                    if (!gain_up && gain == 3'd0)
                        gain_up <= 1'b1;            // cross up
                    else if (gain != 3'd7)
                        gain <= gain + 1'b1;        // (inverted region: actually quieter)
                end
                acc <= 16'd0;
            end
        end
    end
endmodule
