module pp_downscale_dst_scan_ctrl #(
    // 单个像素位宽。
    parameter PIXEL_W     = 10,
    // 目标图像坐标位宽。
    parameter DST_W       = 13,
    // 源图 center 坐标 signed 位宽，可表示 0~4095 并支持相减后的负值。
    parameter TAP_COORD_W = 13,
    // Q8 缩放比例位宽。
    parameter SCALE_W     = 12,
    // 源图最大 4096：12bit 整数 + 9bit 小数 = 21bit。
    parameter SRC_Q_W     = 21,
    // Lanczos4 的 8x8 window 像素数量。
    parameter WIN_PIX_NUM = 64
) (
    input clk,
    input rst_n,
    input scan_clr,

    // 全局 downscale 配置。
    input [SCALE_W-1:0] scale_q8,
    input [DST_W-1:0]   dst_width,
    input [DST_W-1:0]   dst_height,

    // buffer/block 范围输入。
    input        buf_block_valid_i,
    output       buf_block_ready_o,
    input [12:0] buf_block_start_x_i,
    input [12:0] buf_block_start_y_i,
    input [7:0]  buf_block_width_i,
    input [6:0]  buf_block_height_i,
    input        buf_frame_left_i,
    input        buf_frame_right_i,
    input        buf_frame_top_i,
    input        buf_frame_bottom_i,

    // 发给 buffer 的 64-tap 源图 window 请求。
    output req_buf_data_valid_o,
    output reg signed [TAP_COORD_W-1:0] buf_center_x_o,
    output reg signed [TAP_COORD_W-1:0] buf_center_y_o,

    // buffer 返回的 window 数据。
    input buf_window_valid_i,
    input [WIN_PIX_NUM*PIXEL_W-1:0] buf_window_pixels_i,
    input [WIN_PIX_NUM-1:0]         buf_window_valid_mask_i,

    // 打包后送给 Lanczos core 的输出数据。
    output reg lanczos_valid_o,
    input      lanczos_ready_i,
    output reg [DST_W-1:0] lanczos_dst_x_o,
    output reg [DST_W-1:0] lanczos_dst_y_o,
    output reg signed [TAP_COORD_W-1:0] lanczos_center_x_o,
    output reg signed [TAP_COORD_W-1:0] lanczos_center_y_o,
    output reg [8:0] lanczos_phase_x_q9_o,
    output reg [8:0] lanczos_phase_y_q9_o,
    output reg [WIN_PIX_NUM*PIXEL_W-1:0] lanczos_window_pixels_o,
    output reg [WIN_PIX_NUM-1:0]         lanczos_window_valid_mask_o,
    output reg lanczos_block_row_last_o,
    output reg lanczos_bypass_en_o,

    // 当前 block 没有更多 center 请求需要发出。
    output reg buf_block_scan_done_o
);

// -----------------------------------------------------------------------------
// 功能:
//   1. 扫描当前源图 block 可以计算的 dst 输出点。
//   2. 将 dst 坐标转换为源图 Q9 坐标，并拆出 center 和 phase。
//   3. 对每个可计算点向 buffer 请求 64-tap window。
//   4. 将 dst/center/phase/window 数据打包发送给 Lanczos core。
//   5. 维护跨 block 的 edge 坐标，避免漏点或重复计算。
// -----------------------------------------------------------------------------

localparam [2:0] SC_IDLE        = 3'd0; // 等待新的 block。
localparam [2:0] SC_CALC        = 3'd1; // 等待组合坐标计算稳定。
localparam [2:0] SC_CHECK_BOUND = 3'd2; // 检查当前点是否越过 block 边界。
localparam [2:0] SC_REQ_CENTER  = 3'd3; // 向 buffer 发出 center 请求。
localparam [2:0] SC_WAIT_WINDOW = 3'd4; // 等待 buffer 返回 window。
localparam [2:0] SC_OUT         = 3'd5; // 将打包数据送给 Lanczos core。
localparam [2:0] SC_NEXT_POINT  = 3'd6; // 推进 x 或切换到下一行。
localparam [2:0] SC_BLOCK_DONE  = 3'd7; // 提交 edge 寄存器并结束当前 block。

reg [2:0] sc_state;

// saved_edge_* 保存跨 block 的下次扫描起点。
reg [DST_W-1:0] saved_edge_x;
reg [DST_W-1:0] saved_edge_y;

// cur_edge_* 在 block 开始时加载一次，并在当前 block 扫描期间保持不变。
reg [DST_W-1:0] cur_edge_x;
reg [DST_W-1:0] cur_edge_y;

// next_edge_* 记录后续 block 应该从哪里继续扫描。
reg [DST_W-1:0] next_edge_x;
reg [DST_W-1:0] next_edge_y;

// 当前正在测试的 dst 坐标。
reg [DST_W-1:0] dst_x;
reg [DST_W-1:0] dst_y;

// 请求快照，在等待 buffer 返回 window 期间保持不变。
reg [DST_W-1:0] req_dst_x;
reg [DST_W-1:0] req_dst_y;
reg [8:0] req_phase_x_q9;
reg [8:0] req_phase_y_q9;
reg req_block_row_last;
reg req_row_last_by_block;
reg req_bypass_en;

wire scale_integer_bypass;

// 2*dst+1 用于实现像素中心对齐映射：
// src = scale * (dst + 0.5) - 0.5。
wire [DST_W:0] dst_x_twice_plus_one;
wire [DST_W:0] dst_y_twice_plus_one;
wire [DST_W:0] next_x_twice_plus_one;

// 源图 Q9 坐标，以及拆出的整数/小数字段。
wire [SRC_Q_W-1:0] scan_src_x_q9;
wire [SRC_Q_W-1:0] scan_src_y_q9;
wire [SRC_Q_W-1:0] next_src_x_q9;
wire signed [TAP_COORD_W-1:0] scan_center_x;
wire signed [TAP_COORD_W-1:0] scan_center_y;
wire signed [TAP_COORD_W-1:0] next_center_x;
wire [8:0] scan_phase_x_q9;
wire [8:0] scan_phase_y_q9;

// block 局部 center，用于右/下边界判断。
wire signed [TAP_COORD_W-1:0] block_start_x_s;
wire signed [TAP_COORD_W-1:0] block_start_y_s;
wire signed [TAP_COORD_W-1:0] block_x_limit_s;
wire signed [TAP_COORD_W-1:0] block_y_limit_s;
wire signed [TAP_COORD_W-1:0] local_center_x;
wire signed [TAP_COORD_W-1:0] local_center_y;
wire signed [TAP_COORD_W-1:0] next_local_center_x;

wire dst_x_at_frame_end;
wire cur_x_blocked;
wire cur_y_blocked;
wire next_x_blocked;
wire current_row_last;
wire row_last_by_block;
wire buf_block_fire;

// scale 为 3/5/7 时，映射 phase 总是整数对齐。
// 当前版本仍请求 64 tap，只向后级传递 bypass 提示。
assign scale_integer_bypass = (scale_q8 == 12'd768)  ||
                              (scale_q8 == 12'd1280) ||
                              (scale_q8 == 12'd1792);

assign dst_x_twice_plus_one = {dst_x, 1'b0} + {{DST_W{1'b0}}, 1'b1};
assign dst_y_twice_plus_one = {dst_y, 1'b0} + {{DST_W{1'b0}}, 1'b1};
assign next_x_twice_plus_one = {dst_x + {{(DST_W-1){1'b0}}, 1'b1}, 1'b0} +
                                {{DST_W{1'b0}}, 1'b1};

// src_q9 = scale_q8 * (2*dst + 1) - 256。
assign scan_src_x_q9 = (scale_q8 * dst_x_twice_plus_one) - {{(SRC_Q_W-9){1'b0}}, 9'd256};
assign scan_src_y_q9 = (scale_q8 * dst_y_twice_plus_one) - {{(SRC_Q_W-9){1'b0}}, 9'd256};
assign next_src_x_q9 = (scale_q8 * next_x_twice_plus_one) - {{(SRC_Q_W-9){1'b0}}, 9'd256};

// center 是整数部分，phase 是 Q9 小数部分。
// src_q9 只保存 12bit 源图整数坐标；center 输出补 0 扩成 signed 13bit。
assign scan_center_x = $signed({1'b0, scan_src_x_q9[SRC_Q_W-1:9]});
assign scan_center_y = $signed({1'b0, scan_src_y_q9[SRC_Q_W-1:9]});
assign next_center_x = $signed({1'b0, next_src_x_q9[SRC_Q_W-1:9]});
assign scan_phase_x_q9 = scan_src_x_q9[8:0];
assign scan_phase_y_q9 = scan_src_y_q9[8:0];

assign block_start_x_s = $signed(buf_block_start_x_i[TAP_COORD_W-1:0]);
assign block_start_y_s = $signed(buf_block_start_y_i[TAP_COORD_W-1:0]);

// 非 frame 右/下边界 block 必须在 Lanczos4 tap 跨到下一个源图 block 前停止。
// 这里减 4 是为右侧/下侧 tap 范围预留空间。
assign block_x_limit_s = $signed({5'd0, buf_block_width_i}) - 13'sd4;
assign block_y_limit_s = $signed({6'd0, buf_block_height_i}) - 13'sd4;
assign local_center_x = scan_center_x - block_start_x_s;
assign local_center_y = scan_center_y - block_start_y_s;
assign next_local_center_x = next_center_x - block_start_x_s;

assign dst_x_at_frame_end = (dst_x == (dst_width - 1'b1));
assign cur_x_blocked = !buf_frame_right_i && (local_center_x > block_x_limit_s);
assign cur_y_blocked = !buf_frame_bottom_i && (local_center_y > block_y_limit_s);
assign next_x_blocked = !buf_frame_right_i && (next_local_center_x > block_x_limit_s);

// 提前看下一个 x，使当前 block row 的最后一个可算点能同步输出
// lanczos_block_row_last_o。
assign row_last_by_block = !dst_x_at_frame_end && next_x_blocked;
assign current_row_last = dst_x_at_frame_end || row_last_by_block;

// buffer 请求从发出开始保持有效，直到 window 返回。
assign req_buf_data_valid_o = (sc_state == SC_REQ_CENTER) || (sc_state == SC_WAIT_WINDOW);
assign buf_block_ready_o = (sc_state == SC_IDLE);
assign buf_block_fire = buf_block_valid_i && buf_block_ready_o;

// -----------------------------------------------------------------------------
// 主状态机。
// -----------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sc_state <= SC_IDLE;
        saved_edge_x <= {DST_W{1'b0}};
        saved_edge_y <= {DST_W{1'b0}};
        cur_edge_x <= {DST_W{1'b0}};
        cur_edge_y <= {DST_W{1'b0}};
        next_edge_x <= {DST_W{1'b0}};
        next_edge_y <= {DST_W{1'b0}};
        dst_x <= {DST_W{1'b0}};
        dst_y <= {DST_W{1'b0}};
        req_dst_x <= {DST_W{1'b0}};
        req_dst_y <= {DST_W{1'b0}};
        req_phase_x_q9 <= 9'd0;
        req_phase_y_q9 <= 9'd0;
        req_block_row_last <= 1'b0;
        req_row_last_by_block <= 1'b0;
        req_bypass_en <= 1'b0;
        buf_center_x_o <= {TAP_COORD_W{1'b0}};
        buf_center_y_o <= {TAP_COORD_W{1'b0}};
        lanczos_valid_o <= 1'b0;
        lanczos_dst_x_o <= {DST_W{1'b0}};
        lanczos_dst_y_o <= {DST_W{1'b0}};
        lanczos_center_x_o <= {TAP_COORD_W{1'b0}};
        lanczos_center_y_o <= {TAP_COORD_W{1'b0}};
        lanczos_phase_x_q9_o <= 9'd0;
        lanczos_phase_y_q9_o <= 9'd0;
        lanczos_window_pixels_o <= {(WIN_PIX_NUM*PIXEL_W){1'b0}};
        lanczos_window_valid_mask_o <= {WIN_PIX_NUM{1'b0}};
        lanczos_block_row_last_o <= 1'b0;
        lanczos_bypass_en_o <= 1'b0;
        buf_block_scan_done_o <= 1'b0;
    end else if (scan_clr) begin
        // scan_clr 用于开始新 frame/新扫描，并清空跨 block edge。
        sc_state <= SC_IDLE;
        saved_edge_x <= {DST_W{1'b0}};
        saved_edge_y <= {DST_W{1'b0}};
        cur_edge_x <= {DST_W{1'b0}};
        cur_edge_y <= {DST_W{1'b0}};
        next_edge_x <= {DST_W{1'b0}};
        next_edge_y <= {DST_W{1'b0}};
        dst_x <= {DST_W{1'b0}};
        dst_y <= {DST_W{1'b0}};
        req_dst_x <= {DST_W{1'b0}};
        req_dst_y <= {DST_W{1'b0}};
        req_phase_x_q9 <= 9'd0;
        req_phase_y_q9 <= 9'd0;
        req_block_row_last <= 1'b0;
        req_row_last_by_block <= 1'b0;
        req_bypass_en <= 1'b0;
        buf_center_x_o <= {TAP_COORD_W{1'b0}};
        buf_center_y_o <= {TAP_COORD_W{1'b0}};
        lanczos_valid_o <= 1'b0;
        lanczos_dst_x_o <= {DST_W{1'b0}};
        lanczos_dst_y_o <= {DST_W{1'b0}};
        lanczos_center_x_o <= {TAP_COORD_W{1'b0}};
        lanczos_center_y_o <= {TAP_COORD_W{1'b0}};
        lanczos_phase_x_q9_o <= 9'd0;
        lanczos_phase_y_q9_o <= 9'd0;
        lanczos_window_pixels_o <= {(WIN_PIX_NUM*PIXEL_W){1'b0}};
        lanczos_window_valid_mask_o <= {WIN_PIX_NUM{1'b0}};
        lanczos_block_row_last_o <= 1'b0;
        lanczos_bypass_en_o <= 1'b0;
        buf_block_scan_done_o <= 1'b0;
    end else begin
        buf_block_scan_done_o <= 1'b0;

        case (sc_state)
            SC_IDLE: begin
                lanczos_valid_o <= 1'b0;
                if (buf_block_fire) begin
                    // 当前 block 的固定扫描起点只选择一次。
                    cur_edge_x <= buf_frame_left_i ? {DST_W{1'b0}} : saved_edge_x;
                    cur_edge_y <= buf_frame_top_i  ? {DST_W{1'b0}} : saved_edge_y;
                    dst_x <= buf_frame_left_i ? {DST_W{1'b0}} : saved_edge_x;
                    dst_y <= buf_frame_top_i  ? {DST_W{1'b0}} : saved_edge_y;

                    // next x edge 默认继承当前起点。
                    next_edge_x <= buf_frame_left_i ? {DST_W{1'b0}} : saved_edge_x;

                    // y edge 只由每条 block-row 最左侧 block 刷新。
                    if (buf_frame_left_i) begin
                        next_edge_y <= buf_frame_top_i ? {DST_W{1'b0}} : saved_edge_y;
                    end
                    sc_state <= SC_CALC;
                end
            end

            SC_CALC: begin
                sc_state <= SC_CHECK_BOUND;
            end

            SC_CHECK_BOUND: begin
                if (dst_y >= dst_height) begin
                    sc_state <= SC_BLOCK_DONE;
                end else if (cur_y_blocked) begin
                    // 当前行需要下方 block-row 的数据。
                    next_edge_y <= dst_y;
                    sc_state <= SC_BLOCK_DONE;
                end else if (dst_x >= dst_width) begin
                    // 当前 dst 行已经到达 frame 右边界。
                    dst_x <= cur_edge_x;
                    dst_y <= dst_y + {{(DST_W-1){1'b0}}, 1'b1};
                    sc_state <= SC_CALC;
                end else if (cur_x_blocked) begin
                    // 当前点需要右侧 block 的数据。
                    next_edge_x <= dst_x;
                    dst_x <= cur_edge_x;
                    dst_y <= dst_y + {{(DST_W-1){1'b0}}, 1'b1};
                    sc_state <= SC_CALC;
                end else begin
                    // 当前点可由本 block 计算，请求对应 window。
                    req_dst_x <= dst_x;
                    req_dst_y <= dst_y;
                    buf_center_x_o <= scan_center_x;
                    buf_center_y_o <= scan_center_y;
                    req_phase_x_q9 <= scan_phase_x_q9;
                    req_phase_y_q9 <= scan_phase_y_q9;
                    req_block_row_last <= current_row_last;
                    req_row_last_by_block <= row_last_by_block;
                    req_bypass_en <= scale_integer_bypass;
                    sc_state <= SC_REQ_CENTER;
                end
            end

            SC_REQ_CENTER: begin
                sc_state <= SC_WAIT_WINDOW;
            end

            SC_WAIT_WINDOW: begin
                if (buf_window_valid_i) begin
                    // buffer 返回 64 tap 后，和请求快照一起打包输出。
                    lanczos_dst_x_o <= req_dst_x;
                    lanczos_dst_y_o <= req_dst_y;
                    lanczos_center_x_o <= buf_center_x_o;
                    lanczos_center_y_o <= buf_center_y_o;
                    lanczos_phase_x_q9_o <= req_phase_x_q9;
                    lanczos_phase_y_q9_o <= req_phase_y_q9;
                    lanczos_window_pixels_o <= buf_window_pixels_i;
                    lanczos_window_valid_mask_o <= buf_window_valid_mask_i;
                    lanczos_block_row_last_o <= req_block_row_last;
                    lanczos_bypass_en_o <= req_bypass_en;
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
                    if (req_row_last_by_block) begin
                        // 下一个 dst_x 属于右侧 block。
                        next_edge_x <= req_dst_x + {{(DST_W-1){1'b0}}, 1'b1};
                    end
                    dst_x <= cur_edge_x;
                    dst_y <= req_dst_y + {{(DST_W-1){1'b0}}, 1'b1};
                end else begin
                    dst_x <= req_dst_x + {{(DST_W-1){1'b0}}, 1'b1};
                    dst_y <= req_dst_y;
                end
                sc_state <= SC_CALC;
            end

            SC_BLOCK_DONE: begin
                buf_block_scan_done_o <= 1'b1;

                // 到 frame 右边界时清除 x edge；y edge 在 block-row 末尾提交。
                if (buf_frame_right_i) begin
                    saved_edge_x <= {DST_W{1'b0}};
                    if (buf_frame_bottom_i) begin
                        saved_edge_y <= {DST_W{1'b0}};
                        next_edge_y <= {DST_W{1'b0}};
                    end else begin
                        saved_edge_y <= next_edge_y;
                    end
                end else begin
                    saved_edge_x <= next_edge_x;
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
