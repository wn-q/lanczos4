# PP Downscale Lanczos4 项目上下文快照

生成日期：2026-06-12

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
    当前仍是寄存器数组。

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

后级 Lanczos 计算模块给出原图整数中心坐标：

```verilog
lanczos_center_x
lanczos_center_y
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
ram_rws_256x160.v
tb_downscale_block_buffer.v
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
12. right_buffer 保存和 block 尾部 flush。
13. corner_buffer 保存旧 bottom 的右下 7x7。
14. bottom/corner 相关代码用 BOTTOM/CORNER ADD START/END 标记。
```

当前 TB 已覆盖：

```text
frame-left/top 基础取数
left7 + cur16 混合取数
right_buffer 路径
bottom_buffer 路径，center=(5,28)
corner/bottom/right 混合路径，center=(32,28)
valid_mask / from_right_mask / pixel_value 检查
```

已做本地语法/lint：

```text
iverilog -g2012 -DVERIF_DEBUG_EN -tnull ram_rws_256x160.v downscale_block_buffer.v tb_downscale_block_buffer.v
verilator --lint-only -DVERIF_DEBUG_EN ram_rws_256x160.v downscale_block_buffer.v tb_downscale_block_buffer.v
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
dst_x / dst_y 输出点扫描调度
scale_x / scale_y 定点坐标计算
src_x / src_y 生成
center_x / center_y / phase_x / phase_y 生成
Lanczos4 coefficient LUT
horizontal 8-tap MAC
vertical 8-tap MAC
rounding / clipping 到 10bit
downscale 输出打包
Y/U/V 分量独立处理
tile 边界 DDR halo 读取
tile 跨界 stall / request / return 时序
```

## 10. 推荐最终子模块划分

建议最终拆分：

```text
downscale_top
  ├── input_block_buffer
  ├── dst_scan_ctrl / coordinate_generator
  ├── coef_lut
  ├── lanczos_mac_core
  ├── output_pack / output_fifo
  └── tile_halo_ddr_if
```

各模块职责：

```text
input_block_buffer
    当前正在实现的部分。
    接收输入 block 流，管理局部 buffer 和 halo buffer。
    给定 center_x/y 返回 64 tap pixels。

dst_scan_ctrl / coordinate_generator
    下一步建议重点实现。
    扫描 dst_x/dst_y，根据 scale 生成 src_x/src_y。
    输出 center_x/center_y/phase_x/phase_y。
    判断当前输入范围是否足够计算对应输出点。

coef_lut
    根据 phase_x/phase_y 输出 coef_x[0:7]、coef_y[0:7]。

lanczos_mac_core
    64 pixels + coef_x/y -> 横向 8-tap -> 纵向 8-tap -> 10bit pixel。

output_pack / output_fifo
    把单点输出重新组织成后级需要的输出流格式。

tile_halo_ddr_if
    后续支持 tile 边界 halo 写 DDR / 读 DDR。
```

## 11. scale 和 Lanczos 精度约定

当前讨论结论：

```text
scale 支持 1~4 倍范围。
scale 小数部分按 1/256 精度。
Lanczos LUT phase 按 1/512 精度制备。
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

## 12. 后续推进优先级

建议下一步：

```text
1. 在服务器 VCS 跑当前 bottom/corner TB，确认 PASS。
2. 清理临时 BOTTOM/CORNER ADD 标记，保留有意义注释。
3. 设计并实现 dst_scan_ctrl / coordinate_generator。
4. 明确 scale 定点格式和 OpenCV 对齐策略。
5. 根据 lanczos_x_end/y_end 只请求当前已经可计算的输出点。
6. 实现 coef_lut。
7. 实现 lanczos_mac_core。
8. 实现 output_pack。
9. 扩展 Y/U/V 分量处理。
10. 接入 tile 边界 DDR halo。
```

## 13. 重要注意事项

```text
1. 不要把同步 SRAM 当成组合数组读。
2. ram_rws_256x160 没有 write mask，部分 lane 写入必须 RMW。
3. 跨 word 写入要拆成两个 RMW。
4. 覆盖 line SRAM 前，要先保存旧行右 7 列到 right_buffer。
5. 覆盖 bottom_buffer 前，要先保存旧 bottom 右下 7x7 到 corner_buffer。
6. line_y_tag 必须跟随 line SRAM 写入更新。
7. data_rdy=0 时，上游必须保持 data_in/data_vld 或暂停发送。
8. from_right_mask 当前只标记 right_buffer 来源，不标记 bottom/corner 来源。
9. 当前 RTL 主要验证 Y 分量路径，U/V 和 tile DDR 是后续扩展。
10. 当前 tile 边界未来走 DDR，不应继续假设 tile 间 halo 一定来自本地 buffer。
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
