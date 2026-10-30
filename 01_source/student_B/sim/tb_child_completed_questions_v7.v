`timescale 1ns/1ps
// Physical active-low keys -> real debounce/release router -> real game.
// Scorer verdicts are module-boundary stimuli; no force of game state/counters.
module tb_child_completed_questions_v7;
`include "ss_phrases.vh"
    reg clk=0,rst_n=0; always #5 clk=~clk;
    reg [2:0] mode=0;
    reg ui_tick=0,link_up=1,key2_n=1,key3_n=1;
    reg trk_valid=0,trk_voiced=1;
    reg sc_valid=0,sc_short=0;
    reg [1:0] sc_stars=0;
    wire key_next,key_replay,key_long;
    wire [2:0] phase;
    wire [1:0] card_index;
    wire [7:0] sess_q,sess_star,balloon_r,disc_radius,meter_level;
    wire [9:0] train_x;
    wire [2:0] disc_hue;
    wire summary_show;
    wire [47:0] s2_cells;
    integer key2_events=0,key3_events=0,valid_attempts=0;
    dual_key_chord_router #(.DEBOUNCE_CYCLES(2),.HOLD_CYCLES(100),.KEY3_LONG_CYCLES(80)) keys (
        .clk(clk),.rst_n(rst_n),.save_enabled(1'b0),.key2_n(key2_n),.key3_n(key3_n),
        .key2_event(key_next),.key3_event(key_replay),.key3_long_event(key_long));
    always @(posedge clk) begin
        if(key_next) key2_events=key2_events+1;
        if(key_replay) key3_events=key3_events+1;
        if(key_long) $fatal(1,"short-key test unexpectedly emitted long event");
    end
    shengsheng_game dut (
        .clk(clk),.rst_n(rst_n),.mode(mode),.key_next(key_next),.key_replay(key_replay),
        .difficulty(2'd1),.active_index(2'd1),.ui_tick(ui_tick),.link_up(link_up),.tch_armed(1'b0),
        .trk_valid(trk_valid),.trk_voiced(trk_voiced),.trk_pitch(10'd400),.trk_level(8'd185),
        .sc_valid(sc_valid),.sc_active(1'b0),.sc_short(sc_short),.sc_score(7'd80),.sc_stars(sc_stars),
        .sc_hint(3'd0),.sc_mean(10'd400),.sc_bins({16{10'd400}}),
        .sc_point_valid(1'b0),.sc_point_index(7'd0),.sc_point_value(10'd400),
        .syn_playing(1'b0),.syn_progress(8'd0),.syn_done(1'b0),
        .teacher_on(1'b0),.tch_new(1'b0),.tch_off(128'd0),
        .phase_o(phase),.summary_show(summary_show),.sess_q_o(sess_q),.sess_star_o(sess_star),
        .card_index(card_index),.balloon_r(balloon_r),.train_x(train_x),.meter_level(meter_level),
        .disc_radius_o(disc_radius),.disc_hue_o(disc_hue),.s2_cells(s2_cells),.cmd_ready(1'b1));
    task frames;
        input integer n; integer j;
        begin
            for(j=0;j<n;j=j+1) begin
                @(negedge clk); ui_tick=1;
                @(negedge clk); ui_tick=0;
                repeat(12) @(negedge clk);
            end
        end
    endtask
    task await_phase;
        input [2:0] target; integer j;
        begin
            j=0;
            while(phase!=target && j<1100) begin frames(1); j=j+1; end
            if(phase!=target) $fatal(1,"phase wait target=%0d actual=%0d",target,phase);
        end
    endtask
    task emit_result;
        input [1:0] stars; input short_sample;
        begin
            await_phase(3); @(negedge clk);
            sc_stars=stars; sc_short=short_sample; sc_valid=1;
            @(negedge clk); sc_valid=0;
            repeat(2) @(negedge clk);
            if(phase!=4) $fatal(1,"verdict not accepted");
            if(!short_sample) valid_attempts=valid_attempts+1;
        end
    endtask
    task finish_feedback;
        integer j;
        begin
            j=0;
            while(phase==4 && j<250) begin frames(1); j=j+1; end
            if(phase==4) $fatal(1,"feedback stuck");
        end
    endtask
    task answer;
        input [1:0] stars; input short_sample;
        begin emit_result(stars,short_sample); finish_feedback; end
    endtask
    task press;
        input integer key; input tick_on_event; integer j;
        begin
            @(negedge clk);
            if(key==2) key2_n=0; else key3_n=0;
            repeat(14) @(negedge clk);
            key2_n=1; key3_n=1;
            j=0;
            while(!(key==2 ? key_next : key_replay) && j<24) begin @(negedge clk); j=j+1; end
            if(j==24) $fatal(1,"physical short key lost");
            ui_tick=tick_on_event;
            @(negedge clk); ui_tick=0;
            repeat(5) @(negedge clk);
        end
    endtask
    task sample;
        begin
            @(negedge clk); trk_valid=1;
            @(negedge clk); trk_valid=0;
            repeat(3) @(negedge clk);
        end
    endtask
    integer i,k;
    reg [1:0] old_index;
    initial begin
        repeat(5) @(negedge clk); rst_n=1; mode=1; frames(2);
        answer(0,1);
        if(sess_q!=0 || sess_star!=0) $fatal(1,"short counted as completion");
        for(i=0;i<3;i=i+1) begin
            answer(1,0);
            if(sess_q!=0 || sess_star!=0 || card_index!=0) $fatal(1,"retry counted early i=%0d",i);
            if(i==1) begin
                answer(0,1);
                if(dut.retry_count!=1 || !dut.retry_demo || sess_q!=0) $fatal(1,"short input reset consumed retries");
                await_phase(3);
                frames(dut.listen_limit+2);
                if(phase!=4 || dut.retry_count!=1 || !dut.retry_demo || sess_q!=0) $fatal(1,"silence reset consumed retries");
                finish_feedback;
                press(3,0);
                if(dut.retry_count!=1 || !dut.retry_demo || sess_q!=0 || card_index!=0) $fatal(1,"manual replay reset consumed retries");
            end
        end
        answer(1,0);
        if(sess_q!=1 || sess_star!=1 || card_index!=1) $fatal(1,"exhausted retry not final commit");
        emit_result(1,0); old_index=card_index; press(2,0);
        if(sess_q!=1 || sess_star!=1 || card_index!=old_index+2'd1) $fatal(1,"skip failed question counted");
        emit_result(3,0); old_index=card_index; press(3,0);
        if(sess_q!=2 || sess_star!=4 || card_index!=old_index || !dut.question_completed) $fatal(1,"replay lost completion identity");
        emit_result(2,0);
        if(sess_q!=2 || sess_star!=4) $fatal(1,"completed replay double counted");
        // Physical replay exactly at the auto-advance edge must retain identity.
        frames(dut.feed_limit);
        press(3,1);
        if(phase!=0 || !dut.question_completed || card_index!=old_index) $fatal(1,"same-edge replay reopens completed count");
        answer(2,0);
        if(sess_q!=2 || sess_star!=4 || card_index!=old_index+2'd1) $fatal(1,"replayed final completion changed totals");
        await_phase(3); old_index=card_index; press(2,0);
        if(sess_q!=2 || card_index!=old_index+2'd1) $fatal(1,"manual skip unattempted question counted");
        for(i=0;i<7;i=i+1) answer(2,0);
        if(sess_q!=9 || sess_star!=18) $fatal(1,"nine completed totals q=%0d stars=%0d",sess_q,sess_star);
        emit_result(2,0); old_index=card_index;
        press(2,0); press(3,0);
        if(phase!=4 || sess_q!=10 || sess_star!=20 || card_index!=old_index) $fatal(1,"tenth feedback short keys escaped");
        frames(dut.feed_limit); press(3,1);
        if(!summary_show || sess_q!=10 || sess_star!=20) $fatal(1,"tenth replay same edge skipped summary");
        frames(4);
        if(s2_cells!={PH_BLANK,PH_C_STAR,PH_C_0,PH_C_2,PH_BLANK,PH_C_QUESTIONS,PH_C_0,PH_C_1}) $fatal(1,"completed question summary labels/digits");
        press(3,0);
        if(!summary_show || sess_q!=10) $fatal(1,"summary replay created eleventh question");
        press(2,0);
        if(summary_show || sess_q!=0 || sess_star!=0 || dut.question_completed) $fatal(1,"summary next did not reset");
        // Repeat the tenth-boundary case for physical NEXT, in card mode.
        mode=4; frames(2);
        for(i=0;i<9;i=i+1) answer(3,0);
        emit_result(3,0); frames(dut.feed_limit); press(2,1);
        if(!summary_show || sess_q!=10 || sess_star!=30) $fatal(1,"tenth next same edge skipped/reset summary");
        press(2,0);
        if(sess_q!=0 || sess_star!=0 || card_index!=0) $fatal(1,"card round restart");
        // Both short keys reset each non-word activity without creating scores.
        for(k=2;k<=3;k=k+1) begin
            mode=2; frames(2);
            for(i=0;i<12;i=i+1) sample;
            if(dut.held==0 || balloon_r<=24) $fatal(1,"balloon input did not run");
            press(k,0);
            if(dut.held!=0 || balloon_r!=24 || dut.popped || s2_cells!=0) $fatal(1,"balloon key reset failed");
            mode=3; frames(2); sample;
            if(train_x!=48) $fatal(1,"train moved before physical NEXT");
            press(2,0); sample;
            if(train_x!=50) $fatal(1,"train input did not run");
            press(k,0);
            if(train_x!=48 || dut.arrived || meter_level!=0 || s2_cells!=0) $fatal(1,"train key reset failed");
            mode=5; frames(2); sample;
            if(disc_radius!=66 || disc_hue!=3) $fatal(1,"exploration input did not run");
            press(k,0);
            if(disc_radius!=40 || disc_hue!=2 || sess_q!=0 || sess_star!=0) $fatal(1,"exploration reset/count failed");
        end
        if(valid_attempts<=20 || key2_events<8 || key3_events<8) $fatal(1,"insufficient physical event coverage");
        $display("CHILD_COMPLETED_V7_PASS questions=20 attempts=%0d physical_key2=%0d physical_key3=%0d retry_final_once=1 short_silence_replay_preserve_retries=1 short_skip_not_counted=1 completed_replay_once=1 tenth_key_boundary=1 exercise_resets=1",valid_attempts,key2_events,key3_events);
        $finish;
    end
    initial begin #100000000; $fatal(1,"completed-question timeout"); end
endmodule
