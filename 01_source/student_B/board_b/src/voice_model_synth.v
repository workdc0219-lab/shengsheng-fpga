`timescale 1ns/1ps
// Model-voice and feedback-sound synthesiser, bit-exact with
// tools/shengsheng/golden.py Synth. docs/40 section 2.4.
//
// mode 1 = tone demo (six-harmonic hum following the 16-point template of
//          `tone`, 256 sub-steps, ramp-in/ramp-out envelope)
// mode 2 = "ding" (C6+G6), mode 3 = soft prompt (G4), mode 4 = "pop" noise
// The sample prepared on tick N leaves on tick N+1 (sample_out holds it);
// the ~520 clocks between ticks are ample for the sequential harmonic loop.
// progress (0..255) is the current sub-step, used to reveal the target path
// in lock-step with the sound.
module voice_model_synth (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,              // 48 kHz strobe
    input  wire               cmd_valid,
    input  wire [2:0]         cmd_mode,
    input  wire [2:0]         cmd_tone,
    input  wire [7:0]         volume,
    output reg  signed [15:0] sample_out,
    output wire               playing,
    output reg  [7:0]         progress,
    output reg                done
);
`include "ss_consts.vh"
    localparam [23:0] BASE_INC = SS_BASE_INC;
    localparam [23:0] DING0 = SS_DING0_INC, DING1 = SS_DING1_INC, SOFT = SS_SOFT_INC;

    reg [2:0] mode;
    reg [2:0] tone;
    reg signed [15:0] prepared;
    reg [23:0] phase, p2;
    reg [8:0] sub;
    reg [6:0] step_cnt;
    reg [14:0] elapsed;
    reg [15:0] env16;
    reg [15:0] lfsr;
    assign playing = (mode != 3'd0);

    // ------------------------------------------------------ tables
    function [6:0] step_ticks;
        input [2:0] t;
        begin
            case (t)
                3'd3: step_ticks = 7'd112;
                3'd4: step_ticks = 7'd66;
                default: step_ticks = 7'd84;
            endcase
        end
    endfunction

    function signed [7:0] tpl;          // q4 offsets, tables.TONE_TEMPLATES
        input [2:0] t;
        input [3:0] i;
        reg signed [7:0] v;
        begin
            case (t)
            3'd2: case (i)
                0: v = 0; 1: v = 0; 2: v = 2; 3: v = 5; 4: v = 10; 5: v = 16;
                6: v = 22; 7: v = 29; 8: v = 35; 9: v = 42; 10: v = 48; 11: v = 53;
                12: v = 58; 13: v = 61; 14: v = 62; default: v = 64; endcase
            3'd3: case (i)
                0: v = 0; 1: v = -9; 2: v = -21; 3: v = -28; 4: v = -35; 5: v = -40;
                6: v = -44; 7: v = -47; 8: v = -48; 9: v = -46; 10: v = -42; 11: v = -38;
                12: v = -34; 13: v = -29; 14: v = -24; default: v = -19; endcase
            3'd4: case (i)
                0: v = 64; 1: v = 62; 2: v = 58; 3: v = 50; 4: v = 40; 5: v = 29;
                6: v = 16; 7: v = 3; 8: v = -10; 9: v = -22; 10: v = -34; 11: v = -43;
                12: v = -51; 13: v = -58; 14: v = -62; default: v = -64; endcase
            default: v = 64;
            endcase
            tpl = v;
        end
    endfunction

    // shared ROM ports
    reg [7:0] exp_addr;
    wire [15:0] exp_data;
    reg [7:0] sin_addr;
    wire [15:0] sin_data;
    ss_exp2_rom u_exp (.clk(clk), .addr(exp_addr), .data(exp_data));
    ss_sine_rom u_sin (.clk(clk), .addr(sin_addr), .data(sin_data));

    function [7:0] weight;
        input [2:0] h;
        begin
            case (h)
                3'd1: weight = 8'd154; 3'd2: weight = 8'd115; 3'd3: weight = 8'd77;
                3'd4: weight = 8'd51; 3'd5: weight = 8'd31; default: weight = 8'd0;
            endcase
        end
    endfunction

    // ------------------------------------------------------ sequencer
    localparam [3:0] Q_IDLE = 4'd0, Q_STEP = 4'd1, Q_EXP = 4'd2, Q_EXPW = 4'd3,
                     Q_INC = 4'd4, Q_HAR = 4'd5, Q_HARW = 4'd6, Q_HACC = 4'd7,
                     Q_MIX = 4'd8, Q_SFX = 4'd9, Q_SFXW = 4'd10, Q_SFX2 = 4'd11,
                     Q_SFX2W = 4'd12, Q_SFXMIX = 4'd13, Q_OUT = 4'd14;
    reg [3:0] q;
    reg [2:0] h;                       // harmonic index 0..5
    reg [1:0] quad_q;
    reg signed [26:0] acc;
    reg signed [16:0] s_sfx;
    reg signed [16:0] s_a;
    reg signed [15:0] y_pre;
    reg [7:0] env8;

    wire [8:0] sub_c = sub;
    wire [3:0] seg = sub_c[7:4];
    wire [3:0] frac = sub_c[3:0];
    wire signed [7:0] tpl_a = tpl(tone, seg);
    wire signed [7:0] tpl_b = tpl(tone, (seg == 4'd15) ? 4'd15 : seg + 1'b1);
    wire signed [12:0] tpl_d = (tpl_b - tpl_a) * $signed({1'b0, frac});
    wire signed [8:0] q_off = tpl_a + (tpl_d >>> 4);
    wire [14:0] total_ticks = {step_ticks(tone), 8'd0};

    wire signed [15:0] sin_signed = quad_q[1] ? -$signed({1'b0, sin_data[14:0]}) :
                                                 $signed({1'b0, sin_data[14:0]});
    wire [23:0] phase_h = phase * ({2'b00, h} + 4'd1);
    wire [39:0] inc_prod = {16'd0, BASE_INC} * {24'd0, exp_data};

    wire [14:0] sfx_total = (mode == 3'd2) ? 15'd24000 :
                            (mode == 3'd3) ? 15'd19200 : 15'd3840;
    wire lfsr_bit = lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5];

    // envelope for the demo: min(255, elapsed>>2, (total-elapsed)>>3)
    wire [14:0] tail = total_ticks - elapsed;
    wire [12:0] env_up = elapsed[14:2];
    wire [11:0] env_dn = tail[14:3];
    wire [12:0] env_m = (env_up < {1'b0, env_dn}) ? env_up : {1'b0, env_dn};
    wire [7:0] env_demo = (env_m > 13'd255) ? 8'd255 : env_m[7:0];

    wire signed [23:0] mix_env = y_pre * $signed({1'b0, env8});
    wire signed [15:0] y2 = mix_env[23:8];
    wire signed [24:0] mix_vol = y2 * $signed({1'b0, volume});
    wire signed [16:0] vol_out = mix_vol[24:8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= 3'd0; tone <= 3'd1; prepared <= 16'sd0; sample_out <= 16'sd0;
            phase <= 24'd0; p2 <= 24'd0; sub <= 9'd0; step_cnt <= 7'd0;
            elapsed <= 15'd0; env16 <= 16'hFFFF; lfsr <= 16'hACE1;
            progress <= 8'd0; done <= 1'b0;
            q <= Q_IDLE; h <= 3'd0; quad_q <= 2'd0;
            acc <= 27'sd0; s_sfx <= 17'sd0; s_a <= 17'sd0; y_pre <= 16'sd0;
            env8 <= 8'd0; exp_addr <= 8'd0; sin_addr <= 8'd0;
        end else begin
            done <= 1'b0;
            if (cmd_valid) begin
                mode <= cmd_mode; tone <= cmd_tone; prepared <= 16'sd0;
                phase <= 24'd0; p2 <= 24'd0; sub <= 9'd0; step_cnt <= 7'd0;
                elapsed <= 15'd0; env16 <= 16'hFFFF; lfsr <= 16'hACE1;
                progress <= 8'd0; q <= Q_IDLE;
            end else if (tick) begin
                sample_out <= prepared;
                if (mode != 3'd0) begin
                    elapsed <= elapsed + 1'b1;
                    q <= (mode == 3'd1) ? Q_STEP : Q_SFX;
                end
            end else begin
                case (q)
                Q_STEP: begin
                    if (step_cnt + 1'b1 == step_ticks(tone)) begin
                        step_cnt <= 7'd0;
                        sub <= sub + 1'b1;
                        if (sub + 1'b1 == 9'd256) begin
                            mode <= 3'd0; prepared <= 16'sd0; done <= 1'b1; q <= Q_IDLE;
                        end else begin
                            q <= Q_EXP;
                        end
                    end else begin
                        step_cnt <= step_cnt + 1'b1;
                        q <= Q_EXP;
                    end
                end
                Q_EXP: begin
                    progress <= sub[7:0];
                    exp_addr <= q_off + 9'sd96;
                    q <= Q_EXPW;
                end
                Q_EXPW: q <= Q_INC;
                Q_INC: begin
                    phase <= phase + inc_prod[37:14];
                    acc <= 27'sd0;
                    h <= 3'd0;
                    q <= Q_HAR;
                end
                Q_HAR: begin
                    sin_addr <= phase_h[22] ? ~phase_h[21:14] : phase_h[21:14];
                    quad_q <= phase_h[23:22];
                    q <= Q_HARW;
                end
                Q_HARW: q <= Q_HACC;
                Q_HACC: begin
                    acc <= acc + ((h == 3'd0) ? ($signed(sin_signed) <<< 8) :
                                  $signed(sin_signed) * $signed({1'b0, weight(h)}));
                    if (h == 3'd5) begin
                        q <= Q_MIX;
                    end else begin
                        h <= h + 1'b1;
                        q <= Q_HAR;
                    end
                end
                Q_MIX: begin
                    y_pre <= acc >>> 10;
                    env8 <= env_demo;
                    q <= Q_OUT;
                end
                Q_SFX: begin
                    if (elapsed >= sfx_total) begin
                        mode <= 3'd0; prepared <= 16'sd0; done <= 1'b1; q <= Q_IDLE;
                    end else if (mode == 3'd4) begin
                        lfsr <= {lfsr_bit, lfsr[15:1]};
                        s_sfx <= $signed({lfsr_bit, lfsr[15:1]}) >>> 1;
                        env16 <= env16 - (env16 >> 9);
                        q <= Q_SFXMIX;
                    end else begin
                        begin : blk_ph
                            reg [23:0] np;
                            np = phase + ((mode == 3'd2) ? DING0 : SOFT);
                            phase <= np;
                            sin_addr <= np[22] ? ~np[21:14] : np[21:14];
                            quad_q <= np[23:22];
                        end
                        env16 <= env16 - (env16 >> 13);
                        q <= Q_SFXW;
                    end
                end
                Q_SFXW: q <= Q_SFX2;
                Q_SFX2: begin
                    s_a <= sin_signed;
                    if (mode == 3'd2) begin
                        begin : blk_p2
                            reg [23:0] np2;
                            np2 = p2 + DING1;
                            p2 <= np2;
                            sin_addr <= np2[22] ? ~np2[21:14] : np2[21:14];
                            quad_q <= np2[23:22];
                        end
                        q <= Q_SFX2W;
                    end else begin
                        s_sfx <= sin_signed;
                        q <= Q_SFXMIX;
                    end
                end
                Q_SFX2W: q <= 4'd15;
                4'd15: begin
                    s_sfx <= (s_a + sin_signed) >>> 1;
                    q <= Q_SFXMIX;
                end
                Q_SFXMIX: begin
                    y_pre <= s_sfx[15:0];
                    env8 <= env16[15:8];
                    q <= Q_OUT;
                end
                Q_OUT: begin
                    prepared <= (vol_out > 17'sd32767) ? 16'sd32767 :
                                (vol_out < -17'sd32768) ? -16'sd32768 : vol_out[15:0];
                    q <= Q_IDLE;
                end
                default: q <= Q_IDLE;
                endcase
            end
        end
    end
endmodule
