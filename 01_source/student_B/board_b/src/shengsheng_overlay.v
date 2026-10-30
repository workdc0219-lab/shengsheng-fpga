`timescale 1ns/1ps
// ShengSheng training-screen renderer (docs/39 section 5, docs/40 2.5).
//
// Two registered stages: RGB, DE, VSYNC and X leave two clocks after they
// enter, so the downstream HDMI stream sees one consistent, delayed frame.
// Text bitmaps and the two curve column buffers are read one pixel ahead
// (address for x+1 while x is on the wire) so their synchronous RAM data is
// aligned with the pixel that stage A evaluates.
//
// Layers, top priority first: text slots, pitch ball, child curve, target
// path, balloon/train/meter, card highlight, Chao-level grid, darkened
// panel and text bands, background. enable=0 passes RGB through unchanged.
module shengsheng_overlay (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire        summary_show,     // F1: session summary screen
    input  wire        discover_show,    // F2: voice discovery mode
    input  wire [7:0]  disc_radius,      // F2: visualization circle size
    input  wire [2:0]  disc_hue,         // F2: visualization color index
    input  wire [7:0]  sess_q,           // F1: session question count
    input  wire [7:0]  sess_star,        // F1: session star count
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    output reg         vsync_out,
    output reg         de_out,
    output reg  [9:0]  pixel_x_out,
    output reg  [23:0] rgb_out,
    // scene control (video clock domain)
    input  wire        enable,
    input  wire        high_contrast,
    input  wire        panel_show,
    input  wire        child_show,
    input  wire [9:0]  target_reveal,      // columns below this are visible
    input  wire        ball_show,
    input  wire [8:0]  ball_col,
    input  wire [7:0]  ball_y,
    input  wire        balloon_show,
    input  wire [7:0]  balloon_r,
    input  wire        train_show,
    input  wire [9:0]  train_x,
    input  wire [7:0]  meter_level,
    input  wire [7:0]  win_lo,
    input  wire [7:0]  win_hi,
    input  wire        meter_ok,
    input  wire        card_show,
    // R73: three-star celebration pulse on the mountain ridge, and the
    // live loudness meter shown during LISTEN before anything is voiced
    input  wire        celebrate,
    input  wire        listen_meter,
    input  wire [1:0]  card_index,
    input  wire [5:0]  s0_id,
    input  wire [5:0]  s1_id,
    input  wire [47:0] s2_cells,   // 8 cells, LSB cell = leftmost slot
    input  wire [5:0]  s3_id,
    input  wire [1:0]  s3_class,
    // column-buffer drawer
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_buf,             // 0 = target path, 1 = child curve
    input  wire [8:0]  cmd_x0,
    input  wire [3:0]  cmd_log2n,
    input  wire [7:0]  cmd_y0,
    input  wire [7:0]  cmd_y1,
    input  wire        cmd_vis
);
`include "ss_phrases.vh"

    // Eight 24 px slots. Word-mode results are in the feedback band; summary
    // values are 2x. The top bar contains task, target and completed / 10 only.
`include "ui_config.vh"
    localparam integer S2_CELL_W = 24;
    localparam integer S2_CELLS = 8;
    localparam integer S2_X1 = 624;
    localparam integer S2_X0 = S2_X1 - S2_CELL_W * S2_CELLS;   // 432
    localparam integer PANEL_X0 = UI_CHILD_TASK_X, PANEL_X1 = UI_CHILD_TASK_X + UI_CHILD_TASK_W;
    localparam integer PANEL_Y0 = UI_CHILD_TASK_Y, PANEL_Y1 = UI_CHILD_TASK_Y + UI_CHILD_TASK_H;
    localparam integer CURVE_X0 = UI_CHILD_CURVE_X;
    localparam integer TOP_Y0 = 8, FB_Y0 = UI_CHILD_FEEDBACK_Y;
    localparam integer S0_X = 16;
    localparam integer BAL_CX = UI_CHILD_BALLOON_CENTER_X, BAL_CY = UI_CHILD_BALLOON_CENTER_Y;
    localparam [23:0] C_S0 = UI_CHILD_INK, C_S1 = UI_REFERENCE_CURVE, C_S2 = UI_CHILD_INK;
    localparam [23:0] C_GOOD = UI_SUCCESS, C_HINT = UI_WARNING, C_INFO = UI_CHILD_INK,
                      C_CYAN = UI_CHILD_INK;
    // tone climb: the target contour is drawn as a mountain (ridge + two
    // depth bands), the child's voice as an outlined trail with a climber ball
    // opaque body in four depth bands (32/32/64/rest px below the ridge),
    // each with a darker terrace line every 16 px that follows the ridge
    localparam [23:0] C_RIDGE = UI_REFERENCE_CURVE, C_MOUNT = 24'hAAC8AE;
    localparam [23:0] C_M0 = 24'hC9DDC7, C_M1 = 24'hBDD5BC, C_M2 = 24'hB0CDB2, C_M3 = 24'hAAC8AE;
    localparam [23:0] C_T0 = 24'hBDD5BC, C_T1 = 24'hB0CDB2, C_T2 = 24'hAAC8AE, C_T3 = 24'h9DBEAA;
    localparam [23:0] C_CHILD = UI_CHILD_CURVE, C_EDGE = UI_CHILD_INK, C_BALL = UI_CHILD_CURVE;
    localparam [23:0] C_TARGET = UI_SUCCESS;
    localparam [23:0] C_SHLD = 24'hDDE8D5;
    localparam [23:0] C_BALLOON = 24'hD99381, C_BALLOON_RIM = 24'hB97061,
                      C_BALLOON_HI = 24'hF2D5C7, C_STRING = 24'h736451;
    // locomotive
    localparam [23:0] C_BOILER = 24'hE8483C, C_CAB = 24'hB73229, C_WINDOW = 24'hC4ECFF,
                      C_GOLDBAND = 24'hFFC83D, C_WHEEL = 24'h26262C,
                      C_HUB = 24'hB8BCC6, C_SMOKE = 24'hFFFFFF;
    localparam [23:0] C_RAIL = 24'h9097A3, C_SLEEPER = 24'h7A5230, C_FLAG = 24'h5CFF85,
                      C_POLE = 24'hF4F4F4, C_FRAME = 24'hF4F4F4, C_CARD = 24'hFFE14D;

    // ------------------------------------------------------ line counter
    reg [11:0] line_y;
    reg de_q, vs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0; de_q <= 1'b0; vs_q <= 1'b1;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
        end
    end

    // ------------------------------------------------------ descriptors
    // One phrase_desc decoder, walked over the nine text slots once per
    // frame while VSYNC is active, so text never changes mid-frame and the
    // 43-entry descriptor table is built only once.
    reg [31:0] d0, d1, d3;
    reg [31:0] dc [0:7];
    reg [3:0] fetch_k;
    reg [5:0] fetch_id;
    always @* begin
        case (fetch_k)
            4'd0: fetch_id = s0_id;
            4'd1: fetch_id = s1_id;
            4'd2: fetch_id = s3_id;
            4'd3: fetch_id = s2_cells[0 +: 6];
            4'd4: fetch_id = s2_cells[6 +: 6];
            4'd5: fetch_id = s2_cells[12 +: 6];
            4'd6: fetch_id = s2_cells[18 +: 6];
            4'd7: fetch_id = s2_cells[24 +: 6];
            4'd8: fetch_id = s2_cells[30 +: 6];
            4'd9: fetch_id = s2_cells[36 +: 6];
            default: fetch_id = s2_cells[42 +: 6];
        endcase
    end
    wire [31:0] fetch_desc = phrase_desc(fetch_id);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_k <= 4'd15;
            d0 <= 31'd0; d1 <= 31'd0; d3 <= 31'd0;
            dc[0] <= 31'd0; dc[1] <= 31'd0; dc[2] <= 31'd0;
            dc[3] <= 31'd0; dc[4] <= 31'd0; dc[5] <= 31'd0;
            dc[6] <= 31'd0; dc[7] <= 31'd0;
        end else begin
            if (vs_q && !vsync)
                fetch_k <= 4'd0;
            else if (fetch_k != 4'd15)
                fetch_k <= fetch_k + 1'b1;
            case (fetch_k)
                4'd0: d0 <= fetch_desc;
                4'd1: d1 <= fetch_desc;
                4'd2: d3 <= fetch_desc;
            4'd3: dc[0] <= fetch_desc;
            4'd4: dc[1] <= fetch_desc;
            4'd5: dc[2] <= fetch_desc;
            4'd6: dc[3] <= fetch_desc;
            4'd7: dc[4] <= fetch_desc;
            4'd8: dc[5] <= fetch_desc;
            4'd9: dc[6] <= fetch_desc;
            4'd10: dc[7] <= fetch_desc;
                default: ;
            endcase
        end
    end
    wire word_scene = (s0_id == PH_MODE_TONE) || (s0_id == PH_MODE_CARD);
    wire feedback_score = word_scene && (s2_cells != 48'd0);
    wire [9:0] w0 = d0[9:0], w1 = d1[9:0], w3 = d3[9:0];
    wire [9:0] x1 = 10'd320 - {1'b0, w1[9:1]};
    wire [9:0] x3 = feedback_score ? 10'd24 : 10'd320 - {1'b0, w3[9:1]};

    // Share the original phrase ROM read port: only the addressed pixel's
    // label is decoded. No second texture, memory or additional video stage.
    localparam [31:0] D_ROUND = phrase_desc(PH_ROUND);
    localparam [31:0] D_ANSWERS = phrase_desc(PH_SUMMARY_QUESTIONS);
    localparam [31:0] D_STARS = phrase_desc(PH_SUMMARY_STARS);
    reg [3:0] completed_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) completed_frame <= 4'd0;
        else if (vs_q && !vsync)
            completed_frame <= (sess_q >= 8'd10) ? 4'd10 : sess_q[3:0];
    end

    // ------------------------------------------------------ lookahead
    wire [9:0] nx = de ? pixel_x + 1'b1 : 10'd0;
    wire rows_top = (line_y >= TOP_Y0) && (line_y < TOP_Y0 + 32);
    wire rows_fb = (line_y >= FB_Y0) && (line_y < FB_Y0 + 32);
    wire [4:0] row_top = line_y - TOP_Y0;
    wire [4:0] row_fb = line_y - FB_Y0;
    // score cells: six fixed-width slots, right edge pinned at column 624
    wire [9:0] score_x0 = summary_show ? 10'd128 : word_scene ? 10'd416 : S2_X0;
    wire [11:0] score_y0 = summary_show ? 12'd184 : word_scene ? FB_Y0 : TOP_Y0;
    wire rows_score = (line_y >= score_y0) &&
                      (line_y < score_y0 + (summary_show ? 12'd64 : 12'd32));
    wire       s2_in = (nx >= score_x0) &&
                      (nx < score_x0 + (summary_show ? 10'd384 : 10'd192));
    wire [9:0] score_dx = nx - score_x0;
    wire [11:0] score_dy = line_y - score_y0;
    wire [9:0] c2 = summary_show ? {1'b0, score_dx[9:1]} : score_dx;
    wire [13:0] c2x43 = {1'b0, c2[7:0], 5'd0} + {3'd0, c2[7:0], 3'd0} +
                        {5'd0, c2[7:0], 1'b0} + {6'd0, c2[7:0]};
    // (c*43)>>10 overshoots c/24 by one only at the last column of the
    // 8-cell strip, so the clamp back to 7 keeps every slot exact
    wire [2:0] cell_q = (c2x43[13:10] > 4'd7) ? 3'd7 : c2x43[12:10];
    wire [2:0] cell_k = s2_in ? cell_q : 3'd0;
    wire [9:0] cell_base = {3'd0, cell_k, 4'd0} + {4'd0, cell_k, 3'd0};
    wire [9:0] cell_col = c2 - cell_base;
    wire [31:0] dcell = dc[cell_k];

    reg [5:0] progress_id;
    reg [9:0] progress_x;
    always @* begin
        progress_id = PH_BLANK; progress_x = 10'd520;
        if (nx < 10'd540) begin
            progress_id = (completed_frame == 4'd10) ? PH_C_1 : PH_BLANK;
        end else if (nx < 10'd560) begin
            progress_id = (completed_frame == 4'd10) ? PH_C_0 : PH_C_0 + {2'd0, completed_frame};
            progress_x = 10'd540;
        end else if (nx < 10'd580) begin
            progress_id = PH_C_SLASH; progress_x = 10'd560;
        end else if (nx < 10'd600) begin
            progress_id = PH_C_1; progress_x = 10'd580;
        end else begin
            progress_id = PH_C_0; progress_x = 10'd600;
        end
    end
    wire [31:0] progress_desc = phrase_desc(progress_id);

    reg l_hit;
    reg [31:0] l_desc;
    reg [9:0] l_col;
    reg [4:0] l_row;
    reg [2:0] l_color;
    always @* begin
        l_hit = 1'b0; l_desc = 31'd0; l_col = 10'd0; l_row = row_top; l_color = 3'd0;
        if (rows_top && nx >= S0_X && nx < S0_X + w0) begin
            l_hit = 1'b1; l_desc = d0; l_col = nx - S0_X; l_color = 3'd0;
        end else if (rows_top && nx >= x1 && nx < x1 + w1) begin
            l_hit = 1'b1; l_desc = d1; l_col = nx - x1; l_color = 3'd1;
        end else if (rows_top && word_scene && nx >= 10'd448 && nx < 10'd448 + D_ROUND[9:0]) begin
            l_hit = 1'b1; l_desc = D_ROUND; l_col = nx - 10'd448; l_color = 3'd0;
        end else if (rows_top && word_scene && nx >= 10'd520 && nx < 10'd620 &&
                     nx - progress_x < progress_desc[9:0]) begin
            l_hit = 1'b1; l_desc = progress_desc; l_col = nx - progress_x; l_color = 3'd0;
        end else if (summary_show && line_y >= 12'd136 && line_y < 12'd168 &&
                     nx >= 10'd152 && nx < 10'd152 + D_ANSWERS[9:0]) begin
            l_hit = 1'b1; l_desc = D_ANSWERS; l_col = nx - 10'd152;
            l_row = line_y - 12'd136; l_color = 3'd0;
        end else if (summary_show && line_y >= 12'd136 && line_y < 12'd168 &&
                     nx >= 10'd344 && nx < 10'd344 + D_STARS[9:0]) begin
            l_hit = 1'b1; l_desc = D_STARS; l_col = nx - 10'd344;
            l_row = line_y - 12'd136; l_color = 3'd0;
        end else if (rows_score && s2_cells != 48'd0 && s2_in && cell_col < dcell[9:0]) begin
            l_hit = 1'b1; l_desc = dcell; l_col = cell_col; l_color = 3'd2;
            l_row = summary_show ? score_dy[5:1] : score_dy[4:0];
        end else if (rows_fb && nx >= x3 && nx < x3 + w3) begin
            l_hit = 1'b1; l_desc = d3; l_col = nx - x3; l_row = row_fb;
            l_color = 3'd4 + {1'b0, s3_class};
        end
    end
    wire [11:0] row_off = l_row * l_desc[16:10];
    // OPT-8 (docs/53, ported as docs/16 L2): 1 bit/pixel ROM, 8 px per byte;
    // the 14-bit base sits at desc[30:17]. The generator caps the data at
    // 16 KB so the 14-bit sum cannot overflow.
    wire [13:0] rom_addr = l_desc[30:17] + {2'b00, row_off} + {9'd0, l_col[9:3]};
    wire [7:0] rom_data;
    wire text_rd = enable && l_hit;
    ss_phrase_rom u_rom (.clk(clk), .ce(text_rd), .addr(rom_addr), .data(rom_data));

    reg t_hit_q;
    reg [2:0] t_sub_q;      // pixel inside the 8-px byte
    reg [2:0] t_color_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_hit_q <= 1'b0; t_sub_q <= 3'd0; t_color_q <= 3'd0;
        end else begin
            t_hit_q <= enable && l_hit;
            t_sub_q <= l_col[2:0];
            t_color_q <= l_color;
        end
    end

    // ------------------------------------------------------ column buffers
    reg [8:0] tgt_mem [0:511];
    reg [8:0] chd_mem [0:511];
    integer mi;
    initial begin
        for (mi = 0; mi < 512; mi = mi + 1) begin
            tgt_mem[mi] = 9'd0;
            chd_mem[mi] = 9'd0;
        end
    end
    wire [9:0] ncol = nx - CURVE_X0;
    wire ncol_in = (nx >= CURVE_X0) && (nx < CURVE_X0 + 512);
    reg [8:0] tgt_q, chd_q;
    reg col_in_q;
    // drawer
    reg dr_busy, dr_buf, dr_vis;
    reg [8:0] dr_x0, dr_k, dr_last;
    reg [3:0] dr_log2n;
    reg [7:0] dr_y0;
    reg signed [8:0] dr_dy;
    wire signed [18:0] dr_prod = dr_dy * $signed({1'b0, dr_k});
    wire signed [18:0] dr_step = dr_prod >>> dr_log2n;
    wire [7:0] dr_y = dr_y0 + dr_step[7:0];
    wire [8:0] dr_addr = dr_x0 + dr_k;
    assign cmd_ready = !dr_busy;
    always @(posedge clk) begin
        if (dr_busy && !dr_buf) tgt_mem[dr_addr] <= {dr_vis, dr_y};
        if (dr_busy && dr_buf) chd_mem[dr_addr] <= {dr_vis, dr_y};
        tgt_q <= tgt_mem[ncol[8:0]];
        chd_q <= chd_mem[ncol[8:0]];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dr_busy <= 1'b0; dr_buf <= 1'b0; dr_vis <= 1'b0; dr_x0 <= 9'd0;
            dr_k <= 9'd0; dr_last <= 9'd0; dr_log2n <= 4'd0; dr_y0 <= 8'd0;
            dr_dy <= 9'sd0; col_in_q <= 1'b0;
        end else begin
            col_in_q <= ncol_in;
            if (!dr_busy) begin
                if (cmd_valid) begin
                    dr_busy <= 1'b1;
                    dr_buf <= cmd_buf; dr_vis <= cmd_vis; dr_x0 <= cmd_x0;
                    dr_log2n <= cmd_log2n; dr_y0 <= cmd_y0;
                    dr_dy <= $signed({1'b0, cmd_y1}) - $signed({1'b0, cmd_y0});
                    dr_k <= 9'd0;
                    dr_last <= (9'd1 << cmd_log2n) - 1'b1;
                end
            end else if (dr_k == dr_last || dr_addr == 9'd511) begin
                dr_busy <= 1'b0;
            end else begin
                dr_k <= dr_k + 1'b1;
            end
        end
    end

    // ------------------------------------------------------ stage A
    wire [9:0] x = pixel_x;
    wire [11:0] y = line_y;
    wire [9:0] col = x - CURVE_X0;
    wire in_panel = (x >= PANEL_X0) && (x < PANEL_X1) && (y >= PANEL_Y0) && (y < PANEL_Y1);
    wire [11:0] ty = PANEL_Y0 + tgt_q[7:0];
    wire [11:0] cy = PANEL_Y0 + chd_q[7:0];
    wire signed [12:0] dty = $signed({1'b0, y}) - $signed({1'b0, ty});
    wire signed [12:0] dcy = $signed({1'b0, y}) - $signed({1'b0, cy});
    // R75 road: the contour is drawn as a BAND hugging the ridge line -- a
    // light shoulder seats it above, the body hangs 24 px below with depth
    // bands and a terrace line every 8 px. The old fill-to-the-floor turned
    // a flat first tone into a solid green wall; the road keeps sky and
    // landscape visible and reads as "a road to walk" for every shape.
    localparam signed [12:0] ROAD_BODY = 13'sd24;
    localparam signed [12:0] ROAD_SHOULDER = 13'sd5;
    wire tgt_col = panel_show && col_in_q && tgt_q[8] && ({1'b0, col} < target_reveal);
    wire tgt_road = tgt_col && (dty >= -ROAD_SHOULDER) && (dty < ROAD_BODY);
    wire tgt_shoulder = tgt_road && (dty < 0);
    wire tgt_ridge = tgt_road && (dty >= 0) && (dty < 13'sd6) && !col[3];
    reg [5:0] pulse_cnt;
    // audit P1: the old version counted only during the 1600-clk vsync-low
    // window -- 1600 mod 64 == 0, so the counter never advanced during the
    // visible period and ridge_gold stayed 0 forever (the 3-star gold pulse
    // never rendered). Count lines instead: bit 5 flips every 32 lines.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                              pulse_cnt <= 6'd0;
        else if (de_q && !de)                    pulse_cnt <= pulse_cnt + 1'b1;
    end
    wire ridge_gold = celebrate && pulse_cnt[5];
    wire [1:0] tgt_band = (dty >= 13'sd18) ? 2'd2 :
                          (dty >= 13'sd12) ? 2'd1 : 2'd0;
    wire tgt_terr = (dty >= 13'sd8) && (dty[2:0] == 3'd0);
    // child trail: orange core with a dark edge (wider in high-contrast mode)
    wire [3:0] c_thick = high_contrast ? 4'd3 : 4'd2;
    wire [3:0] c_edge = high_contrast ? 4'd5 : 4'd4;
    wire chd_col = panel_show && child_show && col_in_q && chd_q[8];
    wire chd_hit = chd_col &&
                   (dcy <= $signed({9'd0, c_thick})) && (dcy >= -$signed({9'd0, c_thick}));
    // Child identity stays orange even near the reference; proximity is
    // not presented as a second similarity score or a colour-only verdict.
    wire chd_edge = chd_col &&
                    (dcy <= $signed({9'd0, c_edge})) && (dcy >= -$signed({9'd0, c_edge}));
    // Chao levels 5..1 at panel rows 32, 80, 128, 176, 224 (24 px per semitone)
    wire [11:0] gy = y - PANEL_Y0;
    wire grid_row = (gy == 12'd32) || (gy == 12'd80) || (gy == 12'd128) ||
                    (gy == 12'd176) || (gy == 12'd224) ||
                    (high_contrast && ((gy == 12'd33) || (gy == 12'd81) || (gy == 12'd129) ||
                     (gy == 12'd177) || (gy == 12'd225)));
    // dashed so the level lines read over both sky and mountain
    wire grid_hit = panel_show && in_panel && grid_row && (x[3:2] != 2'b11);
    // pitch ball: octagon of radius 7 around the newest point
    wire signed [11:0] bdx = $signed({2'b00, x}) - $signed({2'b00, CURVE_X0[9:0] + {1'b0, ball_col}});
    wire signed [12:0] bdy = $signed({1'b0, y}) - $signed({1'b0, PANEL_Y0[11:0] + {4'd0, ball_y}});
    wire [11:0] abdx = bdx[11] ? -bdx : bdx;
    wire [12:0] abdy = bdy[12] ? -bdy : bdy;
    wire ball_ring = panel_show && ball_show && abdx <= 12'd9 && abdy <= 13'd9 &&
                     ({1'b0, abdx} + abdy) <= 13'd13;
    wire ball_hit = ball_ring && abdx <= 12'd7 && abdy <= 13'd7 &&
                    ({1'b0, abdx} + abdy) <= 13'd10;
    // balloon
    // radius <= 127: anything farther than 127 on an axis is outside
    wire [9:0] gax = (x >= 10'd320) ? x - 10'd320 : 10'd320 - x;
    wire [11:0] gay = (y >= 12'd200) ? y - 12'd200 : 12'd200 - y;
    wire g_near = (gax < 10'd128) && (gay < 12'd128);
    wire [13:0] gdx2 = gax[6:0] * gax[6:0];
    wire [13:0] gdy2 = gay[6:0] * gay[6:0];
    wire [13:0] r2 = balloon_r[6:0] * balloon_r[6:0];
    wire [14:0] g_d2 = {1'b0, gdx2} + gdy2;
    wire in_balloon = balloon_show && g_near && (g_d2 < {1'b0, r2});
    // rim: outside radius r-6, i.e. d2 >= r2 - 12r + 36 (linear in r)
    wire [14:0] rim_in = {1'b0, r2} - {4'd0, balloon_r, 3'd0} - {5'd0, balloon_r, 2'd0} + 15'd36;
    wire balloon_rim = in_balloon && (balloon_r > 8'd12) && (g_d2 >= rim_in);
    // sheen: a diamond (L1 ball, no multiplier) of radius r/5 centred r/3
    // up-left of the centre
    wire [13:0] r3p = {balloon_r[6:0], 6'd0} + {1'd0, balloon_r, 4'd0} +
                      {4'd0, balloon_r, 2'd0} + {6'd0, balloon_r};          // r*85
    wire [5:0] r3 = r3p[13:8];
    wire [13:0] r5p = {1'b0, balloon_r, 5'd0} + {2'd0, balloon_r, 4'd0} +
                      {5'd0, balloon_r, 1'b0};                                // r*50
    wire [5:0] r5 = r5p[13:8];
    wire [9:0] hx0 = 10'd320 - {4'd0, r3};
    wire [11:0] hy0 = 12'd200 - {6'd0, r3};
    wire [9:0] hax = (x >= hx0) ? x - hx0 : hx0 - x;
    wire [11:0] hay = (y >= hy0) ? y - hy0 : hy0 - y;
    wire balloon_hi = in_balloon && (hax < 10'd64) && (hay < 12'd64) &&
                      ({1'b0, hax[5:0]} + {1'b0, hay[5:0]} < {1'b0, r5});
    // knot: small upward triangle hanging under the balloon
    wire [11:0] knot_top = BAL_CY + {4'd0, balloon_r};
    wire [11:0] kdy = y - knot_top;
    wire knot_hit = balloon_show && (y >= knot_top) && (kdy < 12'd7) &&
                    ({2'd0, gax} <= {10'd0, kdy[2:1]});
    // string: 2 px wide, gentle triangle-wave sway
    wire [3:0] sway_t = y[5:2];
    wire [2:0] sway = sway_t[3] ? ~sway_t[2:0] : sway_t[2:0];
    wire [9:0] str_x = 10'd318 + {8'd0, sway[2:1]};
    wire string_hit = balloon_show && (x == str_x || x == str_x + 1'b1) &&
                      (y >= knot_top + 12'd7) && (y < 12'd334);
    // train and loudness meter
    // locomotive, 80 px long, train_x = left edge; rails at rows 302..309
    wire [9:0] tx = x - train_x;
    wire tx_in = train_show && (x >= train_x) && (x < train_x + 10'd80);
    wire ty_in = (y >= 12'd206) && (y < 12'd304);
    wire [6:0] t7 = tx[6:0];
    wire [6:0] yy = y[6:0] - 7'd78;                       // y - 206 inside the band
    wire tr_cab    = tx_in && ty_in && t7 >= 7'd54 && yy >= 7'd30 && yy < 7'd80;
    wire tr_window = tr_cab && t7 >= 7'd60 && t7 < 7'd74 && yy >= 7'd38 && yy < 7'd52;
    wire tr_roof   = tx_in && ty_in && t7 >= 7'd50 && yy >= 7'd24 && yy < 7'd30;
    wire tr_boiler = tx_in && ty_in && t7 < 7'd54 && yy >= 7'd50 && yy < 7'd80;
    wire tr_band   = tr_boiler && (t7[4:2] == 3'b011);    // gold hoops at 12..15, 44..47
    wire tr_chim   = tx_in && ty_in && t7 >= 7'd8 && t7 < 7'd18 && yy >= 7'd34 && yy < 7'd50;
    wire tr_cap    = tx_in && ty_in && t7 >= 7'd6 && t7 < 7'd20 && yy >= 7'd30 && yy < 7'd34;
    // wheels: octagons of radius 8 centred at x 16/40/64, y 294; grey hub
    wire [6:0] w_c = (t7 < 7'd28) ? 7'd16 : (t7 < 7'd52) ? 7'd40 : 7'd64;
    wire [6:0] wdx = (t7 >= w_c) ? t7 - w_c : w_c - t7;
    wire [6:0] wdy = (yy >= 7'd88) ? yy - 7'd88 : 7'd88 - yy;
    wire tr_wheel  = tx_in && ty_in && wdx <= 7'd8 && wdy <= 7'd8 && (wdx + wdy) <= 7'd11;
    wire tr_hub    = tr_wheel && (wdx + wdy) <= 7'd3;
    // two smoke puffs (diamonds) trailing up-left of the chimney
    wire [6:0] s1dx = (t7 >= 7'd13) ? t7 - 7'd13 : 7'd13 - t7;
    wire [6:0] s1dy = (yy >= 7'd20) ? yy - 7'd20 : 7'd20 - yy;
    wire [6:0] s2dx = (t7 >= 7'd4) ? t7 - 7'd4 : 7'd4 - t7;
    wire [6:0] s2dy = (yy >= 7'd6) ? yy - 7'd6 : 7'd6 - yy;
    wire tr_smoke  = tx_in && ty_in && ((s1dx + s1dy) <= 7'd7 || (s2dx + s2dy) <= 7'd6);
    // rails and sleepers
    wire track_on = train_show && x >= PANEL_X0 && x < PANEL_X1;
    wire rail_hit = track_on && y >= 12'd302 && y < 12'd305;
    wire sleeper_hit = track_on && y >= 12'd305 && y < 12'd310 && (x[4:3] == 2'b00);
    // finish flag at the end of the line
    wire flag_pole = train_show && x >= 10'd624 && x < 10'd627 && y >= 12'd226 && y < 12'd302;
    wire flag_hit = train_show && x >= 10'd627 && y >= 12'd226 && y < 12'd242;
    wire [11:0] m_top = PANEL_Y1 - 1 - {4'd0, meter_level};
    wire [11:0] w_top = PANEL_Y1 - 1 - {4'd0, win_hi};
    wire [11:0] w_bot = PANEL_Y1 - 1 - {4'd0, win_lo};
    wire meter_show = train_show || listen_meter;
    wire meter_box = meter_show && x >= 18 && x < 38 && y >= PANEL_Y0 - 2 && y < PANEL_Y1 + 2;
    wire meter_col = meter_show && x >= 20 && x < 36 && y >= PANEL_Y0 && y < PANEL_Y1;
    wire meter_frame = meter_box && !meter_col;
    wire meter_fill = meter_col && y >= m_top;
    wire meter_win = meter_col && !listen_meter && y >= w_top && y <= w_bot;
    // card highlight: 6-pixel frame around card k of the four-card row
    // (cards are 148x240 at x = 16 + 156k, y = 80; the frame sits 4 px outside)
    wire [9:0] qx0 = 10'd12 + {card_index, 7'd0} + {card_index, 4'd0} + {card_index, 3'd0} +
                     {card_index, 2'd0};
    wire card_out = (x >= qx0) && (x < qx0 + 156) && (y >= 12'd76) && (y < 12'd324);
    wire card_in = (x >= qx0 + 6) && (x < qx0 + 150) && (y >= 12'd82) && (y < 12'd318);
    wire card_hit = card_show && card_out && !card_in;
    // text bands
    wire top_full = (s1_id != 6'd0) || (s2_cells != 48'd0);
    wire [9:0] band0_x1 = top_full ? 10'd632 : S0_X + w0 + 10'd8;
    wire band_top = (s0_id != 6'd0 || top_full) && y >= 4 && y < 44 && x >= 8 && x < band0_x1;
    wire band_fb = (s3_id != 6'd0) && y >= 334 && y < 374 &&
                   (feedback_score ? (x >= 8 && x < 632) : (x + 16 >= x3 && x < x3 + w3 + 16));
    // OPT-8 (docs/53): 1 bit per pixel -- a set pixel renders solid (level 3,
    // the same blend path the 2 bpp level 3 used); a lit pixel with a clear
    // BYTE-LOCAL neighbour is softened to level 2 (50 % blend) so stroke
    // edges keep part of the R76 anti-aliasing feel. Edges crossing the byte
    // boundary are not visible to this rule (single read port).
    // rom_data and t_sub_q are registered in the same cycle, so the bit
    // selected here is aligned with the glyph pixel
    wire text_bit = rom_data[7 - t_sub_q];
    wire text_lft = (t_sub_q == 3'd0) ? 1'b1 : rom_data[8 - t_sub_q];
    wire text_rgt = (t_sub_q == 3'd7) ? 1'b1 : rom_data[6 - t_sub_q];
    wire [1:0] text_aa = !text_bit ? 2'd0 :
                         (text_lft && text_rgt) ? 2'd3 : 2'd2;
    wire [1:0] text_level = t_hit_q ? text_aa : 2'd0;
    wire text_px = text_level != 2'd0;

    // ---- audit F2: voice discovery circle (screen center, radius=f(volume))
    wire [9:0] disc_cx = 10'd320;
    wire [9:0] disc_dx = (x >= disc_cx) ? (x - disc_cx) : (disc_cx - x);
    wire [9:0] disc_dy = (y >= 9'd240) ? (y - 9'd240) : (9'd240 - y);
    // rounded blob, the pitch ball's idiom (axial clips + L1 sum): a pure
    // L1 diamond reads sharp/hostile next to the balloon; the two 10x10
    // multipliers of a Euclidean test stay out (PHY-9009). Filled only --
    // the outline ring was the first casualty of the budget squeeze.
    wire [10:0] disc_d = {1'b0, disc_dx} + {1'b0, disc_dy};
    wire [10:0] disc_dlim = {3'd0, disc_radius} + {3'd0, disc_radius[7:2]};
    wire disc_hit = discover_show && (disc_dx < {2'b00, disc_radius}) &&
                    (disc_dy < {2'b00, disc_radius}) && (disc_d < disc_dlim);
    // pitch -> colour: 8 DISTINCT hues, low pitch = warm .. high = cool
    localparam [5:0] P_D0 = 6'd36;  // discovery colours, declared before use
    wire [5:0] disc_pal = P_D0 + {3'd0, disc_hue[2:0]};

    // ------------------------------------------------------ colour selection
    // Stage A reduces every layer hit to one palette index (priority encoded
    // on 1-bit flags) plus a blend flag, so stage B is a single constant
    // lookup and one shared 75 % blender however many shapes are drawn.
    localparam [5:0] P_BASE = 6'd0,  P_T0 = 6'd1,                      // 1..8 text colours
                     P_BALL = 6'd9,  P_EDGE = 6'd10, P_CHILD = 6'd11, P_GRIDM = 6'd12,
                     P_WHITE = 6'd13, P_RIDGE = 6'd14, P_M0 = 6'd15,    // 15..22 mountain
                     P_BHI = 6'd23,  P_RIM = 6'd24,  P_BAL = 6'd25,   P_HUB = 6'd26,
                     P_WHEEL = 6'd27, P_WIN = 6'd28, P_GOLD = 6'd29,  P_CAB = 6'd30,
                     P_BOIL = 6'd31, P_TGT = 6'd32,  P_RAIL = 6'd33,  P_SLEEP = 6'd34;
    localparam [5:0] P_GOOD = P_T0 + 6'd5, P_HINT = P_T0 + 6'd6, P_YELLOW = P_T0 + 6'd1;
    localparam [5:0] P_SHLD = 6'd35;   // R75 road shoulder
    // grid dash over the mountain: mix75(white, C_M1) precomputed
    localparam [23:0] C_GRIDM = 24'hD4EBD7;

    reg [5:0] pal_n;
    reg blend_n;
    always @* begin
        pal_n = P_BASE;
        blend_n = 1'b0;
        if (text_px)                         pal_n = P_T0 + {3'd0, t_color_q};
        else if (ball_hit)                   pal_n = P_BALL;
        else if (ball_ring)                  pal_n = P_EDGE;
        else if (chd_hit)                    pal_n = P_CHILD;
        else if (chd_edge)                   pal_n = P_EDGE;
        else if (meter_fill)                 pal_n = meter_ok ? P_GOOD : P_HINT;
        else if (meter_win) begin            pal_n = P_TGT; blend_n = 1'b1; end
        else if (meter_frame)                pal_n = P_WHITE;
        else if (grid_hit) begin             pal_n = P_WHITE; blend_n = 1'b1; end
        else if (tgt_shoulder)               pal_n = P_SHLD;
        else if (tgt_ridge)                  pal_n = ridge_gold ? P_GOLD : P_RIDGE;
        else if (tgt_road)                   pal_n = P_M0 + {3'd0, tgt_terr, tgt_band};
        else if (disc_hit)                   pal_n = disc_pal;
        else if (balloon_hi)                 pal_n = P_BHI;
        else if (balloon_rim)                pal_n = P_RIM;
        else if (in_balloon || knot_hit)     pal_n = P_BAL;
        else if (string_hit)                 pal_n = P_WHITE;
        else if (tr_hub)                     pal_n = P_HUB;
        else if (tr_wheel || tr_roof || tr_chim || tr_cap) pal_n = P_WHEEL;
        else if (tr_window)                  pal_n = P_WIN;
        else if (tr_band)                    pal_n = P_GOLD;
        else if (tr_cab)                     pal_n = P_CAB;
        else if (tr_boiler)                  pal_n = P_BOIL;
        else if (tr_smoke) begin             pal_n = P_WHITE; blend_n = 1'b1; end
        else if (rail_hit)                   pal_n = P_RAIL;
        else if (sleeper_hit)                pal_n = P_SLEEP;
        else if (flag_hit)                   pal_n = P_GOOD;
        else if (flag_pole)                  pal_n = P_WHITE;
        else if (card_hit)                   pal_n = P_YELLOW;
    end

    reg a_de, a_vs, a_en, a_hc, a_blend;
    reg [1:0] a_dim;             // 0 none, 1 50% dark, 2 25% dark, 3 75% dark
    reg [1:0] a_tlv;
    reg [9:0] a_x;
    reg [23:0] a_rgb;
    reg [5:0] a_pal;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_de <= 1'b0; a_vs <= 1'b1; a_en <= 1'b0; a_hc <= 1'b0; a_x <= 10'd0;
            a_rgb <= 24'd0; a_dim <= 2'd0; a_blend <= 1'b0; a_pal <= P_BASE;
        end else begin
            a_de <= de; a_vs <= vsync; a_x <= pixel_x; a_rgb <= rgb_in;
            a_en <= enable; a_hc <= high_contrast;
            a_pal <= pal_n; a_blend <= blend_n; a_tlv <= text_level;
            // Warm opaque text bands keep 1bpp glyph edges readable;
            // the task panel darkens only in high-contrast mode.
            a_dim <= band_fb ? 2'd1 :
                     (band_top || (summary_show && in_panel)) ? 2'd2 :
                     (panel_show && in_panel && high_contrast) ? 2'd3 : 2'd0;
        end
    end

    // ------------------------------------------------------ stage B
    function [23:0] mix75;
        input [23:0] c;
        input [23:0] bg;
        begin
            mix75 = ((c >> 1) & 24'h7F7F7F) + ((c >> 2) & 24'h3F3F3F) + ((bg >> 2) & 24'h3F3F3F);
        end
    endfunction
    reg [23:0] pc;
    always @* begin
        case (a_pal)
            6'd1:  pc = C_S0;        6'd2:  pc = C_S1;        6'd3:  pc = C_S2;
            6'd4:  pc = C_CYAN;      6'd5:  pc = C_INFO;      6'd6:  pc = C_GOOD;
            6'd7:  pc = C_HINT;      6'd8:  pc = C_CYAN;
            6'd9:  pc = C_BALL;      6'd10: pc = C_EDGE;      6'd11: pc = C_CHILD;
            6'd12: pc = C_GRIDM;     6'd13: pc = C_STRING;    6'd14: pc = C_RIDGE;
            6'd15: pc = C_M0;        6'd16: pc = C_M1;        6'd17: pc = C_M2;
            6'd18: pc = C_M3;        6'd19: pc = C_T0;        6'd20: pc = C_T1;
            6'd21: pc = C_T2;        6'd22: pc = C_T3;
            6'd23: pc = C_BALLOON_HI; 6'd24: pc = C_BALLOON_RIM; 6'd25: pc = C_BALLOON;
            6'd26: pc = C_HUB;       6'd27: pc = C_WHEEL;     6'd28: pc = C_WINDOW;
            6'd29: pc = C_GOLDBAND;  6'd30: pc = C_CAB;       6'd31: pc = C_BOILER;
            6'd32: pc = C_TARGET;    6'd33: pc = C_RAIL;      6'd34: pc = C_SLEEPER;
            6'd35: pc = C_SHLD;
            6'd36: pc = 24'hFF5A7A;  6'd37: pc = 24'hFF9A3D;
            6'd38: pc = 24'hFFE14D;  6'd39: pc = 24'h9BE85C;
            6'd40: pc = 24'h40E07A;  6'd41: pc = 24'h4FC8E8;
            6'd42: pc = 24'h6A8CFF;  6'd43: pc = 24'hC77DFF;
            default: pc = 24'h000000;
        endcase
    end
    function [23:0] mix50;
        input [23:0] c;
        input [23:0] bg;
        begin
            mix50 = ((c >> 1) & 24'h7F7F7F) + ((bg >> 1) & 24'h7F7F7F);
        end
    endfunction
    function [23:0] mix25;
        input [23:0] c;
        input [23:0] bg;
        begin
            mix25 = ((c >> 2) & 24'h3F3F3F) + ((bg >> 1) & 24'h7F7F7F)
                    + ((bg >> 2) & 24'h3F3F3F);
        end
    endfunction
    wire [23:0] base_rgb = (a_dim == 2'd1 || a_dim == 2'd2) ? UI_CHILD_BACKGROUND :
                           (a_dim == 2'd3) ? ((a_rgb >> 2) & 24'h3F3F3F) : a_rgb;
    wire [23:0] out_rgb = !a_en ? a_rgb :
                          (a_tlv == 2'd3) ? pc :
                          (a_tlv == 2'd2) ? mix50(pc, base_rgb) :
                          (a_tlv == 2'd1) ? mix25(pc, base_rgb) :
                          (a_pal == P_BASE) ? base_rgb :
                          a_blend ? mix75(pc, base_rgb) : pc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 1'b0; vsync_out <= 1'b1; pixel_x_out <= 10'd0; rgb_out <= 24'd0;
        end else begin
            de_out <= a_de; vsync_out <= a_vs; pixel_x_out <= a_x; rgb_out <= out_rgb;
        end
    end
endmodule
