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

    lanczos_center_x,
    lanczos_center_y,
    lanczos_window_req,                  //请求读取64个像素
    lanczos_window_busy,                 //表示 window read 状态机正在工作。为 1 时说明 64 个 tap 还没读完，Lanczos 不应该再发新的 lanczos_window_req。
    lanczos_window_pixels,                //当前8x8窗口的像素值，按照tap_idx=0~63顺序打包，每个像素10bit，总共640bit。
    lanczos_window_valid_mask,
    lanczos_window_valid,
    lanczos_window_from_right_mask
);

// ---------------------------------------------------------------------------
// Current scope:
//   1. frame_top block line_buffer receive / Lanczos handshake / writeback.
//   2. right_buffer save for blocks that are not frame/tile right edge.
//   3. Lanczos tap read mux for current block pixels and left halo from
//      right_buffer.
//   4. Tile boundary, non-frame-top compute, bottom_buffer and corner_buffer
//      are intentionally left for later.
// ---------------------------------------------------------------------------

parameter PIXEL_W          = 10;
parameter IN_PIX_PER_CYC  = 16;
parameter IMG_W            = 4096;
parameter IMG_X_W          = 12;
parameter LINEBUF_WORD_W   = 160;
parameter LINEBUF_WORDS    = 256;
parameter LINEBUF_ADDR_W   = 8;
parameter LANCZOS_TAPS     = 8;
parameter TAP_COORD_W      = 14;
parameter X_SAFE_COMMIT    = 9;
parameter X_KEEP_PIX       = 7;
parameter X_CALC_RIGHT_GAP = 4;
parameter RIGHT_COLS       = 7;
parameter BLOCK_MAX_H      = 32;

localparam signed [TAP_COORD_W-1:0] TAP_ZERO    = 14'sd0;
localparam signed [TAP_COORD_W-1:0] TAP_ONE     = 14'sd1;
localparam signed [TAP_COORD_W-1:0] TAP_TWO     = 14'sd2;
localparam signed [TAP_COORD_W-1:0] TAP_THREE   = 14'sd3;
localparam signed [TAP_COORD_W-1:0] TAP_FOUR    = 14'sd4;
localparam signed [TAP_COORD_W-1:0] TAP_SEVEN   = 14'sd7;
localparam signed [TAP_COORD_W-1:0] TAP_SIXTEEN = 14'sd16;

input clk;
input rst_n;

input [53:0] fg2pp_ctrl;   // block开始前更新的控制信息，包含尺寸、坐标、frame/tile边界
input [12:0] sw_pic_height; // 当前整帧图像高度，用于frame bottom边界clip
input [12:0] sw_upscale_pic_width; // 当前整帧图像宽度，用于frame right边界clip
input        ctrl_update_en; // 控制信息锁存使能，通常在新block开始前拉高

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

// Lanczos 8x8 window read interface.
// lanczos_center_x/y 是原图全局整数中心坐标，例如 floor(src_x/src_y)。
// 模块内部按 -3,-2,-1,0,+1,+2,+3,+4 的标准顺序生成 x/y 方向各 8 个 tap。
input signed [TAP_COORD_W-1:0] lanczos_center_x;   //lanczos模块给出需要计算坐标的整数部分
input signed [TAP_COORD_W-1:0] lanczos_center_y;
input                            lanczos_window_req;
output                           lanczos_window_busy;
output [LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W-1:0] lanczos_window_pixels;
output [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_valid_mask;
output                                           lanczos_window_valid;
output [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_from_right_mask;

// ---------------------------------------------------------------------------
// Control registers from fg2pp_ctrl.
// ---------------------------------------------------------------------------
reg [6:0]  block_pixel_height; // 当前block高度，单位是像素行
reg [7:0]  block_pixel_width;  // 当前block宽度，单位是像素列
reg        frame_top_edge;     // 当前block位于整帧最上方
reg        frame_bottom_edge;  // 当前block位于整帧最下方
reg        frame_left_edge;    // 当前block位于整帧最左侧
reg        frame_right_edge;   // 当前block位于整帧最右侧
reg        tile_top_edge;      // 当前block位于tile顶部，当前阶段暂不处理tile跨界
reg        tile_bottom_edge;   // 当前block位于tile底部，当前阶段暂不处理tile跨界
reg        tile_left_edge;     // 当前block位于tile左侧，当前阶段暂不处理tile跨界
reg        tile_right_edge;    // 当前block位于tile右侧，当前阶段暂不处理tile跨界
reg [12:0] block_start_x;      // 当前block左上角的全局x坐标
reg [12:0] block_start_y;      // 当前block左上角的全局y坐标
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
// line_buffer SRAM: 7 banks, each bank stores one 4096-pixel row as 256x160bit words.
reg [PIXEL_W-1:0] cur16_reg    [0:IN_PIX_PER_CYC-1];          // 当前送给Lanczos计算的16个像素段
reg [PIXEL_W-1:0] left7_reg    [0:X_KEEP_PIX-1];              // 上一段的最后7个像素，等下一段算完后写回line SRAM
reg [PIXEL_W-1:0] right_buffer [0:BLOCK_MAX_H-1][0:RIGHT_COLS-1]; // 当前block右7列，供右侧block做左边界计算
reg [12:0]        line_y_tag   [0:6];                          // 7个line SRAM bank当前保存的真实全局y行号

wire [LINEBUF_ADDR_W-1:0] linebuf_ra   [0:6];
wire                      linebuf_re   [0:6];
wire [LINEBUF_WORD_W-1:0] linebuf_dout [0:6];
wire [LINEBUF_ADDR_W-1:0] linebuf_wa   [0:6];
wire                      linebuf_we   [0:6];
wire [LINEBUF_WORD_W-1:0] linebuf_di   [0:6];

reg [2:0]                 linebuf_rd_bank;
reg [2:0]                 linebuf_rd_bank_d;  //同步 SRAM 读数据下一拍才回来，所以需要记住“上一拍读的是哪个 bank
reg [LINEBUF_ADDR_W-1:0]  linebuf_rd_addr;
reg                       linebuf_rd_en;
reg [2:0]                 linebuf_wr_bank;
reg [LINEBUF_ADDR_W-1:0]  linebuf_wr_addr;
reg [LINEBUF_WORD_W-1:0]  linebuf_wr_data;
reg                       linebuf_wr_en;
wire [LINEBUF_WORD_W-1:0] linebuf_rd_data_mux;
wire [`CHIP_MEM_POWER_CTRL-1:0] linebuf_pwrbus_ram_pd;

assign linebuf_pwrbus_ram_pd = {`CHIP_MEM_POWER_CTRL{1'b0}};

//例化了7个sram256x160

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

// 根据上一拍真正发出的读bank选择同步SRAM返回的数据。
assign linebuf_rd_data_mux = linebuf_dout[linebuf_rd_bank_d];

reg [LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W-1:0] lanczos_window_pixels_r;
reg [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_valid_mask_r;
reg [LANCZOS_TAPS*LANCZOS_TAPS-1:0]         lanczos_window_from_right_mask_r;
reg                                           lanczos_window_valid_r;

reg        lanczos_start_r;
reg [7:0]  calc_x_end;
reg [6:0]  calc_y_end;

assign lanczos_start = lanczos_start_r;    //lanczos计算信号
assign lanczos_x_end = calc_x_end;         //当前lanczos可以计算的x范围
assign lanczos_y_end = calc_y_end;         //当前lanczos可以计算的y范围
assign lanczos_window_pixels = lanczos_window_pixels_r;  //当前8x8窗口像素值
assign lanczos_window_valid_mask = lanczos_window_valid_mask_r;
assign lanczos_window_valid = lanczos_window_valid_r;
assign lanczos_window_from_right_mask = lanczos_window_from_right_mask_r;

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
wire [4:0] evict_right_row_idx;
wire [6:0] evict_right_row;
wire [8:0] cur_write_len_full;
wire [4:0] cur_write_len;

// Metadata of the segment currently stored in cur16_reg.
reg [7:0]  calc_block_x_base;      // current 16-pixel segment x base in block
reg [12:0] calc_global_x_base;     // current 16-pixel segment x base in frame
reg [2:0]  calc_linebuf_row;       // line SRAM bank used by current calc row
reg [6:0]  calc_row_cnt;           // current row index inside current block
reg        calc_first_seg_in_row;  // current segment is first segment in row
reg        calc_last_seg_in_row;   // current segment is last segment in row
reg        calc_last_row_in_block; // current segment belongs to block last row

localparam [2:0] ST_IDLE         = 3'd0;
localparam [2:0] ST_RECV         = 3'd1;
localparam [2:0] ST_LANCZOS_BUSY = 3'd2;
localparam [2:0] ST_WRITEBACK    = 3'd3;
localparam [2:0] ST_FLUSH_RIGHT  = 3'd4;

reg [2:0] cur_state;
reg [2:0] nxt_state;

assign in_block_x_base   = {seg16_x, 4'b0000};
assign in_global_x_base  = block_start_x + {5'd0, seg16_x, 4'b0000};
assign linebuf_wr_row_mod= row_cnt % 7'd7;
assign linebuf_wr_row    = linebuf_wr_row_mod[2:0];

assign frame_top_fill_linebuf = frame_top_edge && data_fire && (row_cnt < 7'd7);
assign frame_top_calc_segment = frame_top_edge && data_fire && (row_cnt >= 7'd7);

assign cur_segment_x_end = last_seg_in_row ?
                           (block_pixel_width - 8'd4) :
                           (in_block_x_base + 8'd12);
assign cur_segment_y_end = row_cnt - 7'd4;

assign right_save_en = !frame_right_edge;
assign right_base_x  = block_start_x + {5'd0, block_pixel_width} - 13'd7;
assign cur_write_len_full = {1'b0, block_pixel_width} - {1'b0, calc_block_x_base};
assign cur_write_len      = cur_write_len_full[4:0];
assign evict_right_row     = calc_row_cnt - 7'd7;
assign evict_right_row_idx = evict_right_row[4:0];

// ---------------------------------------------------------------------------
// Lanczos 8x8 window tap offset.
// Standard order: -3,-2,-1,0,+1,+2,+3,+4.
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Low-speed 8x8 window read FSM.
//
// 每次lanczos_window_req锁存一个center坐标，然后按win_idx=0~63逐点取数。
// right_buffer/cur16_reg/left7_reg是寄存器，当前拍即可保存结果；
// line SRAM是同步读，所以历史行像素需要WIN_SRAM_READ/WIN_SRAM_SAVE两拍完成。
// ---------------------------------------------------------------------------
//window状态机状态
localparam [2:0] WIN_IDLE      = 3'd0;  //空闲，等待 lanczos_window_req
localparam [2:0] WIN_TAP_PREP  = 3'd1;  //准备当前 tap 的坐标，判断这个 tap 应该从哪里取
localparam [2:0] WIN_SRAM_READ = 3'd2;  //如果当前 tap 来自 line SRAM，这一拍发 SRAM 读请求
localparam [2:0] WIN_SRAM_SAVE = 3'd3;  //同步 SRAM 数据返回后，把对应 lane 的 10bit 像素保存到 lanczos_window_pixels_r
localparam [2:0] WIN_DONE      = 3'd4;  //64 个 tap 都处理完成，拉高 lanczos_window_valid_r 一拍
//取数来源
localparam [2:0] WIN_SRC_INVALID = 3'd0;  //当前 tap 无效，比如超出当前可计算窗口
localparam [2:0] WIN_SRC_RIGHT   = 3'd1;  //当前 tap 来自左侧 block 保存下来的 right_buffer
localparam [2:0] WIN_SRC_CUR16   = 3'd2;  //当前 tap 位于当前刚输入的 16 像素段，直接从 cur16_reg 取
localparam [2:0] WIN_SRC_LEFT7   = 3'd3;  //当前 tap 位于上一段最后 7 个还没写回 SRAM 的像素，从 left7_reg 取。
localparam [2:0] WIN_SRC_LINE    = 3'd4;  //当前 tap 来自历史 7 行，从 line SRAM 取

reg [2:0] win_state;                     //当前 window read 状态机状态
reg [5:0] win_idx;                       //当前正在处理第几个 tap，范围 0~63   win_idx[2:0] 表示 x 方向 tap index，win_idx[5:3] 表示 y 方向 tap index
reg signed [TAP_COORD_W-1:0] win_center_x_r;  //锁存本次请求的中心坐标
reg signed [TAP_COORD_W-1:0] win_center_y_r;  //
reg [2:0] win_line_rd_bank;                   //当 tap 需要从 line SRAM 读取时，分别记录要读哪个 bank、哪个 160bit word、word 内哪个 10bit lane。
reg [LINEBUF_ADDR_W-1:0] win_line_rd_addr;
reg [3:0] win_line_rd_lane;
reg [5:0] win_line_save_idx;                  //记录当前 SRAM 返回的数据应该写回到 64 tap 输出窗口里的第几个位置

reg signed [TAP_COORD_W-1:0] win_tap_x_g;
reg signed [TAP_COORD_W-1:0] win_tap_y_g;
reg signed [TAP_COORD_W-1:0] win_clip_x_g;
reg signed [TAP_COORD_W-1:0] win_clip_y_g;
reg signed [TAP_COORD_W-1:0] win_local_x;
reg signed [TAP_COORD_W-1:0] win_local_y;
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
reg [2:0]  win_src_sel;
reg [PIXEL_W-1:0] win_direct_pixel;
reg        win_direct_valid;
reg        win_direct_from_right;
reg        win_tap_y_in_block;
reg        win_tap_y_in_window;
reg        win_line_tag_match;

assign lanczos_window_busy = (win_state != WIN_IDLE);

// Lanczos 8x8 窗口读像素的“来源选择组合逻辑  如果像素在寄存器里，当前拍直接给；如果在 line SRAM 里，就告诉后面的 FSM 去读哪个 bank、哪个 word、哪个 lane。
always @(*) begin
    win_src_sel = WIN_SRC_INVALID;
    win_direct_pixel = {PIXEL_W{1'b0}};
    win_direct_valid = 1'b0;
    win_direct_from_right = 1'b0;

    win_frame_width_s = {1'b0, sw_upscale_pic_width};
    win_frame_height_s = {1'b0, sw_pic_height};
    win_block_start_x_s = {1'b0, block_start_x};
    win_block_start_y_s = {1'b0, block_start_y};

    win_tap_x_g = win_center_x_r + tap_offset_by_idx(win_idx[2:0]);   //win_idx 是 0~63，表示 8x8 窗口里的第几个 tap
    win_tap_y_g = win_center_y_r + tap_offset_by_idx(win_idx[5:3]);

    // Lanczos给全局tap坐标；这里先按frame边界做clamp
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

    //block内部坐标
    win_local_x = win_clip_x_g - win_block_start_x_s;
    win_local_y = win_clip_y_g - win_block_start_y_s;
    //无符号化后用于后续的地址计算和比较
    win_clip_x_u = win_clip_x_g[12:0];
    win_clip_y_u = win_clip_y_g[12:0];
    win_local_y_u = win_local_y[6:0];
    //行号模7后得到在line SRAM中对应的bank编号  7个bank
    win_linebuf_row_mod = win_local_y_u % 7'd7;
    win_linebuf_row = win_linebuf_row_mod[2:0];
    // 160bit word 地址，一个 word = 16 像素
    win_line_addr = win_clip_x_u[11:4];
    // 160bit word 里的第几个像素
    win_line_lane = win_clip_x_u[3:0];
    //win_line_tag_match 用来确认这个 bank 里现在存的确实是目标全局 y 行
    win_line_tag_match = (line_y_tag[win_linebuf_row] == win_clip_y_u);

    win_block_width_s = {6'b0, block_pixel_width};
    win_block_height_s = {7'b0, block_pixel_height};
    win_calc_row_cnt_s = {7'b0, calc_row_cnt};
    //y方向最小计算范围
    win_tap_y_min_s = (calc_row_cnt >= 7'd7) ? ({7'b0, calc_row_cnt} - TAP_SEVEN) : TAP_ZERO;
    //判断y再当前block范围
    win_tap_y_in_block = (win_local_y >= TAP_ZERO) && (win_local_y < win_block_height_s);
    //判断tap_y的坐标在不在当前的
    win_tap_y_in_window = (win_local_y >= win_tap_y_min_s) && (win_local_y <= win_calc_row_cnt_s);

    //calc_block_x_base 是当前 16 像素段在 block 内部的 x 起点
    //+16 -7分别是当前16像素的右边界 和 当前段左边那 7 个像素的起点
    win_calc_x_base_s = {6'b0, calc_block_x_base};
    win_calc_x_limit_s = {6'b0, calc_block_x_base} + TAP_SIXTEEN;
    win_calc_left7_base_s = {6'b0, calc_block_x_base} - TAP_SEVEN;
    //full 保留真实 signed 运算结果，idx 是在范围判断成立后才使用的窄位宽数组下标。
    win_right_idx_full = win_local_x + TAP_SEVEN;            //0~6 表示右侧buffer里面的7列相对位置
    win_cur16_idx_full = win_local_x - win_calc_x_base_s;   //0~15 表示在当前16像素段的相对位置
    win_left7_idx_full = win_local_x - win_calc_left7_base_s;  //0~6 表示在上一段最后7个像素中的相对位置
    win_right_idx = win_right_idx_full[2:0];
    win_cur16_idx = win_cur16_idx_full[3:0];
    win_left7_idx = win_left7_idx_full[2:0];

    if ((cur_state == ST_LANCZOS_BUSY) && win_tap_y_in_block && win_tap_y_in_window) begin  //有在当前状态是 ST_LANCZOS_BUSY，并且 y 合法时才继续
        if (win_local_x < TAP_ZERO) begin                                          //左侧 halo：
            if (!frame_left_edge && (win_local_x >= -TAP_SEVEN)) begin
                win_src_sel = WIN_SRC_RIGHT;
                win_direct_pixel = right_buffer[win_local_y_u[4:0]][win_right_idx];
                win_direct_valid = 1'b1;
                win_direct_from_right = 1'b1;
            end
        end else if (win_local_x < win_block_width_s) begin                       
            if ((win_local_y == win_calc_row_cnt_s) &&                           //当前 16 像素段：
                (win_local_x >= win_calc_x_base_s) &&
                (win_local_x < win_calc_x_limit_s)) begin
                win_src_sel = WIN_SRC_CUR16;
                win_direct_pixel = cur16_reg[win_cur16_idx];
                win_direct_valid = 1'b1;
            end else if ((win_local_y == win_calc_row_cnt_s) &&                 //上一段最后7个像素：
                         !calc_first_seg_in_row &&
                         (win_local_x >= win_calc_left7_base_s) &&
                         (win_local_x < win_calc_x_base_s)) begin
                win_src_sel = WIN_SRC_LEFT7;
                win_direct_pixel = left7_reg[win_left7_idx];
                win_direct_valid = 1'b1;
            end else if (win_line_tag_match) begin                   //从 line SRAM 读历史行：
                win_src_sel = WIN_SRC_LINE;
                win_direct_valid = 1'b1;
            end
        end
    end
end



//收到一次 lanczos_window_req 后，把以 lanczos_center_x/y 为中心的 64 个 tap 像素一个个读出来，最后打包到： lanczos_window_pixels_r/lanczos_window_valid_mask_r 里，win_state 状态机控制整个过程。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        win_state <= WIN_IDLE;
        win_idx <= 6'd0;
        win_center_x_r <= {TAP_COORD_W{1'b0}};
        win_center_y_r <= {TAP_COORD_W{1'b0}};
        win_line_rd_bank <= 3'd0;
        win_line_rd_addr <= {LINEBUF_ADDR_W{1'b0}};
        win_line_rd_lane <= 4'd0;
        win_line_save_idx <= 6'd0;                                                    //当前这次 line SRAM 读出来的像素，应该放回 8x8 窗口里的第几个 tap 位置
        lanczos_window_pixels_r <= {(LANCZOS_TAPS*LANCZOS_TAPS*PIXEL_W){1'b0}};
        lanczos_window_valid_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
        lanczos_window_from_right_mask_r <= {(LANCZOS_TAPS*LANCZOS_TAPS){1'b0}};
        lanczos_window_valid_r <= 1'b0;                                               //表示8x8窗口数据准备好了，可以送去计算了
    end else if (buf_clr) begin                                                       //新的block来了
        win_state <= WIN_IDLE;
        win_idx <= 6'd0;
        win_center_x_r <= {TAP_COORD_W{1'b0}};
        win_center_y_r <= {TAP_COORD_W{1'b0}};
        win_line_rd_bank <= 3'd0;
        win_line_rd_addr <= {LINEBUF_ADDR_W{1'b0}};
        win_line_rd_lane <= 4'd0;
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
                    win_line_rd_bank <= win_linebuf_row;
                    win_line_rd_addr <= win_line_addr;
                    win_line_rd_lane <= win_line_lane;
                    win_line_save_idx <= win_idx;
                    win_state <= WIN_SRAM_READ;
                end else begin
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
                lanczos_window_pixels_r[win_line_save_idx*PIXEL_W +: PIXEL_W] <=
                    linebuf_rd_data_mux[win_line_rd_lane*PIXEL_W +: PIXEL_W];
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
                lanczos_window_valid_r <= 1'b1;
                win_state <= WIN_IDLE;
            end

            default: begin
                win_state <= WIN_IDLE;
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// line SRAM RMW write control.写回状态机
// ---------------------------------------------------------------------------
localparam [2:0] LW_IDLE  = 3'd0;
localparam [2:0] LW_READ  = 3'd1;   //读旧的160bit
localparam [2:0] LW_MERGE = 3'd2;   //把需要的更新的新数据替换进去
localparam [2:0] LW_WRITE = 3'd3;   //写回sram
localparam [2:0] LW_DONE  = 3'd4;   //写请求完成

reg [2:0]                line_wr_state;         //当前写状态机处于哪个状态。
reg                      line_wr_start;         //外层逻辑给写状态机的启动脉冲。拉高 1 拍，表示有一次新的 line SRAM 写请求。
reg [2:0]                line_wr_req_bank;      //这次要写 7 个 line SRAM bank 中的哪一个
reg [12:0]               line_wr_req_x;         //这次写入的全局 x 起点
reg [4:0]                line_wr_req_len;       //写入几个像素
reg [LINEBUF_WORD_W-1:0] line_wr_req_pixels;    //这次要写入的新像素数据，打包成 160bit
reg [12:0]               line_wr_cur_x;          //当前正在处理的 x 坐标
reg [4:0]                line_wr_rem_len;        //还剩多少个像素没写完
reg [4:0]                line_wr_data_offset;    //当前处理的数据在 line_wr_req_pixels 里面的偏移
reg [3:0]                line_wr_start_lane;     //当前 word 内从哪个 lane 开始写
reg [4:0]                line_wr_chunk_len;      //当前这个 word 里面本次要写多少个像素。
reg [LINEBUF_WORD_W-1:0] line_wr_merge_word;     //合并后的 160bit word
wire                     line_wr_busy;           //表示写状态机正在工作
wire                     line_wr_done;           //写请求完成

assign line_wr_busy = (line_wr_state != LW_IDLE) && (line_wr_state != LW_DONE);
assign line_wr_done = (line_wr_state == LW_DONE);

// ---------------------------------------------------------------------------
// line SRAM right-edge read control.
//暂时没看懂
// ---------------------------------------------------------------------------
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
wire       right_rd_busy;
wire       right_rd_done;

assign right_rd_busy = (right_rd_state != RR_IDLE) && (right_rd_state != RR_DONE);
assign right_rd_done = (right_rd_state == RR_DONE);

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// right_buffer tail flush control.
// ---------------------------------------------------------------------------
reg [2:0] flush_idx;              // block结束后补存最后7行right_buffer的行序号
wire [6:0] flush_row_cnt;         // flush阶段正在保存的block内部行号
wire [6:0] flush_linebuf_row_mod; // flush行在7行line SRAM中的取模结果
wire [2:0] flush_linebuf_row;     // flush阶段读取line SRAM的bank编号
wire [7:0] cur16_right_base_idx;  // 最后一行右7列在cur16_reg中的起始索引

assign flush_row_cnt         = block_pixel_height - 7'd7 + {4'd0, flush_idx};
assign flush_linebuf_row_mod = flush_row_cnt % 7'd7;
assign flush_linebuf_row     = flush_linebuf_row_mod[2:0];
assign cur16_right_base_idx  = block_pixel_width - calc_block_x_base - 8'd7;


assign data_rdy  = (cur_state == ST_RECV);
assign data_fire = data_vld && data_rdy;

wire recv_linebuf_en;
wire latch_cur16_en;
wire writeback_en;
wire flush_right_en;
wire save_evict_right_en;
wire need_tail_flush;
wire writeback_done;
wire flush_right_done;

assign recv_linebuf_en     = (cur_state == ST_RECV) && frame_top_fill_linebuf;
assign latch_cur16_en      = (cur_state == ST_RECV) && frame_top_calc_segment; // 目前是recv状态并且接收到了7行数据
assign writeback_en        = (cur_state == ST_WRITEBACK);                      // Lanczos计算完成后写回line SRAM
assign flush_right_en      = (cur_state == ST_FLUSH_RIGHT);                    //右边界数据
assign save_evict_right_en = writeback_en && right_save_en && calc_last_seg_in_row && (calc_row_cnt >= 7'd7);
assign need_tail_flush     = writeback_en && right_save_en && calc_last_seg_in_row && calc_last_row_in_block;

integer i_launch;
integer i_line;
integer i_right;
integer i_tag;
integer i_word;
integer i_rr;

localparam [2:0] WB_IDLE       = 3'd0;
localparam [2:0] WB_SAVE_RIGHT = 3'd1;
localparam [2:0] WB_WRITE_L7   = 3'd2;
localparam [2:0] WB_WRITE_CUR  = 3'd3;
localparam [2:0] WB_DONE       = 3'd4;

reg [2:0] wb_state;

assign writeback_done  = (wb_state == WB_DONE);
assign flush_right_done = ((flush_idx < 3'd6) && right_rd_done) ||
                          ((flush_idx == 3'd6) && flush_right_en);

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
// 主流程状态机
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
            if (writeback_done) begin
                if (need_tail_flush) begin
                    nxt_state = ST_FLUSH_RIGHT;
                end else if (calc_last_seg_in_row && calc_last_row_in_block) begin
                    nxt_state = ST_IDLE;
                end else begin
                    nxt_state = ST_RECV;
                end
            end
        end

        ST_FLUSH_RIGHT: begin
            if (flush_right_done && (flush_idx == 3'd6)) begin
                nxt_state = ST_IDLE;
            end
        end

        default: begin
            nxt_state = ST_IDLE;
        end
    endcase
end

// ---------------------------------------------------------------------------
// Receive counters. They only advance when input is truly accepted.计算block中每个16数据的编号和行号
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
            seg16_x <= seg16_x + 1'b1; // 进入本行下一个16像素段
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

        if (latch_cur16_en) begin   //开始接收16个像素开始计算lanczos
            for (i_launch = 0; i_launch < IN_PIX_PER_CYC; i_launch = i_launch + 1) begin
                cur16_reg[i_launch] <= pixel_in[i_launch];
            end

            // 锁存当前16像素段的坐标快照，done返回后写回仍使用这些快照。
            calc_block_x_base <= in_block_x_base;
            calc_global_x_base <= in_global_x_base;
            calc_linebuf_row <= linebuf_wr_row;
            calc_row_cnt <= row_cnt;
            calc_first_seg_in_row <= (seg16_x == 4'd0);
            calc_last_seg_in_row <= last_seg_in_row;
            calc_last_row_in_block <= last_row_in_block;
            calc_x_end <= cur_segment_x_end;
            calc_y_end <= cur_segment_y_end;

            lanczos_start_r <= 1'b1; // 通知Lanczos可以开始计算当前16像素段
        end
    end
end

// ---------------------------------------------------------------------------
// line SRAM access mux.
//根据当前状态机在做什么，
//决定这一拍 line SRAM 要读哪个 bank、哪个地址，
//以及要写哪个 bank、哪个地址、写什么数据。
//只负责把当前拍正确的 bank/addr/en/data 接到 7 个 line SRAM bank 上
//根据当前哪个子状态机需要访问 line SRAM，决定这一拍读哪个 bank、哪个地址；写哪个 bank、哪个地址、写什么数据
// ---------------------------------------------------------------------------
always @(*) begin
    linebuf_rd_bank = 3'd0;
    linebuf_rd_addr = {LINEBUF_ADDR_W{1'b0}};
    linebuf_rd_en   = 1'b0;
    linebuf_wr_bank = 3'd0;
    linebuf_wr_addr = {LINEBUF_ADDR_W{1'b0}};
    linebuf_wr_data = {LINEBUF_WORD_W{1'b0}};
    linebuf_wr_en   = 1'b0;


    //line_wr_state 是写 SRAM 的 RMW 状态机
    if (line_wr_state == LW_READ) begin
        linebuf_rd_bank = line_wr_req_bank;
        linebuf_rd_addr = line_wr_cur_x[11:4];
        linebuf_rd_en   = 1'b1;
    //right_rd_state 从sram中取出数据存在右边buffer里面
    end else if ((right_rd_state == RR_READ0) || (right_rd_state == RR_READ1)) begin
        linebuf_rd_bank = right_rd_bank;
        linebuf_rd_addr = right_rd_x[11:4] + ((right_rd_state == RR_READ1) ? 8'd1 : 8'd0);
        linebuf_rd_en   = 1'b1;
    //win_state 是 8x8 tap 窗口读取状态机
    end else if (win_state == WIN_SRAM_READ) begin
        linebuf_rd_bank = win_line_rd_bank;
        linebuf_rd_addr = win_line_rd_addr;
        linebuf_rd_en   = 1'b1;
    end

    //存每次计算后需要写回的数据
    if (line_wr_state == LW_WRITE) begin
        linebuf_wr_bank = line_wr_req_bank;
        linebuf_wr_addr = line_wr_cur_x[11:4];
        linebuf_wr_data = line_wr_merge_word;
        linebuf_wr_en   = 1'b1;
    end else if (recv_linebuf_en) begin     //前7行直接写入
        linebuf_wr_bank = linebuf_wr_row;
        linebuf_wr_addr = in_global_x_base[11:4];
        linebuf_wr_data = data_in;
        linebuf_wr_en   = 1'b1;
    end
end
//多打一拍
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
// line_y_tag records which global y row is stored in each SRAM bank.
//7 个 line SRAM bank 当前分别保存的是哪一条真实图像行
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
            line_y_tag[linebuf_wr_row] <= block_start_y + {6'd0, row_cnt};  //前7行写入sram时更新line_y_tag,例如line_y_tag[3] <= 3;bank3 当前保存的是全局第3行。
        end

        if ((line_wr_state == LW_WRITE) && calc_last_seg_in_row) begin
            line_y_tag[line_wr_req_bank] <= block_start_y + {6'd0, calc_row_cnt};
        end
    end
end

// ---------------------------------------------------------------------------
// Generic line SRAM write engine. Partial writes use read-modify-write.负责把部分像素写回 line SRAM
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
                    line_wr_cur_x       <= line_wr_req_x;
                    line_wr_rem_len     <= line_wr_req_len;
                    line_wr_data_offset <= 5'd0;
                    line_wr_start_lane  <= line_wr_req_x[3:0];
                    if ((5'd16 - {1'b0, line_wr_req_x[3:0]}) < line_wr_req_len) begin  //判断要写的数据是否跨越当前160bit word边界，如果跨越了就先写一部分
                        line_wr_chunk_len <= 5'd16 - {1'b0, line_wr_req_x[3:0]};       //本次要写多少个像素
                    end else begin
                        line_wr_chunk_len <= line_wr_req_len;
                    end

                    if ((line_wr_req_x[3:0] == 4'd0) && (line_wr_req_len == 5'd16)) begin
                        line_wr_merge_word <= line_wr_req_pixels;
                        line_wr_state <= LW_WRITE;
                    end else begin
                        line_wr_state <= LW_READ;
                    end
                end
            end

            LW_READ: begin
                line_wr_state <= LW_MERGE;
            end

            LW_MERGE: begin
                line_wr_merge_word <= linebuf_rd_data_mux;   //从sram读出来的旧数据
                for (i_word = 0; i_word < 16; i_word = i_word + 1) begin
                    if ((i_word[4:0] >= {1'b0, line_wr_start_lane}) &&
                        (i_word[4:0] < ({1'b0, line_wr_start_lane} + line_wr_chunk_len))) begin
                        line_wr_merge_word[i_word*PIXEL_W +: PIXEL_W] <=
                            line_wr_req_pixels[(line_wr_data_offset + i_word[4:0] - {1'b0, line_wr_start_lane})*PIXEL_W +: PIXEL_W];   //把对应的新数据写入要更新的像素位置
                    end
                end
                line_wr_state <= LW_WRITE;
            end

            LW_WRITE: begin
                if (line_wr_rem_len == line_wr_chunk_len) begin
                    line_wr_state <= LW_DONE;
                end else begin
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
// Read old line SRAM right 7 pixels before the row is overwritten.在某一行 line SRAM 即将被覆盖前，把旧行的最右 7 个像素读出来，保存到 right_buffer
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
                    right_rd_start_lane <= right_rd_x[3:0];
                    right_rd_cross_word <= (right_rd_x[3:0] > 4'd9);
                    right_rd_state      <= RR_READ0;
                end
            end

            RR_READ0: begin
                right_rd_state <= RR_SAVE0;
            end

            RR_SAVE0: begin
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
// Segment writeback sequencer: save old right edge, then RMW left7/current data.这是整个写回阶段的总调度器
//right_rd_state  从 line SRAM 读旧右 7 像素，保存到 right_buffer
//line_wr_state  把 left7_reg 或 cur16_reg 写回 line SRAM
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wb_state          <= WB_IDLE;
        line_wr_start     <= 1'b0;
        right_rd_start    <= 1'b0;
        line_wr_req_bank  <= 3'd0;
        line_wr_req_x     <= 13'd0;
        line_wr_req_len   <= 5'd0;
        line_wr_req_pixels<= {LINEBUF_WORD_W{1'b0}};
        right_rd_bank     <= 3'd0;
        right_rd_x        <= 13'd0;
        right_rd_dst_row  <= 5'd0;
        flush_idx         <= 3'd0;
    end else if (buf_clr) begin
        wb_state          <= WB_IDLE;
        line_wr_start     <= 1'b0;
        right_rd_start    <= 1'b0;
        line_wr_req_bank  <= 3'd0;
        line_wr_req_x     <= 13'd0;
        line_wr_req_len   <= 5'd0;
        line_wr_req_pixels<= {LINEBUF_WORD_W{1'b0}};
        right_rd_bank     <= 3'd0;
        right_rd_x        <= 13'd0;
        right_rd_dst_row  <= 5'd0;
        flush_idx         <= 3'd0;
    end else begin
        line_wr_start  <= 1'b0;
        right_rd_start <= 1'b0;

        if (cur_state == ST_FLUSH_RIGHT) begin  //如果当前是ST_FLUSH_RIGHT，说明 block 已经结束，需要补存最后 7 行的右边界。
            wb_state <= WB_IDLE;

            if (flush_idx < 3'd6) begin
                if (right_rd_state == RR_IDLE) begin
                    right_rd_bank    <= flush_linebuf_row;
                    right_rd_x       <= right_base_x;
                    right_rd_dst_row <= flush_row_cnt[4:0];
                    right_rd_start   <= 1'b1;                    //启动读sram
                end else if (right_rd_done) begin
                    flush_idx <= flush_idx + 1'b1;
                end
            end else begin
                for (i_right = 0; i_right < RIGHT_COLS; i_right = i_right + 1) begin
                    right_buffer[flush_row_cnt[4:0]][i_right] <= cur16_reg[cur16_right_base_idx[3:0] + i_right[3:0]];
                end
                flush_idx <= 3'd0;
            end
        end else if (cur_state != ST_WRITEBACK) begin   //不在写回阶段，SRAM的状态机应该处于空闲状态
            wb_state <= WB_IDLE;
        end else begin
            case (wb_state)
                WB_IDLE: begin
                    if (save_evict_right_en) begin
                        right_rd_bank    <= calc_linebuf_row;
                        right_rd_x       <= right_base_x;
                        right_rd_dst_row <= evict_right_row_idx;
                        right_rd_start   <= 1'b1;
                        wb_state         <= WB_SAVE_RIGHT;
                    end else if (!calc_first_seg_in_row) begin
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

                WB_SAVE_RIGHT: begin
                    if (right_rd_done) begin
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
                            for (i_line = 0; i_line < X_KEEP_PIX; i_line = i_line + 1) begin
                                left7_reg[i_line] <= cur16_reg[X_SAFE_COMMIT + i_line];
                            end
                        end
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
