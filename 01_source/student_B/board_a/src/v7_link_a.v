`timescale 1ns/1ps
// Product A endpoint. B owns sessions; a reset A emits HELLO, not stale
// results. Only a committed live session can arm capture or publish results.
module v7_link_a #(
    parameter integer SINGLE_MIC=0,
    parameter integer CLKS_PER_BIT=27,
    parameter integer LINK_TIMEOUT=18750000,
    parameter integer RETRY_CLOCKS=2500000,
    parameter integer TX_LIMIT=65534
)(
    input wire clk,rst_n,rx,
    output wire tx,
    input wire feature_valid,child_voiced,teacher_voiced,teacher_preference,
    input wire mic_teacher,mic_ready,
    input wire [9:0] child_pitch,teacher_pitch,
    input wire [7:0] child_level,teacher_level,
    output reg capture_arm,capture_cancel,
    input wire capture_armed,capture_done,
    input wire [6:0] capture_n,
    input wire [9:0] capture_mean,
    input wire [127:0] capture_shape,
    output reg demo_armed,
    output reg [127:0] demo_shape,
    output wire link_up,
    output reg protocol_error,
    output reg [2:0] mode,phase,target,tone,
    output reg [1:0] q_idx,eff_diff,stars,
    output reg tch_used,teacher_on,teacher_waiting,res_new,too_short,
    output reg [15:0] res_event,
    output reg [6:0] score,n_points,
    output reg [127:0] shape
);
    `include "v7_defs.vh"
    localparam [1:0] DOWN=0,WAIT_COMMIT=1,UP=2;
    reg [1:0] state;
    assign link_up=(state==UP);
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
    reg [15:0] session,tx_seq,last_rx_seq,last_event,demo_q,context_q;
    reg [31:0] idle,retry;
    reg control_pending,feature_pending,armed_pending,contour_pending,ack_pending;
    reg demo_active,contour_ready;
    reg [15:0] ack_event;
    reg [71:0] feature_snapshot;
    reg [151:0] contour_snapshot;
    wire fresh = rx_sequence>last_rx_seq && rx_sequence<16'hFFFF;
    wire result_fields_ok = (rx_payload[23:16]==1 || rx_payload[23:16]==4) &&
        rx_payload[31:24]>=1 && rx_payload[31:24]<=4 &&
        rx_payload[39:34]==0 && rx_payload[47:40]<=100 &&
        rx_payload[55:48]<=3 && rx_payload[63:56]<=96 && rx_payload[71:64]<=7 &&
        rx_payload[87:80]<4 && rx_payload[15:0]!=0 && rx_payload[15:0]<16'hFFFE &&
        rx_question!=0 && rx_question<16'hFFFE &&
        (rx_payload[32] ? (rx_payload[63:56]<10 && rx_payload[47:40]==0 && rx_payload[55:48]==0) :
                          (rx_payload[63:56]>=10));
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=DOWN; flush<=0; send<=0; tx_kind<=0; tx_len<=0;
            tx_session<=0; tx_sequence<=0; tx_question<=0; tx_payload<=0;
            session<=0; tx_seq<=1; last_rx_seq<=0; last_event<=0; demo_q<=0; context_q<=0;
            idle<=0; retry<=0; control_pending<=1; feature_pending<=0;
            armed_pending<=0; contour_pending<=0; ack_pending<=0; ack_event<=0;
            demo_active<=0; contour_ready<=0; feature_snapshot<=0; contour_snapshot<=0;
            capture_arm<=0; capture_cancel<=0; demo_armed<=0; demo_shape<=0;
            protocol_error<=0; mode<=0; phase<=0; target<=0; tone<=0;
            q_idx<=0; eff_diff<=0; stars<=0; tch_used<=0; teacher_on<=0; teacher_waiting<=0;
            res_new<=0; too_short<=0; res_event<=0; score<=0; n_points<=0; shape<=0;
        end else begin
            flush<=0; send<=0; capture_arm<=0; capture_cancel<=0; res_new<=0;
            if(rx_bad) protocol_error<=1;
            if(idle<LINK_TIMEOUT) idle<=idle+1'b1;
            if(retry>=RETRY_CLOCKS-1) begin
                retry<=0;
                if(state!=UP) control_pending<=1;
                else if(demo_active && contour_ready) contour_pending<=1;
            end else retry<=retry+1'b1;
            if(feature_valid && state==UP) begin
                feature_snapshot<={16'd0,teacher_level,6'd0,teacher_pitch,
                    2'd0,(SINGLE_MIC!=0 && mic_ready),(SINGLE_MIC!=0 && mic_teacher),(SINGLE_MIC!=0),teacher_preference,teacher_voiced,child_voiced,child_level,6'd0,child_pitch};
                feature_pending<=1;
            end
            if(capture_armed && demo_active && !demo_armed) begin demo_armed<=1; armed_pending<=1; end
            if(capture_done && demo_active && demo_armed) begin
                contour_snapshot<={capture_shape,6'd0,capture_mean,1'b0,capture_n};
                demo_shape<=capture_shape; contour_ready<=1; contour_pending<=1;
            end

            if(ready && !send && !flush) begin
                tx_session<=session; tx_sequence<=tx_seq; tx_question<=context_q;
                tx_payload<=0;
                if(control_pending) begin
                    tx_kind<=(state==DOWN)?V7_HELLO:V7_SYNC_ACK; tx_len<=0;
                    tx_sequence<=0; tx_question<=0; send<=1; control_pending<=0;
                end else if(state==UP && tx_seq<TX_LIMIT) begin
                    if(ack_pending) begin
                        tx_kind<=V7_RESULT_ACK; tx_len<=V7_LEN_RESULT_ACK;
                        tx_payload[15:0]<=ack_event; ack_pending<=0; send<=1; tx_seq<=tx_seq+1'b1;
                    end else if(armed_pending && demo_active) begin
                        tx_kind<=V7_DEMO_ARMED; tx_len<=0; tx_question<=demo_q;
                        armed_pending<=0; send<=1; tx_seq<=tx_seq+1'b1;
                    end else if(contour_pending && demo_active && contour_ready) begin
                        tx_kind<=V7_DEMO_CONTOUR; tx_len<=V7_LEN_DEMO_CONTOUR;
                        tx_payload[151:0]<=contour_snapshot; tx_question<=demo_q;
                        contour_pending<=0; send<=1; tx_seq<=tx_seq+1'b1;
                    end else if(feature_pending) begin
                        tx_kind<=V7_FEATURE; tx_len<=V7_LEN_FEATURE;
                        tx_payload[71:0]<=feature_snapshot;
                        feature_pending<=feature_valid; send<=1; tx_seq<=tx_seq+1'b1;
                    end
                end
            end

            if(rx_valid) begin
                if(rx_kind==V7_SYNC && rx_session!=0 && rx_sequence==0) begin
                    // Duplicate SYNC while waiting merely repeats ACK. An UP
                    // session always invalidates before accepting a new SYNC.
                    if(state!=WAIT_COMMIT || session!=rx_session) begin
                        flush<=1; send<=0; capture_cancel<=1; demo_active<=0; demo_armed<=0;
                        feature_pending<=0; contour_pending<=0; armed_pending<=0; ack_pending<=0;
                        contour_ready<=0; last_event<=0; tx_seq<=1; last_rx_seq<=0;
                        tch_used<=0; teacher_on<=0; teacher_waiting<=0; mode<=0; phase<=0; demo_shape<=0;
                    end
                    state<=WAIT_COMMIT; session<=rx_session; idle<=0; retry<=0; control_pending<=1;
                end else if(state==WAIT_COMMIT && rx_kind==V7_SYNC_COMMIT &&
                            rx_session==session && rx_sequence==0) begin
                    state<=UP; idle<=0; control_pending<=0; last_rx_seq<=0; protocol_error<=0;
                end else if(state==UP && rx_session==session && fresh) begin
                    case(rx_kind)
                        V7_STATUS: if(rx_payload[7:0]<=5 && rx_payload[15:8]<=5 &&
                                      rx_payload[23:16]<=4 && rx_payload[31:24]<=3 &&
                                      rx_payload[39:32]<=3 && rx_payload[47:43]==0) begin
                            idle<=0; last_rx_seq<=rx_sequence; context_q<=rx_question;
                            mode<=rx_payload[2:0]; phase<=rx_payload[10:8];
                            q_idx<=rx_payload[25:24]; eff_diff<=rx_payload[33:32];
                            tch_used<=rx_payload[40]; teacher_on<=teacher_preference; teacher_waiting<=rx_payload[42];
                        end else protocol_error<=1;
                        V7_DEMO_REQUEST: begin
                            idle<=0; last_rx_seq<=rx_sequence;
                            if(!demo_active || demo_q!=rx_question) begin
                                capture_arm<=1; demo_q<=rx_question; demo_active<=1; demo_armed<=0;
                                contour_ready<=0; contour_pending<=0; armed_pending<=0;
                            end else if(demo_armed) begin
                                armed_pending<=1;
                                if(contour_ready) contour_pending<=1;
                            end
                        end
                        V7_DEMO_CANCEL: begin
                            idle<=0; last_rx_seq<=rx_sequence;
                            capture_cancel<=1; demo_active<=0; demo_armed<=0;
                            armed_pending<=0; contour_pending<=0; contour_ready<=0;
                        end
                        V7_RESULT: if(result_fields_ok) begin
                            idle<=0; last_rx_seq<=rx_sequence;
                            ack_event<=rx_payload[15:0]; ack_pending<=1;
                            if(rx_payload[15:0]>last_event) begin
                                last_event<=rx_payload[15:0]; res_event<=rx_payload[15:0]; res_new<=1;
                                mode<=rx_payload[18:16]; target<=rx_payload[26:24];
                                q_idx<=rx_payload[25:24]-2'd1;
                                too_short<=rx_payload[32]; tch_used<=rx_payload[33]; tone<=0;
                                score<=rx_payload[46:40]; stars<=rx_payload[49:48];
                                n_points<=rx_payload[62:56]; shape<=rx_payload[215:88];
                            end
                        end else protocol_error<=1;
                        default: protocol_error<=1;
                    endcase
                end
            end
            // Final-priority invalidation: never publish from a stale session.
            if((state!=DOWN && idle>=LINK_TIMEOUT-1 && !rx_valid) ||
               (state==UP && tx_seq>=TX_LIMIT && ready && !send && !flush) || rx_ver) begin
                state<=DOWN; flush<=1; send<=0; idle<=0; retry<=0; control_pending<=1;
                feature_pending<=0; ack_pending<=0; armed_pending<=0; contour_pending<=0;
                capture_cancel<=1; demo_active<=0; demo_armed<=0; contour_ready<=0;
                res_new<=0; tch_used<=0; teacher_on<=0; teacher_waiting<=0; mode<=0; phase<=0;
            end
        end
    end
endmodule
