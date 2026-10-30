`timescale 1ns/1ps

module dual_key_long_hold_guard #(
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter integer HOLD_CYCLES = 100000000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire enabled,
    input  wire key2_n,
    input  wire key3_n,
    output reg  trigger,
    output reg  locked,
    output reg  key2_stable_n,
    output reg  key3_stable_n
);
    localparam integer DB_BITS = (DEBOUNCE_CYCLES <= 2) ? 1 : $clog2(DEBOUNCE_CYCLES);
    localparam integer HOLD_BITS = (HOLD_CYCLES <= 2) ? 1 : $clog2(HOLD_CYCLES);

    reg key2_sync1, key2_sync2;
    reg key3_sync1, key3_sync2;
    reg [DB_BITS-1:0] key2_count;
    reg [DB_BITS-1:0] key3_count;
    reg [HOLD_BITS-1:0] hold_count;

    initial begin
        if (DEBOUNCE_CYCLES < 1 || HOLD_CYCLES < 1) begin
            $display("DUAL_KEY_GUARD_CONFIG_ERROR invalid timing parameter");
            $finish;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key2_sync1 <= 1'b1;
            key2_sync2 <= 1'b1;
            key3_sync1 <= 1'b1;
            key3_sync2 <= 1'b1;
        end else begin
            key2_sync1 <= key2_n;
            key2_sync2 <= key2_sync1;
            key3_sync1 <= key3_n;
            key3_sync2 <= key3_sync1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key2_count <= {DB_BITS{1'b0}};
            key3_count <= {DB_BITS{1'b0}};
            key2_stable_n <= 1'b1;
            key3_stable_n <= 1'b1;
            hold_count <= {HOLD_BITS{1'b0}};
            trigger <= 1'b0;
            locked <= 1'b0;
        end else begin
            trigger <= 1'b0;
            if (key2_sync2 == key2_stable_n)
                key2_count <= {DB_BITS{1'b0}};
            else if (key2_count + 1 >= DEBOUNCE_CYCLES) begin
                key2_count <= {DB_BITS{1'b0}};
                key2_stable_n <= key2_sync2;
            end else key2_count <= key2_count + 1'b1;

            if (key3_sync2 == key3_stable_n)
                key3_count <= {DB_BITS{1'b0}};
            else if (key3_count + 1 >= DEBOUNCE_CYCLES) begin
                key3_count <= {DB_BITS{1'b0}};
                key3_stable_n <= key3_sync2;
            end else key3_count <= key3_count + 1'b1;

            if (!enabled || locked || key2_stable_n || key3_stable_n) begin
                hold_count <= {HOLD_BITS{1'b0}};
            end else if (hold_count + 1 >= HOLD_CYCLES) begin
                hold_count <= {HOLD_BITS{1'b0}};
                trigger <= 1'b1;
                locked <= 1'b1;
            end else begin
                hold_count <= hold_count + 1'b1;
            end
        end
    end
endmodule

