`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// lesson25 sync_2ff
// 单比特电平同步器：异步域来的一根慢变电平，进目的时钟域先过两级触发器。
// 合同边界：
//   - 只适用于"单比特、慢变"信号（源域保持时间远大于两个目的域时钟周期）；
//   - 多位总线禁止逐位2FF（各位到达拍数可能不同→撕裂，本课负例一专门演）；
//   - 单拍脉冲禁止直接2FF（可能整拍落在两个目的沿之间被漏采→用pulse_sync）。
// RESET_VAL：复位时的输出电平，按信号空闲态选择（如低有效sync选1）。
// 第07课按键2FF、第17课monitor同步链都是本模块的先例，本课把它正式定名封存。
// -----------------------------------------------------------------------------
module sync_2ff #(
    parameter RESET_VAL = 1'b0   // 复位输出电平=信号空闲态
)(
    input  wire clk,       // 目的时钟域
    input  wire rst_n,     // 目的域低有效复位
    input  wire async_in,  // 异步输入（源域电平）
    output wire sync_out   // 目的域同步后的电平
);

    (* async_reg = "true" *) reg s1, s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= RESET_VAL;
            s2 <= RESET_VAL;
        end else begin
            s1 <= async_in;
            s2 <= s1;
        end
    end

    assign sync_out = s2;

endmodule
