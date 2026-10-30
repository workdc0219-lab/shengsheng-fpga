`timescale 1ns/1ps
// Microphone front end on the EG4S20 on-chip SAR ADC (TN304).
//
// The ADC runs from a divide-by-two copy of the 25 MHz video clock
// (12.5 MHz <= 16 MHz fmax). A free-running counter in that domain issues
// one SOC every SOC_PERIOD ADC clocks (125 kS/s with the default 100, above
// the TN304 100 kS/s floor). Each EOC captures dout into a holding register
// and toggles a flag; the video domain synchronises the flag and reads the
// held code, which then stays stable for a full conversion period.
//
// Video-domain processing (bit-exact with tools/shengsheng/golden.py
// Frontend): eight codes are summed into one 15.625 kHz single-channel
// sample (7.8125 kHz per channel when TIME_MUX=1), a 1/1024
// leaky integrator seeded from the first sum removes the bias, and the
// difference is doubled and saturated to signed 16 bits.
module mic_adc_frontend #(
    parameter integer SOC_PERIOD = 100,
    parameter [2:0]   CHANNEL = 3'd2,           // J1 pin 15 = L10 = ADC_CH_2
    parameter         VREF_MODE = "ENABLE",
    parameter integer CLIP_LO = 420,            // 0.1*VREF plus margin
    parameter integer CLIP_HI = 3680,           // 0.9*VREF minus margin
    // R81 dual-player: TIME_MUX=1 alternates every SOC between CHANNEL and
    // CHANNEL_B on the single hard ADC (each channel 62.5 kS/s -> 7.8 kS/s
    // after the 8-accumulate). TIME_MUX=0 is bit-identical to the
    // single-channel behaviour the single-board suites validated.
    parameter integer TIME_MUX = 0,
    parameter [2:0]   CHANNEL_B = 3'd3
) (
    input  wire               clk,
    input  wire               rst_n,
    output reg                sample_valid,
    output reg  signed [15:0] sample,
    output reg                clip,             // a code left the linear range
    output reg  [11:0]        raw_code,
    // channel-B stream (TIME_MUX only; held at 0 otherwise)
    output reg                sample_valid_b,
    output reg  signed [15:0] sample_b,
    output reg                clip_b
);
    // ---------------------------------------------------------- ADC domain
    reg adc_clk_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            adc_clk_div <= 1'b0;
        else
            adc_clk_div <= ~adc_clk_div;
    end
    wire adc_clk = adc_clk_div;

    reg [1:0] adc_rst_sync;
    always @(posedge adc_clk or negedge rst_n) begin
        if (!rst_n)
            adc_rst_sync <= 2'b00;
        else
            adc_rst_sync <= {adc_rst_sync[0], 1'b1};
    end
    wire adc_rst_n = adc_rst_sync[1];

    reg [7:0] soc_count;
    reg adc_soc;
    reg [11:0] held_code;
    reg done_toggle;
    wire adc_eoc;
    wire [11:0] adc_dout;
    reg soc_side;                         // channel being programmed next
    reg conv_sel;                         // channel of the conversion in flight
    reg [11:0] held_code_b;
    reg done_toggle_b;

    always @(posedge adc_clk or negedge adc_rst_n) begin
        if (!adc_rst_n) begin
            soc_count <= 8'd0;
            held_code <= 12'd2048;
            done_toggle <= 1'b0;
            held_code_b <= 12'd2048;
            done_toggle_b <= 1'b0;
        end else begin
            soc_count <= (soc_count == SOC_PERIOD - 1) ? 8'd0 : soc_count + 1'b1;
            if (adc_eoc) begin
                if (TIME_MUX && conv_sel) begin
                    held_code_b <= adc_dout;
                    done_toggle_b <= ~done_toggle_b;
                end else begin
                    held_code <= adc_dout;
                    done_toggle <= ~done_toggle;
                end
            end
        end
    end

    // The ADC macro models a 10 ns hold on its soc pin against the rising edge
    // that samples it, so a rising-edge launch leaves only the register's
    // clock-to-out and is reported as a multi-nanosecond hold violation.
    // Launching on the falling edge centres the one-period pulse on the
    // sampling edge instead: it arrives half a period early and stays for a
    // full period, which also keeps the sim model's conversion schedule (it
    // samples soc at the same rising edge either way).
    always @(negedge adc_clk or negedge adc_rst_n) begin
        if (!adc_rst_n) begin
            adc_soc <= 1'b0;
            soc_side <= 1'b0;
            conv_sel <= 1'b0;
        end else begin
            adc_soc <= (soc_count == 8'd0);
            if (TIME_MUX && soc_count == 8'd0) begin
                soc_side <= ~soc_side;       // channel of the NEXT conversion
                conv_sel <= ~soc_side;
            end
        end
    end

    EG_PHY_ADC #(
        .CH0((CHANNEL == 3'd0 || (TIME_MUX && CHANNEL_B == 3'd0)) ? "ENABLE" : "DISABLE"),
        .CH1((CHANNEL == 3'd1 || (TIME_MUX && CHANNEL_B == 3'd1)) ? "ENABLE" : "DISABLE"),
        .CH2((CHANNEL == 3'd2 || (TIME_MUX && CHANNEL_B == 3'd2)) ? "ENABLE" : "DISABLE"),
        .CH3((CHANNEL == 3'd3 || (TIME_MUX && CHANNEL_B == 3'd3)) ? "ENABLE" : "DISABLE"),
        .CH4((CHANNEL == 3'd4 || (TIME_MUX && CHANNEL_B == 3'd4)) ? "ENABLE" : "DISABLE"),
        .CH5((CHANNEL == 3'd5 || (TIME_MUX && CHANNEL_B == 3'd5)) ? "ENABLE" : "DISABLE"),
        .CH6((CHANNEL == 3'd6 || (TIME_MUX && CHANNEL_B == 3'd6)) ? "ENABLE" : "DISABLE"),
        .CH7((CHANNEL == 3'd7 || (TIME_MUX && CHANNEL_B == 3'd7)) ? "ENABLE" : "DISABLE"),
        .VREF(VREF_MODE)
    ) u_adc (
        .clk(adc_clk), .pd(1'b0),
        .s(TIME_MUX ? (soc_side ? CHANNEL_B : CHANNEL) : CHANNEL),
        .soc(adc_soc), .eoc(adc_eoc), .dout(adc_dout)
    );

    // -------------------------------------------------------- video domain
    reg done_s1, done_s2, done_s3;
    reg [2:0] code_count;
    reg [14:0] code_acc;
    reg [25:0] dc_acc;
    reg seeded;
    reg clip_any;

    // channel-B mirror (TIME_MUX only)
    reg done_s1b, done_s2b, done_s3b;
    reg [2:0] code_count_b;
    reg [14:0] code_acc_b;
    reg [25:0] dc_acc_b;
    reg seeded_b;
    reg clip_any_b;

    wire code_strobe = done_s2 ^ done_s3;
    wire [11:0] code = held_code;       // stable: changed >= 2 clocks earlier
    wire code_clip = (code < CLIP_LO) || (code > CLIP_HI);
    wire [14:0] total = code_acc + code;
    wire [14:0] dc = seeded ? dc_acc[24:10] : total;
    wire signed [16:0] diff = $signed({2'b00, total}) - $signed({2'b00, dc});
    wire signed [17:0] doubled = {diff, 1'b0};

    wire code_strobe_b = done_s2b ^ done_s3b;
    wire [11:0] code_b = held_code_b;
    wire code_clip_b = (code_b < CLIP_LO) || (code_b > CLIP_HI);
    wire [14:0] total_b = code_acc_b + code_b;
    wire [14:0] dc_b = seeded_b ? dc_acc_b[24:10] : total_b;
    wire signed [16:0] diff_b = $signed({2'b00, total_b}) - $signed({2'b00, dc_b});
    wire signed [17:0] doubled_b = {diff_b, 1'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_s1 <= 1'b0;
            done_s2 <= 1'b0;
            done_s3 <= 1'b0;
            code_count <= 3'd0;
            code_acc <= 15'd0;
            dc_acc <= 26'd0;
            seeded <= 1'b0;
            clip_any <= 1'b0;
            sample_valid <= 1'b0;
            sample <= 16'sd0;
            clip <= 1'b0;
            raw_code <= 12'd0;
        end else begin
            done_s1 <= done_toggle;
            done_s2 <= done_s1;
            done_s3 <= done_s2;
            sample_valid <= 1'b0;
            if (code_strobe) begin
                raw_code <= code;
                if (code_count == 3'd7) begin
                    code_count <= 3'd0;
                    code_acc <= 15'd0;
                    clip <= clip_any | code_clip;
                    clip_any <= 1'b0;
                    if (seeded)
                        dc_acc <= $signed({1'b0, dc_acc}) + diff;
                    else
                        dc_acc <= {1'b0, total, 10'd0};
                    seeded <= 1'b1;
                    sample <= (doubled > 18'sd32767) ? 16'sd32767 :
                              (doubled < -18'sd32768) ? -16'sd32768 :
                              doubled[15:0];
                    sample_valid <= 1'b1;
                end else begin
                    code_count <= code_count + 1'b1;
                    code_acc <= total;
                    clip_any <= clip_any | code_clip;
                end
            end
        end
    end

    // ---------------- channel-B video path (TIME_MUX) ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_s1b <= 1'b0; done_s2b <= 1'b0; done_s3b <= 1'b0;
            code_count_b <= 3'd0; code_acc_b <= 15'd0;
            dc_acc_b <= 26'd0; seeded_b <= 1'b0; clip_any_b <= 1'b0;
            sample_valid_b <= 1'b0; sample_b <= 16'sd0; clip_b <= 1'b0;
        end else begin
            done_s1b <= done_toggle_b;
            done_s2b <= done_s1b;
            done_s3b <= done_s2b;
            sample_valid_b <= 1'b0;
            if (code_strobe_b) begin
                // raw_code stays on channel A (single diagnostic tap)
                if (code_count_b == 3'd7) begin
                    code_count_b <= 3'd0;
                    code_acc_b <= 15'd0;
                    clip_b <= clip_any_b | code_clip_b;
                    clip_any_b <= 1'b0;
                    if (seeded_b)
                        dc_acc_b <= $signed({1'b0, dc_acc_b}) + diff_b;
                    else
                        dc_acc_b <= {1'b0, total_b, 10'd0};
                    seeded_b <= 1'b1;
                    sample_b <= (doubled_b > 18'sd32767) ? 16'sd32767 :
                              (doubled_b < -18'sd32768) ? -16'sd32768 :
                              doubled_b[15:0];
                    sample_valid_b <= 1'b1;
                end else begin
                    code_count_b <= code_count_b + 1'b1;
                    code_acc_b <= total_b;
                    clip_any_b <= clip_any_b | code_clip_b;
                end
            end
        end
    end
endmodule
