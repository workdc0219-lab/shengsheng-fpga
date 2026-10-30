`timescale 1ns/1ps
// Port-only exercise: distinguish standby, running, feedback and cancelled runs.
// Feature pulses are independent of UI ticks. No force of internal state.
module tb_train_manual_start;
`include "ss_phrases.vh"
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0;
    reg [2:0] mode=3;
    reg link_up=1, single_mic=1, mic_teacher=0, mic_ready=1, mic_transition=0;
    reg key_next=0, key_replay=0, ui_tick=0, trk_valid=0, trk_voiced=0;
    reg [7:0] trk_level=185;
    wire [2:0] phase, syn_mode, sc_target;
    wire [1:0] card_index;
    wire [1:0] legacy_status_index=sc_target[1:0]+2'd3;
    wire [9:0] train_x;
    wire [7:0] meter_level, sess_q, sess_star;
    wire meter_ok, syn_valid, sc_enable;
    wire [5:0] s1_id, s3_id;
    wire [47:0] s2_cells;
    shengsheng_game #(.ENABLE_SINGLE_MIC(1)) dut (
        .clk(clk),.rst_n(rst_n),.mode(mode),
        .single_mic(single_mic),.mic_teacher(mic_teacher),.mic_ready(mic_ready),.mic_transition(mic_transition),
        .key_next(key_next),.key_replay(key_replay),.difficulty(2'd1),.active_index(2'd2),
        .ui_tick(ui_tick),.link_up(link_up),.tch_armed(1'b0),
        .trk_valid(trk_valid),.trk_voiced(trk_voiced),.trk_pitch(10'd400),.trk_level(trk_level),
        .sc_valid(1'b0),.sc_active(1'b0),.sc_short(1'b0),.sc_score(7'd0),.sc_stars(2'd0),
        .sc_hint(3'd0),.sc_mean(10'd400),.sc_bins(160'd0),
        .sc_point_valid(1'b0),.sc_point_index(7'd0),.sc_point_value(10'd400),
        .syn_playing(1'b0),.syn_progress(8'd0),.syn_done(1'b0),
        .syn_cmd_valid(syn_valid),.syn_cmd_mode(syn_mode),
        .teacher_on(1'b0),.tch_new(1'b0),.tch_off(128'd0),.cmd_ready(1'b1),
        .phase_o(phase),.train_x(train_x),.meter_level(meter_level),.meter_ok(meter_ok),
        .s1_id(s1_id),.s3_id(s3_id),.s2_cells(s2_cells),.sc_enable(sc_enable),
        .sc_target(sc_target),.card_index(card_index),.sess_q_o(sess_q),.sess_star_o(sess_star)
    );
    integer dings=0, cases=0;
    always @(posedge clk) begin
        if(rst_n && syn_valid && syn_mode==2) dings=dings+1;
        if(rst_n && mode==3 && (sc_enable || sess_q!=0 || sess_star!=0))
            $fatal(1,"TRAIN_MUST_REMAIN_UNSCORED");
    end
    task pulse;
        input tick, feature, voice;
        input [7:0] level;
        input next_key, replay_key;
        begin
            @(negedge clk);
            ui_tick=tick;trk_valid=feature;trk_voiced=voice;trk_level=level;
            key_next=next_key;key_replay=replay_key;
            @(negedge clk);
            ui_tick=0;trk_valid=0;key_next=0;key_replay=0;
            #1;
        end
    endtask
    task standby;
        input [255:0] label;
        begin
            if(train_x!==48) $fatal(1,"TRAIN_STANDBY_MOVED %0s x=%0d",label,train_x);
            if(phase!==0 || dut.arrived || meter_level!==0 || meter_ok ||
               s2_cells!==0 || s3_id!==PH_I_TRAIN)
                $fatal(1,"TRAIN_STANDBY_STATE %0s phase=%0d meter=%0d hint=%0d",label,phase,meter_level,s3_id);
        end
    endtask
    task running;
        input [9:0] expected_x;
        begin
            if(phase!==3 || train_x!==expected_x || dut.arrived)
                $fatal(1,"TRAIN_RUNNING_STATE phase=%0d x=%0d expected=%0d",phase,train_x,expected_x);
        end
    endtask
    task begin_run;
        begin
            pulse(0,1,1,185,1,0);
            running(48);
            if(meter_level!==0 || meter_ok || s3_id!==PH_H_LOUDER)
                $fatal(1,"TRAIN_START_SAME_EDGE_FEATURE_PRIORITY");
        end
    endtask
    integer i, before_dings;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        repeat(4) @(negedge clk);#1;
        standby("mode entry");
        for(i=0;i<120;i=i+1) begin
            pulse(i[0],1,1,185,0,0);
            standby("noise before start");
        end
        // Out-of-window and unvoiced packets must not overwrite the start hint.
        pulse(1,1,1,240,0,0);standby("loud noise");
        pulse(0,1,0,185,0,0);standby("silence");cases=cases+1;

        begin_run;
        pulse(0,1,1,185,0,0);running(50);
        for(i=0;i<40;i=i+1) pulse(1,0,1,185,0,0);
        running(50); // No stale feature replay on UI ticks.
        pulse(0,1,1,165,0,0);running(52);
        pulse(0,1,1,205,0,0);running(54);
        pulse(0,1,1,164,0,0);running(54);
        if(s3_id!==PH_H_LOUDER || meter_ok) $fatal(1,"TRAIN_LOUDER_HINT");
        pulse(0,1,1,206,0,0);running(54);
        if(s3_id!==PH_H_SOFTER || meter_ok) $fatal(1,"TRAIN_SOFTER_HINT");
        pulse(0,1,0,185,0,0);running(54);
        if(s3_id!==PH_H_LOUDER || meter_level!==0) $fatal(1,"TRAIN_SILENCE_HINT");cases=cases+1;

        // NEXT restarts; REPLAY stops. Same-edge UI/features cannot undo either.
        pulse(1,1,1,185,1,0);running(48);
        pulse(0,1,1,185,0,0);running(50);
        pulse(1,1,1,185,0,1);standby("replay stop");
        for(i=0;i<12;i=i+1) begin pulse(1,1,1,185,0,0);standby("stopped noise");end
        pulse(1,1,1,185,1,1);standby("both key events stop");cases=cases+1;

        // Teacher role and the protection interval cancel rather than pause a run.
        begin_run;pulse(0,1,1,185,0,0);running(50);
        mic_teacher=1;
        pulse(1,1,1,185,1,0);standby("teacher role overrides start");
        mic_teacher=0;
        pulse(0,1,1,185,0,0);standby("child return needs new start");
        begin_run;pulse(0,1,1,185,0,0);running(50);
        mic_transition=1;
        pulse(1,1,1,185,1,0);standby("transition overrides start");
        mic_transition=0;mic_ready=0;
        pulse(0,1,1,185,1,0);standby("guard rejects start");
        mic_ready=1;
        pulse(1,1,1,185,0,0);standby("guard expiry needs new start");cases=cases+1;

        begin_run;pulse(0,1,1,185,0,0);running(50);
        link_up=0;
        pulse(1,1,1,185,1,0);
        if(phase!==0 || train_x!==48 || meter_level!==0 || s3_id!==PH_WAIT_LINK)
            $fatal(1,"TRAIN_LINK_LOSS_PRIORITY");
        @(negedge clk);
        link_up=1;ui_tick=1;trk_valid=1;trk_voiced=1;trk_level=185;key_next=1;
        @(negedge clk);ui_tick=0;trk_valid=0;key_next=0;#1;
        standby("reconnect edge rejects start");
        pulse(1,1,1,185,0,0);standby("reconnect stays idle");cases=cases+1;

        // Mode entry rejects an old key event from the preceding exercise.
        begin_run;pulse(0,1,1,185,0,0);running(50);
        mode=2;pulse(0,0,0,185,0,0);
        @(negedge clk);
        mode=3;ui_tick=1;trk_valid=1;trk_voiced=1;key_next=1;
        @(negedge clk);ui_tick=0;trk_valid=0;key_next=0;#1;
        standby("mode entry rejects key");
        pulse(0,1,1,185,0,0);standby("reentry noise");cases=cases+1;

        // Arrival feedback lasts the existing 120-frame threshold then disarms.
        begin_run;before_dings=dings;
        for(i=0;i<246;i=i+1) pulse(0,1,1,185,0,0);
        if(train_x!==540 || phase!==4 || !dut.arrived || s3_id!==PH_F_ARRIVE)
            $fatal(1,"TRAIN_ARRIVAL");
        pulse(0,1,1,185,0,0);
        if(dings!=before_dings+1) $fatal(1,"TRAIN_ARRIVAL_DING_NOT_EXACTLY_ONCE");
        for(i=0;i<120;i=i+1) pulse(1,1,1,185,0,0);
        if(phase!==4 || train_x!==540) $fatal(1,"TRAIN_FEEDBACK_ENDED_EARLY");
        pulse(1,1,1,185,0,0);standby("arrival timeout disarms");
        for(i=0;i<30;i=i+1) begin pulse(1,1,1,185,0,0);standby("arrival does not auto restart");end
        if(dings!=before_dings+1) $fatal(1,"TRAIN_DING_REPLAYED");cases=cases+1;

        // Keys on the arrival timeout edge retain their explicit semantics.
        begin_run;
        for(i=0;i<246;i=i+1) pulse(0,1,1,185,0,0);
        for(i=0;i<120;i=i+1) pulse(1,0,0,185,0,0);
        pulse(1,1,1,185,1,0);running(48);
        pulse(1,1,1,185,0,1);standby("stop after arrival restart");cases=cases+1;

        // Legacy non-single-mic use still requires a start, without role inputs.
        single_mic=0;mic_teacher=1;mic_ready=0;
        begin_run;pulse(0,1,1,185,0,0);running(50);
        pulse(0,1,1,185,0,1);standby("legacy explicit stop");cases=cases+1;

        // Card text/index change before the scoring target's INTRO update.
        // STATUS must therefore use card_index for mode 4, not sc_target-1.
        mode=4;pulse(0,0,0,185,0,0);
        if(card_index!==0 || sc_target!==1 || s1_id!==PH_P_MAO)
            $fatal(1,"CARD_INITIAL_PROMPT");
        pulse(1,0,0,185,1,0);
        if(card_index!==1 || s1_id!==PH_P_YU || sc_target!==1 ||
           legacy_status_index!==2'd0)
            $fatal(1,"CARD_STATUS_REQUIRES_IMMEDIATE_CARD_INDEX card=%0d text=%0d target=%0d old_index=%0d",card_index,s1_id,sc_target,legacy_status_index);
        $display("CARD_INDEX_STATUS_COUNTEREXAMPLE_PASS card_index=%0d prompt=%0d old_sc_target=%0d old_status_index=%0d",card_index,s1_id,sc_target,legacy_status_index);
        cases=cases+1;

        $display("TRAIN_MANUAL_START_PASS cases=%0d standby_noise=1 key_same_edge=1 role_cancel=1 link_cancel=1 arrival_rearm=1 feature_once=1 card_status_counterexample=1",cases);
        $finish;
    end
    initial begin #1000000;$fatal(1,"TRAIN_MANUAL_START_WATCHDOG");end
endmodule
