


module audio_arc_calculate #(
    parameter ACR_N = 6144
    )(
    input wire       I_clk,
    input wire       I_rst,

    input wire       I_audio_valid,

    output reg       O_acr_valid,
    output reg[19:0] O_acr_cts,
    output reg[19:0] O_acr_n
);


    localparam AUDIO_DIV = ACR_N >> 7;
    // audit P2: AUDIO_DIV = ACR_N>>7 -- a tiny ACR_N would make it 0 and
    // the ACR packets would silently vanish (guard mirrors uart_rx_byte)
    initial begin
        if (ACR_N < 128) begin
            $display("ACR_CONFIG_ERROR ACR_N=%0d < 128 makes AUDIO_DIV=0 (no ACR packets)",
                     ACR_N);
            $finish;
        end
    end

    reg[7:0]  S_audio_div_cnt;
    wire      S_audio_valid_div;
    reg[19:0] S_acr_cts_cnt;


    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_audio_div_cnt <= 'd0;
        else
            if(I_audio_valid)
                begin
                    if(S_audio_div_cnt >= AUDIO_DIV-1)
                        S_audio_div_cnt <= 'd0;
                    else
                        S_audio_div_cnt <= S_audio_div_cnt + 'd1;
                end
            else
                S_audio_div_cnt <= S_audio_div_cnt;
    end


    assign S_audio_valid_div = I_audio_valid && (S_audio_div_cnt == AUDIO_DIV-1) ? 1'b1 : 1'b0;

    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_acr_cts_cnt <= 'd0;
        else
            if(S_audio_valid_div)
                S_acr_cts_cnt <= 'd0;
            else
                S_acr_cts_cnt <= S_acr_cts_cnt + 'd1;
    end


    always @(posedge I_clk) begin
        if(S_audio_valid_div)
            begin
                O_acr_valid <= 1'b1;
                O_acr_cts   <= S_acr_cts_cnt + 'd1;
                O_acr_n     <= ACR_N;
            end
        else    
            begin
                O_acr_valid <= 1'b0;
                O_acr_cts   <= 'd0;
                O_acr_n     <= 'd0;
            end
    end

    
endmodule