# PP Downscale Lanczos4 项目上下文快照

最近更新：2026-07-02

本文档保存当前对话形成的关键设计信息，用于后续继续推进项目，避免上下文丢失。

## 1. 最终模块目标

PP downscale 模块用于 AV1 后处理阶段，对解码后的图像做基于 Lanczos4 的高质量下采样。

完整模块最终需要完成：

```text
输入 block 像素流
-> 根据 scale 生成 dst/src 坐标
-> 为每个输出点准备 Lanczos4 需要的 8x8 原图像素
-> 根据 phase 选择 Lanczos4 系数
-> 做横向 8-tap 和纵向 8-tap MAC
-> rounding / clipping
-> 输出 downscale 后像素
```

当前阶段已经重点推进的是：

```text
输入 block 流缓存 + 64-tap window read
```

也就是：

```text
给定原图整数中心坐标 center_x/center_y，返回 Lanczos4 所需 64 个原图像素。
```

## 2. 输入数据顺序

输入数据按 tile、block、block 内行段顺序 streaming 传输。

tile 顺序：

```text
tile 从左到右、从上到下传输。
例如 2x2 tile:

tile0 tile1
tile2 tile3

传输顺序为 tile0 -> tile1 -> tile2 -> tile3。
```

tile 内 block 顺序：

```text
从左到右
从上到下
```

block 内数据顺序：

```text
每拍 data_in[159:0]
16 个像素
每个像素 10bit
一拍表示当前行连续 16 个像素
block 内按行从左到右、从上到下传输
```

32x32 block 示例：

```text
row0:  x0~15   -> cycle0
row0:  x16~31  -> cycle1
row1:  x0~15   -> cycle2
row1:  x16~31  -> cycle3
...
row31: x0~15   -> cycle62
row31: x16~31  -> cycle63
```

## 3. Y/U/V 分量顺序

实际数据不是只传 Y 分量。

每个 block 数据到来前都会先发送 ctrl 信息，ctrl 中：

```text
block_type = 0 -> Y 分量
block_type = 1 -> U 分量
block_type = 2 -> V 分量
```

同一个 block 的传输顺序为：

```text
block0_Y -> block0_U -> block0_V
block1_Y -> block1_U -> block1_V
...
```

当前 RTL 和 TB 暂时只按 Y 分量路径推进，还没有完整处理 U/V。

后续 U/V 需要确认：

```text
1. U/V 是否与 Y 同尺寸，还是存在 4:2:0 / 4:2:2 chroma subsampling。
2. U/V 的 block_start_x/y 是 luma 坐标还是 chroma 坐标。
3. U/V 是否复用同一套 buffer，还是每个分量独立 buffer。
4. scale 是否与 Y 完全一致。
5. 输出是继续按 block 的 Y/U/V 顺序，还是按平面重新组织。
```

建议：先完成 Y 分量 downscale 闭环，再扩展 U/V。

## 4. tile 边界处理原则

当前 RTL 暂时不处理 tile 边界。

用户已明确：

```text
未来 tile 边界数据会保存在 DDR 里面。
```

因此当前局部 buffer 只解决 frame 内相邻 block 的 halo：

```text
right_buffer  -> 相邻右侧 block 的左侧 halo
bottom_buffer -> 下方 block-row 的上方 halo
corner_buffer -> 右下相邻 block 的左上角 halo
```

未来 tile DDR 需要补充：

```text
tile 右边界写 DDR
tile bottom 边界写 DDR
tile corner 写 DDR 或通过 DDR 组合读取
window read 遇到 tile 边界 tap 时发 DDR halo request
DDR 返回延迟导致 window read stall
```

建议未来独立成：

```text
tile_halo_ddr_if
```

## 5. 当前 buffer 架构

当前不使用整帧缓存，而是使用局部 buffer。

原因：

```text
4096x2304x10bit 整帧缓存太大。
Lanczos4 实际只需要当前输出点附近的 8x8 像素。
```

当前 buffer：

```text
line_buffer
    保存当前 block 最近 7 行历史数据。
    已 SRAM 化，7 个 ram_rws_256x160。

cur16_reg
    保存当前刚输入、正在计算但尚未写回 SRAM 的 16 个像素。

left7_reg
    保存当前行上一段最后 7 个像素，用于同一行跨 16 像素段取 tap。

right_buffer
    保存当前 block 最右 7 列，给右侧 block 使用。
    已 SRAM 化，使用 1 个 ram_rws_64x128。
    addr = block 内部行号，word[69:0] 保存 7 个 10bit 像素。
    word[127:70] 暂未使用。

bottom_buffer
    保存当前 block 最后 7 行，给下一条 block-row 使用。
    已 SRAM 化，7 个 ram_rws_256x160。

corner_buffer
    保存旧 bottom_buffer 的右下 7x7，给右下相邻 block 使用。
    当前是 7x7 寄存器数组。
```

## 6. SRAM 位宽和地址

当前使用：

```text
ram_rws_256x160
```

数据位宽来源：

```text
每拍 16 像素
每像素 10bit
16 * 10 = 160bit
```

地址深度来源：

```text
最大行宽 4096
每 word 存 16 像素
4096 / 16 = 256 words
```

地址位宽：

```text
log2(256) = 8bit
```

地址映射：

```verilog
word_addr = global_x[11:4];
lane_idx  = global_x[3:0];
```

示例：

```text
x=0    -> word_addr=0,   lane=0
x=15   -> word_addr=0,   lane=15
x=16   -> word_addr=1,   lane=0
x=4095 -> word_addr=255, lane=15
```

## 7. 64-tap window read 约定

scanner 给 buffer 原图整数中心坐标：

```verilog
scan_center_x_i
scan_center_y_i
```

模块内部生成 8 个 offset：

```text
-3, -2, -1, 0, +1, +2, +3, +4
```

得到：

```text
tap_x = center_x + offset_x
tap_y = center_y + offset_y
```

输出顺序：

```text
win_idx = y_idx * 8 + x_idx
x 方向变化最快
```

取数来源规则：

```text
local_y < 0 && local_x < 0  -> corner_buffer
local_y < 0 && local_x >= 0 -> bottom_buffer
local_y >= 0 && local_x < 0 -> right_buffer
当前输入的 16 像素段        -> cur16_reg
当前行上一段最后 7 像素      -> left7_reg
已经写回的历史/早期像素      -> line_buffer
```

frame 边界 clip：

```text
x < 0        && frame_left_edge   -> x=0
x >= width   && frame_right_edge  -> x=width-1
y < 0        && frame_top_edge    -> y=0
y >= height  && frame_bottom_edge -> y=height-1
```

## 8. 当前 RTL 已实现功能

当前文件：

```text
downscale_block_buffer.v
pp_downscale_dst_scan_ctrl.v
ram_rws_256x160.v
ram_rws_64x128.v
tb_downscale_scanner_buffer.v
```

已实现：

```text
1. fg2pp_ctrl 锁存。
2. data_in[159:0] 拆成 16 个 10bit pixel。
3. seg16_x / row_cnt 输入计数。
4. data_rdy 反压。
5. frame_top block 前 7 行填 line_buffer。
6. 非 frame_top block 依赖 bottom_buffer 从 row0 开始计算。
7. cur16_reg / left7_reg / line_buffer / right_buffer / bottom_buffer / corner_buffer 取数路径。
8. center-based 64-tap window read。
9. line_buffer SRAM 化。
10. bottom_buffer SRAM 化。
11. line_buffer 部分写回 RMW。
12. right_buffer SRAM 化，使用 ram_rws_64x128 保存每行右 7 列。
13. corner_buffer 保存旧 bottom 的右下 7x7。
14. scanner + buffer 集成接口。
15. ctrl_vld / ctrl_rdy 握手装载 block ctrl。
```

当前 TB 代码包含以下检查方向：

```text
scanner + buffer 基础集成
frame_top 前 7 行 prefill
buffer 根据 center 请求返回 64 tap window
pixel_value(x,y)=y*100+x 的 window pixel 检查
dst_x/dst_y 不重复检查
phase_x/phase_y 检查
```

注意：这里说的是当前 TB 代码覆盖点。完整行为仿真仍建议在服务器 VCS 上重新确认，不要只依赖本地 lint。

已做本地语法/lint：

```text
verilator --lint-only -Wno-fatal -DVERIF_DEBUG_EN --top-module tb_downscale_scanner_buffer \
    ram_rws_256x160.v ram_rws_64x128.v \
    pp_downscale_dst_scan_ctrl.v downscale_block_buffer.v tb_downscale_scanner_buffer.v
```

注意：本地 Windows 的 `vvp.exe` 曾经有路径解析问题。完整仿真建议在服务器 VCS 跑：

```text
make clean
make
```

## 9. 当前没有完成的功能

当前还不是完整 PP downscale 模块。

未完成：

```text
Lanczos4 coefficient LUT
horizontal 8-tap MAC
vertical 8-tap MAC
rounding / clipping 到 10bit
pp_downscale_top
downscale 输出打包
Y/U/V 分量独立处理
tile 边界 DDR halo 读取
tile 跨界 stall / request / return 时序
```

## 10. 推荐最终子模块划分

当前推荐最终采用 4 个主模块，而不是继续拆成过多小模块：

```text
pp_downscale_top
  ├── pp_downscale_dst_scan_ctrl
  ├── pp_downscale_block_buffer
  ├── pp_downscale_lanczos4_core
  └── pp_downscale_output_pack

辅助模块：
  └── pp_downscale_lanczos4_coef_rom
```

这样划分的原因：

```text
1. scan_ctrl 只负责“要算哪个点”和坐标/phase 生成。
2. block_buffer 只负责“输入数据怎么存、64 tap 怎么取”。
3. lanczos4_core 只负责“64 tap + phase 怎么算成 1 个像素”。
4. output_pack 只负责“计算后的单点像素如何重新组织成输出流”。
```

### 10.1 pp_downscale_top

顶层负责连接 scan、buffer、core 和 output_pack，并处理 scale=1 的整路 bypass。

top 输入包括：

```text
clk
rst_n
fg2pp_ctrl
fg2pp_ctrl_vld / fg2pp_ctrl_rdy
sw_pic_height
sw_upscale_pic_width
sw_downscale_scale
sw_downscale_width
sw_downscale_height
fg2pp_data / fg2pp_data_vld / fg2pp_data_rdy
bypass_en
```

连接原则：

```text
fg2pp_ctrl / fg2pp_data
    -> 主要进入 block_buffer。

fg2pp_ctrl_vld / fg2pp_ctrl_rdy
    -> top 连接到 block_buffer 的 ctrl_vld / ctrl_rdy。
    -> ctrl_load = ctrl_vld && ctrl_rdy 时，buffer 锁存 fg2pp_ctrl 并开始当前 block 流程。

sw_pic_height / sw_upscale_pic_width
    -> 进入 block_buffer，用于 frame right/bottom clip。

sw_downscale_scale / sw_downscale_width / sw_downscale_height
    -> 进入 dst_scan_ctrl，用于 dst 扫描和 src 坐标计算。

scale=1 bypass_en
    -> 在 top 层直接旁路，fg2pp_data 打一拍后输出，不进入 scan/buffer/core 计算路径。
```

### 10.2 pp_downscale_dst_scan_ctrl

`dst_scan_ctrl` 负责生成 downscale 输出点坐标。

它的输入主要是：

```text
scale_q8
dst_width
dst_height
buffer 给出的当前 block 描述信息
buffer 返回的 64 tap window
```

它的输出主要是：

```text
发给 buffer：
    center_x
    center_y
    center_req_valid

发给 lanczos4_core：
    dst_x
    dst_y
    phase_x_q9
    phase_y_q9
    window_pixels
    core_bypass_en
```

坐标公式仍然使用：

```text
src_q9 = scale_q8 * (2*dst + 1) - 256
center = src_q9 >> 9
phase  = src_q9[8:0]
```

注意：

```text
scanner 不直接读取像素。
scanner 不知道 line/right/bottom/corner SRAM 的内部细节。
scanner 只把 center 请求交给 buffer。
```

### 10.3 pp_downscale_block_buffer

`block_buffer` 是当前已经重点实现的部分。

它负责：

```text
1. 通过 ctrl_vld / ctrl_rdy 握手接收 fg2pp_ctrl，并锁存当前 block 信息。
2. 接收 fg2pp_data，每拍 160bit，即 16 个 10bit 像素。
3. 管理 line_buffer、right_buffer、bottom_buffer、corner_buffer。
4. 根据 scanner 给出的 center_x/center_y 判断 64 tap 数据是否已经齐全。
5. 数据不够时 data_rdy=1，继续接收输入。
6. 数据够时 data_rdy=0，暂停接收，返回 64 tap window。
```

当前 block_buffer 对外接口约定：

```text
ctrl 输入：
    fg2pp_ctrl
    ctrl_vld
    ctrl_rdy

data 输入：
    data_vld
    data_rdy
    data_in[159:0]

给 scanner 的 block 描述：
    scan_block_ctrl_valid_o
    scan_block_ctrl_ready_i
    scan_block_start_x_o
    scan_block_start_y_o
    scan_block_width_o
    scan_block_height_o
    scan_frame_left_o
    scan_frame_right_o
    scan_frame_top_o
    scan_frame_bottom_o

scanner 请求 center：
    scan_center_valid_i
    scan_center_x_i
    scan_center_y_i

buffer 返回 window：
    scan_window_valid_o
    scan_window_pixels_o

scanner 通知 block 扫描结束：
    scan_block_done_i
```

已经删除的旧接口：

```text
ctrl_update_en
buf_clr
scan_window_busy_o
scan_window_valid_mask_o
scan_window_from_right_mask_o
```

当前 buffer 存储结构约定：

```text
line_buffer
    7 个 ram_rws_256x160。
    每个 bank 保存一行 rolling history。
    word_addr = global_x[11:4]。

bottom_buffer
    7 个 ram_rws_256x160。
    保存上一条 block-row 的底部 7 行。

right_buffer
    已从 reg array 改为 1 个 ram_rws_64x128。
    addr = block 内部行号。
    word[69:0] 保存该行右侧 7 个 10bit 像素。
    word[127:70] 暂未使用。

corner_buffer
    当前仍为 7x7 寄存器数组。
    保存右下角 halo，供右下相邻 block 读取左上角数据。
```

right_buffer SRAM 化后的访问规则：

```text
写入：
    从 line SRAM 读出旧行右 7 列。
    打包成 128bit word。
    写入 ram_rws_64x128。

读取：
    window tap 落在 local_x=-7~-1 且 local_y 在当前 block 内时，
    通过 right SRAM 同步读取得到左侧 halo。
```

### 10.4 pp_downscale_lanczos4_core

`lanczos4_core` 负责真正的 Lanczos4 计算。

它接收：

```text
64 个 10bit pixels
phase_x_q9
phase_y_q9
dst_x
dst_y
core_bypass_en
```

注意：`lanczos4_core` 不需要 center_x/center_y，也不需要 window valid mask。

它输出：

```text
dst_x
dst_y
10bit downscale pixel
out_valid
```

当前确定采用：

```text
8 个乘法器，多拍复用。
系数格式 Q1.15。
系数 ROM 独立做成 pp_downscale_lanczos4_coef_rom。
```

计算流程：

```text
1. coef_rom_x 根据 phase_x_q9 输出 coef_x[0:7]。
2. coef_rom_y 根据 phase_y_q9 输出 coef_y[0:7]。
3. 横向 8-tap：
       每拍处理一行，8 个乘法器并行。
       8 拍得到 h_sum[0:7]。
4. 纵向 8-tap：
       复用 8 个乘法器计算 h_sum[i] * coef_y[i]。
5. 纵向累加得到 v_sum。
6. v_sum 做 rounding、右移、clip，输出 10bit pixel。
```

位宽约定：

```text
pixel      : unsigned 10bit
coef       : signed Q1.15, 16bit
h_sum      : signed 32bit, Q15
v_sum      : signed 48bit, Q30
pixel_out  : clip((v_sum + 2^29) >>> 30) 到 0~1023
```

core 内部 bypass：

```text
scale=1 的整路 bypass 放在 top。
core_bypass_en 只用于整数采样点直接取 center pixel。

tap offset 顺序为：
    -3,-2,-1,0,+1,+2,+3,+4

center pixel 对应：
    x_idx=3
    y_idx=3
    win_idx=3*8+3=27
```

### 10.5 pp_downscale_lanczos4_coef_rom

系数 ROM 独立于 core，便于后续替换 LUT 生成方式。

建议接口：

```verilog
module pp_downscale_lanczos4_coef_rom (
    input  [8:0]   phase_q9,
    output [127:0] coef_o
);
```

ROM 内容：

```text
depth = 512
width = 8 * 16 = 128bit
coef_o[15:0]      -> coef[0]
coef_o[31:16]     -> coef[1]
...
coef_o[127:112]   -> coef[7]
```

core 中建议实例化两个 ROM：

```text
coef_rom_x：phase_x_q9 -> coef_x[0:7]
coef_rom_y：phase_y_q9 -> coef_y[0:7]
```

### 10.6 pp_downscale_output_pack

`output_pack` 后续负责把 core 输出的单点结果重新组织成后级需要的输出格式。

当前先保留为后续模块，暂不实现复杂逻辑。

它需要注意：

```text
scanner/buffer/core 的输出顺序不一定严格等于整帧 raster 顺序。
所以 core 输出必须携带 dst_x/dst_y。
output_pack 根据 dst_x/dst_y 做必要的缓存、排序或打包。
```

## 11. scale 和 Lanczos 精度约定

当前讨论结论：

```text
当前 RTL 规划主路径先支持 2~8 倍 downscale。
scale 使用 Q8，1/256 精度：
    1x = 256
    2x = 512
    3x = 768
    ...
    8x = 2048

scale=1 时建议 top 层整路 bypass，不进入 Lanczos 计算路径。
Lanczos phase 使用 Q9，1/512 精度。
Lanczos 系数当前建议使用 signed Q1.15。
```

坐标计算公式：

```text
src_x = scale_x * (dst_x + 0.5) - 0.5
src_y = scale_y * (dst_y + 0.5) - 0.5
```

其中：

```text
center_x/center_y = floor(src_x/src_y)
phase_x/phase_y   = 小数部分，用于查 LUT
```

系数和累加位宽：

```text
coef      : signed Q1.15, 16bit
h_sum     : signed 32bit, Q15
v_sum     : signed 48bit, Q30
pixel_out : clip((v_sum + 2^29) >>> 30)
```

## 12. 后续推进优先级

建议下一步：

```text
1. 在服务器 VCS 跑最新 scanner + buffer 集成 TB，确认 ctrl_vld/ctrl_rdy、删 mask/busy 接口、right SRAM 后仍能跑。
2. 如果 TB 仍 timeout，优先看 data_rdy、cur_state、scan_center_valid_i、center_data_ready、frame_top_prefill_valid。
3. 清理临时 BOTTOM/CORNER ADD 标记，保留有意义注释。
4. 实现 pp_downscale_lanczos4_coef_rom，生成 512 phase、每 phase 8 个 Q1.15 系数。
5. 实现 pp_downscale_lanczos4_core，采用 8 乘法器多拍复用架构。
6. 将 scan/buffer 输出接入 lanczos4_core，验证 64 tap + phase -> 10bit pixel。
7. 实现 pp_downscale_top，连接 scan、buffer、core，并加入 scale=1 bypass。
8. 实现 output_pack / output_fifo。
9. 扩展 Y/U/V 分量处理。
10. 接入 tile 边界 DDR halo。
```

## 13. 重要注意事项

```text
1. 不要把同步 SRAM 当成组合数组读。
2. ram_rws_256x160 没有 write mask，部分 lane 写入必须 RMW。
3. 跨 word 写入要拆成两个 RMW。
4. 覆盖 line SRAM 前，要先保存旧行右 7 列到 right_buffer。
   当前 right_buffer 使用 ram_rws_64x128，低 70bit 保存 7 个 10bit 像素。
5. 覆盖 bottom_buffer 前，要先保存旧 bottom 右下 7x7 到 corner_buffer。
6. line_y_tag 必须跟随 line SRAM 写入更新。
7. data_rdy=0 时，上游必须保持 data_in/data_vld 或暂停发送。
8. 当前 RTL 主要验证 Y 分量路径，U/V 和 tile DDR 是后续扩展。
9. 当前 tile 边界未来走 DDR，不应继续假设 tile 间 halo 一定来自本地 buffer。
```

## 14. 20260612 line_y_tag 更新细节

本次讨论明确了 `line_y_tag` 的更新边界：

```text
line_y_tag 不能在 row>=7 的任意 line SRAM 写入时都更新。
如果 row7 第一个 segment 写回 cur16_reg[0:8] 后立刻把 bank0 tag 从 row0 改成 row7，
那么后续同一行还需要读取 row0 数据的 window 会因为 tag mismatch 读成 invalid/0。
```

因此 tag 更新需要区分普通 segment 和最后 segment：

```text
1. frame_top 前 7 行直接整 word 写入 line_buffer 时，可以立即更新对应 bank 的 line_y_tag。
2. row>=7 的普通 segment 写回时，不应立即更新 line_y_tag。
3. 当本行最后一个 16 像素 segment 已经完成 Lanczos 计算，并进入 writeback 阶段后，
   当前行可计算范围内的 downscale 点已经完成取数和计算。
4. 此时后续只做 left7_reg / cur16_reg 写回，不再读取旧行数据，
   所以允许在最后 segment 的 line SRAM 写回阶段更新 line_y_tag。
```

对应的简化 RTL 条件可以采用：

```verilog
if ((cur_state == ST_WRITEBACK) &&
    (line_wr_state == LW_WRITE) &&
    calc_last_seg_in_row) begin
    line_y_tag[line_wr_req_bank] <= block_start_y + {6'd0, calc_row_cnt};
end
```

这个条件的含义：

```text
只有当前已经完成 Lanczos 计算，正在执行最后 segment 的写回时，
才把 rolling line SRAM bank 的 tag 更新为当前行号。
```

注意：

```text
该简化方案默认 ST_WRITEBACK 阶段不会再产生新的 64-tap window 读请求。
如果后续架构允许计算核心和写回阶段并行，或者允许 writeback 期间继续读旧行，
则需要改成更严格的“line write 请求携带 tag_update 标记”的方式，
只在最后 segment 的 cur16 写回完成后更新 tag。
```

## 15. 20260625 scanner + buffer 集成更新

当前已经不再只做手动 center window read，而是开始接入新版 `pp_downscale_dst_scan_ctrl`。

新增/更新文件：

```text
pp_downscale_dst_scan_ctrl.v
downscale_block_buffer.v
tb_downscale_scanner_buffer.v
Makefile
```

新的集成目标：

```text
scanner 生成 dst_x/dst_y
-> 计算 src_q9
-> 得到 center_x/center_y/phase_x/phase_y
-> 向 buffer 请求 center 对应的 64-tap window
-> buffer 判断当前数据是否足够
-> 数据足够则暂停输入并返回 64 tap
-> scanner 输出 dst/center/phase/window 给后级 Lanczos core
```

当前 TB：

```text
tb_downscale_scanner_buffer.v
```

当前 TB 场景：

```text
64x64 输入图像
32x32 输出图像
scale_q8 = 512，即 2x downscale
2x2 个 32x32 block:
    block0 = (0,0),  frame_top=1, frame_left=1
    block1 = (32,0), frame_top=1, frame_right=1
    block2 = (0,32), frame_bottom=1, frame_left=1
    block3 = (32,32), frame_bottom=1, frame_right=1
```

TB 检查：

```text
1. 每个 scanner 输出的 dst_x/dst_y 不重复、不遗漏。
2. center_x/center_y/phase_x/phase_y 符合 scale 公式。
3. buffer 返回的 64 个像素符合 pixel_value(x,y)=y*100+x。
```

服务器运行方式：

```bash
make clean
make
```

Makefile 当前默认：

```text
TOP ?= tb_downscale_scanner_buffer
TB_FILE ?= $(TOP).v
```

这样 filelist 只包含当前 TOP 对应的 TB，避免旧 TB 仍引用旧端口导致 VCS 编译失败。

## 16. scanner / buffer 当前接口

buffer 给 scanner 的 block 描述：

```verilog
scan_block_ctrl_valid_o
scan_block_ctrl_ready_i
scan_block_start_x_o
scan_block_start_y_o
scan_block_width_o
scan_block_height_o
scan_frame_left_o
scan_frame_right_o
scan_frame_top_o
scan_frame_bottom_o
```

scanner 给 buffer 的 center 请求：

```verilog
scan_center_valid_i
scan_center_x_i
scan_center_y_i
```

buffer 返回 window：

```verilog
scan_window_pixels_o
scan_window_valid_o
```

scanner 告诉 buffer 当前 block 扫描结束：

```verilog
scan_block_done_i
```

对应 scanner 模块输出名为：

```verilog
buf_block_scan_done_o
```

连接关系：

```text
scanner.buf_block_scan_done_o -> buffer.scan_block_done_i
```

该信号含义：

```text
scanner 当前 block 没有更多 center 要请求。
buffer 如果存在未写回的 cur16_reg segment，可以进入 ST_WRITEBACK 提交。
```

注意：

```text
scan_block_done_i 不是像素数据，也不是 window valid。
它只是 scanner -> buffer 的“当前 block 扫描结束，可以提交缓存”的控制信号。
```

## 17. 当前关键状态机修正

### 17.1 window 返回后不能立即写回

早期错误流程：

```text
ST_WINDOW_BUSY
-> window_done
-> ST_WRITEBACK
```

这个会导致同一个输入 segment 只算完一个 center 就写回，覆盖 line_buffer 中旧行。

例如 frame_top block 中：

```text
row0~row6 已经在 line_buffer
row7 seg0 到来后可以触发计算
如果 center=(0,0) 算完立刻把 row7 写入 bank0
后续 center=(2,0) 或 center=(0,2) 再读 row0 时，会读成 row7，出现 got=700/701...
```

当前修正为：

```text
ST_WINDOW_BUSY
-> window_done
-> ST_WINDOW_RESP
-> 等 scanner 拉低 scan_center_valid_i
-> ST_SCAN_READY
```

`ST_WINDOW_RESP` 的意义：

```text
buffer 返回 scan_window_valid_o 后，scanner 下一拍才看到。
在 scanner 消费 window 之前，scan_center_valid_i 仍然保持旧 center。
如果直接回 ST_SCAN_READY，buffer 会把旧 center 当成新请求重复处理。
```

### 17.2 ST_SCAN_READY 的提交条件

当前原则：

```text
scanner 下一个 center 数据足够 -> 继续 ST_WINDOW_BUSY
scanner 下一个 center 数据不够 -> 如果有未提交 cur16_reg，则 ST_WRITEBACK
scanner block done -> 如果有未提交 cur16_reg，则 ST_WRITEBACK，否则结束
```

不能再使用：

```text
window 返回一次就写回
或者 block_row_last 后就写回
```

原因：

```text
row_last 只表示当前输出行在当前 block 内的最后一个点。
下一条输出行可能仍然只依赖当前已有的旧行，不应该触发 cur16 写回覆盖 line_buffer。
```

### 17.3 scanner 右/下边界 off-by-one

Lanczos4 tap 顺序：

```text
-3, -2, -1, 0, +1, +2, +3, +4
```

因此非 frame_right block 中：

```text
center_x + 4 必须仍在当前 block 内
```

32 宽 block：

```text
local_x 最大像素 = 31
最大可算 center = 27
```

所以 scanner 中 block limit 应为：

```verilog
block_x_limit_s = block_width  - 5;
block_y_limit_s = block_height - 5;
```

不能使用：

```verilog
block_width - 4
```

否则 center_x=28 时需要 x=32，但 scanner 仍认为 block0 可算，buffer 会一直等待不可能到来的数据。

## 18. frame_top 前 7 行 prefill 策略

当前 frame_top block 的前 7 行处理方式：

```text
row0~row6:
    直接写入 line_buffer
    不进入 cur16_reg
    不触发 cur16 写回
```

前 7 行写完后，不应该继续盲目接收 row7。

当前新增：

```verilog
frame_top_prefill_valid
frame_top_prefill_ready
```

含义：

```text
row0~row6 已经写入 line_buffer。
buffer 可以暂停输入，先响应 scanner 中只依赖 row0~row6 的 center 请求。
```

例如 scale=2：

```text
dst_y=0 -> center_y=0
需要 y=-3..4，frame top clip 后实际需要 y=0..4
row0~row6 足够

dst_y=1 -> center_y=2
需要 y=-1..6，frame top clip 后实际需要 y=0..6
row0~row6 足够

dst_y=2 -> center_y=4
需要 y=1..8
row0~row6 不够，需要继续接收 row7/row8
```

因此当前判断不是“前 7 行后立即接收 row7”，而是：

```text
如果 scanner 下一个 center 的 center_y + 4 <= 6
    继续暂停输入并返回 window
否则
    data_rdy=1，继续接收后续行
```

更通用地，buffer 使用：

```text
scan_need_y_min = center_y - 3
scan_need_y_max = center_y + 4
recv_y_min <= scan_need_y_min
scan_need_y_max <= recv_y_max
```

frame top clip 会把负 y 需求 clip 到 0。

## 19. calc_segment_valid 与 frame_top_prefill_valid 的区别

之前 `calc_segment_valid` 只置 1，不清 0，导致 buffer 长期误认为 `cur16_reg` 里有一个未提交 segment。

当前语义拆分为：

```text
frame_top_prefill_valid:
    frame_top block 的 row0~row6 已经在 line_buffer 中。
    当前可以不用 cur16_reg 先算只依赖前 7 行的点。

calc_segment_valid:
    cur16_reg 当前保存着一个已经接收、但还没有写回 line_buffer/bottom/right 的 16 像素 segment。
```

当前时序：

```text
frame_top_prefill_done_fire:
    frame_top_prefill_valid <= 1

latch_cur16_en:
    calc_segment_valid <= 1

writeback_done && calc_segment_valid:
    calc_segment_valid <= 0
    frame_top_prefill_valid <= 0
```

这样可以避免：

```text
cur16_reg 已经写回，但 buffer 仍然认为它有效
或者前 7 行 prefill 阶段被误判成 cur16 segment 阶段
```

## 20. 当前仍需重点验证的问题

当前 VCS 截图显示进度已经推进，但仍可能有以下问题需要继续看波形：

```text
1. block0 末尾是否仍会出现 data_rdy 长时间不拉高。
2. center_y 较大时 line_buffer rolling tag 是否与实际 SRAM 内容一致。
3. bottom_buffer 写入 bank 和下一条 block-row 读取 bank 是否一致。
4. corner_buffer 保存时机是否刚好在 bottom_buffer 覆盖旧数据前。
5. right_buffer flush 在 block 最后 7 行是否完整。
6. scanner saved_edge_x/saved_edge_y 跨 block 是否正确。
```

特别关注：

```text
center=(28,20)
center=(30,20)
win_idx=56~63 got=x
```

这类错误通常说明：

```text
line_buffer 的旧行已经被覆盖
或者 bottom/right/corner 对应 halo 数据没有保存成功
或者 scanner 请求了当前 buffer 实际已经无法提供的旧 y 行
```

## 21. 波形 dump 方法

当前 `tb_downscale_scanner_buffer.v` 支持 VCS VPD dump：

```bash
make clean
make RUN_FLAGS=+DUMP_VPD
```

生成：

```text
tb_downscale_scanner_buffer.vpd
```

用 DVE 打开：

```bash
dve -vpd tb_downscale_scanner_buffer.vpd &
```

也支持通用 VCD：

```bash
make clean
make RUN_FLAGS=+DUMP_VCD
```

生成：

```text
tb_downscale_scanner_buffer.vcd
```

建议优先使用 VPD，因为 VCD 文件会很大。

重点观察信号：

```text
u_buf.cur_state
u_buf.wb_state
u_buf.win_state
u_buf.line_wr_state
u_buf.right_rd_state
u_buf.bottom_wr_state
u_buf.corner_rd_state

u_buf.data_rdy
u_buf.data_fire
u_buf.row_cnt
u_buf.seg16_x
u_buf.calc_segment_valid
u_buf.frame_top_prefill_valid

u_scan.sc_state
u_scan.dst_x
u_scan.dst_y
u_scan.buf_center_x_o
u_scan.buf_center_y_o
u_scan.req_buf_data_valid_o
u_scan.buf_block_scan_done_o

u_buf.scan_center_x_i
u_buf.scan_center_y_i
u_buf.center_data_ready
u_buf.center_x_ready
u_buf.center_y_ready
u_buf.recv_y_min
u_buf.recv_y_max
u_buf.scan_need_y_min
u_buf.scan_need_y_max

u_buf.line_y_tag[0..6]
u_buf.linebuf_wr_en
u_buf.linebuf_wr_bank
u_buf.linebuf_wr_addr
u_buf.bottombuf_wr_en
u_buf.bottombuf_wr_bank
u_buf.bottombuf_wr_addr
```

## 22. 2026-06-25 最新调试记录

本节记录 scanner + buffer 集成后，围绕 `frame_top` block 前 7 行、`data_rdy` 反压、以及 writeback 时机讨论出的最新约定。

### 22.1 当前集成架构

当前 `tb_downscale_scanner_buffer.v` 已经把两个模块连起来：

```text
pp_downscale_dst_scan_ctrl
    -> 产生 dst_x/dst_y
    -> 计算 center_x/center_y/phase_x/phase_y
    -> 向 buffer 发送 center 请求

downscale_block_buffer
    -> 判断当前 center 需要的 64 tap 数据是否已经齐全
    -> 数据不够时 data_rdy=1，继续接收输入
    -> 数据够时 data_rdy=0，暂停输入，返回 64 tap window
```

scanner 侧收到 window 后输出：

```text
lanczos_valid_o
lanczos_dst_x/y_o
lanczos_phase_x/y_q9_o
lanczos_window_pixels_o
lanczos_bypass_en_o
lanczos_block_row_last_o    // 当前代码暂时保留给 TB/调试观察，Lanczos core 后续不需要
```

当前 TB 暂时不接真实 Lanczos MAC，主要验证：

```text
1. scanner 是否按 scale 正确产生 center。
2. buffer 是否在数据够时返回正确 64 tap。
3. buffer 数据不够时是否继续接收输入。
4. scanner/buffer 是否不会重复、漏算或提前覆盖 line_buffer。
```

已删除的 scanner 输出接口：

```text
lanczos_center_x_o
lanczos_center_y_o
lanczos_window_valid_mask_o
```

说明：

```text
center_x/y 只用于 scanner 请求 buffer，不需要继续送给 Lanczos core。
block_row_last 只在 scanner 内部用于推进 dst_x/dst_y，不需要送给 core。
当前 RTL 端口暂时仍保留 lanczos_block_row_last_o，主要用于 TB 打印和调试。
后续接 Lanczos core 时可以删除这个外部端口，但内部 row_last 控制信号必须保留。
window_valid_mask 已删除，约定 window_valid=1 时 64 个 tap 全部有效。
```

### 22.2 frame_top 前 7 行处理策略

对于 `frame_top_edge=1` 的 block，前 7 行输入数据先直接写入 line SRAM。

当第 7 行，也就是 `row_cnt=6` 的最后一个 16 像素段接收完成后：

```text
frame_top_prefill_valid = 1
```

此时 buffer 已经拥有全局 y=0~6 的数据。因为 frame top 方向可以 clip，所以很多 early dst 点并不需要第 8 行数据。

例如 2x downscale：

```text
dst_y=0 -> center_y=0 -> y tap 经过 top clip 后只需要 y=0~4
dst_y=1 -> center_y=2 -> y tap 经过 top clip 后只需要 y=0~6
```

所以前 7 行接收完成后，buffer 应该先暂停输入，让 scanner 消化这些已经可计算的点：

```text
data_rdy = 0
继续响应 scanner center 请求
```

只有当 scanner 请求的点需要更大的 y，例如：

```text
center_y + 4 > 6
```

也就是现有 y=0~6 已经不够时，buffer 才重新允许接收第 8 行：

```text
data_rdy = 1
```

注意这里阈值是 `6`，不是 `7`，因为前 7 行的有效行号是：

```text
0,1,2,3,4,5,6
```

### 22.3 `calc_segment_valid` 和 `frame_top_prefill_valid` 的职责区分

当前需要严格区分两个 valid：

```text
frame_top_prefill_valid
    表示 frame_top block 的前 7 行已经写入 line SRAM。
    此时可能还没有任何 cur16_reg 数据。

calc_segment_valid
    表示 cur16_reg 当前保存了一个已经接收、但尚未写回 line SRAM 的 16 像素 segment。
```

这两个信号不能混用。

正确理解是：

```text
frame_top_prefill_valid=1, calc_segment_valid=0
    -> 只能从 line SRAM 读取前 7 行数据。

calc_segment_valid=1
    -> 当前 row/segment 的数据在 cur16_reg 中，window read 可以读 cur16_reg/left7_reg。
```

写回完成后必须清掉 `calc_segment_valid`，否则 buffer 会误以为 cur16_reg 仍然保存着一个未提交 segment，导致：

```text
1. data_rdy 长时间拉不高。
2. ST_SCAN_READY 误进入 ST_WRITEBACK。
3. window read 误从 cur16_reg/left7_reg 取旧数据。
```

### 22.4 目前 buffer 的 center ready 判断方向

当前 buffer 对 scanner 请求的 `center_x/center_y` 做保守判断。

中心点需要的 Lanczos4 范围是：

```text
x: center_x - 3  ~ center_x + 4
y: center_y - 3  ~ center_y + 4
```

对于 frame top/left/right/bottom，超出 frame 的 tap 由 frame clip 处理。

对于非 frame 边界，buffer 必须确认对应数据已经在以下路径之一中：

```text
line SRAM
cur16_reg
left7_reg
right_buffer
bottom_buffer
corner_buffer
```

因此 center ready 不能简单写成：

```text
frame_right_edge || scan_need_x_max <= recv_x_max
frame_bottom_edge || scan_need_y_max <= recv_y_max
```

因为即使当前 block 是 frame_right，也仍然需要等待当前 block 内尚未接收的数据。例如 block 范围是 x=32~63，center_x=45 时，如果当前只收到 x=32~47 的第一段，某些 tap 仍可能尚未写入或尚未可读。

更合理的方向是：

```text
1. 先根据 frame 边界对 tap 坐标做 clip。
2. 再判断 clip 后的坐标是否已经存在于当前 buffer 可读窗口。
```

当前代码中已经补了 y 方向的 lower bound：

```text
scan_need_y_min
recv_y_min
```

用于防止 scanner 请求已经被 rolling line_buffer 覆盖掉的旧 y 行。

### 22.5 writeback 时机约定

writeback 不应该在每一个 center 计算完成后立刻发生。

当前约定是：

```text
scanner 请求 center
buffer 数据够 -> 返回 window
scanner 推进下一个 center
```

如果下一个 center 仍然可以用当前 buffer 内容计算，则继续 window read，不写回当前 segment。

只有当：

```text
1. scanner 请求的下一个 center 数据不够；
2. 并且当前 cur16_reg 确实有未写回 segment；
```

buffer 才进入 writeback，把当前 segment 写回 line SRAM，然后继续接收后续输入。

另外，当 scanner 完成当前 block 扫描时，会通过：

```text
scan_block_done_i
```

通知 buffer。此时如果仍有 `calc_segment_valid=1`，buffer 需要完成最后一次 writeback；如果没有 pending segment，可以直接回到 idle/等待下一个 block。

### 22.6 当前 VCS 现象

最近一次 VCS 截图中，block0 已经能输出较多点，例如：

```text
dst=(0,0) center=(0,0)
dst=(1,0) center=(2,0)
...
dst=(13,0) center=(26,0) row_last=1
```

这说明 scanner 的 2x 坐标生成和 block 右边界 row_last 判断已经基本跑通。

但是后续仍出现：

```text
timeout waiting data_rdy for segment x=16 y=31
timeout waiting buffer idle
```

以及 right/top 后续 case 中部分 window 像素为 `x`。

这类问题优先从以下方向看波形：

```text
1. calc_segment_valid 是否在 writeback_done 后正确清 0。
2. frame_top_prefill_valid 是否在进入真实 row>=7 segment 后正确退出。
3. center_ready_now 是否因为 stale valid 被错误拉高。
4. line_y_tag 是否在整行写完前过早更新。
5. row31 最后一个 segment 后，ST_WRITEBACK / ST_FLUSH_RIGHT 是否结束。
6. scan_block_done_i 是否到达 buffer，并触发最后 pending segment 的 writeback。
```

### 22.7 当前推荐的波形观察顺序

如果 VCS 再次报 timeout，建议先只看 block0，按下面顺序排查：

```text
1. u_scan.dst_x / dst_y / center_x / center_y
2. u_scan.req_buf_data_valid_o
3. u_buf.scan_center_x_i / scan_center_y_i
4. u_buf.center_data_ready / center_x_ready / center_y_ready
5. u_buf.cur_state
6. u_buf.data_rdy
7. u_buf.calc_segment_valid
8. u_buf.frame_top_prefill_valid
9. u_buf.row_cnt / seg16_x
10. u_buf.line_wr_state / wb_state / writeback_done
```

如果 window 像素为 `x`，再重点看：

```text
1. u_buf.line_y_tag[0..6]
2. u_buf.win_src_sel
3. u_buf.win_line_tag_match
4. u_buf.win_tap_y_in_bottom
5. u_buf.win_corner_tag_match
6. u_buf.linebuf_rd_bank / linebuf_rd_addr / linebuf_rd_data_mux
```

这里 `win_src_sel` 如果选择了 line SRAM，但 `line_y_tag` 不匹配或 SRAM 未被写过，就容易出现 `x`。

## 23. 2026-07-02 最新接口清理和当前快照

本节是当前最新状态，后续新对话可以优先从这里开始看。

### 23.1 ctrl 握手更新

`downscale_block_buffer.v` 已删除旧的：

```text
ctrl_update_en
buf_clr
```

当前使用真实握手：

```verilog
input  ctrl_vld;
output ctrl_rdy;
```

内部握手成功信号命名为：

```verilog
ctrl_load = ctrl_vld && ctrl_rdy;
```

语义：

```text
ctrl_load=1:
    1. 锁存当前 fg2pp_ctrl。
    2. 清当前 block 内部流程状态。
    3. 主状态机进入 ST_RECV，开始接收当前 block 的 data。
```

当前 `ctrl_rdy` 规则：

```verilog
ctrl_rdy = (cur_state == ST_IDLE)
```

也就是说，buffer 只有在当前 block 完成、回到 idle 后，才接收下一个 block 的 ctrl。

### 23.2 window 接口清理

buffer 返回 scanner 的 window 接口当前只保留：

```verilog
scan_window_valid_o
scan_window_pixels_o
```

已删除：

```text
scan_window_busy_o
scan_window_valid_mask_o
scan_window_from_right_mask_o
```

删除原因：

```text
scan_window_busy_o:
    scanner 通过保持 center_valid 并等待 scan_window_valid_o 即可完成协议，不需要 busy。

scan_window_valid_mask_o:
    当前约定 scan_window_valid_o=1 时，64 tap 全部有效。
    如果数据不全，buffer 不拉高 scan_window_valid_o。

scan_window_from_right_mask_o:
    只是 debug 来源标记，不参与功能。
    right 路径正确性通过 64 tap pixel_value 检查。
```

### 23.3 scanner 输出给 Lanczos core 的接口清理

`pp_downscale_dst_scan_ctrl.v` 当前输出给后级 Lanczos core 的信号保留：

```verilog
lanczos_valid_o
lanczos_ready_i
lanczos_dst_x_o
lanczos_dst_y_o
lanczos_phase_x_q9_o
lanczos_phase_y_q9_o
lanczos_window_pixels_o
lanczos_bypass_en_o
lanczos_block_row_last_o    // 当前代码暂时保留给 TB/调试观察，Lanczos core 后续不需要
```

已删除：

```text
lanczos_center_x_o
lanczos_center_y_o
lanczos_window_valid_mask_o
```

删除原因：

```text
lanczos_center_x/y:
    center 只用于 scanner 请求 buffer。
    buffer 已经根据 center 取出 64 tap，core 不再需要 center。

lanczos_block_row_last:
    row_last 只用于 scanner 内部推进 dst_x/dst_y 和 edge_x。
    Lanczos core 不需要知道当前点是否是 block 内一行的最后点。
    当前 RTL 端口暂时仍保留 lanczos_block_row_last_o，主要用于 TB 打印和调试。
    后续接 Lanczos core 时可以删除这个外部端口，但内部 row_last 控制信号必须保留。

lanczos_window_valid_mask:
    window_valid=1 已经表示 64 tap 全部有效。
```

scanner 内部仍然保留以下 row_last 相关信号：

```text
current_row_last
row_last_by_block
req_block_row_last
req_row_last_by_block
```

这些是 scanner 内部控制所需，不能删除。

### 23.4 right_buffer SRAM 化状态

`right_buffer` 已从二维寄存器数组改成 SRAM：

```text
ram_rws_64x128
```

映射：

```text
addr = block 内部 row index，当前使用 6bit，可覆盖 0~63 行。
word[69:0] = 7 个 10bit right halo 像素。
word[127:70] = unused。
```

写入流程：

```text
1. 在 line SRAM 旧行被覆盖前，通过 RR_* 状态机读出该旧行右 7 列。
2. 将 7 个 10bit 像素打包到 128bit word 低 70bit。
3. 进入 RR_WRITE，整 word 写入 right SRAM。
```

读取流程：

```text
window tap 落在：
    local_y >= 0
    local_x = -7..-1
且当前 block 不是 frame_left

则 win_src_sel = WIN_SRC_RIGHT。
window FSM 通过 right SRAM 同步读取得到该 tap。
```

注意：

```text
win_sram_from_right 仍然保留。
它不是 debug 信号，而是 window FSM 区分当前 SRAM 返回数据来自 line/bottom/right 的控制信号。
```

### 23.5 当前主要 RTL 文件

当前主路径相关文件：

```text
downscale_block_buffer.v
pp_downscale_dst_scan_ctrl.v
ram_rws_256x160.v
ram_rws_64x128.v
tb_downscale_scanner_buffer.v
Makefile
```

旧备份和历史文件在 `files/` 中，仅作参考，不作为当前编译主路径。

当前 Makefile 默认 top：

```text
tb_downscale_scanner_buffer
```

当前 Makefile filelist 包含：

```text
ram_rws_256x160.v
ram_rws_64x128.v
pp_downscale_dst_scan_ctrl.v
downscale_block_buffer.v
tb_downscale_scanner_buffer.v
```

### 23.6 当前已通过的本地检查

本地已跑过 Verilator lint：

```bash
verilator --lint-only -Wno-fatal -DVERIF_DEBUG_EN \
    --top-module tb_downscale_scanner_buffer \
    ram_rws_256x160.v ram_rws_64x128.v \
    pp_downscale_dst_scan_ctrl.v downscale_block_buffer.v tb_downscale_scanner_buffer.v
```

结果：

```text
通过，无 warning/error。
```

完整行为仿真仍建议在服务器用 VCS 跑：

```bash
make clean
make
```

### 23.7 当前关键流程快照

#### ctrl 装载流程

```text
上游拉高 ctrl_vld。
buffer 在 ST_IDLE 时拉高 ctrl_rdy。
ctrl_load = ctrl_vld && ctrl_rdy。
ctrl_load 后锁存 fg2pp_ctrl，清当前 block 内部状态，并进入 ST_RECV。
```

当前没有外部 `ctrl_update_en` / `buf_clr`。

#### frame_top 前 7 行流程

对于 `frame_top_edge=1`：

```text
row0~row6:
    data_rdy=1 时接收 data_in。
    直接写 line SRAM。
    不写 cur16_reg。

row6 最后一段接收完成:
    frame_top_prefill_valid=1。
    主状态进入 ST_SCAN_READY。
    buffer 暂停继续接收输入，先响应 scanner 已经可以计算的 center。
```

如果 scanner 请求的 center 只需要 `y=0~6` 范围内数据，则可以直接返回 window。

如果 scanner 请求的 center 需要第 7 行或更下面的数据：

```text
center_data_ready=0。
当前没有 calc_segment_valid 时，ST_SCAN_READY 回到 ST_RECV。
data_rdy 重新拉高，继续接收下一行输入。
```

这就是“前 7 行先存，能算的先算；不够再继续收数据”的当前实现方向。

#### row>=7 / 非 frame_top 当前段流程

当当前输入段可以作为计算段：

```text
latch_cur16_en=1:
    cur16_reg <= 当前 16 个 pixel。
    calc_block_x_base / calc_global_x_base / calc_row_cnt 等快照锁存。
    calc_segment_valid=1。
```

这些快照用于后续 window read 和 writeback，避免 `row_cnt/seg16_x` 后续变化导致写回地址错乱。

scanner 请求 center 后：

```text
center_data_ready=0:
    buffer 继续接收输入。

center_data_ready=1:
    buffer 暂停接收输入。
    window FSM 读取 64 tap。
    scan_window_valid_o 拉高 1 拍。
```

scanner 收到 window 后输出给后续 Lanczos core，并继续请求下一个 center。

#### scan_block_done_i

`scan_block_done_i` 是 scanner 通知 buffer：

```text
当前 block 可扫描的 center 已经处理完。
```

buffer 收到后：

```text
如果当前存在 calc_segment_valid，则进入 ST_WRITEBACK。
否则当前 block 扫描结束，回到 ST_IDLE 等下一个 ctrl。
```

### 23.8 下一步建议

当前最自然的下一步：

```text
1. 服务器 VCS 跑最新 scanner + buffer 集成 TB，确认删接口和 ctrl 握手后仍能跑。
2. 如 TB 仍 timeout，优先看 ctrl_load、cur_state、data_rdy、calc_segment_valid、frame_top_prefill_valid。
3. 开始实现 pp_downscale_lanczos4_coef_rom。
4. 开始实现 pp_downscale_lanczos4_core。
```

Lanczos core 当前已定方案：

```text
8 个乘法器，多拍复用。
系数 ROM 独立。
系数格式 signed Q1.15。
h_sum 32bit。
v_sum 48bit。
输出 pixel_out = clip((v_sum + 2^29) >>> 30)。
```

### 23.9 当前项目代码文件标注

后续继续工作时，优先以 `C:\Users\L\Documents\lanczos4` 根目录下的当前主路径代码为准。

#### 当前参与编译/仿真的主代码文件

```text
C:\Users\L\Documents\lanczos4\downscale_block_buffer.v
```

作用：

```text
当前最核心的 buffer 模块。
负责接收 fg2pp_ctrl 和 data_in[159:0]。
管理 line_buffer / right_buffer / bottom_buffer / corner_buffer。
接收 scanner 给出的 center_x/center_y。
判断 64 tap 数据是否已经齐全。
数据够时返回 scan_window_pixels_o / scan_window_valid_o。
数据不够时继续拉高 data_rdy 接收输入。
```

当前重点接口：

```text
ctrl_vld / ctrl_rdy / ctrl_load
data_vld / data_rdy / data_in
scan_block_ctrl_valid_o / scan_block_ctrl_ready_i
scan_center_valid_i / scan_center_x_i / scan_center_y_i
scan_window_pixels_o / scan_window_valid_o
scan_block_done_i
```

注意：

```text
该文件当前仍是主要调试对象。
如果 VCS timeout 或 window pixel mismatch，优先看这个模块的状态机和 buffer 取数路径。
```

```text
C:\Users\L\Documents\lanczos4\pp_downscale_dst_scan_ctrl.v
```

作用：

```text
scanner / coordinate generator 模块。
根据 scale_q8、dst_width、dst_height 扫描 dst_x/dst_y。
计算 src_q9、center_x/center_y、phase_x/phase_y。
向 buffer 发 center 请求。
收到 buffer window 后，把 dst/phase/window 打包输出给后续 Lanczos core。
维护跨 block 的 edge_x / edge_y，避免漏点或重复点。
```

当前重点接口：

```text
buf_block_valid_i / buf_block_ready_o
buf_block_start_x_i / buf_block_start_y_i
buf_block_width_i / buf_block_height_i
buf_frame_left_i / buf_frame_right_i / buf_frame_top_i / buf_frame_bottom_i
req_buf_data_valid_o
buf_center_x_o / buf_center_y_o
buf_window_valid_i / buf_window_pixels_i
lanczos_valid_o / lanczos_ready_i
lanczos_dst_x_o / lanczos_dst_y_o
lanczos_phase_x_q9_o / lanczos_phase_y_q9_o
lanczos_window_pixels_o
lanczos_bypass_en_o
buf_block_scan_done_o
```

注意：

```text
lanczos_block_row_last_o 当前代码里仍暂时保留给 TB/调试观察。
后续接真实 Lanczos core 时可以删除这个外部端口。
但是 scanner 内部 row_last 控制逻辑不能删除。
```

```text
C:\Users\L\Documents\lanczos4\ram_rws_256x160.v
```

作用：

```text
当前 line_buffer 和 bottom_buffer 使用的 SRAM wrapper。
depth=256，width=160。
一个 word 保存 16 个 10bit 像素。
地址 word_addr = global_x[11:4]。
```

使用位置：

```text
downscale_block_buffer.v 中：
    7 个 line SRAM bank。
    7 个 bottom SRAM bank。
```

```text
C:\Users\L\Documents\lanczos4\ram_rws_64x128.v
```

作用：

```text
当前 right_buffer 使用的 SRAM wrapper。
depth=64，width=128。
每个 word 低 70bit 保存一行右侧 7 个 10bit halo 像素。
word[127:70] 暂未使用。
```

使用位置：

```text
downscale_block_buffer.v 中：
    1 个 right SRAM。
```

```text
C:\Users\L\Documents\lanczos4\tb_downscale_scanner_buffer.v
```

作用：

```text
当前 scanner + buffer 集成 testbench。
实例化 pp_downscale_dst_scan_ctrl 和 downscale_block_buffer。
使用 pixel_value(x,y)=y*100+x 检查 64 tap window。
检查 scanner 输出 dst 坐标、phase、重复/漏点问题。
支持 VCS dump VPD/VCD。
```

当前仿真目标：

```text
验证 scanner 产生 center。
验证 buffer 数据不够时继续接收。
验证 buffer 数据够时返回 64 tap。
验证 scanner 收到 window 后推进下一个 dst 点。
```

```text
C:\Users\L\Documents\lanczos4\Makefile
```

作用：

```text
服务器 VCS 仿真入口。
当前默认 TOP=tb_downscale_scanner_buffer。
当前 filelist 应包含 ram_rws_256x160.v、ram_rws_64x128.v、
pp_downscale_dst_scan_ctrl.v、downscale_block_buffer.v、tb_downscale_scanner_buffer.v。
```

运行方式：

```bash
make clean
make
```

#### 当前文档/辅助文件

```text
C:\Users\L\Documents\lanczos4\files\downscale_project_context.md
```

作用：

```text
当前最重要的项目上下文交接文件。
后续新对话优先读取这个文件。
里面记录当前架构、接口、状态机、已完成内容、未完成内容、调试记录和下一步计划。
```

注意：

```text
C:\Users\L\Documents\lanczos4\downscale_project_context.md
```

根目录下也存在一个同名文件，但它不是当前维护的最新交接文档。
继续项目时以 `files\downscale_project_context.md` 为准。

```text
C:\Users\L\Documents\lanczos4\files\downscale_block_buffer_signal_map.md
```

作用：

```text
记录 downscale_block_buffer.v 中变量、位宽、用途。
如果后续看 buffer 代码不清楚某个信号含义，可以先查这个文件。
```

```text
C:\Users\L\Documents\lanczos4\files\pp_downscale_dst_scan_ctrl_signal_table.md
```

作用：

```text
记录 scanner 模块信号含义。
可能不是最新，但仍可作为理解 scanner 变量的参考。
如果接口与 RTL 不一致，以 pp_downscale_dst_scan_ctrl.v 为准。
```

#### 当前历史/参考文件，不作为主编译路径

以下文件主要用于回看历史方案，不应直接作为当前 RTL 主路径继续开发：

```text
C:\Users\L\Documents\lanczos4\files\downscale.v
C:\Users\L\Documents\lanczos4\files\buffer_old.v
C:\Users\L\Documents\lanczos4\files\downscale_block_buffer20260610.v
C:\Users\L\Documents\lanczos4\files\downscale_block_buffer_v3.v
C:\Users\L\Documents\lanczos4\files\downscale_block_buffer_v4.v
C:\Users\L\Documents\lanczos4\files\tb_downscale_block_buffer.v
C:\Users\L\Documents\lanczos4\files\tb_dst_scan_ctrl.v
C:\Users\L\Documents\lanczos4\files\ram_rws_4096x80.v
```

说明：

```text
这些文件可能包含旧接口，例如 ctrl_update_en、buf_clr、valid_mask、from_right_mask 等。
如果后续编译时误把这些旧 TB 或旧 RTL 加入 filelist，容易出现端口不匹配。
```

#### 当前图片/说明类参考文件

```text
C:\Users\L\Documents\lanczos4\files\128x128.png
C:\Users\L\Documents\lanczos4\files\ram.jpg
C:\Users\L\Documents\lanczos4\tile_block_diagram.svg
C:\Users\L\Documents\lanczos4\top_module_structure.svg
C:\Users\L\Documents\lanczos4\files\bottom_buffer_mapping.svg
C:\Users\L\Documents\lanczos4\files\right_buffer_3block.svg
C:\Users\L\Documents\lanczos4\files\window_fsm.svg
C:\Users\L\Documents\lanczos4\files\wb_fsm.svg
```

作用：

```text
这些用于解释 block/tile 结构、SRAM 可选规格、buffer 映射和状态机，不参与 RTL 编译。
```

#### 当前需要新增但尚未实现的代码文件

```text
pp_downscale_lanczos4_coef_rom.v
pp_downscale_lanczos4_core.v
pp_downscale_top.v
pp_downscale_output_pack.v
```

建议实现顺序：

```text
1. pp_downscale_lanczos4_coef_rom.v
2. pp_downscale_lanczos4_core.v
3. scanner + buffer + core 集成
4. pp_downscale_top.v
5. pp_downscale_output_pack.v
```

## 24. 2026-07-05 scanner + buffer 集成验证状态

### 24.1 当前验证结论

截至 2026-07-05，`tb_downscale_scanner_buffer` 已经在 VCS 中验证 PASS。

本轮验证重点覆盖：

```text
scanner 产生 dst/center 请求
-> buffer 判断 center 对应 64 tap 数据是否已经齐全
-> 数据不足时继续接收输入
-> 数据齐全时暂停输入并返回 64 tap window
-> scanner 输出 dst/phase/window
-> scanner 推进到下一个 dst 点
```

当前 VCS 通过结果说明：

```text
input_segments 正常收完
buffer_windows 与 scanner_outputs 数量一致
窗口像素检查无 mismatch
最终 PASS
```

### 24.2 已覆盖的四个 32x32 block 场景

当前集成 TB 使用 2x downscale，验证 2x2 block 场景：

```text
block0: start=(0,0),   frame_top=1, frame_left=1,  frame_bottom=0, frame_right=0
block1: start=(32,0),  frame_top=1, frame_left=0,  frame_bottom=0, frame_right=1
block2: start=(0,32),  frame_top=0, frame_left=1,  frame_bottom=1, frame_right=0
block3: start=(32,32), frame_top=0, frame_left=0,  frame_bottom=1, frame_right=1
```

覆盖到的 buffer 数据来源：

```text
1. frame top/left clip
2. 当前输入的 cur16_reg
3. 当前行上一段 left7_reg
4. line_buffer SRAM
5. right_buffer SRAM
6. bottom_buffer SRAM
7. corner_buffer
```

其中 block3 的左上角窗口会同时用到：

```text
local_x < 0 && local_y < 0   -> corner_buffer
local_x >= 0 && local_y < 0  -> bottom_buffer
local_x < 0 && local_y >= 0  -> right_buffer
local_x >= 0 && local_y >= 0 -> 当前 block 内部数据路径
```

该混合路径已经通过验证。

### 24.3 corner_buffer 修正细节

曾经的失败现象：

```text
block3 start=(32,32)
center=(28,28)
tap 坐标 x=25~31, y=25~31 读到 0
```

这些点应该来自 `corner_buffer`。错误原因不是 scanner 漏点，而是 block2 位于 `frame_bottom` 时没有保存给 block3 使用的 corner。

原问题本质：

```verilog
bottom_save_en = !frame_bottom_edge && ...
```

如果 `save_corner_en` 被包在 `bottom_save_en` 分支内部，那么当当前 block 是 `frame_bottom` 时：

```text
bottom_save_en=0
save_corner_en 没有机会启动
corner_buffer 不会保存
右下 block 读取左上 halo 时得到 0
```

当前修正原则：

```text
corner 保存条件必须与 bottom 写入解耦。
frame_bottom block 不需要继续写 bottom_buffer，
但仍然需要为右侧 block 保存 corner_buffer。
```

当前调度语义：

```text
if (save_corner_en):
    先读取旧 bottom_buffer 的右 7 列，保存到 corner_buffer
    如果 bottom_save_en=1，再写当前 block 的 bottom_buffer
    如果 bottom_save_en=0，也就是 frame_bottom，只保存 corner 后结束
else if (bottom_save_en):
    正常写 bottom_buffer
else:
    writeback 完成
```

`corner_buffer` 的 tag 仍然指向右侧相邻 block：

```verilog
corner_for_block_start_x <= block_start_x + block_pixel_width;
corner_for_block_start_y <= block_start_y;
```

例如 block2 为：

```text
block_start=(0,32), block_width=32
```

则保存后的 corner tag 为：

```text
corner_for_block_start_x=32
corner_for_block_start_y=32
```

正好匹配 block3：

```text
block_start=(32,32)
```

### 24.4 当前 scanner / buffer 分工

当前已经确定的分工：

```text
scanner:
    根据 scale、dst_x、dst_y 生成 center_x、center_y、phase_x、phase_y。
    负责 block 边界扫描、edge_x/edge_y 推进。
    对 buffer 发出 center 请求。
    收到 window 后输出给后续 Lanczos core。

buffer:
    接收 fg2pp_ctrl 和 160bit 像素流。
    管理 line_buffer/right_buffer/bottom_buffer/corner_buffer。
    判断 scanner 请求的 center 对应 64 tap 是否齐全。
    数据不足时保持接收输入。
    数据齐全时暂停输入并返回 64 tap window。
```

当前不再使用旧的：

```text
lanczos_start
lanczos_x_end
lanczos_y_end
block_lanczos_done
block_lanczos_row_last
```

buffer 也不再主动决定“现在要算哪个点”，而是响应 scanner 的 center 请求。

### 24.5 当前仍需继续完善的方向

下一步建议顺序：

```text
1. 继续清理 downscale_block_buffer.v 中乱码注释，补回有意义中文注释。
2. 给 tb_downscale_scanner_buffer 增加更清晰的 PASS 摘要和关键窗口 dump 开关。
3. 开始实现 pp_downscale_lanczos4_coef_rom.v。
4. 实现 pp_downscale_lanczos4_core.v。
5. 将 scanner + buffer + lanczos_core 串起来做端到端像素计算验证。
6. 后续再扩展 UV 分量、tile DDR halo、更多 scale case。
```

当前优先不要大改已经 PASS 的 scanner/buffer 控制链路。后续改动应先保留 `tb_downscale_scanner_buffer` 作为回归测试。

## 25. 2026-07-09 scan + buffer + lanczos_core 联合 TB

本次新增联合仿真 testbench：

```text
C:\Users\L\Documents\lanczos4\tb_downscale_scan_buffer_core.v
```

该 TB 将当前三段主路径串起来：

```text
pp_downscale_dst_scan_ctrl
    -> 产生 dst/center/phase/window 请求

pp_downscale_block_buffer
    -> 接收 block 输入数据
    -> 判断 center 对应 64 tap 是否齐全
    -> 返回 64 tap window

pp_downscale_lanczos4_core
    -> 接收 64 tap + phase
    -> 查 coef_rom
    -> 做 Lanczos4 横向/纵向计算
    -> 输出 10bit downscale pixel
```

### 25.1 当前连接关系

scanner 到 buffer：

```verilog
u_scan.req_buf_data_valid_o -> u_buf.scan_center_valid_i
u_scan.buf_center_x_o       -> u_buf.scan_center_x_i
u_scan.buf_center_y_o       -> u_buf.scan_center_y_i
u_buf.scan_window_valid_o   -> u_scan.buf_window_valid_i
u_buf.scan_window_pixels_o  -> u_scan.buf_window_pixels_i
u_scan.buf_block_scan_done_o-> u_buf.scan_block_done_i
```

scanner 到 core：

```verilog
u_scan.lanczos_valid_o         -> u_core.scan_pixels_valid
u_core.scan_pixels_ready       -> u_scan.lanczos_ready_i
u_scan.lanczos_window_pixels_o -> u_core.scan_pixels_in
u_scan.lanczos_phase_x_q9_o    -> u_core.phase_x_q9
u_scan.lanczos_phase_y_q9_o    -> u_core.phase_y_q9
u_scan.lanczos_bypass_en_o     -> u_core.bypass_en
u_scan.lanczos_ctrl_o          -> u_core.scan_ctrl_in
```

core 输出：

```verilog
u_core.downscale_pixels_valid
u_core.downscale_pixel_out
u_core.downscale_ctrl
```

### 25.2 TB 检查内容

`tb_downscale_scan_buffer_core.v` 仍使用 64x64 输入图像、2x downscale：

```text
scale_q8   = 512
dst_width  = 32
dst_height = 32
pixel_value(x,y) = y * 100 + x
```

测试 4 个 32x32 block：

```text
block0: start=(0,0),   top-left
block1: start=(32,0),  top-right
block2: start=(0,32),  bottom-left
block3: start=(32,32), bottom-right
```

当前检查点：

```text
1. scanner 输出的 dst_x/dst_y 不越界、不重复。
2. scanner 输出 phase_x/phase_y 与 scale=2 的公式一致。
3. scanner 输出的 64 tap window 仍按 pixel_value(x,y) 检查。
4. scanner -> core 通过 valid/ready 握手，不绕过 core ready。
5. core 最终输出数量必须等于 1024。
6. core 输出 pixel 不允许为 X。
7. core 输出 downscale_ctrl[53:0] 必须等于当前 block 原始 fg2pp_ctrl。
8. core 输出 downscale_ctrl[63:54] 必须为 0。
```

注意：该联合 TB 主要验证 scan/buffer/core 的接口、反压、ctrl 对齐和端到端输出数量。Lanczos MAC 的逐点数值参考已经由 `tb_lanczos4_core` 覆盖，因此联合 TB 暂不重新实现完整 software reference MAC。

### 25.3 Makefile 更新

当前 `Makefile` 的 `RTL_FILES` 已加入：

```text
pp_downscale_lanczos4_coef_rom.v
pp_downscale_lanczos4_core.v
```

服务器运行方式：

```bash
make clean
make TOP=tb_downscale_scan_buffer_core
```

保留 scanner+buffer 回归：

```bash
make clean
make TOP=tb_downscale_scanner_buffer
```

保留 core 单测：

```bash
make clean
make TOP=tb_lanczos4_core
```

### 25.4 当前本地检查状态

已在本地跑过 Verilator lint：

```bash
verilator --lint-only -Wno-fatal -DVERIF_DEBUG_EN \
    --top-module tb_downscale_scan_buffer_core \
    ram_rws_256x160.v ram_rws_64x128.v \
    pp_downscale_dst_scan_ctrl.v downscale_block_buffer.v \
    pp_downscale_lanczos4_coef_rom.v pp_downscale_lanczos4_core.v \
    tb_downscale_scan_buffer_core.v
```

结果：

```text
语法和端口连接通过。
仍有已有 warning：
    TIMESCALEMOD：部分模块没有 timescale。
    UNOPTFLAT：downscale_block_buffer.v 中 window 组合逻辑原有 warning。
```

这些 warning 不是本次联合 TB 新增链路导致的 fatal error。

### 25.5 scanner ctrl 初始化状态

`pp_downscale_dst_scan_ctrl.v` 当前采用：

```text
SC_IDLE:
    等待 ctrl_load。

ctrl latch always:
    ctrl_load 时锁存 fg2pp_ctrl_i 到 block_pixel_width、frame_left_edge 等寄存器。

SC_INIT_BLOCK:
    使用已经锁存后的 frame_left_edge/frame_top_edge 初始化 cur_edge_x/y、dst_x/y。
```

`fg2pp_ctrl_r` 用途：

```text
保存当前 block 的原始 54bit ctrl。
scanner 输出给 core 时：
    lanczos_ctrl_o = {10'd0, fg2pp_ctrl_r}
core 再将该 ctrl 与 downscale pixel 对齐输出。
```

## 26. 2026-07-09 deterministic image reference TB

新增端到端数值对比 testbench：`tb_downscale_image_ref.v`。

目标：
- 构造一张确定的 64x64 源图。
- 使用现有 `scan + buffer + lanczos4_core` 联合链路做 2x downscale，输出 32x32 目标图。
- TB 内部使用同一份 `pp_downscale_lanczos4_coef_rom`，根据源图、scanner 输出的 `dst/phase` 重新计算 reference pixel。
- core 输出的每个 `downscale_pixel_out` 都和 reference pixel 逐点比较。
- 仿真结束后打印完整 32x32 RTL downscale 目标图像，每行格式为 `DST_ROW xx: ...`。

源图模型：
```text
source_pixel(x,y) = (x*17 + y*29 + x*y*3 + ((x ^ y)*5) + 37) & 1023
```
该模型是确定性的 10bit 图像，不依赖外部文件，方便 VCS 回归复现。

reference 计算：
- scale 固定为 2x：`scale_q8 = 512`。
- 输出尺寸：`dst_width=32`, `dst_height=32`。
- 对每个 scanner 接受的输出点：
  - `center_x = dst_x * 2`
  - `center_y = dst_y * 2`
  - phase 直接使用 scanner 输出的 `phase_x_q9/phase_y_q9`。
- tap 顺序保持当前工程约定：`-3,-2,-1,0,+1,+2,+3,+4`。
- frame 边界使用 clamp。
- 使用 Q2.14 系数、横向 8 tap + 纵向 8 tap、`+ 1<<27` 后右移 28，再 clip 到 10bit。

连接关系：
```text
pp_downscale_dst_scan_ctrl -> pp_downscale_block_buffer -> pp_downscale_dst_scan_ctrl -> pp_downscale_lanczos4_core
```
scanner 接收 buffer 返回的 64 tap window 后送入 core。TB 在 scanner/core 握手时把 reference pixel 压入 FIFO；core 输出时从 FIFO 取出对应 reference 做比较。

覆盖场景：
- 64x64 源图分成 4 个 32x32 block 输入。
- block0: top-left
- block1: top-right，覆盖 right halo
- block2: bottom-left，覆盖 bottom halo
- block3: bottom-right，覆盖 corner/bottom/right 混合路径

运行方式：
```bash
make clean
make TOP=tb_downscale_image_ref
```

可选 dump 波形：
```bash
make TOP=tb_downscale_image_ref RUN_FLAGS=+DUMP_VPD
make TOP=tb_downscale_image_ref RUN_FLAGS=+DUMP_VCD
```

PASS 标准：
- scanner 输出点数量为 1024。
- core 输出点数量为 1024。
- 每个 core 输出像素与 reference model 一致。
- 每个 core 输出 ctrl 与对应 scanner ctrl 对齐。
- 最终打印：`PASS: tb_downscale_image_ref completed with no errors`。

注意：
- 当前 Windows 窗口没有 `verilator/iverilog/vcs` 环境，未在本机直接跑仿真；需要在服务器使用 VCS 执行上述 make 命令。
- 该 TB 是端到端数值回归，不替代已有 `tb_downscale_scan_buffer_core.v` 的窗口/握手调试用途。

## 27. 2026-07-14 scanner几何预计算与case目录更新

### 27.1 当前实现目标

scanner在请求当前block的第一个center之前，先计算该输入block在downscale输出图像中的几何范围：

```text
block_start_x_new
block_start_y_new
plan_edge_x
plan_edge_y
block_width_new
block_height_new
```

`plan_edge_x/plan_edge_y`采用右开区间：

```text
block_start_x_new <= dst_x < plan_edge_x
block_start_y_new <= dst_y < plan_edge_y

block_width_new  = plan_edge_x - block_start_x_new
block_height_new = plan_edge_y - block_start_y_new
```

正式扫描、跨block保存的edge和输出ctrl宽高都使用同一份`plan_edge`结果。

### 27.2 Q9坐标与四候选并行扫描

坐标公式：

```text
src_q9 = scale_q8 * (2*dst + 1) - 256
center = src_q9 >> 9
phase  = src_q9[8:0]
```

dst每增加1，source Q9坐标增加：

```text
geom_step_q9 = 2 * scale_q8
```

新增状态：

```text
SC_GEOM_INIT：初始化geom_dst_x/y和geom_src_x/y_q9。
SC_GEOM_SCAN：X、Y同拍扫描，每方向每拍比较4个连续候选center。
SC_SEND_CTRL：根据plan_edge_x/y计算输出block宽高并更新ctrl。
```

每拍每个方向检查：

```text
geom_dst + 0
geom_dst + 1
geom_dst + 2
geom_dst + 3
```

如果4个候选都没有到达边界：

```text
geom_dst    += 4
geom_src_q9 += 4 * geom_step_q9
```

X/Y在同一个`SC_GEOM_SCAN`周期并行执行。某个方向先完成后，通过`geom_x_done/geom_y_done`保持结果，另一个方向继续扫描。

```text
geom_x_done_next = geom_x_done || geom_x_hit
geom_y_done_next = geom_y_done || geom_y_hit
```

这样本拍刚找到边界时可以直接参与完成判断。

### 27.3 plan_edge与guard

当前buffer仍然返回完整8x8 Lanczos4窗口，tap范围为`center-3 ... center+4`，因此所有倍率暂时统一使用`guard=4`：

```text
geom_x_limit = block_start_x + block_pixel_width  - 4
geom_y_limit = block_start_y + block_pixel_height - 4
```

第一个满足下式的dst成为右开边界：

```text
center_x(dst_x) >= geom_x_limit -> plan_edge_x = dst_x
center_y(dst_y) >= geom_y_limit -> plan_edge_y = dst_y
```

frame右/下边界允许clip：

```text
frame_right_edge  -> plan_edge_x = dst_width
frame_bottom_edge -> plan_edge_y = dst_height
```

3x/5x/7x虽然输出`bypass_en=1`，目前仍保留`guard=4`。buffer增加只读center像素的真实bypass路径后，才能改为`guard=0`。

### 27.4 输出ctrl四字段更新

scanner构造`updated_ctrl_r`：

```text
updated_ctrl_r[6:0]   = block_height_new
updated_ctrl_r[14:7]  = block_width_new
updated_ctrl_r[35:23] = block_start_x_new
updated_ctrl_r[48:36] = block_start_y_new
```

其余frame/tile边界、block64_loc、block_type、picture_ready字段透传。链路为：

```text
updated_ctrl_r
-> scanner.lanczos_ctrl_o
-> core.scan_ctrl_in
-> core.downscale_ctrl
```

### 27.5 dst与center坐标语义

更新后的ctrl起点是downscale输出图像的`dst`坐标，不是原图center坐标。

2倍downscale示例：

```text
dst=(14,14)
src=(28.5,28.5)
center=(28,28)
phase=(256,256)
```

block3输出几何：

```text
start=(14,14), size=18x18
dst_x=14...31
dst_y=14...31
```

第一条输出行：

```text
dst=(14,14) -> center=(28,28)
...
dst=(31,14) -> center=(62,28), row_last=1
```

`tb_downscale_scan_buffer_core`只打印全局前16点和每行`row_last`，因此日志首先看到`dst=(31,14)`是正常的，不表示block从31开始扫描。

2倍、64x64输入、四个32x32 block的输出几何：

```text
block0: start=(0,0),   size=14x14
block1: start=(14,0),  size=18x14
block2: start=(0,14),  size=14x18
block3: start=(14,14), size=18x18
```

总输出点数：

```text
14*14 + 18*14 + 14*18 + 18*18 = 1024
```

示例ctrl `0x000000e007550912`解码为：

```text
block_start_x_new=14
block_start_y_new=14
block_width_new=18
block_height_new=18
```

### 27.6 case目录和Makefile

所有TB已统一移动到：

```text
C:\Users\L\Documents\lanczos4\case
```

当前case：

```text
case/tb_dst_scan_geometry.v
case/tb_downscale_scan_buffer_core.v
case/tb_downscale_scanner_buffer.v
case/tb_downscale_image_ref.v
case/tb_downscale_block_buffer.v
case/tb_lanczos4_core.v
case/tb_prefill_7row_case.v
case/tb_dst_scan_ctrl.v
```

Makefile：

```makefile
CASE_DIR ?= case
TB_FILE  ?= $(CASE_DIR)/$(TOP).v
```

运行时继续只指定TOP模块名：

```bash
make clean
make TOP=tb_dst_scan_geometry
```

### 27.7 专用scanner几何TB

新增`case/tb_dst_scan_geometry.v`，只实例化scanner，使用dummy window应答推动扫描，不连接真实buffer和core。

覆盖：

```text
scale=2.0
scale=2.3，scale_q8=589
scale=3/5/7
frame_left/right/top/bottom
连续3个横向block
连续3条纵向block-row
saved_edge_x/y跨block传递
updated_ctrl、dst顺序、phase、row_last、bypass
```

白盒检查：

```text
1. plan_edge_x/y等于逐点reference找到的第一个越界dst。
2. 未命中边界时geom_dst_x/y每拍增加4。
3. geom_src_x/y_q9每次推进增加8*scale_q8。
4. 四候选推进次数等于(plan_edge-start)/4。
5. 长扫描必须观察到X/Y同拍推进。
6. 输出数量等于block_width_new*block_height_new。
```

主要预期：

```text
2x横向三个block：14x4、16x4、18x4
2x纵向三条block-row：4x14、4x16、4x18
2.3x、48x64非右/下边界block：19x26
3x：9x9
5x：6x6
7x：4x4
```

PASS信息：

```text
PASS: tb_dst_scan_geometry completed, cases=10
```

### 27.8 当前状态与下一步

Windows环境没有`vcs/iverilog/verilator/make`，新TB只完成静态检查，需在服务器运行：

```bash
make clean
make TOP=tb_dst_scan_geometry

make clean
make TOP=tb_downscale_scan_buffer_core

make clean
make TOP=tb_downscale_image_ref
```

几何和联合回归稳定后的任务顺序：

```text
1. 实现输出packer。
2. 像素通路从10bit规划到最高16bit。
3. 8个16bit像素打包成128bit输出。
4. 每个输出block的像素前发送updated ctrl。
5. right_buffer改为SRAM。
6. 扩展Y/U/V状态隔离和tile DDR halo。
```
