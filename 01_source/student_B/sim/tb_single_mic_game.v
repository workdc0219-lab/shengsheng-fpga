`timescale 1ns/1ps
// Real game + real scorer, accelerated UI frame spacing, port stimulus only.
module tb_single_mic_game;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,mt=0,mready=1,transition=0,teacher_on=1,tick=0,voice=0,tn=0;
 reg [2:0] mode=1;
 reg [9:0] pitch=400;
 wire arm,cancel,enable,request,dcancel,active,result,short_result,pvalid,used,summary;
 wire [2:0] target,phase,hint;
 wire [1:0] stars,diff;
 wire [6:0] score,npoints,pindex;
 wire [9:0] mean,pvalue;
 wire [159:0] bins_out;
 wire allowed=!mt&&mready;
 wire eligible=result&&!transition&&allowed&&!cancel;
 wire [7:0] count,starcount;
 wire [7:0] balloon;
 shengsheng_game #(.ENABLE_SINGLE_MIC(1)) game(
  .clk(clk),.rst_n(rst),.single_mic(1'b1),.mic_teacher(mt),.mic_ready(mready),.mic_transition(transition),
  .mode(mode),.key_next(1'b0),.key_replay(1'b0),.difficulty(2'd1),.active_index(2'd1),
  .ui_tick(tick),.link_up(1'b1),.tch_armed(1'b1),.trk_valid(tick),.trk_voiced(voice),.trk_pitch(pitch),.trk_level(8'd180),
  .sc_valid(eligible),.sc_active(active),.sc_short(short_result),.sc_score(score),.sc_stars(stars),.sc_hint(hint),.sc_mean(mean),.sc_bins(bins_out),
  .sc_point_valid(pvalid),.sc_point_index(pindex),.sc_point_value(pvalue),.sc_arm(arm),.sc_cancel(cancel),.sc_enable(enable),.sc_target(target),
  .demo_request(request),.demo_cancel(dcancel),.syn_playing(1'b0),.syn_progress(8'd0),.syn_done(1'b0),
  .cmd_ready(1'b1),.teacher_on(teacher_on),.tch_new(tn),.tch_off(128'd0),.phase_o(phase),.tch_used(used),
  .sess_q_o(count),.sess_star_o(starcount),.summary_show(summary),.eff_diff(diff),.balloon_r(balloon));
 tone_scorer scorer(
  .clk(clk),.rst_n(rst),.arm(arm),.cancel(cancel||transition||!allowed),.target(target),.difficulty(diff),.enable(enable),
  .frame_valid(tick),.voiced(voice),.pitch_q4(pitch),.nb_valid(1'b0),.nb_tone(3'd0),.dtw_valid(1'b0),.dtw_tone(3'd0),
  .result_valid(result),.n_points(npoints),.too_short(short_result),.score(score),.stars(stars),.hint(hint),.mean_q4(mean),.bins_flat(bins_out),
  .point_valid(pvalid),.point_index(pindex),.point_value(pvalue),.active(active));
 integer accepted=0,requests=0,last_score=0;
 always @(posedge clk)begin
  if(eligible)begin accepted=accepted+1;last_score=score;end
  if(request)requests=requests+1;
  if(rst&&mt&&enable)$fatal(1,"teacher can arm child scorer");
 end
 task frames(input integer n);integer i;begin
  for(i=0;i<n;i=i+1)begin @(negedge clk);tick=1;@(negedge clk);tick=0;repeat(998)@(negedge clk);end
 end endtask
 task select_role(input reg role);begin
  @(negedge clk);transition=1;mt=role;mready=0;
  @(negedge clk);transition=0;frames(5);
  mready=1;frames(1);
 end endtask
 task demo;begin
  frames(40);if(phase!=1)$fatal(1,"teacher DEMO not entered %0d",phase);
  @(negedge clk);tn=1;@(negedge clk);tn=0;frames(2);
  if(phase!=2||!used)$fatal(1,"teacher contour not retained");
 end endtask
 integer old_balloon;
 initial begin
  repeat(5)@(negedge clk);rst=1;frames(600);
  if(phase!=0||requests!=0||accepted!=0)$fatal(1,"wait for teacher key timed out");
  select_role(1);demo();frames(800);
  if(phase!=2||enable||accepted!=0)$fatal(1,"waiting for child key timed out or scored");
  select_role(0);frames(15);
  if(phase!=3||!enable||!used)$fatal(1,"child did not enter LISTEN with teacher reference");
  voice=1;frames(20);if(!active)$fatal(1,"real child answer not collected");
  // Abort mid-utterance; the ensuing silence must not finish an old answer.
  select_role(1);voice=0;frames(30);
  if(accepted!=0||active||count!=0)$fatal(1,"abandoned answer counted");
  demo();select_role(0);frames(15);
  voice=1;frames(30);voice=0;frames(32);
  if(accepted!=1||phase!=4||last_score<80||count!=1)$fatal(1,"normal child scoring failed accepted=%0d phase=%0d score=%0d count=%0d",accepted,phase,last_score,count);
  // Model-voice preference still works with the same microphone controls.
  mode=0;frames(2);teacher_on=0;mode=1;frames(60);
  if(phase!=3||!enable)$fatal(1,"model voice path broken");
  voice=1;frames(15);select_role(1);voice=0;frames(700);
  if(accepted!=1||phase!=2||enable)$fatal(1,"model path role pause failed");
  select_role(0);frames(15);voice=1;frames(30);voice=0;frames(32);
  if(accepted!=2)$fatal(1,"model path child answer failed");
  // Non-scored voice interaction must also ignore teacher speech.
  mode=2;select_role(1);frames(2);old_balloon=balloon;voice=1;frames(30);
  if(balloon!=old_balloon)$fatal(1,"teacher speech affected child balloon");
  select_role(0);frames(10);if(balloon==old_balloon)$fatal(1,"child balloon no longer responds");
  $display("SINGLE_MIC_GAME_PASS teacher_demo manual_wait abort_no_score resume_score model_voice balloon_role_gate");$finish;
 end
 initial begin #100000000;$fatal(1,"watchdog");end
endmodule
