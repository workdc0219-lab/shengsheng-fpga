`timescale 1ns/1ps
// F1/F3 unit glyphs (题/星) for the summary score strip -- GENERATED
// by tools/make_badge_rom.py - do not edit by hand. Reached through
// PH_C_TI / PH_C_XING descriptors (stride bit 6 = badge-ROM select).
// 256 x 8; every address the descriptors can reach (base 0/128 +
// 31 rows x 3 B stride + col < 8) lands below 224.
module ss_badge_rom (
    input  wire        clk,
    input  wire        ce,
    input  wire [7:0]  addr,
    output reg  [7:0]  data
);
    reg [7:0] rom [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) rom[i] = 8'h00;
        // C_TI '题' base 0 width 24 stride 3
        // C_XING '星' base 128 width 24 stride 3
        rom[21] = 8'h04;
        rom[22] = 8'h2f;
        rom[23] = 8'hf8;
        rom[24] = 8'h0f;
        rom[25] = 8'hef;
        rom[26] = 8'hf8;
        rom[27] = 8'h0c;
        rom[28] = 8'h61;
        rom[29] = 8'h80;
        rom[30] = 8'h0f;
        rom[31] = 8'he1;
        rom[33] = 8'h0f;
        rom[34] = 8'hef;
        rom[35] = 8'hf0;
        rom[36] = 8'h0c;
        rom[37] = 8'h6f;
        rom[38] = 8'hf0;
        rom[39] = 8'h0f;
        rom[40] = 8'hed;
        rom[41] = 8'hb0;
        rom[42] = 8'h07;
        rom[43] = 8'hed;
        rom[44] = 8'hb0;
        rom[45] = 8'h1f;
        rom[46] = 8'hfd;
        rom[47] = 8'hb0;
        rom[48] = 8'h1f;
        rom[49] = 8'hfd;
        rom[50] = 8'hb0;
        rom[51] = 8'h01;
        rom[52] = 8'h8d;
        rom[53] = 8'hb0;
        rom[54] = 8'h07;
        rom[55] = 8'he5;
        rom[56] = 8'hb0;
        rom[57] = 8'h0d;
        rom[58] = 8'hf3;
        rom[59] = 8'he0;
        rom[60] = 8'h0d;
        rom[61] = 8'h87;
        rom[62] = 8'h70;
        rom[63] = 8'h0f;
        rom[64] = 8'h9e;
        rom[65] = 8'h30;
        rom[66] = 8'h1f;
        rom[67] = 8'h8c;
        rom[68] = 8'h10;
        rom[69] = 8'h19;
        rom[70] = 8'hff;
        rom[71] = 8'hf8;
        rom[72] = 8'h10;
        rom[73] = 8'h7f;
        rom[74] = 8'hf8;
        rom[152] = 8'h03;
        rom[153] = 8'hff;
        rom[154] = 8'hc0;
        rom[155] = 8'h03;
        rom[156] = 8'hff;
        rom[157] = 8'hc0;
        rom[158] = 8'h03;
        rom[160] = 8'hc0;
        rom[161] = 8'h03;
        rom[162] = 8'hff;
        rom[163] = 8'hc0;
        rom[164] = 8'h03;
        rom[166] = 8'hc0;
        rom[167] = 8'h03;
        rom[168] = 8'hff;
        rom[169] = 8'hc0;
        rom[170] = 8'h03;
        rom[171] = 8'hff;
        rom[172] = 8'hc0;
        rom[173] = 8'h03;
        rom[174] = 8'h1c;
        rom[176] = 8'h03;
        rom[177] = 8'h18;
        rom[179] = 8'h07;
        rom[180] = 8'hff;
        rom[181] = 8'hf0;
        rom[182] = 8'h07;
        rom[183] = 8'hff;
        rom[184] = 8'he0;
        rom[185] = 8'h0f;
        rom[186] = 8'hfc;
        rom[188] = 8'h0b;
        rom[189] = 8'hff;
        rom[190] = 8'he0;
        rom[192] = 8'h18;
        rom[195] = 8'h18;
        rom[197] = 8'h1f;
        rom[198] = 8'hff;
        rom[199] = 8'hf8;
        rom[200] = 8'h1f;
        rom[201] = 8'hff;
        rom[202] = 8'hf8;
    end
    always @(posedge clk) if (ce) data <= rom[addr];
endmodule
