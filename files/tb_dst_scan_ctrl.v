module tb_dst_scan_ctrl;

localparam PIXEL_W = 10;
localparam LANCZOS_TAPS = 8;
localparam TAP_COORD_W = 14;
localparam DST_W = 13;
localparam WIN_PIX_NUM = LANCZOS_TAPS * LANCZOS_TAPS;
localparam CLK_PERIOD = 10;

reg clk;
reg rst_n;
reg scan_clr;

reg [11:0] scale_q8;
reg [DST_W-1:0] dst_width;
reg [DST_W-1:0] dst_height;

reg seg_start_i;
reg [12:0] block_start_x_i;
reg [12:0] block_start_y_i;
reg [7:0]  lanczos_x_end_i;
reg [6:0]  lanczos_y_end_i;
reg frame_left_i;
reg frame_right_i;
reg frame_top_i;
reg frame_bottom_i;

reg window_busy_i;
wire window_req_o;
wire signed [TAP_COORD_W-1:0] window_center_x_o;
wire signed [TAP_COORD_W-1:0] window_center_y_o;

reg window_valid_i;
reg [WIN_PIX_NUM*PIXEL_W-1:0] window_pixels_i;
reg [WIN_PIX_NUM-1:0]         window_valid_mask_i;

wire out_valid_o;
reg  out_ready_i;
wire [DST_W-1:0] out_dst_x_o;
wire [DST_W-1:0] out_dst_y_o;
wire signed [TAP_COORD_W-1:0] out_center_x_o;
wire signed [TAP_COORD_W-1:0] out_center_y_o;
wire [8:0] out_phase_x_q9_o;
wire [8:0] out_phase_y_q9_o;
wire [WIN_PIX_NUM*PIXEL_W-1:0] out_window_pixels_o;
wire [WIN_PIX_NUM-1:0]         out_window_valid_mask_o;
wire out_bypass_en_o;
wire segment_done_o;

integer error_count;
integer timeout_cnt;

pp_downscale_dst_scan_ctrl dut (
    .clk(clk),
    .rst_n(rst_n),
    .scan_clr(scan_clr),
    .scale_q8(scale_q8),
    .dst_width(dst_width),
    .dst_height(dst_height),
    .seg_start_i(seg_start_i),
    .block_start_x_i(block_start_x_i),
    .block_start_y_i(block_start_y_i),
    .lanczos_x_end_i(lanczos_x_end_i),
    .lanczos_y_end_i(lanczos_y_end_i),
    .frame_left_i(frame_left_i),
    .frame_right_i(frame_right_i),
    .frame_top_i(frame_top_i),
    .frame_bottom_i(frame_bottom_i),
    .window_busy_i(window_busy_i),
    .window_req_o(window_req_o),
    .window_center_x_o(window_center_x_o),
    .window_center_y_o(window_center_y_o),
    .window_valid_i(window_valid_i),
    .window_pixels_i(window_pixels_i),
    .window_valid_mask_i(window_valid_mask_i),
    .out_valid_o(out_valid_o),
    .out_ready_i(out_ready_i),
    .out_dst_x_o(out_dst_x_o),
    .out_dst_y_o(out_dst_y_o),
    .out_center_x_o(out_center_x_o),
    .out_center_y_o(out_center_y_o),
    .out_phase_x_q9_o(out_phase_x_q9_o),
    .out_phase_y_q9_o(out_phase_y_q9_o),
    .out_window_pixels_o(out_window_pixels_o),
    .out_window_valid_mask_o(out_window_valid_mask_o),
    .out_bypass_en_o(out_bypass_en_o),
    .segment_done_o(segment_done_o)
);

always #(CLK_PERIOD/2) clk = ~clk;

task reset_dut;
begin
    clk = 1'b0;
    rst_n = 1'b0;
    scan_clr = 1'b0;
    scale_q8 = 12'd512;
    dst_width = 13'd8;
    dst_height = 13'd8;
    seg_start_i = 1'b0;
    block_start_x_i = 13'd0;
    block_start_y_i = 13'd0;
    lanczos_x_end_i = 8'd0;
    lanczos_y_end_i = 7'd0;
    frame_left_i = 1'b0;
    frame_right_i = 1'b0;
    frame_top_i = 1'b0;
    frame_bottom_i = 1'b0;
    window_busy_i = 1'b0;
    window_valid_i = 1'b0;
    window_pixels_i = {(WIN_PIX_NUM*PIXEL_W){1'b0}};
    window_valid_mask_i = {WIN_PIX_NUM{1'b0}};
    out_ready_i = 1'b1;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
end
endtask

task clear_scan;
begin
    @(negedge clk);
    scan_clr = 1'b1;
    @(negedge clk);
    scan_clr = 1'b0;
end
endtask

task start_segment;
    input integer block_x;
    input integer block_y;
    input integer x_end;
    input integer y_end;
    input integer frame_left;
    input integer frame_right;
    input integer frame_top;
    input integer frame_bottom;
begin
    @(negedge clk);
    block_start_x_i = block_x[12:0];
    block_start_y_i = block_y[12:0];
    lanczos_x_end_i = x_end[7:0];
    lanczos_y_end_i = y_end[6:0];
    frame_left_i = frame_left[0];
    frame_right_i = frame_right[0];
    frame_top_i = frame_top[0];
    frame_bottom_i = frame_bottom[0];
    seg_start_i = 1'b1;
    @(negedge clk);
    seg_start_i = 1'b0;
end
endtask

task wait_window_req;
    input integer exp_center_x;
    input integer exp_center_y;
begin
    timeout_cnt = 0;
    while (!window_req_o && (timeout_cnt < 200)) begin
        @(posedge clk);
        timeout_cnt = timeout_cnt + 1;
    end
    if (!window_req_o) begin
        $display("[%0t] ERROR: timeout waiting window_req", $time);
        error_count = error_count + 1;
    end else begin
        if (window_center_x_o !== exp_center_x[TAP_COORD_W-1:0]) begin
            $display("[%0t] ERROR: window_center_x exp=%0d got=%0d",
                     $time, exp_center_x, window_center_x_o);
            error_count = error_count + 1;
        end
        if (window_center_y_o !== exp_center_y[TAP_COORD_W-1:0]) begin
            $display("[%0t] ERROR: window_center_y exp=%0d got=%0d",
                     $time, exp_center_y, window_center_y_o);
            error_count = error_count + 1;
        end
    end
end
endtask

task drive_window_valid;
    input integer payload_base;
begin
    @(negedge clk);
    window_pixels_i = {(WIN_PIX_NUM*PIXEL_W){1'b0}};
    window_pixels_i[0 +: PIXEL_W] = payload_base[PIXEL_W-1:0];
    window_valid_mask_i = {WIN_PIX_NUM{1'b1}};
    window_valid_i = 1'b1;
    @(negedge clk);
    window_valid_i = 1'b0;
    window_pixels_i = {(WIN_PIX_NUM*PIXEL_W){1'b0}};
    window_valid_mask_i = {WIN_PIX_NUM{1'b0}};
end
endtask

task wait_output;
    input integer exp_dst_x;
    input integer exp_dst_y;
    input integer exp_center_x;
    input integer exp_center_y;
    input integer exp_phase_x;
    input integer exp_phase_y;
    input integer exp_bypass;
    input integer exp_payload_base;
begin
    timeout_cnt = 0;
    while (!out_valid_o && (timeout_cnt < 200)) begin
        @(posedge clk);
        timeout_cnt = timeout_cnt + 1;
    end

    if (!out_valid_o) begin
        $display("[%0t] ERROR: timeout waiting out_valid", $time);
        error_count = error_count + 1;
    end else begin
        if (out_dst_x_o !== exp_dst_x[DST_W-1:0]) begin
            $display("[%0t] ERROR: out_dst_x exp=%0d got=%0d", $time, exp_dst_x, out_dst_x_o);
            error_count = error_count + 1;
        end
        if (out_dst_y_o !== exp_dst_y[DST_W-1:0]) begin
            $display("[%0t] ERROR: out_dst_y exp=%0d got=%0d", $time, exp_dst_y, out_dst_y_o);
            error_count = error_count + 1;
        end
        if (out_center_x_o !== exp_center_x[TAP_COORD_W-1:0]) begin
            $display("[%0t] ERROR: out_center_x exp=%0d got=%0d", $time, exp_center_x, out_center_x_o);
            error_count = error_count + 1;
        end
        if (out_center_y_o !== exp_center_y[TAP_COORD_W-1:0]) begin
            $display("[%0t] ERROR: out_center_y exp=%0d got=%0d", $time, exp_center_y, out_center_y_o);
            error_count = error_count + 1;
        end
        if (out_phase_x_q9_o !== exp_phase_x[8:0]) begin
            $display("[%0t] ERROR: phase_x exp=%0d got=%0d", $time, exp_phase_x, out_phase_x_q9_o);
            error_count = error_count + 1;
        end
        if (out_phase_y_q9_o !== exp_phase_y[8:0]) begin
            $display("[%0t] ERROR: phase_y exp=%0d got=%0d", $time, exp_phase_y, out_phase_y_q9_o);
            error_count = error_count + 1;
        end
        if (out_bypass_en_o !== exp_bypass[0]) begin
            $display("[%0t] ERROR: bypass exp=%0d got=%0d", $time, exp_bypass, out_bypass_en_o);
            error_count = error_count + 1;
        end
        if (out_window_pixels_o[0 +: PIXEL_W] !== exp_payload_base[PIXEL_W-1:0]) begin
            $display("[%0t] ERROR: payload exp=%0d got=%0d",
                     $time, exp_payload_base[PIXEL_W-1:0], out_window_pixels_o[0 +: PIXEL_W]);
            error_count = error_count + 1;
        end
        if (out_window_valid_mask_o !== {WIN_PIX_NUM{1'b1}}) begin
            $display("[%0t] ERROR: valid_mask exp=all1 got=0x%h", $time, out_window_valid_mask_o);
            error_count = error_count + 1;
        end
    end
end
endtask

task consume_output;
begin
    @(negedge clk);
    out_ready_i = 1'b1;
    @(negedge clk);
end
endtask

task request_and_check;
    input integer exp_dst_x;
    input integer exp_dst_y;
    input integer exp_center_x;
    input integer exp_center_y;
    input integer exp_phase_x;
    input integer exp_phase_y;
    input integer exp_bypass;
    input integer payload;
begin
    wait_window_req(exp_center_x, exp_center_y);
    drive_window_valid(payload);
    wait_output(exp_dst_x, exp_dst_y, exp_center_x, exp_center_y,
                exp_phase_x, exp_phase_y, exp_bypass, payload);
    consume_output();
end
endtask

task wait_segment_done;
begin
    timeout_cnt = 0;
    while (!segment_done_o && (timeout_cnt < 200)) begin
        @(posedge clk);
        timeout_cnt = timeout_cnt + 1;
    end
    if (!segment_done_o) begin
        $display("[%0t] ERROR: timeout waiting segment_done", $time);
        error_count = error_count + 1;
    end
end
endtask

initial begin
    error_count = 0;
    reset_dut();

    $display("[%0t] TEST1: scale=2 unlocks two rows and computes current x range", $time);
    clear_scan();
    scale_q8 = 12'd512;
    dst_width = 13'd8;
    dst_height = 13'd8;
    start_segment(0, 0, 2, 2, 1, 0, 1, 0);
    request_and_check(0, 0, 0, 0, 256, 256, 0, 100);
    request_and_check(1, 0, 2, 0, 256, 256, 0, 101);
    request_and_check(0, 1, 0, 2, 256, 256, 0, 110);
    request_and_check(1, 1, 2, 2, 256, 256, 0, 111);
    wait_segment_done();

    $display("[%0t] TEST2: next segment continues active_next_x without unlocking new y", $time);
    start_segment(0, 0, 6, 2, 0, 0, 1, 0);
    request_and_check(2, 0, 4, 0, 256, 256, 0, 120);
    request_and_check(3, 0, 6, 0, 256, 256, 0, 121);
    request_and_check(2, 1, 4, 2, 256, 256, 0, 130);
    request_and_check(3, 1, 6, 2, 256, 256, 0, 131);
    wait_segment_done();

    $display("[%0t] TEST3: scale=3 generates integer centers and bypass flag", $time);
    clear_scan();
    scale_q8 = 12'd768;
    dst_width = 13'd4;
    dst_height = 13'd4;
    start_segment(0, 0, 20, 20, 1, 0, 1, 0);
    request_and_check(0, 0, 1, 1, 0, 0, 1, 300);
    wait_segment_done();

    $display("[%0t] TEST4: out_ready backpressure keeps output stable", $time);
    clear_scan();
    scale_q8 = 12'd512;
    dst_width = 13'd4;
    dst_height = 13'd4;
    start_segment(0, 0, 0, 0, 1, 0, 1, 0);
    wait_window_req(0, 0);
    out_ready_i = 1'b0;
    drive_window_valid(400);
    wait_output(0, 0, 0, 0, 256, 256, 0, 400);
    repeat (3) begin
        @(posedge clk);
        if (!out_valid_o || (out_dst_x_o !== 13'd0) ||
            (out_window_pixels_o[0 +: PIXEL_W] !== 10'd400)) begin
            $display("[%0t] ERROR: output changed while out_ready=0", $time);
            error_count = error_count + 1;
        end
    end
    consume_output();
    wait_segment_done();

    $display("[%0t] TEST5: frame_right lets active row finish dst_width", $time);
    clear_scan();
    scale_q8 = 12'd512;
    dst_width = 13'd4;
    dst_height = 13'd2;
    start_segment(0, 0, 0, 0, 1, 1, 1, 0);
    request_and_check(0, 0, 0, 0, 256, 256, 0, 500);
    request_and_check(1, 0, 2, 0, 256, 256, 0, 501);
    request_and_check(2, 0, 4, 0, 256, 256, 0, 502);
    request_and_check(3, 0, 6, 0, 256, 256, 0, 503);
    wait_segment_done();

    if (error_count == 0) begin
        $display("[%0t] PASS: tb_dst_scan_ctrl completed with no errors", $time);
    end else begin
        $display("[%0t] FAIL: tb_dst_scan_ctrl found %0d errors", $time, error_count);
    end

    $finish;
end

endmodule
