# pp_downscale_dst_scan_ctrl 变量与位宽说明表

本文档基于当前 `pp_downscale_dst_scan_ctrl.v`。接口命名约定：

- `buf_*`：和 buffer 模块交互的信号。
- `lanczos_*`：和 Lanczos core 交互的信号。
- `scale_q8/dst_width/dst_height`：全局配置，不加模块前缀。

默认参数：

| 名称 | 类型 | 默认值/位宽 | 含义 | 位宽原因 |
|---|---|---:|---|---|
| `PIXEL_W` | parameter | 10 | 单个像素位宽 | 当前像素按 10bit 处理 |
| `DST_W` | parameter | 13 | 目标图坐标位宽 | 13bit 可表示 `0~8191`，覆盖 4096 级图像并留余量 |
| `TAP_COORD_W` | parameter | 13 | 源图 center signed 坐标位宽 | signed 13bit 可表示 `-4096~4095`，覆盖最大 4096 宽源图，并支持相减后的负值 |
| `SCALE_W` | parameter | 12 | `scale_q8` 位宽 | 12bit 可覆盖当前规划的 2x~8x 缩放 |
| `SRC_Q_W` | parameter | 21 | `src_q9` 坐标位宽 | 源图最大 4096，整数部分 12bit，加 Q9 小数 9bit，总共 21bit |
| `WIN_PIX_NUM` | parameter | 64 | Lanczos window tap 数 | Lanczos4 使用 `8x8=64` tap |

## 输入端口

| 名称 | 方向/类型 | 位宽 | 含义 | 位宽原因 |
|---|---|---:|---|---|
| `clk` | input | 1 | 时钟 | 单 bit 时钟 |
| `rst_n` | input | 1 | 低有效异步复位 | 单 bit 复位 |
| `scan_clr` | input | 1 | 清空扫描状态 | 单 bit 控制 |
| `scale_q8` | input | `SCALE_W=12` | 缩放比例，Q8 格式 | 例如 `512` 表示 2.0，12bit 覆盖设计缩放范围 |
| `dst_width` | input | `DST_W=13` | downscale 输出图宽度 | 和目标图 x 坐标同宽 |
| `dst_height` | input | `DST_W=13` | downscale 输出图高度 | 和目标图 y 坐标同宽 |
| `buf_block_valid_i` | input | 1 | buffer 当前 block 信息有效，请求 scan 接收并开始扫描 | 单 bit valid，和 `buf_block_ready_o` 组成 ready/valid 握手 |
| `buf_block_start_x_i` | input | 13 | 当前 block 在源图中的全局起始 x | 覆盖 4096 级源图坐标并留余量 |
| `buf_block_start_y_i` | input | 13 | 当前 block 在源图中的全局起始 y | 同 x |
| `buf_block_width_i` | input | 8 | 当前 block 宽度 | 8bit 可表示 `0~255`，覆盖常见 block 宽度 |
| `buf_block_height_i` | input | 7 | 当前 block 高度 | 7bit 可表示 `0~127`，覆盖当前 block 高度 |
| `buf_frame_left_i` | input | 1 | 当前 block 是否在整帧最左侧 | 单 bit 边界标志 |
| `buf_frame_right_i` | input | 1 | 当前 block 是否在整帧最右侧 | 单 bit 边界标志 |
| `buf_frame_top_i` | input | 1 | 当前 block 是否在整帧最上侧 | 单 bit 边界标志 |
| `buf_frame_bottom_i` | input | 1 | 当前 block 是否在整帧最下侧 | 单 bit 边界标志 |
| `buf_window_valid_i` | input | 1 | buffer 返回的 64 tap window 有效 | 单 bit valid |
| `buf_window_pixels_i` | input | `WIN_PIX_NUM*PIXEL_W=640` | buffer 返回的 64 个 tap 像素 | `64 * 10bit = 640bit` |
| `buf_window_valid_mask_i` | input | `WIN_PIX_NUM=64` | buffer 返回的 64 tap 有效 mask | 每个 tap 对应 1bit |
| `lanczos_ready_i` | input | 1 | Lanczos core 可以接收当前输出 | 单 bit ready |

## 输出端口

| 名称 | 方向/类型 | 位宽 | 给谁 | 含义 | 位宽原因 |
|---|---|---:|---|---|---|
| `buf_block_ready_o` | output wire | 1 | buffer | scan 当前处于 `SC_IDLE`，可以接收新的 block 信息 | 单 bit ready，由状态机组合生成 |
| `req_buf_data_valid_o` | output wire | 1 | buffer | 请求 buffer 数据有效，保持到 window 返回 | 单 bit valid，由状态机组合生成 |
| `buf_center_x_o` | output reg signed | `TAP_COORD_W=13` | buffer | 请求 buffer 读取 window 的源图 center x | signed 13bit 可表示 `0~4095`，同时支持 local 相减后的负值 |
| `buf_center_y_o` | output reg signed | `TAP_COORD_W=13` | buffer | 请求 buffer 读取 window 的源图 center y | 同 x |
| `buf_block_scan_done_o` | output reg | 1 | buffer | 当前 block 可发出的 center 请求扫描完成 | 单 bit pulse |
| `lanczos_valid_o` | output reg | 1 | Lanczos | 输出数据有效 | 单 bit valid |
| `lanczos_dst_x_o` | output reg | `DST_W=13` | Lanczos | 当前输出点的目标图 x 坐标 | 目标图 x 坐标位宽 |
| `lanczos_dst_y_o` | output reg | `DST_W=13` | Lanczos | 当前输出点的目标图 y 坐标 | 目标图 y 坐标位宽 |
| `lanczos_center_x_o` | output reg signed | `TAP_COORD_W=13` | Lanczos | 当前输出 window 对应的源图 center x | 与 buffer 请求 center 同宽，但在 `lanczos_valid_o` 时有效 |
| `lanczos_center_y_o` | output reg signed | `TAP_COORD_W=13` | Lanczos | 当前输出 window 对应的源图 center y | 同 x |
| `lanczos_phase_x_q9_o` | output reg | 9 | Lanczos | 当前输出点 x 方向 Q9 小数相位 | Q9 坐标低 9bit |
| `lanczos_phase_y_q9_o` | output reg | 9 | Lanczos | 当前输出点 y 方向 Q9 小数相位 | Q9 坐标低 9bit |
| `lanczos_window_pixels_o` | output reg | `WIN_PIX_NUM*PIXEL_W=640` | Lanczos | 64 tap window 像素 | `64 * 10bit = 640bit` |
| `lanczos_window_valid_mask_o` | output reg | `WIN_PIX_NUM=64` | Lanczos | 64 tap 有效 mask | 每个 tap 对应 1bit |
| `lanczos_block_row_last_o` | output reg | 1 | Lanczos | 当前点是否为当前 block 内该输出行最后一个可算点 | 单 bit 标志 |
| `lanczos_bypass_en_o` | output reg | 1 | Lanczos | 特殊整数缩放 bypass 标志 | 单 bit 标志 |

## 内部寄存器

| 名称 | 方向/类型 | 位宽 | 含义 | 位宽原因 |
|---|---|---:|---|---|
| `sc_state` | internal reg | 3 | 当前状态机状态 | 8 个状态需要 3bit |
| `saved_edge_x` | internal reg | `DST_W=13` | 跨 block 保存的下次 x 扫描起点 | 保存目标图 x 坐标 |
| `saved_edge_y` | internal reg | `DST_W=13` | 跨 block 保存的下次 y 扫描起点 | 保存目标图 y 坐标 |
| `cur_edge_x` | internal reg | `DST_W=13` | 当前 block 固定使用的 x 起点 | 目标图 x 坐标 |
| `cur_edge_y` | internal reg | `DST_W=13` | 当前 block 固定使用的 y 起点 | 目标图 y 坐标 |
| `next_edge_x` | internal reg | `DST_W=13` | 当前 block 扫描后留给右侧 block 的 x 起点 | 目标图 x 坐标 |
| `next_edge_y` | internal reg | `DST_W=13` | 当前 block row 扫描后留给下方 block row 的 y 起点 | 目标图 y 坐标 |
| `dst_x` | internal reg | `DST_W=13` | 当前正在尝试计算的目标图 x | 目标图 x 坐标 |
| `dst_y` | internal reg | `DST_W=13` | 当前正在尝试计算的目标图 y | 目标图 y 坐标 |
| `req_dst_x` | internal reg | `DST_W=13` | 已请求 window 的目标图 x 快照 | 等待 buffer 返回期间保持和 window 对齐 |
| `req_dst_y` | internal reg | `DST_W=13` | 已请求 window 的目标图 y 快照 | 同 x |
| `req_phase_x_q9` | internal reg | 9 | 已请求 window 的 x 相位快照 | Q9 phase 低 9bit |
| `req_phase_y_q9` | internal reg | 9 | 已请求 window 的 y 相位快照 | 同 x |
| `req_block_row_last` | internal reg | 1 | 请求点是否为当前 block 内行尾 | 单 bit 标志，需要和 window 返回对齐 |
| `req_row_last_by_block` | internal reg | 1 | 行尾是否由 block 右边界导致 | 单 bit 标志，用于更新 `next_edge_x` |
| `req_bypass_en` | internal reg | 1 | 请求点 bypass 标志快照 | 单 bit 标志，需要和 window 返回对齐 |

## 内部组合信号

| 名称 | 方向/类型 | 位宽 | 含义 | 位宽原因 |
|---|---|---:|---|---|
| `scale_integer_bypass` | internal wire | 1 | `scale_q8` 是否为 3x/5x/7x | 单 bit 判断 |
| `dst_x_twice_plus_one` | internal wire | `DST_W+1=14` | `2*dst_x+1` | 13bit 坐标左移一位后需要 14bit |
| `dst_y_twice_plus_one` | internal wire | `DST_W+1=14` | `2*dst_y+1` | 同 x |
| `next_x_twice_plus_one` | internal wire | `DST_W+1=14` | `2*(dst_x+1)+1` | 用于提前判断下一个 x 是否跨 block |
| `scan_src_x_q9` | internal wire | `SRC_Q_W=21` | 当前 x 映射到源图后的 Q9 坐标 | 源图最大 4096，12bit 整数 + 9bit 小数 |
| `scan_src_y_q9` | internal wire | `SRC_Q_W=21` | 当前 y 映射到源图后的 Q9 坐标 | 同 x |
| `next_src_x_q9` | internal wire | `SRC_Q_W=21` | 下一个 x 映射到源图后的 Q9 坐标 | look-ahead 使用 |
| `scan_center_x` | internal wire signed | `TAP_COORD_W=13` | 当前点源图整数 center x | 从 `scan_src_x_q9[20:9]` 取 12bit 整数，再补 0 扩成 signed 13bit |
| `scan_center_y` | internal wire signed | `TAP_COORD_W=13` | 当前点源图整数 center y | 同 x |
| `next_center_x` | internal wire signed | `TAP_COORD_W=13` | 下一个 x 的源图整数 center x | look-ahead 使用 |
| `scan_phase_x_q9` | internal wire | 9 | 当前点 x 小数相位 | Q9 低 9bit |
| `scan_phase_y_q9` | internal wire | 9 | 当前点 y 小数相位 | Q9 低 9bit |
| `block_start_x_s` | internal wire signed | `TAP_COORD_W=13` | signed 形式的 block 起始 x | 源图最大 4096，13bit signed 可覆盖 `0~4095` |
| `block_start_y_s` | internal wire signed | `TAP_COORD_W=13` | signed 形式的 block 起始 y | 同 x |
| `block_x_limit_s` | internal wire signed | `TAP_COORD_W=13` | 当前 block 内最大可算 local center x | `buf_block_width_i` 扩展到 13bit 后减 4 |
| `block_y_limit_s` | internal wire signed | `TAP_COORD_W=13` | 当前 block 内最大可算 local center y | `buf_block_height_i` 扩展到 13bit 后减 4 |
| `local_center_x` | internal wire signed | `TAP_COORD_W=13` | 当前 center x 相对 block 起点的位置 | 可能为负，所以 signed |
| `local_center_y` | internal wire signed | `TAP_COORD_W=13` | 当前 center y 相对 block 起点的位置 | 同 x |
| `next_local_center_x` | internal wire signed | `TAP_COORD_W=13` | 下一个 x 的 local center | 判断下一个点是否越过 block 右边界 |
| `dst_x_at_frame_end` | internal wire | 1 | 当前 x 是否为整张目标图当前行最后一点 | 单 bit 判断 |
| `cur_x_blocked` | internal wire | 1 | 当前点是否因 block 右边界不可算 | 单 bit 判断 |
| `cur_y_blocked` | internal wire | 1 | 当前点是否因 block 下边界不可算 | 单 bit 判断 |
| `next_x_blocked` | internal wire | 1 | 下一个 x 是否会被 block 右边界挡住 | 单 bit look-ahead |
| `row_last_by_block` | internal wire | 1 | 当前点是否是由 block 右边界导致的行尾 | 单 bit 标志 |
| `current_row_last` | internal wire | 1 | 当前点是否为当前输出段行尾 | `dst_x_at_frame_end || row_last_by_block` |
| `buf_block_fire` | internal wire | 1 | block 信息握手成功，scan 在 `SC_IDLE` 接收当前 block 并进入扫描 | `buf_block_valid_i && buf_block_ready_o` |

## 为什么 buffer center 和 Lanczos center 都保留

| 信号 | 阶段 | 有效条件 | 用途 |
|---|---|---|---|
| `buf_center_x_o/buf_center_y_o` | 请求阶段 | `req_buf_data_valid_o=1` | 送给 buffer，请求读取对应 center 的 64 tap window |
| `lanczos_center_x_o/lanczos_center_y_o` | 输出阶段 | `lanczos_valid_o=1` | 和 `lanczos_window_pixels_o` 对齐后送给 Lanczos core |

两组信号数值通常相同，但属于不同接口阶段：前者给 buffer 发请求，后者和 buffer 返回的 window 数据一起给 Lanczos。
