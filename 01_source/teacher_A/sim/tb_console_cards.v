// Candidate teacher-console cards: real v7 UART receive path plus ROM pixels.
// Synthetic RTL evidence only; no HDMI-core, timing or board qualification.
`timescale 1ns/1ps
module tb_console_cards;
    reg clk=0, rst_n=1;
    always #5 clk=~clk;
    localparam integer BIT_CLOCKS=8;
    localparam integer LINK_TIMEOUT=50000;
    reg send=0;
    reg [7:0] kind=0;
    reg [5:0] length=0;
    reg [15:0] seq=0, question=1;
    reg [255:0] payload=0;
    wire peer_tx, peer_ready, teacher_tx, link_up, protocol_error;
    wire [2:0] mode, phase, target, tone;
    wire [1:0] q_idx, eff_diff, stars;
    wire tch_used, teacher_on, teacher_waiting, res_new, too_short;
    wire [15:0] res_event;
    wire [6:0] score, n_points;
    wire [127:0] shape, demo_shape;
    wire capture_arm, capture_cancel, demo_armed;
    integer checks=0, glyph_pixels=0, result_events=0;
    integer stage, m, q;
    reg [11:0] probe_x=320, probe_y=10;
    reg [7:0] expected_glyphs [0:1159];

    v7_packet_tx #(.CLKS_PER_BIT(BIT_CLOCKS)) peer (
        .clk(clk), .rst_n(rst_n), .flush(1'b0), .send(send),
        .kind(kind), .length(length), .session(16'h1234),
        .packet_seq(seq), .question(question), .payload(payload),
        .tx(peer_tx), .ready(peer_ready), .done());

    v7_link_a #(.SINGLE_MIC(1), .CLKS_PER_BIT(BIT_CLOCKS),
                .LINK_TIMEOUT(LINK_TIMEOUT), .RETRY_CLOCKS(1000)) link (
        .clk(clk), .rst_n(rst_n), .rx(peer_tx), .tx(teacher_tx),
        .feature_valid(1'b0), .child_voiced(1'b0), .teacher_voiced(1'b0),
        .teacher_preference(1'b0), .mic_teacher(1'b0), .mic_ready(1'b1),
        .child_pitch(10'd0), .teacher_pitch(10'd0),
        .child_level(8'd0), .teacher_level(8'd0),
        .capture_arm(capture_arm), .capture_cancel(capture_cancel),
        .capture_armed(1'b0), .capture_done(1'b0), .capture_n(7'd0),
        .capture_mean(10'd0), .capture_shape(128'd0),
        .demo_armed(demo_armed), .demo_shape(demo_shape),
        .link_up(link_up), .protocol_error(protocol_error),
        .mode(mode), .phase(phase), .target(target), .tone(tone),
        .q_idx(q_idx), .eff_diff(eff_diff), .stars(stars),
        .tch_used(tch_used), .teacher_on(teacher_on),
        .teacher_waiting(teacher_waiting), .res_new(res_new),
        .too_short(too_short), .res_event(res_event),
        .score(score), .n_points(n_points), .shape(shape));

    teacher_console #(.SINGLE_MIC(1)) dut (
        .clk(clk), .rst_n(rst_n), .mic_teacher(1'b0), .mic_ready(1'b1),
        .teacher_tick(1'b0), .frame_tick(1'b0), .child_v(1'b0),
        .child_p(10'd0), .teacher_v(1'b0), .teacher_p(10'd0), .demo_en(1'b0),
        .b_link_up(link_up), .b_mode(mode), .b_phase(phase), .b_q(q_idx),
        .b_teacher_on(teacher_waiting), .res_new(res_new), .res_target(target),
        .res_stars(stars), .res_short(too_short), .res_score(score),
        .res_tch_used(tch_used), .res_shape(shape), .tch_shape(demo_shape),
        .hist_load(1'b0), .hist_short(1'b0), .hist_score(7'd0),
        .hist_stars(2'd0), .replay_busy(1'b0), .journal_error(1'b0),
        .journal_error_kind(2'd0), .demo_armed(demo_armed),
        .axis_user(), .axis_valid(), .axis_last(), .axis_data());

    always @(posedge clk) if (rst_n && res_new) result_events=result_events+1;

    task transmit;
        input [7:0] packet_kind;
        input [5:0] packet_length;
        input [15:0] packet_seq, packet_question;
        input [255:0] packet_payload;
        begin
            @(negedge clk);
            while (!peer_ready) @(negedge clk);
            kind=packet_kind; length=packet_length; seq=packet_seq;
            question=packet_question; payload=packet_payload; send=1;
            @(negedge clk); send=0;
            while (!peer_ready) @(negedge clk);
            repeat(12) @(negedge clk);
            if (protocol_error) $fatal(1,"CARD_PROTOCOL_ERROR kind=%0d",packet_kind);
        end
    endtask

    task status;
        input [2:0] status_mode;
        input [1:0] status_q;
        input [15:0] packet_seq, packet_question;
        reg [255:0] body;
        begin
            body=0;
            body[7:0]={5'd0,status_mode}; body[15:8]=8'd3;
            body[23:16]={6'd0,status_q}+8'd1;
            body[31:24]={6'd0,status_q}; body[39:32]=8'd1;
            transmit(8'd17,6'd6,packet_seq,packet_question,body);
            if (!link_up || mode!=status_mode || q_idx!=status_q)
                $fatal(1,"CARD_STATUS_DECODE mode=%0d q=%0d",mode,q_idx);
        end
    endtask

    task expect_header;
        input integer expected;
        begin
            probe_x=320; probe_y=10; #1;
            if (dut.s_id !== expected[5:0])
                $fatal(1,"CARD_HEADER_ID mode=%0d q=%0d expected=%0d actual=%0d",mode,q_idx,expected,dut.s_id);
            checks=checks+1;
        end
    endtask

    task check_glyph;
        input integer card_q;
        integer width, stride, base, x, y;
        reg [1:0] actual_pixel, expected_pixel;
        begin
            case(card_q)
                0: begin width=67;stride=17;base=0;end
                1: begin width=49;stride=13;base=340;end
                2: begin width=63;stride=16;base=600;end
                3: begin width=46;stride=12;base=920;end
            endcase
            if (dut.d_w!=width || dut.d_strd!=stride)
                $fatal(1,"CARD_GLYPH_GEOMETRY q=%0d",card_q);
            for(y=0;y<20;y=y+1) begin
                for(x=0;x<width;x=x+1) begin
                    probe_x=306+x; probe_y=8+y;
                    repeat(2) @(posedge clk);
                    #1;
                    expected_pixel=(expected_glyphs[base+y*stride+(x>>2)] >> (6-2*(x&3))) & 2'b11;
                    actual_pixel=(dut.rom_q >> (6-2*(x&3))) & 2'b11;
                    if (!dut.t_in || dut.s_id!=(53+card_q) || actual_pixel !== expected_pixel)
                        $fatal(1,"CARD_GLYPH_PIXEL q=%0d x=%0d y=%0d expected=%0d actual=%0d",card_q,x,y,expected_pixel,actual_pixel);
                    glyph_pixels=glyph_pixels+1;
                    @(negedge clk);
                end
            end
            probe_x=383;probe_y=31;#1;
            if(dut.t_in) $fatal(1,"CARD_GLYPH_RIGHT_EDGE_NOT_BLANK q=%0d",card_q);
        end
    endtask

    task result;
        input [15:0] event_id, packet_seq, packet_question;
        input [2:0] result_mode, result_target;
        reg [255:0] body;
        begin
            body=0;body[15:0]=event_id;
            body[23:16]={5'd0,result_mode};body[31:24]={5'd0,result_target};
            body[47:40]=8'd90;body[55:48]=8'd3;body[63:56]=8'd16;
            body[79:72]=8'd100;
            transmit(8'd48,6'd27,packet_seq,packet_question,body);
        end
    endtask

    initial begin
        $readmemh("sim/card_expected_glyphs.hex",expected_glyphs);
        force dut.vx_q=probe_x;force dut.vy_q=probe_y;
        #1 rst_n=0;repeat(4)@(negedge clk);rst_n=1;
        transmit(8'd2,6'd0,16'd0,16'd1,256'd0);
        transmit(8'd4,6'd0,16'd0,16'd1,256'd0);
        if(!link_up) $fatal(1,"CARD_HANDSHAKE");

        // Cross every advertised mode with every q. Cards come first so the
        // unmodified Q6 console fails for the actual reported defect.
        for(stage=0;stage<6;stage=stage+1) begin
            case(stage)0:m=4;1:m=1;2:m=3;3:m=0;4:m=2;5:m=5;endcase
            for(q=0;q<4;q=q+1) begin
                status(m,q,16'd1+stage*4+q,16'd1+stage*4+q);
                expect_header(m==4 ? 53+q : m==1 ? 9+q : 0);
                if(m==4) check_glyph(q);
            end
        end

        // An accepted late result legitimately describes its own old q.
        // The subsequent live STATUS must select the latest current card.
        status(4,3,16'd25,16'd30);expect_header(56);
        result(16'd1,16'd26,16'd28,3'd4,3'd1);expect_header(53);
        if(result_events!=1 || target!=1 || tone!=0) $fatal(1,"CARD_RESULT_DECODE");
        status(4,3,16'd27,16'd30);expect_header(56);
        // Forward packet sequence with duplicate event is ACKed, but cannot
        // roll the question display back after the newer STATUS.
        result(16'd1,16'd28,16'd28,3'd4,3'd1);expect_header(56);
        if(result_events!=1) $fatal(1,"CARD_DUPLICATE_RESULT");
        result(16'd2,16'd29,16'd31,3'd1,3'd4);expect_header(12);
        status(4,1,16'd30,16'd32);expect_header(54);
        status(3,3,16'd31,16'd33);expect_header(0);
        status(4,2,16'd32,16'd34);expect_header(55);

        // An actual protocol timeout must clear the question text, rather
        // than leaving an animal or ma label visible while disconnected.
        repeat(LINK_TIMEOUT+20)@(negedge clk);
        if(link_up) $fatal(1,"CARD_LINK_TIMEOUT_NOT_REACHED");
        expect_header(0);
        if(dut.CP_FONT_ROWS!=20 || dut.CP_DASH!=44 || dut.CP_STORAGE_ERROR!=46 ||
           dut.CP_COUNT_CAP!=52 || dut.CP_CARD_MAO!=53 || dut.CP_CARD_TU!=56)
            $fatal(1,"CARD_STABLE_PHRASE_IDS");
        $display("CONSOLE_CARDS_PASS headers=%0d glyph_pixels=%0d modes_q=24 late_result_status=PASS duplicate_result=PASS disconnect=PASS",checks,glyph_pixels);
        $finish;
    end
    initial begin #20000000;$fatal(1,"CARD_TEST_TIMEOUT");end
endmodule
