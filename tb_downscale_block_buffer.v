module tb_downscale_block_buffer;

localparam PIXEL_W = 10;
localparam LANCZOS_TAPS = 8;
localparam TAP_COORD_W = 14;
localparam WIN_PIX_NUM = LANCZOS_TAPS * LANCZOS_TAPS;
localparam CLK_PERIOD = 10;

reg clk;
reg rst_n;

reg [53:0] fg2pp_ctrl;
reg [12:0] sw_pic_height;
reg [12:0] sw_upscale_pic_width;
reg        ctrl_update_en;

reg         buf_clr;
reg         data_vld;
wire        data_rdy;
reg [159:0] data_in;

reg block_lanczos_done;
reg block_lanczos_row_last;

wire       lanczos_start;
wire [7:0] lanczos_x_end;
wire [6:0] lanczos_y_end;
wire [12:0] block_start_x_o;
wire [12:0] block_start_y_o;

reg  signed [TAP_COORD_W-1:0] lanczos_center_x;
reg  signed [TAP_COORD_W-1:0] lanczos_center_y;
reg                           lanczos_window_req;
wire                          lanczos_window_busy;
wire [WIN_PIX_NUM*PIXEL_W-1:0] lanczos_window_pixels;
wire [WIN_PIX_NUM-1:0]         lanczos_window_valid_mask;
wire                           lanczos_window_valid;
wire [WIN_PIX_NUM-1:0]         lanczos_window_from_right_mask;

integer error_count;
integer i;
integer row_i;

pp_downscale_block_buffer dut (
    .clk(clk),
    .rst_n(rst_n),

    .fg2pp_ctrl(fg2pp_ctrl),
    .sw_pic_height(sw_pic_height),
    .sw_upscale_pic_width(sw_upscale_pic_width),
    .ctrl_update_en(ctrl_update_en),

    .buf_clr(buf_clr),
    .data_vld(data_vld),
    .data_rdy(data_rdy),
    .data_in(data_in),

    .block_lanczos_done(block_lanczos_done),
    .block_lanczos_row_last(block_lanczos_row_last),

    .lanczos_start(lanczos_start),
    .lanczos_x_end(lanczos_x_end),
    .lanczos_y_end(lanczos_y_end),
    .block_start_x_o(block_start_x_o),
    .block_start_y_o(block_start_y_o),

    .lanczos_center_x(lanczos_center_x),
    .lanczos_center_y(lanczos_center_y),
    .lanczos_window_req(lanczos_window_req),
    .lanczos_window_busy(lanczos_window_busy),
    .lanczos_window_pixels(lanczos_window_pixels),
    .lanczos_window_valid_mask(lanczos_window_valid_mask),
    .lanczos_window_valid(lanczos_window_valid),
    .lanczos_window_from_right_mask(lanczos_window_from_right_mask)
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

task send_segment;
    input integer y;
    input integer x_base;
begin
    @(negedge clk);
    data_in  = make_segment(y, x_base);
    data_vld = 1'b1;

    while (!data_rdy) begin
        @(negedge clk);
    end

    @(negedge clk);
    data_vld = 1'b0;
    data_in  = 160'd0;
end
endtask

task config_block_edges;
    input integer start_x;
    input integer start_y;
    input integer frame_top;
    input integer frame_bottom;
    input integer frame_left;
    input integer frame_right;
begin
    @(negedge clk);
    fg2pp_ctrl = 54'd0;
    fg2pp_ctrl[6:0]   = 7'd32;
    fg2pp_ctrl[14:7]  = 8'd32;
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

    ctrl_update_en = 1'b1;
    @(negedge clk);
    ctrl_update_en = 1'b0;

    buf_clr = 1'b1;
    @(negedge clk);
    buf_clr = 1'b0;
end
endtask

task config_block;
    input integer start_x;
    input integer start_y;
    input integer frame_left;
    input integer frame_right;
begin
    config_block_edges(start_x, start_y, 1, 0, frame_left, frame_right);
end
endtask

task finish_segment;
    input integer wait_for_recv;
begin
    @(negedge clk);
    block_lanczos_done = 1'b1;
    @(negedge clk);
    block_lanczos_done = 1'b0;

    if (wait_for_recv != 0) begin
        while (!data_rdy) begin
            @(negedge clk);
        end
    end else begin
        repeat (120) @(posedge clk);
    end
end
endtask

task run_full_block;
    input integer start_x;
    input integer start_y;
    input integer frame_top;
    input integer frame_bottom;
    input integer frame_left;
    input integer frame_right;
    integer blk_row;
begin
    config_block_edges(start_x, start_y, frame_top, frame_bottom, frame_left, frame_right);

    for (blk_row = 0; blk_row < 32; blk_row = blk_row + 1) begin
        send_segment(start_y + blk_row, start_x);
        if (!((frame_top != 0) && (blk_row < 7))) begin
            wait (lanczos_start == 1'b1);
            finish_segment(1);
        end

        send_segment(start_y + blk_row, start_x + 16);
        if (!((frame_top != 0) && (blk_row < 7))) begin
            wait (lanczos_start == 1'b1);
            if (blk_row == 31) begin
                finish_segment(0);
            end else begin
                finish_segment(1);
            end
        end
    end
end
endtask

task request_window;
    input integer center_x;
    input integer center_y;
    integer timeout_cnt;
    integer wait_cycles;
    time req_time;
    time valid_time;
    reg got_valid;
begin
    @(negedge clk);
    lanczos_center_x = center_x[TAP_COORD_W-1:0];
    lanczos_center_y = center_y[TAP_COORD_W-1:0];
    lanczos_window_req = 1'b1;
    req_time = $time;

    @(negedge clk);
    lanczos_window_req = 1'b0;

    got_valid = 1'b0;
    wait_cycles = 0;
    valid_time = 0;
    for (timeout_cnt = 0; timeout_cnt < 300; timeout_cnt = timeout_cnt + 1) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
        if (lanczos_window_valid) begin
            got_valid = 1'b1;
            valid_time = $time;
            timeout_cnt = 300;
        end
    end

    if (!got_valid) begin
        $display("[%0t] ERROR: window read timeout, center=(%0d,%0d)", $time, center_x, center_y);
        error_count = error_count + 1;
    end else begin
        $display("[%0t] WINDOW_LATENCY center=(%0d,%0d) cycles=%0d time=%0t",
                 $time, center_x, center_y, wait_cycles, valid_time - req_time);
    end
end
endtask

task dump_window;
    input integer center_x;
    input integer center_y;
    integer x_idx;
    integer y_idx;
    integer win_idx;
    reg [PIXEL_W-1:0] got_pixel;
begin
    $display("[%0t] WINDOW_DUMP center=(%0d,%0d)", $time, center_x, center_y);
    for (y_idx = 0; y_idx < LANCZOS_TAPS; y_idx = y_idx + 1) begin
        $write("  row%0d:", y_idx);
        for (x_idx = 0; x_idx < LANCZOS_TAPS; x_idx = x_idx + 1) begin
            win_idx = y_idx * LANCZOS_TAPS + x_idx;
            got_pixel = lanczos_window_pixels[win_idx*PIXEL_W +: PIXEL_W];
            $write(" %0d", got_pixel);
        end
        $write("\n");
    end
    $display("  valid_mask      = 0x%016h", lanczos_window_valid_mask);
    $display("  from_right_mask = 0x%016h", lanczos_window_from_right_mask);
end
endtask

task check_window;
    input integer center_x;
    input integer center_y;
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

            exp_x = center_x + tap_offset(x_idx);
            exp_y = center_y + tap_offset(y_idx);

            if (exp_x < 0) begin
                exp_x = 0;
            end
            if (exp_y < 0) begin
                exp_y = 0;
            end

            got_pixel = lanczos_window_pixels[win_idx*PIXEL_W +: PIXEL_W];
            exp_pixel = pixel_value(exp_x, exp_y);

            if (!lanczos_window_valid_mask[win_idx]) begin
                $display("[%0t] ERROR: win_idx %0d invalid, center=(%0d,%0d), expected coord=(%0d,%0d)",
                         $time, win_idx, center_x, center_y, exp_x, exp_y);
                error_count = error_count + 1;
            end

            if (lanczos_window_from_right_mask[win_idx]) begin
                $display("[%0t] ERROR: win_idx %0d should not come from right_buffer in frame-left case",
                         $time, win_idx);
                error_count = error_count + 1;
            end

            if (got_pixel !== exp_pixel) begin
                $display("[%0t] ERROR: win_idx %0d pixel mismatch, got=%0d expected=%0d coord=(%0d,%0d)",
                         $time, win_idx, got_pixel, exp_pixel, exp_x, exp_y);
                error_count = error_count + 1;
            end
        end
    end
end
endtask

task check_window_right_case;
    input integer center_x;
    input integer center_y;
    integer x_idx;
    integer y_idx;
    integer win_idx;
    integer exp_x;
    integer exp_y;
    reg [PIXEL_W-1:0] got_pixel;
    reg [PIXEL_W-1:0] exp_pixel;
    reg exp_from_right;
begin
    for (y_idx = 0; y_idx < LANCZOS_TAPS; y_idx = y_idx + 1) begin
        for (x_idx = 0; x_idx < LANCZOS_TAPS; x_idx = x_idx + 1) begin
            win_idx = y_idx * LANCZOS_TAPS + x_idx;
            exp_x = center_x + tap_offset(x_idx);
            exp_y = center_y + tap_offset(y_idx);
            exp_from_right = (x_idx < 3);

            got_pixel = lanczos_window_pixels[win_idx*PIXEL_W +: PIXEL_W];
            exp_pixel = pixel_value(exp_x, exp_y);

            if (!lanczos_window_valid_mask[win_idx]) begin
                $display("[%0t] ERROR: right case win_idx %0d invalid, expected coord=(%0d,%0d)",
                         $time, win_idx, exp_x, exp_y);
                error_count = error_count + 1;
            end

            if (lanczos_window_from_right_mask[win_idx] !== exp_from_right) begin
                $display("[%0t] ERROR: right case win_idx %0d from_right mismatch, got=%0d expected=%0d coord=(%0d,%0d)",
                         $time, win_idx, lanczos_window_from_right_mask[win_idx], exp_from_right, exp_x, exp_y);
                error_count = error_count + 1;
            end

            if (got_pixel !== exp_pixel) begin
                $display("[%0t] ERROR: right case win_idx %0d pixel mismatch, got=%0d expected=%0d coord=(%0d,%0d)",
                         $time, win_idx, got_pixel, exp_pixel, exp_x, exp_y);
                error_count = error_count + 1;
            end
        end
    end

    if (lanczos_window_valid_mask !== 64'hffff_ffff_ffff_ffff) begin
        $display("[%0t] ERROR: right case valid_mask mismatch, got=0x%016h",
                 $time, lanczos_window_valid_mask);
        error_count = error_count + 1;
    end

    if (lanczos_window_from_right_mask !== 64'h0707_0707_0707_0707) begin
        $display("[%0t] ERROR: right case from_right_mask mismatch, got=0x%016h expected=0x0707070707070707",
                 $time, lanczos_window_from_right_mask);
        error_count = error_count + 1;
    end
end
endtask

task check_window_bottom_case;
    input integer center_x;
    input integer center_y;
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
            exp_x = center_x + tap_offset(x_idx);
            exp_y = center_y + tap_offset(y_idx);

            got_pixel = lanczos_window_pixels[win_idx*PIXEL_W +: PIXEL_W];
            exp_pixel = pixel_value(exp_x, exp_y);

            if (!lanczos_window_valid_mask[win_idx]) begin
                $display("[%0t] ERROR: bottom case win_idx %0d invalid, expected coord=(%0d,%0d)",
                         $time, win_idx, exp_x, exp_y);
                error_count = error_count + 1;
            end

            if (lanczos_window_from_right_mask[win_idx]) begin
                $display("[%0t] ERROR: bottom case win_idx %0d should not come from right_buffer, coord=(%0d,%0d)",
                         $time, win_idx, exp_x, exp_y);
                error_count = error_count + 1;
            end

            if (got_pixel !== exp_pixel) begin
                $display("[%0t] ERROR: bottom case win_idx %0d pixel mismatch, got=%0d expected=%0d coord=(%0d,%0d)",
                         $time, win_idx, got_pixel, exp_pixel, exp_x, exp_y);
                error_count = error_count + 1;
            end
        end
    end

    if (lanczos_window_valid_mask !== 64'hffff_ffff_ffff_ffff) begin
        $display("[%0t] ERROR: bottom case valid_mask mismatch, got=0x%016h",
                 $time, lanczos_window_valid_mask);
        error_count = error_count + 1;
    end

    if (lanczos_window_from_right_mask !== 64'h0000_0000_0000_0000) begin
        $display("[%0t] ERROR: bottom case from_right_mask mismatch, got=0x%016h expected=0x0000000000000000",
                 $time, lanczos_window_from_right_mask);
        error_count = error_count + 1;
    end
end
endtask

task check_window_corner_case;
    input integer center_x;
    input integer center_y;
    integer x_idx;
    integer y_idx;
    integer win_idx;
    integer exp_x;
    integer exp_y;
    reg [PIXEL_W-1:0] got_pixel;
    reg [PIXEL_W-1:0] exp_pixel;
    reg exp_from_right;
begin
    for (y_idx = 0; y_idx < LANCZOS_TAPS; y_idx = y_idx + 1) begin
        for (x_idx = 0; x_idx < LANCZOS_TAPS; x_idx = x_idx + 1) begin
            win_idx = y_idx * LANCZOS_TAPS + x_idx;
            exp_x = center_x + tap_offset(x_idx);
            exp_y = center_y + tap_offset(y_idx);
            exp_from_right = ((exp_y >= 32) && (exp_x < 32));

            got_pixel = lanczos_window_pixels[win_idx*PIXEL_W +: PIXEL_W];
            exp_pixel = pixel_value(exp_x, exp_y);

            if (!lanczos_window_valid_mask[win_idx]) begin
                $display("[%0t] ERROR: corner case win_idx %0d invalid, expected coord=(%0d,%0d)",
                         $time, win_idx, exp_x, exp_y);
                error_count = error_count + 1;
            end

            if (lanczos_window_from_right_mask[win_idx] !== exp_from_right) begin
                $display("[%0t] ERROR: corner case win_idx %0d from_right mismatch, got=%0d expected=%0d coord=(%0d,%0d)",
                         $time, win_idx, lanczos_window_from_right_mask[win_idx], exp_from_right, exp_x, exp_y);
                error_count = error_count + 1;
            end

            if (got_pixel !== exp_pixel) begin
                $display("[%0t] ERROR: corner case win_idx %0d pixel mismatch, got=%0d expected=%0d coord=(%0d,%0d)",
                         $time, win_idx, got_pixel, exp_pixel, exp_x, exp_y);
                error_count = error_count + 1;
            end
        end
    end

    if (lanczos_window_valid_mask !== 64'hffff_ffff_ffff_ffff) begin
        $display("[%0t] ERROR: corner case valid_mask mismatch, got=0x%016h",
                 $time, lanczos_window_valid_mask);
        error_count = error_count + 1;
    end

    if (lanczos_window_from_right_mask !== 64'h0700_0000_0000_0000) begin
        $display("[%0t] ERROR: corner case from_right_mask mismatch, got=0x%016h expected=0x0700000000000000",
                 $time, lanczos_window_from_right_mask);
        error_count = error_count + 1;
    end
end
endtask

initial begin
    clk = 1'b0;
    rst_n = 1'b0;

    fg2pp_ctrl = 54'd0;
    sw_pic_height = 13'd128;
    sw_upscale_pic_width = 13'd128;
    ctrl_update_en = 1'b0;

    buf_clr = 1'b0;
    data_vld = 1'b0;
    data_in = 160'd0;

    block_lanczos_done = 1'b0;
    block_lanczos_row_last = 1'b0;

    lanczos_center_x = 14'sd0;
    lanczos_center_y = 14'sd0;
    lanczos_window_req = 1'b0;

    error_count = 0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("[%0t] CASE: block0 frame-top/frame-left baseline", $time);
    config_block(0, 0, 1, 0);

    for (i = 0; i < 7; i = i + 1) begin
        send_segment(i, 0);
        send_segment(i, 16);
    end

    send_segment(7, 0);
    wait (lanczos_start == 1'b1);
    $display("[%0t] INFO: lanczos_start detected, x_end=%0d y_end=%0d",
             $time, lanczos_x_end, lanczos_y_end);

    request_window(5, 3);
    dump_window(5, 3);
    check_window(5, 3);

    request_window(1, 1);
    dump_window(1, 1);
    check_window(1, 1);

    finish_segment(1);

    send_segment(7, 16);
    wait (lanczos_start == 1'b1);
    $display("[%0t] INFO: lanczos_start detected for second segment, x_end=%0d y_end=%0d",
             $time, lanczos_x_end, lanczos_y_end);

    request_window(16, 3);
    dump_window(16, 3);
    check_window(16, 3);

    finish_segment(1);

    for (row_i = 8; row_i < 32; row_i = row_i + 1) begin
        send_segment(row_i, 0);
        wait (lanczos_start == 1'b1);
        finish_segment(1);

        send_segment(row_i, 16);
        wait (lanczos_start == 1'b1);
        if (row_i == 31) begin
            finish_segment(0);
        end else begin
            finish_segment(1);
        end
    end

    $display("[%0t] CASE: block1 right_buffer path", $time);
    config_block(32, 0, 0, 0);

    for (i = 0; i < 7; i = i + 1) begin
        send_segment(i, 32);
        send_segment(i, 48);
    end

    send_segment(7, 32);
    wait (lanczos_start == 1'b1);
    $display("[%0t] INFO: lanczos_start detected for right_buffer case, x_end=%0d y_end=%0d",
             $time, lanczos_x_end, lanczos_y_end);

    request_window(32, 3);
    dump_window(32, 3);
    check_window_right_case(32, 3);

    finish_segment(1);

    send_segment(7, 48);
    wait (lanczos_start == 1'b1);
    finish_segment(1);

    for (row_i = 8; row_i < 32; row_i = row_i + 1) begin
        send_segment(row_i, 32);
        wait (lanczos_start == 1'b1);
        finish_segment(1);

        send_segment(row_i, 48);
        wait (lanczos_start == 1'b1);
        if (row_i == 31) begin
            finish_segment(0);
        end else begin
            finish_segment(1);
        end
    end

    $display("[%0t] CASE: block2 bottom_buffer path", $time);
    config_block_edges(0, 32, 0, 0, 1, 0);

    send_segment(32, 0);
    wait (lanczos_start == 1'b1);
    $display("[%0t] INFO: lanczos_start detected for bottom_buffer case, x_end=%0d y_end=%0d",
             $time, lanczos_x_end, lanczos_y_end);

    request_window(5, 28);
    dump_window(5, 28);
    check_window_bottom_case(5, 28);

    finish_segment(1);

    send_segment(32, 16);
    wait (lanczos_start == 1'b1);
    finish_segment(1);

    for (row_i = 33; row_i < 64; row_i = row_i + 1) begin
        send_segment(row_i, 0);
        wait (lanczos_start == 1'b1);
        finish_segment(1);

        send_segment(row_i, 16);
        wait (lanczos_start == 1'b1);
        if (row_i == 63) begin
            finish_segment(0);
        end else begin
            finish_segment(1);
        end
    end

    $display("[%0t] CASE: block3 corner/bottom/right mixed path", $time);
    config_block_edges(32, 32, 0, 0, 0, 0);

    send_segment(32, 32);
    wait (lanczos_start == 1'b1);
    $display("[%0t] INFO: lanczos_start detected for corner_buffer case, x_end=%0d y_end=%0d",
             $time, lanczos_x_end, lanczos_y_end);

    request_window(32, 28);
    dump_window(32, 28);
    check_window_corner_case(32, 28);

    finish_segment(1);

    repeat (10) @(posedge clk);

    if (error_count == 0) begin
        $display("[%0t] PASS: tb_downscale_block_buffer completed with no errors", $time);
    end else begin
        $display("[%0t] FAIL: tb_downscale_block_buffer found %0d errors", $time, error_count);
    end

    $finish;
end

endmodule
