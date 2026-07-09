module pp_downscale ( // downscale Lanczos4后处理顶层模块
    //inputs
    clk,rst_n,sw_pic_height,sw_upscale_width,fg2pp_ctrl_vld,fg2pp_ctrl,
    fg2pp_data_vld,fg2pp_data,pp_downscale_data_rdy,pp_downscale_ctrl_rdy,
    //outputs
    fg2pp_ctrl_rdy,fg2pp_data_rdy,pp_downscale_ctrl_out_vld,pp_downscale_ctrl_out,pp_downscale_data_vld,pp_downscale_data_out
);

input clk; // 模块工作时钟
input rst_n; // 低有效异步复位
input[12:0] sw_pic_height; // 源图像高度，后续边界clamp会用到
input[13:0] sw_upscale_width; // 源图像宽度，后续边界clamp会用到
input fg2pp_ctrl_vld; // 上游送来的block控制信息有效
input[53:0] fg2pp_ctrl; // block尺寸、坐标、边界等控制信息
input fg2pp_data_vld; // 上游16像素数据有效
input[159:0] fg2pp_data; // 一拍16个10bit像素，表示同一行连续16点
input pp_downscale_data_rdy; // 下游数据接收ready，后续输出反压使用
input pp_downscale_ctrl_rdy; // 下游控制接收ready，后续控制反压使用

output fg2pp_ctrl_rdy; // 本模块可接收新的block控制信息
output fg2pp_data_rdy; // 本模块可接收当前block像素数据
output pp_downscale_ctrl_out_vld; // 向下游输出控制信息有效
output[53:0] pp_downscale_ctrl_out; // 透传或重组后的输出控制信息
output pp_downscale_data_vld; // downscale输出数据有效
output[159:0] pp_downscale_data_out; // downscale后打包输出的16个10bit像素

// ---------------------------------------------------------------------------
// Downscale Lanczos4 framework
// ---------------------------------------------------------------------------
// Current assumptions used by this skeleton:
// 1. Input data is one source row segment per cycle.
//    fg2pp_data[159:0] contains 16 pixels, 10 bits per pixel.
// 2. Scale is configured as Q3.8, fractional precision is 1/256.
// 3. Source coordinate accumulator is Q?.9, fractional precision is 1/512.
// 4. Lanczos4 coefficient LUT uses 512 phases and 8 taps per phase.
// 5. This file is a framework. The real coefficient ROM, SRAM macros,
//    pending queue depth, and output packer should be refined later.
//
// Important note:
// The current module interface does not contain scale_x/scale_y or output
// width/height inputs. For now, localparams are used as placeholders. In the
// real design, these should come from software registers.

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
parameter PIXEL_W           = 10; // 单像素位宽，当前视频像素为10bit
parameter IN_PIX_PER_CYC   = 16; // 输入总线一拍包含16个像素
parameter BLOCK_MAX_W      = 32; // 当前框架按最大32像素block宽度规划局部缓存
parameter BLOCK_MAX_H      = 32; // 当前框架按最大32像素block高度规划局部缓存
parameter LANCZOS_TAPS     = 8; // Lanczos4半径为4，对应8个tap
parameter PHASE_NUM        = 512; // 坐标小数为1/512，因此LUT有512个相位
parameter COEF_W           = 16; // 每个Lanczos系数使用signed 16bit定点
parameter HACC_W           = 32; // 水平8tap乘加的累加位宽
parameter VACC_W           = 48; // 垂直8tap乘加的累加位宽
parameter X_LEFT_KEEP      = 7; // 跨16像素段计算时需要保留上一段最后7个像素
parameter X_SAFE_COMMIT    = 9; // 当前16像素段中可立即覆盖旧linebuf的前9个像素
parameter X_WIN_PIX        = 23; // 上一段7像素加当前16像素形成23像素横向窗口
parameter RIGHT_HALO_COLS  = 7; // 右边界需要保存7列，供右侧block到来后补算
parameter BOTTOM_HALO_ROWS = 7; // 下边界需要保存7行，供下方block到来后补算
parameter PENDING_DEPTH    = 32; // 最多暂存的未就绪输出点任务数量

// Placeholder configuration for 128 -> 42 example:
// real scale = 128 / 42 = 3.047619
// Q3.8 scale = round(3.047619 * 256) = 780
localparam [10:0] CFG_SCALE_X_Q8 = 11'd780; // 示例x方向scale，Q3.8格式，128到42时取780
localparam [10:0] CFG_SCALE_Y_Q8 = 11'd780; // 示例y方向scale，Q3.8格式，128到42时取780
localparam [12:0] CFG_DST_WIDTH  = 13'd42; // 示例输出宽度42，真实设计应由寄存器配置
localparam [12:0] CFG_DST_HEIGHT = 13'd42; // 示例输出高度42，真实设计应由寄存器配置

localparam [8:0] HALF_Q9 = 9'd256; // Q9坐标格式下0.5等于256

// ---------------------------------------------------------------------------
// FSM state encoding
// ---------------------------------------------------------------------------
localparam ST_IDLE       = 3'd0; // 等待新block控制信息
localparam ST_LOAD_CTRL  = 3'd1; // 锁存并解析当前block控制信息
localparam ST_RECV_BLOCK = 3'd2; // 接收当前block的一行16像素段数据
localparam ST_ISSUE_OUT  = 3'd3; // 遍历当前block拥有的输出点并发起滤波或pending
localparam ST_SAVE_HALO  = 3'd4; // block结束时保存右/下边界halo
localparam ST_FLUSH      = 3'd5; // 图像结束后清理剩余pending任务

reg [2:0] cur_state; // 当前FSM状态
reg [2:0] nxt_state; // 组合逻辑计算出的下一FSM状态

// ---------------------------------------------------------------------------
// Control parsing registers
// ---------------------------------------------------------------------------
reg [6:0]  block_pixel_height; // 当前block的像素高度
reg [7:0]  block_pixel_width; // 当前block的像素宽度
reg        frame_top_edge; // 当前block是否位于整帧顶部
reg        frame_bottom_edge; // 当前block是否位于整帧底部
reg        frame_left_edge; // 当前block是否位于整帧最左侧
reg        frame_right_edge; // 当前block是否位于整帧最右侧
reg        tile_top_edge; // 当前block是否位于tile顶部
reg        tile_bottom_edge; // 当前block是否位于tile底部
reg        tile_left_edge; // 当前block是否位于tile左侧
reg        tile_right_edge; // 当前block是否位于tile右侧
reg [12:0] block_start_x; // 当前block左上角源图x坐标
reg [12:0] block_start_y; // 当前block左上角源图y坐标
reg [1:0]  block64_loc; // 当前block在64/128 superblock中的位置
reg [1:0]  block_type; // luma或interleave chroma类型
reg        picture_ready; // 当前图像输入结束标志

reg [53:0] ctrl_out_hold; // 暂存当前block控制信息，后续可透传给下游

// ---------------------------------------------------------------------------
// Input block counters
// One cycle contains 16 pixels from the same source row.
// For a 32x32 block, cycles_per_row = 2 and total cycles = 64.
// ---------------------------------------------------------------------------
reg [3:0]  seg16_x; // 当前行内第几个16像素段
reg [6:0]  row_cnt; // 当前block内第几行
reg [3:0]  cycles_per_row; // 当前block每行需要接收多少个16像素段
wire       recv_fire; // valid和ready同时为1时表示本拍真正接收数据
wire       last_seg_in_row; // 当前16像素段是否为本行最后一段
wire       last_row_in_block; // 当前输入行是否为本block最后一行
wire       block_recv_done; // 当前block最后一拍数据接收完成
wire [7:0] cycles_per_row_calc; // 由block宽度计算ceil(width/16)

assign recv_fire         = (cur_state == ST_RECV_BLOCK) && fg2pp_data_vld && fg2pp_data_rdy; // 只有接收状态且valid/ready同时为1才真正收数
assign last_seg_in_row   = (seg16_x == (cycles_per_row - 1'b1)); // seg16_x到达本行最后一个16像素段
assign last_row_in_block = (row_cnt == (block_pixel_height - 1'b1)); // row_cnt到达当前block最后一行
assign block_recv_done   = recv_fire && last_seg_in_row && last_row_in_block; // 最后一行最后一段握手成功，block接收结束
assign cycles_per_row_calc = (fg2pp_ctrl[14:7] + 8'd15) >> 4; // 用(width+15)>>4实现ceil(width/16)

// ---------------------------------------------------------------------------
// Scale and coordinate generation
// scale_q8:  Q3.8, step is 1/256.
// coord_q9:  Q?.9, step is 1/512.
//
// x_step_q9  = scale_x_q8 << 1
// x_start_q9 = scale_x_q8 - 256
// src_x_q9   = x_start_q9 + dst_x * x_step_q9
// ---------------------------------------------------------------------------
wire [11:0] scale_x_step_q9; // x方向每输出一个点时源坐标增加的Q9步长
wire [11:0] scale_y_step_q9; // y方向每输出一行时源坐标增加的Q9步长
wire signed [13:0] src_x_start_q9; // 输出第0列对应的Q9源x起点
wire signed [13:0] src_y_start_q9; // 输出第0行对应的Q9源y起点

assign scale_x_step_q9 = {CFG_SCALE_X_Q8, 1'b0}; // Q3.8 scale左移一位变成Q9坐标步长
assign scale_y_step_q9 = {CFG_SCALE_Y_Q8, 1'b0}; // Q3.8 scale左移一位变成Q9坐标步长
assign src_x_start_q9  = $signed({3'b0, CFG_SCALE_X_Q8}) - $signed({5'b0, HALF_Q9}); // 计算scale*0.5-0.5的x方向中心对齐起点
assign src_y_start_q9  = $signed({3'b0, CFG_SCALE_Y_Q8}) - $signed({5'b0, HALF_Q9}); // 计算scale*0.5-0.5的y方向中心对齐起点

// Current source write coordinate for incoming 16-pixel segment.
wire [12:0] in_base_x; // 当前输入16像素段的源图起始x坐标
wire [12:0] in_y; // 当前输入段所在的源图y坐标

assign in_base_x = block_start_x + {5'd0, seg16_x, 4'b0000}; // block起始x加seg16_x*16得到本拍起始x
assign in_y      = block_start_y + {6'd0, row_cnt}; // block起始y加row_cnt得到本拍源行y

// ---------------------------------------------------------------------------
// Input unpack
// pixel_in[0] is fg2pp_data[9:0], pixel_in[15] is fg2pp_data[159:150].
// ---------------------------------------------------------------------------
reg [PIXEL_W-1:0] pixel_in [0:IN_PIX_PER_CYC-1]; // 从160bit总线拆出的16个10bit像素
integer unpack_i; // 拆分fg2pp_data时使用的循环索引

always @(*) begin
    for (unpack_i = 0; unpack_i < IN_PIX_PER_CYC; unpack_i = unpack_i + 1) begin
        pixel_in[unpack_i] = fg2pp_data[unpack_i*PIXEL_W +: PIXEL_W]; // 从160bit输入总线按10bit切出第unpack_i个像素
    end
end

wire [12:0] pixel_wr_x [0:IN_PIX_PER_CYC-1]; // 当前16个像素各自在源图中的真实x坐标
wire [6:0]  pixel_wr_x_idx [0:IN_PIX_PER_CYC-1]; // 当前demo 128宽linebuf使用的7bit列地址
wire [12:0] prev_left7_wr_x [0:X_LEFT_KEEP-1]; // 上一段保留7像素对应的真实x坐标
wire [6:0]  prev_left7_wr_x_idx [0:X_LEFT_KEEP-1]; // 上一段保留7像素写回linebuf时的列地址
genvar gi_wr_x; // 展开16个像素写地址计算的generate索引
generate
    for (gi_wr_x = 0; gi_wr_x < IN_PIX_PER_CYC; gi_wr_x = gi_wr_x + 1) begin : GEN_WR_X
        localparam [12:0] WR_X_OFFSET = gi_wr_x; // 当前像素相对本16像素段起点的偏移
        assign pixel_wr_x[gi_wr_x] = in_base_x + WR_X_OFFSET; // 本拍第i个像素写入x为in_base_x+i
        assign pixel_wr_x_idx[gi_wr_x] = pixel_wr_x[gi_wr_x][6:0]; // 当前demo仅128列，取低7位作为linebuf列地址
    end
endgenerate

genvar gi_left7_x; // 展开7个left7写回地址计算的generate索引
generate
    for (gi_left7_x = 0; gi_left7_x < X_LEFT_KEEP; gi_left7_x = gi_left7_x + 1) begin : GEN_LEFT7_WR_X
        localparam [12:0] LEFT7_OFFSET = gi_left7_x; // left7像素相对写回起点的偏移
        assign prev_left7_wr_x[gi_left7_x] = in_base_x - 13'd7 + LEFT7_OFFSET; // 当前段起点减7得到上一段x9到x15的写回地址
        assign prev_left7_wr_x_idx[gi_left7_x] = prev_left7_wr_x[gi_left7_x][6:0]; // left7写回demo linebuf时取低7位列地址
    end
endgenerate

// ---------------------------------------------------------------------------
// Small demo line buffer placeholder
// Real implementation should replace this with SRAM macros sized for
// sw_upscale_width and enough line history / valid tags.
//
// The horizontal 8-tap window cannot discard all 16 pixels after one cycle.
// For the next 16-pixel segment, the previous segment's last 7 pixels are
// still needed:
//
//   old segment : x0  ... x8  x9 ... x15
//   next segment: x16 ... x31
//
// For src_x_int = 12, taps are x9...x16. Therefore x9...x15 must be kept.
// This is implemented as:
//
//   left7_reg[0:6] = previous segment x9...x15
//   x_win23[7:22] = current segment x_base...x_base+15
//   x_win23[0:22] = {left7_reg, current 16 pixels}
//
// A real design should make this context per active source row when several
// rows are interleaved. In this simplified block-row stream, one left7 context
// is enough to show the mechanism.
// ---------------------------------------------------------------------------
//三个buffer，右边界，下边界和当前block前7行历史像素buffer
reg [PIXEL_W-1:0] linebuf [0:6][0:127]; // 7行历史像素buffer，保存当前行之前的7行数据
reg [PIXEL_W-1:0] left7_reg [0:X_LEFT_KEEP-1]; // 保存上一段x9到x15，供下一段跨segment取tap
reg [PIXEL_W-1:0] x_win23   [0:X_WIN_PIX-1]; // 由left7和当前16像素拼成的横向23像素取数窗口
reg [PIXEL_W-1:0] right_buffer  [0:BLOCK_MAX_H-1][0:RIGHT_HALO_COLS-1]; // 按行保存左侧/当前block右侧7列像素
reg [PIXEL_W-1:0] bottom_buffer [0:BOTTOM_HALO_ROWS-1][0:127]; // 保存当前block底部7行像素，demo宽度暂定128

integer wr_i; // 写入linebuf时的循环索引
integer win_i; // 构造x_win23和left7更新时的循环索引
wire [2:0] linebuf_wr_row; // 7行linebuf实际写入行号
wire [12:0] linebuf_wr_row_mod; // 当前源图y坐标对7取模后的写行号
wire linebuf_full; // in_y>=7表示历史7行已经具备，需要延迟覆盖旧行
wire [6:0] bottom_buffer_start_row; // 当前block底部7行在block内的起始行号
wire [6:0] bottom_buffer_row_delta; // 当前底部行相对bottom_buffer起始行的偏移
wire [2:0] bottom_buffer_wr_row; // 当前输入行写入bottom_buffer的行号
wire       bottom_buffer_row_vld; // 当前输入行是否属于block底部7行

assign linebuf_wr_row_mod = in_y % 13'd7; // 7行循环缓存用源y对7取模
assign linebuf_wr_row     = linebuf_wr_row_mod[2:0]; // 模7结果作为linebuf写行地址
assign linebuf_full       = (in_y >= 13'd7); // 前7行可直接写，第8行开始需要保护旧行后7个像素
assign bottom_buffer_start_row = block_pixel_height - 7'd7; // bottom_buffer保存block最后7行
assign bottom_buffer_row_vld   = (row_cnt >= bottom_buffer_start_row); // 当前行落在block底部7行时需要保存
assign bottom_buffer_row_delta = row_cnt - bottom_buffer_start_row; // 计算当前行在底部7行中的相对位置
assign bottom_buffer_wr_row    = bottom_buffer_row_delta[2:0]; // bottom_buffer内部行号0~6

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // SRAM contents are intentionally not reset in real hardware.
    end else if (recv_fire) begin
        // Build a 23-pixel x window for horizontal Lanczos4.
        // First segment in a row has no previous segment. At frame-left,
        // do not inject clamp pixels here. Frame/tile clamp should be handled
        // by the tap address/select logic when the filter is issued.
        for (win_i = 0; win_i < X_LEFT_KEEP; win_i = win_i + 1) begin
            if (seg16_x == 4'd0) begin
                if (frame_left_edge) begin
                    x_win23[win_i] <= {PIXEL_W{1'b0}}; // frame左边界的左侧tap后续由tap选择逻辑clamp到边界像素，这里只清零占位避免误用
                end else begin
                    x_win23[win_i] <= right_buffer[row_cnt[4:0]][win_i]; // 新行首段且不是frame左边界时，使用左侧block保存的右边界7像素
                end
            end else begin
                x_win23[win_i] <= left7_reg[win_i]; // 把上一段保留的7个像素放到当前23像素窗口左侧
            end
        end

        for (win_i = 0; win_i < IN_PIX_PER_CYC; win_i = win_i + 1) begin
            x_win23[X_LEFT_KEEP + win_i] <= pixel_in[win_i]; // 把当前16个像素接到23像素窗口右侧
        end

        // Save current segment x9...x15 for the next segment.
        for (win_i = 0; win_i < X_LEFT_KEEP; win_i = win_i + 1) begin
            left7_reg[win_i] <= pixel_in[9 + win_i]; // 保存当前段x9到x15，下一段计算x12等跨段tap时使用
        end

        if (!linebuf_full) begin
            // Before 7 source rows are stored, no old history row is being
            // overwritten. The whole current segment can be written directly.
            for (wr_i = 0; wr_i < IN_PIX_PER_CYC; wr_i = wr_i + 1) begin
                if (pixel_wr_x[wr_i] < 13'd128) begin
                    linebuf[linebuf_wr_row][pixel_wr_x_idx[wr_i]] <= pixel_in[wr_i]; // linebuf未满前直接写入当前16像素段
                end
            end
        end else begin
            // Once linebuf is full, the target line still contains old source
            // pixels needed by the current vertical 8-tap calculation. Commit
            // only the portion proven safe after this segment is calculated.
            //
            // In a pipelined MAC, these writes should be gated by the real
            // segment_calc_done signal. This skeleton ties commit to recv_fire.
            if (seg16_x != 4'd0) begin
                for (win_i = 0; win_i < X_LEFT_KEEP; win_i = win_i + 1) begin
                    if (prev_left7_wr_x[win_i] < 13'd128) begin
                        linebuf[linebuf_wr_row][prev_left7_wr_x_idx[win_i]] <= left7_reg[win_i]; // 下一段到来后，上一段保留的x9到x15已经安全，可补写回linebuf
                    end
                end
            end

            for (wr_i = 0; wr_i < X_SAFE_COMMIT; wr_i = wr_i + 1) begin
                if (pixel_wr_x[wr_i] < 13'd128) begin
                    linebuf[linebuf_wr_row][pixel_wr_x_idx[wr_i]] <= pixel_in[wr_i]; // 前7行尚未覆盖旧数据时，当前16像素可直接写入linebuf
                end
            end

            if (last_seg_in_row) begin
                for (win_i = 0; win_i < X_LEFT_KEEP; win_i = win_i + 1) begin
                    if (pixel_wr_x[X_SAFE_COMMIT + win_i] < 13'd128) begin
                        linebuf[linebuf_wr_row][pixel_wr_x_idx[X_SAFE_COMMIT + win_i]] <= pixel_in[X_SAFE_COMMIT + win_i]; // 行尾没有下一段需要旧数据，flush当前段最后7个像素到linebuf
                    end
                end
            end
        end

        if(last_seg_in_row) begin
            if(frame_left_edge) begin
                for (wr_i = 0; wr_i < RIGHT_HALO_COLS; wr_i = wr_i + 1) begin
                   right_buffer[row_cnt[4:0]][win_i] <= pixel_in[9 + win_i]; // frame左边界的右侧tap后续由tap选择逻辑clamp到边界像素，这里只清零占位避免误用
                end
            end else if (frame_right_edge) begin
                for (wr_i = 0; wr_i < RIGHT_HALO_COLS; wr_i = wr_i + 1) begin
                   right_buffer[row_cnt[4:0]][win_i] <= {PIXEL_W{1'b0}}; // frame右边界的右侧tap后续由tap选择逻辑clamp到边界像素，这里只清零占位避免误用
                end
            end else begin                                              //如果在block中间，那么需要等到计算完相应的点再更新
                right_buffer_update_pending[row_cnt[4:0]] <= 1'b1;

                for (win_i = 0; win_i < X_LEFT_KEEP; win_i = win_i + 1) begin
                    right_buffer_update_data[row_cnt[4:0]][win_i] <= pixel_in[9 + win_i];
                end
            end
        end

        if (right_lanczos_row_done && right_buffer_update_pending[right_lanczos_done_row]) begin              //占位，后续完善
            for (win_i = 0; win_i < X_LEFT_KEEP; win_i = win_i + 1) begin
                right_buffer[right_lanczos_done_row][win_i]
                    <= right_buffer_update_data[right_lanczos_done_row][win_i];
            end

            right_buffer_update_pending[right_lanczos_done_row] <= 1'b0;
        end



        if (bottom_buffer_row_vld) begin
            for (wr_i = 0; wr_i < IN_PIX_PER_CYC; wr_i = wr_i + 1) begin
                if (pixel_wr_x[wr_i] < 13'd128) begin
                    bottom_buffer[bottom_buffer_wr_row][pixel_wr_x_idx[wr_i]] <= pixel_in[wr_i]; // 当前行属于block底部7行时，保存到bottom_buffer供下一行block使用
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Right and bottom boundary buffers
// right_buffer stores the current/previous block's right 7 columns.
// bottom_buffer stores the current block's bottom 7 rows.
// These raw pixels are used later when pending points are completed by neighbor block data. // 保存边界像素，等邻居block到来后补算pending点
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Pending task queue
// A task records one output pixel that belongs to this block but cannot be
// calculated yet because at least one Lanczos4 tap needs a future neighbor.
// ---------------------------------------------------------------------------
reg                  pend_valid   [0:PENDING_DEPTH-1]; // 每条pending任务是否有效
reg [12:0]           pend_dst_x   [0:PENDING_DEPTH-1]; // pending点最终输出x坐标
reg [12:0]           pend_dst_y   [0:PENDING_DEPTH-1]; // pending点最终输出y坐标
reg [12:0]           pend_src_x_i [0:PENDING_DEPTH-1]; // pending点对应源x整数坐标
reg [8:0]            pend_phase_x [0:PENDING_DEPTH-1]; // pending点对应x方向512相位
reg [12:0]           pend_src_y_i [0:PENDING_DEPTH-1]; // pending点对应源y整数坐标
reg [8:0]            pend_phase_y [0:PENDING_DEPTH-1]; // pending点对应y方向512相位
reg [1:0]            pend_type    [0:PENDING_DEPTH-1]; // 记录pending缺右侧、下方还是右下角数据
reg [4:0]            pend_wr_ptr; // pending任务写入指针
reg [4:0]            pend_rd_ptr; // pending任务读取指针，后续补算使用

localparam PEND_RIGHT  = 2'd1; // 输出点缺右侧block像素
localparam PEND_BOTTOM = 2'd2; // 输出点缺下方block像素
localparam PEND_CORNER = 2'd3; // 输出点同时缺右侧和下方/右下像素

// ---------------------------------------------------------------------------
// Owned output range for current block
// A block owns an output point when floor(src_x) and floor(src_y) fall inside
// the source block range. Some owned points still become pending.
// For clarity this skeleton computes/runs ranges sequentially. Division logic
// is left as a TODO because the production design may use firmware-precomputed
// ranges or a small divider.
// ---------------------------------------------------------------------------
reg [12:0] dst_x_first; // 当前block负责的第一个输出x，后续用精确范围计算替换
reg [12:0] dst_x_last; // 当前block负责的最后一个输出x，后续用精确范围计算替换
reg [12:0] dst_y_first; // 当前block负责的第一个输出y，后续用精确范围计算替换
reg [12:0] dst_y_last; // 当前block负责的最后一个输出y，后续用精确范围计算替换

reg [12:0] cur_dst_x; // 当前正在遍历/计算的输出x坐标
reg [12:0] cur_dst_y; // 当前正在遍历/计算的输出y坐标
reg signed [22:0] cur_src_x_q9; // cur_dst_x反推得到的Q9源x坐标
reg signed [22:0] cur_src_y_q9; // cur_dst_y反推得到的Q9源y坐标

wire [12:0] cur_src_x_int; // 源x坐标整数部分，用来定位8tap中心
wire [12:0] cur_src_y_int; // 源y坐标整数部分，用来定位8tap中心
wire [8:0]  cur_phase_x; // 源x坐标小数部分，作为512相位LUT地址
wire [8:0]  cur_phase_y; // 源y坐标小数部分，作为512相位LUT地址

assign cur_src_x_int = cur_src_x_q9[21:9]; // Q9源x坐标右移9位得到整数部分
assign cur_src_y_int = cur_src_y_q9[21:9]; // Q9源y坐标右移9位得到整数部分
assign cur_phase_x   = cur_src_x_q9[8:0]; // Q9源x低9位直接作为512相位
assign cur_phase_y   = cur_src_y_q9[8:0]; // Q9源y低9位直接作为512相位

wire [12:0] block_x1; // 当前block最右侧源x坐标
wire [12:0] block_y1; // 当前block最下侧源y坐标
wire        need_right_block; // 当前输出点横向8tap是否需要右侧block像素
wire        need_bottom_block; // 当前输出点纵向8tap是否需要下方block像素
wire        output_window_ready; // 当前输出点所需邻域是否已在本block/缓存中

assign block_x1 = block_start_x + {5'd0, block_pixel_width}  - 13'd1; // block_start_x加宽度减1得到右边界
assign block_y1 = block_start_y + {6'd0, block_pixel_height} - 13'd1; // block_start_y加高度减1得到下边界

// A point needs the right neighbor if src_x_int + 4 crosses the block right
// edge. Frame edge can be handled by clamp, so it does not need a neighbor.
assign need_right_block  = (!frame_right_edge)  && (cur_src_x_int > (block_x1 - 13'd4)); // src_x_int大于block_x1-4说明右侧tap跨block
assign need_bottom_block = (!frame_bottom_edge) && (cur_src_y_int > (block_y1 - 13'd4)); // src_y_int大于block_y1-4说明下方tap跨block

// This is the high-level ready decision. The actual design also needs valid
// tags for linebuf/halo pixels and tile-edge policy checks.
assign output_window_ready = !need_right_block && !need_bottom_block; // 不缺右侧/下方block时当前点可进入滤波

// ---------------------------------------------------------------------------
// Lanczos4 coefficient LUT placeholder
// lut512[phase][tap], each coefficient is signed Q2.14.
// TODO: initialize from generated ROM values.
// ---------------------------------------------------------------------------
reg signed [COEF_W-1:0] lut512 [0:PHASE_NUM-1][0:LANCZOS_TAPS-1]; // 512相位、每相位8tap的Lanczos4系数表占位
reg signed [COEF_W-1:0] coef_x [0:LANCZOS_TAPS-1]; // 当前输出点x方向8个Lanczos系数
reg signed [COEF_W-1:0] coef_y [0:LANCZOS_TAPS-1]; // 当前输出点y方向8个Lanczos系数
integer coef_i; // 读取8个x/y系数时的循环索引

always @(*) begin
    for (coef_i = 0; coef_i < LANCZOS_TAPS; coef_i = coef_i + 1) begin
        coef_x[coef_i] = lut512[cur_phase_x][coef_i]; // 根据x相位从512相位LUT读取第coef_i个水平系数
        coef_y[coef_i] = lut512[cur_phase_y][coef_i]; // 根据y相位从512相位LUT读取第coef_i个垂直系数
    end
end

// ---------------------------------------------------------------------------
// Filter datapath placeholders
// TODO:
// 1. Read 8 x taps for each of 8 source rows.
// 2. Do horizontal 8-tap MAC to produce 8 hsum values.
// 3. Do vertical 8-tap MAC.
// 4. Round and clip to 10-bit output pixel.
// ---------------------------------------------------------------------------
reg signed [HACC_W-1:0] h_acc [0:LANCZOS_TAPS-1]; // 水平8tap MAC结果数组占位
reg signed [VACC_W-1:0] v_acc; // 垂直8tap MAC累加结果占位
reg [PIXEL_W-1:0]       filtered_pixel; // round/clip后的10bit输出像素占位
reg                     filter_out_vld; // 滤波pipeline输出有效占位信号

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        filter_out_vld <= 1'b0; // 默认本拍没有滤波输出
        filtered_pixel <= {PIXEL_W{1'b0}}; // MAC尚未接入，输出像素暂时置0
    end else begin
        filter_out_vld <= 1'b0; // 默认本拍没有滤波输出
        if ((cur_state == ST_ISSUE_OUT) && output_window_ready) begin
            // Placeholder until the real MAC pipeline is connected.
            filter_out_vld <= 1'b1; // 当前输出点窗口就绪，产生一个滤波输出占位
            filtered_pixel <= {PIXEL_W{1'b0}}; // MAC尚未接入，输出像素暂时置0
        end
    end
end

// ---------------------------------------------------------------------------
// Interface ready/valid
// ---------------------------------------------------------------------------
assign fg2pp_ctrl_rdy = (cur_state == ST_IDLE); // 空闲状态才接收新的block控制
assign fg2pp_data_rdy = (cur_state == ST_RECV_BLOCK); // RECV_BLOCK状态才接收像素数据

assign pp_downscale_ctrl_out_vld = (cur_state == ST_LOAD_CTRL); // LOAD_CTRL阶段向下游发出控制有效
assign pp_downscale_ctrl_out     = ctrl_out_hold; // 输出锁存后的block控制信息

assign pp_downscale_data_vld = filter_out_vld; // 滤波结果有效时输出数据有效
assign pp_downscale_data_out = {16{filtered_pixel}}; // 当前占位实现把同一个像素复制成16像素输出

// ---------------------------------------------------------------------------
// FSM sequential
// ---------------------------------------------------------------------------
integer pi; // 复位pending队列时使用的循环索引

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_state <= ST_IDLE; // 复位后FSM回到空闲
    end else begin
        cur_state <= nxt_state; // 每拍更新FSM状态
    end
end

// ---------------------------------------------------------------------------
// FSM combinational
// ---------------------------------------------------------------------------
always @(*) begin
    nxt_state = cur_state; // 默认保持当前FSM状态
    case (cur_state)
        ST_IDLE: begin
            if (fg2pp_ctrl_vld) begin
                nxt_state = ST_LOAD_CTRL; // 收到ctrl后进入控制锁存状态
            end
        end

        ST_LOAD_CTRL: begin
            nxt_state = ST_RECV_BLOCK; // 控制锁存完成后开始接收block像素
        end

        ST_RECV_BLOCK: begin
            if (block_recv_done) begin
                nxt_state = ST_ISSUE_OUT; // block数据收完后开始遍历输出点
            end
        end

        ST_ISSUE_OUT: begin
            if ((cur_dst_y > dst_y_last) || (dst_y_first > dst_y_last)) begin
                nxt_state = ST_SAVE_HALO; // 当前block输出遍历完成后保存边界halo
            end
        end

        ST_SAVE_HALO: begin
            if (picture_ready) begin
                nxt_state = ST_FLUSH; // picture_ready时进入图像收尾flush
            end else begin
                nxt_state = ST_IDLE; // 当前流程结束后回到空闲等待下一block
            end
        end

        ST_FLUSH: begin
            // TODO: drain pending queue after picture_ready.
            nxt_state = ST_IDLE; // 当前流程结束后回到空闲等待下一block
        end

        default: begin
            nxt_state = ST_IDLE; // 当前流程结束后回到空闲等待下一block
        end
    endcase
end

// ---------------------------------------------------------------------------
// Control load and input counters
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        block_pixel_height <= 7'd0;
        block_pixel_width  <= 8'd0;
        frame_top_edge     <= 1'b0; // 锁存frame顶部边界标志
        frame_bottom_edge  <= 1'b0; // 锁存frame底部边界标志
        frame_left_edge    <= 1'b0; // 锁存frame左边界标志
        frame_right_edge   <= 1'b0; // 锁存frame右边界标志
        tile_top_edge      <= 1'b0; // 锁存tile顶部边界标志
        tile_bottom_edge   <= 1'b0; // 锁存tile底部边界标志
        tile_left_edge     <= 1'b0; // 锁存tile左边界标志
        tile_right_edge    <= 1'b0; // 锁存tile右边界标志
        block_start_x      <= 13'd0; // 锁存当前block起始x坐标
        block_start_y      <= 13'd0; // 锁存当前block起始y坐标
        block64_loc        <= 2'd0; // 锁存block64位置字段
        block_type         <= 2'd0; // 锁存luma/chroma类型字段
        picture_ready      <= 1'b0; // 锁存图像结束标志
        ctrl_out_hold      <= 54'd0;
        cycles_per_row     <= 4'd0;
        seg16_x            <= 4'd0; // 新block或行结束时段计数清零
        row_cnt            <= 7'd0; // 新block开始时行计数清零
    end else begin
        if ((cur_state == ST_IDLE) && fg2pp_ctrl_vld && fg2pp_ctrl_rdy) begin
            block_pixel_height <= fg2pp_ctrl[6:0]; // 从ctrl中锁存当前block高度
            block_pixel_width  <= fg2pp_ctrl[14:7]; // 从ctrl中锁存当前block宽度
            frame_top_edge     <= fg2pp_ctrl[15]; // 锁存frame顶部边界标志
            frame_bottom_edge  <= fg2pp_ctrl[16]; // 锁存frame底部边界标志
            frame_left_edge    <= fg2pp_ctrl[17]; // 锁存frame左边界标志
            frame_right_edge   <= fg2pp_ctrl[18]; // 锁存frame右边界标志
            tile_top_edge      <= fg2pp_ctrl[19]; // 锁存tile顶部边界标志
            tile_bottom_edge   <= fg2pp_ctrl[20]; // 锁存tile底部边界标志
            tile_left_edge     <= fg2pp_ctrl[21]; // 锁存tile左边界标志
            tile_right_edge    <= fg2pp_ctrl[22]; // 锁存tile右边界标志
            block_start_x      <= fg2pp_ctrl[35:23]; // 锁存当前block起始x坐标
            block_start_y      <= fg2pp_ctrl[48:36]; // 锁存当前block起始y坐标
            block64_loc        <= fg2pp_ctrl[50:49]; // 锁存block64位置字段
            block_type         <= fg2pp_ctrl[52:51]; // 锁存luma/chroma类型字段
            picture_ready      <= fg2pp_ctrl[53]; // 锁存图像结束标志
            ctrl_out_hold      <= fg2pp_ctrl; // 保存当前ctrl用于后续输出

            // ceil(block_pixel_width / 16)
            cycles_per_row <= cycles_per_row_calc[3:0]; // 锁存当前block每行需要的16像素段数量
            seg16_x        <= 4'd0; // 新block或行结束时段计数清零
            row_cnt        <= 7'd0; // 新block开始时行计数清零
        end else if (recv_fire) begin
            if (last_seg_in_row) begin
                seg16_x <= 4'd0; // 新block或行结束时段计数清零
                row_cnt <= row_cnt + 1'b1; // 当前行最后一段接收后切到下一行
            end else begin
                seg16_x <= seg16_x + 1'b1; // 当前行继续接收下一个16像素段
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Output range setup and traversal
// TODO: Replace the simple demo ranges with exact formulas:
// dst_x_first = ceil((block_x0*512 - x_start_q9) / x_step_q9)
// dst_x_last  = floor(((block_x1+1)*512 - 1 - x_start_q9) / x_step_q9)
// Same for y.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dst_x_first   <= 13'd0; // 示例中从输出第0列开始遍历
        dst_x_last    <= 13'd0;
        dst_y_first   <= 13'd0; // 示例中从输出第0行开始遍历
        dst_y_last    <= 13'd0;
        cur_dst_x     <= 13'd0; // 输出x遍历计数清零
        cur_dst_y     <= 13'd0; // 输出y遍历计数清零
        cur_src_x_q9  <= 23'sd0;
        cur_src_y_q9  <= 23'sd0;
    end else if (cur_state == ST_LOAD_CTRL) begin
        // Demo range for framework bring-up: scan all dst points.
        // Production RTL should compute the range owned by this block.
        dst_x_first  <= 13'd0; // 示例中从输出第0列开始遍历
        dst_x_last   <= CFG_DST_WIDTH - 1'b1; // 示例中遍历到输出最后一列
        dst_y_first  <= 13'd0; // 示例中从输出第0行开始遍历
        dst_y_last   <= CFG_DST_HEIGHT - 1'b1; // 示例中遍历到输出最后一行

        cur_dst_x    <= 13'd0; // 输出x遍历计数清零
        cur_dst_y    <= 13'd0; // 输出y遍历计数清零
        cur_src_x_q9 <= {{9{src_x_start_q9[13]}}, src_x_start_q9}; // 每行开始时源x坐标回到中心对齐起点
        cur_src_y_q9 <= {{9{src_y_start_q9[13]}}, src_y_start_q9}; // 输出首行源y坐标设置为中心对齐起点
    end else if (cur_state == ST_ISSUE_OUT) begin
        if (cur_dst_y <= dst_y_last) begin
            if (cur_dst_x < dst_x_last) begin
                cur_dst_x    <= cur_dst_x + 1'b1; // 遍历到下一个输出列
                cur_src_x_q9 <= cur_src_x_q9 + $signed({11'd0, scale_x_step_q9}); // 输出x前进一步，源x坐标累加scale步长
            end else begin
                cur_dst_x    <= dst_x_first; // 当前输出行结束后x回到本block首列
                cur_dst_y    <= cur_dst_y + 1'b1; // 切换到下一输出行
                cur_src_x_q9 <= {{9{src_x_start_q9[13]}}, src_x_start_q9}; // 每行开始时源x坐标回到中心对齐起点
                cur_src_y_q9 <= cur_src_y_q9 + $signed({11'd0, scale_y_step_q9}); // 输出y前进一步，源y坐标累加scale步长
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Pending queue write
// For every owned output point, decide whether all taps are available.
// If right/bottom neighbor data is missing, store one pending task.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pend_wr_ptr <= 5'd0; // 复位pending写指针
        pend_rd_ptr <= 5'd0; // 复位pending读指针
        for (pi = 0; pi < PENDING_DEPTH; pi = pi + 1) begin
            pend_valid[pi]   <= 1'b0; // 复位时清除每条pending有效位
            pend_dst_x[pi]   <= 13'd0; // 复位pending输出x字段
            pend_dst_y[pi]   <= 13'd0; // 复位pending输出y字段
            pend_src_x_i[pi] <= 13'd0; // 复位pending源x整数坐标字段
            pend_phase_x[pi] <= 9'd0; // 复位pending x相位字段
            pend_src_y_i[pi] <= 13'd0; // 复位pending源y整数坐标字段
            pend_phase_y[pi] <= 9'd0; // 复位pending y相位字段
            pend_type[pi]    <= 2'd0; // 复位pending类型字段
        end
    end else if ((cur_state == ST_ISSUE_OUT) && !output_window_ready) begin
        pend_valid[pend_wr_ptr]   <= 1'b1; // 当前输出点数据未齐，写入一条pending任务
        pend_dst_x[pend_wr_ptr]   <= cur_dst_x; // 记录pending点的输出x坐标
        pend_dst_y[pend_wr_ptr]   <= cur_dst_y; // 记录pending点的输出y坐标
        pend_src_x_i[pend_wr_ptr] <= cur_src_x_int; // 记录pending点的源x整数坐标
        pend_phase_x[pend_wr_ptr] <= cur_phase_x; // 记录pending点的x相位
        pend_src_y_i[pend_wr_ptr] <= cur_src_y_int; // 记录pending点的源y整数坐标
        pend_phase_y[pend_wr_ptr] <= cur_phase_y; // 记录pending点的y相位
        if (need_right_block && need_bottom_block) begin
            pend_type[pend_wr_ptr] <= PEND_CORNER; // 该pending点需要右侧和下方/右下邻居数据
        end else if (need_right_block) begin
            pend_type[pend_wr_ptr] <= PEND_RIGHT; // 该pending点只缺右侧block数据
        end else begin
            pend_type[pend_wr_ptr] <= PEND_BOTTOM; // 该pending点只缺下方block数据
        end
        pend_wr_ptr <= pend_wr_ptr + 1'b1; // pending任务写入后指针加一
    end
end

// ---------------------------------------------------------------------------
// Halo save placeholder
// TODO: connect this to the actual block storage/SRAM read path. The framework
// shows where halo capture belongs in the control flow.
// ---------------------------------------------------------------------------
integer hi; // 遍历halo行时使用的循环索引
integer hj; // 遍历halo列时使用的循环索引

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Memories are not reset in real hardware.
    end else if (cur_state == ST_SAVE_HALO) begin
        // right_buffer和bottom_buffer已在RECV_BLOCK阶段随输入逐行保存，这里暂不需要额外搬移。
    end
end

endmodule
