`timescale 1ns/1ps

module pp_downscale_lanczos4_core (
    // outputs
    downscale_pixel_out,
    downscale_pixels_valid,
    scan_pixels_ready,
    downscale_ctrl,

    // inputs
    clk,
    rst_n,
    scan_pixels_in,
    scan_pixels_valid,
    phase_x_q9,
    phase_y_q9,
    scan_ctrl_in,
    bypass_en,
    downscale_pixels_ready
);

parameter PIXEL_W = 10;
parameter CTRL_W  = 64;
parameter PHASE_W = 9;
parameter TAP_NUM = 8;
parameter COEF_W  = 16;  // signed Q2.14
parameter HACC_W  = 32;  // horizontal sum, Q?.14
parameter VACC_W  = 48;  // vertical sum, Q?.28

localparam INT_W = VACC_W - 28;

input clk;
input rst_n;
input [TAP_NUM*TAP_NUM*PIXEL_W-1:0] scan_pixels_in;
input scan_pixels_valid;
input [PHASE_W-1:0] phase_x_q9;
input [PHASE_W-1:0] phase_y_q9;
input [CTRL_W-1:0] scan_ctrl_in;
input bypass_en;
input downscale_pixels_ready;

output [PIXEL_W-1:0] downscale_pixel_out;
output downscale_pixels_valid;
output scan_pixels_ready;
output [CTRL_W-1:0] downscale_ctrl;

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

reg [2:0] h_row_idx;
reg signed [HACC_W-1:0] h_sum [0:TAP_NUM-1];
reg signed [VACC_W-1:0] v_sum_r;

wire scan_pixels_en;
assign scan_pixels_ready = (lc_state == LC_IDLE);
assign scan_pixels_en = scan_pixels_valid && scan_pixels_ready;

assign downscale_pixel_out = pixel_out_r;
assign downscale_pixels_valid = pixel_valid_r;
assign downscale_ctrl = ctrl_out_r;

wire [PIXEL_W-1:0] center_pixel_in;
assign center_pixel_in = scan_pixels_in[27*PIXEL_W +: PIXEL_W];

wire signed [COEF_W-1:0] coef_x0;
wire signed [COEF_W-1:0] coef_x1;
wire signed [COEF_W-1:0] coef_x2;
wire signed [COEF_W-1:0] coef_x3;
wire signed [COEF_W-1:0] coef_x4;
wire signed [COEF_W-1:0] coef_x5;
wire signed [COEF_W-1:0] coef_x6;
wire signed [COEF_W-1:0] coef_x7;

wire signed [COEF_W-1:0] coef_y0;
wire signed [COEF_W-1:0] coef_y1;
wire signed [COEF_W-1:0] coef_y2;
wire signed [COEF_W-1:0] coef_y3;
wire signed [COEF_W-1:0] coef_y4;
wire signed [COEF_W-1:0] coef_y5;
wire signed [COEF_W-1:0] coef_y6;
wire signed [COEF_W-1:0] coef_y7;

pp_downscale_lanczos4_coef_rom u_coef_x (
    .phase_q9(phase_x_r),
    .coef0(coef_x0),
    .coef1(coef_x1),
    .coef2(coef_x2),
    .coef3(coef_x3),
    .coef4(coef_x4),
    .coef5(coef_x5),
    .coef6(coef_x6),
    .coef7(coef_x7)
);

pp_downscale_lanczos4_coef_rom u_coef_y (
    .phase_q9(phase_y_r),
    .coef0(coef_y0),
    .coef1(coef_y1),
    .coef2(coef_y2),
    .coef3(coef_y3),
    .coef4(coef_y4),
    .coef5(coef_y5),
    .coef6(coef_y6),
    .coef7(coef_y7)
);

reg signed [HACC_W-1:0] hcalc_comb;
reg signed [VACC_W-1:0] vcalc_comb;
reg signed [VACC_W-1:0] rounded_q28_comb;
reg signed [INT_W-1:0]  rounded_int_comb;
reg [PIXEL_W-1:0] clip_pixel_comb;

// Horizontal 8-tap combination. h_row_idx selects one row in the 8x8 window.
always @(*) begin
    hcalc_comb =
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 0*PIXEL_W) +: PIXEL_W]}) * coef_x0) +
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 1*PIXEL_W) +: PIXEL_W]}) * coef_x1) +
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 2*PIXEL_W) +: PIXEL_W]}) * coef_x2) +
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 3*PIXEL_W) +: PIXEL_W]}) * coef_x3) +
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 4*PIXEL_W) +: PIXEL_W]}) * coef_x4) +
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 5*PIXEL_W) +: PIXEL_W]}) * coef_x5) +
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 6*PIXEL_W) +: PIXEL_W]}) * coef_x6) +
        ($signed({1'b0, pixels_r[(h_row_idx*80 + 7*PIXEL_W) +: PIXEL_W]}) * coef_x7);
end

// Vertical 8-tap combination. h_sum is Q?.14 and coef_y is Q2.14.
always @(*) begin
    vcalc_comb =
        (h_sum[0] * coef_y0) +
        (h_sum[1] * coef_y1) +
        (h_sum[2] * coef_y2) +
        (h_sum[3] * coef_y3) +
        (h_sum[4] * coef_y4) +
        (h_sum[5] * coef_y5) +
        (h_sum[6] * coef_y6) +
        (h_sum[7] * coef_y7);
end

// v_sum_r is signed Q?.28. Round to integer and clip to 10-bit pixel range.
always @(*) begin
    rounded_q28_comb = v_sum_r + {{(VACC_W-28){1'b0}}, 1'b1, 27'd0};
    rounded_int_comb = rounded_q28_comb[VACC_W-1:28];

    if (rounded_int_comb < 0) begin
        clip_pixel_comb = {PIXEL_W{1'b0}};
    end else if (rounded_int_comb > 1023) begin
        clip_pixel_comb = {PIXEL_W{1'b1}};
    end else begin
        clip_pixel_comb = rounded_int_comb[PIXEL_W-1:0];
    end
end

integer i;

always @(posedge clk) begin
    if (!rst_n) begin
        lc_state <= LC_IDLE;
        pixels_r <= {(TAP_NUM*TAP_NUM*PIXEL_W){1'b0}};
        phase_x_r <= {PHASE_W{1'b0}};
        phase_y_r <= {PHASE_W{1'b0}};
        ctrl_r <= {CTRL_W{1'b0}};
        bypass_r <= 1'b0;
        pixel_out_r <= {PIXEL_W{1'b0}};
        pixel_valid_r <= 1'b0;
        ctrl_out_r <= {CTRL_W{1'b0}};
        h_row_idx <= 3'd0;
        v_sum_r <= {VACC_W{1'b0}};
        for (i = 0; i < TAP_NUM; i = i + 1) begin
            h_sum[i] <= {HACC_W{1'b0}};
        end
    end else begin
        case (lc_state)
            LC_IDLE: begin
                pixel_valid_r <= 1'b0;
                if (scan_pixels_en) begin
                    pixels_r <= scan_pixels_in;
                    phase_x_r <= phase_x_q9;
                    phase_y_r <= phase_y_q9;
                    ctrl_r <= scan_ctrl_in;
                    bypass_r <= bypass_en;

                    if (bypass_en) begin
                        pixel_out_r <= center_pixel_in;
                        ctrl_out_r <= scan_ctrl_in;
                        pixel_valid_r <= 1'b1;
                        lc_state <= LC_OUT;
                    end else begin
                        h_row_idx <= 3'd0;
                        lc_state <= LC_HCALC;
                    end
                end
            end

            LC_HCALC: begin
                h_sum[h_row_idx] <= hcalc_comb;
                if (h_row_idx == 3'd7) begin
                    lc_state <= LC_VCALC;
                end else begin
                    h_row_idx <= h_row_idx + 1'b1;
                    lc_state <= LC_HCALC;
                end
            end

            LC_VCALC: begin
                v_sum_r <= vcalc_comb;
                lc_state <= LC_ROUND_CLIP;
            end

            LC_ROUND_CLIP: begin
                pixel_out_r <= clip_pixel_comb;
                ctrl_out_r <= ctrl_r;
                pixel_valid_r <= 1'b1;
                lc_state <= LC_OUT;
            end

            LC_OUT: begin
                if (downscale_pixels_ready) begin
                    pixel_valid_r <= 1'b0;
                    lc_state <= LC_IDLE;
                end else begin
                    lc_state <= LC_OUT;
                end
            end

            default: begin
                lc_state <= LC_IDLE;
            end
        endcase
    end
end

endmodule
