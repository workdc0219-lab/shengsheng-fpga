`timescale 1ns/1ps
// shengsheng_game teacher-demo path (docs/14 section 1), module level.
//   A. teacher_on = 0: INTRO ends with the model voice (syn mode 1), as v5.
//   B. teacher_on = 1 + a curve: no model voice; DEMO -> GUARD on the curve;
//      the redrawn target mountain's 16 segments carry clamp_y(off + level)
//      bit-exact (level 64 for tone 1); tch_used = 1.
//   C. teacher_on = 1, no curve: model voice after 480 frames, mountain from
//      the template, tch_used = 0.
module tb_game_teacher;
    reg clk = 1'b0;
    always #20 clk = ~clk;
    reg rst_n = 1'b0;

    reg [2:0] mode = 3'd0;
    reg trk_valid = 1'b0;
    reg teacher_on = 1'b0, tch_new = 1'b0;
    reg [127:0] tch_off = 128'd0;
    reg syn_playing = 1'b0;
    wire syn_cmd_valid;
    wire [2:0] syn_cmd_mode, syn_cmd_tone, phase_o;
    wire cmd_valid, cmd_buf, cmd_vis, tch_used;
    wire [8:0] cmd_x0;
    wire [3:0] cmd_log2n;
    wire [7:0] cmd_y0, cmd_y1;

    shengsheng_game dut (
        .clk(clk), .rst_n(rst_n), .mode(mode), .key_next(1'b0), .key_replay(1'b0),
        .difficulty(2'd1), .active_index(2'd1),
        .ui_tick(trk_valid), .link_up(1'b1), .tch_armed(1'b1),
        .trk_valid(trk_valid), .trk_voiced(1'b0), .trk_pitch(10'd0), .trk_level(8'd0),
        .sc_valid(1'b0), .sc_active(1'b0), .sc_short(1'b0), .sc_score(7'd0), .sc_stars(2'd0),
        .sc_hint(3'd0), .sc_mean(10'd0), .sc_bins(160'd0), .sc_point_valid(1'b0),
        .sc_point_index(7'd0), .sc_point_value(10'd0),
        .sc_arm(), .sc_target(), .sc_enable(),
        .syn_playing(syn_playing), .syn_progress(8'd0), .syn_done(1'b0),
        .syn_cmd_valid(syn_cmd_valid), .syn_cmd_mode(syn_cmd_mode), .syn_cmd_tone(syn_cmd_tone),
        .goto_valid(), .goto_index(), .training(), .celebrate(), .listen_meter(),
        .eff_diff(), .panel_show(), .child_show(), .target_reveal(), .ball_show(),
        .ball_col(), .ball_y(), .balloon_show(), .balloon_r(), .train_show(),
        .train_x(), .meter_level(), .win_lo(), .win_hi(), .meter_ok(), .card_show(),
        .card_index(), .s0_id(), .s1_id(), .s2_cells(), .s3_id(), .s3_class(),
        .cmd_valid(cmd_valid), .cmd_ready(1'b1), .cmd_buf(cmd_buf), .cmd_x0(cmd_x0),
        .cmd_log2n(cmd_log2n), .cmd_y0(cmd_y0), .cmd_y1(cmd_y1), .cmd_vis(cmd_vis),
        .teacher_on(teacher_on), .tch_new(tch_new), .tch_off(tch_off),
        .phase_o(phase_o), .tch_used(tch_used)
    );

    // model voice monitor: syn mode 1 = the demo
    integer demo_cmds = 0;
    always @(posedge clk) if (syn_cmd_valid && syn_cmd_mode == 3'd1) demo_cmds = demo_cmds + 1;

    // target-mountain segment capture (job 2 = buf 0, log2n 5, visible)
    reg [7:0] seg_y0 [0:15];
    reg [7:0] seg_y1 [0:15];
    integer n_seg = 0;
    always @(posedge clk)
        if (cmd_valid && !cmd_buf && cmd_log2n == 4'd5 && cmd_vis) begin
            seg_y0[cmd_x0[8:5]] = cmd_y0; seg_y1[cmd_x0[8:5]] = cmd_y1;
            n_seg = n_seg + 1;
        end

    function [7:0] clamp_y;
        input integer off;
        integer v;
        begin
            v = 128 - off - (off >>> 1);
            clamp_y = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
        end
    endfunction

    task frames;
        input integer n;
        integer f;
        begin
            for (f = 0; f < n; f = f + 1) begin
                @(posedge clk); trk_valid <= 1'b1;
                @(posedge clk); trk_valid <= 1'b0;
                repeat (60) @(posedge clk);
            end
        end
    endtask

    integer errors = 0, k, d0, pk;
    reg signed [7:0] o;
    initial begin
        #200 rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ---------------- A: no teacher
        mode = 3'd1; frames(40);
        if (demo_cmds != 1 || phase_o != 3'd1) begin
            errors = errors + 1; $display("ERROR A demo_cmds=%0d phase=%0d", demo_cmds, phase_o);
        end
        frames(5);                           // syn_playing stays 0 -> GUARD
        if (phase_o != 3'd2 || tch_used) begin
            errors = errors + 1; $display("ERROR A phase=%0d tch_used=%b", phase_o, tch_used);
        end

        // ---------------- B: teacher with a curve
        mode = 3'd0; frames(2);
        teacher_on = 1'b1; demo_cmds = 0;
        for (k = 0; k < 16; k = k + 1) begin
            o = (k * 37 % 200) - 100;        // spread incl. negatives
            if (k == 5) o = 8'sd127;          // clamps y at 0 with level 64
            tch_off[k*8 +: 8] = o;
        end
        mode = 3'd1; frames(40);             // INTRO (36) -> DEMO wait
        if (demo_cmds != 0 || phase_o != 3'd1) begin
            errors = errors + 1; $display("ERROR B demo_cmds=%0d phase=%0d", demo_cmds, phase_o);
        end
        frames(30);                          // still waiting
        if (phase_o != 3'd1) begin errors = errors + 1; $display("ERROR B left DEMO without a curve"); end
        n_seg = 0;
        @(posedge clk); tch_new <= 1'b1; @(posedge clk); tch_new <= 1'b0;
        frames(3);
        if (phase_o != 3'd2 || !tch_used || n_seg != 16) begin
            errors = errors + 1; $display("ERROR B phase=%0d tch_used=%b segs=%0d", phase_o, tch_used, n_seg);
        end
        d0 = $signed(tch_off[7:0]) + 64;
        if (seg_y0[0] !== clamp_y(d0)) begin
            errors = errors + 1; $display("ERROR B seg0 y0=%0d exp=%0d", seg_y0[0], clamp_y(d0));
        end
        for (k = 0; k < 16; k = k + 1) begin
            pk = (k == 15) ? 15 : k + 1;
            d0 = $signed(tch_off[pk*8 +: 8]) + 64;
            if (seg_y1[k] !== clamp_y(d0)) begin
                errors = errors + 1; $display("ERROR B seg%0d y1=%0d exp=%0d", k, seg_y1[k], clamp_y(d0));
            end
        end
        if (demo_cmds != 0) begin errors = errors + 1; $display("ERROR B model voice played"); end

        // ---------------- C: teacher on, no curve -> timeout fallback
        mode = 3'd0; frames(2);
        demo_cmds = 0;
        mode = 3'd1; frames(40);
        if (demo_cmds != 0) begin errors = errors + 1; $display("ERROR C early model voice"); end
        frames(430);                         // DEMO ~434 frames < 480 timeout
        if (demo_cmds != 0) begin errors = errors + 1; $display("ERROR C model voice before timeout"); end
        frames(60);                          // past 480
        if (demo_cmds != 1 || tch_used) begin
            errors = errors + 1; $display("ERROR C demo_cmds=%0d tch_used=%b", demo_cmds, tch_used);
        end
        frames(5);
        if (phase_o < 3'd2) begin errors = errors + 1; $display("ERROR C stuck phase=%0d", phase_o); end

        if (errors == 0) $display("SS_GAME_TEACHER_PASS");
        else $display("SS_GAME_TEACHER_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
