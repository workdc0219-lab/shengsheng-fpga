`timescale 1ns/1ps

// KEY4 parameter menu. A short press cycles the volume through five steps;
// holding the key for one second before release cycles the slideshow period
// through four steps in media mode, or cycles the independent base difficulty
// in training. Settings are volatile; no Flash persistence is requested here.
// V8 (ENABLE_CONTRAST=1): a short press that STARTS while contrast_select is
// high steps the picture contrast through five levels (50..150 %) instead of
// the volume; it raises menu_event with menu_kind 3 and no cfg_update_valid,
// so the player configuration is not re-applied. 0 keeps the V7 behaviour.
module param_menu_controller #(
    parameter integer CLKS_PER_MS = 50000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer LONG_HOLD_MS = 1000,
    parameter integer ENABLE_CONTRAST = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key4_n,
    input  wire        service_ready,
    input  wire        training_mode,
    input  wire [7:0]  live_volume,
    input  wire [31:0] live_period_ms,
    input  wire        contrast_select,
    output reg  [2:0]  contrast,    // 0..4 = 50, 75, 100, 125, 150 %
    output reg         cfg_update_valid,
    output reg  [31:0] cfg_period_ms,
    output reg  [7:0]  cfg_volume,
    output reg         menu_event,
    output reg  [1:0]  difficulty,  // independent base difficulty, default medium
    output reg  [1:0]  menu_kind,   // 0 = volume, 1 = media period, 2 = difficulty, 3 = contrast
    output reg  [3:0]  menu_level   // new level index for reporting
);
    localparam integer VOLUME_STEPS = 5;
    localparam integer PERIOD_STEPS = 4;

    reg [7:0] volume_lut [0:VOLUME_STEPS-1];
    reg [31:0] period_lut [0:PERIOD_STEPS-1];
    initial begin
        volume_lut[0] = 8'd0;   volume_lut[1] = 8'd64;
        volume_lut[2] = 8'd128; volume_lut[3] = 8'd192;
        volume_lut[4] = 8'd255;
        period_lut[0] = 32'd2000;  period_lut[1] = 32'd5000;
        period_lut[2] = 32'd10000; period_lut[3] = 32'd30000;
    end

    function [3:0] volume_level;
        input [7:0] value;
        begin
            case (value)
                8'd0:   volume_level = 4'd0;
                8'd64:  volume_level = 4'd1;
                8'd128: volume_level = 4'd2;
                8'd192: volume_level = 4'd3;
                default: volume_level = 4'd4;
            endcase
        end
    endfunction

    function [3:0] period_level;
        input [31:0] value;
        begin
            if (value < 32'd3500)       period_level = 4'd0;
            else if (value < 32'd7500)  period_level = 4'd1;
            else if (value < 32'd20000) period_level = 4'd2;
            else                        period_level = 4'd3;
        end
    endfunction

    // Debounce plus press-duration measurement on the raw active-low key.
    reg [1:0] sync;
    reg raw_state;
    reg [19:0] debounce_count;
    reg stable_state;
    reg [31:0] hold_count;
    reg press_active;
    reg long_marked;
    reg press_training;
    reg press_contrast;
    reg [3:0] lvl_next;

    wire pressed_now = (stable_state == 1'b0);
    wire hold_reached = (hold_count >= LONG_HOLD_MS * CLKS_PER_MS);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync <= 2'b11;
            raw_state <= 1'b1;
            debounce_count <= 20'd0;
            stable_state <= 1'b1;
            hold_count <= 32'd0;
            press_active <= 1'b0;
            long_marked <= 1'b0;
            press_training <= 1'b0;
            press_contrast <= 1'b0;
            contrast <= 3'd2;
            difficulty <= 2'd1;
            cfg_update_valid <= 1'b0;
            cfg_period_ms <= 32'd5000;
            cfg_volume <= 8'd64;
            menu_event <= 1'b0;
            menu_kind <= 2'd0;
            menu_level <= 4'd0;
        end else begin
            cfg_update_valid <= 1'b0;
            menu_event <= 1'b0;

            sync <= {sync[0], key4_n};
            if (sync[1] != raw_state) begin
                if (debounce_count >= DEBOUNCE_MS * CLKS_PER_MS - 1) begin
                    raw_state <= sync[1];
                    stable_state <= sync[1];
                    debounce_count <= 20'd0;
                end else begin
                    debounce_count <= debounce_count + 1'b1;
                end
            end else begin
                debounce_count <= 20'd0;
            end

            if (!press_active) begin
                if (pressed_now) begin
                    press_active <= 1'b1;
                    hold_count <= 32'd0;
                    long_marked <= 1'b0;
                    press_training <= training_mode;
                    press_contrast <= (ENABLE_CONTRAST != 0) && contrast_select;
                end
            end else begin
                if (!pressed_now) begin
                    press_active <= 1'b0;
                    if (service_ready) begin
                        cfg_period_ms <= live_period_ms;
                        cfg_volume <= live_volume;
                        if (long_marked) begin
                            if (press_training) begin
                                difficulty <= difficulty + 2'd1;
                                menu_level <= {2'd0, difficulty + 2'd1};
                                menu_kind <= 2'd2;
                            end else begin
                                lvl_next = period_level(live_period_ms);
                                lvl_next = (lvl_next == PERIOD_STEPS-1) ? 4'd0 : lvl_next + 1'b1;
                                menu_level <= lvl_next;
                                cfg_period_ms <= period_lut[lvl_next];
                                menu_kind <= 2'd1;
                            end
                        end else if (press_contrast) begin
                            contrast <= (contrast == 3'd4) ? 3'd0 : contrast + 1'b1;
                            menu_level <= (contrast == 3'd4) ? 4'd0 : {1'b0, contrast} + 1'b1;
                            menu_kind <= 2'd3;
                        end else begin
                            lvl_next = volume_level(live_volume);
                            lvl_next = (lvl_next == VOLUME_STEPS-1) ? 4'd0 : lvl_next + 1'b1;
                            menu_level <= lvl_next;
                            cfg_volume <= volume_lut[lvl_next];
                            menu_kind <= 2'd0;
                        end
                        menu_event <= 1'b1;
                        cfg_update_valid <= long_marked || !press_contrast;
                    end
                    hold_count <= 32'd0;
                end else begin
                    if (hold_count < LONG_HOLD_MS * CLKS_PER_MS)
                        hold_count <= hold_count + 1'b1;
                    if (hold_reached)
                        long_marked <= 1'b1;
                end
            end
        end
    end
endmodule
