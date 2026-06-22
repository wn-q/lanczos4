# downscale_block_buffer code walkthrough

本文按状态机协作关系串起 `downscale_block_buffer.v` 的功能，并列出每个
`always` 块分别负责什么。

## 1. 模块当前实现范围

`pp_downscale_block_buffer` 当前主要做四件事：

1. 接收当前 block 的输入像素，每拍 16 个像素，即一个 160bit word。
2. 对 frame top 场景，先填满 7 行 line SRAM，然后逐段启动 Lanczos 计算。
3. Lanczos 计算期间，根据中心坐标读取 8x8 tap 窗口，数据来源可能是：
   `right_buffer`、`cur16_reg`、`left7_reg`、`line SRAM`。
4. Lanczos 当前段算完后，把当前段数据写回 line SRAM，并在需要时保存右侧 7 列到
   `right_buffer`，供右侧 block 使用。

当前代码注释也说明：tile 边界、非 frame-top、bottom/corner buffer 还没有完整接入。

## 2. 关键存储结构

### cur16_reg

`cur16_reg[0:15]` 保存当前正在送给 Lanczos 计算的 16 个输入像素段。

这 16 个像素在 Lanczos busy 期间还没有写回 line SRAM，所以窗口读取时如果 tap
落在当前段范围内，要直接从 `cur16_reg` 旁路读取。

### left7_reg

`left7_reg[0:6]` 保存上一段的最后 7 个像素，也就是上一段的 `x9~x15`。

非行尾段写回时，当前 16 像素段只先安全写前 9 个，后 7 个要留给下一段做左侧
tap 使用。等下一段算完后，这 7 个像素才安全写回 line SRAM。

### right_buffer

`right_buffer[row][0:6]` 保存当前 block 的右侧 7 列像素，用于右侧 block 的左侧
halo。

保存 right_buffer 时有两类来源：

- 正常覆盖旧行前，从 line SRAM 旧行里读出右 7 列。
- block 最后几行不会自然被后续行覆盖，所以在 `ST_FLUSH_RIGHT` 阶段额外 flush。

### line SRAM

代码例化了 7 个 `ram_rws_256x160` bank：

- 7 个 bank 对应循环保存的 7 条历史行。
- 每个 bank 有 256 个 word。
- 每个 word 是 160bit，即 16 个 10bit 像素。

`linebuf_rd_bank` 选择读哪一个 bank，`linebuf_rd_addr` 选择该 bank 内哪个 160bit
word，`linebuf_rd_data_mux` 是读回来的 160bit word。

`line_y_tag[0:6]` 记录每个 bank 当前保存的真实全局 y 行号。因为 `y % 7` 只能得到
物理 bank，不能保证这个 bank 里一定是目标行，所以读取 line SRAM 前需要 tag match。

## 3. 顶层状态机 cur_state

顶层状态机是模块的数据阶段控制器：

```text
ST_IDLE
  等待外部 buf_clr 后进入 ST_RECV。

ST_RECV
  接收输入像素。
  frame top 前 7 行只写 line SRAM，不启动 Lanczos。
  row_cnt >= 7 后，每接收一个 16 像素段，锁存到 cur16_reg 并拉高 lanczos_start。

ST_LANCZOS_BUSY
  等待外部 Lanczos 计算完成 block_lanczos_done。
  这个阶段允许 8x8 window read FSM 响应 lanczos_window_req。

ST_WRITEBACK
  当前段 Lanczos 完成后，调用写回 sequencer。
  写回 sequencer 可能先保存旧行右 7 列，再写 left7，再写 cur16。

ST_FLUSH_RIGHT
  block 最后一行写完后，补存最后 7 行的 right_buffer。
  前 6 行从 line SRAM 读，最后 1 行从 cur16_reg 取。
```

典型转移关系：

```text
ST_RECV
  -- latch_cur16_en -->
ST_LANCZOS_BUSY
  -- block_lanczos_done -->
ST_WRITEBACK
  -- writeback_done 且不是 block 结束 -->
ST_RECV

ST_WRITEBACK
  -- writeback_done 且 need_tail_flush -->
ST_FLUSH_RIGHT
  -- flush 最后一行完成 -->
ST_IDLE
```

## 4. 子状态机之间的配合

### 4.1 window read FSM: win_state

`win_state` 是低速 8x8 tap 窗口读取器。

它只在 `cur_state == ST_LANCZOS_BUSY` 时接受 `lanczos_window_req`。一次请求会锁存
`lanczos_center_x/y`，然后用 `win_idx = 0..63` 逐个取 64 个 tap。

每个 tap 先走组合逻辑判断来源：

```text
WIN_SRC_RIGHT   -> right_buffer，当前拍可直接保存
WIN_SRC_CUR16   -> cur16_reg，当前拍可直接保存
WIN_SRC_LEFT7   -> left7_reg，当前拍可直接保存
WIN_SRC_LINE    -> line SRAM，同步读，需要 READ/SAVE 两拍
WIN_SRC_INVALID -> 保存 valid=0
```

状态流：

```text
WIN_IDLE
  等 lanczos_window_req。

WIN_TAP_PREP
  根据 win_src_sel 处理当前 win_idx。
  如果来源是寄存器，直接写入 lanczos_window_pixels_r。
  如果来源是 line SRAM，锁存 bank/addr/lane/save_idx，进入 WIN_SRAM_READ。

WIN_SRAM_READ
  通过 line SRAM access mux 发出读请求。

WIN_SRAM_SAVE
  从 linebuf_rd_data_mux 的 160bit word 中按 lane 切出 10bit 像素，
  写回 lanczos_window_pixels_r[win_line_save_idx]。

WIN_DONE
  拉高 lanczos_window_valid_r 一拍，然后回到 WIN_IDLE。
```

`win_line_save_idx` 的作用是保存“本次 SRAM 返回数据属于第几个 tap”。SRAM 数据晚一拍
回来，所以不能只依赖当前 `win_idx`。

### 4.2 line SRAM write FSM: line_wr_state

`line_wr_state` 是通用 line SRAM 写引擎，用来处理 partial write。

因为 line SRAM 一个 word 是 16 像素，写请求可能只更新其中几个像素，或者跨 16 像素
word 边界，所以它采用 read-modify-write：

```text
LW_IDLE
  等 line_wr_start，锁存写请求。
  计算本次 chunk 能写多少像素，避免跨过当前 16 像素 word 边界。
  如果刚好整 word 写 16 像素且 x 对齐 16，则跳过读旧数据，直接进入 LW_WRITE。
  否则进入 LW_READ。

LW_READ
  发起 line SRAM 旧 word 读取。

LW_MERGE
  把旧 160bit word 读出来，只替换本次需要更新的 lane。

LW_WRITE
  写回合并后的 160bit word。
  如果请求还没写完，移动到下一个 16 像素 word 继续 LW_READ。

LW_DONE
  写请求完成，一拍后回到 LW_IDLE。
```

### 4.3 right7 read FSM: right_rd_state

`right_rd_state` 专门从 line SRAM 旧行中读取连续 7 个像素，保存到 `right_buffer`。

因为起始 x 可能不对齐 16 像素 word，右 7 列可能跨 word：

```text
start_lane <= 9  -> 7 个像素都在当前 160bit word。
start_lane > 9   -> 需要当前 word + 下一个 word。
```

状态流：

```text
RR_IDLE
  等 right_rd_start，锁存 start_lane 和是否跨 word。

RR_READ0
  读第一个 160bit word。

RR_SAVE0
  保存还在第一个 word 内的像素。
  如果跨 word，进入 RR_READ1，否则 RR_DONE。

RR_READ1
  读下一个 160bit word。

RR_SAVE1
  保存跨到下一个 word 的剩余像素。

RR_DONE
  完成，一拍后回到 RR_IDLE。
```

### 4.4 writeback sequencer: wb_state

`wb_state` 是顶层 `ST_WRITEBACK` 阶段的调度器，本身不直接访问 SRAM，而是启动
`right_rd_state` 和 `line_wr_state` 两个子状态机。

写回顺序是：

1. 如果当前行会覆盖 7 行前的旧历史行，先启动 `right_rd_state` 保存旧行右 7 列。
2. 如果不是本行第一段，启动 `line_wr_state` 把上一段遗留的 `left7_reg` 写回。
3. 启动 `line_wr_state` 写当前 `cur16_reg`。
4. 如果当前段不是行尾，只写前 9 个像素，并把后 7 个更新到 `left7_reg`。
5. 如果当前段是行尾，写有效的全部当前段像素。

`ST_FLUSH_RIGHT` 阶段也复用这个 always 块：

- `flush_idx < 6` 时，启动 `right_rd_state` 从 line SRAM 读对应行的右 7 列。
- `flush_idx == 6` 时，最后一行的右 7 列直接从 `cur16_reg` 保存。

## 5. line SRAM 访问仲裁

line SRAM 只有一套读控制信号和一套写控制信号，所以代码用一个组合 mux 决定当前拍谁访问：

读优先级：

```text
line_wr_state == LW_READ
  -> line write engine 的 RMW 读旧 word

right_rd_state == RR_READ0/RR_READ1
  -> right7 保存逻辑读旧行右 7 列

win_state == WIN_SRAM_READ
  -> Lanczos window read 读历史行 tap
```

写来源：

```text
line_wr_state == LW_WRITE
  -> RMW 写回合并后的 160bit word

recv_linebuf_en
  -> frame top 前 7 行输入直接写 line SRAM
```

`linebuf_rd_bank_d` 是上一拍真正发出的读 bank。同步 SRAM 数据晚一拍回来，所以
`linebuf_rd_data_mux = linebuf_dout[linebuf_rd_bank_d]` 才能选到正确返回的 160bit word。

## 6. 每个 always 块功能索引

### line 123: 控制寄存器锁存

在 `ctrl_update_en` 时从 `fg2pp_ctrl` 锁存 block 尺寸、frame/tile 边界、block 起点、
block 类型等控制信息。

### line 165: 输入 160bit 拆成 16 个像素

组合逻辑，把 `data_in` 拆成 `pixel_in[0:15]`，每个像素 `PIXEL_W` bit。

### line 406: 单个 window tap 来源选择

组合逻辑，基于 `win_center_x/y` 和 `win_idx` 计算当前 tap 坐标，做 frame clip，转成
block local 坐标，再决定来源：

```text
left halo -> right_buffer
current segment -> cur16_reg
previous segment tail -> left7_reg
committed history -> line SRAM
otherwise invalid
```

同时计算 line SRAM 的 `bank/addr/lane` 和 direct pixel 输出。

### line 495: 8x8 window read FSM

时序逻辑。响应 `lanczos_window_req`，逐个读取 64 个 tap。寄存器来源当前拍保存；
line SRAM 来源走 `WIN_SRAM_READ/WIN_SRAM_SAVE` 两拍。完成后拉高
`lanczos_window_valid_r` 一拍。

### line 704: 顶层状态寄存器

时序逻辑。`cur_state <= nxt_state`。复位到 `ST_IDLE`，`buf_clr` 后进入 `ST_RECV`。

### line 718: 顶层下一状态组合逻辑

组合逻辑。根据 `latch_cur16_en`、`block_lanczos_done`、`writeback_done`、
`need_tail_flush`、`flush_right_done` 决定 `cur_state` 下一拍进入哪个阶段。

### line 767: 接收计数器

时序逻辑。维护：

- `seg16_x`: 当前行第几个 16 像素段。
- `row_cnt`: 当前 block 内第几行。
- `cycles_per_row`: 每行需要多少个 16 像素段。

只在 `data_fire` 时前进。

### line 792: Lanczos 启动和当前段快照

时序逻辑。在 `latch_cur16_en` 时：

- 把输入 16 像素锁存到 `cur16_reg`。
- 锁存当前段的 x/y、line SRAM bank、是否行首/行尾/最后一行等元数据。
- 计算 `lanczos_x_end/y_end`。
- 拉高 `lanczos_start_r` 一拍。

这些快照后续用于窗口读取和写回，避免 `row_cnt/seg16_x` 继续变化后影响当前段。

### line 834: line SRAM 读写访问 mux

组合逻辑。仲裁 line SRAM 本拍的读写控制信号。

读侧在 line write RMW、right7 read、window SRAM read 之间选择。写侧在 RMW 写回和
frame top 前 7 行直接写入之间选择。

### line 870: 读 bank 延迟一拍

时序逻辑。同步 SRAM 返回数据晚一拍，所以保存上一拍的 `linebuf_rd_bank` 到
`linebuf_rd_bank_d`，用于选择 `linebuf_dout` 的正确 bank。

### line 884: line_y_tag 维护

时序逻辑。记录每个 line SRAM bank 当前保存的真实全局 y 行。

- 前 7 行直接写 SRAM 时，更新对应 bank 的 tag。
- RMW 写回当前计算行时，更新写入 bank 的 tag。

### line 907: 通用 line SRAM RMW 写引擎

时序逻辑。处理 `line_wr_start` 请求，支持非 16 像素对齐、长度小于 16、跨 word 的
写请求。必要时先读旧 word，合并新像素，再写回。

### line 990: 旧行右 7 像素读取 FSM

时序逻辑。处理 `right_rd_start` 请求，从 line SRAM 读出从 `right_rd_x` 开始的连续
7 个像素，保存到 `right_buffer[right_rd_dst_row][0:6]`。如果跨 16 像素 word，会读
两次 SRAM。

### line 1055: 写回调度器和 flush right 控制

时序逻辑。顶层 `ST_WRITEBACK` 阶段调度：

- 保存即将被覆盖旧行的右 7 列。
- 写回 `left7_reg`。
- 写回 `cur16_reg`。
- 更新下一段需要的 `left7_reg`。

顶层 `ST_FLUSH_RIGHT` 阶段也在这里处理最后 7 行的 right_buffer flush。

## 7. 一次典型数据流

以 frame top block 为例：

```text
1. buf_clr 后进入 ST_RECV。

2. row_cnt = 0..6：
   data_fire 时 recv_linebuf_en=1，输入 16 像素直接写入 line SRAM。
   line_y_tag 同步更新。

3. row_cnt >= 7：
   每收到一个 16 像素段，latch_cur16_en=1。
   当前 16 像素进入 cur16_reg，当前段元数据锁存，lanczos_start 拉高。
   顶层进入 ST_LANCZOS_BUSY。

4. Lanczos 侧发 lanczos_window_req：
   win_state 逐 tap 读取 8x8 窗口。
   当前行当前段读 cur16_reg，上一段尾部读 left7_reg，历史行读 line SRAM，
   左侧 halo 读 right_buffer。

5. 外部拉高 block_lanczos_done：
   顶层进入 ST_WRITEBACK。

6. wb_state 调度写回：
   必要时先保存旧行右 7 列到 right_buffer。
   非行首先把 left7_reg 写回 line SRAM。
   再把 cur16_reg 写回 line SRAM。
   非行尾只写前 9 个像素，并把后 7 个保存到 left7_reg。

7. 如果不是 block 结束：
   writeback_done 后回到 ST_RECV，继续接收下一段。

8. 如果是 block 最后一行最后一段：
   writeback_done 后进入 ST_FLUSH_RIGHT。
   补存最后 7 行的 right_buffer，完成后进入 ST_IDLE。
```

## 8. 读代码时的抓手

如果想顺着代码读，建议顺序是：

1. 先看顶层状态机：`cur_state/nxt_state`。
2. 再看 `latch_cur16_en` 如何启动 Lanczos。
3. 看 `win_state` 如何响应 `lanczos_window_req` 读 64 个 tap。
4. 看 `line SRAM access mux` 如何把三类读请求接到 SRAM。
5. 看 `wb_state` 如何在 `ST_WRITEBACK` 调用 `right_rd_state` 和 `line_wr_state`。
6. 最后看 `ST_FLUSH_RIGHT` 如何补齐 block 最后 7 行的 right_buffer。
