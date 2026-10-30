`timescale 1ns/1ps

module promax_text_overlay #(
    parameter integer PARAM_X = 8,
    parameter integer PARAM_Y = 40,
    parameter integer SUBTITLE_Y = 72,
    parameter integer H_ACTIVE = 640
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire        subtitle_enable,
    input  wire [95:0] subtitle_text,
    input  wire [5:0]  subtitle_length,
    input  wire [7:0]  brightness,
    input  wire [7:0]  volume,
    input  wire [31:0] period_ms,
    input  wire        auto_enabled,
    input  wire        source_scale_2x,
    input  wire        training_mode,
    input  wire [1:0]  base_difficulty,
    output wire [23:0] rgb_out,
    output wire        overlay_active
);
    localparam integer CELL_W = 12;
    localparam integer CELL_H = 16;
    localparam integer SUBTITLE_CELL_W = 18;
    localparam integer SUBTITLE_CELL_H = 18;
    localparam integer PARAM_CHARS = 32;
    localparam integer SCROLL_CYCLE = H_ACTIVE + 128;
    localparam integer SUBTITLE_BAND_Y = SUBTITLE_Y;
    localparam integer SUBTITLE_BAND_BOTTOM = SUBTITLE_Y + SUBTITLE_CELL_H + 2;
    wire [9:0] subtitle_width = subtitle_length * SUBTITLE_CELL_W;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    reg [9:0] scroll_pos;
    reg [1:0] scroll_div;
    reg [7:0] brightness_frame;
    reg [7:0] volume_frame;
    reg [31:0] period_frame;
    reg auto_frame;
    reg source_scale_2x_frame;
    reg training_frame;
    reg [1:0] difficulty_frame;
    wire frame_start = vs_q && !vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            scroll_pos <= 10'd0;
            scroll_div <= 2'd0;
            brightness_frame <= 8'd255;
            volume_frame <= 8'd255;
            period_frame <= 32'd5000;
            auto_frame <= 1'b0;
            source_scale_2x_frame <= 1'b0;
            training_frame <= 1'b0;
            difficulty_frame <= 2'd1;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                brightness_frame <= brightness;
                volume_frame <= volume;
                period_frame <= period_ms;
                auto_frame <= auto_enabled;
                source_scale_2x_frame <= source_scale_2x;
                training_frame <= training_mode;
                difficulty_frame <= base_difficulty;
                if (scroll_div == 2'd2) begin
                    scroll_div <= 2'd0;
                    scroll_pos <= (scroll_pos == SCROLL_CYCLE-1) ?
                                  10'd0 : scroll_pos + 1'b1;
                end else begin
                    scroll_div <= scroll_div + 1'b1;
                end
            end
        end
    end

    function [7:0] decimal_hundreds;
        input [7:0] value;
        begin
            decimal_hundreds = "0" + value / 100;
        end
    endfunction

    localparam [255:0] CN_GLYPH_0 = 256'b0000000100000000000000010000000011111111111111100000000100000000011111111111110000000000000000000011111111111000001000010000100000100001000010000011111111111000001000000000000000100000000000000010000000000000010000000000000001000000000000001000000000000000;
    localparam [255:0] CN_GLYPH_1 = 256'b0000000011111000011111110000000000000001000000000011111111111000000000100000000011111111111111100000010000000000000010000000000000011111111100000010100000010000010011111111000010001000000100000000111111110000000010000001000000001111111100000000100000010000;
    localparam [255:0] CN_GLYPH_2 = 256'b0000000000000000000111111111000000010000000100000001000000010000000100010001000000010001000100000001000100010000000100010001000000010001000100000001001010010000000100101001000000000100100000000000010010000000000010001000001000110000100000101100000001111110;
    localparam [255:0] CN_GLYPH_3 = 256'b0000000100000000000000100000000000000100000000000001111111110000000100000001000000010000000100000001000000010000000111111111000000010000000100000001000000010000000111111111000000010000000100000001000000010000000100000001000000011111111100000001000000010000;
    localparam [255:0] CN_GLYPH_4 = 256'b0000000000000000001111111111000000000000000100000000000000010000000000000001000000000000000100000000000000010000001111111111000000100000000000000010000000000000001000000000000000100000000001000010000000000100001000000000010000011111111111000000000000000000;
    localparam [255:0] CN_GLYPH_5 = 256'b0001000001000000000100000100000000100000010000000111111001111100010000101000010001000010100001000100001100000100010000100100010001111110001001000100001000100100010000100000010001000010000001000100001000000100011111100000010001000010001010000000000000010000;
    localparam [255:0] CN_GLYPH_6 = 256'b0000001000000000000000010000000000111111111110000000000000000000000010000010000000000100010000001111111111111110000000000000000000011111111100000001000000010000000100000001000000011111111100000001000000010000000100000001000000011111111100000001000000010000;
    localparam [255:0] CN_GLYPH_7 = 256'b0001000001000000000100000100000000100111111111000010000010000000010010001000000011111011111000000001000100100000001000100010000001000011111111001111100000100000010000010010100000000001001001000001101000100010111001000010001001000000101000000000000001000000;
    localparam [255:0] CN_GLYPH_8 = 256'b0000000000000000011111111111100000000000000010000000000000001000000010000000100000000100000010000000001000001000000000100000100000000000011010000000000110001000000011100000100001110000000010000010000000001000000000000000100000000000010100000000000000100000;

    function [15:0] chinese_glyph_row;
        input [3:0] glyph_id;
        input [3:0] row;
        reg [255:0] glyph_bits;
        begin
            case (glyph_id)
                4'd0: glyph_bits = CN_GLYPH_0;
                4'd1: glyph_bits = CN_GLYPH_1;
                4'd2: glyph_bits = CN_GLYPH_2;
                4'd3: glyph_bits = CN_GLYPH_3;
                4'd4: glyph_bits = CN_GLYPH_4;
                4'd5: glyph_bits = CN_GLYPH_5;
                4'd6: glyph_bits = CN_GLYPH_6;
                4'd7: glyph_bits = CN_GLYPH_7;
                4'd8: glyph_bits = CN_GLYPH_8;
                default: glyph_bits = 256'b0;
            endcase
            chinese_glyph_row = glyph_bits[255-row*16 -: 16];
        end
    endfunction

    function [7:0] decimal_tens;
        input [7:0] value;
        begin
            decimal_tens = "0" + (value % 100) / 10;
        end
    endfunction

    function [7:0] decimal_ones;
        input [7:0] value;
        begin
            decimal_ones = "0" + value % 10;
        end
    endfunction

    function [7:0] param_char;
        input integer index;
        reg [7:0] bright_percent;
        reg [7:0] period_seconds;
        begin
            case (brightness_frame)
                8'd255: bright_percent = 8'd100;
                8'd192: bright_percent = 8'd75;
                8'd128: bright_percent = 8'd50;
                default: bright_percent = 8'd25;
            endcase
            if (period_frame >= 30000)
                period_seconds = 8'd30;
            else if (period_frame >= 10000)
                period_seconds = 8'd10;
            else if (period_frame >= 5000)
                period_seconds = 8'd5;
            else
                period_seconds = 8'd2;

            case (index)
                0: param_char = "B";  1: param_char = "R";
                2: param_char = "T";
                3: param_char = decimal_hundreds(bright_percent);
                4: param_char = decimal_tens(bright_percent);
                5: param_char = decimal_ones(bright_percent);
                6: param_char = " ";  7: param_char = "V";
                8: param_char = "O";  9: param_char = "L";
                10: param_char = decimal_hundreds(volume_frame);
                11: param_char = decimal_tens(volume_frame);
                12: param_char = decimal_ones(volume_frame);
                13: param_char = " ";  14: param_char = training_frame ? "D" : "P";
                15: param_char = training_frame ? "I" : decimal_tens(period_seconds);
                16: param_char = training_frame ? "F" : decimal_ones(period_seconds);
                17: param_char = training_frame ? "F" : "S";
                18: param_char = training_frame ? ":" : " ";
                19: param_char = training_frame ? (8'h31 + {6'd0, difficulty_frame}) : "M";
                20: param_char = training_frame ? " " : ":";
                21: param_char = training_frame ? " " : (auto_frame ? "A" : "M");
                22: param_char = source_scale_2x_frame ? "1" : "6";
                23: param_char = source_scale_2x_frame ? "2" : "4";
                24: param_char = source_scale_2x_frame ? "8" : "0";
                25: param_char = source_scale_2x_frame ? "0" : "X";
                26: param_char = source_scale_2x_frame ? "X" : "4";
                27: param_char = source_scale_2x_frame ? "9" : "8";
                28: param_char = source_scale_2x_frame ? "6" : "0";
                29: param_char = source_scale_2x_frame ? "0" : " ";
                default: param_char = " ";
            endcase
        end
    endfunction

    function [7:0] subtitle_char;
        input integer index;
        begin
            if (index >= 0 && index < subtitle_length)
                subtitle_char = subtitle_text[index*8 +: 8];
            else
                subtitle_char = " ";
        end
    endfunction

    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010;default:glyph_row=0;endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111;default:glyph_row=0;endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "I": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "J": case(row) 0:glyph_row=5'b00111;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00010;4:glyph_row=5'b10010;5:glyph_row=5'b10010;6:glyph_row=5'b01100;default:glyph_row=0;endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                "Q": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10101;5:glyph_row=5'b10010;6:glyph_row=5'b01101;default:glyph_row=0;endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110;default:glyph_row=0;endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110;default:glyph_row=0;endcase
                "V": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b01010;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "W": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10101;4:glyph_row=5'b10101;5:glyph_row=5'b10101;6:glyph_row=5'b01010;default:glyph_row=0;endcase
                "X": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b01010;5:glyph_row=5'b10001;6:glyph_row=5'b10001;default:glyph_row=0;endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                "Z": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b10000;6:glyph_row=5'b11111;default:glyph_row=0;endcase
                ":": case(row) 1:glyph_row=5'b00100;2:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                ".": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b00100;default:glyph_row=0;endcase
                ",": case(row) 5:glyph_row=5'b00100;6:glyph_row=5'b01000;default:glyph_row=0;endcase
                "!": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "?": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;5:glyph_row=5'b00100;default:glyph_row=0;endcase
                "-": case(row) 3:glyph_row=5'b11111;default:glyph_row=0;endcase
                "_": case(row) 6:glyph_row=5'b11111;default:glyph_row=0;endcase
                "/": case(row) 0:glyph_row=5'b00001;1:glyph_row=5'b00010;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b10000;default:glyph_row=0;endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    integer param_local_x;
    integer param_cell;
    integer param_col;
    integer subtitle_stream_x;
    integer subtitle_cell;
    integer subtitle_col;
    reg [7:0] selected_char;
    reg [4:0] selected_row;
    reg [15:0] selected_chinese_row;
    reg param_pixel;
    reg param_band_pixel;
    reg subtitle_pixel;
    reg subtitle_band_pixel;

    always @* begin
        param_local_x = pixel_x - PARAM_X;
        param_cell = 0;
        param_col = 0;
        subtitle_stream_x = pixel_x + scroll_pos;
        if (subtitle_stream_x >= SCROLL_CYCLE)
            subtitle_stream_x = subtitle_stream_x - SCROLL_CYCLE;
        subtitle_cell = 0;
        subtitle_col = 0;
        selected_char = " ";
        selected_row = 5'b00000;
        selected_chinese_row = 16'b0;
        param_pixel = 1'b0;
        param_band_pixel = 1'b0;
        subtitle_pixel = 1'b0;
        subtitle_band_pixel = 1'b0;

        if (enable && de && pixel_x >= PARAM_X &&
            pixel_x < PARAM_X + PARAM_CHARS*CELL_W &&
            line_y >= PARAM_Y && line_y < PARAM_Y + CELL_H) begin
            param_band_pixel = 1'b1;
            param_cell = param_local_x / CELL_W;
            param_col = (param_local_x - param_cell*CELL_W) >> 1;
            if (param_col < 5 && ((line_y-PARAM_Y) >> 1) < 7) begin
                selected_char = param_char(param_cell);
                selected_row = glyph_row(selected_char, (line_y-PARAM_Y) >> 1);
                param_pixel = selected_row[4-param_col];
            end
        end

        if (enable && subtitle_enable && de &&
            pixel_x >= 8 && pixel_x < H_ACTIVE-8 &&
            line_y >= SUBTITLE_BAND_Y && line_y < SUBTITLE_BAND_BOTTOM)
            subtitle_band_pixel = 1'b1;

        if (enable && subtitle_enable && de &&
            pixel_x >= 8 && pixel_x < H_ACTIVE-8 &&
            line_y >= SUBTITLE_Y && line_y < SUBTITLE_Y + SUBTITLE_CELL_H &&
            subtitle_stream_x < subtitle_width) begin
            subtitle_cell = subtitle_stream_x / SUBTITLE_CELL_W;
            subtitle_col = subtitle_stream_x - subtitle_cell*SUBTITLE_CELL_W;
            selected_char = subtitle_char(subtitle_cell);
            if (selected_char[7]) begin
                if (subtitle_col >= 1 && subtitle_col < 17 &&
                    line_y >= SUBTITLE_Y+2 && line_y < SUBTITLE_Y+18) begin
                    selected_chinese_row = chinese_glyph_row(
                        selected_char[3:0], line_y-SUBTITLE_Y-2);
                    subtitle_pixel = selected_chinese_row[16-subtitle_col];
                end
            end else if (subtitle_col >= 4 && subtitle_col < 14 &&
                         line_y >= SUBTITLE_Y+2 && line_y < SUBTITLE_Y+16) begin
                selected_row = glyph_row(selected_char, (line_y-SUBTITLE_Y-2) >> 1);
                subtitle_pixel = selected_row[4-((subtitle_col-4) >> 1)];
            end
        end
    end

    assign overlay_active = param_pixel || param_band_pixel || subtitle_pixel || subtitle_band_pixel;
    assign rgb_out = overlay_active ?
                     ((subtitle_pixel || param_pixel) ? 24'h493F35 : 24'hFFF6E9) : rgb_in;
endmodule
