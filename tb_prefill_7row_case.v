module tb_prefill_7row_case;

localparam PIXEL_W          = 10;
localparam LANCZOS_TAPS     = 8;
localparam WIN_PIX_NUM      = 64;
localparam TAP_COORD_W      = 13;
localparam BUF_TAP_COORD_W  = 14;
localparam DST_W            = 13;
localparam CLK_PERIOD       = 10;

reg clk;
reg rst_n;

reg [53:0] fg2pp_ctrl;
reg [12:0] sw_pic_height;
reg [12:0] sw_upscale_pic_width;
reg        ctrl_vld;
wire       ctrl_rdy;
reg        data_vld;
reg [159:0] data_in;
wire       data_rdy;

reg [11:0] scale_q8;
reg [DST_W-1:0] dst_width;
reg [DST_W-1:0] dst_height;

wire        scan_block_ctrl_valid;
wire        scan_block_ctrl_ready;
wire [12:0] scan_block_start_x;
wire [12:0] scan_block_start_y;
wire [7:0]  scan_block_width;
wire [6:0]  scan_block_height;
wire        scan_frame_left;
wire        scan_frame_right;
wire        scan_frame_top;
wire        scan_frame_bottom;

wire        center_req_valid;
wire signed [TAP_COORD_W-1:0] center_x;
wire signed [TAP_COORD_W-1:0] center_y;
wire signed [BUF_TAP_COORD_W-1:0] buffer_center_x;
wire signed [BUF_TAP_COORD_W-1:0] buffer_center_y;

wire [WIN_PIX_NUM*PIXEL_W-1:0] scan_window_pixels;
wire                           scan_window_valid;

wire        lanczos_valid;
reg         lanczos_ready;
wire [DST_W-1:0] lanczos_dst_x;
wire [DST_W-1:0] lanczos_dst_y;
wire [8:0] lanczos_phase_x_q9;
wire [8:0] lanczos_phase_y_q9;
wire [WIN_PIX_NUM*PIXEL_W-1:0] lanczos_window_pixels;
wire        lanczos_block_row_last;
wire        lanczos_bypass_en;
wire        scan_block_done;

integer error_count;
integer output_count;
integer buffer_window_count;
integer send_count;
integer timeout_cnt;
integer seen_idx;
integer max_dst_y_seen;
reg [1023:0] seen_dst;

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
    .scan_block_ctrl_valid_o(scan_block_ctrl_valid),
    .scan_block_ctrl_ready_i(scan_block_ctrl_ready),
    .scan_block_start_x_o(scan_block_start_x),
    .scan_block_start_y_o(scan_block_start_y),
    .scan_block_width_o(scan_block_width),
    .scan_block_height_o(scan_block_height),
    .scan_frame_left_o(scan_frame_left),
    .scan_frame_right_o(scan_frame_right),
    .scan_frame_top_o(scan_frame_top),
    .scan_frame_bottom_o(scan_frame_bottom),
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
    .WIN_PIX_NUM(WIN_PIX_NUM)
) u_scan (
    .clk(clk),
    .rst_n(rst_n),
    .scale_q8(scale_q8),
    .dst_width(dst_width),
    .dst_height(dst_height),
    .buf_block_valid_i(scan_block_ctrl_valid),
    .buf_block_ready_o(scan_block_ctrl_ready),
    .buf_block_start_x_i(scan_block_start_x),
    .buf_block_start_y_i(scan_block_start_y),
    .buf_block_width_i(scan_block_width),
    .buf_block_height_i(scan_block_height),
    .buf_frame_left_i(scan_frame_left),
    .buf_frame_right_i(scan_frame_right),
    .buf_frame_top_i(scan_frame_top),
    .buf_frame_bottom_i(scan_frame_bottom),
    .req_buf_data_valid_o(center_req_valid),
    .buf_center_x_o(center_x),
    .buf_center_y_o(center_y),
    .buf_window_valid_i(scan_window_valid),
    .buf_window_pixels_i(scan_window_pixels),
    .lanczos_valid_o(lanczos_valid),
    .lanczos_ready_i(lanczos_ready),
    .lanczos_dst_x_o(lanczos_dst_x),
    .lanczos_dst_y_o(lanczos_dst_y),
    .lanczos_phase_x_q9_o(lanczos_phase_x_q9),
    .lanczos_phase_y_q9_o(lanczos_phase_y_q9),
    .lanczos_window_pixels_o(lanczos_window_pixels),
    .lanczos_block_row_last_o(lanczos_block_row_last),
    .lanczos_bypass_en_o(lanczos_bypass_en),
    .buf_block_scan_done_o(scan_block_done)
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

function [PIXEL_W-1:0] pixel_value;
    input integer x;
    input integer y;
    integer value;
begin
    value = y * 100 + x;
    pixel_value = value[PIXEL_W-1:0];
end
endfunction

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
                $display("[%0t] ERROR: win_idx %0d mismatch center=(%0d,%0d) coord=(%0d,%0d) got=%0d exp=%0d",
                         $time, win_idx, center_x_i, center_y_i, exp_x, exp_y, got_pixel, exp_pixel);
                error_count = error_count + 1;
            end
        end
    end
end
endtask

task dump_window_pixels;
    input [WIN_PIX_NUM*PIXEL_W-1:0] pixels;
    input integer center_x_i;
    input integer center_y_i;
    integer x_idx;
    integer y_idx;
    integer win_idx;
    reg [PIXEL_W-1:0] dump_pixel;
begin
    $display("[%0t] WINDOW_DUMP dst=(%0d,%0d) center=(%0d,%0d) phase=(%0d,%0d)",
             $time, lanczos_dst_x, lanczos_dst_y,
             center_x_i, center_y_i,
             lanczos_phase_x_q9, lanczos_phase_y_q9);

    for (y_idx = 0; y_idx < LANCZOS_TAPS; y_idx = y_idx + 1) begin
        $write("  row%0d:", y_idx);
        for (x_idx = 0; x_idx < LANCZOS_TAPS; x_idx = x_idx + 1) begin
            win_idx = y_idx * LANCZOS_TAPS + x_idx;
            dump_pixel = pixels[win_idx*PIXEL_W +: PIXEL_W];
            $write(" %0d", dump_pixel);
        end
        $write("\n");
    end
end
endtask

task check_lanczos_output;
    integer src_x_q9;
    integer src_y_q9;
    integer exp_center_x;
    integer exp_center_y;
    integer exp_phase_x;
    integer exp_phase_y;
    integer dst_x_int;
    integer dst_y_int;
begin
    dst_x_int = {19'd0, lanczos_dst_x};
    dst_y_int = {19'd0, lanczos_dst_y};
    seen_idx = (dst_y_int * 32) + dst_x_int;

    if (seen_dst[seen_idx]) begin
        $display("[%0t] ERROR: duplicate dst output dst=(%0d,%0d)", $time, lanczos_dst_x, lanczos_dst_y);
        error_count = error_count + 1;
    end
    seen_dst[seen_idx] = 1'b1;

    src_x_q9 = scale_q8 * ((lanczos_dst_x * 2) + 1) - 256;
    src_y_q9 = scale_q8 * ((lanczos_dst_y * 2) + 1) - 256;
    exp_center_x = src_x_q9 >> 9;
    exp_center_y = src_y_q9 >> 9;
    exp_phase_x = src_x_q9 % 512;
    exp_phase_y = src_y_q9 % 512;

    if (lanczos_phase_x_q9 !== exp_phase_x[8:0]) begin
        $display("[%0t] ERROR: phase_x mismatch dst=(%0d,%0d) got=%0d exp=%0d",
                 $time, lanczos_dst_x, lanczos_dst_y, lanczos_phase_x_q9, exp_phase_x);
        error_count = error_count + 1;
    end
    if (lanczos_phase_y_q9 !== exp_phase_y[8:0]) begin
        $display("[%0t] ERROR: phase_y mismatch dst=(%0d,%0d) got=%0d exp=%0d",
                 $time, lanczos_dst_x, lanczos_dst_y, lanczos_phase_y_q9, exp_phase_y);
        error_count = error_count + 1;
    end

    check_window_pixels(lanczos_window_pixels, exp_center_x, exp_center_y);
    dump_window_pixels(lanczos_window_pixels, exp_center_x, exp_center_y);

    output_count = output_count + 1;
    if (dst_y_int > max_dst_y_seen) begin
        max_dst_y_seen = dst_y_int;
    end

    $display("[%0t] PREFILL_OUT count=%0d dst=(%0d,%0d) center=(%0d,%0d) phase=(%0d,%0d) row_last=%0d",
             $time, output_count, lanczos_dst_x, lanczos_dst_y,
             exp_center_x, exp_center_y,
             lanczos_phase_x_q9, lanczos_phase_y_q9,
             lanczos_block_row_last);
end
endtask

task reset_dut;
begin
    clk = 1'b0;
    rst_n = 1'b0;
    fg2pp_ctrl = 54'd0;
    sw_pic_height = 13'd64;
    sw_upscale_pic_width = 13'd64;
    ctrl_vld = 1'b0;
    data_vld = 1'b0;
    data_in = 160'd0;
    scale_q8 = 12'd512;
    dst_width = 13'd32;
    dst_height = 13'd32;
    lanczos_ready = 1'b1;
    error_count = 0;
    output_count = 0;
    buffer_window_count = 0;
    send_count = 0;
    timeout_cnt = 0;
    max_dst_y_seen = -1;
    seen_dst = 1024'd0;

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

end
endtask

task config_top_left_block;
begin
    @(negedge clk);
    fg2pp_ctrl = 54'd0;
    fg2pp_ctrl[6:0]   = 7'd32;
    fg2pp_ctrl[14:7]  = 8'd32;
    fg2pp_ctrl[15]    = 1'b1;
    fg2pp_ctrl[16]    = 1'b0;
    fg2pp_ctrl[17]    = 1'b1;
    fg2pp_ctrl[18]    = 1'b0;
    fg2pp_ctrl[19]    = 1'b1;
    fg2pp_ctrl[20]    = 1'b0;
    fg2pp_ctrl[21]    = 1'b1;
    fg2pp_ctrl[22]    = 1'b0;
    fg2pp_ctrl[35:23] = 13'd0;
    fg2pp_ctrl[48:36] = 13'd0;

    ctrl_vld = 1'b1;
    timeout_cnt = 0;
    while (!ctrl_rdy && (timeout_cnt < 20000)) begin
        @(negedge clk);
        timeout_cnt = timeout_cnt + 1;
    end
    if (!ctrl_rdy) begin
        $display("[%0t] ERROR: timeout waiting ctrl_rdy", $time);
        error_count = error_count + 1;
    end
    @(negedge clk);
    ctrl_vld = 1'b0;

    $display("[%0t] CONFIG top-left block, scale=2x", $time);
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
        $display("[%0t] SEND_SEG row=%0d x=%0d", $time, y, x_base);
        @(negedge clk);
    end

    data_vld = 1'b0;
    data_in = 160'd0;
end
endtask

task send_full_row;
    input integer y;
begin
    send_segment(y, 0);
    send_segment(y, 16);
end
endtask

task wait_outputs_and_data_request;
    input integer exp_outputs;
    input integer exp_max_y;
    reg saw_data_pause;
begin
    saw_data_pause = 1'b0;
    timeout_cnt = 0;
    while (!((output_count >= exp_outputs) && saw_data_pause && data_rdy) &&
           (timeout_cnt < 80000)) begin
        @(posedge clk);
        timeout_cnt = timeout_cnt + 1;
        if (!data_rdy) begin
            saw_data_pause = 1'b1;
        end
    end

    if (timeout_cnt >= 80000) begin
        $display("[%0t] ERROR: timeout waiting prefill outputs/data request, outputs=%0d exp=%0d max_y=%0d data_rdy=%0d pause_seen=%0d",
                 $time, output_count, exp_outputs, max_dst_y_seen, data_rdy, saw_data_pause);
        error_count = error_count + 1;
    end

    if (output_count !== exp_outputs) begin
        $display("[%0t] ERROR: output count mismatch at checkpoint, got=%0d exp=%0d",
                 $time, output_count, exp_outputs);
        error_count = error_count + 1;
    end

    if (max_dst_y_seen !== exp_max_y) begin
        $display("[%0t] ERROR: max dst_y mismatch at checkpoint, got=%0d exp=%0d",
                 $time, max_dst_y_seen, exp_max_y);
        error_count = error_count + 1;
    end
end
endtask

always @(posedge clk) begin
    if (rst_n && scan_window_valid) begin
        buffer_window_count = buffer_window_count + 1;
    end
end

always @(posedge clk) begin
    if (rst_n && lanczos_valid) begin
        check_lanczos_output();
    end
end

initial begin
`ifndef VERILATOR
    if ($test$plusargs("DUMP_VPD")) begin
        $display("[%0t] INFO: enable VPD waveform dump: tb_prefill_7row_case.vpd", $time);
        $vcdplusfile("tb_prefill_7row_case.vpd");
        $vcdplusmemon;
        $vcdpluson;
    end
`endif

    if ($test$plusargs("DUMP_VCD")) begin
        $display("[%0t] INFO: enable VCD waveform dump: tb_prefill_7row_case.vcd", $time);
        $dumpfile("tb_prefill_7row_case.vcd");
        $dumpvars(0);
    end
end

initial begin
    integer row;

    reset_dut();
    config_top_left_block();

    $display("[%0t] CASE: feed frame_top row0~row6 only", $time);
    for (row = 0; row < 7; row = row + 1) begin
        send_full_row(row);
    end

    // scale=2 时，前 7 行足够计算 dst_y=0 和 dst_y=1：
    // dst_y=0 -> center_y=0，top clip 后需要 y=0~4；
    // dst_y=1 -> center_y=2，top clip 后需要 y=0~6。
    // 每个输出行在 32 宽非 frame_right block 内可算 dst_x=0~13，共 14 点。
    wait_outputs_and_data_request(28, 1);

    $display("[%0t] CHECKPOINT: prefill produced dst_y=0/1, buffer requests more input", $time);

    // 第 8 行，按 0-based 是 row7。此时 buffer 应该已经重新拉高 data_rdy 接收新数据。
    $display("[%0t] CASE: feed row7, data_rdy should accept it after prefill is exhausted", $time);
    send_full_row(7);

    // 对 scale=2，下一行 dst_y=2 的 center_y=4，需要 y=1~8，所以 row7 仍不够。
    // 这里等待一小段时间，确认 row7 被接收后不会错误地产生 dst_y=2。
    repeat (40) @(posedge clk);
    if (output_count !== 28) begin
        $display("[%0t] ERROR: row7 alone should not produce next output row, output_count=%0d exp=28",
                 $time, output_count);
        error_count = error_count + 1;
    end

    $display("[%0t] CASE: feed row8, now dst_y=2 should become computable", $time);
    send_full_row(8);
    wait_outputs_and_data_request(42, 2);

    $display("[%0t] SUMMARY: input_segments=%0d buffer_windows=%0d scanner_outputs=%0d errors=%0d",
             $time, send_count, buffer_window_count, output_count, error_count);

    if (error_count == 0) begin
        $display("PASS: tb_prefill_7row_case completed with no errors");
    end else begin
        $display("FAIL: tb_prefill_7row_case completed with %0d errors", error_count);
    end

    $finish;
end

endmodule
