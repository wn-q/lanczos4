`timescale 1ns/1ps

module tb_dst_scan_geometry;

localparam PIXEL_W     = 10;
localparam DST_W       = 13;
localparam TAP_COORD_W = 13;
localparam SCALE_W     = 12;
localparam SRC_Q_W     = 21;
localparam CTRL_W      = 64;
localparam WIN_PIX_NUM = 64;
localparam CLK_PERIOD  = 10;

localparam [3:0] SC_GEOM_SCAN = 4'd10;
localparam [3:0] SC_SEND_CTRL = 4'd11;

reg clk;
reg rst_n;

reg [SCALE_W-1:0] scale_q8;
reg [DST_W-1:0]   dst_width;
reg [DST_W-1:0]   dst_height;

reg        ctrl_vld_i;
wire       ctrl_rdy_o;
reg [53:0] fg2pp_ctrl_i;

wire req_buf_data_valid_o;
wire signed [TAP_COORD_W-1:0] buf_center_x_o;
wire signed [TAP_COORD_W-1:0] buf_center_y_o;

reg  buf_window_valid_i;
reg  [WIN_PIX_NUM*PIXEL_W-1:0] buf_window_pixels_i;

wire lanczos_valid_o;
reg  lanczos_ready_i;
wire [DST_W-1:0] lanczos_dst_x_o;
wire [DST_W-1:0] lanczos_dst_y_o;
wire [8:0] lanczos_phase_x_q9_o;
wire [8:0] lanczos_phase_y_q9_o;
wire [WIN_PIX_NUM*PIXEL_W-1:0] lanczos_window_pixels_o;
wire lanczos_block_row_last_o;
wire lanczos_bypass_en_o;
wire [CTRL_W-1:0] lanczos_ctrl_o;
wire buf_block_scan_done_o;

integer error_count;
integer timeout_count;
integer case_count;
integer output_count;
integer request_count;

integer expected_saved_edge_x;
integer expected_saved_edge_y;
integer expected_start_x;
integer expected_start_y;
integer expected_plan_x;
integer expected_plan_y;
integer expected_next_x;
integer expected_next_y;
integer expected_output_count;
integer expected_bypass;
integer current_scale;
reg [63:0] expected_ctrl;
reg case_output_active;

reg response_pending;
reg request_seen;

pp_downscale_dst_scan_ctrl #(
    .PIXEL_W(PIXEL_W),
    .DST_W(DST_W),
    .TAP_COORD_W(TAP_COORD_W),
    .SCALE_W(SCALE_W),
    .SRC_Q_W(SRC_Q_W),
    .WIN_PIX_NUM(WIN_PIX_NUM),
    .CTRL_W(CTRL_W)
) dut (
    .clk(clk),
    .rst_n(rst_n),
    .scale_q8(scale_q8),
    .dst_width(dst_width),
    .dst_height(dst_height),
    .ctrl_vld_i(ctrl_vld_i),
    .ctrl_rdy_o(ctrl_rdy_o),
    .fg2pp_ctrl_i(fg2pp_ctrl_i),
    .req_buf_data_valid_o(req_buf_data_valid_o),
    .buf_center_x_o(buf_center_x_o),
    .buf_center_y_o(buf_center_y_o),
    .buf_window_valid_i(buf_window_valid_i),
    .buf_window_pixels_i(buf_window_pixels_i),
    .lanczos_valid_o(lanczos_valid_o),
    .lanczos_ready_i(lanczos_ready_i),
    .lanczos_dst_x_o(lanczos_dst_x_o),
    .lanczos_dst_y_o(lanczos_dst_y_o),
    .lanczos_phase_x_q9_o(lanczos_phase_x_q9_o),
    .lanczos_phase_y_q9_o(lanczos_phase_y_q9_o),
    .lanczos_window_pixels_o(lanczos_window_pixels_o),
    .lanczos_block_row_last_o(lanczos_block_row_last_o),
    .lanczos_bypass_en_o(lanczos_bypass_en_o),
    .lanczos_ctrl_o(lanczos_ctrl_o),
    .buf_block_scan_done_o(buf_block_scan_done_o)
);

always #(CLK_PERIOD/2) clk = ~clk;

// The geometry test does not instantiate a real buffer.  Return one dummy
// 64-pixel window for every new center request so the scanner can advance.
always @(posedge clk) begin
    if (!rst_n) begin
        buf_window_valid_i  <= 1'b0;
        buf_window_pixels_i <= {(WIN_PIX_NUM*PIXEL_W){1'b0}};
        response_pending    <= 1'b0;
        request_seen        <= 1'b0;
    end else begin
        buf_window_valid_i <= 1'b0;

        if (!req_buf_data_valid_o) begin
            request_seen <= 1'b0;
        end

        if (req_buf_data_valid_o && !request_seen) begin
            request_seen     <= 1'b1;
            response_pending <= 1'b1;
            request_count    <= request_count + 1;
        end

        if (response_pending) begin
            buf_window_valid_i  <= 1'b1;
            buf_window_pixels_i <= {(WIN_PIX_NUM*PIXEL_W){1'b0}};
            response_pending    <= 1'b0;
        end
    end
end

function integer model_src_q9;
    input integer scale_i;
    input integer dst_i;
begin
    model_src_q9 = scale_i * ((dst_i * 2) + 1) - 256;
end
endfunction

function integer model_center;
    input integer scale_i;
    input integer dst_i;
begin
    model_center = model_src_q9(scale_i, dst_i) >>> 9;
end
endfunction

function integer model_phase;
    input integer scale_i;
    input integer dst_i;
begin
    model_phase = model_src_q9(scale_i, dst_i) & 511;
end
endfunction

// Return the first destination coordinate whose center reaches the exclusive
// source limit.  The current RTL uses guard=4 for every scale because the
// buffer still returns a complete 8x8 Lanczos window for bypass points.
function integer model_plan_edge;
    input integer scale_i;
    input integer dst_start_i;
    input integer dst_size_i;
    input integer source_limit_i;
    input integer frame_end_i;
    integer candidate;
begin
    if (frame_end_i != 0) begin
        model_plan_edge = dst_size_i;
    end else begin
        candidate = dst_start_i;
        while ((candidate < dst_size_i) &&
               (model_center(scale_i, candidate) < source_limit_i)) begin
            candidate = candidate + 1;
        end
        model_plan_edge = candidate;
    end
end
endfunction

// Check every accepted scanner output.  Besides point order and phase, this
// also proves that the updated ctrl geometry agrees with plan_edge_x/y.
always @(negedge clk) begin
    integer expected_phase_x;
    integer expected_phase_y;
    integer expected_row_last;

    if (rst_n && case_output_active && lanczos_valid_o && lanczos_ready_i) begin
        expected_phase_x = model_phase(current_scale, expected_next_x);
        expected_phase_y = model_phase(current_scale, expected_next_y);
        expected_row_last = ((expected_next_x + 1) >= expected_plan_x);

        if (lanczos_dst_x_o !== expected_next_x[DST_W-1:0]) begin
            $display("[%0t] ERROR: dst_x got=%0d exp=%0d",
                     $time, lanczos_dst_x_o, expected_next_x);
            error_count = error_count + 1;
        end
        if (lanczos_dst_y_o !== expected_next_y[DST_W-1:0]) begin
            $display("[%0t] ERROR: dst_y got=%0d exp=%0d",
                     $time, lanczos_dst_y_o, expected_next_y);
            error_count = error_count + 1;
        end
        if (lanczos_phase_x_q9_o !== expected_phase_x[8:0]) begin
            $display("[%0t] ERROR: phase_x dst=%0d got=%0d exp=%0d",
                     $time, expected_next_x, lanczos_phase_x_q9_o, expected_phase_x);
            error_count = error_count + 1;
        end
        if (lanczos_phase_y_q9_o !== expected_phase_y[8:0]) begin
            $display("[%0t] ERROR: phase_y dst=%0d got=%0d exp=%0d",
                     $time, expected_next_y, lanczos_phase_y_q9_o, expected_phase_y);
            error_count = error_count + 1;
        end
        if (lanczos_block_row_last_o !== expected_row_last[0]) begin
            $display("[%0t] ERROR: row_last dst=(%0d,%0d) got=%0d exp=%0d",
                     $time, expected_next_x, expected_next_y,
                     lanczos_block_row_last_o, expected_row_last);
            error_count = error_count + 1;
        end
        if (lanczos_bypass_en_o !== expected_bypass[0]) begin
            $display("[%0t] ERROR: bypass got=%0d exp=%0d",
                     $time, lanczos_bypass_en_o, expected_bypass);
            error_count = error_count + 1;
        end
        if (lanczos_ctrl_o !== expected_ctrl) begin
            $display("[%0t] ERROR: updated ctrl got=0x%016h exp=0x%016h",
                     $time, lanczos_ctrl_o, expected_ctrl);
            error_count = error_count + 1;
        end

        output_count = output_count + 1;
        if (expected_row_last != 0) begin
            expected_next_x = expected_start_x;
            expected_next_y = expected_next_y + 1;
        end else begin
            expected_next_x = expected_next_x + 1;
        end
    end
end

task reset_dut;
begin
    clk                   = 1'b0;
    rst_n                 = 1'b0;
    scale_q8              = 12'd512;
    dst_width             = 13'd1;
    dst_height            = 13'd1;
    ctrl_vld_i            = 1'b0;
    fg2pp_ctrl_i          = 54'd0;
    lanczos_ready_i       = 1'b1;
    error_count           = 0;
    timeout_count         = 0;
    case_count            = 0;
    output_count          = 0;
    request_count         = 0;
    expected_saved_edge_x = 0;
    expected_saved_edge_y = 0;
    expected_start_x      = 0;
    expected_start_y      = 0;
    expected_plan_x       = 0;
    expected_plan_y       = 0;
    expected_next_x       = 0;
    expected_next_y       = 0;
    expected_output_count = 0;
    expected_bypass       = 0;
    current_scale         = 512;
    expected_ctrl         = 64'd0;
    case_output_active    = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
end
endtask

// Monitor SC_GEOM_SCAN directly.  Whenever a direction has no hit among its
// four candidates, its base dst and Q9 source coordinate must advance by four.
task check_geometry_scan;
    integer old_dst_x;
    integer old_dst_y;
    integer old_src_x_q9;
    integer old_src_y_q9;
    integer check_x_advance;
    integer check_y_advance;
    integer x_advance_count;
    integer y_advance_count;
    integer parallel_advance_count;
begin
    timeout_count = 0;
    while ((dut.sc_state != SC_GEOM_SCAN) && (timeout_count < 100)) begin
        @(negedge clk);
        timeout_count = timeout_count + 1;
    end

    if (dut.sc_state != SC_GEOM_SCAN) begin
        $display("[%0t] ERROR: timeout waiting SC_GEOM_SCAN", $time);
        error_count = error_count + 1;
    end

    x_advance_count = 0;
    y_advance_count = 0;
    parallel_advance_count = 0;

    while (dut.sc_state == SC_GEOM_SCAN) begin
        old_dst_x = dut.geom_dst_x;
        old_dst_y = dut.geom_dst_y;
        old_src_x_q9 = dut.geom_src_x_q9;
        old_src_y_q9 = dut.geom_src_y_q9;
        check_x_advance = !dut.geom_x_done && !dut.geom_x_hit;
        check_y_advance = !dut.geom_y_done && !dut.geom_y_hit;

        if (check_x_advance && check_y_advance) begin
            parallel_advance_count = parallel_advance_count + 1;
        end

        @(negedge clk);

        if (check_x_advance) begin
            x_advance_count = x_advance_count + 1;
            if (dut.geom_dst_x !== (old_dst_x + 4)) begin
                $display("[%0t] ERROR: X candidate base did not advance by 4, old=%0d new=%0d",
                         $time, old_dst_x, dut.geom_dst_x);
                error_count = error_count + 1;
            end
            if (dut.geom_src_x_q9 !==
                (old_src_x_q9 + (current_scale * 8))) begin
                $display("[%0t] ERROR: X Q9 source step got=%0d exp=%0d",
                         $time, dut.geom_src_x_q9,
                         old_src_x_q9 + (current_scale * 8));
                error_count = error_count + 1;
            end
        end

        if (check_y_advance) begin
            y_advance_count = y_advance_count + 1;
            if (dut.geom_dst_y !== (old_dst_y + 4)) begin
                $display("[%0t] ERROR: Y candidate base did not advance by 4, old=%0d new=%0d",
                         $time, old_dst_y, dut.geom_dst_y);
                error_count = error_count + 1;
            end
            if (dut.geom_src_y_q9 !==
                (old_src_y_q9 + (current_scale * 8))) begin
                $display("[%0t] ERROR: Y Q9 source step got=%0d exp=%0d",
                         $time, dut.geom_src_y_q9,
                         old_src_y_q9 + (current_scale * 8));
                error_count = error_count + 1;
            end
        end
    end

    if (dut.sc_state !== SC_SEND_CTRL) begin
        $display("[%0t] ERROR: geometry scan left through unexpected state=%0d",
                 $time, dut.sc_state);
        error_count = error_count + 1;
    end
    if (dut.plan_edge_x !== expected_plan_x[DST_W-1:0]) begin
        $display("[%0t] ERROR: plan_edge_x got=%0d exp=%0d",
                 $time, dut.plan_edge_x, expected_plan_x);
        error_count = error_count + 1;
    end
    if (dut.plan_edge_y !== expected_plan_y[DST_W-1:0]) begin
        $display("[%0t] ERROR: plan_edge_y got=%0d exp=%0d",
                 $time, dut.plan_edge_y, expected_plan_y);
        error_count = error_count + 1;
    end
    if (!dut.frame_right_edge &&
        (x_advance_count != ((expected_plan_x - expected_start_x) / 4))) begin
        $display("[%0t] ERROR: X four-candidate cycle count got=%0d exp=%0d",
                 $time, x_advance_count,
                 (expected_plan_x - expected_start_x) / 4);
        error_count = error_count + 1;
    end
    if (!dut.frame_bottom_edge &&
        (y_advance_count != ((expected_plan_y - expected_start_y) / 4))) begin
        $display("[%0t] ERROR: Y four-candidate cycle count got=%0d exp=%0d",
                 $time, y_advance_count,
                 (expected_plan_y - expected_start_y) / 4);
        error_count = error_count + 1;
    end
    if (!dut.frame_right_edge && !dut.frame_bottom_edge &&
        ((expected_plan_x - expected_start_x) >= 4) &&
        ((expected_plan_y - expected_start_y) >= 4) &&
        (parallel_advance_count == 0)) begin
        $display("[%0t] ERROR: X/Y geometry searches never advanced together",
                 $time);
        error_count = error_count + 1;
    end

    $display("[%0t] GEOM_RESULT start=(%0d,%0d) edge=(%0d,%0d) size=%0dx%0d x_step4=%0d y_step4=%0d parallel=%0d",
             $time, expected_start_x, expected_start_y,
             dut.plan_edge_x, dut.plan_edge_y,
             expected_plan_x - expected_start_x,
             expected_plan_y - expected_start_y,
             x_advance_count, y_advance_count, parallel_advance_count);
end
endtask

task run_block_case;
    input integer scale_i;
    input integer dst_width_i;
    input integer dst_height_i;
    input integer block_x_i;
    input integer block_y_i;
    input integer block_width_i;
    input integer block_height_i;
    input integer frame_top_i;
    input integer frame_bottom_i;
    input integer frame_left_i;
    input integer frame_right_i;
    reg [53:0] ctrl_value;
    integer errors_before;
begin
    errors_before = error_count;
    case_count = case_count + 1;
    current_scale = scale_i;
    scale_q8 = scale_i[SCALE_W-1:0];
    dst_width = dst_width_i[DST_W-1:0];
    dst_height = dst_height_i[DST_W-1:0];

    if ((frame_top_i != 0) && (frame_left_i != 0)) begin
        expected_saved_edge_x = 0;
        expected_saved_edge_y = 0;
    end

    expected_start_x = (frame_left_i != 0) ? 0 : expected_saved_edge_x;
    expected_start_y = (frame_top_i != 0) ? 0 : expected_saved_edge_y;
    expected_plan_x = model_plan_edge(scale_i, expected_start_x,
                                      dst_width_i,
                                      block_x_i + block_width_i - 4,
                                      frame_right_i);
    expected_plan_y = model_plan_edge(scale_i, expected_start_y,
                                      dst_height_i,
                                      block_y_i + block_height_i - 4,
                                      frame_bottom_i);
    expected_next_x = expected_start_x;
    expected_next_y = expected_start_y;
    expected_output_count = (expected_plan_x - expected_start_x) *
                            (expected_plan_y - expected_start_y);
    expected_bypass = ((scale_i == 768) ||
                       (scale_i == 1280) ||
                       (scale_i == 1792));
    output_count = 0;
    request_count = 0;
    case_output_active = 1'b1;

    ctrl_value = 54'd0;
    ctrl_value[6:0]   = block_height_i[6:0];
    ctrl_value[14:7]  = block_width_i[7:0];
    ctrl_value[15]    = frame_top_i[0];
    ctrl_value[16]    = frame_bottom_i[0];
    ctrl_value[17]    = frame_left_i[0];
    ctrl_value[18]    = frame_right_i[0];
    ctrl_value[19]    = frame_top_i[0];
    ctrl_value[20]    = frame_bottom_i[0];
    ctrl_value[21]    = frame_left_i[0];
    ctrl_value[22]    = frame_right_i[0];
    ctrl_value[35:23] = block_x_i[12:0];
    ctrl_value[48:36] = block_y_i[12:0];
    ctrl_value[52:51] = 2'd0;

    expected_ctrl = {10'd0, ctrl_value};
    expected_ctrl[6:0]   = (expected_plan_y - expected_start_y);
    expected_ctrl[14:7]  = (expected_plan_x - expected_start_x);
    expected_ctrl[35:23] = expected_start_x[12:0];
    expected_ctrl[48:36] = expected_start_y[12:0];

    timeout_count = 0;
    while (!ctrl_rdy_o && (timeout_count < 100)) begin
        @(negedge clk);
        timeout_count = timeout_count + 1;
    end
    if (!ctrl_rdy_o) begin
        $display("[%0t] ERROR: timeout waiting ctrl_rdy_o", $time);
        error_count = error_count + 1;
    end

    fg2pp_ctrl_i = ctrl_value;
    ctrl_vld_i = 1'b1;
    @(negedge clk);
    ctrl_vld_i = 1'b0;

    $display("[%0t] CASE%0d scale_q8=%0d src_block=(%0d,%0d %0dx%0d) edges TBLR=%0d%0d%0d%0d",
             $time, case_count, scale_i,
             block_x_i, block_y_i, block_width_i, block_height_i,
             frame_top_i, frame_bottom_i, frame_left_i, frame_right_i);

    check_geometry_scan();

    timeout_count = 0;
    while (!buf_block_scan_done_o && (timeout_count < 200000)) begin
        @(negedge clk);
        timeout_count = timeout_count + 1;
    end
    if (!buf_block_scan_done_o) begin
        $display("[%0t] ERROR: timeout waiting block scan done", $time);
        error_count = error_count + 1;
    end

    case_output_active = 1'b0;
    if (output_count != expected_output_count) begin
        $display("[%0t] ERROR: output count got=%0d exp=%0d",
                 $time, output_count, expected_output_count);
        error_count = error_count + 1;
    end
    if (request_count != expected_output_count) begin
        $display("[%0t] ERROR: request count got=%0d exp=%0d",
                 $time, request_count, expected_output_count);
        error_count = error_count + 1;
    end

    if (frame_right_i != 0) begin
        expected_saved_edge_x = 0;
        if (frame_bottom_i != 0) begin
            expected_saved_edge_y = 0;
        end else begin
            expected_saved_edge_y = expected_plan_y;
        end
    end else begin
        expected_saved_edge_x = expected_plan_x;
    end

    @(negedge clk);
    if (error_count == errors_before) begin
        $display("[%0t] CASE%0d PASS outputs=%0d", $time, case_count, output_count);
    end
end
endtask

initial begin
    reset_dut();

    // 2x: three horizontal blocks.  This checks saved_edge_x propagation and
    // the final frame-right block consuming the remaining destination width.
    run_block_case(512, 48, 4,  0, 0, 32, 8, 1, 1, 1, 0);
    run_block_case(512, 48, 4, 32, 0, 32, 8, 1, 1, 0, 0);
    run_block_case(512, 48, 4, 64, 0, 32, 8, 1, 1, 0, 1);

    // 2x: three vertical block rows.  frame-right commits plan_edge_y for
    // the next block row, while the bottom row consumes dst_height.
    run_block_case(512, 4, 48, 0,  0, 8, 32, 1, 0, 1, 1);
    run_block_case(512, 4, 48, 0, 32, 8, 32, 0, 0, 1, 1);
    run_block_case(512, 4, 48, 0, 64, 8, 32, 0, 1, 1, 1);

    // 2.3x represented by Q8 value 589.  A 48x64 non-right/non-bottom
    // source block is expected to produce geometry 19x26 with guard=4.
    run_block_case(589, 64, 64, 0, 0, 48, 64, 1, 0, 1, 0);

    // Integer 3x/5x/7x cases verify phase=0 and bypass=1.  Geometry still
    // uses guard=4 until the buffer has a center-only bypass read path.
    run_block_case(768,  64, 64, 0, 0, 32, 32, 1, 0, 1, 0);
    run_block_case(1280, 64, 64, 0, 0, 32, 32, 1, 0, 1, 0);
    run_block_case(1792, 64, 64, 0, 0, 32, 32, 1, 0, 1, 0);

    repeat (5) @(negedge clk);
    if (error_count == 0) begin
        $display("PASS: tb_dst_scan_geometry completed, cases=%0d", case_count);
    end else begin
        $display("FAIL: tb_dst_scan_geometry completed with %0d errors", error_count);
    end
    $finish;
end

endmodule
