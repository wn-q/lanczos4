# downscale_block_buffer 信号与位宽说明

更新时间：2026-06-22

对应 RTL：`downscale_block_buffer.v`

本文整理 `pp_downscale_block_buffer` 当前版本中主要参数、端口、寄存器、wire 和状态机信号的含义。重点说明：

- 信号是输入、输出还是内部变量。
- 信号位宽为什么这样设置。
- 信号在 buffer / scanner / Lanczos4 window read 流程中的作用。

## 1. 模块总体功能

`pp_downscale_block_buffer` 是 downscale 数据缓存与 64-tap window 提供模块。

它接收上游按 block 顺序输入的像素流，每拍 160bit，即 16 个 10bit 像素。模块内部维护：

- `line_buffer`：当前 block 内部 7 行历史数据。
- `cur16_reg`：当前刚收到、尚未完全写回 SRAM 的 16 个像素。
- `left7_reg`：上一段 16 像素的最后 7 个像素。
- `right_buffer`：当前 block 最右 7 列，供右侧 block 使用。
- `bottom_buffer`：当前 block 最后 7 行，供下一条 block-row 使用。
- `corner_buffer`：右下角 7x7 halo，供右下相邻 block 使用。

新版接口中，buffer 不再主动发 `lanczos_start`，而是：

1. 向 scanner 提供当前 block 描述。
2. 接收 scanner 发来的 `center_x/center_y` 请求。
3. 判断当前数据是否足够。
4. 数据够时暂停输入，读取 8x8=64 个像素并返回给 scanner/Lanczos core。

## 2. 参数与 localparam

| 名称 | 类型/位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `PIXEL_W` | parameter = 10 | 参数 | 单像素位宽 | 当前 Y 分量为 10bit。 |
| `IN_PIX_PER_CYC` | parameter = 16 | 参数 | 每拍输入像素数 | `data_in` 为 160bit，等于 16 个 10bit 像素。 |
| `IMG_W` | parameter = 4096 | 参数 | 支持的最大图像宽度 | 当前规划支持 4096 宽输入。 |
| `IMG_X_W` | parameter = 12 | 参数 | 图像 x 地址位宽 | `2^12=4096`，可索引 0~4095。 |
| `LINEBUF_WORD_W` | parameter = 160 | 参数 | SRAM word 位宽 | 一个 word 存 16 个 10bit 像素。 |
| `LINEBUF_WORDS` | parameter = 256 | 参数 | 单行 SRAM word 数 | `4096/16=256`。 |
| `LINEBUF_ADDR_W` | parameter = 8 | 参数 | SRAM word 地址位宽 | `2^8=256`。 |
| `LANCZOS_TAPS` | parameter = 8 | 参数 | Lanczos4 单方向 tap 数 | Lanczos4 横向 8 tap，纵向 8 tap。 |
| `TAP_COORD_W` | parameter = 14 | 参数 | tap 全局坐标位宽 | 需要表示负 tap、4096 附近坐标，以及边界 clip 后坐标。 |
| `X_SAFE_COMMIT` | parameter = 9 | 参数 | 当前 16 像素段可先写回像素数 | 16 像素中前 9 个写回 line SRAM，后 7 个保留给下一段。 |
| `X_KEEP_PIX` | parameter = 7 | 参数 | 保留给下一段的像素数 | Lanczos4 左侧最多需要 7 个跨段/跨 block halo。 |
| `X_CALC_RIGHT_GAP` | parameter = 4 | 参数 | 右侧计算保留距离 | Lanczos4 右侧需要 `+4` tap。当前版本部分旧逻辑保留该参数。 |
| `RIGHT_COLS` | parameter = 7 | 参数 | right halo 列数 | 当前 block 最右 7 列供右侧 block 的负 x tap 使用。 |
| `BOTTOM_ROWS` | parameter = 7 | 参数 | bottom halo 行数 | 当前 block 最后 7 行供下方 block-row 的负 y tap 使用。 |
| `CORNER_PIX` | parameter = 7 | 参数 | corner halo 宽高 | 右下角保存 7x7，供右下 block 的左上角 halo 使用。 |
| `BLOCK_MAX_H` | parameter = 32 | 参数 | 当前 block 最大高度 | 当前阶段 block 高度按 32 规划。 |
| `TAP_ZERO/ONE/TWO/THREE/FOUR/SEVEN/SIXTEEN` | signed `[TAP_COORD_W-1:0]` | localparam | signed 常量 | 统一 tap 计算中的 signed 常量，避免无符号比较错误。 |

## 3. 顶层输入输出端口

### 3.1 时钟、复位与控制

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `clk` | 1 | input | 时钟 | 标准单 bit 时钟。 |
| `rst_n` | 1 | input | 低有效复位 | 标准单 bit 复位。 |
| `fg2pp_ctrl` | `[53:0]` | input | 当前 block 控制信息 | 由协议定义，总宽度 54bit。 |
| `sw_pic_height` | `[12:0]` | input | frame 高度 | 支持 0~8191，覆盖 4096/2304 等场景。 |
| `sw_upscale_pic_width` | `[12:0]` | input | frame 宽度 | 支持 0~8191，覆盖 4096 宽。 |
| `ctrl_vld` | 1 | input | 当前 block ctrl 有效 | 与 `ctrl_rdy` 握手成功后锁存 `fg2pp_ctrl`。 |
| `ctrl_rdy` | 1 | output | buffer 可以接收 ctrl | 当前实现为 `cur_state == ST_IDLE` 时拉高。 |

### 3.2 输入像素流

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `data_vld` | 1 | input | 上游输入数据有效 | valid/ready 协议。 |
| `data_rdy` | 1 | output | buffer 可接收输入 | window/read/writeback 忙时拉低。 |
| `data_in` | `[159:0]` | input | 当前拍 16 个像素 | `16*10=160bit`。 |

### 3.3 buffer 到 scanner 的 block 描述接口

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `scan_block_ctrl_valid_o` | 1 | output | 当前 block 控制信息有效 | valid/ready 握手。 |
| `scan_block_ctrl_ready_i` | 1 | input | scanner 可接收 block 控制信息 | valid/ready 握手。 |
| `scan_block_start_x_o` | `[12:0]` | output | 当前 block 全局起始 x | 来自 ctrl 的 13bit 坐标。 |
| `scan_block_start_y_o` | `[12:0]` | output | 当前 block 全局起始 y | 来自 ctrl 的 13bit 坐标。 |
| `scan_block_width_o` | `[7:0]` | output | 当前 block 宽度 | ctrl 中 block width 为 8bit，可覆盖 0~255。 |
| `scan_block_height_o` | `[6:0]` | output | 当前 block 高度 | ctrl 中 block height 为 7bit，可覆盖 0~127。 |
| `scan_frame_left_o` | 1 | output | 当前 block 位于 frame 左边界 | 边界标志单 bit。 |
| `scan_frame_right_o` | 1 | output | 当前 block 位于 frame 右边界 | 边界标志单 bit。 |
| `scan_frame_top_o` | 1 | output | 当前 block 位于 frame 顶边界 | 边界标志单 bit。 |
| `scan_frame_bottom_o` | 1 | output | 当前 block 位于 frame 底边界 | 边界标志单 bit。 |

### 3.4 scanner 到 buffer 的 center 请求接口

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `scan_center_valid_i` | 1 | input | scanner 当前 center 请求有效 | scanner 保持到 window 返回。 |
| `scan_center_x_i` | signed `[TAP_COORD_W-1:0]` | input | 请求的原图 center_x | signed 便于处理边界和 local 坐标相减。 |
| `scan_center_y_i` | signed `[TAP_COORD_W-1:0]` | input | 请求的原图 center_y | signed 便于处理边界和 local 坐标相减。 |

### 3.5 buffer 返回 64-tap window

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `scan_window_pixels_o` | `[639:0]` | output | 64 个 10bit 像素 | `8*8*10=640bit`。 |
| `scan_window_valid_o` | 1 | output | 当前 64-tap window 输出有效 | window 完成时拉高 1 拍。 |

## 4. ctrl 锁存寄存器

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `block_pixel_height` | `[6:0]` | 内部 reg | 当前 block 高度 | 对应 `fg2pp_ctrl[6:0]`。 |
| `block_pixel_width` | `[7:0]` | 内部 reg | 当前 block 宽度 | 对应 `fg2pp_ctrl[14:7]`。 |
| `frame_top_edge` | 1 | 内部 reg | 当前 block 是否位于 frame 顶边界 | 对应 ctrl bit。 |
| `frame_bottom_edge` | 1 | 内部 reg | 当前 block 是否位于 frame 底边界 | 对应 ctrl bit。 |
| `frame_left_edge` | 1 | 内部 reg | 当前 block 是否位于 frame 左边界 | 对应 ctrl bit。 |
| `frame_right_edge` | 1 | 内部 reg | 当前 block 是否位于 frame 右边界 | 对应 ctrl bit。 |
| `tile_top_edge` | 1 | 内部 reg | 当前 block 是否位于 tile 顶边界 | 当前阶段暂未展开 tile 跨界处理。 |
| `tile_bottom_edge` | 1 | 内部 reg | 当前 block 是否位于 tile 底边界 | 当前阶段暂未展开 tile 跨界处理。 |
| `tile_left_edge` | 1 | 内部 reg | 当前 block 是否位于 tile 左边界 | 当前阶段暂未展开 tile 跨界处理。 |
| `tile_right_edge` | 1 | 内部 reg | 当前 block 是否位于 tile 右边界 | 当前阶段暂未展开 tile 跨界处理。 |
| `block_start_x` | `[12:0]` | 内部 reg | 当前 block 全局起始 x | 对应 `fg2pp_ctrl[35:23]`。 |
| `block_start_y` | `[12:0]` | 内部 reg | 当前 block 全局起始 y | 对应 `fg2pp_ctrl[48:36]`。 |
| `block64_loc` | `[1:0]` | 内部 reg | 当前 block 在 superblock 中的位置 | 对应 ctrl，当前仅锁存。 |
| `block_type` | `[1:0]` | 内部 reg | 当前数据类型 | 后续支持 Y/U/V 时使用。 |
| `picture_ready` | 1 | 内部 reg | 图像输出完成标志 | 对应 ctrl bit。 |

## 5. 输入像素拆包与接收计数

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `pixel_in[i]` | `[PIXEL_W-1:0]` | 内部 reg array | `data_in` 拆出的 16 个像素 lane | 每个 lane 10bit。 |
| `unpack_i` | integer | 内部循环变量 | 拆包循环下标 | 仿真/综合循环变量。 |
| `seg16_x` | `[3:0]` | 内部 reg | 当前行第几个 16 像素段 | block 宽 32 时只需 0~1；保留 4bit 可覆盖最多 16 段。 |
| `row_cnt` | `[6:0]` | 内部 reg | 当前 block 内部行号 | block 高度 ctrl 是 7bit。 |
| `cycles_per_row` | `[3:0]` | 内部 reg | 每行 16 像素段数量 | `ceil(block_width/16)`，4bit 覆盖最多 16 段。 |
| `cycles_per_row_calc` | `[7:0]` | 内部 wire | 每行段数计算结果 | 由 8bit block width 计算。 |
| `last_seg_in_row` | 1 | 内部 wire | 当前段是否为本行最后一段 | 比较结果单 bit。 |
| `last_row_in_block` | 1 | 内部 wire | 当前行是否为 block 最后一行 | 比较结果单 bit。 |
| `block_recv_done` | 1 | 内部 wire | 当前 block 像素接收完成 | `data_fire && last_seg && last_row`。 |
| `data_fire` | 1 | 内部 wire | 输入握手成功 | `data_vld && data_rdy`。 |

## 6. 像素缓存与 halo buffer

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `cur16_reg[0:15]` | 每项 `[PIXEL_W-1:0]` | 内部 reg array | 当前刚输入、还没完全提交的 16 像素 | 当前拍输入正好 16 像素。 |
| `left7_reg[0:6]` | 每项 `[PIXEL_W-1:0]` | 内部 reg array | 上一段最后 7 像素 | Lanczos4 跨 16 像素段最多需要左侧 7 像素。 |
| `right_buffer[0:31][0:6]` | 每项 `[PIXEL_W-1:0]` | 内部 reg array | 当前 block 最右 7 列 | 32 行最大 block 高度，7 列 halo。 |
| `corner_buffer[0:6][0:6]` | 每项 `[PIXEL_W-1:0]` | 内部 reg array | 右下角 7x7 halo | 右下相邻 block 的左上角 tap 需要。 |
| `corner_valid` | 1 | 内部 reg | corner_buffer 是否有效 | 单 bit valid。 |
| `corner_for_block_start_x` | `[12:0]` | 内部 reg | corner 对应目标 block 起始 x | 用 tag 防止错误 block 读取。 |
| `corner_for_block_start_y` | `[12:0]` | 内部 reg | corner 对应目标 block 起始 y | 用 tag 防止错误 block 读取。 |
| `line_y_tag[0:6]` | 每项 `[12:0]` | 内部 reg array | line SRAM 每个 bank 当前真实 y 行号 | rolling 7 bank 复用时判断数据是否属于目标行。 |

## 7. line_buffer SRAM 信号

line_buffer 使用 7 个 `ram_rws_256x160` bank。地址映射：

```text
bank      = global_y % 7
word_addr = global_x[11:4]
lane      = global_x[3:0]
```

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `linebuf_ra[0:6]` | 每项 `[7:0]` | 内部 wire | 每个 SRAM bank 读地址 | 256 word 需要 8bit。 |
| `linebuf_re[0:6]` | 每项 1 | 内部 wire | 每个 SRAM bank 读使能 | 单 bit enable。 |
| `linebuf_dout[0:6]` | 每项 `[159:0]` | 内部 wire | 每个 SRAM bank 读数据 | 一个 word 为 160bit。 |
| `linebuf_wa[0:6]` | 每项 `[7:0]` | 内部 wire | 每个 SRAM bank 写地址 | 256 word 需要 8bit。 |
| `linebuf_we[0:6]` | 每项 1 | 内部 wire | 每个 SRAM bank 写使能 | 单 bit enable。 |
| `linebuf_di[0:6]` | 每项 `[159:0]` | 内部 wire | 每个 SRAM bank 写数据 | 一个 word 为 160bit。 |
| `linebuf_rd_bank` | `[2:0]` | 内部 reg | 当前读哪个 line bank | 7 个 bank 需要 3bit。 |
| `linebuf_rd_bank_d` | `[2:0]` | 内部 reg | 同步读延迟后的 bank | SRAM dout 下一拍有效，需要延迟 bank。 |
| `linebuf_rd_addr` | `[7:0]` | 内部 reg | 当前 line SRAM 读 word 地址 | 256 word 需要 8bit。 |
| `linebuf_rd_en` | 1 | 内部 reg | line SRAM 读使能 | 单 bit enable。 |
| `linebuf_wr_bank` | `[2:0]` | 内部 reg | 当前写哪个 line bank | 7 个 bank 需要 3bit。 |
| `linebuf_wr_addr` | `[7:0]` | 内部 reg | 当前 line SRAM 写 word 地址 | 256 word 需要 8bit。 |
| `linebuf_wr_data` | `[159:0]` | 内部 reg | 当前 line SRAM 写 word 数据 | 16 个 10bit 像素。 |
| `linebuf_wr_en` | 1 | 内部 reg | line SRAM 写使能 | 单 bit enable。 |
| `linebuf_rd_data_mux` | `[159:0]` | 内部 wire | 当前选中 bank 的读数据 | 由 `linebuf_rd_bank_d` 选择。 |
| `linebuf_pwrbus_ram_pd` | ``[`CHIP_MEM_POWER_CTRL-1:0]`` | 内部 wire | RAM 电源控制 | 位宽由宏定义控制，当前默认 1。 |
| `gi_linebuf_bank` | genvar | generate 变量 | 例化 7 个 line SRAM | 生成循环变量。 |

## 8. bottom_buffer SRAM 信号

bottom_buffer 也使用 7 个 `ram_rws_256x160` bank。它保存上一条 block-row 的 bottom 7 行，地址映射与 line_buffer 相同。

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `bottombuf_ra[0:6]` | 每项 `[7:0]` | 内部 wire | bottom SRAM 读地址 | 256 word 需要 8bit。 |
| `bottombuf_re[0:6]` | 每项 1 | 内部 wire | bottom SRAM 读使能 | 单 bit enable。 |
| `bottombuf_dout[0:6]` | 每项 `[159:0]` | 内部 wire | bottom SRAM 读数据 | 一个 word 为 160bit。 |
| `bottombuf_wa[0:6]` | 每项 `[7:0]` | 内部 wire | bottom SRAM 写地址 | 256 word 需要 8bit。 |
| `bottombuf_we[0:6]` | 每项 1 | 内部 wire | bottom SRAM 写使能 | 单 bit enable。 |
| `bottombuf_di[0:6]` | 每项 `[159:0]` | 内部 wire | bottom SRAM 写数据 | 一个 word 为 160bit。 |
| `bottombuf_rd_bank` | `[2:0]` | 内部 reg | 当前读哪个 bottom bank | 7 个 bank 需要 3bit。 |
| `bottombuf_rd_bank_d` | `[2:0]` | 内部 reg | bottom 同步读延迟 bank | SRAM dout 下一拍有效。 |
| `bottombuf_rd_addr` | `[7:0]` | 内部 reg | bottom 读 word 地址 | 256 word 需要 8bit。 |
| `bottombuf_rd_en` | 1 | 内部 reg | bottom 读使能 | 单 bit enable。 |
| `bottombuf_wr_bank` | `[2:0]` | 内部 reg | bottom 写 bank | 7 个 bank 需要 3bit。 |
| `bottombuf_wr_addr` | `[7:0]` | 内部 reg | bottom 写 word 地址 | 256 word 需要 8bit。 |
| `bottombuf_wr_data` | `[159:0]` | 内部 reg | bottom 写 word 数据 | 一个 word 为 160bit。 |
| `bottombuf_wr_en` | 1 | 内部 reg | bottom 写使能 | 单 bit enable。 |
| `bottombuf_rd_data_mux` | `[159:0]` | 内部 wire | 当前选中 bottom bank 的读数据 | 由 `bottombuf_rd_bank_d` 选择。 |
| `bottombuf_pwrbus_ram_pd` | ``[`CHIP_MEM_POWER_CTRL-1:0]`` | 内部 wire | bottom SRAM 电源控制 | 位宽由宏定义控制。 |
| `gi_bottombuf_bank` | genvar | generate 变量 | 例化 7 个 bottom SRAM | 生成循环变量。 |

## 9. scanner/window 接口与 center ready 判断

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `lanczos_window_pixels_r` | `[639:0]` | 内部 reg | 64-tap window 数据寄存器 | `64*10=640bit`。 |
| `lanczos_window_valid_r` | 1 | 内部 reg | window 输出有效 | window 完成后一拍 pulse。 |
| `sent_scan_ctrl_ready` | 1 | 内部 reg | 当前 block 描述是否已发给 scanner | 防止同一 block 重复握手。 |
| `calc_segment_valid` | 1 | 内部 reg | 当前 `calc_*` 快照是否有效 | 有可计算 segment 后置位，用于 center ready 判断。 |
| `scan_center_local_x` | signed `[13:0]` | 内部 wire | scanner center 转 block-local x | center 减 block 起点可能为负。 |
| `scan_center_local_y` | signed `[13:0]` | 内部 wire | scanner center 转 block-local y | center 减 block 起点可能为负。 |
| `scan_need_x_max` | signed `[13:0]` | 内部 wire | 当前 center 右侧最大 tap 需求 | `center_local_x + 4`。 |
| `scan_need_y_max` | signed `[13:0]` | 内部 wire | 当前 center 下侧最大 tap 需求 | `center_local_y + 4`。 |
| `recv_x_max` | signed `[13:0]` | 内部 wire | 当前已接收 segment 覆盖的最大 local x | `calc_block_x_base + 15`。 |
| `recv_y_max` | signed `[13:0]` | 内部 wire | 当前已接收最大 local y | `calc_row_cnt`。 |
| `center_x_ready` | 1 | 内部 wire | center x 方向数据是否足够 | frame right 可 clip，否则要求 `need_x_max <= recv_x_max`。 |
| `center_y_ready` | 1 | 内部 wire | center y 方向数据是否足够 | frame bottom 可 clip，否则要求 `need_y_max <= recv_y_max`。 |
| `center_data_ready` | 1 | 内部 wire | 当前 center 是否可以启动 window read | scanner valid、segment valid、x/y ready 同时满足。 |
| `center_ready_now` | 1 | 内部 wire | 当前周期可以启动 window read | 还要求 `win_state == WIN_IDLE`。 |
| `scan_block_ctrl_en` | 1 | 内部 wire | block 控制信息握手成功 | `scan_block_ctrl_valid_o && scan_block_ctrl_ready_i`。 |
| `window_done` | 1 | 内部 wire | 64-tap window read 完成 | `win_state == WIN_DONE`。 |

## 10. 当前输入段坐标与写回快照

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `in_block_x_base` | `[7:0]` | 内部 wire | 当前 16 像素段在 block 内 x 起点 | block width 是 8bit。 |
| `in_global_x_base` | `[12:0]` | 内部 wire | 当前 16 像素段全局 x 起点 | 全局坐标 13bit。 |
| `linebuf_wr_row_mod` | `[6:0]` | 内部 wire | `row_cnt % 7` 的完整结果 | row_cnt 为 7bit。 |
| `linebuf_wr_row` | `[2:0]` | 内部 wire | 当前行写入 line bank | 7 个 bank 需要 3bit。 |
| `frame_top_fill_linebuf` | 1 | 内部 wire | frame top 前 7 行直接填 line SRAM | 控制信号。 |
| `frame_top_calc_segment` | 1 | 内部 wire | frame top 从第 8 行开始形成可计算 segment | 控制信号。 |
| `non_frame_top_calc_segment` | 1 | 内部 wire | 非 frame top 从 row0 即可形成可计算 segment | 上方数据来自 bottom_buffer。 |
| `calc_segment_fire` | 1 | 内部 wire | 当前输入段形成计算快照 | `frame_top_calc_segment || non_frame_top_calc_segment`。 |
| `cur_segment_x_end` | `[7:0]` | 内部 wire | 当前段可计算 x 右边界，旧逻辑保留 | 基于 block 内 x，8bit。 |
| `cur_segment_y_end` | `[6:0]` | 内部 wire | 当前段可计算 y 下边界，旧逻辑保留 | 基于 block 内 y，7bit。 |
| `right_save_en` | 1 | 内部 wire | 是否需要保存 right halo | frame right 不保存。 |
| `right_base_x` | `[12:0]` | 内部 wire | 当前 block 最右 7 列全局 x 起点 | 全局 x 13bit。 |
| `evict_right_row` | `[6:0]` | 内部 wire | 被 line SRAM 覆盖淘汰的行号 | `calc_row_cnt - 7`。 |
| `evict_right_row_idx` | `[4:0]` | 内部 wire | right_buffer 目标行索引 | block 最大 32 行，需要 5bit。 |
| `cur_write_len_full` | `[8:0]` | 内部 wire | 最后一段有效像素数扩展结果 | `block_width - calc_block_x_base`，需要多 1bit 防借位。 |
| `cur_write_len` | `[4:0]` | 内部 wire | 当前段写回像素数量 | 最大 16，5bit 可表示 0~31。 |
| `bottom_row_start` | `[6:0]` | 内部 wire | 当前 block 最后 7 行起始行号 | block 高度 7bit。 |
| `bottom_wr_row_offset` | `[6:0]` | 内部 wire | 当前行在 bottom 7 行中的偏移 | 由 7bit 行号相减。 |
| `bottom_wr_req_bank_calc` | `[2:0]` | 内部 wire | bottom 写 bank | 7 个 bank 需要 3bit。 |
| `bottom_save_en` | 1 | 内部 wire | 当前行是否写入 bottom_buffer | 控制信号。 |
| `save_corner_en` | 1 | 内部 wire | 覆盖旧 bottom 前是否保存 corner | 控制信号。 |
| `calc_block_x_base` | `[7:0]` | 内部 reg | 当前计算 segment 的 block-local x 起点快照 | 写回和 window 取 cur16 时使用。 |
| `calc_global_x_base` | `[12:0]` | 内部 reg | 当前计算 segment 的全局 x 起点快照 | line/bottom 写地址使用。 |
| `calc_linebuf_row` | `[2:0]` | 内部 reg | 当前计算 segment 对应 line bank 快照 | 7 bank 需要 3bit。 |
| `calc_row_cnt` | `[6:0]` | 内部 reg | 当前计算 segment 的 block-local y 快照 | 7bit 行号。 |
| `calc_first_seg_in_row` | 1 | 内部 reg | 当前 segment 是否本行第一段 | 决定是否写 left7。 |
| `calc_last_seg_in_row` | 1 | 内部 reg | 当前 segment 是否本行最后一段 | 决定写回长度和 right 保存。 |
| `calc_last_row_in_block` | 1 | 内部 reg | 当前 segment 是否 block 最后一行 | 决定 tail flush。 |

## 11. 主状态机 ST_*

| 名称 | 编码 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `ST_IDLE` | `3'd0` | localparam | 空闲状态 | 当前主状态共 6 个，3bit 足够。 |
| `ST_RECV` | `3'd1` | localparam | 接收输入数据 | 主流程状态。 |
| `ST_SCAN_READY` | `3'd2` | localparam | 已有 segment 快照，等待 center 数据满足或写回 | 新 scanner 接入后的中间状态。 |
| `ST_WINDOW_BUSY` | `3'd3` | localparam | 正在执行 64-tap window read | 暂停输入。 |
| `ST_WRITEBACK` | `3'd4` | localparam | 执行 cur16/left7/right/bottom/corner 写回 | 写回阶段。 |
| `ST_FLUSH_RIGHT` | `3'd5` | localparam | block 尾部补存 right_buffer | 处理最后 7 行。 |
| `cur_state` | `[2:0]` | 内部 reg | 主状态机当前状态 | 3bit 覆盖 0~7。 |
| `nxt_state` | `[2:0]` | 内部 reg | 主状态机下一状态 | 3bit 覆盖 0~7。 |
| `recv_linebuf_en` | 1 | 内部 wire | frame top 前 7 行写 line SRAM | 控制信号。 |
| `latch_cur16_en` | 1 | 内部 wire | 当前输入段锁存到 cur16_reg | 控制信号。 |
| `writeback_en` | 1 | 内部 wire | 当前处于写回阶段 | 控制信号。 |
| `save_evict_right_en` | 1 | 内部 wire | 写回前保存被淘汰旧行右 7 列 | 控制信号。 |
| `need_tail_flush` | 1 | 内部 wire | block 结束后是否 flush right_buffer 尾部 | 控制信号。 |
| `writeback_done` | 1 | 内部 wire | 写回调度完成 | 来自 `wb_state == WB_DONE`。 |
| `flush_right_done` | 1 | 内部 wire | right tail flush 完成 | 控制信号。 |

## 12. 64-tap window read 状态机与取数信号

### 12.1 window FSM 与来源编码

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `WIN_IDLE`~`WIN_DONE` | `[2:0]` localparam | 内部 | window read FSM 状态 | 5 个状态，3bit。 |
| `WIN_SRC_INVALID` | `3'd0` | localparam | 当前 tap 来源无效 | 来源编码。 |
| `WIN_SRC_RIGHT` | `3'd1` | localparam | tap 来自 right_buffer | 来源编码。 |
| `WIN_SRC_CUR16` | `3'd2` | localparam | tap 来自 cur16_reg | 来源编码。 |
| `WIN_SRC_LEFT7` | `3'd3` | localparam | tap 来自 left7_reg | 来源编码。 |
| `WIN_SRC_LINE` | `3'd4` | localparam | tap 来自 line_buffer SRAM | 来源编码。 |
| `WIN_SRC_BOTTOM` | `3'd5` | localparam | tap 来自 bottom_buffer SRAM | 来源编码。 |
| `WIN_SRC_CORNER` | `3'd6` | localparam | tap 来自 corner_buffer | 来源编码。 |
| `win_state` | `[2:0]` | 内部 reg | window read 当前状态 | 3bit 状态编码。 |
| `win_idx` | `[5:0]` | 内部 reg | 当前读取第几个 tap | 64 个 tap 需要 6bit。 |
| `win_center_x_r` | signed `[13:0]` | 内部 reg | 当前 window 的 center_x 快照 | signed tap 坐标。 |
| `win_center_y_r` | signed `[13:0]` | 内部 reg | 当前 window 的 center_y 快照 | signed tap 坐标。 |

### 12.2 window SRAM 读暂存

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `win_line_rd_bank` | `[2:0]` | 内部 reg | window 读 line bank | 7 bank 需要 3bit。 |
| `win_line_rd_addr` | `[7:0]` | 内部 reg | window 读 line word 地址 | 256 word 需要 8bit。 |
| `win_line_rd_lane` | `[3:0]` | 内部 reg | window 读 line word 内 lane | 16 lane 需要 4bit。 |
| `win_bottom_rd_bank` | `[2:0]` | 内部 reg | window 读 bottom bank | 7 bank 需要 3bit。 |
| `win_bottom_rd_addr` | `[7:0]` | 内部 reg | window 读 bottom word 地址 | 256 word 需要 8bit。 |
| `win_bottom_rd_lane` | `[3:0]` | 内部 reg | window 读 bottom word 内 lane | 16 lane 需要 4bit。 |
| `win_sram_from_bottom` | 1 | 内部 reg | 本次同步 SRAM 读是否来自 bottom | 区分 dout mux。 |
| `win_line_save_idx` | `[5:0]` | 内部 reg | SRAM 返回数据对应的 tap index | 64 tap 需要 6bit。 |

### 12.3 window 坐标和索引

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `win_tap_x_g` | signed `[13:0]` | 内部 reg | 当前 tap 全局 x | center 加 offset 后可能为负。 |
| `win_tap_y_g` | signed `[13:0]` | 内部 reg | 当前 tap 全局 y | center 加 offset 后可能为负。 |
| `win_clip_x_g` | signed `[13:0]` | 内部 reg | frame clip 后 x | signed 统一比较。 |
| `win_clip_y_g` | signed `[13:0]` | 内部 reg | frame clip 后 y | signed 统一比较。 |
| `win_local_x` | signed `[13:0]` | 内部 reg | tap 相对当前 block 的 x | 可能为负，表示左侧 halo。 |
| `win_local_y` | signed `[13:0]` | 内部 reg | tap 相对当前 block 的 y | 可能为负，表示上方 halo。 |
| `win_frame_width_s` | signed `[13:0]` | 内部 reg | frame 宽度 signed 版本 | 与 signed tap 坐标比较。 |
| `win_frame_height_s` | signed `[13:0]` | 内部 reg | frame 高度 signed 版本 | 与 signed tap 坐标比较。 |
| `win_block_start_x_s` | signed `[13:0]` | 内部 reg | block 起始 x signed 版本 | local 坐标计算。 |
| `win_block_start_y_s` | signed `[13:0]` | 内部 reg | block 起始 y signed 版本 | local 坐标计算。 |
| `win_block_width_s` | signed `[13:0]` | 内部 reg | block 宽度 signed 版本 | 与 signed local_x 比较。 |
| `win_block_height_s` | signed `[13:0]` | 内部 reg | block 高度 signed 版本 | 与 signed local_y 比较。 |
| `win_calc_row_cnt_s` | signed `[13:0]` | 内部 reg | 当前计算行 signed 版本 | 与 signed local_y 比较。 |
| `win_tap_y_min_s` | signed `[13:0]` | 内部 reg | 当前 line window 最小可读 y | 7 行历史窗口。 |
| `win_calc_x_base_s` | signed `[13:0]` | 内部 reg | 当前 cur16 x 起点 | 判断是否读 cur16。 |
| `win_calc_x_limit_s` | signed `[13:0]` | 内部 reg | 当前 cur16 x 终点后一位 | `calc_x_base + 16`。 |
| `win_calc_left7_base_s` | signed `[13:0]` | 内部 reg | left7 对应 local x 起点 | `calc_x_base - 7`。 |
| `win_right_idx_full` | signed `[13:0]` | 内部 reg | right_buffer 索引完整计算 | local_x + 7。 |
| `win_cur16_idx_full` | signed `[13:0]` | 内部 reg | cur16 索引完整计算 | local_x - calc_x_base。 |
| `win_left7_idx_full` | signed `[13:0]` | 内部 reg | left7 索引完整计算 | local_x - left7_base。 |
| `win_bottom_y_idx_full` | signed `[13:0]` | 内部 reg | bottom y 索引完整计算 | local_y + 7。 |
| `win_corner_x_idx_full` | signed `[13:0]` | 内部 reg | corner x 索引完整计算 | local_x + 7。 |
| `win_corner_y_idx_full` | signed `[13:0]` | 内部 reg | corner y 索引完整计算 | local_y + 7。 |
| `win_clip_x_u` | `[12:0]` | 内部 reg | clip 后无符号 x | 用于 SRAM 地址。 |
| `win_clip_y_u` | `[12:0]` | 内部 reg | clip 后无符号 y | 用于 tag 比较。 |
| `win_local_y_u` | `[6:0]` | 内部 reg | local_y 无符号低位 | 当前 block 行号范围 7bit。 |
| `win_linebuf_row_mod` | `[6:0]` | 内部 reg | `local_y % 7` | 7bit 行号取模。 |
| `win_linebuf_row` | `[2:0]` | 内部 reg | line bank index | 7 bank 需要 3bit。 |
| `win_line_addr` | `[7:0]` | 内部 reg | line/bottom word 地址 | `global_x[11:4]`。 |
| `win_line_lane` | `[3:0]` | 内部 reg | word 内 lane | `global_x[3:0]`。 |
| `win_right_idx` | `[2:0]` | 内部 reg | right_buffer 列索引 | 7 列需要 3bit。 |
| `win_cur16_idx` | `[3:0]` | 内部 reg | cur16 lane 索引 | 16 lane 需要 4bit。 |
| `win_left7_idx` | `[2:0]` | 内部 reg | left7 索引 | 7 个元素需要 3bit。 |
| `win_bottom_idx` | `[2:0]` | 内部 reg | bottom bank/行索引 | 7 行需要 3bit。 |
| `win_corner_x_idx` | `[2:0]` | 内部 reg | corner x 索引 | 7 列需要 3bit。 |
| `win_corner_y_idx` | `[2:0]` | 内部 reg | corner y 索引 | 7 行需要 3bit。 |

### 12.4 window 来源选择标志

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `win_src_sel` | `[2:0]` | 内部 reg | 当前 tap 来源选择 | 7 种来源，3bit。 |
| `win_direct_pixel` | `[PIXEL_W-1:0]` | 内部 reg | 寄存器路径直接返回的像素 | 单像素位宽。 |
| `win_direct_valid` | 1 | 内部 reg | 当前寄存器路径像素有效 | 单 bit valid。 |
| `win_tap_y_in_block` | 1 | 内部 reg | tap y 是否在当前 block 内 | 控制判断。 |
| `win_tap_y_in_window` | 1 | 内部 reg | tap y 是否在当前 7 行历史窗口内 | 控制判断。 |
| `win_tap_y_in_bottom` | 1 | 内部 reg | tap y 是否落在上方 bottom halo | 控制判断。 |
| `win_line_tag_match` | 1 | 内部 reg | line SRAM bank tag 是否匹配目标 y | 防止 rolling bank 读错行。 |
| `win_corner_tag_match` | 1 | 内部 reg | corner_buffer tag 是否匹配当前 block | 防止错误 block 读取 corner。 |

## 13. line write RMW 状态机 LW_*

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `LW_IDLE`~`LW_DONE` | `[2:0]` localparam | 内部 | line 写回 RMW 状态 | 5 个状态，3bit。 |
| `line_wr_state` | `[2:0]` | 内部 reg | line 写回状态 | 3bit 状态编码。 |
| `line_wr_start` | 1 | 内部 reg | 启动一次 line 写请求 | 单 bit pulse。 |
| `line_wr_req_bank` | `[2:0]` | 内部 reg | 写入目标 line bank | 7 bank 需要 3bit。 |
| `line_wr_req_x` | `[12:0]` | 内部 reg | 写入起始全局 x | 全局 x 13bit。 |
| `line_wr_req_len` | `[4:0]` | 内部 reg | 写入像素数量 | 最大 16 或拆分后数量，5bit。 |
| `line_wr_req_pixels` | `[159:0]` | 内部 reg | 待写入像素打包 | 最多 16 个 10bit。 |
| `line_wr_cur_x` | `[12:0]` | 内部 reg | 当前 RMW 正在处理的 x | 可能跨 word，保留全局 x。 |
| `line_wr_rem_len` | `[4:0]` | 内部 reg | 剩余待写像素数 | 最大 16，5bit。 |
| `line_wr_data_offset` | `[4:0]` | 内部 reg | 当前 chunk 在请求数据中的偏移 | 最大 16，5bit。 |
| `line_wr_start_lane` | `[3:0]` | 内部 reg | 当前 word 起始 lane | 16 lane 需要 4bit。 |
| `line_wr_chunk_len` | `[4:0]` | 内部 reg | 当前 word 本次写多少 lane | 最大 16，5bit。 |
| `line_wr_merge_word` | `[159:0]` | 内部 reg | RMW 合并后的完整 word | SRAM 无 byte mask，必须整 word 写。 |
| `line_wr_done` | 1 | 内部 wire | line 写回完成 | `line_wr_state == LW_DONE`。 |

## 14. right/bottom/corner 辅助状态机

### 14.1 right read RR_*

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `RR_IDLE`~`RR_DONE` | `[2:0]` localparam | 内部 | 保存 right halo 的读状态 | 6 个状态，3bit。 |
| `right_rd_state` | `[2:0]` | 内部 reg | right 保存状态 | 3bit 状态编码。 |
| `right_rd_start` | 1 | 内部 reg | 启动 right 保存 | 单 bit pulse。 |
| `right_rd_bank` | `[2:0]` | 内部 reg | 从哪个 line bank 读旧行 | 7 bank 需要 3bit。 |
| `right_rd_x` | `[12:0]` | 内部 reg | right 7 列起始全局 x | 全局 x 13bit。 |
| `right_rd_dst_row` | `[4:0]` | 内部 reg | 写入 right_buffer 的行号 | 最大 32 行需要 5bit。 |
| `right_rd_start_lane` | `[3:0]` | 内部 reg | right 7 列在 word 内起始 lane | 16 lane 需要 4bit。 |
| `right_rd_cross_word` | 1 | 内部 reg | right 7 列是否跨 word | 单 bit。 |
| `right_rd_done` | 1 | 内部 wire | right 保存完成 | 状态完成标志。 |

### 14.2 bottom write BW_*

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `BW_IDLE/BW_WRITE/BW_DONE` | `[1:0]` localparam | 内部 | bottom 写状态 | 3 个状态，2bit。 |
| `bottom_wr_state` | `[1:0]` | 内部 reg | bottom 写状态 | 2bit 状态编码。 |
| `bottom_wr_start` | 1 | 内部 reg | 启动 bottom 写 | 单 bit pulse。 |
| `bottom_wr_req_bank` | `[2:0]` | 内部 reg | bottom 写 bank | 7 bank 需要 3bit。 |
| `bottom_wr_req_addr` | `[7:0]` | 内部 reg | bottom 写 word 地址 | 256 word 需要 8bit。 |
| `bottom_wr_req_data` | `[159:0]` | 内部 reg | bottom 写 word 数据 | 一个 word 为 160bit。 |
| `bottom_wr_done` | 1 | 内部 wire | bottom 写完成 | 状态完成标志。 |

### 14.3 corner save CR_*

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `CR_IDLE`~`CR_DONE` | `[1:0]` localparam | 内部 | corner 保存状态 | 4 个状态，2bit。 |
| `corner_rd_state` | `[1:0]` | 内部 reg | corner 保存状态 | 2bit 状态编码。 |
| `corner_rd_start` | 1 | 内部 reg | 启动 corner 保存 | 单 bit pulse。 |
| `corner_rd_idx` | `[2:0]` | 内部 reg | 当前保存 corner 的第几行 | 7 行需要 3bit。 |
| `corner_rd_addr` | `[7:0]` | 内部 reg | 从 bottom SRAM 读的 word 地址 | 256 word 需要 8bit。 |
| `corner_rd_start_lane` | `[3:0]` | 内部 reg | corner 起始 lane | 16 lane 需要 4bit。 |
| `corner_rd_done` | 1 | 内部 wire | corner 保存完成 | 状态完成标志。 |

## 15. tail flush 与写回调度 WB_*

| 名称 | 位宽 | 方向 | 含义 | 位宽设置原因 |
|---|---:|---|---|---|
| `flush_idx` | `[2:0]` | 内部 reg | block 尾部 flush right 的行偏移 | 需要 0~6，3bit。 |
| `flush_row_cnt` | `[6:0]` | 内部 wire | 当前 flush 的 block-local 行号 | block 行号 7bit。 |
| `flush_linebuf_row_mod` | `[6:0]` | 内部 wire | flush 行对应 line bank 取模结果 | 7bit 行号取模。 |
| `flush_linebuf_row` | `[2:0]` | 内部 wire | flush 行对应 line bank | 7 bank 需要 3bit。 |
| `cur16_right_base_idx` | `[7:0]` | 内部 wire | cur16 中最后 7 个有效像素起始 index | 基于 block width 和 calc x 计算。 |
| `WB_IDLE`~`WB_DONE` | `[2:0]` localparam | 内部 | 写回调度状态 | 7 个状态，3bit。 |
| `wb_state` | `[2:0]` | 内部 reg | 当前写回调度状态 | 3bit 状态编码。 |

WB 状态的作用：

- `WB_SAVE_RIGHT`：覆盖旧 line 行前，先保存旧行最右 7 列到 `right_buffer`。
- `WB_WRITE_L7`：非本行第一段时，把上一段 `left7_reg` 写回 line SRAM。
- `WB_WRITE_CUR`：写回当前 `cur16_reg` 的安全部分或最后段有效像素。
- `WB_SAVE_CORNER`：覆盖 bottom 旧数据前，保存右下 7x7 到 `corner_buffer`。
- `WB_WRITE_BOTTOM`：当前 block 最后 7 行写入 `bottom_buffer`。
- `WB_DONE`：写回完成，通知主状态机继续。

## 16. 循环变量

| 名称 | 类型 | 方向 | 含义 |
|---|---|---|---|
| `i_launch` | integer | 内部 | 锁存 `cur16_reg` 时循环 16 lane。 |
| `i_line` | integer | 内部 | 组装 line/bottom 写数据时循环 lane。 |
| `i_right` | integer | 内部 | 写 right_buffer 时循环 7 列。 |
| `i_tag` | integer | 内部 | 初始化或更新 tag 时循环 bank。 |
| `i_word` | integer | 内部 | RMW merge 时循环 16 lane。 |
| `i_rr` | integer | 内部 | right 读保存时循环 lane。 |
| `i_corner` | integer | 内部 | corner 保存时循环 7 列。 |

这些变量只作为 Verilog 循环下标使用，不代表硬件数据通路寄存器。

## 17. 位宽设计原则总结

1. **像素相关位宽**
   - 单像素为 `PIXEL_W=10`。
   - 每拍 16 像素，因此输入和 SRAM word 都是 `160bit`。

2. **4096 宽地址**
   - 像素级 x 地址需要 12bit：`0~4095`。
   - SRAM 以 16 像素为一个 word，因此每行 `4096/16=256` word，word 地址为 8bit。
   - lane 地址为 4bit，对应 word 内 16 个像素。

3. **block 内坐标**
   - block width 使用 8bit，来自 ctrl。
   - block height 使用 7bit，来自 ctrl。
   - block 内行号 `row_cnt` 使用 7bit。
   - right_buffer 行索引最大 32 行，使用 5bit。

4. **tap 坐标**
   - tap 坐标使用 signed `TAP_COORD_W=14`。
   - 这样可以表示 frame 左/上边界外的负 tap，也可以覆盖 4096 附近全局坐标。

5. **状态机编码**
   - 主状态机、window FSM、line write FSM、right read FSM 使用 3bit。
   - bottom write 和 corner save 状态较少，使用 2bit。

6. **valid/ready 与 busy**
   - 输入像素用 `data_vld/data_rdy`。
   - block 描述用 `scan_block_ctrl_valid_o/scan_block_ctrl_ready_i`。
   - scanner center 请求使用 valid/response 模式：scanner 保持 center，buffer 返回 `scan_window_valid_o`。
