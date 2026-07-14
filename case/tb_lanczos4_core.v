`timescale 1ns/1ps

module tb_lanczos4_core;

parameter PIXEL_W = 10;
parameter CTRL_W  = 64;
parameter PHASE_W = 9;
parameter TAP_NUM = 8;
parameter WIN_W   = TAP_NUM*TAP_NUM*PIXEL_W;
parameter COEF_W  = 16;

reg clk;
reg rst_n;

reg [WIN_W-1:0] scan_pixels_in;
reg scan_pixels_valid;
wire scan_pixels_ready;
reg [PHASE_W-1:0] phase_x_q9;
reg [PHASE_W-1:0] phase_y_q9;
reg [CTRL_W-1:0] scan_ctrl_in;
reg bypass_en;
reg downscale_pixels_ready;

wire [PIXEL_W-1:0] downscale_pixel_out;
wire downscale_pixels_valid;
wire [CTRL_W-1:0] downscale_ctrl;

integer error_count;
integer output_count;
integer timeout_cnt;
integer i;
integer ref_row;
integer ref_col;

reg [PHASE_W-1:0] ref_phase_x_q9;
reg [PHASE_W-1:0] ref_phase_y_q9;

wire signed [COEF_W-1:0] ref_coef_x0;
wire signed [COEF_W-1:0] ref_coef_x1;
wire signed [COEF_W-1:0] ref_coef_x2;
wire signed [COEF_W-1:0] ref_coef_x3;
wire signed [COEF_W-1:0] ref_coef_x4;
wire signed [COEF_W-1:0] ref_coef_x5;
wire signed [COEF_W-1:0] ref_coef_x6;
wire signed [COEF_W-1:0] ref_coef_x7;

wire signed [COEF_W-1:0] ref_coef_y0;
wire signed [COEF_W-1:0] ref_coef_y1;
wire signed [COEF_W-1:0] ref_coef_y2;
wire signed [COEF_W-1:0] ref_coef_y3;
wire signed [COEF_W-1:0] ref_coef_y4;
wire signed [COEF_W-1:0] ref_coef_y5;
wire signed [COEF_W-1:0] ref_coef_y6;
wire signed [COEF_W-1:0] ref_coef_y7;

reg signed [63:0] ref_h_sum [0:TAP_NUM-1];
reg signed [63:0] ref_v_sum;
reg signed [63:0] ref_rounded;
reg signed [63:0] ref_int;
reg [PIXEL_W-1:0] exp_ref_pixel;

pp_downscale_lanczos4_core u_dut (
    .downscale_pixel_out(downscale_pixel_out),
    .downscale_pixels_valid(downscale_pixels_valid),
    .scan_pixels_ready(scan_pixels_ready),
    .downscale_ctrl(downscale_ctrl),
    .clk(clk),
    .rst_n(rst_n),
    .scan_pixels_in(scan_pixels_in),
    .scan_pixels_valid(scan_pixels_valid),
    .phase_x_q9(phase_x_q9),
    .phase_y_q9(phase_y_q9),
    .scan_ctrl_in(scan_ctrl_in),
    .bypass_en(bypass_en),
    .downscale_pixels_ready(downscale_pixels_ready)
);

pp_downscale_lanczos4_coef_rom u_ref_coef_x (
    .phase_q9(ref_phase_x_q9),
    .coef0(ref_coef_x0),
    .coef1(ref_coef_x1),
    .coef2(ref_coef_x2),
    .coef3(ref_coef_x3),
    .coef4(ref_coef_x4),
    .coef5(ref_coef_x5),
    .coef6(ref_coef_x6),
    .coef7(ref_coef_x7)
);

pp_downscale_lanczos4_coef_rom u_ref_coef_y (
    .phase_q9(ref_phase_y_q9),
    .coef0(ref_coef_y0),
    .coef1(ref_coef_y1),
    .coef2(ref_coef_y2),
    .coef3(ref_coef_y3),
    .coef4(ref_coef_y4),
    .coef5(ref_coef_y5),
    .coef6(ref_coef_y6),
    .coef7(ref_coef_y7)
);

always #5 clk = ~clk;

function [PIXEL_W-1:0] pixel_at;
    input [WIN_W-1:0] win;
    input integer idx;
begin
    pixel_at = win[idx*PIXEL_W +: PIXEL_W];
end
endfunction

function signed [COEF_W-1:0] ref_coef_x;
    input integer idx;
begin
    case (idx)
        0: ref_coef_x = ref_coef_x0;
        1: ref_coef_x = ref_coef_x1;
        2: ref_coef_x = ref_coef_x2;
        3: ref_coef_x = ref_coef_x3;
        4: ref_coef_x = ref_coef_x4;
        5: ref_coef_x = ref_coef_x5;
        6: ref_coef_x = ref_coef_x6;
        7: ref_coef_x = ref_coef_x7;
        default: ref_coef_x = 16'sd0;
    endcase
end
endfunction

function signed [COEF_W-1:0] ref_coef_y;
    input integer idx;
begin
    case (idx)
        0: ref_coef_y = ref_coef_y0;
        1: ref_coef_y = ref_coef_y1;
        2: ref_coef_y = ref_coef_y2;
        3: ref_coef_y = ref_coef_y3;
        4: ref_coef_y = ref_coef_y4;
        5: ref_coef_y = ref_coef_y5;
        6: ref_coef_y = ref_coef_y6;
        7: ref_coef_y = ref_coef_y7;
        default: ref_coef_y = 16'sd0;
    endcase
end
endfunction

task set_increment_window;
    input integer base;
    reg [PIXEL_W-1:0] pix_tmp;
begin
    pix_tmp = base[PIXEL_W-1:0];
    for (i = 0; i < 64; i = i + 1) begin
        scan_pixels_in[i*PIXEL_W +: PIXEL_W] = pix_tmp;
        pix_tmp = pix_tmp + 1'b1;
    end
end
endtask

task set_constant_window;
    input integer value;
begin
    for (i = 0; i < 64; i = i + 1) begin
        scan_pixels_in[i*PIXEL_W +: PIXEL_W] = value[PIXEL_W-1:0];
    end
end
endtask

task set_mixed_window;
    input integer base;
    reg [PIXEL_W-1:0] pix_tmp;
    integer mix_tmp;
begin
    for (i = 0; i < 64; i = i + 1) begin
        mix_tmp = base + (i * 17) + ((i % 7) * 23);
        pix_tmp = mix_tmp[PIXEL_W-1:0];
        scan_pixels_in[i*PIXEL_W +: PIXEL_W] = pix_tmp;
    end
end
endtask

task calc_reference_pixel;
    input [PHASE_W-1:0] phase_x;
    input [PHASE_W-1:0] phase_y;
    output [PIXEL_W-1:0] ref_pixel;
begin
    ref_phase_x_q9 = phase_x;
    ref_phase_y_q9 = phase_y;
    #1;

    for (ref_row = 0; ref_row < 8; ref_row = ref_row + 1) begin
        ref_h_sum[ref_row] = 64'sd0;
        for (ref_col = 0; ref_col < 8; ref_col = ref_col + 1) begin
            ref_h_sum[ref_row] = ref_h_sum[ref_row] +
                ($signed({1'b0, pixel_at(scan_pixels_in, ref_row*8 + ref_col)}) *
                 ref_coef_x(ref_col));
        end
    end

    ref_v_sum = 64'sd0;
    for (ref_row = 0; ref_row < 8; ref_row = ref_row + 1) begin
        ref_v_sum = ref_v_sum + (ref_h_sum[ref_row] * ref_coef_y(ref_row));
    end

    ref_rounded = ref_v_sum + 64'sd134217728;
    ref_int = ref_rounded >>> 28;

    if (ref_int < 0) begin
        ref_pixel = {PIXEL_W{1'b0}};
    end else if (ref_int > 1023) begin
        ref_pixel = {PIXEL_W{1'b1}};
    end else begin
        ref_pixel = ref_int[PIXEL_W-1:0];
    end
end
endtask

task send_window;
    input [PHASE_W-1:0] phase_x;
    input [PHASE_W-1:0] phase_y;
    input bypass;
    input [CTRL_W-1:0] ctrl;
begin
    timeout_cnt = 0;
    while (!scan_pixels_ready && (timeout_cnt < 1000)) begin
        @(posedge clk);
        #1;
        timeout_cnt = timeout_cnt + 1;
    end

    if (timeout_cnt >= 1000) begin
        $display("[%0t] ERROR: timeout waiting scan_pixels_ready", $time);
        error_count = error_count + 1;
    end

    phase_x_q9 = phase_x;
    phase_y_q9 = phase_y;
    bypass_en = bypass;
    scan_ctrl_in = ctrl;
    scan_pixels_valid = 1'b1;
    @(posedge clk);
    #1;
    scan_pixels_valid = 1'b0;
end
endtask

task wait_output;
    input [PIXEL_W-1:0] exp_pixel;
    input [CTRL_W-1:0] exp_ctrl;
begin
    timeout_cnt = 0;
    while (!downscale_pixels_valid && (timeout_cnt < 2000)) begin
        @(posedge clk);
        #1;
        timeout_cnt = timeout_cnt + 1;
    end

    if (timeout_cnt >= 2000) begin
        $display("[%0t] ERROR: timeout waiting output", $time);
        error_count = error_count + 1;
    end else begin
        output_count = output_count + 1;
        $display("[%0t] CORE_OUT count=%0d pixel=%0d ctrl=0x%016h",
                 $time, output_count, downscale_pixel_out, downscale_ctrl);

        if (downscale_pixel_out !== exp_pixel) begin
            $display("[%0t] ERROR: pixel mismatch, got=%0d exp=%0d",
                     $time, downscale_pixel_out, exp_pixel);
            error_count = error_count + 1;
        end

        if (downscale_ctrl !== exp_ctrl) begin
            $display("[%0t] ERROR: ctrl mismatch, got=0x%016h exp=0x%016h",
                     $time, downscale_ctrl, exp_ctrl);
            error_count = error_count + 1;
        end

        @(posedge clk);
        #1;
    end
end
endtask

task check_backpressure_hold;
    input [PIXEL_W-1:0] exp_pixel;
    input [CTRL_W-1:0] exp_ctrl;
begin
    downscale_pixels_ready = 1'b0;
    repeat (3) begin
        @(posedge clk);
        #1;
        if (downscale_pixels_valid !== 1'b1) begin
            $display("[%0t] ERROR: valid dropped during backpressure", $time);
            error_count = error_count + 1;
        end
        if (downscale_pixel_out !== exp_pixel) begin
            $display("[%0t] ERROR: pixel changed during backpressure, got=%0d exp=%0d",
                     $time, downscale_pixel_out, exp_pixel);
            error_count = error_count + 1;
        end
        if (downscale_ctrl !== exp_ctrl) begin
            $display("[%0t] ERROR: ctrl changed during backpressure, got=0x%016h exp=0x%016h",
                     $time, downscale_ctrl, exp_ctrl);
            error_count = error_count + 1;
        end
    end
    downscale_pixels_ready = 1'b1;
    @(posedge clk);
    #1;
end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    scan_pixels_in = {WIN_W{1'b0}};
    scan_pixels_valid = 1'b0;
    phase_x_q9 = {PHASE_W{1'b0}};
    phase_y_q9 = {PHASE_W{1'b0}};
    ref_phase_x_q9 = {PHASE_W{1'b0}};
    ref_phase_y_q9 = {PHASE_W{1'b0}};
    scan_ctrl_in = {CTRL_W{1'b0}};
    bypass_en = 1'b0;
    downscale_pixels_ready = 1'b1;
    error_count = 0;
    output_count = 0;
    timeout_cnt = 0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[%0t] CASE0: bypass returns center pixel", $time);
    set_increment_window(100);
    send_window(9'd123, 9'd321, 1'b1, 64'h1111_2222_3333_4444);
    wait_output(pixel_at(scan_pixels_in, 27), 64'h1111_2222_3333_4444);

    $display("[%0t] CASE1: phase zero returns center pixel through MAC", $time);
    set_increment_window(200);
    send_window(9'd0, 9'd0, 1'b0, 64'haaaa_bbbb_cccc_dddd);
    wait_output(pixel_at(scan_pixels_in, 27), 64'haaaa_bbbb_cccc_dddd);

    $display("[%0t] CASE2: constant window keeps same value for arbitrary phase", $time);
    set_constant_window(321);
    send_window(9'd256, 9'd384, 1'b0, 64'h0123_4567_89ab_cdef);
    wait_output(10'd321, 64'h0123_4567_89ab_cdef);

    $display("[%0t] CASE3: output backpressure holds valid/data/ctrl", $time);
    set_increment_window(300);
    send_window(9'd0, 9'd0, 1'b0, 64'h5555_aaaa_1234_9876);
    timeout_cnt = 0;
    while (!downscale_pixels_valid && (timeout_cnt < 2000)) begin
        @(posedge clk);
        #1;
        timeout_cnt = timeout_cnt + 1;
    end
    if (timeout_cnt >= 2000) begin
        $display("[%0t] ERROR: timeout waiting output before backpressure check", $time);
        error_count = error_count + 1;
    end else begin
        check_backpressure_hold(pixel_at(scan_pixels_in, 27), 64'h5555_aaaa_1234_9876);
        output_count = output_count + 1;
    end

    $display("[%0t] CASE4: reference compare, mixed window phase=(64,128)", $time);
    set_mixed_window(17);
    calc_reference_pixel(9'd64, 9'd128, exp_ref_pixel);
    send_window(9'd64, 9'd128, 1'b0, 64'h0000_0000_0000_0004);
    wait_output(exp_ref_pixel, 64'h0000_0000_0000_0004);

    $display("[%0t] CASE5: reference compare, mixed window phase=(255,511)", $time);
    set_mixed_window(73);
    calc_reference_pixel(9'd255, 9'd511, exp_ref_pixel);
    send_window(9'd255, 9'd511, 1'b0, 64'h0000_0000_0000_0005);
    wait_output(exp_ref_pixel, 64'h0000_0000_0000_0005);

    $display("[%0t] CASE6: reference compare, mixed window phase=(400,37)", $time);
    set_mixed_window(501);
    calc_reference_pixel(9'd400, 9'd37, exp_ref_pixel);
    send_window(9'd400, 9'd37, 1'b0, 64'h0000_0000_0000_0006);
    wait_output(exp_ref_pixel, 64'h0000_0000_0000_0006);

    repeat (5) @(posedge clk);
    if (error_count == 0) begin
        $display("PASS: tb_lanczos4_core completed with no errors, outputs=%0d", output_count);
    end else begin
        $display("FAIL: tb_lanczos4_core completed with %0d errors, outputs=%0d",
                 error_count, output_count);
    end
    $finish;
end

endmodule
