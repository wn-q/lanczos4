module pp_downscale_dst_scan_ctrl #(
    parameter PIXEL_W     = 10,
    parameter DST_W       = 13,
    parameter TAP_COORD_W = 13,
    parameter SCALE_W     = 12,
    parameter SRC_Q_W     = 21,
    parameter WIN_PIX_NUM = 64,
    parameter CTRL_W      = 64
) (
    input clk,
    input rst_n,

    input [SCALE_W-1:0] scale_q8,
    input [DST_W-1:0]   dst_width,
    input [DST_W-1:0]   dst_height,

    input        ctrl_vld_i,
    output       ctrl_rdy_o,
    input [53:0] fg2pp_ctrl_i,

    output req_buf_data_valid_o,
    output reg signed [TAP_COORD_W-1:0] buf_center_x_o,
    output reg signed [TAP_COORD_W-1:0] buf_center_y_o,

    input buf_window_valid_i,
    input [WIN_PIX_NUM*PIXEL_W-1:0] buf_window_pixels_i,

    output reg lanczos_valid_o,
    input      lanczos_ready_i,
    output reg [DST_W-1:0] lanczos_dst_x_o,
    output reg [DST_W-1:0] lanczos_dst_y_o,
    output reg [8:0] lanczos_phase_x_q9_o,
    output reg [8:0] lanczos_phase_y_q9_o,
    output reg [WIN_PIX_NUM*PIXEL_W-1:0] lanczos_window_pixels_o,
    output reg lanczos_block_row_last_o,
    output reg lanczos_bypass_en_o,
    output reg [CTRL_W-1:0] lanczos_ctrl_o,

    output reg buf_block_scan_done_o
);

localparam [3:0] SC_IDLE        = 4'd0;
localparam [3:0] SC_INIT_BLOCK  = 4'd1;
localparam [3:0] SC_CALC        = 4'd2;
localparam [3:0] SC_CHECK_BOUND = 4'd3;
localparam [3:0] SC_REQ_CENTER  = 4'd4;
localparam [3:0] SC_WAIT_WINDOW = 4'd5;
localparam [3:0] SC_OUT         = 4'd6;
localparam [3:0] SC_NEXT_POINT  = 4'd7;
localparam [3:0] SC_BLOCK_DONE  = 4'd8;
localparam [3:0] SC_GEOM_INIT   = 4'd9;
localparam [3:0] SC_GEOM_SCAN   = 4'd10;
localparam [3:0] SC_SEND_CTRL   = 4'd11;

reg [3:0] sc_state;

reg [DST_W-1:0] saved_edge_x;
reg [DST_W-1:0] saved_edge_y;

// Downscale-space geometry for the current source block.  These values are
// calculated before the first center request, then copied into the ctrl that
// travels with every pixel of this output block.
reg [DST_W-1:0] block_start_x_new;
reg [DST_W-1:0] block_start_y_new;
reg [7:0]       block_width_new;
reg [6:0]       block_height_new;
reg [DST_W-1:0] plan_edge_x;
reg [DST_W-1:0] plan_edge_y;

// Four-candidate-per-cycle geometry search state.  X and Y advance in
// parallel, so the setup latency is the slower direction rather than X+Y.
reg [DST_W-1:0]   geom_dst_x;
reg [DST_W-1:0]   geom_dst_y;
reg [SRC_Q_W-1:0] geom_src_x_q9;
reg [SRC_Q_W-1:0] geom_src_y_q9;
reg                 geom_x_done;
reg                 geom_y_done;
reg [53:0]          updated_ctrl_r;

reg [6:0]  block_pixel_height;   // 当前 block 高度，scanner 用它判断 y 方向 block 边界。
reg [7:0]  block_pixel_width;    // 当前 block 宽度，scanner 用它判断 x 方向 block 边界。
reg        frame_top_edge;       // 当前 block 位于 frame 顶部。
reg        frame_bottom_edge;    // 当前 block 位于 frame 底部。
reg        frame_left_edge;      // 当前 block 位于 frame 左边界。
reg        frame_right_edge;     // 当前 block 位于 frame 右边界。
reg        tile_top_edge;        // 当前 block 位于 tile 顶部，当前阶段先锁存备用。
reg        tile_bottom_edge;     // 当前 block 位于 tile 底部，当前阶段先锁存备用。
reg        tile_left_edge;       // 当前 block 位于 tile 左边界，当前阶段先锁存备用。
reg        tile_right_edge;      // 当前 block 位于 tile 右边界，当前阶段先锁存备用。
reg [12:0] block_start_x;        // 当前 block 左上角全局 x 坐标。
reg [12:0] block_start_y;        // 当前 block 左上角全局 y 坐标。
reg [1:0]  block64_loc;          // 当前 block 在 superblock 中的位置，先锁存备用。
reg [1:0]  block_type;           // 当前数据类型，先锁存备用。
reg        picture_ready;        // 图像完成标志，先锁存备用。
reg [53:0] fg2pp_ctrl_r;         // 原始 ctrl 延迟到 lanczos 输出时透传给 core。

reg [DST_W-1:0] dst_x;
reg [DST_W-1:0] dst_y;
reg [DST_W-1:0] req_dst_x;
reg [DST_W-1:0] req_dst_y;
reg [8:0] req_phase_x_q9;
reg [8:0] req_phase_y_q9;
reg req_block_row_last;
reg req_bypass_en;

wire scale_integer_bypass;
wire [DST_W:0] dst_x_twice_plus_one;
wire [DST_W:0] dst_y_twice_plus_one;

wire [SRC_Q_W-1:0] scan_src_x_q9;
wire [SRC_Q_W-1:0] scan_src_y_q9;
wire signed [TAP_COORD_W-1:0] scan_center_x;
wire signed [TAP_COORD_W-1:0] scan_center_y;
wire [8:0] scan_phase_x_q9;
wire [8:0] scan_phase_y_q9;

wire dst_x_at_frame_end;
wire cur_x_blocked;
wire cur_y_blocked;
wire current_row_last;
wire ctrl_load;
wire new_frame_start;

wire [DST_W-1:0] geom_start_x;
wire [DST_W-1:0] geom_start_y;
wire [13:0]      geom_x_limit;
wire [13:0]      geom_y_limit;
wire [SRC_Q_W-1:0] geom_step_q9;
wire [SRC_Q_W-1:0] geom_src_x_q9_1;
wire [SRC_Q_W-1:0] geom_src_x_q9_2;
wire [SRC_Q_W-1:0] geom_src_x_q9_3;
wire [SRC_Q_W-1:0] geom_src_y_q9_1;
wire [SRC_Q_W-1:0] geom_src_y_q9_2;
wire [SRC_Q_W-1:0] geom_src_y_q9_3;
wire [DST_W-1:0] block_width_new_calc;
wire [DST_W-1:0] block_height_new_calc;
wire geom_x_done_next;
wire geom_y_done_next;
reg  geom_x_hit;
reg  geom_y_hit;
reg [DST_W-1:0] geom_x_plan_value;
reg [DST_W-1:0] geom_y_plan_value;



assign scale_integer_bypass = (scale_q8 == 12'd768)  ||
                              (scale_q8 == 12'd1280) ||
                              (scale_q8 == 12'd1792);

assign dst_x_twice_plus_one = {dst_x, 1'b0} + 14'd1;
assign dst_y_twice_plus_one = {dst_y, 1'b0} + 14'd1;

assign scan_src_x_q9 = (scale_q8 * dst_x_twice_plus_one) - 21'd256;
assign scan_src_y_q9 = (scale_q8 * dst_y_twice_plus_one) - 21'd256;

assign scan_center_x = $signed({1'b0, scan_src_x_q9[SRC_Q_W-1:9]});
assign scan_center_y = $signed({1'b0, scan_src_y_q9[SRC_Q_W-1:9]});
assign scan_phase_x_q9 = scan_src_x_q9[8:0];
assign scan_phase_y_q9 = scan_src_y_q9[8:0];

assign dst_x_at_frame_end = (dst_x == (dst_width - 1'b1));
assign cur_x_blocked = !frame_right_edge && (dst_x >= plan_edge_x);
assign cur_y_blocked = !frame_bottom_edge && (dst_y >= plan_edge_y);
assign current_row_last = frame_right_edge ? dst_x_at_frame_end :
                                              ((dst_x + 13'd1) >= plan_edge_x);

assign geom_start_x = frame_left_edge ? {DST_W{1'b0}} : saved_edge_x;
assign geom_start_y = frame_top_edge  ? {DST_W{1'b0}} : saved_edge_y;

// The current buffer always returns a full 8x8 window.  Keep a +4 guard for
// every scale until a dedicated bypass-only center-read path is added.
assign geom_x_limit = {1'b0, block_start_x} + {6'd0, block_pixel_width} - 14'd4;
assign geom_y_limit = {1'b0, block_start_y} + {7'd0, block_pixel_height} - 14'd4;
assign geom_step_q9 = {scale_q8, 1'b0};

assign geom_src_x_q9_1 = geom_src_x_q9 + geom_step_q9;
assign geom_src_x_q9_2 = geom_src_x_q9_1 + geom_step_q9;
assign geom_src_x_q9_3 = geom_src_x_q9_2 + geom_step_q9;
assign geom_src_y_q9_1 = geom_src_y_q9 + geom_step_q9;
assign geom_src_y_q9_2 = geom_src_y_q9_1 + geom_step_q9;
assign geom_src_y_q9_3 = geom_src_y_q9_2 + geom_step_q9;

assign block_width_new_calc = plan_edge_x - block_start_x_new;
assign block_height_new_calc = plan_edge_y - block_start_y_new;
assign geom_x_done_next = geom_x_done || geom_x_hit;
assign geom_y_done_next = geom_y_done || geom_y_hit;

// Compare four monotonically increasing X candidates in parallel.  The first
// one reaching the exclusive source limit is the next block's dst_x start.
always @(*) begin
    geom_x_hit = 1'b0;
    geom_x_plan_value = {DST_W{1'b0}};

    if (frame_right_edge) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = dst_width;
    end else if (geom_dst_x >= dst_width) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = dst_width;
    end else if (geom_src_x_q9[SRC_Q_W-1:9] >= geom_x_limit) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = geom_dst_x;
    end else if ((geom_dst_x + 13'd1) >= dst_width) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = dst_width;
    end else if (geom_src_x_q9_1[SRC_Q_W-1:9] >= geom_x_limit) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = geom_dst_x + 13'd1;
    end else if ((geom_dst_x + 13'd2) >= dst_width) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = dst_width;
    end else if (geom_src_x_q9_2[SRC_Q_W-1:9] >= geom_x_limit) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = geom_dst_x + 13'd2;
    end else if ((geom_dst_x + 13'd3) >= dst_width) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = dst_width;
    end else if (geom_src_x_q9_3[SRC_Q_W-1:9] >= geom_x_limit) begin
        geom_x_hit = 1'b1;
        geom_x_plan_value = geom_dst_x + 13'd3;
    end
end

// Y direction uses the same four-candidate search and runs in the same cycle
// as X.  This avoids serial X-then-Y setup latency.
always @(*) begin
    geom_y_hit = 1'b0;
    geom_y_plan_value = {DST_W{1'b0}};

    if (frame_bottom_edge) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = dst_height;
    end else if (geom_dst_y >= dst_height) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = dst_height;
    end else if (geom_src_y_q9[SRC_Q_W-1:9] >= geom_y_limit) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = geom_dst_y;
    end else if ((geom_dst_y + 13'd1) >= dst_height) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = dst_height;
    end else if (geom_src_y_q9_1[SRC_Q_W-1:9] >= geom_y_limit) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = geom_dst_y + 13'd1;
    end else if ((geom_dst_y + 13'd2) >= dst_height) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = dst_height;
    end else if (geom_src_y_q9_2[SRC_Q_W-1:9] >= geom_y_limit) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = geom_dst_y + 13'd2;
    end else if ((geom_dst_y + 13'd3) >= dst_height) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = dst_height;
    end else if (geom_src_y_q9_3[SRC_Q_W-1:9] >= geom_y_limit) begin
        geom_y_hit = 1'b1;
        geom_y_plan_value = geom_dst_y + 13'd3;
    end
end

assign req_buf_data_valid_o = (sc_state == SC_REQ_CENTER) || (sc_state == SC_WAIT_WINDOW);
assign ctrl_rdy_o = (sc_state == SC_IDLE);
assign ctrl_load = ctrl_vld_i && ctrl_rdy_o;


assign new_frame_start = frame_top_edge && frame_left_edge;

// ---------------------------------------------------------------------------
// Ctrl latch always: 在 ctrl_vld_i && ctrl_rdy_o 时锁存当前 block 的控制信息。
// 后续扫描逻辑统一使用这些有名字的寄存器，不直接访问 fg2pp_ctrl_i 的 bit 位。
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        block_pixel_height <= 7'd0;
        block_pixel_width  <= 8'd0;
        frame_top_edge     <= 1'b0;
        frame_bottom_edge  <= 1'b0;
        frame_left_edge    <= 1'b0;
        frame_right_edge   <= 1'b0;
        tile_top_edge      <= 1'b0;
        tile_bottom_edge   <= 1'b0;
        tile_left_edge     <= 1'b0;
        tile_right_edge    <= 1'b0;
        block_start_x      <= 13'd0;
        block_start_y      <= 13'd0;
        block64_loc        <= 2'd0;
        block_type         <= 2'd0;
        picture_ready      <= 1'b0;
        fg2pp_ctrl_r       <= 54'd0;
    end else if (ctrl_load) begin
        block_pixel_height <= fg2pp_ctrl_i[6:0];
        block_pixel_width  <= fg2pp_ctrl_i[14:7];
        frame_top_edge     <= fg2pp_ctrl_i[15];
        frame_bottom_edge  <= fg2pp_ctrl_i[16];
        frame_left_edge    <= fg2pp_ctrl_i[17];
        frame_right_edge   <= fg2pp_ctrl_i[18];
        tile_top_edge      <= fg2pp_ctrl_i[19];
        tile_bottom_edge   <= fg2pp_ctrl_i[20];
        tile_left_edge     <= fg2pp_ctrl_i[21];
        tile_right_edge    <= fg2pp_ctrl_i[22];
        block_start_x      <= fg2pp_ctrl_i[35:23];
        block_start_y      <= fg2pp_ctrl_i[48:36];
        block64_loc        <= fg2pp_ctrl_i[50:49];
        block_type         <= fg2pp_ctrl_i[52:51];
        picture_ready      <= fg2pp_ctrl_i[53];
        fg2pp_ctrl_r <= fg2pp_ctrl_i;
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        sc_state <= SC_IDLE;
        saved_edge_x <= {DST_W{1'b0}};
        saved_edge_y <= {DST_W{1'b0}};
        block_start_x_new <= {DST_W{1'b0}};
        block_start_y_new <= {DST_W{1'b0}};
        block_width_new <= 8'd0;
        block_height_new <= 7'd0;
        plan_edge_x <= {DST_W{1'b0}};
        plan_edge_y <= {DST_W{1'b0}};
        geom_dst_x <= {DST_W{1'b0}};
        geom_dst_y <= {DST_W{1'b0}};
        geom_src_x_q9 <= {SRC_Q_W{1'b0}};
        geom_src_y_q9 <= {SRC_Q_W{1'b0}};
        geom_x_done <= 1'b0;
        geom_y_done <= 1'b0;
        updated_ctrl_r <= 54'd0;
        dst_x <= {DST_W{1'b0}};
        dst_y <= {DST_W{1'b0}};
        req_dst_x <= {DST_W{1'b0}};
        req_dst_y <= {DST_W{1'b0}};
        req_phase_x_q9 <= 9'd0;
        req_phase_y_q9 <= 9'd0;
        req_block_row_last <= 1'b0;
        req_bypass_en <= 1'b0;
        buf_center_x_o <= {TAP_COORD_W{1'b0}};
        buf_center_y_o <= {TAP_COORD_W{1'b0}};
        lanczos_valid_o <= 1'b0;
        lanczos_dst_x_o <= {DST_W{1'b0}};
        lanczos_dst_y_o <= {DST_W{1'b0}};
        lanczos_phase_x_q9_o <= 9'd0;
        lanczos_phase_y_q9_o <= 9'd0;
        lanczos_window_pixels_o <= {(WIN_PIX_NUM*PIXEL_W){1'b0}};
        lanczos_block_row_last_o <= 1'b0;
        lanczos_bypass_en_o <= 1'b0;
        lanczos_ctrl_o <= {CTRL_W{1'b0}};
        buf_block_scan_done_o <= 1'b0;
    end else begin
        buf_block_scan_done_o <= 1'b0;

        case (sc_state)
            SC_IDLE: begin
                lanczos_valid_o <= 1'b0;
                if (ctrl_load) begin
                    sc_state <= SC_INIT_BLOCK;
                end
            end
            
            SC_INIT_BLOCK: begin
                if (new_frame_start) begin
                    saved_edge_x <= {DST_W{1'b0}};
                    saved_edge_y <= {DST_W{1'b0}};
                end
                sc_state <= SC_GEOM_INIT;
            end

            // Start geometry search from the saved output edge.  The Q9
            // source coordinate is calculated once; subsequent candidates
            // advance only by 2 * scale_q8.
            SC_GEOM_INIT: begin
                block_start_x_new <= geom_start_x;
                block_start_y_new <= geom_start_y;
                geom_dst_x <= geom_start_x;
                geom_dst_y <= geom_start_y;
                geom_src_x_q9 <= (scale_q8 * ({geom_start_x, 1'b0} + 14'd1)) - 21'd256;
                geom_src_y_q9 <= (scale_q8 * ({geom_start_y, 1'b0} + 14'd1)) - 21'd256;
                geom_x_done <= 1'b0;
                geom_y_done <= 1'b0;
                sc_state <= SC_GEOM_SCAN;
            end

            // Search four destination coordinates for X and Y in parallel.
            // Each direction stops at its first source-center boundary.
            SC_GEOM_SCAN: begin
                if (!geom_x_done) begin
                    if (geom_x_hit) begin
                        plan_edge_x <= geom_x_plan_value;
                        geom_x_done <= 1'b1;
                    end else begin
                        geom_dst_x <= geom_dst_x + 13'd4;
                        geom_src_x_q9 <= geom_src_x_q9 +
                                         geom_step_q9 + geom_step_q9 +
                                         geom_step_q9 + geom_step_q9;
                    end
                end

                if (!geom_y_done) begin
                    if (geom_y_hit) begin
                        plan_edge_y <= geom_y_plan_value;
                        geom_y_done <= 1'b1;
                    end else begin
                        geom_dst_y <= geom_dst_y + 13'd4;
                        geom_src_y_q9 <= geom_src_y_q9 +
                                         geom_step_q9 + geom_step_q9 +
                                         geom_step_q9 + geom_step_q9;
                    end
                end

                if (geom_x_done_next && geom_y_done_next) begin
                    sc_state <= SC_SEND_CTRL;
                end
            end

            // plan_edge_* are exclusive output bounds.  Form the four new
            // ctrl fields before the first center request of this block.
            SC_SEND_CTRL: begin
                block_width_new <= block_width_new_calc[7:0];
                block_height_new <= block_height_new_calc[6:0];
                updated_ctrl_r <= {
                    fg2pp_ctrl_r[53:49],
                    block_start_y_new[12:0],
                    block_start_x_new[12:0],
                    fg2pp_ctrl_r[22:15],
                    block_width_new_calc[7:0],
                    block_height_new_calc[6:0]
                };
                dst_x <= block_start_x_new;
                dst_y <= block_start_y_new;
                sc_state <= SC_CALC;
            end

            SC_CALC: begin
                sc_state <= SC_CHECK_BOUND;
            end

            SC_CHECK_BOUND: begin
                if (dst_y >= dst_height) begin
                    sc_state <= SC_BLOCK_DONE;
                end else if (cur_y_blocked) begin
                    sc_state <= SC_BLOCK_DONE;
                end else if (dst_x >= dst_width) begin
                    dst_x <= block_start_x_new;
                    dst_y <= dst_y + 13'd1;
                    sc_state <= SC_CALC;
                end else if (cur_x_blocked) begin
                    dst_x <= block_start_x_new;
                    dst_y <= dst_y + 13'd1;
                    sc_state <= SC_CALC;
                end else begin
                    req_dst_x <= dst_x;
                    req_dst_y <= dst_y;
                    buf_center_x_o <= scan_center_x;
                    buf_center_y_o <= scan_center_y;
                    req_phase_x_q9 <= scan_phase_x_q9;
                    req_phase_y_q9 <= scan_phase_y_q9;
                    req_block_row_last <= current_row_last;
                    req_bypass_en <= scale_integer_bypass;
                    sc_state <= SC_REQ_CENTER;
                end
            end

            SC_REQ_CENTER: begin
                sc_state <= SC_WAIT_WINDOW;
            end

            SC_WAIT_WINDOW: begin
                if (buf_window_valid_i) begin
                    lanczos_dst_x_o <= req_dst_x;
                    lanczos_dst_y_o <= req_dst_y;
                    lanczos_phase_x_q9_o <= req_phase_x_q9;
                    lanczos_phase_y_q9_o <= req_phase_y_q9;
                    lanczos_window_pixels_o <= buf_window_pixels_i;
                    lanczos_block_row_last_o <= req_block_row_last;
                    lanczos_bypass_en_o <= req_bypass_en;
                    lanczos_ctrl_o <= {10'd0, updated_ctrl_r};
                    lanczos_valid_o <= 1'b1;
                    sc_state <= SC_OUT;
                end
            end

            SC_OUT: begin
                if (lanczos_ready_i) begin
                    lanczos_valid_o <= 1'b0;
                    sc_state <= SC_NEXT_POINT;
                end
            end

            SC_NEXT_POINT: begin
                if (req_block_row_last) begin
                    dst_x <= block_start_x_new;
                    dst_y <= req_dst_y + 13'd1;
                end else begin
                    dst_x <= req_dst_x + 13'd1;
                    dst_y <= req_dst_y;
                end
                sc_state <= SC_CALC;
            end

            SC_BLOCK_DONE: begin
                buf_block_scan_done_o <= 1'b1;
                if (frame_right_edge) begin
                    saved_edge_x <= {DST_W{1'b0}};
                    if (frame_bottom_edge) begin
                        saved_edge_y <= {DST_W{1'b0}};
                    end else begin
                        saved_edge_y <= plan_edge_y;
                    end
                end else begin
                    saved_edge_x <= plan_edge_x;
                end
                sc_state <= SC_IDLE;
            end

            default: begin
                sc_state <= SC_IDLE;
            end
        endcase
    end
end

endmodule
