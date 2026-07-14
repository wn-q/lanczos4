`timescale 1ns/1ps

module tb_downscale_image_ref;

localparam PIXEL_W         = 10;
localparam COEF_W          = 16;
localparam LANCZOS_TAPS    = 8;
localparam WIN_PIX_NUM     = 64;
localparam TAP_COORD_W     = 13;
localparam BUF_TAP_COORD_W = 14;
localparam DST_W           = 13;
localparam CTRL_W          = 64;
localparam SRC_W           = 64;
localparam SRC_H           = 64;
localparam DST_IMG_W       = 32;
localparam DST_IMG_H       = 32;
localparam FIFO_DEPTH      = 2048;
localparam CLK_PERIOD      = 10;

reg clk;
reg rst_n;

reg [53:0] fg2pp_ctrl;
reg [12:0] sw_pic_height;
reg [12:0] sw_upscale_pic_width;
reg        ctrl_vld;
wire       ctrl_rdy;
reg        scan_ctrl_vld;
wire       scan_ctrl_rdy;

reg        data_vld;
reg [159:0] data_in;
wire       data_rdy;

reg [11:0] scale_q8;
reg [DST_W-1:0] dst_width;
reg [DST_W-1:0] dst_height;

wire        center_req_valid;
wire signed [TAP_COORD_W-1:0] center_x;
wire signed [TAP_COORD_W-1:0] center_y;
wire signed [BUF_TAP_COORD_W-1:0] buffer_center_x;
wire signed [BUF_TAP_COORD_W-1:0] buffer_center_y;

wire [WIN_PIX_NUM*PIXEL_W-1:0] scan_window_pixels;
wire                           scan_window_valid;

wire        scan_lanczos_valid;
wire        core_scan_ready;
wire [DST_W-1:0] scan_lanczos_dst_x;
wire [DST_W-1:0] scan_lanczos_dst_y;
wire [8:0] scan_lanczos_phase_x_q9;
wire [8:0] scan_lanczos_phase_y_q9;
wire [WIN_PIX_NUM*PIXEL_W-1:0] scan_lanczos_window_pixels;
wire        scan_lanczos_block_row_last;
wire        scan_lanczos_bypass_en;
wire [CTRL_W-1:0] scan_lanczos_ctrl;
wire        scan_block_done;

wire [PIXEL_W-1:0] downscale_pixel_out;
wire               downscale_pixels_valid;
reg                downscale_pixels_ready;
wire [CTRL_W-1:0]  downscale_ctrl;

reg [8:0] ref_phase_x_q9;
reg [8:0] ref_phase_y_q9;

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

integer error_count;
integer scanner_accept_count;
integer core_output_count;
integer send_count;
integer timeout_cnt;
integer fifo_wr_ptr;
integer fifo_rd_ptr;
integer row_print;
integer col_print;

reg [PIXEL_W-1:0] exp_fifo_pixel [0:FIFO_DEPTH-1];
reg [DST_W-1:0]   exp_fifo_dst_x [0:FIFO_DEPTH-1];
reg [DST_W-1:0]   exp_fifo_dst_y [0:FIFO_DEPTH-1];
reg [CTRL_W-1:0]  exp_fifo_ctrl  [0:FIFO_DEPTH-1];
reg [PIXEL_W-1:0] output_img      [0:DST_IMG_H-1][0:DST_IMG_W-1];
reg [PIXEL_W-1:0] reference_img   [0:DST_IMG_H-1][0:DST_IMG_W-1];
reg [PIXEL_W-1:0] expected_pixel_tmp;

reg block_scan_done_seen;
reg [53:0] current_block_ctrl;

assign buffer_center_x = {center_x[TAP_COORD_W-1], center_x};
assign buffer_center_y = {center_y[TAP_COORD_W-1], center_y};

pp_downscale_block_buffer #(
    .PIXEL_W(PIXEL_W),
    .LANCZOS_TAPS(LANCZOS_TAPS),
    .TAP_COORD_W(BUF_TAP_COORD_W)
) u_buf (
    .clk(clk),
    .rst_n(rst_n),
    .fg2pp_ctrl(fg2pp_ctrl),
    .sw_pic_height(sw_pic_height),
    .sw_upscale_pic_width(sw_upscale_pic_width),
    .ctrl_vld(ctrl_vld),
    .ctrl_rdy(ctrl_rdy),
    .data_vld(data_vld),
    .data_rdy(data_rdy),
    .data_in(data_in),
    .scan_block_done_i(scan_block_done),
    .scan_center_valid_i(center_req_valid),
    .scan_center_x_i(buffer_center_x),
    .scan_center_y_i(buffer_center_y),
    .scan_window_pixels_o(scan_window_pixels),
    .scan_window_valid_o(scan_window_valid)
);

pp_downscale_dst_scan_ctrl #(
    .PIXEL_W(PIXEL_W),
    .DST_W(DST_W),
    .TAP_COORD_W(TAP_COORD_W),
    .WIN_PIX_NUM(WIN_PIX_NUM),
    .CTRL_W(CTRL_W)
) u_scan (
    .clk(clk),
    .rst_n(rst_n),
    .scale_q8(scale_q8),
    .dst_width(dst_width),
    .dst_height(dst_height),
    .ctrl_vld_i(scan_ctrl_vld),
    .ctrl_rdy_o(scan_ctrl_rdy),
    .fg2pp_ctrl_i(fg2pp_ctrl),
    .req_buf_data_valid_o(center_req_valid),
    .buf_center_x_o(center_x),
    .buf_center_y_o(center_y),
    .buf_window_valid_i(scan_window_valid),
    .buf_window_pixels_i(scan_window_pixels),
    .lanczos_valid_o(scan_lanczos_valid),
    .lanczos_ready_i(core_scan_ready),
    .lanczos_dst_x_o(scan_lanczos_dst_x),
    .lanczos_dst_y_o(scan_lanczos_dst_y),
    .lanczos_phase_x_q9_o(scan_lanczos_phase_x_q9),
    .lanczos_phase_y_q9_o(scan_lanczos_phase_y_q9),
    .lanczos_window_pixels_o(scan_lanczos_window_pixels),
    .lanczos_block_row_last_o(scan_lanczos_block_row_last),
    .lanczos_bypass_en_o(scan_lanczos_bypass_en),
    .lanczos_ctrl_o(scan_lanczos_ctrl),
    .buf_block_scan_done_o(scan_block_done)
);

pp_downscale_lanczos4_core #(
    .PIXEL_W(PIXEL_W),
    .CTRL_W(CTRL_W),
    .TAP_NUM(LANCZOS_TAPS)
) u_core (
    .clk(clk),
    .rst_n(rst_n),
    .scan_pixels_in(scan_lanczos_window_pixels),
    .scan_pixels_valid(scan_lanczos_valid),
    .scan_pixels_ready(core_scan_ready),
    .phase_x_q9(scan_lanczos_phase_x_q9),
    .phase_y_q9(scan_lanczos_phase_y_q9),
    .scan_ctrl_in(scan_lanczos_ctrl),
    .bypass_en(scan_lanczos_bypass_en),
    .downscale_pixels_ready(downscale_pixels_ready),
    .downscale_pixels_valid(downscale_pixels_valid),
    .downscale_pixel_out(downscale_pixel_out),
    .downscale_ctrl(downscale_ctrl)
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

always #(CLK_PERIOD/2) clk = ~clk;

function integer tap_offset;
    input integer tap_idx;
begin
    case (tap_idx)
        0: tap_offset = -3;
        1: tap_offset = -2;
        2: tap_offset = -1;
        3: tap_offset = 0;
        4: tap_offset = 1;
        5: tap_offset = 2;
        6: tap_offset = 3;
        7: tap_offset = 4;
        default: tap_offset = 0;
    endcase
end
endfunction

function integer clip_coord;
    input integer value;
    input integer max_value;
begin
    if (value < 0) begin
        clip_coord = 0;
    end else if (value > max_value) begin
        clip_coord = max_value;
    end else begin
        clip_coord = value;
    end
end
endfunction

function [PIXEL_W-1:0] source_pixel;
    input integer x;
    input integer y;
    integer value;
begin
    value = (x * 17) + (y * 29) + (x * y * 3) + ((x ^ y) * 5) + 37;
    source_pixel = value[PIXEL_W-1:0];
end
endfunction

function [159:0] make_segment;
    input integer y;
    input integer x_base;
    integer lane;
begin
    make_segment = 160'd0;
    for (lane = 0; lane < 16; lane = lane + 1) begin
        make_segment[lane*PIXEL_W +: PIXEL_W] = source_pixel(x_base + lane, y);
    end
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

task calc_reference_pixel;
    input integer center_x_i;
    input integer center_y_i;
    input [8:0] phase_x_i;
    input [8:0] phase_y_i;
    output [PIXEL_W-1:0] ref_pixel;
    integer row_idx;
    integer col_idx;
    integer src_x;
    integer src_y;
    reg signed [63:0] h_sum [0:LANCZOS_TAPS-1];
    reg signed [63:0] v_sum;
    reg signed [63:0] rounded;
    reg signed [63:0] rounded_int;
begin
    ref_phase_x_q9 = phase_x_i;
    ref_phase_y_q9 = phase_y_i;
    #1;

    for (row_idx = 0; row_idx < LANCZOS_TAPS; row_idx = row_idx + 1) begin
        h_sum[row_idx] = 64'sd0;
        for (col_idx = 0; col_idx < LANCZOS_TAPS; col_idx = col_idx + 1) begin
            src_x = clip_coord(center_x_i + tap_offset(col_idx), SRC_W - 1);
            src_y = clip_coord(center_y_i + tap_offset(row_idx), SRC_H - 1);
            h_sum[row_idx] = h_sum[row_idx] +
                ($signed({1'b0, source_pixel(src_x, src_y)}) * ref_coef_x(col_idx));
        end
    end

    v_sum = 64'sd0;
    for (row_idx = 0; row_idx < LANCZOS_TAPS; row_idx = row_idx + 1) begin
        v_sum = v_sum + (h_sum[row_idx] * ref_coef_y(row_idx));
    end

    rounded = v_sum + 64'sd134217728;
    rounded_int = rounded >>> 28;

    if (rounded_int < 0) begin
        ref_pixel = {PIXEL_W{1'b0}};
    end else if (rounded_int > 1023) begin
        ref_pixel = {PIXEL_W{1'b1}};
    end else begin
        ref_pixel = rounded_int[PIXEL_W-1:0];
    end
end
endtask

task reset_dut;
    integer r;
    integer c;
begin
    clk = 1'b0;
    rst_n = 1'b0;
    fg2pp_ctrl = 54'd0;
    sw_pic_height = 13'd64;
    sw_upscale_pic_width = 13'd64;
    ctrl_vld = 1'b0;
    scan_ctrl_vld = 1'b0;
    data_vld = 1'b0;
    data_in = 160'd0;
    scale_q8 = 12'd512;
    dst_width = 13'd32;
    dst_height = 13'd32;
    downscale_pixels_ready = 1'b1;
    ref_phase_x_q9 = 9'd0;
    ref_phase_y_q9 = 9'd0;
    error_count = 0;
    scanner_accept_count = 0;
    core_output_count = 0;
    send_count = 0;
    timeout_cnt = 0;
    fifo_wr_ptr = 0;
    fifo_rd_ptr = 0;
    block_scan_done_seen = 1'b0;
    current_block_ctrl = 54'd0;

    for (r = 0; r < DST_IMG_H; r = r + 1) begin
        for (c = 0; c < DST_IMG_W; c = c + 1) begin
            output_img[r][c] = {PIXEL_W{1'b0}};
            reference_img[r][c] = {PIXEL_W{1'b0}};
        end
    end

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
end
endtask

task config_block;
    input integer start_x;
    input integer start_y;
    input integer width;
    input integer height;
    input integer frame_top;
    input integer frame_bottom;
    input integer frame_left;
    input integer frame_right;
begin
    block_scan_done_seen = 1'b0;

    @(negedge clk);
    fg2pp_ctrl = 54'd0;
    fg2pp_ctrl[6:0]   = height[6:0];
    fg2pp_ctrl[14:7]  = width[7:0];
    fg2pp_ctrl[15]    = (frame_top != 0);
    fg2pp_ctrl[16]    = (frame_bottom != 0);
    fg2pp_ctrl[17]    = (frame_left != 0);
    fg2pp_ctrl[18]    = (frame_right != 0);
    fg2pp_ctrl[19]    = (frame_top != 0);
    fg2pp_ctrl[20]    = (frame_bottom != 0);
    fg2pp_ctrl[21]    = (frame_left != 0);
    fg2pp_ctrl[22]    = (frame_right != 0);
    fg2pp_ctrl[35:23] = start_x[12:0];
    fg2pp_ctrl[48:36] = start_y[12:0];
    current_block_ctrl = fg2pp_ctrl;

    timeout_cnt = 0;
    while (!(ctrl_rdy && scan_ctrl_rdy) && (timeout_cnt < 20000)) begin
        @(negedge clk);
        timeout_cnt = timeout_cnt + 1;
    end

    if (!(ctrl_rdy && scan_ctrl_rdy)) begin
        $display("[%0t] ERROR: timeout waiting ctrl ready, buf=%0d scan=%0d",
                 $time, ctrl_rdy, scan_ctrl_rdy);
        error_count = error_count + 1;
    end

    ctrl_vld = 1'b1;
    scan_ctrl_vld = 1'b1;
    @(negedge clk);
    ctrl_vld = 1'b0;
    scan_ctrl_vld = 1'b0;

    $display("[%0t] CONFIG_BLOCK start=(%0d,%0d) size=%0dx%0d top=%0d bottom=%0d left=%0d right=%0d",
             $time, start_x, start_y, width, height,
             frame_top, frame_bottom, frame_left, frame_right);
end
endtask

task send_segment;
    input integer y;
    input integer x_base;
begin
    @(negedge clk);
    data_in = make_segment(y, x_base);
    data_vld = 1'b1;

    timeout_cnt = 0;
    while (!data_rdy && (timeout_cnt < 20000)) begin
        @(negedge clk);
        timeout_cnt = timeout_cnt + 1;
    end

    if (!data_rdy) begin
        $display("[%0t] ERROR: timeout waiting data_rdy for segment x=%0d y=%0d",
                 $time, x_base, y);
        error_count = error_count + 1;
    end else begin
        send_count = send_count + 1;
        @(negedge clk);
    end

    data_vld = 1'b0;
    data_in = 160'd0;
end
endtask

task wait_buffer_idle;
begin
    timeout_cnt = 0;
    while (!((u_buf.cur_state == 3'd0) &&
             (u_buf.wb_state == 3'd0) &&
             (u_buf.win_state == 3'd0) &&
             (u_buf.line_wr_state == 3'd0) &&
             (u_buf.right_rd_state == 3'd0) &&
             (u_buf.bottom_wr_state == 2'd0) &&
             (u_buf.corner_rd_state == 2'd0)) &&
           (timeout_cnt < 50000)) begin
        @(posedge clk);
        timeout_cnt = timeout_cnt + 1;
    end

    if (timeout_cnt >= 50000) begin
        $display("[%0t] ERROR: timeout waiting buffer idle", $time);
        error_count = error_count + 1;
    end
end
endtask

task wait_core_drain;
begin
    timeout_cnt = 0;
    while ((core_output_count < scanner_accept_count) && (timeout_cnt < 50000)) begin
        @(posedge clk);
        timeout_cnt = timeout_cnt + 1;
    end

    if (timeout_cnt >= 50000) begin
        $display("[%0t] ERROR: timeout waiting core drain, core=%0d scanner=%0d",
                 $time, core_output_count, scanner_accept_count);
        error_count = error_count + 1;
    end
end
endtask

task wait_block_done;
begin
    timeout_cnt = 0;
    while (!block_scan_done_seen && (timeout_cnt < 50000)) begin
        @(posedge clk);
        timeout_cnt = timeout_cnt + 1;
    end

    if (!block_scan_done_seen) begin
        $display("[%0t] ERROR: timeout waiting scanner block done", $time);
        error_count = error_count + 1;
    end

    wait_buffer_idle();
    wait_core_drain();
end
endtask

task run_full_block;
    input integer start_x;
    input integer start_y;
    input integer frame_top;
    input integer frame_bottom;
    input integer frame_left;
    input integer frame_right;
    integer row;
begin
    config_block(start_x, start_y, 32, 32,
                 frame_top, frame_bottom, frame_left, frame_right);

    for (row = 0; row < 32; row = row + 1) begin
        send_segment(start_y + row, start_x);
        send_segment(start_y + row, start_x + 16);
    end

    wait_block_done();
end
endtask

task print_downscaled_image;
begin
    $display("RTL_DOWNSCALE_IMAGE_BEGIN");
    for (row_print = 0; row_print < DST_IMG_H; row_print = row_print + 1) begin
        $write("DST_ROW %02d:", row_print);
        for (col_print = 0; col_print < DST_IMG_W; col_print = col_print + 1) begin
            $write(" %0d", output_img[row_print][col_print]);
        end
        $write("\n");
    end
    $display("RTL_DOWNSCALE_IMAGE_END");
end
endtask

always @(posedge clk) begin
    if (!rst_n) begin
        block_scan_done_seen <= 1'b0;
    end else if (scan_block_done) begin
        block_scan_done_seen <= 1'b1;
    end
end

always @(posedge clk) begin
    if (rst_n && scan_lanczos_valid && core_scan_ready) begin
        if (fifo_wr_ptr >= FIFO_DEPTH) begin
            $display("[%0t] ERROR: expected FIFO overflow", $time);
            error_count = error_count + 1;
        end else begin
            calc_reference_pixel(scan_lanczos_dst_x * 2,
                                 scan_lanczos_dst_y * 2,
                                 scan_lanczos_phase_x_q9,
                                 scan_lanczos_phase_y_q9,
                                 expected_pixel_tmp);
            exp_fifo_pixel[fifo_wr_ptr] = expected_pixel_tmp;
            exp_fifo_dst_x[fifo_wr_ptr] = scan_lanczos_dst_x;
            exp_fifo_dst_y[fifo_wr_ptr] = scan_lanczos_dst_y;
            exp_fifo_ctrl[fifo_wr_ptr] = scan_lanczos_ctrl;
            reference_img[scan_lanczos_dst_y][scan_lanczos_dst_x] =
                expected_pixel_tmp;
            fifo_wr_ptr = fifo_wr_ptr + 1;
        end

        scanner_accept_count = scanner_accept_count + 1;
        if ((scanner_accept_count < 8) || scan_lanczos_block_row_last) begin
            $display("[%0t] SCAN_ACCEPT count=%0d dst=(%0d,%0d) phase=(%0d,%0d) row_last=%0d",
                     $time, scanner_accept_count + 1,
                     scan_lanczos_dst_x, scan_lanczos_dst_y,
                     scan_lanczos_phase_x_q9, scan_lanczos_phase_y_q9,
                     scan_lanczos_block_row_last);
        end
    end
end

always @(posedge clk) begin
    if (rst_n && downscale_pixels_valid && downscale_pixels_ready) begin
        if (fifo_rd_ptr >= fifo_wr_ptr) begin
            $display("[%0t] ERROR: core output without expected FIFO data, pixel=%0d",
                     $time, downscale_pixel_out);
            error_count = error_count + 1;
        end else begin
            output_img[exp_fifo_dst_y[fifo_rd_ptr]][exp_fifo_dst_x[fifo_rd_ptr]] =
                downscale_pixel_out;

            if (downscale_pixel_out !== exp_fifo_pixel[fifo_rd_ptr]) begin
                $display("[%0t] ERROR: output pixel mismatch dst=(%0d,%0d) got=%0d exp=%0d",
                         $time,
                         exp_fifo_dst_x[fifo_rd_ptr],
                         exp_fifo_dst_y[fifo_rd_ptr],
                         downscale_pixel_out,
                         exp_fifo_pixel[fifo_rd_ptr]);
                error_count = error_count + 1;
            end

            if (downscale_ctrl !== exp_fifo_ctrl[fifo_rd_ptr]) begin
                $display("[%0t] ERROR: output ctrl mismatch dst=(%0d,%0d) got=0x%016h exp=0x%016h",
                         $time,
                         exp_fifo_dst_x[fifo_rd_ptr],
                         exp_fifo_dst_y[fifo_rd_ptr],
                         downscale_ctrl,
                         exp_fifo_ctrl[fifo_rd_ptr]);
                error_count = error_count + 1;
            end

            core_output_count = core_output_count + 1;
            if (core_output_count < 8) begin
                $display("[%0t] CORE_OUT count=%0d dst=(%0d,%0d) pixel=%0d ref=%0d",
                         $time, core_output_count + 1,
                         exp_fifo_dst_x[fifo_rd_ptr],
                         exp_fifo_dst_y[fifo_rd_ptr],
                         downscale_pixel_out,
                         exp_fifo_pixel[fifo_rd_ptr]);
            end
            fifo_rd_ptr = fifo_rd_ptr + 1;
        end
    end
end

initial begin
`ifndef VERILATOR
    if ($test$plusargs("DUMP_VPD")) begin
        $display("[%0t] INFO: enable VPD waveform dump: tb_downscale_image_ref.vpd", $time);
        $vcdplusfile("tb_downscale_image_ref.vpd");
        $vcdplusmemon;
        $vcdpluson;
    end
`endif

    if ($test$plusargs("DUMP_VCD")) begin
        $display("[%0t] INFO: enable VCD waveform dump: tb_downscale_image_ref.vcd", $time);
        $dumpfile("tb_downscale_image_ref.vcd");
        $dumpvars(0);
    end
end

initial begin
    reset_dut();

    $display("[%0t] CASE: deterministic 64x64 image, Lanczos4 2x downscale to 32x32", $time);
    run_full_block(0, 0, 1, 0, 1, 0);
    run_full_block(32, 0, 1, 0, 0, 1);
    run_full_block(0, 32, 0, 1, 1, 0);
    run_full_block(32, 32, 0, 1, 0, 1);

    wait_core_drain();
    repeat (20) @(posedge clk);

    if (scanner_accept_count !== (DST_IMG_W * DST_IMG_H)) begin
        $display("[%0t] ERROR: scanner count mismatch, got=%0d exp=%0d",
                 $time, scanner_accept_count, DST_IMG_W * DST_IMG_H);
        error_count = error_count + 1;
    end

    if (core_output_count !== (DST_IMG_W * DST_IMG_H)) begin
        $display("[%0t] ERROR: core count mismatch, got=%0d exp=%0d",
                 $time, core_output_count, DST_IMG_W * DST_IMG_H);
        error_count = error_count + 1;
    end

    print_downscaled_image();

    $display("[%0t] SUMMARY: input_segments=%0d scanner_to_core=%0d core_outputs=%0d errors=%0d",
             $time, send_count, scanner_accept_count, core_output_count, error_count);

    if (error_count == 0) begin
        $display("PASS: tb_downscale_image_ref completed with no errors");
    end else begin
        $display("FAIL: tb_downscale_image_ref completed with %0d errors", error_count);
    end

    $finish;
end

endmodule
