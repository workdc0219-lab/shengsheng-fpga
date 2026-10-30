`timescale 1ns/1ps
// Teacher contour capture (docs/14 section 2). Board A runs this on the ch3
// teacher channel: every finished utterance becomes a 16-point pitch shape
// that Board B draws as the target mountain.
//
// Segmentation, octave guard and the 16-bin layout follow
// board_b/src/tone_scorer.v: after an explicit arm and three quiet frames,
// three new voiced
// frames open an utterance, 24 unvoiced frames or 96 points close it, fewer
// than 10 points is discarded; bin k covers [k*n>>4, (k+1)*n>>4), an empty
// bin takes the point at its lower index. The bin mean is a rounded integer
// division done serially -- Board A has no free DSP block, so the scorer's
// sum*recip multiply is not an option here. Output: off[k] = clamp(binv[k] -
// mean, -127, 127) with mean = sum(binv) >> 4, packed [k*8 +: 8].
module contour_capture (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         frame_valid,
    input  wire         voiced,
    input  wire [9:0]   pitch_q4,
    output reg          done,            // 1-clk pulse: off_flat/n_out/mean_out new
    output reg  [6:0]   n_out,
    output reg  [9:0]   mean_out,
    output reg  [127:0] off_flat,
    input  wire         arm,
    input  wire         cancel,
    output reg          armed           // request accepted; one result per arm
);
    localparam integer END_FRAMES = 24;
    localparam integer MAX_POINTS = 96;
    localparam integer MIN_POINTS = 10;

    // ------------------------------------------------------ point memory
    reg [9:0] pts [0:127];
    reg [6:0] wr_addr;
    reg [9:0] wr_data;
    reg wr_en;
    reg [6:0] rd_j;
    reg [9:0] rd_data;
    always @(posedge clk) begin
        if (wr_en && rst_n && !arm && !cancel)
            pts[wr_addr] <= wr_data;
        rd_data <= pts[rd_j];
    end

    function [9:0] guard;                    // tone_scorer.guard, verbatim
        input [9:0] p;
        input [9:0] last;
        reg signed [11:0] d;
        reg signed [11:0] dm, dp;
        reg signed [11:0] v;
        begin
            d = $signed({2'b00, p}) - $signed({2'b00, last});
            dm = d - 12'sd192;
            dp = d + 12'sd192;
            v = $signed({2'b00, p});
            if ((d >= 12'sd144) || (d <= -12'sd144)) begin
                if (dm > -12'sd48 && dm < 12'sd48)
                    v = v - 12'sd192;
                else if (dp > -12'sd48 && dp < 12'sd48)
                    v = v + 12'sd192;
                else
                    v = $signed({2'b00, last});
            end
            guard = (v < 0) ? 10'd0 : (v > 12'sd1023) ? 10'd1023 : v[9:0];
        end
    endfunction

    localparam [3:0] ST_IDLE = 4'd0, ST_ON1 = 4'd1, ST_ON2 = 4'd2, ST_ACT = 4'd3,
                     FB_START = 4'd4, FB_ISSUE = 4'd5, FB_TAKE = 4'd6,
                     FB_DIV = 4'd7, FB_NEXT = 4'd8, MN_SUM = 4'd9, OF_OUT = 4'd10;
    reg [3:0] st;
    reg [1:0] run_len;
    reg [9:0] run0, run1, onset_p, last_pt;
    reg [6:0] n;
    reg [5:0] uv;
    reg in_utt;
    reg [1:0] quiet_count;
    reg quiet_ready;

    reg [3:0] k;
    reg [10:0] kn;
    reg [2:0] cnt, remain;
    reg [12:0] bsum;
    reg [9:0] binv [0:15];
    reg [13:0] bin_total;
    // serial divider: quo = (bsum + cnt/2) / cnt
    reg [13:0] dvd, quo;
    reg [3:0] rem;
    reg [3:0] it;

    wire [10:0] kn_next = kn + {4'd0, n};
    wire [6:0] lo_idx = kn[10:4];
    wire [6:0] hi_idx = kn_next[10:4];

    reg [9:0] g_src;
    always @* begin
        case (st)
            ST_ON1:  g_src = run1;
            ST_ON2:  g_src = onset_p;
            default: g_src = pitch_q4;
        endcase
    end
    wire [9:0] g_val = guard(g_src, last_pt);

    wire [3:0] div_t = {rem[2:0], dvd[13]};
    wire div_ge = (div_t >= {1'b0, cnt});
    wire signed [11:0] off_d = $signed({2'b00, binv[k]}) - $signed({2'b00, bin_total[13:4]});
    wire [7:0] off_c = (off_d > 12'sd127) ? 8'd127 :
                       (off_d < -12'sd127) ? 8'h81 : off_d[7:0];

    integer bi;
    always @(posedge clk or negedge rst_n) begin
        // Cancellation is synchronous and dominates simultaneous arm/frame/done.
        // Re-arm discards every stage of the previous utterance and result.
        if (!rst_n) begin
            st <= ST_IDLE; run_len <= 2'd0; run0 <= 10'd0; run1 <= 10'd0;
            onset_p <= 10'd0; last_pt <= 10'd0; n <= 7'd0; uv <= 6'd0; in_utt <= 1'b0;
            wr_en <= 1'b0; wr_addr <= 7'd0; wr_data <= 10'd0; rd_j <= 7'd0;
            k <= 4'd0; kn <= 11'd0; cnt <= 3'd0; remain <= 3'd0; bsum <= 13'd0;
            bin_total <= 14'd0; dvd <= 14'd0; quo <= 14'd0; rem <= 4'd0; it <= 4'd0;
            done <= 1'b0; n_out <= 7'd0; mean_out <= 10'd0; off_flat <= 128'd0;
            armed <= 1'b0;
            quiet_count <= 2'd0; quiet_ready <= 1'b0;
            for (bi = 0; bi < 16; bi = bi + 1) binv[bi] <= 10'd0;
        end else if (cancel || arm) begin
            // Keep this a separate synchronous branch: TD must infer the
            // asynchronous reset solely from rst_n with constant values.
            st <= ST_IDLE; run_len <= 2'd0; run0 <= 10'd0; run1 <= 10'd0;
            onset_p <= 10'd0; last_pt <= 10'd0; n <= 7'd0; uv <= 6'd0; in_utt <= 1'b0;
            wr_en <= 1'b0; wr_addr <= 7'd0; wr_data <= 10'd0; rd_j <= 7'd0;
            k <= 4'd0; kn <= 11'd0; cnt <= 3'd0; remain <= 3'd0; bsum <= 13'd0;
            bin_total <= 14'd0; dvd <= 14'd0; quo <= 14'd0; rem <= 4'd0; it <= 4'd0;
            done <= 1'b0; n_out <= 7'd0; mean_out <= 10'd0; off_flat <= 128'd0;
            armed <= arm && !cancel;
            quiet_count <= 2'd0; quiet_ready <= 1'b0;
            for (bi = 0; bi < 16; bi = bi + 1) binv[bi] <= 10'd0;
        end else begin
            done <= 1'b0;
            wr_en <= 1'b0;
            if (armed) begin
            case (st)
            ST_IDLE, ST_ACT: begin
                if (frame_valid) begin
                    if (!quiet_ready) begin
                        if (voiced) quiet_count <= 2'd0;
                        else if (quiet_count == 2'd2) quiet_ready <= 1'b1;
                        else quiet_count <= quiet_count + 1'b1;
                    end else if (!in_utt) begin
                        if (voiced) begin
                            if (run_len == 2'd0) begin
                                run0 <= pitch_q4; run_len <= 2'd1;
                            end else if (run_len == 2'd1) begin
                                run1 <= pitch_q4; run_len <= 2'd2;
                            end else begin
                                onset_p <= pitch_q4;
                                run_len <= 2'd0;
                                in_utt <= 1'b1;
                                uv <= 6'd0;
                                wr_en <= 1'b1; wr_addr <= 7'd0; wr_data <= run0;
                                last_pt <= run0;
                                n <= 7'd1;
                                st <= ST_ON1;
                            end
                        end else begin
                            run_len <= 2'd0;
                        end
                    end else if (voiced) begin
                        uv <= 6'd0;
                        wr_en <= 1'b1; wr_addr <= n; wr_data <= g_val;
                        last_pt <= g_val;
                        n <= n + 1'b1;
                        if (n + 1'b1 >= MAX_POINTS) begin
                            k <= 4'd0; kn <= 11'd0;
                            st <= FB_START;
                        end
                    end else begin
                        uv <= uv + 1'b1;
                        if (uv + 1'b1 >= END_FRAMES) begin
                            if (n < MIN_POINTS) begin
                                in_utt <= 1'b0; n <= 7'd0; uv <= 6'd0;
                                st <= ST_IDLE;
                            end else begin
                                k <= 4'd0; kn <= 11'd0;
                                st <= FB_START;
                            end
                        end
                    end
                end
            end
            ST_ON1: begin
                wr_en <= 1'b1; wr_addr <= 7'd1; wr_data <= g_val;
                last_pt <= g_val;
                n <= 7'd2;
                st <= ST_ON2;
            end
            ST_ON2: begin
                wr_en <= 1'b1; wr_addr <= 7'd2; wr_data <= g_val;
                last_pt <= g_val;
                n <= 7'd3;
                st <= ST_ACT;
            end
            FB_START: begin
                rd_j <= lo_idx;
                cnt <= (hi_idx > lo_idx) ? (hi_idx - lo_idx) : 3'd0;
                remain <= (hi_idx > lo_idx) ? (hi_idx - lo_idx) : 3'd0;
                bsum <= 13'd0;
                st <= FB_ISSUE;
            end
            FB_ISSUE: st <= FB_TAKE;                  // read latency
            FB_TAKE: begin
                if (cnt == 3'd0) begin
                    binv[k] <= rd_data;
                    st <= FB_NEXT;
                end else if (remain == 3'd1) begin
                    dvd <= {1'b0, bsum + rd_data} + {11'd0, cnt[2:1]};
                    quo <= 14'd0; rem <= 4'd0; it <= 4'd0;
                    st <= FB_DIV;
                end else begin
                    bsum <= bsum + rd_data;
                    remain <= remain - 1'b1;
                    rd_j <= rd_j + 1'b1;
                    st <= FB_ISSUE;
                end
            end
            FB_DIV: begin
                rem <= div_ge ? div_t - {1'b0, cnt} : div_t;
                quo <= {quo[12:0], div_ge};
                dvd <= {dvd[12:0], 1'b0};
                it <= it + 1'b1;
                if (it == 4'd13) begin
                    binv[k] <= {quo[8:0], div_ge};   // quotient <= 1023
                    st <= FB_NEXT;
                end
            end
            FB_NEXT: begin
                if (k == 4'd15) begin
                    k <= 4'd0;
                    bin_total <= 14'd0;
                    st <= MN_SUM;
                end else begin
                    k <= k + 1'b1;
                    kn <= kn_next;
                    st <= FB_START;
                end
            end
            MN_SUM: begin
                bin_total <= bin_total + binv[k];
                k <= k + 1'b1;
                if (k == 4'd15)
                    st <= OF_OUT;                     // k wraps to 0
            end
            OF_OUT: begin
                off_flat[k*8 +: 8] <= off_c;
                k <= k + 1'b1;
                if (k == 4'd15) begin
                    n_out <= n;
                    mean_out <= bin_total[13:4];
                    done <= 1'b1;
                    armed <= 1'b0;
                    in_utt <= 1'b0; n <= 7'd0; uv <= 6'd0; run_len <= 2'd0;
                    st <= ST_IDLE;
                end
            end
            default: st <= ST_IDLE;
            endcase
            end
        end
    end
endmodule
