`timescale 1ns/1ps

module tb_downscale_scan_buffer_core;

localparam PIXEL_W         = 10;
localparam LANCZOS_TAPS    = 8;
localparam WIN_PIX_NUM     = 64;
localparam TAP_COORD_W     = 13;
localparam BUF_TAP_COORD_W = 14;
localparam DST_W           = 13;
localparam CTRL_W          = 64;
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

integer error_count;
integer scanner_accept_count;
integer core_output_count;
integer buffer_window_count;
integer send_count;
integer timeout_cnt;
integer seen_idx;
reg [1023:0] seen_dst;
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

always #(CLK_PERIOD/2) clk = ~clk;

// Lanczos4 8-tap window 的 tap 下标到相对 center 偏移的映射。
// window 顺序为 -3, -2, -1, 0, +1, +2, +3, +4。
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

// 对源图坐标做边界钳位。测试模型用 clamp 方式处理 frame 边界，
// 负坐标钳到 0，超过最大坐标时钳到 max_value。
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

// 生成参考源图像素值。tb 使用一张可计算的 64x64 测试图，
// 像素值为 y * 100 + x，并截断到 PIXEL_W 位。
function [PIXEL_W-1:0] pixel_value;
    input integer x;
    input integer y;
    integer value;
begin
    value = y * 100 + x;
    pixel_value = value[PIXEL_W-1:0];
end
endfunction

// 生成一个输入 segment。data_in 为 160bit，一次携带 16 个 10bit 像素；
// lane0 对应 x_base，lane15 对应 x_base + 15。
function [159:0] make_segment;
    input integer y;
    input integer x_base;
    integer lane;
begin
    make_segment = 160'd0;
    for (lane = 0; lane < 16; lane = lane + 1) begin
        make_segment[lane*PIXEL_W +: PIXEL_W] = pixel_value(x_base + lane, y);
    end
end
endfunction

// 检查 scanner 送入 core 的 8x8 window 是否正确。
// 根据 center 坐标和 tap_offset 算出 64 个期望源图坐标，再和 pixels 逐点比较。
task check_window_pixels;
    input [WIN_PIX_NUM*PIXEL_W-1:0] pixels;
    input integer center_x_i;
    input integer center_y_i;
    integer x_idx;
    integer y_idx;
    integer win_idx;
    integer exp_x;
    integer exp_y;
    reg [PIXEL_W-1:0] got_pixel;
    reg [PIXEL_W-1:0] exp_pixel;
begin
    for (y_idx = 0; y_idx < LANCZOS_TAPS; y_idx = y_idx + 1) begin
        for (x_idx = 0; x_idx < LANCZOS_TAPS; x_idx = x_idx + 1) begin
            win_idx = y_idx * LANCZOS_TAPS + x_idx;
            exp_x = clip_coord(center_x_i + tap_offset(x_idx), 63);
            exp_y = clip_coord(center_y_i + tap_offset(y_idx), 63);
            got_pixel = pixels[win_idx*PIXEL_W +: PIXEL_W];
            exp_pixel = pixel_value(exp_x, exp_y);

            if (got_pixel !== exp_pixel) begin
                $display("[%0t] ERROR: window mismatch idx=%0d center=(%0d,%0d) coord=(%0d,%0d) got=%0d exp=%0d",
                         $time, win_idx, center_x_i, center_y_i, exp_x, exp_y, got_pixel, exp_pixel);
                error_count = error_count + 1;
            end
        end
    end
end
endtask

// 检查 scanner 和 Lanczos core 之间的一次有效握手。
// 主要验证 dst 不越界不重复、phase 计算正确、ctrl 透传正确，
// 并调用 check_window_pixels 检查 64-tap window 内容。
task check_scanner_to_core_accept;
    integer src_x_q9;
    integer src_y_q9;
    integer exp_center_x;
    integer exp_center_y;
    integer exp_phase_x;
    integer exp_phase_y;
    integer dst_x_int;
    integer dst_y_int;
begin
    dst_x_int = {19'd0, scan_lanczos_dst_x};
    dst_y_int = {19'd0, scan_lanczos_dst_y};

    if ((scan_lanczos_dst_x >= dst_width) || (scan_lanczos_dst_y >= dst_height)) begin
        $display("[%0t] ERROR: scanner dst out of range dst=(%0d,%0d)",
                 $time, scan_lanczos_dst_x, scan_lanczos_dst_y);
        error_count = error_count + 1;
    end else begin
        seen_idx = (dst_y_int * 32) + dst_x_int;
        if (seen_dst[seen_idx]) begin
            $display("[%0t] ERROR: duplicate scanner dst output dst=(%0d,%0d)",
                     $time, scan_lanczos_dst_x, scan_lanczos_dst_y);
            error_count = error_count + 1;
        end
        seen_dst[seen_idx] = 1'b1;
    end

    src_x_q9 = scale_q8 * ((scan_lanczos_dst_x * 2) + 1) - 256;
    src_y_q9 = scale_q8 * ((scan_lanczos_dst_y * 2) + 1) - 256;
    exp_center_x = src_x_q9 >> 9;
    exp_center_y = src_y_q9 >> 9;
    exp_phase_x = src_x_q9 % 512;
    exp_phase_y = src_y_q9 % 512;

    if (scan_lanczos_phase_x_q9 !== exp_phase_x[8:0]) begin
        $display("[%0t] ERROR: scanner phase_x mismatch dst=(%0d,%0d) got=%0d exp=%0d",
                 $time, scan_lanczos_dst_x, scan_lanczos_dst_y,
                 scan_lanczos_phase_x_q9, exp_phase_x);
        error_count = error_count + 1;
    end

    if (scan_lanczos_phase_y_q9 !== exp_phase_y[8:0]) begin
        $display("[%0t] ERROR: scanner phase_y mismatch dst=(%0d,%0d) got=%0d exp=%0d",
                 $time, scan_lanczos_dst_x, scan_lanczos_dst_y,
                 scan_lanczos_phase_y_q9, exp_phase_y);
        error_count = error_count + 1;
    end

    if (scan_lanczos_ctrl[53:0] !== current_block_ctrl) begin
        $display("[%0t] ERROR: scanner ctrl mismatch got=0x%014h exp=0x%014h",
                 $time, scan_lanczos_ctrl[53:0], current_block_ctrl);
        error_count = error_count + 1;
    end

    check_window_pixels(scan_lanczos_window_pixels, exp_center_x, exp_center_y);
    scanner_accept_count = scanner_accept_count + 1;

    if ((scanner_accept_count <= 16) || scan_lanczos_block_row_last) begin
        $display("[%0t] SCAN2CORE count=%0d dst=(%0d,%0d) center=(%0d,%0d) phase=(%0d,%0d) row_last=%0d",
                 $time, scanner_accept_count,
                 scan_lanczos_dst_x, scan_lanczos_dst_y,
                 exp_center_x, exp_center_y,
                 scan_lanczos_phase_x_q9, scan_lanczos_phase_y_q9,
                 scan_lanczos_block_row_last);
    end
end
endtask

// 检查 Lanczos core 的输出。
// 当前 tb 不做卷积数值 golden 对比，只检查 ctrl 透传、高位清零、
// 输出像素不是 X，并统计 core 输出数量。
task check_core_output;
begin
    if (downscale_ctrl[53:0] !== current_block_ctrl) begin
        $display("[%0t] ERROR: core ctrl mismatch got=0x%014h exp=0x%014h pixel=%0d",
                 $time, downscale_ctrl[53:0], current_block_ctrl, downscale_pixel_out);
        error_count = error_count + 1;
    end

    if (downscale_ctrl[63:54] !== 10'd0) begin
        $display("[%0t] ERROR: core ctrl high bits mismatch got=0x%03h exp=0",
                 $time, downscale_ctrl[63:54]);
        error_count = error_count + 1;
    end

    if (^downscale_pixel_out === 1'bx) begin
        $display("[%0t] ERROR: core output pixel is X", $time);
        error_count = error_count + 1;
    end

    core_output_count = core_output_count + 1;
    if ((core_output_count <= 16) || (core_output_count == 1024)) begin
        $display("[%0t] CORE_OUT count=%0d pixel=%0d ctrl=0x%016h",
                 $time, core_output_count, downscale_pixel_out, downscale_ctrl);
    end
end
endtask

// 复位并初始化 tb/DUT 输入。
// 设置 64x64 源图、32x32 目标图、scale_q8=512(scale=2)，
// 清空计数器、错误数和 dst 覆盖记录。
task reset_dut;
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
    error_count = 0;
    scanner_accept_count = 0;
    core_output_count = 0;
    buffer_window_count = 0;
    send_count = 0;
    seen_dst = 1024'd0;
    block_scan_done_seen = 1'b0;
    current_block_ctrl = 54'd0;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
end
endtask

// 配置一个 32x32 block 的控制信息，同时送给 buffer 和 scanner。
// start_x/start_y 指源图 block 起点，frame_* 标记当前 block 是否贴着整帧边界。
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

// 向 buffer 发送一段 16 像素数据。
// data_vld 保持到 data_rdy 拉高，握手成功后 send_count 加 1；
// 如果等待过久则报 data_rdy timeout。
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

// 等待 block buffer 内部所有子状态机回到 idle。
// 这是白盒检查，用于确认 line/right/bottom/corner/window/writeback 流程已经收尾。
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

// 等待 Lanczos core 消化完 scanner 已经交给它的所有 window。
// 即 core_output_count 追上 scanner_accept_count，避免下一个阶段提前结束。
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

// 等待当前 block 扫描完成，并等待 buffer/core 都排空。
// scan_block_done 由 always 块锁存到 block_scan_done_seen，避免错过单拍 done。
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

// 跑完一个完整 32x32 block。
// 先配置 block，然后每行发送两个 16-pixel segment，共 64 个 segment，
// 最后等待 scanner、buffer 和 core 都完成当前 block。
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

always @(posedge clk) begin
    if (!rst_n) begin
        block_scan_done_seen <= 1'b0;
    end else if (scan_block_done) begin
        block_scan_done_seen <= 1'b1;
    end
end

always @(posedge clk) begin
    if (rst_n && scan_window_valid) begin
        buffer_window_count = buffer_window_count + 1;
    end
end

always @(posedge clk) begin
    if (rst_n && scan_lanczos_valid && core_scan_ready) begin
        check_scanner_to_core_accept();
    end
end

always @(posedge clk) begin
    if (rst_n && downscale_pixels_valid && downscale_pixels_ready) begin
        check_core_output();
    end
end

initial begin
`ifndef VERILATOR
    if ($test$plusargs("DUMP_VPD")) begin
        $display("[%0t] INFO: enable VPD waveform dump: tb_downscale_scan_buffer_core.vpd", $time);
        $vcdplusfile("tb_downscale_scan_buffer_core.vpd");
        $vcdplusmemon;
        $vcdpluson;
    end
`endif

    if ($test$plusargs("DUMP_VCD")) begin
        $display("[%0t] INFO: enable VCD waveform dump: tb_downscale_scan_buffer_core.vcd", $time);
        $dumpfile("tb_downscale_scan_buffer_core.vcd");
        $dumpvars(0);
    end
end

initial begin
    reset_dut();

    $display("[%0t] CASE0: top-left block", $time);
    run_full_block(0, 0, 1, 0, 1, 0);

    $display("[%0t] CASE1: top-right block, right halo path", $time);
    run_full_block(32, 0, 1, 0, 0, 1);

    $display("[%0t] CASE2: bottom-left block, bottom halo path", $time);
    run_full_block(0, 32, 0, 1, 1, 0);

    $display("[%0t] CASE3: bottom-right block, corner/bottom/right mixed path", $time);
    run_full_block(32, 32, 0, 1, 0, 1);

    wait_core_drain();

    repeat (20) @(posedge clk);

    if (scanner_accept_count !== 1024) begin
        $display("[%0t] ERROR: scanner_accept_count mismatch, got=%0d exp=1024",
                 $time, scanner_accept_count);
        error_count = error_count + 1;
    end

    if (core_output_count !== 1024) begin
        $display("[%0t] ERROR: core_output_count mismatch, got=%0d exp=1024",
                 $time, core_output_count);
        error_count = error_count + 1;
    end

    if (seen_dst !== {1024{1'b1}}) begin
        $display("[%0t] ERROR: not all dst points were accepted by core", $time);
        error_count = error_count + 1;
    end

    $display("[%0t] SUMMARY: input_segments=%0d buffer_windows=%0d scanner_to_core=%0d core_outputs=%0d errors=%0d",
             $time, send_count, buffer_window_count, scanner_accept_count,
             core_output_count, error_count);

    if (error_count == 0) begin
        $display("PASS: tb_downscale_scan_buffer_core completed with no errors");
    end else begin
        $display("FAIL: tb_downscale_scan_buffer_core completed with %0d errors", error_count);
    end

    $finish;
end

endmodule
