`timescale 1ns/1ps
// Product B coordinator. Lost connection cancels in-flight work. Results are
// retried from one immutable event snapshot; a second pending event causes
// visible protocol_error and resynchronisation, never silent overwrite.
module v7_link_b #(
    parameter integer ALLOW_SINGLE_MIC=0,
    parameter integer CLKS_PER_BIT=27,
    parameter integer LINK_TIMEOUT=18750000,
    parameter integer RETRY_CLOCKS=2500000,
    parameter integer QUIET_CLOCKS=500000,
    // Reduced only by directed tests; production resynchronises before wrap.
    parameter integer EVENT_LIMIT=65534,
    parameter integer TX_LIMIT=65534
)(
    input wire clk,rst_n,rx,
    output wire tx,
    input wire frame_tick,
    input wire [2:0] mode,phase,target,
    input wire [1:0] q_idx,eff_diff,
    input wire tch_used,summary,
    input wire demo_request,demo_cancel,
    input wire sc_valid,sc_short,
    input wire [6:0] sc_score,sc_n,
    input wire [1:0] sc_stars,
    input wire [2:0] sc_hint,
    input wire [9:0] sc_mean,
    input wire [159:0] sc_bins,
    output wire link_up,
    output reg protocol_error,
    output reg feat_valid,feat_voiced,
    output reg single_mic,mic_teacher,mic_ready,
    output wire mic_transition,
    output reg [9:0] feat_pitch,
    output reg [7:0] feat_level,
    output reg teacher_preference,teacher_voiced,
    output reg [9:0] teacher_pitch,
    output reg [7:0] teacher_level,
    output reg tch_armed,tch_new,
    output reg [6:0] tch_n,
    output reg [127:0] tch_shape
);
    `include "v7_defs.vh"
    localparam [2:0] QUIET=0,WAIT_ACK=1,WAIT_FEATURE=2,UP=3;
    reg [2:0] state;
    wire restart_now;
    // Invalidate on the SAME edge as a checked reset/timeout/overflow event.
    // sc_valid must be an eligible raw event, not gated by this output.
    assign link_up=(state==UP) && !restart_now;
    reg flush,send;
    wire ready,rx_valid,rx_bad,rx_ver;
    reg [7:0] tx_kind;
    reg [5:0] tx_len;
    reg [15:0] tx_session,tx_sequence,tx_question;
    reg [255:0] tx_payload;
    wire [7:0] rx_kind;
    wire [5:0] rx_len;
    wire [15:0] rx_session,rx_sequence,rx_question;
    wire [255:0] rx_payload;
    v7_packet_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx(
        .clk(clk),.rst_n(rst_n),.flush(flush),.send(send),.kind(tx_kind),.length(tx_len),
        .session(tx_session),.packet_seq(tx_sequence),.question(tx_question),.payload(tx_payload),
        .tx(tx),.ready(ready),.done());
    v7_packet_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx(
        .clk(clk),.rst_n(rst_n),.flush(flush),.rx(rx),.valid(rx_valid),
        .kind(rx_kind),.length(rx_len),.session(rx_session),.packet_seq(rx_sequence),
        .question(rx_question),.payload(rx_payload),.packet_error(rx_bad),.version_error(rx_ver));
    reg [15:0] session,tx_seq,last_rx_seq,question,event_id;
    reg [31:0] idle,retry,quiet_count;
    reg control_pending,status_pending,request_pending,cancel_pending,result_pending,result_send;
    reg demo_active;
    // Store immutable metadata and a rotating 16x10-bit point bank.
    // Convert one point per clock in place; after 16 rotations every slot
    // contains its final signed 8-bit offset. This replaces 16 parallel
    // subtract/clamp cones with one without changing the wire payload.
    reg [87:0] result_snapshot;
    reg [159:0] result_points;
    reg [3:0] result_pack_index;
    reg result_packing;
    reg [15:0] result_question;
    reg [2:0] heartbeat;
    wire fresh=rx_sequence>last_rx_seq && rx_sequence<16'hFFFF;
    wire feature_ok=rx_payload[15:10]==0 &&
                    ((ALLOW_SINGLE_MIC!=0 && rx_payload[27]) ? rx_payload[31:30]==0 : rx_payload[31:27]==0) &&
                    rx_payload[47:42]==0 && rx_payload[71:56]==0;
    assign mic_transition=(ALLOW_SINGLE_MIC!=0) && rx_valid &&
        (state==WAIT_FEATURE || state==UP) && rx_session==session && fresh &&
        rx_kind==V7_FEATURE && feature_ok &&
        ((single_mic!=rx_payload[27]) || (rx_payload[27] &&
         ((mic_teacher!=rx_payload[28]) || (mic_ready && !rx_payload[29]))));
    function [7:0] offset;
        input [9:0] value,mean;
        reg signed [11:0] d;
        begin
            d=$signed({2'b0,value})-$signed({2'b0,mean});
            offset=(d>127)?8'd127:(d< -127)?8'h81:d[7:0];
        end
    endfunction
    integer k;
    assign restart_now=(rx_valid && rx_kind==V7_HELLO && state!=QUIET) || rx_ver ||
        (state!=QUIET && idle>=LINK_TIMEOUT-1 && !rx_valid) ||
        (state==UP && (question>=16'hFFFE || event_id>=EVENT_LIMIT ||
                     (tx_seq>=TX_LIMIT && ready && !send && !flush))) ||
        // Do not accept locally a last event which would be cleared by the
        // mandatory counter restart on the very next clock.
        (state==UP && sc_valid && (event_id>=EVENT_LIMIT-1 || tx_seq>=TX_LIMIT-1)) ||
        (state==UP && sc_valid && result_pending);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=QUIET; flush<=0; send<=0; tx_kind<=0; tx_len<=0;
            tx_session<=0; tx_sequence<=0; tx_question<=0; tx_payload<=0;
            session<=0; tx_seq<=1; last_rx_seq<=0; question<=1; event_id<=0;
            idle<=0; retry<=0; quiet_count<=0; control_pending<=0; status_pending<=0;
            request_pending<=0; cancel_pending<=0; result_pending<=0; result_send<=0;
            demo_active<=0; result_snapshot<=0; result_question<=0; heartbeat<=0;
            result_points<=0;result_pack_index<=0;result_packing<=0;
            single_mic<=0;mic_teacher<=0;mic_ready<=0;
            protocol_error<=0; feat_valid<=0; feat_voiced<=0; feat_pitch<=0; feat_level<=0;
            teacher_preference<=0; teacher_voiced<=0; teacher_pitch<=0; teacher_level<=0;
            tch_armed<=0; tch_new<=0; tch_n<=0; tch_shape<=0;
        end else begin
            flush<=0; send<=0; feat_valid<=0; tch_new<=0;
            if(rx_bad) protocol_error<=1;
            if(idle<LINK_TIMEOUT) idle<=idle+1'b1;
            if(state==QUIET) begin
                if(quiet_count>=QUIET_CLOCKS-1) begin
                    session<=(session>=16'hFFFD)?16'd1:session+1'b1;
                    state<=WAIT_ACK; quiet_count<=0; control_pending<=1; idle<=0; retry<=0;
                end else quiet_count<=quiet_count+1'b1;
            end
            if(retry>=RETRY_CLOCKS-1) begin
                retry<=0;
                if(state==WAIT_ACK || state==WAIT_FEATURE) control_pending<=1;
                if(state==UP) begin
                    status_pending<=1;
                    if(demo_active && !tch_armed) request_pending<=1;
                    if(result_pending && !result_packing) result_send<=1;
                end
            end else retry<=retry+1'b1;
            if(frame_tick && state==UP) begin
                heartbeat<=heartbeat+1'b1;
                if(heartbeat==7) status_pending<=1;
            end
            if(demo_cancel && state==UP) begin
                demo_active<=0; tch_armed<=0; request_pending<=0; cancel_pending<=1;
                question<=question+1'b1;
            end
            if(demo_request && state==UP) begin
                question<=question+1'b1; demo_active<=1; tch_armed<=0;
                request_pending<=1; cancel_pending<=0;
            end
            if(result_packing) begin
                result_points<={2'b00,offset(result_points[9:0],result_snapshot[81:72]),result_points[159:10]};
                result_pack_index<=result_pack_index+1'b1;
                if(result_pack_index==4'd15) begin result_packing<=0;result_send<=1;end
            end
            if(sc_valid && state==UP && !result_pending && (mode==1 || mode==4)) begin
                event_id<=event_id+1'b1; result_pending<=1; result_send<=0; result_question<=question;
                result_points<=sc_bins;result_pack_index<=0;result_packing<=1;
                result_snapshot[15:0]<=event_id+1'b1;
                result_snapshot[23:16]<={5'b0,mode}; result_snapshot[31:24]<={5'b0,target};
                result_snapshot[39:32]<={6'b0,tch_used,sc_short};
                result_snapshot[47:40]<={1'b0,sc_score}; result_snapshot[55:48]<={6'b0,sc_stars};
                result_snapshot[63:56]<={1'b0,sc_n}; result_snapshot[71:64]<={5'b0,sc_hint};
                result_snapshot[87:72]<={6'b0,sc_mean};
                // The entire raw curve was captured above on the acceptance edge.
            end

            if(ready && !send && !flush) begin
                tx_session<=session; tx_sequence<=tx_seq; tx_question<=question; tx_payload<=0;
                if(control_pending) begin
                    tx_kind<=(state==WAIT_ACK)?V7_SYNC:V7_SYNC_COMMIT;
                    tx_len<=0; tx_sequence<=0; tx_question<=0; send<=1; control_pending<=0;
                end else if(state==UP && tx_seq<TX_LIMIT) begin
                    if(cancel_pending && !demo_request) begin
                        tx_kind<=V7_DEMO_CANCEL; tx_len<=0; send<=1; cancel_pending<=0; tx_seq<=tx_seq+1'b1;
                    end else if(request_pending && demo_active && !demo_cancel && !demo_request) begin
                        tx_kind<=V7_DEMO_REQUEST; tx_len<=0; send<=1; request_pending<=0; tx_seq<=tx_seq+1'b1;
                    end else if(result_send && result_pending && !result_packing) begin
                        tx_kind<=V7_RESULT; tx_len<=V7_LEN_RESULT; tx_payload[87:0]<=result_snapshot;
                        for(k=0;k<16;k=k+1) tx_payload[88+k*8 +:8]<=result_points[k*10 +:8];
                        tx_question<=result_question; send<=1; result_send<=0; tx_seq<=tx_seq+1'b1;
                    end else if(status_pending) begin
                        tx_kind<=V7_STATUS; tx_len<=V7_LEN_STATUS;
                        tx_payload[47:0]<={5'b0,demo_active,summary,tch_used,6'b0,eff_diff,6'b0,q_idx,5'b0,target,5'b0,phase,5'b0,mode};
                        send<=1; status_pending<=0; tx_seq<=tx_seq+1'b1;
                    end
                end
            end
            if(rx_valid) begin
                if(state==WAIT_ACK && rx_kind==V7_SYNC_ACK && rx_session==session && rx_sequence==0) begin
                    state<=WAIT_FEATURE; control_pending<=1; idle<=0; retry<=0;
                end else if((state==WAIT_FEATURE || state==UP) && rx_session==session && fresh) begin
                    case(rx_kind)
                        V7_FEATURE: if(feature_ok) begin
                            state<=UP; idle<=0; last_rx_seq<=rx_sequence; control_pending<=0;
                            feat_valid<=1; feat_pitch<=rx_payload[9:0]; feat_level<=rx_payload[23:16];
                            feat_voiced<=rx_payload[24]; teacher_voiced<=rx_payload[25];
                            teacher_preference<=rx_payload[26]; teacher_pitch<=rx_payload[41:32];
                            teacher_level<=rx_payload[55:48];
                            single_mic<=rx_payload[27];mic_teacher<=rx_payload[28];mic_ready<=rx_payload[29];
                            if(state!=UP) begin status_pending<=1; protocol_error<=0; end
                        end else protocol_error<=1;
                        V7_DEMO_ARMED: if(state==UP) begin
                            idle<=0; last_rx_seq<=rx_sequence;
                            if(demo_active && rx_question==question && !demo_cancel && !demo_request) tch_armed<=1;
                        end
                        V7_DEMO_CONTOUR: if(state==UP && rx_payload[7:0]>=10 && rx_payload[7:0]<=96 && rx_payload[23:18]==0) begin
                            idle<=0; last_rx_seq<=rx_sequence;
                            if(demo_active && tch_armed && rx_question==question && !demo_cancel && !demo_request) begin
                                tch_n<=rx_payload[6:0]; tch_shape<=rx_payload[151:24];
                                tch_new<=1; demo_active<=0; request_pending<=0;
                            end
                        end
                        V7_RESULT_ACK: if(state==UP) begin
                            idle<=0; last_rx_seq<=rx_sequence;
                            if(result_pending && rx_payload[15:0]==event_id) begin result_pending<=0; result_send<=0; end
                        end
                        default: protocol_error<=1;
                    endcase
                end
            end
            if(restart_now) begin
                state<=QUIET; flush<=1; send<=0; quiet_count<=0; idle<=0; retry<=0;
                control_pending<=0; status_pending<=0; request_pending<=0; cancel_pending<=0;
                result_pending<=0; result_send<=0; result_packing<=0;result_pack_index<=0;
                demo_active<=0; tch_armed<=0; tch_new<=0;
                feat_valid<=0; feat_voiced<=0; feat_level<=0; teacher_voiced<=0; teacher_level<=0;
                single_mic<=0;mic_teacher<=0;mic_ready<=0;
                tx_seq<=1; last_rx_seq<=0; question<=1; event_id<=0; teacher_preference<=0;
                if(rx_ver || (sc_valid && result_pending)) protocol_error<=1;
            end
        end
    end
endmodule
