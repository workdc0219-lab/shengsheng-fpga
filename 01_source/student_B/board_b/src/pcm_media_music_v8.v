`timescale 1ns/1ps

// V8 display-mode music (F4). Replaces pcm_media_tone in the product. Each
// picture keeps its V7 six-note melody as the lead (plus octave and double-
// octave partials), over a bass + fifth pad on the chord root and a short
// noise "hat" at every note, so the 16-band spectrum drawn over the picture
// shows several moving bands instead of one. Bit-exact with
// tools/model_f4_v8.py (class Music); constants in spectrum_v8_tables.vh.
//
// One sample per 48 kHz tick: the state the sample depends on is
// snapshotted on the tick edge, then an 11-step sequencer that shares one
// 64-entry sine table and one envelope-gain unit computes it and pushes it
// 11 clocks after the tick into the same 8-entry FIFO / valid-ready contract
// as pcm_media_tone, so the HDMI audio path is unchanged. Volume scales the
// mix with one multiplier, as before.
// A picture change reloads the 100 ms cue blip and restarts the melody on
// the clock after the change (one clock later still if that is a tick).
module pcm_media_music_v8 #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [1:0]         media_id,
    input  wire [7:0]         volume,
    output wire               sample_valid,
    input  wire               sample_ready,
    output wire signed [15:0] sample_left,
    output wire signed [15:0] sample_right,
    output reg                overflow,
    output wire               blip_active
);
`include "spectrum_v8_tables.vh"

    // envelope gain: 1, 3/4, 1/2, 3/8, 1/4, 3/16, 1/8, 3/32, then silent
    function signed [17:0] env_gain;
        input signed [17:0] x;
        input [5:0] idx;
        reg [1:0] a;
        begin
            a = idx[2:1];
            if (idx >= 6'd8)
                env_gain = 18'sd0;
            else if (!idx[0])
                env_gain = x >>> a;
            else
                env_gain = (x >>> (a + 1)) + (x >>> (a + 2));
        end
    endfunction

    // ---------------------------------------------------- 48 kHz tick
    reg [24:0] rate_accumulator;
    wire sample_tick = rate_accumulator >= CLOCK_HZ - SAMPLE_HZ;

    // ---------------------------------------------------- voice state
    reg [19:0] mel_ph, bass_ph, pad_ph;
    reg [2:0]  note;
    reg [14:0] count;
    reg [12:0] blip;
    reg [1:0]  media_q;
    reg [15:0] lfsr;
    reg signed [11:0] n_prev;
    wire signed [15:0] lfsr_s = lfsr;
    wire signed [11:0] n_now = lfsr_s >>> 4;               // 12-bit noise
    wire [2:0] mel_env  = count[13:11];                     // count < 12000
    wire [2:0] bass_env = (note[0] ? 3'd3 : 3'd0) + {1'b0, count[13:12]};
    wire [5:0] hat_env  = count[13:8];
    assign blip_active = (blip != 13'd0);

    // ---------------------------------------------------- tick snapshot
    reg [7:0]  s_mel;          // mel_ph[19:12]
    reg [5:0]  s_bass, s_pad;
    reg signed [12:0] s_hp;
    reg [2:0]  s_menv, s_benv;
    reg [5:0]  s_henv;
    reg        s_blip;
    reg [7:0]  s_vol;

    // ---------------------------------------------------- sequencer
    reg [3:0] st;
    reg signed [17:0] r_mel, r_lead, r_low, r_mix;
    reg signed [26:0] r_prod;
    reg [5:0] sine_idx;
    always @* begin
        case (st)
            4'd1:    sine_idx = s_mel[7:2];   // mel_ph >> 14
            4'd2:    sine_idx = s_mel[6:1];   // mel_ph >> 13
            4'd3:    sine_idx = s_mel[5:0];   // mel_ph >> 12
            4'd4:    sine_idx = s_bass;
            default: sine_idx = s_pad;
        endcase
    end
    wire signed [13:0] sv = f4_sine64(sine_idx);
    wire signed [17:0] sv18 = sv;
    reg signed [17:0] g_x;
    reg [5:0] g_idx;
    always @* begin
        case (st)
            4'd6:    begin g_x = r_lead;  g_idx = {3'd0, s_menv}; end
            4'd7:    begin g_x = r_low;   g_idx = {3'd0, s_benv}; end
            default: begin g_x = s_hp;    g_idx = s_henv; end
        endcase
    end
    wire signed [17:0] g_out = env_gain(g_x, g_idx);
    wire signed [18:0] scaled = r_prod >>> 8;
    wire signed [15:0] clamped = (scaled > 19'sd32767)  ? 16'sd32767 :
                                 (scaled < -19'sd32768) ? -16'sd32768 : scaled[15:0];
    wire push_now = (st == 4'd11);

    // ---------------------------------------------------- FIFO (as V7)
    reg signed [15:0] fifo [0:7];
    reg [2:0] write_pointer;
    reg [2:0] read_pointer;
    reg [3:0] fifo_count;
    assign sample_valid = fifo_count != 0;
    assign sample_left = fifo[read_pointer];
    assign sample_right = fifo[read_pointer];
    wire sample_pop = sample_valid && sample_ready;
    wire sample_push = push_now && (fifo_count != 8 || sample_pop);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rate_accumulator <= 25'd0;
            mel_ph <= 20'd0; bass_ph <= 20'd0; pad_ph <= 20'd0;
            note <= 3'd0; count <= 15'd0; blip <= 13'd0; media_q <= 2'd0;
            lfsr <= 16'hACE1; n_prev <= 12'sd0;
            s_mel <= 8'd0; s_bass <= 6'd0; s_pad <= 6'd0; s_hp <= 13'sd0;
            s_menv <= 3'd0; s_benv <= 3'd0; s_henv <= 6'd0; s_blip <= 1'b0; s_vol <= 8'd0;
            st <= 4'd0;
            r_mel <= 18'sd0; r_lead <= 18'sd0; r_low <= 18'sd0; r_mix <= 18'sd0;
            r_prod <= 27'sd0;
            write_pointer <= 3'd0; read_pointer <= 3'd0; fifo_count <= 4'd0;
            overflow <= 1'b0;
        end else begin
            if (sample_tick)
                rate_accumulator <= rate_accumulator + SAMPLE_HZ - CLOCK_HZ;
            else
                rate_accumulator <= rate_accumulator + SAMPLE_HZ;

            if (sample_tick) begin
                // snapshot (pre-update state) and launch the sequencer
                s_mel <= mel_ph[19:12]; s_bass <= bass_ph[19:14]; s_pad <= pad_ph[19:14];
                s_hp <= n_now - n_prev;
                s_menv <= mel_env; s_benv <= bass_env; s_henv <= hat_env;
                s_blip <= blip_active; s_vol <= volume;
                st <= 4'd1;
                // state update
                mel_ph <= mel_ph + (blip_active ? F4_BLIP_INC : f4_melody_inc({media_q, note}));
                bass_ph <= bass_ph + f4_bass_inc(media_q);
                pad_ph <= pad_ph + f4_pad_inc(media_q);
                n_prev <= n_now;
                lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3]};
                if (blip_active)
                    blip <= blip - 1'b1;
                else if (count >= F4_NOTE_LAST) begin
                    count <= 15'd0;
                    note <= (note == 3'd5) ? 3'd0 : note + 1'b1;
                end else
                    count <= count + 1'b1;
            end else begin
                if (media_id != media_q) begin
                    blip <= F4_BLIP_SAMPLES;
                    note <= 3'd0;
                    count <= 15'd0;
                    media_q <= media_id;
                end
                case (st)
                    4'd1: begin r_mel <= sv18; r_lead <= sv18; end
                    4'd2: r_lead <= r_lead + (sv18 >>> 2);
                    4'd3: r_lead <= r_lead + (sv18 >>> 2);
                    4'd4: r_low <= sv18;
                    4'd5: r_low <= r_low + (sv18 >>> 2);
                    4'd6: r_mix <= g_out;
                    4'd7: r_mix <= r_mix + g_out;
                    4'd8: r_mix <= r_mix + g_out;
                    4'd9: r_mix <= s_blip ? r_mel : r_mix + (r_mix >>> 2);
                    4'd10: r_prod <= r_mix * $signed({1'b0, s_vol});
                    default: ;
                endcase
                if (st != 4'd0)
                    st <= (st == 4'd11) ? 4'd0 : st + 1'b1;
            end

            if (sample_push) begin
                fifo[write_pointer] <= clamped;
                write_pointer <= write_pointer + 1'b1;
            end else if (push_now)
                overflow <= 1'b1;
            if (sample_pop)
                read_pointer <= read_pointer + 1'b1;
            case ({sample_push, sample_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end
endmodule
