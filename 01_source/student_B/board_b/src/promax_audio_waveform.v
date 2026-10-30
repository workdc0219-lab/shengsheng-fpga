`timescale 1ns/1ps

module promax_audio_waveform #(
    parameter integer WAVE_X = 64,
    parameter integer WAVE_Y = 400,
    parameter integer WAVE_WIDTH = 512,
    parameter integer WAVE_HEIGHT = 64,
    parameter integer DECIMATE = 12
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out,
    output wire        waveform_active
);
    localparam integer SAMPLE_COUNT = 32;
    localparam integer SAMPLE_SPACING = WAVE_WIDTH / SAMPLE_COUNT;
    localparam integer CENTER_Y = WAVE_Y + WAVE_HEIGHT/2;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    reg signed [7:0] sample_bank0 [0:SAMPLE_COUNT-1];
    reg signed [7:0] sample_bank1 [0:SAMPLE_COUNT-1];
    reg write_bank;
    reg display_bank;
    reg display_valid;
    reg [5:0] capture_count;
    reg [7:0] decimate_count;
    reg [7:0] peak_bank0;
    reg [7:0] peak_bank1;
    reg [7:0] display_peak;
    wire [7:0] sample_abs = pcm_tap_left[15] ?
                            (~pcm_tap_left[15:8] + 1'b1) : pcm_tap_left[15:8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            write_bank <= 1'b0;
            display_bank <= 1'b1;
            display_valid <= 1'b0;
            capture_count <= 6'd0;
            decimate_count <= 8'd0;
            peak_bank0 <= 8'd0;
            peak_bank1 <= 8'd0;
            display_peak <= 8'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                if (capture_count == SAMPLE_COUNT) begin
                    display_bank <= write_bank;
                    display_valid <= 1'b1;
                    display_peak <= write_bank ? peak_bank1 : peak_bank0;
                    write_bank <= ~write_bank;
                end
                capture_count <= 6'd0;
                decimate_count <= 8'd0;
                if (write_bank) peak_bank0 <= 8'd0;
                else peak_bank1 <= 8'd0;
            end else if (pcm_tap_valid && capture_count < SAMPLE_COUNT) begin
                if (decimate_count == 0) begin
                    if (write_bank)
                        sample_bank1[capture_count] <= pcm_tap_left[15:8];
                    else
                        sample_bank0[capture_count] <= pcm_tap_left[15:8];
                    capture_count <= capture_count + 1'b1;
                    decimate_count <= DECIMATE-1;
                    if (write_bank) begin
                        if (sample_abs > peak_bank1) peak_bank1 <= sample_abs;
                    end else begin
                        if (sample_abs > peak_bank0) peak_bank0 <= sample_abs;
                    end
                end else begin
                    decimate_count <= decimate_count - 1'b1;
                end
            end
        end
    end

    integer sample_index;
    integer sample_value;
    integer sample_y;
    integer peak_height;
    reg signed [7:0] selected_sample;
    reg wave_pixel;
    reg axis_pixel;
    reg peak_pixel;

    always @* begin
        sample_index = 0;
        selected_sample = 8'sd0;
        sample_value = 0;
        sample_y = CENTER_Y;
        peak_height = display_peak >> 2;
        wave_pixel = 1'b0;
        axis_pixel = 1'b0;
        peak_pixel = 1'b0;

        if (enable && de && pixel_x >= WAVE_X &&
            pixel_x < WAVE_X + WAVE_WIDTH &&
            line_y >= WAVE_Y && line_y < WAVE_Y + WAVE_HEIGHT) begin
            axis_pixel = (line_y == CENTER_Y);
            sample_index = (pixel_x-WAVE_X) / SAMPLE_SPACING;
            if (display_valid && sample_index < SAMPLE_COUNT) begin
                selected_sample = display_bank ?
                                  sample_bank1[sample_index] : sample_bank0[sample_index];
                sample_value = $signed(selected_sample);
                sample_y = CENTER_Y - sample_value/4;
                wave_pixel = (line_y >= sample_y-1 && line_y <= sample_y+1);
            end
        end

        if (enable && de && pixel_x >= WAVE_X+WAVE_WIDTH+8 &&
            pixel_x < WAVE_X+WAVE_WIDTH+16 &&
            line_y >= WAVE_Y+WAVE_HEIGHT-peak_height &&
            line_y < WAVE_Y+WAVE_HEIGHT)
            peak_pixel = 1'b1;
    end

    assign waveform_active = wave_pixel || axis_pixel || peak_pixel;
    assign rgb_out = wave_pixel ? 24'h20ff90 :
                     peak_pixel ? 24'hffb020 :
                     axis_pixel ? 24'h406060 : rgb_in;
endmodule
