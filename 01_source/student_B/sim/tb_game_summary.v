`timescale 1ns/1ps
// shengsheng_game F1 (session summary screen) at module level, tone mode.
//   * sess_q/sess_star commit completed questions and their final valid result
//   * the 10th scored question ends the FEED in PH_SUMMARY and the strip
//     fills on the summary's 3rd frame via the shared-BCD scan
//   * a too-short attempt is counted by neither total
//   * exiting (KEY2 or the 600-frame timeout) resets the session totals,
//     including sess_stars (audit P2-2), and switching modes mid-summary
//     closes the session too (audit P2-1)
// Badge milestones/persistence were DEFERRED (docs/19 D8) -- the F3 blocks
// of the first cut are gone from the game.
`include "ss_phrases.vh"
module tb_game_summary;
    reg clk = 1'b0;
    always #20 clk = ~clk;
    reg rst_n = 1'b0;

    reg [2:0] mode = 3'd0;
    reg trk_valid = 1'b0;
    reg teacher_on = 1'b0;
    reg key_next = 1'b0, key_replay = 1'b0;
    reg sc_valid = 1'b0, sc_short = 1'b0;
    reg [6:0] sc_score = 7'd80;
    reg [1:0] sc_stars = 2'd0;
    reg [2:0] sc_hint = 3'd0;

    wire [2:0] phase_o;
    wire [47:0] s2_cells;
    wire [5:0]  s0_id;
    wire [7:0]  sess_q_o, sess_star_o;
    wire summary_show;

    shengsheng_game dut (
        .clk(clk), .rst_n(rst_n), .mode(mode), .key_next(key_next),
        .key_replay(key_replay), .difficulty(2'd1), .active_index(2'd1),
        .ui_tick(trk_valid), .link_up(1'b1), .tch_armed(1'b0),
        .trk_valid(trk_valid), .trk_voiced(1'b0), .trk_pitch(10'd0),
        .trk_level(8'd0),
        .sc_valid(sc_valid), .sc_active(1'b0), .sc_short(sc_short),
        .sc_score(sc_score), .sc_stars(sc_stars), .sc_hint(sc_hint),
        .sc_mean(10'd0), .sc_bins(160'd0), .sc_point_valid(1'b0),
        .sc_point_index(7'd0), .sc_point_value(10'd0),
        .sc_arm(), .sc_target(), .sc_enable(),
        .syn_playing(1'b0), .syn_progress(8'd0), .syn_done(1'b0),
        .syn_cmd_valid(), .syn_cmd_mode(), .syn_cmd_tone(),
        .goto_valid(), .goto_index(), .training(), .celebrate(),
        .listen_meter(),
        .panel_show(), .child_show(), .target_reveal(), .ball_show(),
        .ball_col(), .ball_y(), .balloon_show(), .balloon_r(),
        .train_show(), .train_x(), .meter_level(), .win_lo(), .win_hi(),
        .meter_ok(), .card_show(), .card_index(), .eff_diff(),
        .s0_id(s0_id), .s1_id(), .s2_cells(s2_cells), .s3_id(), .s3_class(),
        .cmd_valid(), .cmd_ready(1'b1), .cmd_buf(), .cmd_x0(),
        .cmd_log2n(), .cmd_y0(), .cmd_y1(), .cmd_vis(),
        .teacher_on(teacher_on), .tch_new(1'b0), .tch_off(128'd0),
        .phase_o(phase_o), .tch_used(),
        .summary_show(summary_show), .discover_show(),
        .disc_radius_o(), .disc_hue_o(),
        .sess_q_o(sess_q_o), .sess_star_o(sess_star_o)
    );

    task frames;
        input integer n;
        integer f;
        begin
            for (f = 0; f < n; f = f + 1) begin
                @(posedge clk); trk_valid <= 1'b1;
                @(posedge clk); trk_valid <= 1'b0;
                repeat (10) @(posedge clk);
            end
        end
    endtask

    task exit_summary;
        begin
            @(posedge clk);
            key_next <= 1'b1;
            @(posedge clk);
            key_next <= 1'b0;
            frames(2);
        end
    endtask

    // one scored attempt: wait for LISTEN, inject sc_valid, wait out FEED.
    // If the attempt completes a session the task RETURNS WITH THE SUMMARY
    // UP so the caller can inspect the strip.
    task auto_score;
        input [1:0] st;
        input sh;
        integer guard;
        begin
            if (summary_show) exit_summary;
            guard = 0;
            while (phase_o != 3'd3 && guard < 900) begin
                frames(1); guard = guard + 1;
            end
            frames(2);
            @(posedge clk);
            sc_stars <= st; sc_short <= sh;
            sc_valid <= 1'b1;
            @(posedge clk);
            sc_valid <= 1'b0;
            guard = 0;
            while ((phase_o != 3'd4) && guard < 60) begin
                frames(1); guard = guard + 1;
            end
            guard = 0;
            while ((phase_o == 3'd4) && guard < 300) begin
                frames(1); guard = guard + 1;
            end
            frames(2);
        end
    endtask

    integer errors = 0;
    integer n_scored = 0;
    integer k;
    reg [47:0] expect_cells;
    initial begin
        #200 rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // r1: 3 stars; one too-short attempt must not count
        mode = 3'd1; frames(40);
        auto_score(2'd3, 1'b0); n_scored = n_scored + 1;
        if (sess_q_o !== 8'd1 || sess_star_o !== 8'd3) begin
            errors = errors + 1;
            $display("SS_SUM ERROR r1 sess_q=%0d sess_star=%0d",
                     sess_q_o, sess_star_o);
        end
        auto_score(2'd0, 1'b1);
        if (sess_q_o !== 8'd1 || sess_star_o !== 8'd3) begin
            errors = errors + 1;
            $display("SS_SUM ERROR short attempt counted: %0d/%0d",
                     sess_q_o, sess_star_o);
        end

        // r2..r10: 2 stars each -> summary on the 10th scored question
        for (k = 0; k < 9; k = k + 1) begin
            auto_score(2'd2, 1'b0); n_scored = n_scored + 1;
        end
        if (sess_q_o !== 8'd10 || sess_star_o !== 8'd21) begin
            errors = errors + 1;
            $display("SS_SUM ERROR r10 totals %0d/%0d", sess_q_o, sess_star_o);
        end
        if (!summary_show || phase_o != 3'd5) begin
            errors = errors + 1;
            $display("SS_SUM ERROR summary not shown (phase=%0d)", phase_o);
        end
        frames(4);   // the strip fills on the summary's 3rd frame (BCD scan)
        // "10题21★" scoreboard style (star tens always shown)
        expect_cells = {PH_BLANK, PH_C_STAR, PH_C_1, PH_C_2, PH_BLANK,
                        PH_C_QUESTIONS, PH_C_0, PH_C_1};
        if (s2_cells !== expect_cells) begin
            errors = errors + 1;
            $display("SS_SUM ERROR summary cells=%h exp=%h", s2_cells,
                     expect_cells);
        end

        // KEY2 exit: totals reset, back to question 1
        exit_summary;
        if (dut.sess_q !== 8'd0 || dut.sess_star !== 8'd0 ||
            dut.sess_stars !== 4'd0) begin
            errors = errors + 1;
            $display("SS_SUM ERROR session not reset on exit");
        end
        if (dut.q_idx !== 2'd0 || dut.s1_id !== PH_P_MA1) begin
            errors = errors + 1;
            $display("SS_SUM ERROR exit did not restart the round: q_idx=%0d s1=%0d",
                     dut.q_idx, dut.s1_id);
        end

        // second session: r1..r10 again, timeout exit this time
        for (k = 0; k < 10; k = k + 1) begin
            auto_score(2'd2, 1'b0); n_scored = n_scored + 1;
        end
        if (!summary_show) begin
            errors = errors + 1;
            $display("SS_SUM ERROR second summary missing");
        end
        k = 0;
        while (summary_show && k < 700) begin
            frames(1); k = k + 1;
        end
        if (summary_show) begin
            errors = errors + 1;
            $display("SS_SUM ERROR 600-frame timeout did not fire");
        end else if (dut.sess_q !== 8'd0 || dut.sess_stars !== 4'd0) begin
            errors = errors + 1;
            $display("SS_SUM ERROR timeout exit left totals %0d/%0d",
                     dut.sess_q, dut.sess_stars);
        end

        // mode switch mid-summary closes the session (audit P2-1)
        for (k = 0; k < 10; k = k + 1) begin
            auto_score(2'd2, 1'b0); n_scored = n_scored + 1;
        end
        if (!summary_show) begin
            errors = errors + 1;
            $display("SS_SUM ERROR third summary missing");
        end
        mode = 3'd2; frames(4);
        if (dut.sess_q !== 8'd0 || dut.sess_star !== 8'd0) begin
            errors = errors + 1;
            $display("SS_SUM ERROR mode switch left totals %0d/%0d",
                     dut.sess_q, dut.sess_star);
        end
        if (summary_show) begin
            errors = errors + 1;
            $display("SS_SUM ERROR summary_show leaks into balloon mode");
        end

        if (errors == 0)
            $display("SS_SUM_PASS scored=%0d", n_scored);
        else
            $display("SS_SUM_FAIL errors=%0d", errors);
        $finish;
    end

    // guard against a stuck FSM
    initial begin
        #600_000_000;
        $display("SS_SUM_FAIL timeout phase=%0d scored=%0d", phase_o, n_scored);
        $finish;
    end
endmodule
