`timescale 1ns/1ps
module tb_child_game_v7;
`include "ss_phrases.vh"
    reg clk=0,rst_n=0; always #5 clk=~clk;
    reg [2:0] mode=0;
    reg ui_tick=0,link_up=0,tch_armed=0,teacher_on=0,tch_new=0;
    reg key_next=0,key_replay=0,trk_valid=0,trk_voiced=0;
    reg [9:0] trk_pitch=400;
    reg [7:0] trk_level=185;
    reg sc_valid=0,sc_active=0,sc_short=0,sc_point_valid=0;
    reg [1:0] sc_stars=0;
    reg [6:0] sc_point_index=0;
    wire [2:0] phase;
    wire sc_arm,sc_cancel,sc_enable,demo_request,demo_cancel,tch_used,summary_show,discover_show;
    wire [5:0] s0_id,s3_id;
    wire [7:0] sess_q,sess_star,disc_radius;
    wire [1:0] card_index;
    wire [9:0] train_x;
    wire cmd_valid,cmd_buf,cmd_vis;
    wire [8:0] cmd_x0,ball_col;
    wire [3:0] cmd_log2n;
    wire syn_cmd_valid;
    wire [2:0] syn_cmd_mode;
    shengsheng_game dut (
        .clk(clk),.rst_n(rst_n),.mode(mode),.key_next(key_next),.key_replay(key_replay),
        .difficulty(2'd1),.active_index(2'd1),.ui_tick(ui_tick),.link_up(link_up),.tch_armed(tch_armed),
        .trk_valid(trk_valid),.trk_voiced(trk_voiced),.trk_pitch(trk_pitch),.trk_level(trk_level),
        .sc_valid(sc_valid),.sc_active(sc_active),.sc_short(sc_short),.sc_score(7'd80),.sc_stars(sc_stars),
        .sc_hint(3'd0),.sc_mean(10'd400),.sc_bins({16{10'd400}}),
        .sc_point_valid(sc_point_valid),.sc_point_index(sc_point_index),.sc_point_value(10'd400),
        .sc_arm(sc_arm),.sc_cancel(sc_cancel),.sc_enable(sc_enable),.demo_request(demo_request),.demo_cancel(demo_cancel),
        .syn_playing(1'b0),.syn_progress(8'd0),.syn_done(1'b0),.syn_cmd_valid(syn_cmd_valid),.syn_cmd_mode(syn_cmd_mode),
        .teacher_on(teacher_on),.tch_new(tch_new),.tch_off({16{8'd0}}),.phase_o(phase),.tch_used(tch_used),
        .summary_show(summary_show),.discover_show(discover_show),.disc_radius_o(disc_radius),
        .sess_q_o(sess_q),.sess_star_o(sess_star),.s0_id(s0_id),.s3_id(s3_id),.card_index(card_index),.train_x(train_x),
        .cmd_valid(cmd_valid),.cmd_ready(1'b1),.cmd_buf(cmd_buf),.cmd_x0(cmd_x0),.cmd_log2n(cmd_log2n),
        .cmd_vis(cmd_vis),.ball_col(ball_col));
    integer requests=0,cancels=0,sc_cancels=0,demos=0,live_segments=0,max_x=0;
    always @(posedge clk) begin
        if(demo_request) requests=requests+1;
        if(demo_cancel) cancels=cancels+1;
        if(sc_cancel) sc_cancels=sc_cancels+1;
        if(syn_cmd_valid && syn_cmd_mode==1) demos=demos+1;
        if(cmd_valid && cmd_buf && cmd_vis && cmd_log2n==3) begin
            live_segments=live_segments+1;
            if(cmd_x0>max_x) max_x=cmd_x0;
            if(cmd_x0>504) $fatal(1,"live command wraps");
        end
    end
    task frames;
        input integer n; integer j;
        begin
            for(j=0;j<n;j=j+1) begin
                @(negedge clk); ui_tick=1; @(negedge clk); ui_tick=0;
                repeat(80) @(negedge clk);
            end
        end
    endtask
    task await_phase;
        input [2:0] p; integer j;
        begin
            j=0; while(phase!=p && j<1100) begin frames(1); j=j+1; end
            if(phase!=p) $fatal(1,"phase wait target=%0d actual=%0d",p,phase);
        end
    endtask
    task result;
        input [1:0] stars; input short_sample;
        begin
            await_phase(3); @(negedge clk);
            sc_stars=stars; sc_short=short_sample; sc_valid=1;
            @(negedge clk); sc_valid=0; frames(1);
            if(phase!=4) $fatal(1,"result not accepted");
            while(phase==4) frames(1);
        end
    endtask
    task sample;
        begin
            @(negedge clk); trk_valid=1; trk_voiced=1;
            @(negedge clk); trk_valid=0;
            repeat(4) @(negedge clk);
        end
    endtask
    integer i, before_cancel, before_demo;
    initial begin
        repeat(5) @(negedge clk); rst_n=1; mode=1;
        frames(90);
        if(phase!==0 || dut.timer!==0 || s3_id!==PH_WAIT_LINK || sc_enable || sess_q!==0) $fatal(1,"offline waiting");
        link_up=1; frames(2); await_phase(3);
        if(demos!=1 || sess_q!=0) $fatal(1,"local UI tick did not advance without data");
        before_cancel=sc_cancels;
        @(negedge clk); key_next=1; sc_valid=1;
        @(negedge clk); key_next=0; sc_valid=0; frames(1);
        if(sc_cancels!=before_cancel+1 || sess_q!=0 || card_index!=1) $fatal(1,"key/result cancellation priority");
        teacher_on=1; await_phase(1);
        if(requests!=1 || s3_id!==PH_WAIT_TEACHER) $fatal(1,"teacher request contract");
        @(negedge clk); tch_new=1; @(negedge clk); tch_new=0; frames(2);
        if(phase!=1 || tch_used) $fatal(1,"unarmed teacher curve accepted");
        tch_armed=1;
        @(negedge clk); tch_new=1; @(negedge clk); tch_new=0; frames(2);
        if(!tch_used || phase!=2) $fatal(1,"armed teacher curve rejected");
        await_phase(3);
        before_cancel=sc_cancels;
        @(negedge clk); key_replay=1; @(negedge clk); key_replay=0; tch_armed=0;
        frames(1);
        if(sc_cancels!=before_cancel+1 || tch_used) $fatal(1,"replay does not cancel");
        await_phase(1); before_demo=demos;
        frames(485);
        if(demos!=before_demo+1 || tch_used) $fatal(1,"teacher timeout needs local tick");
        before_cancel=sc_cancels;
        link_up=0; sc_valid=1; frames(5); sc_valid=0;
        if(sc_cancels!=before_cancel+1 || s3_id!==PH_WAIT_LINK || sess_q!=0) $fatal(1,"link loss not cancelled");
        teacher_on=0; link_up=1; frames(2); await_phase(3); frames(2);
        for(i=0;i<96;i=i+1) begin
            @(negedge clk); sc_point_index=i; sc_point_valid=1;
            @(negedge clk); sc_point_valid=0; repeat(12) @(negedge clk);
        end
        if(live_segments!=96 || max_x!=504 || ball_col!=511) $fatal(1,"96point map segments=%0d xmax=%0d",live_segments,max_x);
        mode=0; frames(2); mode=1; frames(2);
        for(i=0;i<4;i=i+1) result(0,0);
        if(card_index!=1 || dut.retry_count!=0 || sess_q!=1 || sess_star!=0) $fatal(1,"retry completion/next question");
        result(0,0);
        if(card_index!=1 || !dut.retry_demo || sess_q!=1) $fatal(1,"next question first failure counted/skipped");
        mode=5; frames(2); sc_valid=1; frames(2); sc_valid=0;
        sample;
        if(sc_enable || sess_q!=0 || !discover_show || disc_radius!=66) $fatal(1,"exploration counted or missing sample");
        mode=3; frames(2); sample;
        if(train_x!=48) $fatal(1,"train moved before NEXT");
        @(negedge clk); key_next=1; @(negedge clk); key_next=0;
        sample;
        if(train_x!=50) $fatal(1,"between-tick sample dropped");
        frames(50);
        if(train_x!=50) $fatal(1,"stale level replayed");
        mode=4; frames(2);
        result(0,1);
        if(sess_q!=0) $fatal(1,"short sample counted");
        for(i=0;i<10;i=i+1) result(3,0);
        frames(4);
        if(!summary_show || sess_q!=10 || sess_star!=30 || dut.card_show) $fatal(1,"card summary");
        @(negedge clk); key_next=1; @(negedge clk); key_next=0; frames(2);
        if(summary_show || sess_q!=0 || card_index!=0 || s0_id!=PH_MODE_CARD) $fatal(1,"card summary restart");
        $display("CHILD_GAME_V7_PASS local_ui=1 cancel=1 teacher_handshake=1 live_points=96 retry=1 summary=1 discovery=1");
        $finish;
    end
    initial begin #100000000; $fatal(1,"child game timeout"); end
endmodule
