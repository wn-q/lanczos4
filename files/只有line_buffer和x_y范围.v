module pp_downscale_block_buffer (
    clk,
    rst_n,

    block_start_x,
    block_pixel_width,
    block_pixel_height,
    frame_top_edge,

    buf_clr,
    data_vld,
    data_in,

    block_lanczos_done,
    block_lanczos_row_last,

    lanczos_start,
    lanczos_x_end,
    lanczos_y_end
);

// ---------------------------------------------------------------------------
// Minimal line_buffer-only version.
//
// Current scope:
//   1. Only frame_top_edge block is handled.
//   2. Row 0~6 are written directly into line_buffer.
//   3. Starting from row 7, each incoming 16-pixel segment is latched into
//      cur16_reg and lanczos_start is pulsed.
//   4. After Lanczos calculation finishes, block_lanczos_done writes safe
//      pixels back into line_buffer.
//   5. Non-frame-top block behavior is intentionally left blank for now.
// ---------------------------------------------------------------------------

parameter PIXEL_W          = 10;
parameter IN_PIX_PER_CYC  = 16;
parameter IMG_W            = 128;
parameter LINEBUF_ROWS     = 7;
parameter X_SAFE_COMMIT    = 9;
parameter X_KEEP_PIX       = 7;
parameter X_CALC_RIGHT_GAP = 4;

input clk;
input rst_n;

input [12:0]  block_start_x;
input [7:0]   block_pixel_width;
input [6:0]   block_pixel_height;
input         frame_top_edge;

input         buf_clr;
input         data_vld;
input [159:0] data_in;

// block_lanczos_done: current cur16_reg segment has finished calculation.
// block_lanczos_row_last: this done pulse belongs to the last segment of row.
input         block_lanczos_done;
input         block_lanczos_row_last;

output        lanczos_start;
output [7:0]  lanczos_x_end;
output [6:0]  lanczos_y_end;

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
reg [3:0] seg16_x;  //block内部
reg [6:0] row_cnt;
reg [3:0] cycles_per_row;

wire [7:0] cycles_per_row_calc;
wire       last_seg_in_row;
wire       last_row_in_block;
wire       block_recv_done;

assign cycles_per_row_calc = (block_pixel_width + 8'd15) >> 4;
assign last_seg_in_row     = (seg16_x == (cycles_per_row - 1'b1));
assign last_row_in_block   = (row_cnt == (block_pixel_height - 1'b1));
assign block_recv_done     = data_vld && last_seg_in_row && last_row_in_block;

// ---------------------------------------------------------------------------
// Buffers used by the current minimal flow.
// line_buffer stores 7 historical rows.
// cur16_reg stores the current 16-pixel segment being calculated.
// left7_reg stores the previous segment's x9~x15 until the next segment has
// consumed them.
// ---------------------------------------------------------------------------
reg [PIXEL_W-1:0] line_buffer [0:LINEBUF_ROWS-1][0:IMG_W-1];
reg [PIXEL_W-1:0] cur16_reg   [0:IN_PIX_PER_CYC-1];
reg [PIXEL_W-1:0] left7_reg   [0:X_KEEP_PIX-1];

reg        lanczos_start_r;
reg [7:0]  lanczos_x_end_r;
reg [6:0]  lanczos_y_end_r;

assign lanczos_start = lanczos_start_r;
assign lanczos_x_end = lanczos_x_end_r;
assign lanczos_y_end = lanczos_y_end_r;

wire [7:0]  in_block_x_base;
wire [12:0] in_global_x_base;
wire        frame_top_fill_linebuf;
wire        frame_top_calc_segment;
wire [7:0]  cur_segment_x_end;
wire [6:0]  cur_segment_y_end;

assign in_block_x_base  = {seg16_x, 4'b0000};  //seg16_x左移4位，相当于乘以16，得到一行当前16像素段的x起始位置
assign in_global_x_base = block_start_x + {5'd0, seg16_x, 4'b0000};

// frame_top block: row 0~6 only fill line_buffer.
assign frame_top_fill_linebuf = frame_top_edge && data_vld && (row_cnt < 7'd7);

// frame_top block: row 7 and later can start Lanczos calculation because
// line_buffer already has 7 historical rows.
assign frame_top_calc_segment = frame_top_edge && data_vld && (row_cnt >= 7'd7);

// For a normal 16-pixel segment, current data can support x_base+12.
// For the row's last segment, the valid right boundary is block_width-4.
assign cur_segment_x_end = last_seg_in_row ?                     //x能计算到的范围
                           (block_pixel_width - 3'd4) :
                           (in_block_x_base + 4'd12);

assign cur_segment_y_end = row_cnt - 3'd4;   //y能计算到的范围

// Metadata of the segment currently stored in cur16_reg.
reg [7:0]  calc_block_x_base;
reg [12:0] calc_global_x_base;
reg [2:0]  calc_linebuf_row;
reg        calc_first_seg_in_row;

integer i;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        seg16_x <= 4'd0;
        row_cnt <= 7'd0;
        cycles_per_row <= 4'd0;
        lanczos_start_r <= 1'b0;
        lanczos_x_end_r <= 8'd0;
        lanczos_y_end_r <= 7'd0;
        calc_block_x_base <= 8'd0;
        calc_global_x_base <= 13'd0;
        calc_linebuf_row <= 3'd0;
        calc_first_seg_in_row <= 1'b0;
    end else begin
        lanczos_start_r <= 1'b0;

        if (buf_clr) begin
            seg16_x <= 4'd0;
            row_cnt <= 7'd0;
            cycles_per_row <= cycles_per_row_calc[3:0];
        end else if (data_vld) begin
            if (frame_top_fill_linebuf) begin
                for (i = 0; i < IN_PIX_PER_CYC; i = i + 1) begin
                    if ((in_block_x_base + i) < block_pixel_width) begin
                        line_buffer[row_cnt[2:0]][in_global_x_base + i] <= pixel_in[i];
                    end
                end
            end

            if (frame_top_calc_segment) begin   //先存在cur16_reg里，然后触发计算
                for (i = 0; i < IN_PIX_PER_CYC; i = i + 1) begin
                    cur16_reg[i] <= pixel_in[i];
                end

                calc_block_x_base <= in_block_x_base;
                calc_global_x_base <= in_global_x_base;
                calc_linebuf_row <= row_cnt[2:0];
                calc_first_seg_in_row <= (seg16_x == 4'd0);   //每行的第一个16像素段

                lanczos_x_end_r <= cur_segment_x_end;  //x的计算范围
                lanczos_y_end_r <= cur_segment_y_end;  //y的计算范围
                lanczos_start_r <= 1'b1;   //可以开始计算
            end

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

        if (block_lanczos_done) begin   //每次计算完毕
            // From the second 16-pixel segment onward, the previous segment's
            // x9~x15 have now been consumed and can be written into line_buffer.
            if (!calc_first_seg_in_row) begin
                for (i = 0; i < X_KEEP_PIX; i = i + 1) begin
                    line_buffer[calc_linebuf_row][calc_global_x_base - 13'd7 + i] <= left7_reg[i];   //计算完毕，可以把7个像素写入到linebuff
                end
            end

            if (block_lanczos_row_last) begin          //如果是最后一行计算结束
                // Last segment of this row: all pixels in cur16_reg are safe
                // because no following segment needs them as left halo.
                for (i = 0; i < IN_PIX_PER_CYC; i = i + 1) begin
                    if ((calc_block_x_base + i) < block_pixel_width) begin
                        line_buffer[calc_linebuf_row][calc_global_x_base + i] <= cur16_reg[i];    //可以把16个像素都写入line_buffer
                    end
                end
            end else begin
                // Middle segment: only x0~x8 are safe. x9~x15 must be kept
                // until the next segment finishes calculation.
                for (i = 0; i < X_SAFE_COMMIT; i = i + 1) begin          //不是最后一个，每次只写前9个像素
                    if ((calc_block_x_base + i) < block_pixel_width) begin
                        line_buffer[calc_linebuf_row][calc_global_x_base + i] <= cur16_reg[i];
                    end
                end

                for (i = 0; i < X_KEEP_PIX; i = i + 1) begin  //后7个像素写到left7_reg里面
                    left7_reg[i] <= cur16_reg[X_SAFE_COMMIT + i];
                end
            end
        end
    end
end

endmodule
