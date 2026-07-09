`ifndef CHIP_MEM_POWER_CTRL
    `define CHIP_MEM_POWER_CTRL 1
`endif

module pp_downscale_block_buffer (
    clk,
    rst_n,
    fg2pp_ctrl,
    sw_pic_height,
    sw_upscale_pic_width,
    ctrl_update_en,
    buf_clr,
    data_vld,
    data_rdy,
    data_in,
    block_lanczos_done,
    block_lanczos_row_last,
    lanczos_start,
    lanczos_x_end,
    lanczos_y_end,
    block_start_x_o,
    block_start_y_o,
    lanczos_center_x,
    lanczos_center_y,
    lanczos_window_req,
    lanczos_window_busy,
    lanczos_window_pixels,
    lanczos_window_valid_mask,
    lanczos_window_valid,
    lanczos_window_from_right_mask
);

parameter PIXEL_W          = 10;                // 每个像素位宽，当前为 10bit。
parameter IN_PIX_PER_CYC  = 16;                 // 每拍输入 16 个像素，对应 data_in 160bit。
parameter IMG_W            = 4096;              // 当前规划支持的最大图像宽度。
parameter IMG_X_W          = 12;                // 4096 列地址需要 12bit。
parameter LINEBUF_WORD_W   = 160;               // line/bottom SRAM 一个 word 存 16 个 10bit 像素。
parameter LINEBUF_WORDS    = 256;               // 4096/16=256 个 word 覆盖一整行。
parameter LINEBUF_ADDR_W   = 8;                 // 256 深度 SRAM 的地址宽度。
parameter LANCZOS_TAPS     = 8;                 // Lanczos4 横向和纵向各 8 tap。
parameter TAP_COORD_W      = 14;                // tap 全局坐标位宽，支持负坐标和 4096 附近坐标。
parameter X_SAFE_COMMIT    = 9;                 // 当前 16 像素段中可先写回 line SRAM 的前 9 个像素。
parameter X_KEEP_PIX       = 7;                 // 当前 16 像素段末尾保留 7 个像素给下一段使用。
parameter X_CALC_RIGHT_GAP = 4;                 // 右侧还缺未来 tap 时，当前段可计算范围需要保留的 gap。
parameter RIGHT_COLS       = 7;                 // 保存给右侧 block 的右边界列数。

parameter BOTTOM_ROWS      = 7;                 // 保存给下方 block-row 的底部行数。
parameter CORNER_PIX       = 7;                 // corner_buffer 宽高均为 7。

parameter BLOCK_MAX_H      = 32;                // 当前阶段 block 最大高度。

// 坐标和缓存设计约定：
// 1. 输入数据按 block 内从左到右、从上到下传输，每拍 16 个连续像素。
// 2. line_buffer 保存当前 block 计算需要回看的 7 行历史数据。
// 3. bottom_buffer 保存上一条 block-row 的底部 7 行，供非 frame_top block 读取上方 halo。
// 4. right_buffer/corner_buffer 负责跨左右 block 的 halo 数据。
// Lanczos tap 坐标使用 signed 表示，便于描述 frame 左/上边界外的负 tap。
localparam signed [TAP_COORD_W-1:0] TAP_ZERO    = 14'sd0;
localparam signed [TAP_COORD_W-1:0] TAP_ONE     = 14'sd1;
localparam signed [TAP_COORD_W-1:0] TAP_TWO     = 14'sd2;
localparam signed [TAP_COORD_W-1:0] TAP_THREE   = 14'sd3;
localparam signed [TAP_COORD_W-1:0] TAP_FOUR    = 14'sd4;
localparam signed [TAP_COORD_W-1:0] TAP_SEVEN   = 14'sd7;
localparam signed [TAP_COORD_W-1:0] TAP_SIXTEEN = 14'sd16;

input clk;
input rst_n;
input [53:0] fg2pp_ctrl;
input [12:0] sw_pic_height;
input [12:0] sw_upscale_pic_width;
input        ctrl_update_en;
input        buf_clr;
input        data_vld;
input [159:0] data_in;
output       data_rdy;
input        block_lanczos_done;
input        block_lanczos_row_last;
output       lanczos_start;
output [7:0] lanczos_x_end;
output [6:0] lanczos_y_end;
output [12:0] block_start_x_o;
output [12:0] block_start_y_o;
input signed [TAP_COORD_W-1:0] lanczos_center_x;
input signed [TAP_COORD_W-1:0] lanczos_center_y;
input                          lanczos_window_req;
output                         lanczos_window_busy;
output [LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W-1:0] lanczos_window_pixels;
output [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_valid_mask;
output                                         lanczos_window_valid;
output [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_from_right_mask;

// ctrl 在 block 开始前给出。后续 data 流只携带像素，因此这里需要把 ctrl 固定住，
// 避免接收、写回、window read 过程中使用到下一 block 的边界或坐标信息。
reg [6:0]  block_pixel_height;                  // 当前 block 高度，以像素为单位。
reg [7:0]  block_pixel_width;                   // 当前 block 宽度，以像素为单位。
reg        frame_top_edge;                      // 当前 block 位于 frame 顶边界，负 y tap 需要 clip。
reg        frame_bottom_edge;                   // 当前 block 位于 frame 底边界，超过高度的 y tap 需要 clip。
reg        frame_left_edge;                     // 当前 block 位于 frame 左边界，负 x tap 需要 clip。
reg        frame_right_edge;                    // 当前 block 位于 frame 右边界，超过宽度的 x tap 需要 clip。
reg        tile_top_edge;                       // tile 顶边界标志，当前阶段暂未展开 tile 跨界处理。
reg        tile_bottom_edge;
reg        tile_left_edge;
reg        tile_right_edge;
reg [12:0] block_start_x;                       // 当前 block 左上角全局 x 坐标。
reg [12:0] block_start_y;                       // 当前 block 左上角全局 y 坐标。
reg [1:0]  block64_loc;                         // 当前 block 在 superblock 中的位置，暂随 ctrl 锁存。
reg [1:0]  block_type;                          // 当前数据类型，0 为 luma，1 为 interleave chroma。
reg        picture_ready;                       // 图像输出完成标志，暂随 ctrl 锁存。
// ---------------------------------------------------------------------------
// Ctrl latch always: 在 ctrl_update_en 拉高时锁存当前 block 的控制信息。
// 这些信息包括尺寸、全局起点、frame/tile 边界，整个 block 处理期间保持稳定。
// ---------------------------------------------------------------------------
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

// data_in 按 lane 拆包，pixel_in[0] 对应当前 16 像素段最左侧像素。
// 这里默认 data_in[9:0] 是 lane0，data_in[159:150] 是 lane15。
reg [PIXEL_W-1:0] pixel_in [0:IN_PIX_PER_CYC-1];
integer unpack_i;
// ---------------------------------------------------------------------------
// Input unpack always: 将 data_in[159:0] 拆成 16 个 10bit 像素 lane。
// 这里只做组合拆包，不改变时序。
// ---------------------------------------------------------------------------
always @(*) begin
    for (unpack_i = 0; unpack_i < IN_PIX_PER_CYC; unpack_i = unpack_i + 1) begin
        pixel_in[unpack_i] = data_in[unpack_i*PIXEL_W +: PIXEL_W];
    end
end

reg [3:0] seg16_x;                              // 当前 block 行内第几个 16 像素段。
reg [6:0] row_cnt;                              // 当前 block 内部行号。
reg [3:0] cycles_per_row;                       // 当前 block 每行需要接收多少个 16 像素段。
wire [7:0] cycles_per_row_calc;
wire       last_seg_in_row;
wire       last_row_in_block;
wire       block_recv_done;
wire       data_fire;

assign cycles_per_row_calc = (block_pixel_width + 8'd15) >> 4;
assign last_seg_in_row     = (seg16_x == (cycles_per_row - 1'b1));
assign last_row_in_block   = (row_cnt == (block_pixel_height - 1'b1));
assign block_recv_done     = data_fire && last_seg_in_row && last_row_in_block;

// 当前输入段和跨 block/跨行 halo 的寄存器缓存。
// cur16_reg 保存“正在算但还没写回 SRAM”的当前拍数据；
// left7_reg 保存上一段末尾 7 个像素，解决同一行内 x 方向跨 16 像素段取数；
// right_buffer/corner_buffer 解决跨 block 的左侧和左上角 halo。
reg [PIXEL_W-1:0] cur16_reg     [0:IN_PIX_PER_CYC-1]; // 当前正在计算的 16 像素段；Lanczos busy 时不能被覆盖。
reg [PIXEL_W-1:0] left7_reg     [0:X_KEEP_PIX-1]; // 当前行上一段最后 7 个像素，供跨段 tap 读取。
reg [PIXEL_W-1:0] right_buffer  [0:BLOCK_MAX_H-1][0:RIGHT_COLS-1]; // 当前 block 最右 7 列，供右侧 block 读取左侧 halo。

reg [PIXEL_W-1:0] corner_buffer [0:BOTTOM_ROWS-1][0:CORNER_PIX-1]; // 右下角 7x7 halo，供右下相邻 block 读取左上角数据。
reg               corner_valid;                 // corner_buffer 当前是否保存了有效 halo。
reg [12:0]        corner_for_block_start_x;     // corner_buffer 对应的目标 block_start_x。
reg [12:0]        corner_for_block_start_y;     // corner_buffer 对应的目标 block_start_y。

reg [12:0]        line_y_tag [0:6];             // 记录每个 line SRAM bank 当前保存的真实全局 y 行号。

// line_buffer 使用 7 个 256x160 SRAM bank。
// bank 表示 rolling 的 7 行，word_addr=global_x[11:4]，lane=global_x[3:0]。
// 例如 x=32 对应 word_addr=2、lane=0；x=47 对应 word_addr=2、lane=15。
wire [LINEBUF_ADDR_W-1:0] linebuf_ra   [0:6];
wire                      linebuf_re   [0:6];
wire [LINEBUF_WORD_W-1:0] linebuf_dout [0:6];
wire [LINEBUF_ADDR_W-1:0] linebuf_wa   [0:6];
wire                      linebuf_we   [0:6];
wire [LINEBUF_WORD_W-1:0] linebuf_di   [0:6];
reg [2:0]                 linebuf_rd_bank;
reg [2:0]                 linebuf_rd_bank_d;
reg [LINEBUF_ADDR_W-1:0]  linebuf_rd_addr;
reg                       linebuf_rd_en;
reg [2:0]                 linebuf_wr_bank;
reg [LINEBUF_ADDR_W-1:0]  linebuf_wr_addr;
reg [LINEBUF_WORD_W-1:0]  linebuf_wr_data;
reg                       linebuf_wr_en;
wire [LINEBUF_WORD_W-1:0] linebuf_rd_data_mux;
wire [`CHIP_MEM_POWER_CTRL-1:0] linebuf_pwrbus_ram_pd;

assign linebuf_pwrbus_ram_pd = {`CHIP_MEM_POWER_CTRL{1'b0}};

genvar gi_linebuf_bank;
generate
    for (gi_linebuf_bank = 0; gi_linebuf_bank < 7; gi_linebuf_bank = gi_linebuf_bank + 1) begin : GEN_LINEBUF_SRAM
        localparam [2:0] LINEBUF_BANK_ID = gi_linebuf_bank;
        assign linebuf_ra[gi_linebuf_bank] = linebuf_rd_addr;
        assign linebuf_re[gi_linebuf_bank] = linebuf_rd_en && (linebuf_rd_bank == LINEBUF_BANK_ID);
        assign linebuf_wa[gi_linebuf_bank] = linebuf_wr_addr;
        assign linebuf_we[gi_linebuf_bank] = linebuf_wr_en && (linebuf_wr_bank == LINEBUF_BANK_ID);
        assign linebuf_di[gi_linebuf_bank] = linebuf_wr_data;

        ram_rws_256x160 u_linebuf_sram (
            .clk(clk),
            .rst_n(rst_n),
            .ra(linebuf_ra[gi_linebuf_bank]),
            .re(linebuf_re[gi_linebuf_bank]),
            .dout(linebuf_dout[gi_linebuf_bank]),
            .wa(linebuf_wa[gi_linebuf_bank]),
            .we(linebuf_we[gi_linebuf_bank]),
            .di(linebuf_di[gi_linebuf_bank]),
            .pwrbus_ram_pd(linebuf_pwrbus_ram_pd)
        );
    end
endgenerate

assign linebuf_rd_data_mux = linebuf_dout[linebuf_rd_bank_d];

// === BOTTOM/CORNER ADD START: bottom_buffer SRAM bank 声明与实例化 ===
// bottom_buffer 的地址映射与 line_buffer 相同，但 bank0~6 表示上一条 block-row 的底部 7 行。
// 非 frame_top block 读取 local_y=-7~-1 时，会从这里拿到上方 block-row 的数据。
wire [LINEBUF_ADDR_W-1:0] bottombuf_ra   [0:BOTTOM_ROWS-1];
wire                      bottombuf_re   [0:BOTTOM_ROWS-1];
wire [LINEBUF_WORD_W-1:0] bottombuf_dout [0:BOTTOM_ROWS-1];
wire [LINEBUF_ADDR_W-1:0] bottombuf_wa   [0:BOTTOM_ROWS-1];
wire                      bottombuf_we   [0:BOTTOM_ROWS-1];
wire [LINEBUF_WORD_W-1:0] bottombuf_di   [0:BOTTOM_ROWS-1];
reg [2:0]                 bottombuf_rd_bank;
reg [2:0]                 bottombuf_rd_bank_d;
reg [LINEBUF_ADDR_W-1:0]  bottombuf_rd_addr;
reg                       bottombuf_rd_en;
reg [2:0]                 bottombuf_wr_bank;
reg [LINEBUF_ADDR_W-1:0]  bottombuf_wr_addr;
reg [LINEBUF_WORD_W-1:0]  bottombuf_wr_data;
reg                       bottombuf_wr_en;
wire [LINEBUF_WORD_W-1:0] bottombuf_rd_data_mux;
wire [`CHIP_MEM_POWER_CTRL-1:0] bottombuf_pwrbus_ram_pd;

assign bottombuf_pwrbus_ram_pd = {`CHIP_MEM_POWER_CTRL{1'b0}};

genvar gi_bottombuf_bank;
generate
    for (gi_bottombuf_bank = 0; gi_bottombuf_bank < BOTTOM_ROWS; gi_bottombuf_bank = gi_bottombuf_bank + 1) begin : GEN_BOTTOMBUF_SRAM
        localparam [2:0] BOTTOMBUF_BANK_ID = gi_bottombuf_bank;
        assign bottombuf_ra[gi_bottombuf_bank] = bottombuf_rd_addr;
        assign bottombuf_re[gi_bottombuf_bank] = bottombuf_rd_en && (bottombuf_rd_bank == BOTTOMBUF_BANK_ID);
        assign bottombuf_wa[gi_bottombuf_bank] = bottombuf_wr_addr;
        assign bottombuf_we[gi_bottombuf_bank] = bottombuf_wr_en && (bottombuf_wr_bank == BOTTOMBUF_BANK_ID);
        assign bottombuf_di[gi_bottombuf_bank] = bottombuf_wr_data;

        ram_rws_256x160 u_bottombuf_sram (
            .clk(clk),
            .rst_n(rst_n),
            .ra(bottombuf_ra[gi_bottombuf_bank]),
            .re(bottombuf_re[gi_bottombuf_bank]),
            .dout(bottombuf_dout[gi_bottombuf_bank]),
            .wa(bottombuf_wa[gi_bottombuf_bank]),
            .we(bottombuf_we[gi_bottombuf_bank]),
            .di(bottombuf_di[gi_bottombuf_bank]),
            .pwrbus_ram_pd(bottombuf_pwrbus_ram_pd)
        );
    end
endgenerate

assign bottombuf_rd_data_mux = bottombuf_dout[bottombuf_rd_bank_d];


// 64-tap window 输出寄存器：win_idx=y_idx*8+x_idx，x 方向变化最快。
reg [LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W-1:0] lanczos_window_pixels_r;
reg [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_valid_mask_r;
reg [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_from_right_mask_r;
reg                                         lanczos_window_valid_r;
reg                                         lanczos_start_r;
reg [7:0]                                   calc_x_end;
reg [6:0]                                   calc_y_end;

assign lanczos_start = lanczos_start_r;
assign lanczos_x_end = calc_x_end;
assign lanczos_y_end = calc_y_end;
assign block_start_x_o = block_start_x;
assign block_start_y_o = block_start_y;
assign lanczos_window_pixels = lanczos_window_pixels_r;
assign lanczos_window_valid_mask = lanczos_window_valid_mask_r;
assign lanczos_window_valid = lanczos_window_valid_r;
assign lanczos_window_from_right_mask = lanczos_window_from_right_mask_r;

wire [7:0]  in_block_x_base;
wire [12:0] in_global_x_base;
wire [6:0]  linebuf_wr_row_mod;
wire [2:0]  linebuf_wr_row;
wire        frame_top_fill_linebuf;
wire        frame_top_calc_segment;
wire        non_frame_top_calc_segment;
wire        calc_segment_fire;
wire [7:0]  cur_segment_x_end;
wire [6:0]  cur_segment_y_end;
wire        right_save_en;
wire [12:0] right_base_x;
wire [4:0]  evict_right_row_idx;
wire [6:0]  evict_right_row;
wire [8:0]  cur_write_len_full;
wire [4:0]  cur_write_len;
// === BOTTOM/CORNER ADD START: bottom/corner 保存控制信号 ===
wire [6:0]  bottom_row_start;            //底部7行从哪一行开始
wire [6:0]  bottom_wr_row_offset;        //当前行是底部区域里的第几行
wire [2:0]  bottom_wr_req_bank_calc;
wire        bottom_save_en;
wire        save_corner_en;


reg [7:0]  calc_block_x_base;
reg [12:0] calc_global_x_base;
reg [2:0]  calc_linebuf_row;
reg [6:0]  calc_row_cnt;
reg        calc_first_seg_in_row;
reg        calc_last_seg_in_row;
reg        calc_last_row_in_block;

assign in_block_x_base   = {seg16_x, 4'b0000};  // 当前 16 像素段在 block 内部的 x 起点。
assign in_global_x_base  = block_start_x + {5'd0, seg16_x, 4'b0000}; // 当前 16 像素段在整帧中的 x 起点。
assign linebuf_wr_row_mod= row_cnt % 7'd7;      // 当前行写入 7 行 rolling line SRAM 的 bank。
assign linebuf_wr_row    = linebuf_wr_row_mod[2:0];

// frame_top block 没有上方 bottom halo，所以必须先收满 7 行历史行；
// 非 frame_top block 的上方 7 行已经在 bottom_buffer 中，因此 row0 到来即可启动计算。
assign frame_top_fill_linebuf      = frame_top_edge && data_fire && (row_cnt < 7'd7); // frame_top block 前 7 行只写 line SRAM，不启动计算。
assign frame_top_calc_segment      = frame_top_edge && data_fire && (row_cnt >= 7'd7);
// === BOTTOM/CORNER ADD START: 非 frame_top block 可依赖 bottom_buffer 从 row0 开始计算 ===
assign non_frame_top_calc_segment  = !frame_top_edge && data_fire; // 非 frame 顶部 block 中，当前输入的 16 像素段可以直接作为计算段启动 Lanczos

assign calc_segment_fire           = frame_top_calc_segment || non_frame_top_calc_segment; //当前16像素段启动Lanczos

// 当前 16 像素段到来后，右侧还需要预留 Lanczos4 的未来 tap，
// 所以非最后段最多只开放到 in_block_x_base+12；最后段开放到 block_width-4。
assign cur_segment_x_end = last_seg_in_row ? (block_pixel_width - 8'd4) : (in_block_x_base + 8'd12); // 当前 16 像素段到来后可计算的 x 右边界。
assign cur_segment_y_end = frame_top_edge ? (row_cnt - 7'd4) : row_cnt; // 当前 16 像素段到来后可计算的 y 下边界。

// right_buffer 保存的是当前 block 最右 7 列。
// frame 右边界没有右侧 block，不需要保存；tile 跨界后续再接 DDR 方案。
assign right_save_en = !frame_right_edge;       // frame 右边界没有右侧 block，因此不保存 right halo。
assign right_base_x  = block_start_x + {5'd0, block_pixel_width} - 13'd7; // 当前 block 最右 7 列的全局 x 起点。
assign cur_write_len_full = {1'b0, block_pixel_width} - {1'b0, calc_block_x_base}; // 最后一段实际有效像素数量的扩展计算。
assign cur_write_len      = cur_write_len_full[4:0];
assign evict_right_row     = calc_row_cnt - 7'd7; // 当前行写回会覆盖 7 行前的旧行，该旧行需要保存 right halo。
assign evict_right_row_idx = evict_right_row[4:0];

// === BOTTOM/CORNER ADD START: 判断当前行是否需要写 bottom，以及是否要先保存 corner ===
// bottom_buffer 保存当前 block 最后 7 行，给下一条 block-row 使用。
// 第一拍覆盖旧 bottom 前，如果该旧 bottom 的右 7 列会被右下 block 使用，需要先保存到 corner_buffer。
assign bottom_row_start = block_pixel_height - 7'd7; // 当前 block 最后 7 行开始写入 bottom_buffer。
assign bottom_wr_row_offset = calc_row_cnt - bottom_row_start;
assign bottom_wr_req_bank_calc = bottom_wr_row_offset[2:0]; // bottom_buffer bank0~6 对应当前 block 最后 7 行。
assign bottom_save_en = !frame_bottom_edge && (calc_row_cnt >= bottom_row_start);
assign save_corner_en = bottom_save_en && !frame_top_edge && !frame_right_edge &&
                        (calc_row_cnt == bottom_row_start) && calc_first_seg_in_row;




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
wire save_evict_right_en;
wire need_tail_flush;
wire writeback_done;
wire flush_right_done;

assign recv_linebuf_en     = (cur_state == ST_RECV) && frame_top_fill_linebuf; // frame_top 前 7 行直接整 160bit 写入 line SRAM。
assign latch_cur16_en      = (cur_state == ST_RECV) && calc_segment_fire; // 真正接收到可计算 segment 时锁存 cur16_reg。
assign writeback_en        = (cur_state == ST_WRITEBACK);
assign save_evict_right_en = writeback_en && right_save_en && calc_last_seg_in_row && (calc_row_cnt >= 7'd7);
assign need_tail_flush     = writeback_en && right_save_en && calc_last_seg_in_row && calc_last_row_in_block;
// ---------------------------------------------------------------------------
// Main state register always: 保存 ST_* 主状态机当前状态。
// 复位或 buf_clr 时回到 ST_IDLE，其余时间按 next_state 推进。
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
// Main next-state always: 根据接收、Lanczos 完成、写回完成和 flush 完成决定主流程跳转。
// 这个 always 只产生 next_state，不直接修改计数器或 buffer。
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
            end
        end

        ST_LANCZOS_BUSY: begin
            if (block_lanczos_done) begin
                nxt_state = ST_WRITEBACK;
            end
        end

        ST_WRITEBACK: begin
            if (writeback_done) begin
                if (need_tail_flush) begin
                    nxt_state = ST_FLUSH_RIGHT;
                end else if (calc_last_row_in_block && calc_last_seg_in_row) begin
                    nxt_state = ST_IDLE;
                end else begin
                    nxt_state = ST_RECV;
                end
            end
        end

        ST_FLUSH_RIGHT: begin
            if (flush_right_done) begin
                nxt_state = ST_IDLE;
            end
        end

        default: begin
            nxt_state = ST_IDLE;
        end
    endcase
end

function signed [TAP_COORD_W-1:0] tap_offset_by_idx;
    input [2:0] tap_idx;
begin
    case (tap_idx)
        3'd0: tap_offset_by_idx = -TAP_THREE;
        3'd1: tap_offset_by_idx = -TAP_TWO;
        3'd2: tap_offset_by_idx = -TAP_ONE;
        3'd3: tap_offset_by_idx = TAP_ZERO;
        3'd4: tap_offset_by_idx = TAP_ONE;
        3'd5: tap_offset_by_idx = TAP_TWO;
        3'd6: tap_offset_by_idx = TAP_THREE;
        3'd7: tap_offset_by_idx = TAP_FOUR;
        default: tap_offset_by_idx = TAP_ZERO;
    endcase
end
endfunction

localparam [2:0] WIN_IDLE      = 3'd0;
localparam [2:0] WIN_TAP_PREP  = 3'd1;
localparam [2:0] WIN_SRAM_READ = 3'd2;
localparam [2:0] WIN_SRAM_SAVE = 3'd3;
localparam [2:0] WIN_DONE      = 3'd4;
localparam [2:0] WIN_SRC_INVALID = 3'd0;
localparam [2:0] WIN_SRC_RIGHT   = 3'd1;
localparam [2:0] WIN_SRC_CUR16   = 3'd2;
localparam [2:0] WIN_SRC_LEFT7   = 3'd3;
localparam [2:0] WIN_SRC_LINE    = 3'd4;
// === BOTTOM/CORNER ADD START: 64-tap window 新增的上方 halo 来源 ===
localparam [2:0] WIN_SRC_BOTTOM  = 3'd5;
localparam [2:0] WIN_SRC_CORNER  = 3'd6;


reg [2:0] win_state;                            // 64-tap window read 状态机状态。
reg [5:0] win_idx;                              // 当前正在读取的 tap 编号，范围 0~63。
reg signed [TAP_COORD_W-1:0] win_center_x_r;
reg signed [TAP_COORD_W-1:0] win_center_y_r;
reg [2:0] win_line_rd_bank;
reg [LINEBUF_ADDR_W-1:0] win_line_rd_addr;
reg [3:0] win_line_rd_lane;
// === BOTTOM/CORNER ADD START: window 读取 bottom SRAM 的地址暂存 ===
reg [2:0] win_bottom_rd_bank;
reg [LINEBUF_ADDR_W-1:0] win_bottom_rd_addr;
reg [3:0] win_bottom_rd_lane;
reg       win_sram_from_bottom;                 // 记录本次 SRAM 读取来自 line_buffer 还是 bottom_buffer。

reg [5:0] win_line_save_idx;                    // SRAM 数据返回时对应的 64-tap 输出位置。
reg signed [TAP_COORD_W-1:0] win_tap_x_g;
reg signed [TAP_COORD_W-1:0] win_tap_y_g;
reg signed [TAP_COORD_W-1:0] win_clip_x_g;
reg signed [TAP_COORD_W-1:0] win_clip_y_g;
reg signed [TAP_COORD_W-1:0] win_local_x;       // clip 后 tap_x 减 block_start_x 得到的 block-local x。
reg signed [TAP_COORD_W-1:0] win_local_y;       // clip 后 tap_y 减 block_start_y 得到的 block-local y。
reg signed [TAP_COORD_W-1:0] win_frame_width_s;
reg signed [TAP_COORD_W-1:0] win_frame_height_s;
reg signed [TAP_COORD_W-1:0] win_block_start_x_s;
reg signed [TAP_COORD_W-1:0] win_block_start_y_s;
reg signed [TAP_COORD_W-1:0] win_block_width_s;
reg signed [TAP_COORD_W-1:0] win_block_height_s;
reg signed [TAP_COORD_W-1:0] win_calc_row_cnt_s;
reg signed [TAP_COORD_W-1:0] win_tap_y_min_s;
reg signed [TAP_COORD_W-1:0] win_calc_x_base_s;
reg signed [TAP_COORD_W-1:0] win_calc_x_limit_s;
reg signed [TAP_COORD_W-1:0] win_calc_left7_base_s;
reg signed [TAP_COORD_W-1:0] win_right_idx_full;
reg signed [TAP_COORD_W-1:0] win_cur16_idx_full;
reg signed [TAP_COORD_W-1:0] win_left7_idx_full;
// === BOTTOM/CORNER ADD START: local_y/local_x 映射到 bottom/corner 索引 ===
//把上方halo的y坐标 -7..-1 转成 bottom_buffer 行号 0..6
reg signed [TAP_COORD_W-1:0] win_bottom_y_idx_full;
reg signed [TAP_COORD_W-1:0] win_corner_x_idx_full;
reg signed [TAP_COORD_W-1:0] win_corner_y_idx_full;

reg [12:0] win_clip_x_u;
reg [12:0] win_clip_y_u;
reg [6:0]  win_local_y_u;
reg [6:0]  win_linebuf_row_mod;
reg [2:0]  win_linebuf_row;
reg [LINEBUF_ADDR_W-1:0] win_line_addr;
reg [3:0]  win_line_lane;
reg [2:0]  win_right_idx;
reg [3:0]  win_cur16_idx;
reg [2:0]  win_left7_idx;
// === BOTTOM/CORNER ADD START: bottom/corner 取数索引 ===
reg [2:0]  win_bottom_idx;
reg [2:0]  win_corner_x_idx;
reg [2:0]  win_corner_y_idx;

reg [2:0]  win_src_sel;
reg [PIXEL_W-1:0] win_direct_pixel;
reg        win_direct_valid;
reg        win_direct_from_right;
reg        win_tap_y_in_block;
reg        win_tap_y_in_window;
// === BOTTOM/CORNER ADD START: 判断 tap 是否落在当前 block 上方 halo 或 corner tag 是否匹配 ===
reg        win_tap_y_in_bottom;  //表示当前 tap 的 y 坐标落在当前 block 上方 7 行 halo 区域
reg        win_line_tag_match;   //判断 bank 里的数据是不是当前 tap 需要的那一行
reg        win_corner_tag_match;


assign lanczos_window_busy = (win_state != WIN_IDLE);
// ---------------------------------------------------------------------------
// Window source select always: 根据当前 8x8 tap 的全局坐标判断像素来源。
// 这里完成 frame clip、global/local 坐标转换，并选择 right/cur16/left7/line/bottom/corner。
// ---------------------------------------------------------------------------
always @(*) begin
    win_src_sel = WIN_SRC_INVALID;
    win_direct_pixel = {PIXEL_W{1'b0}};
    win_direct_valid = 1'b0;
    win_direct_from_right = 1'b0;
    win_frame_width_s = {1'b0, sw_upscale_pic_width};
    win_frame_height_s = {1'b0, sw_pic_height};
    win_block_start_x_s = {1'b0, block_start_x};
    win_block_start_y_s = {1'b0, block_start_y};

    // win_idx 的低 3bit 是 x tap index，高 3bit 是 y tap index。
    // tap_offset_by_idx 产生标准顺序 -3,-2,-1,0,+1,+2,+3,+4。
    win_tap_x_g = win_center_x_r + tap_offset_by_idx(win_idx[2:0]);
    win_tap_y_g = win_center_y_r + tap_offset_by_idx(win_idx[5:3]);  //计算需要的y方向的坐标

    // 只有在 frame 边界时才 clip；非 frame 边界保留负 local 坐标，让 halo buffer 接管。
    win_clip_x_g = win_tap_x_g;
    if (frame_left_edge && (win_tap_x_g < TAP_ZERO)) begin
        win_clip_x_g = TAP_ZERO;
    end else if (frame_right_edge && (win_tap_x_g >= win_frame_width_s)) begin
        win_clip_x_g = win_frame_width_s - TAP_ONE;
    end
    win_clip_y_g = win_tap_y_g;
    if (frame_top_edge && (win_tap_y_g < TAP_ZERO)) begin
        win_clip_y_g = TAP_ZERO;
    end else if (frame_bottom_edge && (win_tap_y_g >= win_frame_height_s)) begin
        win_clip_y_g = win_frame_height_s - TAP_ONE;
    end

    // local_x/local_y 用来判断 tap 落在当前 block 内部、左侧 halo，还是上方 halo。
    win_local_x = win_clip_x_g - win_block_start_x_s;  //计算的坐标减去该block的起始坐标
    win_local_y = win_clip_y_g - win_block_start_y_s;
    win_clip_x_u = win_clip_x_g[12:0];
    win_clip_y_u = win_clip_y_g[12:0];
    win_local_y_u = win_local_y[6:0];
    win_linebuf_row_mod = win_local_y_u % 7'd7;
    win_linebuf_row = win_linebuf_row_mod[2:0];
    win_line_addr = win_clip_x_u[11:4];
    win_line_lane = win_clip_x_u[3:0];

    // line_buffer 是 7 行 rolling 复用，tag 不匹配说明该 bank 已经被其他行覆盖，不能读取。
    win_line_tag_match = (line_y_tag[win_linebuf_row] == win_clip_y_u);  //判断line_buffer里面的实际坐标行是否跟要取的一致

    // corner_buffer 只对右下相邻 block 有效，必须 block_start_x/y 都匹配才允许读取。
    win_corner_tag_match = corner_valid &&
                           (corner_for_block_start_x == block_start_x) &&
                           (corner_for_block_start_y == block_start_y);
    win_block_width_s = {6'b0, block_pixel_width};
    win_block_height_s = {7'b0, block_pixel_height};
    win_calc_row_cnt_s = {7'b0, calc_row_cnt};
    win_tap_y_min_s = (calc_row_cnt >= 7'd7) ? ({7'b0, calc_row_cnt} - TAP_SEVEN) : TAP_ZERO;
    win_tap_y_in_block = (win_local_y >= TAP_ZERO) && (win_local_y < win_block_height_s);
    win_tap_y_in_window = (win_local_y >= win_tap_y_min_s) && (win_local_y <= win_calc_row_cnt_s);
    // === BOTTOM/CORNER ADD START: 判断是否需要从上一条 block-row 的 bottom/corner 取数 ===
    // 非 frame_top 时，local_y=-7~-1 表示当前 block 上方 7 行，需要从 bottom/corner 取。
    win_tap_y_in_bottom = !frame_top_edge && (win_local_y >= -TAP_SEVEN) && (win_local_y < TAP_ZERO);
    
    win_calc_x_base_s = {6'b0, calc_block_x_base};
    win_calc_x_limit_s = {6'b0, calc_block_x_base} + TAP_SIXTEEN;
    win_calc_left7_base_s = {6'b0, calc_block_x_base} - TAP_SEVEN;
    //是把当前tap的x坐标换算成对应buffer的数组下标
    win_right_idx_full = win_local_x + TAP_SEVEN;
    win_cur16_idx_full = win_local_x - win_calc_x_base_s;
    win_left7_idx_full = win_local_x - win_calc_left7_base_s;
    // === BOTTOM/CORNER ADD START: 将负 local 坐标转换成 0~6 的 bottom/corner 索引 ===
    win_bottom_y_idx_full = win_local_y + TAP_SEVEN;
    win_corner_x_idx_full = win_local_x + TAP_SEVEN;
    win_corner_y_idx_full = win_local_y + TAP_SEVEN;
    
    win_right_idx = win_right_idx_full[2:0];
    win_cur16_idx = win_cur16_idx_full[3:0];
    win_left7_idx = win_left7_idx_full[2:0];
    // === BOTTOM/CORNER ADD START: bottom/corner 最终数组下标 ===
    win_bottom_idx = win_bottom_y_idx_full[2:0];
    win_corner_x_idx = win_corner_x_idx_full[2:0];
    win_corner_y_idx = win_corner_y_idx_full[2:0];
    
    if (cur_state == ST_LANCZOS_BUSY) begin
        // === BOTTOM/CORNER ADD START: 64-tap window 对上方 halo 的取数路径 ===
        if (win_tap_y_in_bottom) begin
            if (win_local_x < TAP_ZERO) begin
                // 左上 halo：x 来自左侧 block，y 来自上方 block-row，因此读 corner_buffer。
                if (!frame_left_edge && (win_local_x >= -TAP_SEVEN) && win_corner_tag_match) begin
                    win_src_sel = WIN_SRC_CORNER;
                    win_direct_pixel = corner_buffer[win_corner_y_idx][win_corner_x_idx];
                    win_direct_valid = 1'b1;
                end
            end else if (win_local_x < win_block_width_s) begin
                // 上方 halo：x 在当前 block 范围内，y 在当前 block 上方，读 bottom_buffer。
                win_src_sel = WIN_SRC_BOTTOM;
                win_direct_valid = 1'b1;
            end
        
        end else if (win_tap_y_in_block && win_tap_y_in_window) begin
            if (win_local_x < TAP_ZERO) begin
                // 左侧 halo：当前 block 左侧 7 列来自左侧 block 保存的 right_buffer。
                if (!frame_left_edge && (win_local_x >= -TAP_SEVEN)) begin
                    win_src_sel = WIN_SRC_RIGHT;
                    win_direct_pixel = right_buffer[win_local_y_u[4:0]][win_right_idx];
                    win_direct_valid = 1'b1;
                    win_direct_from_right = 1'b1;
                end
            end else if (win_local_x < win_block_width_s) begin
                if ((win_local_y == win_calc_row_cnt_s) &&
                    (win_local_x >= win_calc_x_base_s) &&
                    (win_local_x < win_calc_x_limit_s)) begin
                    // 当前刚输入的 16 像素段还没写回 line SRAM，直接从 cur16_reg 旁路读取。
                    win_src_sel = WIN_SRC_CUR16;
                    win_direct_pixel = cur16_reg[win_cur16_idx];
                    win_direct_valid = 1'b1;
                end else if ((win_local_y == win_calc_row_cnt_s) &&
                             !calc_first_seg_in_row &&
                             (win_local_x >= win_calc_left7_base_s) &&
                             (win_local_x < win_calc_x_base_s)) begin
                    // 当前行上一段最后 7 个像素暂存在 left7_reg，还没有写入 line SRAM。
                    win_src_sel = WIN_SRC_LEFT7;
                    win_direct_pixel = left7_reg[win_left7_idx];
                    win_direct_valid = 1'b1;
                end else if (win_line_tag_match) begin
                    // 已经提交到 line SRAM 的历史行或当前行早期像素，从 line_buffer 读取。
                    win_src_sel = WIN_SRC_LINE;
                    win_direct_valid = 1'b1;
                end
            end
        end
    end
end
// ---------------------------------------------------------------------------
// Window read FSM always: 收到 lanczos_window_req 后逐个读取 64 个 tap。
// 寄存器来源直接取数，SRAM 来源发读请求并等待下一拍 dout。
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        win_state <= WIN_IDLE;
        win_idx <= 6'd0;
        win_center_x_r <= {TAP_COORD_W{1'b0}};
        win_center_y_r <= {TAP_COORD_W{1'b0}};
        win_line_rd_bank <= 3'd0;
        win_line_rd_addr <= {LINEBUF_ADDR_W{1'b0}};
        win_line_rd_lane <= 4'd0;
        win_bottom_rd_bank <= 3'd0;
        win_bottom_rd_addr <= {LINEBUF_ADDR_W{1'b0}};
        win_bottom_rd_lane <= 4'd0;
        win_sram_from_bottom <= 1'b0;
        win_line_save_idx <= 6'd0;
        lanczos_window_pixels_r <= {(LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W){1'b0}};
        lanczos_window_valid_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
        lanczos_window_from_right_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
        lanczos_window_valid_r <= 1'b0;
    end else if (buf_clr) begin
        win_state <= WIN_IDLE;
        win_idx <= 6'd0;
        win_center_x_r <= {TAP_COORD_W{1'b0}};
        win_center_y_r <= {TAP_COORD_W{1'b0}};
        win_line_rd_bank <= 3'd0;
        win_line_rd_addr <= {LINEBUF_ADDR_W{1'b0}};
        win_line_rd_lane <= 4'd0;
        win_bottom_rd_bank <= 3'd0;
        win_bottom_rd_addr <= {LINEBUF_ADDR_W{1'b0}};
        win_bottom_rd_lane <= 4'd0;
        win_sram_from_bottom <= 1'b0;
        win_line_save_idx <= 6'd0;
        lanczos_window_pixels_r <= {(LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W){1'b0}};
        lanczos_window_valid_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
        lanczos_window_from_right_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
        lanczos_window_valid_r <= 1'b0;
    end else begin
        lanczos_window_valid_r <= 1'b0;
        case (win_state)
            WIN_IDLE: begin
                if (lanczos_window_req && (cur_state == ST_LANCZOS_BUSY)) begin
                    // 锁存 Lanczos 给出的整数中心坐标，后续 64 个 tap 都基于这个中心展开。
                    win_center_x_r <= lanczos_center_x;
                    win_center_y_r <= lanczos_center_y;
                    win_idx <= 6'd0;
                    lanczos_window_pixels_r <= {(LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W){1'b0}};
                    lanczos_window_valid_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
                    lanczos_window_from_right_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
                    win_state <= WIN_TAP_PREP;
                end
            end
            WIN_TAP_PREP: begin
                if (win_src_sel == WIN_SRC_LINE) begin
                    // line_buffer 是同步 SRAM，先发起读请求，下一拍再保存返回数据。
                    win_line_rd_bank <= win_linebuf_row;
                    win_line_rd_addr <= win_line_addr;
                    win_line_rd_lane <= win_line_lane;
                    win_line_save_idx <= win_idx;
                    win_sram_from_bottom <= 1'b0;
                    win_state <= WIN_SRAM_READ;
                // === BOTTOM/CORNER ADD START: window 读取 bottom_buffer 的同步 SRAM 路径 ===
                end else if (win_src_sel == WIN_SRC_BOTTOM) begin
                    // bottom_buffer 同样是同步 SRAM，用 win_sram_from_bottom 区分返回数据来源。
                    win_bottom_rd_bank <= win_bottom_idx;
                    win_bottom_rd_addr <= win_line_addr;
                    win_bottom_rd_lane <= win_line_lane;
                    win_line_save_idx <= win_idx;
                    win_sram_from_bottom <= 1'b1;
                    win_state <= WIN_SRAM_READ;
                
                end else begin
                    // right/cur16/left7/corner 都是寄存器路径，可以在本状态直接写入 window 输出。
                    lanczos_window_pixels_r[win_idx*PIXEL_W +: PIXEL_W] <= win_direct_pixel;
                    lanczos_window_valid_mask_r[win_idx] <= win_direct_valid;
                    lanczos_window_from_right_mask_r[win_idx] <= win_direct_from_right;
                    if (win_idx == 6'd63) begin
                        win_state <= WIN_DONE;
                    end else begin
                        win_idx <= win_idx + 1'b1;
                    end
                end
            end
            WIN_SRAM_READ: begin
                win_state <= WIN_SRAM_SAVE;
            end
            WIN_SRAM_SAVE: begin
                // === BOTTOM/CORNER ADD START: bottom_buffer SRAM 返回数据写入 64-tap window ===
                if (win_sram_from_bottom) begin
                    // 保存 bottom SRAM 返回的一个 lane 到对应 win_idx。
                    lanczos_window_pixels_r[win_line_save_idx*PIXEL_W +: PIXEL_W] <=
                        bottombuf_rd_data_mux[win_bottom_rd_lane*PIXEL_W +: PIXEL_W];
                end else begin
                
                    // 保存 line SRAM 返回的一个 lane 到对应 win_idx。
                    lanczos_window_pixels_r[win_line_save_idx*PIXEL_W +: PIXEL_W] <=
                        linebuf_rd_data_mux[win_line_rd_lane*PIXEL_W +: PIXEL_W];
                end
                lanczos_window_valid_mask_r[win_line_save_idx] <= 1'b1;
                lanczos_window_from_right_mask_r[win_line_save_idx] <= 1'b0;
                if (win_line_save_idx == 6'd63) begin
                    win_state <= WIN_DONE;
                end else begin
                    win_idx <= win_line_save_idx + 1'b1;
                    win_state <= WIN_TAP_PREP;
                end
            end
            WIN_DONE: begin
                // 64 个 tap 全部写入输出寄存器后，valid 拉高 1 拍。
                lanczos_window_valid_r <= 1'b1;
                win_state <= WIN_IDLE;
            end
            default: begin
                win_state <= WIN_IDLE;
            end
        endcase
    end
end

// LW_*：line_buffer 写回状态机；非整 word 写入需要 read-modify-write。
localparam [2:0] LW_IDLE  = 3'd0;
localparam [2:0] LW_READ  = 3'd1;
localparam [2:0] LW_MERGE = 3'd2;
localparam [2:0] LW_WRITE = 3'd3;
localparam [2:0] LW_DONE  = 3'd4;

reg [2:0]                line_wr_state;
reg                      line_wr_start;
reg [2:0]                line_wr_req_bank;
reg [12:0]               line_wr_req_x;
reg [4:0]                line_wr_req_len;
reg [LINEBUF_WORD_W-1:0] line_wr_req_pixels;
reg [12:0]               line_wr_cur_x;
reg [4:0]                line_wr_rem_len;
reg [4:0]                line_wr_data_offset;
reg [3:0]                line_wr_start_lane;
reg [4:0]                line_wr_chunk_len;
reg [LINEBUF_WORD_W-1:0] line_wr_merge_word;
wire                     line_wr_done;

assign line_wr_done = (line_wr_state == LW_DONE);

// RR_*：从 line SRAM 读出即将被覆盖旧行的右 7 列，保存到 right_buffer。
localparam [2:0] RR_IDLE  = 3'd0;
localparam [2:0] RR_READ0 = 3'd1;
localparam [2:0] RR_SAVE0 = 3'd2;
localparam [2:0] RR_READ1 = 3'd3;
localparam [2:0] RR_SAVE1 = 3'd4;
localparam [2:0] RR_DONE  = 3'd5;

reg [2:0]  right_rd_state;
reg        right_rd_start;
reg [2:0]  right_rd_bank;
reg [12:0] right_rd_x;
reg [4:0]  right_rd_dst_row;
reg [3:0]  right_rd_start_lane;
reg        right_rd_cross_word;
wire       right_rd_done;

assign right_rd_done = (right_rd_state == RR_DONE);

// === BOTTOM/CORNER ADD START: bottom_buffer 写状态机定义和请求寄存器 ===
// BW_*：bottom_buffer 写状态机；当前假设 x/width 16 对齐，直接整 word 写。
localparam [1:0] BW_IDLE  = 2'd0;
localparam [1:0] BW_WRITE = 2'd1;
localparam [1:0] BW_DONE  = 2'd2;

reg [1:0]                bottom_wr_state;
reg                      bottom_wr_start;
reg [2:0]                bottom_wr_req_bank;
reg [LINEBUF_ADDR_W-1:0] bottom_wr_req_addr;
reg [LINEBUF_WORD_W-1:0] bottom_wr_req_data;
wire                     bottom_wr_done;

assign bottom_wr_done = (bottom_wr_state == BW_DONE);


// === BOTTOM/CORNER ADD START: corner_buffer 保存状态机定义和请求寄存器 ===
// CR_*：bottom_buffer 被当前 block 覆盖前，保存旧 bottom 的右 7 列到 corner_buffer。
localparam [1:0] CR_IDLE = 2'd0;
localparam [1:0] CR_READ = 2'd1;
localparam [1:0] CR_SAVE = 2'd2;
localparam [1:0] CR_DONE = 2'd3;

reg [1:0]                corner_rd_state;
reg                      corner_rd_start;
reg [2:0]                corner_rd_idx;
reg [LINEBUF_ADDR_W-1:0] corner_rd_addr;
reg [3:0]                corner_rd_start_lane;
wire                     corner_rd_done;

assign corner_rd_done = (corner_rd_state == CR_DONE);


reg [2:0] flush_idx;
wire [6:0] flush_row_cnt;
wire [6:0] flush_linebuf_row_mod;
wire [2:0] flush_linebuf_row;
wire [7:0] cur16_right_base_idx;

assign flush_row_cnt         = block_pixel_height - 7'd7 + {4'd0, flush_idx};
assign flush_linebuf_row_mod = flush_row_cnt % 7'd7;
assign flush_linebuf_row     = flush_linebuf_row_mod[2:0];
assign cur16_right_base_idx  = block_pixel_width - calc_block_x_base - 8'd7;
assign flush_right_done      = (cur_state == ST_FLUSH_RIGHT) && (flush_idx == 3'd6) && (right_rd_state == RR_IDLE);

// WB_*：segment 写回调度状态机，串行安排 right/left7/cur16/corner/bottom 操作。
localparam [2:0] WB_IDLE         = 3'd0;
localparam [2:0] WB_SAVE_RIGHT   = 3'd1;
localparam [2:0] WB_WRITE_L7     = 3'd2;
localparam [2:0] WB_WRITE_CUR    = 3'd3;
localparam [2:0] WB_SAVE_CORNER  = 3'd4;
localparam [2:0] WB_WRITE_BOTTOM = 3'd5;
localparam [2:0] WB_DONE         = 3'd6;

reg [2:0] wb_state;

assign writeback_done = (wb_state == WB_DONE);

integer i_launch;
integer i_line;
integer i_right;
integer i_tag;
integer i_word;
integer i_rr;
integer i_corner;
// ---------------------------------------------------------------------------
// Receive counter always: 只在 data_fire 时推进 seg16_x 和 row_cnt。
// data_rdy=0 时上游数据不会被接收，计数器也不会误前进。
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
            // 只在真正握手成功时推进输入坐标；block 收完后回到下一 block 起点。
            if (block_recv_done) begin
            seg16_x <= 4'd0;
            row_cnt <= 7'd0;
        end else if (last_seg_in_row) begin
            seg16_x <= 4'd0;
            row_cnt <= row_cnt + 1'b1;
        end else begin
            seg16_x <= seg16_x + 1'b1;
        end
    end
end
// ---------------------------------------------------------------------------
// Lanczos launch snapshot always: 在可计算 segment 被接收时锁存 cur16_reg 和 calc_* 快照。
// block_lanczos_done 返回后，写回仍使用这些快照。
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
            // Lanczos 计算期间 data_rdy 会拉低，因此 cur16_reg 不会被下一拍输入覆盖。
            for (i_launch = 0; i_launch < IN_PIX_PER_CYC; i_launch = i_launch + 1) begin
                cur16_reg[i_launch] <= pixel_in[i_launch];
            end
            // 写回需要使用“当时接收的 segment 坐标”，不能依赖后续变化的 row_cnt/seg16_x。
            calc_block_x_base <= in_block_x_base;     //当前正在送给 Lanczos 计算的这个 16 像素段，在当前 block 内部的 x 起始坐标
            calc_global_x_base <= in_global_x_base;
            calc_linebuf_row <= linebuf_wr_row;
            calc_row_cnt <= row_cnt;
            calc_first_seg_in_row <= (seg16_x == 4'd0);
            calc_last_seg_in_row <= last_seg_in_row;
            calc_last_row_in_block <= last_row_in_block;
            calc_x_end <= cur_segment_x_end;
            calc_y_end <= cur_segment_y_end;
            lanczos_start_r <= 1'b1;
        end
    end
end
// ---------------------------------------------------------------------------
// Line SRAM access mux always: 仲裁本拍 line_buffer 的读写端口。
// 读覆盖 line RMW、right 保存、window 读；写覆盖 line RMW 和 frame_top 初始填充。
// ---------------------------------------------------------------------------
always @(*) begin
    linebuf_rd_bank = 3'd0;
    linebuf_rd_addr = {LINEBUF_ADDR_W{1'b0}};
    linebuf_rd_en   = 1'b0;
    linebuf_wr_bank = 3'd0;
    linebuf_wr_addr = {LINEBUF_ADDR_W{1'b0}};
    linebuf_wr_data = {LINEBUF_WORD_W{1'b0}};
    linebuf_wr_en   = 1'b0;
    if (line_wr_state == LW_READ) begin
        // line 写回 RMW：先读出旧 word，后续只替换目标 lane。
        linebuf_rd_bank = line_wr_req_bank;
        linebuf_rd_addr = line_wr_cur_x[11:4];
        linebuf_rd_en   = 1'b1;
    end else if ((right_rd_state == RR_READ0) || (right_rd_state == RR_READ1)) begin
        // 保存 right_buffer 时，需要在旧行被覆盖前从 line SRAM 读出右 7 列。
        linebuf_rd_bank = right_rd_bank;
        linebuf_rd_addr = right_rd_x[11:4] + ((right_rd_state == RR_READ1) ? 8'd1 : 8'd0);
        linebuf_rd_en   = 1'b1;
    end else if ((win_state == WIN_SRAM_READ) && !win_sram_from_bottom) begin
        // 64-tap window 读取当前 block 内部已经提交到 line SRAM 的像素。
        linebuf_rd_bank = win_line_rd_bank;
        linebuf_rd_addr = win_line_rd_addr;
        linebuf_rd_en   = 1'b1;
    end
    if (line_wr_state == LW_WRITE) begin
        // RMW 合并完成后，整 160bit word 写回。
        linebuf_wr_bank = line_wr_req_bank;
        linebuf_wr_addr = line_wr_cur_x[11:4];
        linebuf_wr_data = line_wr_merge_word;
        linebuf_wr_en   = 1'b1;
    end else if (recv_linebuf_en) begin
        // frame_top 的前 7 行只是建立历史行，输入天然 16 像素对齐，可整 word 写入。
        linebuf_wr_bank = linebuf_wr_row;
        linebuf_wr_addr = in_global_x_base[11:4];
        linebuf_wr_data = data_in;
        linebuf_wr_en   = 1'b1;
    end
end
// ---------------------------------------------------------------------------
// Bottom SRAM access mux always: 仲裁本拍 bottom_buffer 的读写端口。
// 读用于 corner 保存或 window 上方 halo，写用于保存当前 block 最后 7 行。
// ---------------------------------------------------------------------------
// === BOTTOM/CORNER ADD START: bottom_buffer SRAM 读写端口仲裁 ===
always @(*) begin
    bottombuf_rd_bank = 3'd0;
    bottombuf_rd_addr = {LINEBUF_ADDR_W{1'b0}};
    bottombuf_rd_en   = 1'b0;
    bottombuf_wr_bank = 3'd0;
    bottombuf_wr_addr = {LINEBUF_ADDR_W{1'b0}};
    bottombuf_wr_data = {LINEBUF_WORD_W{1'b0}};
    bottombuf_wr_en   = 1'b0;
    if (corner_rd_state == CR_READ) begin
        // 保存 corner 前，读取旧 bottom_buffer 的右下 7x7 中的一行。
        bottombuf_rd_bank = corner_rd_idx;
        bottombuf_rd_addr = corner_rd_addr;
        bottombuf_rd_en   = 1'b1;
    end else if ((win_state == WIN_SRAM_READ) && win_sram_from_bottom) begin
        // 64-tap window 读取当前 block 上方 halo。
        bottombuf_rd_bank = win_bottom_rd_bank;
        bottombuf_rd_addr = win_bottom_rd_addr;
        bottombuf_rd_en   = 1'b1;
    end
    if (bottom_wr_state == BW_WRITE) begin
        // 当前 block 最后 7 行写入 bottom_buffer，供下一条 block-row 使用。
        bottombuf_wr_bank = bottom_wr_req_bank;
        bottombuf_wr_addr = bottom_wr_req_addr;
        bottombuf_wr_data = bottom_wr_req_data;
        bottombuf_wr_en   = 1'b1;
    end
end

// ---------------------------------------------------------------------------
// Line SRAM read-bank delay always: 锁存上一拍读取的 line SRAM bank。
// SRAM 同步读下一拍返回 dout，因此需要用延迟后的 bank 选择正确数据。
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        linebuf_rd_bank_d <= 3'd0;
    end else if (buf_clr) begin
        linebuf_rd_bank_d <= 3'd0;
    end else if (linebuf_rd_en) begin
        linebuf_rd_bank_d <= linebuf_rd_bank;
    end
end
// ---------------------------------------------------------------------------
// Bottom SRAM read-bank delay always: 锁存上一拍读取的 bottom SRAM bank。
// bottom_buffer 同步读下一拍返回 dout。
// ---------------------------------------------------------------------------
// === BOTTOM/CORNER ADD START: bottom_buffer 同步读 bank 延迟 ===
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bottombuf_rd_bank_d <= 3'd0;
    end else if (buf_clr) begin
        bottombuf_rd_bank_d <= 3'd0;
    end else if (bottombuf_rd_en) begin
        bottombuf_rd_bank_d <= bottombuf_rd_bank;
    end
end
// ---------------------------------------------------------------------------
// line_y_tag always: 记录 7 个 line SRAM bank 当前保存的真实全局 y 行号。
// window 读 line_buffer 时用 tag 判断 rolling bank 是否仍属于目标行。
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i_tag = 0; i_tag < 7; i_tag = i_tag + 1) begin
            line_y_tag[i_tag] <= 13'h1fff;
        end
    end else if (buf_clr) begin
        for (i_tag = 0; i_tag < 7; i_tag = i_tag + 1) begin
            line_y_tag[i_tag] <= 13'h1fff;
        end
    end else begin
        if (recv_linebuf_en) begin
            // frame_top 前 7 行直接写入 line SRAM，此时 bank 保存的真实全局 y 也要同步更新。
            line_y_tag[linebuf_wr_row] <= block_start_y + {6'd0, row_cnt};
        end
        if ((cur_state == ST_WRITEBACK) &&(line_wr_state == LW_WRITE) && calc_last_seg_in_row)  begin
            // row>=7 的写回通过 line write FSM 完成；tag 跟随当前写回行更新。
            line_y_tag[line_wr_req_bank] <= block_start_y + {6'd0, calc_row_cnt};
        end
    end
end

// ---------------------------------------------------------------------------
// Line write FSM always: 执行 line_buffer 写请求。
// 非整 160bit word 写入会执行 RMW，跨 word 时自动拆分。
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        line_wr_state       <= LW_IDLE;
        line_wr_cur_x       <= 13'd0;
        line_wr_rem_len     <= 5'd0;
        line_wr_data_offset <= 5'd0;
        line_wr_start_lane  <= 4'd0;
        line_wr_chunk_len   <= 5'd0;
        line_wr_merge_word  <= {LINEBUF_WORD_W{1'b0}};
    end else if (buf_clr) begin
        line_wr_state       <= LW_IDLE;
        line_wr_cur_x       <= 13'd0;
        line_wr_rem_len     <= 5'd0;
        line_wr_data_offset <= 5'd0;
        line_wr_start_lane  <= 4'd0;
        line_wr_chunk_len   <= 5'd0;
        line_wr_merge_word  <= {LINEBUF_WORD_W{1'b0}};
    end else begin
        case (line_wr_state)
            LW_IDLE: begin
                if (line_wr_start && (line_wr_req_len != 5'd0)) begin
                    // 新写请求进入时，根据起始 x 计算当前 word 内的 start lane 和本次 chunk 长度。
                    line_wr_cur_x       <= line_wr_req_x;
                    line_wr_rem_len     <= line_wr_req_len;
                    line_wr_data_offset <= 5'd0;
                    line_wr_start_lane  <= line_wr_req_x[3:0];
                    if ((5'd16 - {1'b0, line_wr_req_x[3:0]}) < line_wr_req_len) begin
                        line_wr_chunk_len <= 5'd16 - {1'b0, line_wr_req_x[3:0]};
                    end else begin
                        line_wr_chunk_len <= line_wr_req_len;
                    end
                    if ((line_wr_req_x[3:0] == 4'd0) && (line_wr_req_len == 5'd16)) begin
                        // 完整覆盖一个 160bit word 时不需要读旧数据，直接写入。
                        line_wr_merge_word <= line_wr_req_pixels;
                        line_wr_state <= LW_WRITE;
                    end else begin
                        // 只覆盖部分 lane 时必须先读旧 word，再 merge 后整 word 写回。
                        line_wr_state <= LW_READ;
                    end
                end
            end
            LW_READ: begin
                line_wr_state <= LW_MERGE;
            end
            LW_MERGE: begin
                // 默认保留旧 word，循环中只替换本次请求覆盖的 lane。
                line_wr_merge_word <= linebuf_rd_data_mux;
                for (i_word = 0; i_word < 16; i_word = i_word + 1) begin
                    if ((i_word[4:0] >= {1'b0, line_wr_start_lane}) &&
                        (i_word[4:0] < ({1'b0, line_wr_start_lane} + line_wr_chunk_len))) begin
                        line_wr_merge_word[i_word*PIXEL_W +: PIXEL_W] <=
                            line_wr_req_pixels[(line_wr_data_offset + i_word[4:0] - {1'b0, line_wr_start_lane})*PIXEL_W +: PIXEL_W];
                    end
                end
                line_wr_state <= LW_WRITE;
            end
            LW_WRITE: begin
                if (line_wr_rem_len == line_wr_chunk_len) begin
                    line_wr_state <= LW_DONE;
                end else begin
                    // 跨 word 写入时，跳到下一个 16 像素对齐 word 继续处理剩余像素。
                    line_wr_cur_x       <= {line_wr_cur_x[12:4] + 9'd1, 4'd0};
                    line_wr_rem_len     <= line_wr_rem_len - line_wr_chunk_len;
                    line_wr_data_offset <= line_wr_data_offset + line_wr_chunk_len;
                    line_wr_start_lane  <= 4'd0;
                    line_wr_chunk_len   <= line_wr_rem_len - line_wr_chunk_len;
                    line_wr_state       <= LW_READ;
                end
            end
            LW_DONE: begin
                line_wr_state <= LW_IDLE;
            end
            default: begin
                line_wr_state <= LW_IDLE;
            end
        endcase
    end
end
// ---------------------------------------------------------------------------
// Right read FSM always: 在 line_buffer 旧行被覆盖前读取该旧行最右 7 列。
// 读出的像素保存到 right_buffer，供右侧 block 读取左侧 halo。
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        right_rd_state      <= RR_IDLE;
        right_rd_start_lane <= 4'd0;
        right_rd_cross_word <= 1'b0;
    end else if (buf_clr) begin
        right_rd_state      <= RR_IDLE;
        right_rd_start_lane <= 4'd0;
        right_rd_cross_word <= 1'b0;
    end else begin
        case (right_rd_state)
            RR_IDLE: begin
                if (right_rd_start) begin
                    // right_base_x 通常是 block 最右 7 列起点；如果起点落在 lane9 之后，7 列会跨两个 word。
                    right_rd_start_lane <= right_rd_x[3:0];
                    right_rd_cross_word <= (right_rd_x[3:0] > 4'd9);
                    right_rd_state      <= RR_READ0;
                end
            end
            RR_READ0: begin
                right_rd_state <= RR_SAVE0;
            end
            RR_SAVE0: begin
                // 先保存第一个 word 中能覆盖到的右边界像素。
                for (i_rr = 0; i_rr < RIGHT_COLS; i_rr = i_rr + 1) begin
                    if (({1'b0, right_rd_start_lane} + i_rr[4:0]) < 5'd16) begin
                        right_buffer[right_rd_dst_row][i_rr] <=
                            linebuf_rd_data_mux[({1'b0, right_rd_start_lane} + i_rr[4:0])*PIXEL_W +: PIXEL_W];
                    end
                end
                if (right_rd_cross_word) begin
                    right_rd_state <= RR_READ1;
                end else begin
                    right_rd_state <= RR_DONE;
                end
            end
            RR_READ1: begin
                right_rd_state <= RR_SAVE1;
            end
            RR_SAVE1: begin
                // 如果右 7 列跨 word，第二次读负责补齐剩余像素。
                for (i_rr = 0; i_rr < RIGHT_COLS; i_rr = i_rr + 1) begin
                    if (({1'b0, right_rd_start_lane} + i_rr[4:0]) >= 5'd16) begin
                        right_buffer[right_rd_dst_row][i_rr] <=
                            linebuf_rd_data_mux[({1'b0, right_rd_start_lane} + i_rr[4:0] - 5'd16)*PIXEL_W +: PIXEL_W];
                    end
                end
                right_rd_state <= RR_DONE;
            end
            RR_DONE: begin
                right_rd_state <= RR_IDLE;
            end
            default: begin
                right_rd_state <= RR_IDLE;
            end
        endcase
    end
end
// ---------------------------------------------------------------------------
// Bottom write FSM always: 将当前 block 最后 7 行写入 bottom_buffer。
// 当前假设 x/width 16 对齐，因此 bottom 直接整 160bit word 写。
// ---------------------------------------------------------------------------
// === BOTTOM/CORNER ADD START: bottom_buffer 写状态机 ===
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bottom_wr_state <= BW_IDLE;
    end else if (buf_clr) begin
        bottom_wr_state <= BW_IDLE;
    end else begin
        case (bottom_wr_state)
            BW_IDLE: begin
                if (bottom_wr_start) begin
                    // bottom 写请求已经在 WB_* 中准备好 bank/address/data，这里只负责打一拍写使能。
                    bottom_wr_state <= BW_WRITE;
                end
            end
            BW_WRITE: begin
                bottom_wr_state <= BW_DONE;
            end
            BW_DONE: begin
                bottom_wr_state <= BW_IDLE;
            end
            default: begin
                bottom_wr_state <= BW_IDLE;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// Corner save FSM always: 在 bottom_buffer 被当前 block 覆盖前保存旧 bottom 的右下 7x7。
// 保存后的 corner_buffer 供右下相邻 block 读取左上角 halo。
// ---------------------------------------------------------------------------
// === BOTTOM/CORNER ADD START: corner_buffer 保存状态机 ===
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        corner_rd_state <= CR_IDLE;
        corner_rd_idx <= 3'd0;
        corner_rd_addr <= {LINEBUF_ADDR_W{1'b0}};
        corner_rd_start_lane <= 4'd0;
        corner_valid <= 1'b0;
        corner_for_block_start_x <= 13'd0;
        corner_for_block_start_y <= 13'd0;
    end else begin
        case (corner_rd_state)
            CR_IDLE: begin
                if (corner_rd_start) begin
                    // 当前 block 开始覆盖旧 bottom 前，从旧 bottom 的右 7 列连续读 7 行。
                    corner_rd_idx <= 3'd0;
                    corner_rd_addr <= right_base_x[11:4];
                    corner_rd_start_lane <= right_base_x[3:0];
                    corner_rd_state <= CR_READ;
                end
            end
            CR_READ: begin
                corner_rd_state <= CR_SAVE;
            end
            CR_SAVE: begin
                // 保存旧 bottom 的一行右 7 列，7 次后形成 7x7 corner。
                //覆盖前boottom前保存
                for (i_corner = 0; i_corner < CORNER_PIX; i_corner = i_corner + 1) begin
                    corner_buffer[corner_rd_idx][i_corner] <=
                        bottombuf_rd_data_mux[({1'b0, corner_rd_start_lane} + i_corner[4:0])*PIXEL_W +: PIXEL_W];
                end
                if (corner_rd_idx == 3'd6) begin
                    // corner 只给右侧相邻 block 使用，因此 tag 指向 block_start_x + block_width。
                    corner_valid <= 1'b1;
                    corner_for_block_start_x <= block_start_x + {5'd0, block_pixel_width};
                    corner_for_block_start_y <= block_start_y;
                    corner_rd_state <= CR_DONE;
                end else begin
                    corner_rd_idx <= corner_rd_idx + 1'b1;
                    corner_rd_state <= CR_READ;
                end
            end
            CR_DONE: begin
                corner_rd_state <= CR_IDLE;
            end
            default: begin
                corner_rd_state <= CR_IDLE;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// Writeback scheduler always: 调度当前 segment 计算完成后的所有写回动作。
// 顺序处理 right、left7、cur16、corner 和 bottom，避免端口冲突。
//负责数据写回
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wb_state           <= WB_IDLE;
        line_wr_start      <= 1'b0;
        right_rd_start     <= 1'b0;
        bottom_wr_start    <= 1'b0;
        corner_rd_start    <= 1'b0;
        line_wr_req_bank   <= 3'd0;
        line_wr_req_x      <= 13'd0;
        line_wr_req_len    <= 5'd0;
        line_wr_req_pixels <= {LINEBUF_WORD_W{1'b0}};
        right_rd_bank      <= 3'd0;
        right_rd_x         <= 13'd0;
        right_rd_dst_row   <= 5'd0;
        bottom_wr_req_bank <= 3'd0;
        bottom_wr_req_addr <= {LINEBUF_ADDR_W{1'b0}};
        bottom_wr_req_data <= {LINEBUF_WORD_W{1'b0}};
        flush_idx          <= 3'd0;
    end else if (buf_clr) begin
        wb_state           <= WB_IDLE;
        line_wr_start      <= 1'b0;
        right_rd_start     <= 1'b0;
        bottom_wr_start    <= 1'b0;
        corner_rd_start    <= 1'b0;
        line_wr_req_bank   <= 3'd0;
        line_wr_req_x      <= 13'd0;
        line_wr_req_len    <= 5'd0;
        line_wr_req_pixels <= {LINEBUF_WORD_W{1'b0}};
        right_rd_bank      <= 3'd0;
        right_rd_x         <= 13'd0;
        right_rd_dst_row   <= 5'd0;
        bottom_wr_req_bank <= 3'd0;
        bottom_wr_req_addr <= {LINEBUF_ADDR_W{1'b0}};
        bottom_wr_req_data <= {LINEBUF_WORD_W{1'b0}};
        flush_idx          <= 3'd0;
    end else begin
        line_wr_start   <= 1'b0;
        right_rd_start  <= 1'b0;
        bottom_wr_start <= 1'b0;
        corner_rd_start <= 1'b0;
        if (cur_state == ST_FLUSH_RIGHT) begin
            // block 结束后，最后 7 行不会再被后续行自然淘汰，需要主动补存 right_buffer。
            wb_state <= WB_IDLE;
            if (flush_idx < 3'd6) begin
                if (right_rd_state == RR_IDLE) begin
                    right_rd_bank    <= flush_linebuf_row;
                    right_rd_x       <= right_base_x;
                    right_rd_dst_row <= flush_row_cnt[4:0];
                    right_rd_start   <= 1'b1;
                end else if (right_rd_done) begin
                    flush_idx <= flush_idx + 1'b1;
                end
            end else begin
                // 最后一行仍在 cur16_reg 中，直接取最后 7 个有效像素写入 right_buffer。
                for (i_right = 0; i_right < RIGHT_COLS; i_right = i_right + 1) begin
                    right_buffer[flush_row_cnt[4:0]][i_right] <= cur16_reg[cur16_right_base_idx[3:0] + i_right[3:0]];
                end
                flush_idx <= 3'd0;
            end
        end else if (cur_state != ST_WRITEBACK) begin
            wb_state <= WB_IDLE;
        end else begin
            case (wb_state)
                WB_IDLE: begin
                    if (save_evict_right_en) begin
                        // 当前行最后一段写回前，先保存即将被覆盖的“7 行前旧行”的右 7 列。
                        right_rd_bank    <= calc_linebuf_row;
                        right_rd_x       <= right_base_x;
                        right_rd_dst_row <= evict_right_row_idx;
                        right_rd_start   <= 1'b1;
                        wb_state         <= WB_SAVE_RIGHT;
                    end else if (!calc_first_seg_in_row) begin
                        // 非本行第一段时，上一段末尾 7 个像素已不再需要旁路，先写回 line SRAM。
                        line_wr_req_bank   <= calc_linebuf_row;
                        line_wr_req_x      <= calc_global_x_base - 13'd7;
                        line_wr_req_len    <= 5'd7;
                        line_wr_req_pixels <= {LINEBUF_WORD_W{1'b0}};
                        for (i_line = 0; i_line < X_KEEP_PIX; i_line = i_line + 1) begin
                            line_wr_req_pixels[i_line*PIXEL_W +: PIXEL_W] <= left7_reg[i_line];
                        end
                        line_wr_start <= 1'b1;
                        wb_state      <= WB_WRITE_L7;
                    end else begin
                        // 本行第一段没有 left7，直接写当前段前 9 个像素；最后段则写所有有效像素。
                        line_wr_req_bank   <= calc_linebuf_row;
                        line_wr_req_x      <= calc_global_x_base;
                        line_wr_req_len    <= calc_last_seg_in_row ? cur_write_len : 5'd9;
                        line_wr_req_pixels <= {LINEBUF_WORD_W{1'b0}};
                        for (i_line = 0; i_line < IN_PIX_PER_CYC; i_line = i_line + 1) begin
                            line_wr_req_pixels[i_line*PIXEL_W +: PIXEL_W] <= cur16_reg[i_line];
                        end
                        line_wr_start <= 1'b1;
                        wb_state      <= WB_WRITE_CUR;
                    end
                end
                WB_SAVE_RIGHT: begin
                    if (right_rd_done) begin
                        // right 保存完成后，再继续原本的 left7/cur16 写回流程。
                        if (!calc_first_seg_in_row) begin
                            line_wr_req_bank   <= calc_linebuf_row;
                            line_wr_req_x      <= calc_global_x_base - 13'd7;
                            line_wr_req_len    <= 5'd7;
                            line_wr_req_pixels <= {LINEBUF_WORD_W{1'b0}};
                            for (i_line = 0; i_line < X_KEEP_PIX; i_line = i_line + 1) begin
                                line_wr_req_pixels[i_line*PIXEL_W +: PIXEL_W] <= left7_reg[i_line];
                            end
                            line_wr_start <= 1'b1;
                            wb_state      <= WB_WRITE_L7;
                        end else begin
                            line_wr_req_bank   <= calc_linebuf_row;
                            line_wr_req_x      <= calc_global_x_base;
                            line_wr_req_len    <= calc_last_seg_in_row ? cur_write_len : 5'd9;
                            line_wr_req_pixels <= {LINEBUF_WORD_W{1'b0}};
                            for (i_line = 0; i_line < IN_PIX_PER_CYC; i_line = i_line + 1) begin
                                line_wr_req_pixels[i_line*PIXEL_W +: PIXEL_W] <= cur16_reg[i_line];
                            end
                            line_wr_start <= 1'b1;
                            wb_state      <= WB_WRITE_CUR;
                        end
                    end
                end
                WB_WRITE_L7: begin
                    if (line_wr_done) begin
                        // left7 已经写回，继续写当前 cur16 段的安全部分。
                        line_wr_req_bank   <= calc_linebuf_row;
                        line_wr_req_x      <= calc_global_x_base;
                        line_wr_req_len    <= calc_last_seg_in_row ? cur_write_len : 5'd9;
                        line_wr_req_pixels <= {LINEBUF_WORD_W{1'b0}};
                        for (i_line = 0; i_line < IN_PIX_PER_CYC; i_line = i_line + 1) begin
                            line_wr_req_pixels[i_line*PIXEL_W +: PIXEL_W] <= cur16_reg[i_line];
                        end
                        line_wr_start <= 1'b1;
                        wb_state      <= WB_WRITE_CUR;
                    end
                end
                WB_WRITE_CUR: begin
                    if (line_wr_done) begin
                        if (!calc_last_seg_in_row) begin
                            // 非最后段时，当前段末尾 7 个像素还要给下一段计算使用，暂存到 left7_reg。
                            for (i_line = 0; i_line < X_KEEP_PIX; i_line = i_line + 1) begin
                                left7_reg[i_line] <= cur16_reg[X_SAFE_COMMIT + i_line];
                            end
                        end
                        if (bottom_save_en) begin
                            // === BOTTOM/CORNER ADD START: WB 中调度 corner 保存或 bottom 写入 ===
                            if (save_corner_en) begin
                                // 当前 block 第一次覆盖旧 bottom 前，先把旧 bottom 的右下角保存到 corner。
                                corner_rd_start <= 1'b1;
                                wb_state <= WB_SAVE_CORNER;
                            end else begin
                                // 当前行属于 block 最后 7 行，写入 bottom_buffer 供下一条 block-row 使用。
                                bottom_wr_req_bank <= bottom_wr_req_bank_calc;
                                bottom_wr_req_addr <= calc_global_x_base[11:4];
                                bottom_wr_req_data <= {LINEBUF_WORD_W{1'b0}};
                                for (i_line = 0; i_line < IN_PIX_PER_CYC; i_line = i_line + 1) begin
                                    bottom_wr_req_data[i_line*PIXEL_W +: PIXEL_W] <= cur16_reg[i_line];
                                end
                                bottom_wr_start <= 1'b1;
                                wb_state <= WB_WRITE_BOTTOM;
                            end
                            
                        end else begin
                            wb_state <= WB_DONE;
                        end
                    end
                end
                WB_SAVE_CORNER: begin
                    // === BOTTOM/CORNER ADD START: corner 保存完成后再写当前 bottom ===
                    if (corner_rd_done) begin
                        // corner 保存完成后，允许当前 block 的 bottom 数据覆盖 bottom_buffer。
                        bottom_wr_req_bank <= bottom_wr_req_bank_calc;
                        bottom_wr_req_addr <= calc_global_x_base[11:4];
                        bottom_wr_req_data <= {LINEBUF_WORD_W{1'b0}};
                        for (i_line = 0; i_line < IN_PIX_PER_CYC; i_line = i_line + 1) begin
                            bottom_wr_req_data[i_line*PIXEL_W +: PIXEL_W] <= cur16_reg[i_line];
                        end
                        bottom_wr_start <= 1'b1;
                        wb_state <= WB_WRITE_BOTTOM;
                    end
                    
                end
                WB_WRITE_BOTTOM: begin
                    // === BOTTOM/CORNER ADD START: 等待 bottom_buffer 写入完成 ===
                    if (bottom_wr_done) begin
                        wb_state <= WB_DONE;
                    end
                    
                end
                WB_DONE: begin
                    wb_state <= WB_IDLE;
                end
                default: begin
                    wb_state <= WB_IDLE;
                end
            endcase
        end
    end
end

endmodule
