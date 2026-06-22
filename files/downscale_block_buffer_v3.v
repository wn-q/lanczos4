module pp_downscale_block_buffer (
    clk,
    rst_n,

    fg2pp_ctrl,
    ctrl_update_en,

    buf_clr,
    data_vld,
    data_rdy,
    data_in,

    block_lanczos_done,
    block_lanczos_row_last,

    lanczos_start,
    lanczos_x_end,
    lanczos_y_end
);

// ---------------------------------------------------------------------------
// Current scope:
//   1. frame_top block line_buffer receive / Lanczos handshake / writeback.
//   2. right_buffer save for frame_left or tile_left blocks.
//   3. Non-frame-top compute, right-side block readback, delayed overwrite,
//      bottom_buffer and corner_buffer are intentionally left for later.
// ---------------------------------------------------------------------------

parameter PIXEL_W          = 10;
parameter IN_PIX_PER_CYC  = 16;
parameter IMG_W            = 128;
parameter LINEBUF_ROWS     = 7;
parameter X_SAFE_COMMIT    = 9;
parameter X_KEEP_PIX       = 7;
parameter X_CALC_RIGHT_GAP = 4;
parameter RIGHT_COLS       = 7;
parameter BLOCK_MAX_H      = 32;

input clk;
input rst_n;

input [53:0] fg2pp_ctrl;   // block开始前更新的控制信息，包含尺寸、坐标、frame/tile边界
input        ctrl_update_en; // 控制信息锁存使能，通常在一个新block开始前拉高

input         buf_clr;
input         data_vld;
input [159:0] data_in;
output        data_rdy;

// block_lanczos_done: current cur16_reg segment has finished calculation.
// block_lanczos_row_last is kept for interface compatibility, but the module
// uses the locally latched calc_last_seg_in_row flag for writeback.
input         block_lanczos_done;
input         block_lanczos_row_last;

output        lanczos_start;
output [7:0]  lanczos_x_end;
output [6:0]  lanczos_y_end;

// ---------------------------------------------------------------------------
// Control registers from fg2pp_ctrl.
// ---------------------------------------------------------------------------
reg [6:0]  block_pixel_height; // 当前block高度，单位是像素行
reg [7:0]  block_pixel_width;  // 当前block宽度，单位是像素列
reg        frame_top_edge;     // 当前block位于整帧最上方，前7行需要先填line_buffer
reg        frame_bottom_edge;  // 当前block位于整帧最下方，后续bottom处理会用
reg        frame_left_edge;    // 当前block位于整帧最左侧，可直接生成给右侧block的right_buffer
reg        frame_right_edge;   // 当前block位于整帧最右侧，不需要在本地保存right_buffer
reg        tile_top_edge;      // 当前block位于tile顶部，后续tile跨界处理会用
reg        tile_bottom_edge;   // 当前block位于tile底部，后续tile跨界处理会用
reg        tile_left_edge;     // 当前block位于tile左侧，第一版也允许直接保存right_buffer
reg        tile_right_edge;    // 当前block位于tile右侧，右侧数据后续计划走DDR，不保存right_buffer
reg [12:0] block_start_x;      // 当前block左上角在整幅图中的x坐标
reg [12:0] block_start_y;      // 当前block左上角在整幅图中的y坐标
reg [1:0]  block64_loc;        // 当前block在superblock中的位置，当前buffer逻辑暂不使用
reg [1:0]  block_type;         // luma/chroma类型，当前buffer逻辑暂不使用
reg        picture_ready;      // 图像输入结束标志，当前buffer逻辑暂不使用

always @(posedge clk or negedge rst_n) begin
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
    end else if (ctrl_update_en) begin
        block_pixel_height <= fg2pp_ctrl[6:0];
        block_pixel_width  <= fg2pp_ctrl[14:7];
        frame_top_edge     <= fg2pp_ctrl[15];
        frame_bottom_edge  <= fg2pp_ctrl[16];
        frame_left_edge    <= fg2pp_ctrl[17];
        frame_right_edge   <= fg2pp_ctrl[18];
        tile_top_edge      <= fg2pp_ctrl[19];
        tile_bottom_edge   <= fg2pp_ctrl[20];
        tile_left_edge     <= fg2pp_ctrl[21];
        tile_right_edge    <= fg2pp_ctrl[22];
        block_start_x      <= fg2pp_ctrl[35:23];
        block_start_y      <= fg2pp_ctrl[48:36];
        block64_loc        <= fg2pp_ctrl[50:49];
        block_type         <= fg2pp_ctrl[52:51];
        picture_ready      <= fg2pp_ctrl[53];
    end
end

// ---------------------------------------------------------------------------
// Input unpack: data_in contains 16 pixels, 10 bits per pixel.
// ---------------------------------------------------------------------------
reg [PIXEL_W-1:0] pixel_in [0:IN_PIX_PER_CYC-1];
integer unpack_i;

always @(*) begin
    for (unpack_i = 0; unpack_i < IN_PIX_PER_CYC; unpack_i = unpack_i + 1) begin
        pixel_in[unpack_i] = data_in[unpack_i*PIXEL_W +: PIXEL_W];
    end
end

// ---------------------------------------------------------------------------
// Local receive counters.
// seg16_x: current 16-pixel segment index inside one block row.
// row_cnt: current source row index inside current block.
// ---------------------------------------------------------------------------
reg [3:0] seg16_x;
reg [6:0] row_cnt;
reg [3:0] cycles_per_row;

wire [7:0] cycles_per_row_calc;
wire       last_seg_in_row;
wire       last_row_in_block;
wire       block_recv_done;
wire       data_fire;

assign cycles_per_row_calc = (block_pixel_width + 8'd15) >> 4;
assign last_seg_in_row     = (seg16_x == (cycles_per_row - 1'b1));
assign last_row_in_block   = (row_cnt == (block_pixel_height - 1'b1));
assign block_recv_done     = data_fire && last_seg_in_row && last_row_in_block;

// ---------------------------------------------------------------------------
// Buffers.
// line_buffer stores 7 historical rows.
// cur16_reg stores the current 16-pixel segment being calculated.
// left7_reg stores the previous segment's x9~x15 until next segment consumes
// them.
// right_buffer stores the current block's right 7 columns for the right block.
// ---------------------------------------------------------------------------
reg [PIXEL_W-1:0] line_buffer  [0:LINEBUF_ROWS-1][0:IMG_W-1]; // 7行循环buffer，保存当前行上方的历史行
reg [PIXEL_W-1:0] cur16_reg    [0:IN_PIX_PER_CYC-1];          // 正在送给Lanczos计算的当前16像素段
reg [PIXEL_W-1:0] left7_reg    [0:X_KEEP_PIX-1];              // 上一个16像素段的x9~x15，等下一段算完后才能写回
reg [PIXEL_W-1:0] right_buffer [0:BLOCK_MAX_H-1][0:RIGHT_COLS-1]; // 当前block右7列，供右侧block做左边界计算

reg        lanczos_start_r;
reg [7:0]  calc_x_end;
reg [6:0]  calc_y_end;

assign lanczos_start = lanczos_start_r;
assign lanczos_x_end = calc_x_end;
assign lanczos_y_end = calc_y_end;

wire [7:0]  in_block_x_base;
wire [12:0] in_global_x_base;
wire [6:0]  linebuf_wr_row_mod;
wire [2:0]  linebuf_wr_row;
wire        frame_top_fill_linebuf;
wire        frame_top_calc_segment;
wire [7:0]  cur_segment_x_end;
wire [6:0]  cur_segment_y_end;
wire        right_save_en;
wire [12:0] right_base_x;

assign in_block_x_base   = {seg16_x, 4'b0000}; // 当前16像素段在block内部的x起点，seg16_x*16
assign in_global_x_base  = block_start_x + {5'd0, seg16_x, 4'b0000}; // 当前16像素段在整幅图中的x起点
assign linebuf_wr_row_mod= row_cnt % 7'd7; // line_buffer只有7行，row7覆盖row0，row8覆盖row1
assign linebuf_wr_row    = linebuf_wr_row_mod[2:0]; // 当前输入行将要写入/覆盖的line_buffer物理行号

assign frame_top_fill_linebuf = frame_top_edge && data_fire && (row_cnt < 7'd7); // frame顶部前7行只填历史buffer，不启动计算
assign frame_top_calc_segment = frame_top_edge && data_fire && (row_cnt >= 7'd7); // 第8行开始已有7行历史，可以启动Lanczos

assign cur_segment_x_end = last_seg_in_row ?
                           (block_pixel_width - 3'd4) :
                           (in_block_x_base + 4'd12);
assign cur_segment_y_end = row_cnt - 3'd4;

assign right_save_en = !frame_right_edge && !tile_right_edge;
assign right_base_x  = block_start_x + {5'd0, block_pixel_width} - 13'd7; // 当前block最右7列的全局起始x坐标

// Metadata of the segment currently stored in cur16_reg.
reg [7:0]  calc_block_x_base;      // 当前送算16像素段在block内部的x起点，用于判断写回是否超过block宽度
reg [12:0] calc_global_x_base;     // 当前送算16像素段在整幅图中的x起点，用于写line_buffer列地址
reg [2:0]  calc_linebuf_row;       // 当前送算行对应的line_buffer物理行，done回来后仍用这个快照写回
reg [6:0]  calc_row_cnt;           // 当前送算行在block内部的真实y行号，用于right_buffer行索引
reg        calc_first_seg_in_row;  // 当前段是否本行第一个16像素段，决定是否需要写回上一段left7
reg        calc_last_seg_in_row;   // 当前段是否本行最后一个16像素段，决定当前cur16能否全部写回
reg        calc_last_row_in_block; // 当前段是否属于block最后一行，决定是否进入right_buffer尾部flush

// right_buffer tail flush control.
reg [2:0] flush_idx;              // block结束后补存最后7行right_buffer，flush_idx表示第几行
wire [6:0] flush_row_cnt;         // flush阶段正在保存的block内部真实行号
wire [6:0] flush_linebuf_row_mod; // flush行在7行line_buffer中的物理行号取模结果
wire [2:0] flush_linebuf_row;     // flush阶段读取line_buffer的物理行号
wire [7:0] cur16_right_base_idx;  // 最后一行保存在cur16_reg中，这里是其右7列在cur16_reg里的起始索引

assign flush_row_cnt         = block_pixel_height - 7'd7 + {4'd0, flush_idx};
assign flush_linebuf_row_mod = flush_row_cnt % 7'd7;
assign flush_linebuf_row     = flush_linebuf_row_mod[2:0];
assign cur16_right_base_idx  = block_pixel_width - calc_block_x_base - 8'd7;

localparam [2:0] ST_IDLE         = 3'd0;
localparam [2:0] ST_RECV         = 3'd1;
localparam [2:0] ST_LANCZOS_BUSY = 3'd2;
localparam [2:0] ST_WRITEBACK    = 3'd3;
localparam [2:0] ST_FLUSH_RIGHT  = 3'd4;

reg [2:0] cur_state;
reg [2:0] nxt_state;

assign data_rdy  = (cur_state == ST_RECV);
assign data_fire = data_vld && data_rdy;

wire recv_linebuf_en;
wire latch_cur16_en;
wire writeback_en;
wire flush_right_en;
wire save_evict_right_en;
wire need_tail_flush;

assign recv_linebuf_en     = (cur_state == ST_RECV) && frame_top_fill_linebuf;
assign latch_cur16_en      = (cur_state == ST_RECV) && frame_top_calc_segment; //当前这拍输入的 16 个像素需要锁存到 cur16_reg，并且启动一次 Lanczos 计算。
assign writeback_en        = (cur_state == ST_WRITEBACK);    //Lanczos 已经算完，准备把 cur16_reg 写回 line_buffer
assign flush_right_en      = (cur_state == ST_FLUSH_RIGHT);
assign save_evict_right_en = writeback_en &&              //当 Lanczos 算完一行的最后一个16像素段，并且当前行会覆盖 line_buffer 里的某条旧历史行，并且当前 block 右边界需要保留，就把旧历史行的右7列保存到 right_buffer
                             right_save_en &&
                             calc_last_seg_in_row &&
                             (calc_row_cnt >= 7'd7);
assign need_tail_flush     = writeback_en &&
                             right_save_en &&
                             calc_last_seg_in_row &&
                             calc_last_row_in_block;

integer i_launch;
integer i_line;
integer i_right;

// ---------------------------------------------------------------------------
// FSM state register: only records which phase the block buffer is in.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_state <= ST_IDLE;
    end else if (buf_clr) begin
        cur_state <= ST_RECV;
    end else begin
        cur_state <= nxt_state;
    end
end

// ---------------------------------------------------------------------------
// FSM next-state logic: no buffer/register data movement here.
//状态机
// ---------------------------------------------------------------------------
always @(*) begin
    nxt_state = cur_state;

    case (cur_state)
        ST_IDLE: begin
            nxt_state = ST_IDLE;
        end

        ST_RECV: begin
            if (latch_cur16_en) begin
                nxt_state = ST_LANCZOS_BUSY;
            end else begin
                nxt_state = ST_RECV;
            end
        end

        ST_LANCZOS_BUSY: begin
            if (block_lanczos_done) begin
                nxt_state = ST_WRITEBACK;
            end
        end

        ST_WRITEBACK: begin
            if (need_tail_flush) begin
                nxt_state = ST_FLUSH_RIGHT;
            end else if (calc_last_seg_in_row && calc_last_row_in_block) begin
                nxt_state = ST_IDLE;
            end else begin
                nxt_state = ST_RECV;
            end
        end

        ST_FLUSH_RIGHT: begin
            if (flush_idx == 3'd6) begin
                nxt_state = ST_IDLE;
            end
        end

        default: begin
            nxt_state = ST_IDLE;
        end
    endcase
end

// ---------------------------------------------------------------------------
// Receive counters. They only advance when input is truly accepted.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        seg16_x <= 4'd0;
        row_cnt <= 7'd0;
        cycles_per_row <= 4'd0;
    end else if (buf_clr) begin
        seg16_x <= 4'd0;
        row_cnt <= 7'd0;
        cycles_per_row <= cycles_per_row_calc[3:0];
    end else if (data_fire) begin
        if (block_recv_done) begin
            seg16_x <= 4'd0;
            row_cnt <= 7'd0;
        end else if (last_seg_in_row) begin
            seg16_x <= 4'd0;
            row_cnt <= row_cnt + 1'b1;
        end else begin
            seg16_x <= seg16_x + 1'b1;        //计数当前16像素段在block内部的x起点，seg16_x*16和row_cnt一起可以唯一确定当前输入的16像素在block内部的坐标
        end
    end
end

// ---------------------------------------------------------------------------
// Lanczos launch and segment snapshot.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lanczos_start_r <= 1'b0;
        calc_x_end <= 8'd0;
        calc_y_end <= 7'd0;
        calc_block_x_base <= 8'd0;
        calc_global_x_base <= 13'd0;
        calc_linebuf_row <= 3'd0;
        calc_row_cnt <= 7'd0;
        calc_first_seg_in_row <= 1'b0;
        calc_last_seg_in_row <= 1'b0;
        calc_last_row_in_block <= 1'b0;
    end else begin
        lanczos_start_r <= 1'b0;

        if (latch_cur16_en) begin
            for (i_launch = 0; i_launch < IN_PIX_PER_CYC; i_launch = i_launch + 1) begin
                cur16_reg[i_launch] <= pixel_in[i_launch];
            end

            // 锁存当前16像素段的坐标快照。Lanczos done回来时，
            // row_cnt/seg16_x可能已经变化，写回必须使用这些快照。
            calc_block_x_base <= in_block_x_base;
            calc_global_x_base <= in_global_x_base;
            calc_linebuf_row <= linebuf_wr_row;
            calc_row_cnt <= row_cnt;
            calc_first_seg_in_row <= (seg16_x == 4'd0);
            calc_last_seg_in_row <= last_seg_in_row;
            calc_last_row_in_block <= last_row_in_block;
            calc_x_end <= cur_segment_x_end;
            calc_y_end <= cur_segment_y_end;

            lanczos_start_r <= 1'b1;   //可以开始计算lanczos
        end
    end
end

// ---------------------------------------------------------------------------
// line_buffer and left7_reg data path.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (recv_linebuf_en) begin
        for (i_line = 0; i_line < IN_PIX_PER_CYC; i_line = i_line + 1) begin
            if ((in_block_x_base + i_line) < block_pixel_width) begin
                line_buffer[linebuf_wr_row][in_global_x_base + i_line] <= pixel_in[i_line];
            end
        end
    end

    if (writeback_en) begin
        if (!calc_first_seg_in_row) begin
            for (i_line = 0; i_line < X_KEEP_PIX; i_line = i_line + 1) begin
                // 当前段已经用完上一段留下的右侧7个像素，此时可以安全写回line_buffer。
                line_buffer[calc_linebuf_row][calc_global_x_base - 13'd7 + i_line] <= left7_reg[i_line];
            end
        end

        if (calc_last_seg_in_row) begin
            for (i_line = 0; i_line < IN_PIX_PER_CYC; i_line = i_line + 1) begin
                if ((calc_block_x_base + i_line) < block_pixel_width) begin
                    //最后一个数据直接全部写回去
                    line_buffer[calc_linebuf_row][calc_global_x_base + i_line] <= cur16_reg[i_line];
                end
            end
        end else begin
            for (i_line = 0; i_line < X_SAFE_COMMIT; i_line = i_line + 1) begin
                if ((calc_block_x_base + i_line) < block_pixel_width) begin
                    // 非最后段只能写当前16像素段的前9个，后7个还要给下一段当左侧halo。
                    line_buffer[calc_linebuf_row][calc_global_x_base + i_line] <= cur16_reg[i_line];
                end
            end
                    //后7个像素先暂存在left7_reg，等下一段来时再写回line_buffer
            for (i_line = 0; i_line < X_KEEP_PIX; i_line = i_line + 1) begin
                left7_reg[i_line] <= cur16_reg[X_SAFE_COMMIT + i_line];
            end
        end
    end
end

// ---------------------------------------------------------------------------
// right_buffer data path and tail flush index.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        flush_idx <= 3'd0;
    end else if (buf_clr) begin
        flush_idx <= 3'd0;
    end else begin
        if (save_evict_right_en) begin
            // 本行最后一个16像素段算完时，当前输入行会覆盖line_buffer中的旧历史行。
            // 在覆盖前，先把这条旧历史行的右7列保存到right_buffer。
            for (i_right = 0; i_right < RIGHT_COLS; i_right = i_right + 1) begin
                right_buffer[calc_row_cnt - 7'd7][i_right] <= line_buffer[calc_linebuf_row][right_base_x + i_right];
            end
        end

        if (flush_right_en) begin
            // block结束时，最后7行还没有被后续输入行淘汰，所以需要额外flush到right_buffer。
            // flush_idx 0~5 从line_buffer读最后7行中的前6行；flush_idx 6 从cur16_reg读最后一行。
            if (flush_idx < 3'd6) begin
                for (i_right = 0; i_right < RIGHT_COLS; i_right = i_right + 1) begin
                    right_buffer[flush_row_cnt[4:0]][i_right] <= line_buffer[flush_linebuf_row][right_base_x + i_right];
                end
                flush_idx <= flush_idx + 1'b1;
            end else begin
                for (i_right = 0; i_right < RIGHT_COLS; i_right = i_right + 1) begin
                    right_buffer[flush_row_cnt[4:0]][i_right] <= cur16_reg[cur16_right_base_idx + i_right];
                end
                flush_idx <= 3'd0;
            end
        end
    end
end

endmodule
