// Temporary T5 observation only; does not drive the video/PHY datapath.
// flags: {gray AXI transfer, SOF transfer, EOL transfer, gray selected,
//         ch0 gray seen, ch1 gray seen, ch2 gray seen, 640 gray words in a row}.
// Clear on leaving gray mode. A full gray line uses either legal disparity
// encoding of RGB byte 8'h80; isolated matching packet words cannot set bit0.
module hdmi_gray_probe_v8 (
    input wire clk, rst_n, enable,
    input wire valid, ready, user, last,
    input wire [23:0] rgb,
    input wire [9:0] ch0, ch1, ch2,
    output reg [7:0] flags
);
    wire g0 = ch0 == 10'h180 || ch0 == 10'h37f;
    wire g1 = ch1 == 10'h180 || ch1 == 10'h37f;
    wire g2 = ch2 == 10'h180 || ch2 == 10'h37f;
    reg [9:0] gray_run;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flags <= 8'd0;
            gray_run <= 10'd0;
        end else if (!enable) begin
            flags <= 8'd0;
            gray_run <= 10'd0;
        end else begin
            flags[7] <= flags[7] || (valid && ready && rgb == 24'h808080);
            flags[6] <= flags[6] || (valid && ready && user);
            flags[5] <= flags[5] || (valid && ready && last);
            flags[4] <= 1'b1;
            flags[3] <= flags[3] || g0;
            flags[2] <= flags[2] || g1;
            flags[1] <= flags[1] || g2;
            if (!flags[0]) begin
                if (g0 && g1 && g2) begin
                    if (gray_run == 10'd639)
                        flags[0] <= 1'b1;
                    else
                        gray_run <= gray_run + 10'd1;
                end else
                    gray_run <= 10'd0;
            end
        end
    end
endmodule
