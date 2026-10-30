`timescale 1ns/1ps

module status_osd_overlay #(
    parameter integer OSD_X = 8,
    parameter integer OSD_Y = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire [1:0]  active_index,
    input  wire        auto_enabled,
    input  wire [7:0]  error_code,
    // Detected tone of the last scored attempt: 1..4, or 0 for "no rule
    // fired". Shown in a fifth cell so a bench session can read the
    // classifier's decision directly instead of inferring it from the star
    // count. Registering it here (rather than sampling it combinationally)
    // matters: the cell must keep the value the moment it was latched, and
    // it must survive the whole frame, exactly as active_index does.
    input  wire [2:0]  tone_code,
    input  wire        in_de,
    input  wire [11:0] in_rgb,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    output reg  [11:0] out_rgb,
    output reg         out_de,
    output wire        osd_pixel
);
    reg [1:0] index_q;
    reg auto_q;
    reg [7:0] error_q;
    reg [2:0] tone_q;
    reg osd_hit;
    reg [3:0] char_value;
    reg [2:0] char_row;
    reg [2:0] char_col;
    reg [4:0] glyph_row;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            index_q <= 2'd0;
            auto_q <= 1'b0;
            error_q <= 8'd0;
            tone_q <= 3'd0;
        end else if (frame_start) begin
            index_q <= active_index;
            auto_q <= auto_enabled;
            error_q <= error_code;
            tone_q <= tone_code;
        end
    end

    function [4:0] font_row;
        input [3:0] value;
        input [2:0] row;
        begin
            case (value)
                4'h0: case(row) 0:font_row=5'b11111;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b10001;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b11111; endcase
                4'h1: case(row) 0:font_row=5'b00100;1:font_row=5'b01100;2:font_row=5'b00100;3:font_row=5'b00100;4:font_row=5'b00100;5:font_row=5'b00100;default:font_row=5'b11111; endcase
                4'h2: case(row) 0:font_row=5'b11111;1:font_row=5'b00001;2:font_row=5'b00001;3:font_row=5'b11111;4:font_row=5'b10000;5:font_row=5'b10000;default:font_row=5'b11111; endcase
                4'h3: case(row) 0:font_row=5'b11111;1:font_row=5'b00001;2:font_row=5'b00001;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11111; endcase
                4'h4: case(row) 0:font_row=5'b10001;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b00001; endcase
                4'h5: case(row) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11111; endcase
                4'h6: case(row) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b11111;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b11111; endcase
                4'h7: case(row) 0:font_row=5'b11111;1:font_row=5'b00001;2:font_row=5'b00010;3:font_row=5'b00100;4:font_row=5'b01000;5:font_row=5'b01000;default:font_row=5'b01000; endcase
                4'h8: case(row) 0:font_row=5'b11111;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11111;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b11111; endcase
                4'h9: case(row) 0:font_row=5'b11111;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11111;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11111; endcase
                4'ha: case(row) 0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b11111;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b10001; endcase
                4'he: case(row) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b11110;4:font_row=5'b10000;5:font_row=5'b10000;default:font_row=5'b11111; endcase
                4'hf: case(row) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b11110;4:font_row=5'b10000;5:font_row=5'b10000;default:font_row=5'b10000; endcase
                default: font_row = 5'b00000;
            endcase
        end
    endfunction

    always @* begin
        osd_hit = 1'b0;
        char_value = 4'h0;
        char_row = pixel_y - OSD_Y;
        char_col = pixel_x - OSD_X;
        glyph_row = 5'b00000;
        if (pixel_x >= OSD_X && pixel_x < OSD_X + 40 &&
            pixel_y >= OSD_Y && pixel_y < OSD_Y + 8) begin
            case ((pixel_x - OSD_X) / 8)
                0: char_value = {2'b00, index_q} + 1'b1;
                1: char_value = auto_q ? 4'ha : 4'he;
                2: char_value = error_q[7:4];
                3: char_value = error_q[3:0];
                // cell 4: tone digit, 0 for "no rule fired". A blank glyph
                // (4'h0 renders as a full box, so '0' is used for none) --
                // the value is a digit so the same font table serves it.
                4: char_value = {1'b0, tone_q};
                default: char_value = 4'h0;
            endcase
            glyph_row = font_row(char_value, char_row);
            if ((pixel_x - OSD_X) % 8 < 5 && char_row < 7)
                osd_hit = glyph_row[4 - ((pixel_x - OSD_X) % 8)];
        end
        out_de = in_de;
        out_rgb = in_rgb;
        if (in_de && osd_hit)
            out_rgb = error_q == 0 ? 12'hff0 : 12'hf44;
    end

    assign osd_pixel = osd_hit && in_de;
endmodule
