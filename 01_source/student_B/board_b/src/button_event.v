`timescale 1ns / 1ps

module button_event #(
    parameter integer CLK_HZ = 50000000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,
    output reg  press,
    output reg  level
);
    localparam integer STABLE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer CNT_W = 20;
    reg key_m, key_s;
    reg [CNT_W-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_m <= 1'b1;
            key_s <= 1'b1;
        end else begin
            key_m <= key_n;
            key_s <= key_m;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= {CNT_W{1'b0}};
            level <= 1'b0;
            press <= 1'b0;
        end else begin
            press <= 1'b0;
            if ((~key_s) == level) begin
                cnt <= {CNT_W{1'b0}};
            end else if (cnt == STABLE_CYCLES - 1) begin
                cnt   <= {CNT_W{1'b0}};
                level <= ~key_s;
                if (~key_s)
                    press <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
