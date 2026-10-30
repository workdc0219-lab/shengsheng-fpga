`timescale 1ns/1ps
// One physical CH2 microphone, explicit role buttons. Both held is a no-op.
// No samples leave this router during role settling. Trackers are
// reset across a role change and refill their windows before publication.
module single_mic_control #(
    parameter integer DEBOUNCE_CYCLES=500000,
    parameter integer GUARD_CYCLES=5000000
)(
    input wire clk,rst_n,key_teacher_n,key_child_n,
    input wire sample_valid,
    input wire signed [15:0] sample,
    output reg teacher_selected,
    output reg role_changed,
    output wire settling,
    output wire child_valid,teacher_valid,
    output wire signed [15:0] routed_sample
);
    reg [1:0] tm,cm,keys_stable,keys_candidate;
    reg [19:0] debounce_count;
    reg press_used;
    reg [22:0] guard_count;
    wire [1:0] keys_sync={tm[1],cm[1]};
    assign settling=(guard_count!=0) || role_changed;
    assign child_valid=sample_valid && !settling && !teacher_selected;
    assign teacher_valid=sample_valid && !settling && teacher_selected;
    assign routed_sample=sample;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            tm<=2'b11;cm<=2'b11;keys_stable<=2'b11;keys_candidate<=2'b11;debounce_count<=0;
            press_used<=0;teacher_selected<=0;role_changed<=0;guard_count<=GUARD_CYCLES;
        end else begin
            tm<={tm[0],key_teacher_n};cm<={cm[0],key_child_n};
            role_changed<=0;
            if(guard_count!=0)guard_count<=guard_count-1'b1;
            if(keys_sync!=keys_candidate)begin keys_candidate<=keys_sync;debounce_count<=0;end
            else if(keys_sync==keys_stable)debounce_count<=0;
            else if(debounce_count==DEBOUNCE_CYCLES-1)begin
                keys_stable<=keys_sync;debounce_count<=0;
            end else debounce_count<=debounce_count+1'b1;
            if(keys_stable==2'b11)press_used<=0;
            else if(!press_used)begin
                press_used<=1;
                if((keys_stable==2'b01 && !teacher_selected) ||
                   (keys_stable==2'b10 && teacher_selected))begin
                    teacher_selected<=!keys_stable[1];
                    role_changed<=1;guard_count<=GUARD_CYCLES;
                end
            end
        end
    end
endmodule
