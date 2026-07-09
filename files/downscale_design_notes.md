# PP Downscale Lanczos4 设计记录

本文档用于记录 PP 后处理 downscale 模块的总体目标、输入传输格式、当前已经实现的 RTL 功能、暂未覆盖的限制，以及后续推进方向。  
目的：即使对话上下文丢失，也可以根据本文档继续推进项目。

## 1. 最终模块目标

PP downscale 模块位于 AV1 后处理链路中，用于将解码后的图像按照软件配置的缩放比例做高质量下采样。

最终模块要完成的事情不是单纯缓存像素，也不是单纯做 MAC，而是完整解决：

```text
输入 block 像素流
-> 根据 scale 生成 dst/src 坐标
-> 为每个输出点准备 Lanczos4 需要的 8x8 原图像素
-> 根据 phase 选择 Lanczos4 系数
-> 完成横向和纵向 8-tap 计算
-> 输出 downscale 后的像素
```

当前阶段的重点是前半部分：

```text
在不缓存整帧的情况下，正确接收 block 流数据，并为给定 center_x/center_y 返回 64 个 tap 像素。
```

## 2. 为什么不能直接整帧缓存

以 4096x2304 10bit 图像为例，如果缓存整帧，需要：

```text
4096 * 2304 * 10bit
```

存储开销过大，不适合作为 PP 内部 SRAM 方案。

因此当前设计采用局部 buffer + halo buffer：

```text
line_buffer    保存当前 block 计算需要的历史行
right_buffer   保存左侧 block 给右侧 block 用的左侧 halo
bottom_buffer  保存上方 block-row 给下方 block-row 用的上方 halo
corner_buffer  保存右下相邻 block 需要的左上角 halo
```

核心思想：

```text
只保存 Lanczos4 计算真正需要的邻域数据，不保存整帧。
```

## 3. 输入图像传输格式

### 3.1 tile 和 block 顺序

输入数据按 tile、block、block 内行段顺序 streaming 传输。

如果图像有多个 tile，例如 2x2：

```text
tile0  tile1
tile2  tile3
```

当前理解的传输顺序为：

```text
tile0 -> tile1 -> tile2 -> tile3
```

每个 tile 内部的 block 顺序为：

```text
从左到右
从上到下
```

也就是说：

```text
先传完 tile0 内部所有 block
再传 tile1 内部所有 block
再传 tile2 内部所有 block
再传 tile3 内部所有 block
```

### 3.2 block 内部像素顺序

每个 block 内部按行传输：

```text
从左到右
从上到下
```

每拍输入：

```text
data_in[159:0] = 16 个像素 * 10bit
```

一个 32x32 block 的 Y 分量传输示例：

```text
row0:  x0~15   -> cycle0
row0:  x16~31  -> cycle1
row1:  x0~15   -> cycle2
row1:  x16~31  -> cycle3
...
row31: x0~15   -> cycle62
row31: x16~31  -> cycle63
```

RTL 中用于定位当前输入数据的计数：

```verilog
seg16_x          // 当前行内第几个 16 像素段
row_cnt          // 当前 block 内部行号
in_block_x_base  // 当前 16 像素段在 block 内部的 x 起点
in_global_x_base // 当前 16 像素段在整帧中的 x 起点
```

这些计数只在握手成功时推进：

```verilog
data_fire = data_vld && data_rdy;
```

### 3.3 Y/U/V 分量顺序

实际数据不是只传 Y。每个 block 数据来之前会先发送 ctrl 信息，ctrl 中：

```text
block_type = 0 -> Y 分量
block_type = 1 -> U 分量
block_type = 2 -> V 分量
```

同一个 block 的传输顺序为：

```text
当前 block 的 Y 分量
当前 block 的 U 分量
当前 block 的 V 分量
下一个 block 的 Y 分量
下一个 block 的 U 分量
下一个 block 的 V 分量
...
```

也就是：

```text
block0_Y -> block0_U -> block0_V -> block1_Y -> block1_U -> block1_V -> ...
```

当前 RTL 和 TB 暂时只按 Y 分量路径推进，尚未区分 U/V 的独立缓存、坐标缩放关系和输出组织。

后续接入 U/V 时需要确认：

- U/V 是否与 Y 同尺寸，还是 4:2:0/4:2:2 下采样尺寸。
- U/V 的 `block_start_x/y` 和 `block_pixel_width/height` 是否已经按 chroma 坐标给出。
- U/V 是否复用同一套 line/right/bottom/corner buffer，还是按分量分 bank/分实例。
- 输出顺序是否仍按 block 内 Y/U/V，还是 downscale 后重新组织。

## 4. ctrl 信息

当前 ctrl 由 `fg2pp_ctrl` 输入，在 `ctrl_update_en` 时锁存。

已使用或需要使用的字段：

```text
block_pixel_height
block_pixel_width
frame_top_edge
frame_bottom_edge
frame_left_edge
frame_right_edge
tile_top_edge
tile_bottom_edge
tile_left_edge
tile_right_edge
block_start_x
block_start_y
block_type
picture_ready
```

当前 RTL 已锁存这些字段，但主要使用的是：

```text
block 宽高
frame 边界
block_start_x/y
block_type 锁存但还未真正参与 Y/U/V 分量分流
```

tile 边界当前暂不处理，未来 tile 边界 halo 会保存在 DDR 中。

## 5. 当前 buffer 架构

### 5.1 line_buffer

用途：

```text
保存当前 block 内部最近 7 行历史数据。
```

原因：

```text
Lanczos4 垂直方向需要 8 tap。
当前输入行通过 cur16_reg 提供，因此额外保存 7 行历史即可。
```

实现：

```text
7 个 ram_rws_256x160 SRAM bank
```

地址映射：

```verilog
word_addr = global_x[11:4];
lane_idx  = global_x[3:0];
```

一个 SRAM word 保存：

```text
16 pixels * 10bit = 160bit
```

最大宽度 4096 时：

```text
4096 / 16 = 256 word
```

所以 SRAM 深度为 256，地址位宽为 8bit。

### 5.2 cur16_reg

用途：

```text
保存当前刚输入、正在被 Lanczos 计算使用的 16 个像素。
```

原因：

当前 16 像素还没有写回 line SRAM，但 Lanczos 当前点可能已经需要读取它，因此提供旁路。

### 5.3 left7_reg

用途：

```text
保存当前行上一段 16 像素的最后 7 个像素。
```

原因：

当前段刚到来时，计算可能需要上一段末尾的 tap。为了避免过早覆盖，这 7 个像素先保存在寄存器中。

### 5.4 right_buffer

用途：

```text
保存当前 block 最右 7 列，给右侧 block 做左侧 halo。
```

触发场景：

```text
右侧 block 请求 local_x < 0 的 tap。
```

当前实现：

```text
right_buffer 仍是寄存器数组。
```

### 5.5 bottom_buffer

用途：

```text
保存当前 block 最后 7 行，给下一条 block-row 做上方 halo。
```

触发场景：

```text
非 frame_top block 请求 local_y = -7 ~ -1 的 tap。
```

当前实现：

```text
7 个 ram_rws_256x160 SRAM bank
```

当前假设：

```text
block x 起点和宽度按 16 像素对齐，因此 bottom 写入先整 word 写，不做 RMW。
```

### 5.6 corner_buffer

用途：

```text
保存右下相邻 block 需要的左上角 7x7 halo。
```

触发场景：

```text
local_x < 0 && local_y < 0
```

原因：

右下相邻 block 同时需要左侧 block 数据和上方 block-row 数据。单靠 right_buffer 或 bottom_buffer 不够，因此需要在 bottom_buffer 被覆盖前保存旧 bottom 的右 7 列。

当前实现：

```text
7x7 寄存器数组
corner_valid
corner_for_block_start_x/y tag
```

## 6. 64-tap window read 约定

后级 Lanczos 计算模块给出整数中心坐标：

```verilog
lanczos_center_x
lanczos_center_y
```

buffer 模块内部展开 8-tap offset：

```text
-3, -2, -1, 0, +1, +2, +3, +4
```

得到：

```text
tap_x = center_x + offset_x
tap_y = center_y + offset_y
```

输出 64 个像素：

```text
win_idx = y_idx * 8 + x_idx
```

也就是 x 方向变化最快。

取数来源：

```text
local_y < 0 && local_x < 0  -> corner_buffer
local_y < 0 && local_x >= 0 -> bottom_buffer
local_y >= 0 && local_x < 0 -> right_buffer
当前 16 像素段              -> cur16_reg
当前行上一段最后 7 像素      -> left7_reg
已写回历史行/当前行早期像素  -> line_buffer
```

frame 边界处理：

```text
frame_left_edge   && x < 0       -> clip 到 x=0
frame_right_edge  && x >= width  -> clip 到 width-1
frame_top_edge    && y < 0       -> clip 到 y=0
frame_bottom_edge && y >= height -> clip 到 height-1
```

tile 边界处理：

```text
当前暂不处理。
未来 tile 边界 halo 数据会保存到 DDR，并由 tile_halo_ddr_if 或类似模块提供。
```

## 7. 当前已实现功能

当前 `downscale_block_buffer.v` 已实现：

- `fg2pp_ctrl` 锁存。
- 160bit 输入拆成 16 个 10bit pixel。
- `seg16_x/row_cnt` 输入计数。
- `data_rdy` 反压。
- frame_top block 前 7 行填充 line_buffer。
- 非 frame_top block 基于 bottom_buffer 从 row0 开始计算。
- `cur16_reg/left7_reg/line_buffer/right_buffer/bottom_buffer/corner_buffer` 取数路径。
- center-based 64-tap window read。
- line_buffer SRAM 化：7 个 `ram_rws_256x160`。
- bottom_buffer SRAM 化：7 个 `ram_rws_256x160`。
- line SRAM 部分写回 RMW。
- right_buffer 保存和 block 尾部 flush。
- corner_buffer 保存旧 bottom 右下 7x7。
- bottom/corner 相关标记注释：`BOTTOM/CORNER ADD START/END`。

当前 `tb_downscale_block_buffer.v` 已覆盖：

- frame-left/top 基础取数。
- left7 + cur16 混合取数。
- right_buffer 路径。
- bottom_buffer 路径，`center=(5,28)`。
- corner/bottom/right 混合路径，`center=(32,28)`。
- `valid_mask/from_right_mask/pixel_value` 检查。

当前语法/lint 检查已通过：

```text
iverilog -g2012 -DVERIF_DEBUG_EN -tnull ram_rws_256x160.v downscale_block_buffer.v tb_downscale_block_buffer.v
verilator --lint-only -DVERIF_DEBUG_EN ram_rws_256x160.v downscale_block_buffer.v tb_downscale_block_buffer.v
```

本地没有跑完整 vvp 仿真，因为 Windows 环境中的 `vvp.exe` 曾出现路径解析问题。服务器可用 VCS 执行：

```text
make clean
make
```

## 8. 当前没有完成的内容

当前设计还不是完整 PP downscale，只完成了 block buffer 和 64-tap 取数支撑。

尚未完成：

- `dst_x/dst_y` 输出点扫描调度。
- `scale_x/scale_y` 定点坐标计算。
- `src_x/src_y` 的整数中心和 phase 生成。
- Lanczos4 系数 LUT。
- 横向 8-tap MAC。
- 纵向 8-tap MAC。
- rounding / clipping 到 10bit。
- downscale 输出打包。
- Y/U/V 三分量独立处理。
- tile 边界 DDR halo 读取。
- tile 跨界时的 stall/DDR request/return 时序。

## 9. 后续推荐子模块划分

建议完整 downscale 顶层拆成：

```text
downscale_top
  ├── input_block_buffer
  ├── dst_scan_ctrl / coordinate_generator
  ├── coef_lut
  ├── lanczos_mac_core
  ├── output_pack / output_fifo
  └── tile_halo_ddr_if   // 后续支持 tile 边界
```

### input_block_buffer

当前正在实现的模块。

负责：

```text
输入 block 流接收
局部 buffer/halo buffer 管理
给定 center_x/y 返回 64 tap pixels
```

### dst_scan_ctrl / coordinate_generator

下一阶段建议重点实现。

负责：

```text
扫描 dst_x/dst_y
根据 scale 计算 src_x/src_y
生成 center_x/center_y
生成 phase_x/phase_y
判断当前输入范围是否足够计算该输出点
```

### coef_lut

负责：

```text
根据 phase_x/phase_y 输出 coef_x[0:7] 和 coef_y[0:7]
```

当前规划：

```text
scale 小数精度 1/256
LUT phase 精度 1/512
coef 格式可先按 signed Q2.14
```

### lanczos_mac_core

负责：

```text
64 pixels + coef_x/y
-> 横向 8-tap
-> 纵向 8-tap
-> rounding / clip
-> 10bit pixel
```

### output_pack / output_fifo

负责：

```text
把单点输出按后级要求重新组织成输出流
处理 output valid/ready
```

### tile_halo_ddr_if

后续 tile 跨界支持模块。

负责：

```text
tile 边界 halo 写 DDR
tile 边界 halo 从 DDR 读回
向 input_block_buffer/window read 提供 tile 边界 tap
```

## 10. 后续推进优先级

建议顺序：

1. 先跑服务器 VCS，确认当前 bottom/corner TB PASS。
2. 清理 `downscale_block_buffer.v` 中临时 `BOTTOM/CORNER ADD` 标记，保留有意义注释。
3. 设计 `dst_scan_ctrl / coordinate_generator`。
4. 明确 scale 定点格式、phase 格式和 OpenCV 对齐策略。
5. 实现 dst 扫描，根据 `lanczos_x_end/y_end` 只请求已可计算点。
6. 实现 Lanczos coefficient LUT。
7. 实现 `lanczos_mac_core`。
8. 接入输出打包。
9. 再扩展 Y/U/V 分量处理。
10. 最后接入 tile 边界 DDR halo。

## 11. Y/U/V 后续接入注意点

当前 block_type 定义需要按新输入协议理解：

```text
0: Y
1: U
2: V
```

后续至少需要决定：

1. 三个分量是否共用同一套 buffer 实例，还是每个分量独立一套 buffer。
2. U/V 分量的图像宽高是否与 Y 一致。
3. U/V 的 scale 是否与 Y 相同，还是需要 chroma 坐标换算。
4. `fg2pp_ctrl.block_start_x/y` 对 U/V 是 luma 坐标还是 chroma 坐标。
5. 输出是否要求 Y/U/V 保持输入 block 顺序，还是按 downscale 后图像平面输出。

建议后续先做 Y 分量完整闭环，再根据实际 chroma 格式扩展 U/V。

## 12. tile 边界 DDR 后续注意点

当前 frame 内相邻 block 的 halo 通过 right/bottom/corner buffer 解决。

tile 边界不同：

```text
tile 内部传输完后，下一个 tile 不一定能直接从当前局部 buffer 获得 halo。
```

用户已明确未来 tile 边界会保存在 DDR 中，因此后续需要：

- tile 右边界写 DDR，给右侧 tile 使用。
- tile bottom 边界写 DDR，给下方 tile 使用。
- tile corner 写 DDR 或通过 DDR 组合读取。
- window read 遇到 tile 边界 tap 时，向 DDR halo 接口请求。
- DDR 返回延迟可能导致 window read stall。

当前阶段不实现 tile DDR，但顶层和 buffer 取数路径需要预留扩展点。

## 13. 重要注意事项

- 不要把同步 SRAM 当成组合数组读。
- `ram_rws_256x160` 没有 write mask，部分 lane 写入必须 RMW。
- 跨 word 写入要拆成两个 RMW。
- 覆盖 line SRAM 前，要先保存旧行右 7 列到 right_buffer。
- 覆盖 bottom_buffer 前，要先保存旧 bottom 右下 7x7 到 corner_buffer。
- `line_y_tag` 必须跟随 line SRAM 写入更新，否则 window read 可能读错 rolling bank。
- `data_rdy=0` 时，上游必须保持当前 `data_in/data_vld` 或暂停发送。
- 当前 `from_right_mask` 只标记 right_buffer 来源，不标记 bottom/corner 来源。
- 当前 RTL 主要验证 Y 分量路径，U/V 和 tile DDR 都是后续扩展。
