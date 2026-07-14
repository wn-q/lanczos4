parameter INTERLEAVE_IDLE = 3'd0;
parameter INTERLEAVE_INIT = 3'd1;
parameter INTERLEAVE_Y = 3'd2;
parameter INTERLEAVE_U = 3'd3;
parameter INTERLEAVE_V = 3'd4;
wire[10:0] mult_tmp = block_pixel_width[7:2] * block_pixel_height[6:2];



wire block_start = status_idle && fg2pp_ctrl_vld;
wire status_idle = (interleave_fsm == INTERLEAVE_IDLE);
wire status_init = (interleave_fsm == INTERLEAVE_INIT);
wire status_y = (interleave_fsm == INTERLEAVE_Y);
wire status_u = (interleave_fsm == INTERLEAVE_U);
wire status_v = (interleave_fsm == INTERLEAVE_V);
wire block_y_done = status_y && (tile_out_cnt >= {1'b0,block_4x4_count});
wire block_u_done = status_u && (tile_out_cnt >= {1'b0,block_4x4_count});
wire block_v_done = status_v && (tile_out_cnt >= {1'b0,block_4x4_count});

always @(posedge clk)begin
    if(!rst_n)
        interleave_fsm <= INTERLEAVE_IDLE;
    else if(!sw_dec_en)
        interleave_fsm <= INTERLEAVE_IDLE;
    else 
        interleave_fsm <= interleave_fsm_next;
end

always @(*)begin
    case(interleave_fsm)
        INTERLEAVE_IDLE:
            if(block_start)
                interleave_fsm_next = INTERLEAVE_INIT;
            else
                interleave_fsm_next = INTERLEAVE_IDLE;
        INTERLEAVE_INIT:
            if(block_type == 0)
                interleave_fsm_next = INTERLEAVE_Y;       
            else if(block_type == 1)
                 interleave_fsm_next = INTERLEAVE_U;
            else
                interleave_fsm_next = INTERLEAVE_V;
        INTERLEAVE_Y:
            if(block_y_done)
                interleave_fsm_next = INTERLEAVE_IDLE;
            else
                interleave_fsm_next = INTERLEAVE_Y;
        INTERLEAVE_U:
            if(block_u_done)
                interleave_fsm_next = INTERLEAVE_IDLE;
            else
                interleave_fsm_next = INTERLEAVE_U; 
        INTERLEAVE_V:
            if(block_v_done)
                interleave_fsm_next = INTERLEAVE_IDLE;
            else
                interleave_fsm_next = INTERLEAVE_V;
        default:
            interleave_fsm_next = INTERLEAVE_IDLE;
    endcase
end

always @(posedge_clk)begin
    if(!rst_n)
        block_4x4_cnt <= 4'd0;
    else if(status_init)
        block_4x4_cnt <= mult_tmp;
end

always @(posedge_clk)begin
    if(!rst_n)
        tiled_out_cnt <= 12'0;
    else if(status_idle| status_init)
        tiled_out_cnt <= 12'd0;
    else if(pp_interleave_data_out_vld & pp_interleave_data_out_rdy) //后面需要改一下
        tiled_out_cnt <= tiled_out_cnt + 12'd1;
end


module pp_downscale_lanczos4_core(
    //outputs
    downscale_pixel_out,
    downscale_pixel_valid,
    downscale_ctrl,
    scan_pixel_ready,

    //input
    clk,
    rst_n,
    scan_pixel_in,
    scan_pixel_valid,
    scan_pixel_ctrl,
    phase_x_q9,
    phase_y_q9,
    downsacle_pixel_ready,
    bypass_en
);

parameter PIXEL_W = 10;
parameter CTRL_W  = 64;
parameter PHASE_W = 9;
parameter TAP_NUM = 8;
parameter COEF_W  = 16;  // signed Q2.14
parameter HACC_W  = 32;  // pixel * coef_x, then 8-tap sum, still Q2.14
parameter VACC_W  = 48;  // hsum * coef_y, then 8-tap sum, Q4.28

input clk;
input rst_n;
input [CTRL_W*PIXEL_W-1:0] scan_pixel_in;
input scan_pixel_valid;
input [CTRL_W-1:0] scan_pixel_ctrl;
input [PHASE_W-1:0] phase_x_q9;
input [PHASE_W-1:0] phase_y_q9;
input downsacle_pixel_ready;
input bypass_en;

output [PIXEL_W-1:0] downscale_pixel_out;
output downscale_pixel_valid;
output [CTRL_W-1:0]downscale_ctrl;
output scan_pixel_ready;

wire signed [COEF_W-1:0] coef_x0,coef_x1,coef_x2,coef_x3,coef_x4,coef_x5,coef_x6,coef_x7;
wire signed [COEF_W-1:0] coef_y0,coef_y1,coef_y2,coef_y3,coef_y4,coef_y5,coef_y6,coef_y7;

pp_downscale_lanczos4_coef_rom u_coed_x(
    .phase_q9(phase_x_r),
    .coef0(coef_x0),
    .coef1(coef_x1),
    .coef2(coef_x2),
    .coef3(coef_x3),
    .coef4(coef_x4),
    .coef5(coef_x5),
    .coef6(coef_x6),
    .coef7(coef_x7),

);

pp_downscale_lanczos4_coef_rom u_coed_y(
    .phase_q9(phase_y_r),
    .coef0(coef_y0),
    .coef1(coef_y1),
    .coef2(coef_y2),
    .coef3(coef_y3),
    .coef4(coef_y4),
    .coef5(coef_y5),
    .coef6(coef_y6),
    .coef7(coef_y7),
);
reg [TAP_NUM*TAP_NUM*PIXEL_W-1:0] pixels_r;
reg signed [HACC_W-1:0] hcalc_comb;
reg signed [VACC_W-1:0] vcalc_comb;
reg signed [VACC_W-1:0] rounded_q28_comb;
reg signed [VACC_W-1:0] rounded_int_comb;
reg [PIXEL_W-1:0] clip_pixel_comb;
reg [2:0] h_row_idx;
reg signed [HACC_W-1:0] h_sum [0:TAP_NUM-1];

always @(*)begin
    hcalc_comb = 
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 0*PIXEL_W) +: PIXEL_W]}) * coef_x0) +
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 1*PIXEL_W) +: PIXEL_W]}) * coef_x1) +
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 2*PIXEL_W) +: PIXEL_W]}) * coef_x2) +
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 3*PIXEL_W) +: PIXEL_W]}) * coef_x3) +
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 4*PIXEL_W) +: PIXEL_W]}) * coef_x4) +
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 5*PIXEL_W) +: PIXEL_W]}) * coef_x5) +
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 6*PIXEL_W) +: PIXEL_W]}) * coef_x6) +
        ($signed({1'b0,pixels_r[(h_row_idx*80 + 7*PIXEL_W) +: PIXEL_W]}) * coef_x7) ;
end

always @(*)begin
    vcalc_comb = 
        (h_sum[0] * coef_y0) + 
        (h_sum[1] * coef_y1) +
        (h_sum[2] * coef_y2) +
        (h_sum[3] * coef_y3) +
        (h_sum[4] * coef_y4) +
        (h_sum[5] * coef_y5) +
        (h_sum[6] * coef_y6) +
        (h_sum[7] * coef_y7) ;
end

always @(*)begin
    rounded_q28_comb = v_sum_r + (20'b0,1'b1,27'b0);
    rounded_int_comb = rounded_q28_comb >>> 28;
    if(rounded_int_comb <0) begin
        clip_pixel_comb = {10'b0};
    end else if (rounded_int_comb > 1023) begin
        clip_pixel_comb = {10'b1};
      
    end else begin
        clip_pixel_comb = rounded_int_comb[PIXEL_W-1:0]
    end
    
end

//状态机
localparam [2:0] LC_IDLE       = 3'd0;
localparam [2:0] LC_HCALC      = 3'd1;
localparam [2:0] LC_VCALC      = 3'd2;
localparam [2:0] LC_ROUND_CLIP = 3'd3;
localparam [2:0] LC_OUT        = 3'd4;

reg [2:0] lc_state;

reg [TAP_NUM*TAP_NUM*PIXEL_W-1:0] pixels_r;
reg [PHASE_W-1:0] phase_x_r;
reg [PHASE_W-1:0] phase_y_r;
reg [CTRL_W-1:0] ctrl_r;
reg bypass_r;

reg [PIXEL_W-1:0] pixel_out_r;
reg pixel_valid_r;
reg [CTRL_W-1:0] ctrl_out_r;
reg signed [VACC_W-1:0] v_sum_r;
wire scan_pixel_en;

assign scan_pixel_ready = (lc_state == LC_IDLE);
assign scan_pixel_en = scan_pixel_ready && scan_pixel_valid;
//output
assign downscale_ctrl = ctrl_out_r;
assign downscale_pixel_out = pixel_out_r;
assign downscale_pixel_valid = pixel_valid_r;

wire [PIXEL_W-1:0] center_pixel_in;
assign center_pixel_in  = scan_pixel_in[27*PIXEL_W+: PIXEL_W];

integer  i;

always @(posedge clk) begin
    if(!rst_n) begin
        lc_state   <= LC_IDLE;
        pixels_r   <= 640'b0;
        phase_x_q9 <= 9'b0;
        phase_y_q9 <= 9'b0;
        ctrl_r     <= 64'b0;
        bypass_r   <= 1'b0;
        pixel_out_r <=10'b0;
        pixel_valid_r <= 1'b0;
        ctrl_out_r    <= 54'b0;
        h_roe_idx     <= 3'b0;
        v_sum_r       <= 48'b0;
        for (i = 0;i<TAP_NUM;i=i + 1) begin
            h_sum[i] <= {HACC_W{1'b0}};
        end
    end else begin
        case(lc_state)
            LC_IDLE:begin
                pixel_valid_r <= 1'b0;
                if(scan_pixel_en) begin
                    pixel_out_r <= scan_pixel_in;
                    phase_x_r <= phase_x_q9;
                    phase_y_r <= phase_y_q9;
                    ctrl_r    <= scan_pixel_ctrl;
                    bypass_r  <= bypass_en;

                    if(bypass_en)begin
                        pixel_out_r<=center_pixel_in;
                        pixel_valid_r <= scan_pixel_ctrl;
                        pixel_valid_r <= 1'b1;
                        lc_state <= LC_OUT;

                    end else begin
                        h_row_idx <= 3'b0;
                        lc_state <= LC_HCALC;
                    end
                end
            end

            LC_HCALC:begin
                h_sum[h_row_idx] <= hcalc_comb;
                if(h_row_idx == 3'b7)begin
                    lc_state <= LC_VCALC;
                end else begin
                    h_row_idx <= h_row_idx + 1'b1;
                end
            end

            LC_VCALC:begin
                v_sum_r <= vcalc_comb;
                lc_state <= LC_ROUND_CLIP;
            end

            LC_ROUND_CLIP:begin
                pixel_out_r <= clip_pixel_comb;
                ctrl_out_r  <= ctrl_r;
                pixel_valid_r <= 1'b1;
                lc_state      <= LC_OUT;
            end

            LC_OUT:begin
                if(downsacle_pixel_ready)begin
                    pixel_valid_r <= 1'b0;
                    lc_state      <= LC_IDLE;
                end
            end
    
            default:begin
                lc_state <= LC_IDLE;
            end
        endcase
end

endmodule
