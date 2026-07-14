wire[128+16:0] buffer_data_fifo_rdata0;
wire[128+16:0] buffer_data_fifo_rdata1;
wire[128+16:0] buffer_data_fifo_rdata2;
wire[128+16:0] buffer_data_fifo_rdata3;

reg[1:0]       read_line_cnt;

always @(posedge clk) begin
    if(!rst_n)
    qstate <= IDLE;
else if(!sw_dec_en)
qstate <= IDLE;
else
qstate <= dstate;
end

always @(*) begin
    case(qstate)
        IDLE: begin
            if(pp_interleave_ctrl_in_vld) begin
                dstate = READ_CONTROL;
            end else begin
                dstate = IDLE;
            end
        end
        READ_CONTROL: begin
            dstate = CALC_TRANSFER;
        end
        CALC_TRANSFER: begin
            dstate = WRITE_BUFFER;
        end
        WRITE_BUFFER: begin
            if(write_buffer_done) begin
                dstate = WRITE_FINISH;
            end else begin
                dstate = WRITE_BUFFER;
            end
        end
        WRITE_FINISH: begin
            dstate = CALC_BURST;
        end
        CALC_BURST: begin
            dstate = MAKE_BUS_REQUEST;
        end
        MAKE_BUS_REQUEST: begin
            if(pp_trans_send_aw_rdy) begin
                dstate = SEND_DATA;
            end else begin
                dstate = MAKE_BUS_REQUEST;
            end
        end
        SEND_DATA: begin
            if(pp_trans_send_w_vld && pp_trans_send_w_rdy && pp_trans_send_w_last && read_line_cnt == 2'd3 && block_done) begin
                dstate = IDLE;
            end else if(pp_trans_send_w_vld && pp_trans_send_w_rdy && pp_trans_send_w_last && read_line_cnt == 2'd3) begin
                dstate = CALC_TRANSFER;
            end else if(pp_trans_send_w_vld && pp_trans_send_w_rdy && pp_trans_send_w_last && read_line_cnt != 2'd3) begin
                dstate = MAKE_BUS_REQUEST;
            end else begin
                dstate = SEND_DATA;
            end
        end
        default: begin
            dstate = IDLE;
        end
    endcase
end

assign pp_interleave_ctrl_in_rdy = (qstate == IDLE);
assign pp_interleave_data_in_rdy = (qstate == WRITE_BUFFER) && !(need_left_data || need_left_data_1p || need_start_offset || write_buffer_done);

assign pp_trans_send_aw_vld = (qstate == MAKE_BUS_REQUEST);
assign pp_trans_send_aw_addr = true_address;
assign pp_trans_send_aw_bytes = {5'h0, final_data_amount};

assign pp_trans_send_w_vld = (qstate == SEND_DATA);
assign pp_trans_send_w_data = (read_line_cnt == 2'd0) ? buffer_data_fifo_rdata0[127:0]:
(read_line_cnt == 2'd1) ? buffer_data_fifo_rdata1[127:0]:
(read_line_cnt == 2'd2) ? buffer_data_fifo_rdata2[127:0]:
buffer_data_fifo_rdata3[127:0];

assign pp_trans_send_w_last = (read_line_cnt == 2'd0) ? buffer_data_fifo_rdata0[144]:
(read_line_cnt == 2'd1) ? buffer_data_fifo_rdata1[144]:
(read_line_cnt == 2'd2) ? buffer_data_fifo_rdata2[144]:
buffer_data_fifo_rdata3[144];

assign pp_trans_send_w_strb = (read_line_cnt == 2'd0) ? buffer_data_fifo_rdata0[143:128]:
(read_line_cnt == 2'd1) ? buffer_data_fifo_rdata1[143:128]:
(read_line_cnt == 2'd2) ? buffer_data_fifo_rdata2[143:128]:
buffer_data_fifo_rdata3[143:128];

assign ctrl_update_en = pp_interleave_ctrl_in_rdy && pp_interleave_ctrl_in_vld;
assign read_ctrl_en   = (qstate == READ_CONTROL);
assign calc_trans_en  = (qstate == CALC_TRANSFER);
assign calc_burst_en  = (qstate == CALC_BURST);

always @(posedge clk) begin
    if(!rst_n) begin
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
        block_start_y      <= 13'h0;
        block_start_x      <= 13'h0;
        block64_loc        <= 2'h0;
        block_type         <= 2'd0;
        picture_ready      <= 1'b0;
    end else if(ctrl_update_en) begin
        block_pixel_height <= pp_interleave_ctrl_in[6:0];
        block_pixel_width  <= pp_interleave_ctrl_in[14:7];
        frame_top_edge     <= pp_interleave_ctrl_in[15];
        frame_bottom_edge  <= pp_interleave_ctrl_in[16];
        frame_left_edge    <= pp_interleave_ctrl_in[17];
        frame_right_edge   <= pp_interleave_ctrl_in[18];
        tile_top_edge      <= pp_interleave_ctrl_in[19];
        tile_bottom_edge   <= pp_interleave_ctrl_in[20];
        tile_left_edge     <= pp_interleave_ctrl_in[21];
        tile_right_edge    <= pp_interleave_ctrl_in[22];
        block_start_y      <= pp_interleave_ctrl_in[35:23];
        block_start_x      <= pp_interleave_ctrl_in[48:36];
        block64_loc        <= pp_interleave_ctrl_in[50:49];
        block_type         <= pp_interleave_ctrl_in[52:51];
        picture_ready      <= pp_interleave_ctrl_in[53];
    end
end

/****************************/

assign block_finish = (qstate == SEND_DATA) &&
pp_trans_send_w_vld && pp_trans_send_w_rdy && pp_trans_send_w_last && (read_line_cnt == 2'd3) && block_done;

always @(posedge clk) begin
    if(!rst_n) begin
        block01_left_remain_bytes_lu <= 4'h0;
    end else if(block_finish && (block_type == 2'd0) && (!block64_loc[1]) && frame_right_edge) begin
        block01_left_remain_bytes_lu <= 4'h0;
    end else if(block_finish && (block_type == 2'd0) && (!block64_loc[1])) begin //update when block_finish
    block01_left_remain_bytes_lu <= block_line_bytes_total[3:0];
end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block23_left_remain_bytes_lu <= 4'h0;
    end else if(block_finish && (block_type == 2'd0) && block64_loc[1] && frame_right_edge) begin
        block23_left_remain_bytes_lu <= 4'h0;
    end else if(block_finish && (block_type == 2'd0) && block64_loc[1]) begin //update when block_finish
    block23_left_remain_bytes_lu <= block_line_bytes_total[3:0];
end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block01_left_remain_bytes_ch0 <= 4'h0;
    end else if(block_finish && (block_type == 2'd1) && (!block64_loc[1]) && frame_right_edge) begin
        block01_left_remain_bytes_ch0 <= 4'h0;
    end else if(block_finish && (block_type == 2'd1) && (!block64_loc[1])) begin //update when block_finish
    block01_left_remain_bytes_ch0 <= block_line_bytes_total[3:0];
end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block23_left_remain_bytes_ch0 <= 4'h0;
    end else if(block_finish && (block_type == 2'd1) && block64_loc[1] && frame_right_edge) begin
        block23_left_remain_bytes_ch0 <= 4'h0;
    end else if(block_finish && (block_type == 2'd1) && block64_loc[1]) begin //update when block_finish
    block23_left_remain_bytes_ch0 <= block_line_bytes_total[3:0];
end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block01_left_remain_bytes_ch1 <= 4'h0;
    end else if(block_finish && (block_type == 2'd2) && (!block64_loc[1]) && frame_right_edge) begin
        block01_left_remain_bytes_ch1 <= 4'h0;
    end else if(block_finish && (block_type == 2'd2) && (!block64_loc[1])) begin //update when block_finish
    block01_left_remain_bytes_ch1 <= block_line_bytes_total[3:0];
end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block23_left_remain_bytes_ch1 <= 4'h0;
    end else if(block_finish && (block_type == 2'd2) && block64_loc[1] && frame_right_edge) begin
        block23_left_remain_bytes_ch1 <= 4'h0;
    end else if(block_finish && (block_type == 2'd2) && block64_loc[1]) begin //update when block_finish
    block23_left_remain_bytes_ch1 <= block_line_bytes_total[3:0];
end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block_left_edge_remain_bytes_lu <= 4'h0;
    end else if(read_ctrl_en && (block_type == 2'd0) && tile_top_edge && tile_left_edge) begin
        block_left_edge_remain_bytes_lu <= block01_left_remain_bytes_lu;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block_left_edge_remain_bytes_ch0 <= 4'h0;
    end else if(read_ctrl_en && (block_type == 2'd1) && tile_top_edge && tile_left_edge) begin
        block_left_edge_remain_bytes_ch0 <= block01_left_remain_bytes_ch0;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block_left_edge_remain_bytes_ch1 <= 4'h0;
    end else if(read_ctrl_en && (block_type == 2'd2) && tile_top_edge && tile_left_edge) begin
        block_left_edge_remain_bytes_ch1 <= block01_left_remain_bytes_ch1;
    end
end

assign block_start_x_div4 = block_start_x[12:2];




assign block_pixel_width_div4 = block_pixel_width[7:2];

assign block_line_bytes_8bit = block_pixel_width;
assign block_line_bytes_10bit = block_pixel_width + block_pixel_width_div4;

assign block_line_bytes = (sw_bitdepth == 2'b0) ? block_line_bytes_8bit : block_line_bytes_10bit;
assign block_left_remain_bytes = (block_type == 2'd0) ? (block64_loc[1] ? block23_left_remain_bytes_lu : block01_left_remain_bytes_lu) :
                                 (block_type == 2'd1) ? (block64_loc[1] ? block23_left_remain_bytes_ch0 : block01_left_remain_bytes_ch0) :
                                (block64_loc[1] ? block23_left_remain_bytes_ch1 : block01_left_remain_bytes_ch1);

assign block_left_edge_remain_bytes = (block_type == 2'd0) ? block_left_edge_remain_bytes_lu :
                                      (block_type == 2'd1) ? block_left_edge_remain_bytes_ch0 :
                                                             block_left_edge_remain_bytes_ch1 ;


assign block_line_bytes_total = (tile_left_edge ? block_left_edge_remain_bytes : block_left_remain_bytes) + block_line_bytes;

assign block_line_bytes_trans = (tile_left_edge && tile_right_edge) ? block_line_bytes_total - block_start_x_use[3:0] :
tile_right_edge  ? block_line_bytes_total :
tile_left_edge   ? {block_line_bytes_total[7:4], 4'h0} - block_start_x_use[3:0] : {block_line_bytes_total[7:4], 4'h0};
assign block_line_16bytes_calc = tile_right_edge ? (block_line_bytes_total[7:4] + (|block_line_bytes_total[3:0])) :block_line_bytes_total[7:4];


assign data_load_cnt_max = block_pixel_width_div4 - 1'd1;

assign data_load_en_last = data_load_en && (data_load_cnt == data_load_cnt_max);

assign data_load_en = pp_interleave_data_in_vld && pp_interleave_data_in_rdy;
assign data_load_offset_step = (sw_bitdepth == 2'b0) ? 3'd4 : 3'd5;
assign data_load_offset_nxt = data_load_offset[3:0] + data_load_offset_step;_remain_bytes = (block_type == 2'd0) ? block_left_edge_remain_bytes_lu :
(block_type == 2'd1) ? block_left_edge_remain_bytes_ch0 :
block_left_edge_remain_bytes_ch1 ;





//
always @(posedge clk) begin
    if(!rst_n) begin
        need_left_data <= 1'b0;
    end else if(calc_trans_en && !tile_left_edge && (block_left_remain_bytes != 4'h0)) begin
        need_left_data <= 1'b1;
    end else if(left_data_sram_rd_done) begin
        need_left_data <= 1'b0;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        need_left_data_1p <= 1'b0;
    end else begin
        need_left_data_1p <= need_left_data;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        need_start_offset <= 1'b0;
    end else if(calc_trans_en && tile_left_edge && (block_start_x_use[3:0] != 4'h0)) begin
        need_start_offset <= 1'b1;
    end else begin
        need_start_offset <= 1'b0;
    end
end

assign left_data_sram_rd_en = need_left_data;

always @(posedge clk) begin
    if(!rst_n) begin
        left_data_sram_rd_cnt <= 2'b0;
    end else if(left_data_sram_rd_en && left_data_sram_rd_cnt == 2'd3) begin
        left_data_sram_rd_cnt <= 2'b0;
    end else if(left_data_sram_rd_en) begin
        left_data_sram_rd_cnt <= left_data_sram_rd_cnt + 1'b1;
    end
end

assign left_data_sram_rd_done = left_data_sram_rd_en && (left_data_sram_rd_cnt == 2'd3);

assign left_data_sram_lu_ren  = left_data_sram_rd_en && (block_type == 2'd0);
assign left_data_sram_ch0_ren = left_data_sram_rd_en && (block_type == 2'd1);
assign left_data_sram_ch1_ren = left_data_sram_rd_en && (block_type == 2'd2);

assign left_data_sram_raddr = ((block_type == 0) ?
{block64_loc[1], 6'h0} : {block64_loc[1], 5'h0}) + {block_line_cnt, 2'h0} + left_data_sram_rd_cnt; //sram读的地址

assign left_data_sram_lu_raddr  = left_data_sram_raddr;
assign left_data_sram_ch0_raddr = left_data_sram_raddr[6:0];
assign left_data_sram_ch1_raddr = left_data_sram_raddr[6:0];

assign left_data_sram_lu_rd0 = left_data_sram_lu_ren && (left_data_sram_rd_cnt == 2'd0); //读sram的使能
assign left_data_sram_lu_rd1 = left_data_sram_lu_ren && (left_data_sram_rd_cnt == 2'd1);
assign left_data_sram_lu_rd2 = left_data_sram_lu_ren && (left_data_sram_rd_cnt == 2'd2);
assign left_data_sram_lu_rd3 = left_data_sram_lu_ren && (left_data_sram_rd_cnt == 2'd3);

assign left_data_sram_ch0_rd0 = left_data_sram_ch0_ren && (left_data_sram_rd_cnt == 2'd0);
assign left_data_sram_ch0_rd1 = left_data_sram_ch0_ren && (left_data_sram_rd_cnt == 2'd1);
assign left_data_sram_ch0_rd2 = left_data_sram_ch0_ren && (left_data_sram_rd_cnt == 2'd2);
assign left_data_sram_ch0_rd3 = left_data_sram_ch0_ren && (left_data_sram_rd_cnt == 2'd3);

assign left_data_sram_ch1_rd0 = left_data_sram_ch1_ren && (left_data_sram_rd_cnt == 2'd0);
assign left_data_sram_ch1_rd1 = left_data_sram_ch1_ren && (left_data_sram_rd_cnt == 2'd1);
assign left_data_sram_ch1_rd2 = left_data_sram_ch1_ren && (left_data_sram_rd_cnt == 2'd2);
assign left_data_sram_ch1_rd3 = left_data_sram_ch1_ren && (left_data_sram_rd_cnt == 2'd3);

always @(posedge clk) begin
    if(!rst_n) begin
        left_data_sram_lu_rd0_1p <= 1'b0;
        left_data_sram_lu_rd1_1p <= 1'b0;
        left_data_sram_lu_rd2_1p <= 1'b0;
        left_data_sram_lu_rd3_1p <= 1'b0;
        left_data_sram_ch0_rd0_1p <= 1'b0;
        left_data_sram_ch0_rd1_1p <= 1'b0;
        left_data_sram_ch0_rd2_1p <= 1'b0;
        left_data_sram_ch0_rd3_1p <= 1'b0;
        left_data_sram_ch1_rd0_1p <= 1'b0;
        left_data_sram_ch1_rd1_1p <= 1'b0;
        left_data_sram_ch1_rd2_1p <= 1'b0;
        left_data_sram_ch1_rd3_1p <= 1'b0;
    end else begin
        left_data_sram_lu_rd0_1p <= left_data_sram_lu_rd0;  //读出的数据寄存一下，后面可能会用到
        left_data_sram_lu_rd1_1p <= left_data_sram_lu_rd1;
        left_data_sram_lu_rd2_1p <= left_data_sram_lu_rd2;
        left_data_sram_lu_rd3_1p <= left_data_sram_lu_rd3;
        left_data_sram_ch0_rd0_1p <= left_data_sram_ch0_rd0;
        left_data_sram_ch0_rd1_1p <= left_data_sram_ch0_rd1;
        left_data_sram_ch0_rd2_1p <= left_data_sram_ch0_rd2;
        left_data_sram_ch0_rd3_1p <= left_data_sram_ch0_rd3;
        left_data_sram_ch1_rd0_1p <= left_data_sram_ch1_rd0;
        left_data_sram_ch1_rd1_1p <= left_data_sram_ch1_rd1;
        left_data_sram_ch1_rd2_1p <= left_data_sram_ch1_rd2;
        left_data_sram_ch1_rd3_1p <= left_data_sram_ch1_rd3;
    end
end


always @(posedge clk) begin
    if(!rst_n) begin
        data_load_cnt <= 6'h0;
    end else if(write_buffer_done) begin
        data_load_cnt <= 6'h0;
    end else if(data_load_en) begin
        data_load_cnt <= data_load_cnt + 1'd1;   //加载一次数据，计数器加1
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        write_buffer_done <= 1'b0;
    end else if(data_load_en_last) begin
        write_buffer_done <= 1'b1;      //当数据加载到最后一次时，写buffer完成
    end else begin
        write_buffer_done <= 1'b0;
    end
end

always @(posedge clk) begin   //
    if(!rst_n) begin
        data_load_offset <= 5'h0;
    end else if(calc_trans_en) begin
        data_load_offset <= 5'h0;
    end else if(need_left_data) begin
        data_load_offset <= {1'b0, block_left_remain_bytes};  //需要加载左边剩余的数据时，偏移量从剩余字节数开始
    end else if(need_start_offset) begin
        data_load_offset <= {1'b0, block_start_x_use[3:0]}; //需要加载起始偏移量时，偏移量从块起始位置的低4位开始
    end else if(data_load_en) begin
        data_load_offset <= data_load_offset_nxt;           //正常加载数据时，偏移量按照步长递增
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wr <= 1'b0;
    end else if((data_load_en && data_load_offset_nxt >= 5'd16) ||  //要不要把16B数据写入buffer的条件：1.正在加载数据，并且下一个偏移量超过16；2.写buffer完成，并且当前偏移量还有剩余，并且是右边界
    (write_buffer_done && (|data_load_offset[3:0]) && tile_right_edge)) begin
        buffer_wr <= 1'b1;
    end else begin
        buffer_wr <= 1'b0;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        left_data_sram_wr_en <= 1'b0;
    end else if(write_buffer_done && (|data_load_offset[3:0]) && !tile_right_edge) begin  //当前16B没写满的，写进sram存储起来，不是tile的右边界
        left_data_sram_wr_en <= 1'b1;
    end else if(left_data_sram_wr_en && left_data_sram_wr_cnt == 2'd3) begin
        left_data_sram_wr_en <= 1'b0;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        left_data_sram_wr_cnt <= 2'h0;
    end else if(left_data_sram_wr_en && left_data_sram_wr_cnt == 2'd3) begin  //写三拍数据到sram后，写入完成，计数器清零
        left_data_sram_wr_cnt <= 2'h0;
    end else if(left_data_sram_wr_en) begin
        left_data_sram_wr_cnt <= left_data_sram_wr_cnt + 1'b1;
    end
end


assign left_data_sram_lu_wen  = left_data_sram_wr_en && (block_type == 2'd0);   //YUV的写使能
assign left_data_sram_ch0_wen = left_data_sram_wr_en && (block_type == 2'd1);
assign left_data_sram_ch1_wen = left_data_sram_wr_en && (block_type == 2'd2);

assign left_data_sram_waddr = ((block_type == 0) ?
{block64_loc[1], 6'h0} : {block64_loc[1], 5'h0}) + {block_line_cnt, 2'h0} + left_data_sram_wr_cnt;  //写的地址计算方式

assign left_data_sram_lu_waddr  = left_data_sram_waddr;       //yuv写的地址
assign left_data_sram_ch0_waddr = left_data_sram_waddr[6:0];
assign left_data_sram_ch1_waddr = left_data_sram_waddr[6:0];

assign left_data_sram_wdata = (left_data_sram_wr_cnt == 2'd0) ? buffer_wdata0_buf[119:0] :  //sram要写的数据，位宽是120bit的，因为可能不满16B，最大时15B
(left_data_sram_wr_cnt == 2'd1) ? buffer_wdata1_buf[119:0] :
(left_data_sram_wr_cnt == 2'd2) ? buffer_wdata2_buf[119:0] :
buffer_wdata3_buf[119:0] ;
assign left_data_sram_lu_wdata  = left_data_sram_wdata; //yuv的写数据
assign left_data_sram_ch0_wdata = left_data_sram_wdata;
assign left_data_sram_ch1_wdata = left_data_sram_wdata;

assign buffer_wr_first = buffer_remain_data == block_line_bytes_trans;//remian_data表示当前还剩多少个数据没写出去，当剩余数据等于本行要写的数据时，说明这是本行第一次写数据
assign buffer_wr_last = buffer_remain_data <= 6'd16; //当剩余数据小于等于16时，说明这是本行最后一次写数据了

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_remain_data <= 8'h0;
    end else if(calc_trans_en) begin
        buffer_remain_data <= block_line_bytes_trans;
    end else if(buffer_wr && buffer_wr_last) begin
        buffer_remain_data <= 8'h0;
    end else if(buffer_wr && buffer_wr_first && tile_left_edge) begin    //当第一次写数据，并且是左边界时，剩余数据要减去16，还要加上起始偏移量，因为起始偏移量表示本行前面有多少数据不需要写入
        buffer_remain_data <= buffer_remain_data - 5'd16 + block_start_x_use[3:0];
    end else if(buffer_wr) begin
        buffer_remain_data <= buffer_remain_data - 5'd16;
    end
end
//remain_data是字节为单位
always @(*) begin                   //三种情况，第一拍，前面有上一个剩余的数据，屏蔽前面的数据；最后一拍，不满16B;其他情况，全有效
    if(buffer_wr_last) begin
        case(buffer_remain_data[3:0])
            4'd1:  data_strb = 16'b0000_0000_0000_0001;
            4'd2:  data_strb = 16'b0000_0000_0000_0011;
            4'd3:  data_strb = 16'b0000_0000_0000_0111;
            4'd4:  data_strb = 16'b0000_0000_0000_1111;
            4'd5:  data_strb = 16'b0000_0000_0001_1111;
            4'd6:  data_strb = 16'b0000_0000_0011_1111;
            4'd7:  data_strb = 16'b0000_0000_0111_1111;
            4'd8:  data_strb = 16'b0000_0000_1111_1111;
            4'd9:  data_strb = 16'b0000_0001_1111_1111;
            4'd10: data_strb = 16'b0000_0011_1111_1111;
            4'd11: data_strb = 16'b0000_0111_1111_1111;
            4'd12: data_strb = 16'b0000_1111_1111_1111;
            4'd13: data_strb = 16'b0001_1111_1111_1111;
            4'd14: data_strb = 16'b0011_1111_1111_1111;
            4'd15: data_strb = 16'b0111_1111_1111_1111;
            default: data_strb = 16'b1111_1111_1111_1111;
        endcase
    end else if(buffer_wr_first && tile_left_edge) begin
        case(block_start_x_use[3:0])
            4'd1:  data_strb = 16'b1111_1111_1111_1110;
            4'd2:  data_strb = 16'b1111_1111_1111_1100;
            4'd3:  data_strb = 16'b1111_1111_1111_1000;
            4'd4:  data_strb = 16'b1111_1111_1111_0000;
            4'd5:  data_strb = 16'b1111_1111_1110_0000;
            4'd6:  data_strb = 16'b1111_1111_1100_0000;
            4'd7:  data_strb = 16'b1111_1111_1000_0000;
            4'd8:  data_strb = 16'b1111_1111_0000_0000;
            4'd9:  data_strb = 16'b1111_1110_0000_0000;
            4'd10: data_strb = 16'b1111_1100_0000_0000;
            4'd11: data_strb = 16'b1111_1000_0000_0000;
            4'd12: data_strb = 16'b1111_0000_0000_0000;
            4'd13: data_strb = 16'b1110_0000_0000_0000;
            4'd14: data_strb = 16'b1100_0000_0000_0000;
            4'd15: data_strb = 16'b1000_0000_0000_0000;
            default: data_strb = 16'b1111_1111_1111_1111;
        endcase
    end else begin
        data_strb = 16'b1111_1111_1111_1111;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_waddr <= 4'b0;
    end else if(calc_trans_en) begin
        buffer_waddr <= 4'b0;
    end else if(buffer_wr) begin
        buffer_waddr <= buffer_waddr + 4'd1;//👉 现在要往buffer的第几个位置写数据
    end
end

//assign sram0_wr = buffer_wr;
//assign sram1_wr = buffer_wr;
//assign sram2_wr = buffer_wr;
//assign sram3_wr = buffer_wr;

//assign sram0_waddr = buffer_waddr;
//assign sram1_waddr = buffer_waddr;
//assign sram2_waddr = buffer_waddr;
//assign sram3_waddr = buffer_waddr;
//拆分输入数据，8bit时每32bit数据前面补8bit 0，10bit时直接用40bit数据
assign buffer_wdata0_temp = (sw_bitdepth == 2'd0) ?
{8'h0, pp_interleave_data_in[37:30], pp_interleave_data_in[27:20], pp_interleave_data_in[17:10], pp_interleave_data_in[7:0]} : pp_interleave_data_in[39:0];
assign buffer_wdata1_temp = (sw_bitdepth == 2'd0) ?
{8'h0, pp_interleave_data_in[77:70], pp_interleave_data_in[67:60], pp_interleave_data_in[57:50], pp_interleave_data_in[47:40]} : pp_interleave_data_in[79:40];
assign buffer_wdata2_temp = (sw_bitdepth == 2'd0) ?
{8'h0, pp_interleave_data_in[117:110], pp_interleave_data_in[107:100], pp_interleave_data_in[97:90], pp_interleave_data_in[87:80]} : pp_interleave_data_in[119:80];
assign buffer_wdata3_temp = (sw_bitdepth == 2'd0) ?
{8'h0, pp_interleave_data_in[157:150], pp_interleave_data_in[147:140], pp_interleave_data_in[137:130], pp_interleave_data_in[127:120]} : pp_interleave_data_in[159:120];

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wdata0_buf <= 120'h0;   //120bit位宽 用来拼接缓存
    end else if(calc_trans_en) begin
        buffer_wdata0_buf <= 120'h0;
    end else if(left_data_sram_lu_rd0_1p) begin   //读取sram中上一个block中的剩余数据  yuv的读取
        buffer_wdata0_buf <= left_data_sram_lu_rdata[119:0];
    end else if(left_data_sram_ch0_rd0_1p) begin
        buffer_wdata0_buf <= left_data_sram_ch0_rdata[119:0];
    end else if(left_data_sram_ch1_rd0_1p) begin
        buffer_wdata0_buf <= left_data_sram_ch1_rdata[119:0];
    end else if(data_load_en && sw_bitdepth == 2'd0) begin   //加载数据并且位宽为8bit时，已经占了多少个byte,8bit每次来4byte
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata0_buf <= {88'h0, buffer_wdata0_temp[31:0]};
            4'd4:  buffer_wdata0_buf <= {56'h0, buffer_wdata0_temp[31:0], buffer_wdata0_buf[31:0]};
            4'd8:  buffer_wdata0_buf <= {24'h0, buffer_wdata0_temp[31:0], buffer_wdata0_buf[63:0]};
            4'd12: buffer_wdata0_buf <= 120'h0;
            default: buffer_wdata0_buf <= buffer_wdata0_buf;
        endcase
    end else if(data_load_en && sw_bitdepth == 2'd1) begin   //10bit每次来4个像素5byte
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata0_buf <= {80'h0, buffer_wdata0_temp[39:0]};
            4'd1:  buffer_wdata0_buf <= {72'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[7:0]};
            4'd2:  buffer_wdata0_buf <= {64'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[15:0]};
            4'd3:  buffer_wdata0_buf <= {56'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[23:0]};
            4'd4:  buffer_wdata0_buf <= {48'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[31:0]};
            4'd5:  buffer_wdata0_buf <= {40'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[39:0]};
            4'd6:  buffer_wdata0_buf <= {32'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[47:0]};
            4'd7:  buffer_wdata0_buf <= {24'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[55:0]};
            4'd8:  buffer_wdata0_buf <= {16'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[63:0]};
            4'd9:  buffer_wdata0_buf <= { 8'h0, buffer_wdata0_temp[39:0], buffer_wdata0_buf[71:0]};
            4'd10: buffer_wdata0_buf <= {       buffer_wdata0_temp[39:0], buffer_wdata0_buf[79:0]};
            4'd11: buffer_wdata0_buf <= {       buffer_wdata0_temp[31:0], buffer_wdata0_buf[87:0]};
            4'd12: buffer_wdata0_buf <= {112'h0, buffer_wdata0_temp[39:32]};
            4'd13: buffer_wdata0_buf <= {104'h0, buffer_wdata0_temp[39:24]};
            4'd14: buffer_wdata0_buf <= { 96'h0, buffer_wdata0_temp[39:16]};
            4'd15: buffer_wdata0_buf <= { 88'h0, buffer_wdata0_temp[39:8]};
            default: buffer_wdata0_buf <= buffer_wdata0_buf;
        endcase
    end
end

always @(posedge clk) begin  //只有凑满16byte的这拍，才生成buffer_wdata0
    if(!rst_n) begin
        buffer_wdata0 <= 128'h0;          //16byte,可以发给DDR,判断什么时候凑满16BYtes
    end else if(calc_trans_en) begin
        buffer_wdata0 <= 128'h0;
    end else if(write_buffer_done && (|data_load_offset[3:0]) && tile_right_edge) begin //tile的右边界 全部写出去
        buffer_wdata0 <= {8'h0, buffer_wdata0_buf};
    end else if(data_load_en && sw_bitdepth == 2'd0 && (data_load_offset[3:0] == 4'd12)) begin //新的数据来了，加上旧的数据刚好凑满16bytes
        buffer_wdata0 <= {buffer_wdata0_temp[31:0], buffer_wdata0_buf[95:0]};
    end else if(data_load_en && sw_bitdepth == 2'd1) begin   //10bit,
        case(data_load_offset[3:0])
            4'd11: buffer_wdata0 <= {buffer_wdata0_temp[39:0], buffer_wdata0_buf[87:0]};  //跟前面对应
            4'd12: buffer_wdata0 <= {buffer_wdata0_temp[31:0], buffer_wdata0_buf[95:0]};
            4'd13: buffer_wdata0 <= {buffer_wdata0_temp[23:0], buffer_wdata0_buf[103:0]};
            4'd14: buffer_wdata0 <= {buffer_wdata0_temp[15:0], buffer_wdata0_buf[111:0]};
            4'd15: buffer_wdata0 <= {buffer_wdata0_temp[7:0],  buffer_wdata0_buf[119:0]};
            default: buffer_wdata0 <= buffer_wdata0;
        endcase
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wdata1_buf <= 120'h0;
    end else if(calc_trans_en) begin
        buffer_wdata1_buf <= 120'h0;
    end else if(left_data_sram_lu_rd1_1p) begin
        buffer_wdata1_buf <= left_data_sram_lu_rdata[119:0];
    end else if(left_data_sram_ch0_rd1_1p) begin
        buffer_wdata1_buf <= left_data_sram_ch0_rdata[119:0];
    end else if(left_data_sram_ch1_rd1_1p) begin
        buffer_wdata1_buf <= left_data_sram_ch1_rdata[119:0];
    end else if(data_load_en && sw_bitdepth == 2'd0) begin
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata1_buf <= {88'h0, buffer_wdata1_temp[31:0]};
            4'd4:  buffer_wdata1_buf <= {56'h0, buffer_wdata1_temp[31:0], buffer_wdata1_buf[31:0]};
            4'd8:  buffer_wdata1_buf <= {24'h0, buffer_wdata1_temp[31:0], buffer_wdata1_buf[63:0]};
            4'd12: buffer_wdata1_buf <= 120'h0;
            default: buffer_wdata1_buf <= buffer_wdata1_buf;
        endcase
    end else if(data_load_en && sw_bitdepth == 2'd1) begin
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata1_buf <= {80'h0, buffer_wdata1_temp[39:0]};
            4'd1:  buffer_wdata1_buf <= {72'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[7:0]};
            4'd2:  buffer_wdata1_buf <= {64'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[15:0]};
            4'd3:  buffer_wdata1_buf <= {56'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[23:0]};
            4'd4:  buffer_wdata1_buf <= {48'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[31:0]};
            4'd5:  buffer_wdata1_buf <= {40'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[39:0]};
            4'd6:  buffer_wdata1_buf <= {32'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[47:0]};
            4'd7:  buffer_wdata1_buf <= {24'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[55:0]};
            4'd8:  buffer_wdata1_buf <= {16'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[63:0]};
            4'd9:  buffer_wdata1_buf <= { 8'h0, buffer_wdata1_temp[39:0], buffer_wdata1_buf[71:0]};
            4'd10: buffer_wdata1_buf <= {       buffer_wdata1_temp[39:0], buffer_wdata1_buf[79:0]};
            4'd11: buffer_wdata1_buf <= {       buffer_wdata1_temp[31:0], buffer_wdata1_buf[87:0]};
            4'd12: buffer_wdata1_buf <= {112'h0, buffer_wdata1_temp[39:32]};
            4'd13: buffer_wdata1_buf <= {104'h0, buffer_wdata1_temp[39:24]};
            4'd14: buffer_wdata1_buf <= { 96'h0, buffer_wdata1_temp[39:16]};
            4'd15: buffer_wdata1_buf <= { 88'h0, buffer_wdata1_temp[39:8]};
            default: buffer_wdata1_buf <= buffer_wdata1_buf;
        endcase
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wdata1 <= 128'h0;
    end else if(calc_trans_en) begin
        buffer_wdata1 <= 128'h0;
    end else if(write_buffer_done && (|data_load_offset[3:0]) && tile_right_edge) begin
        buffer_wdata1 <= {8'h0, buffer_wdata1_buf};
    end else if(data_load_en && sw_bitdepth == 2'd0 && (data_load_offset[3:0] == 4'd12)) begin
        buffer_wdata1 <= {buffer_wdata1_temp[31:0], buffer_wdata1_buf[95:0]};
    end else if(data_load_en && sw_bitdepth == 2'd1) begin
        case(data_load_offset[3:0])
            4'd11: buffer_wdata1 <= {buffer_wdata1_temp[39:0], buffer_wdata1_buf[87:0]};
            4'd12: buffer_wdata1 <= {buffer_wdata1_temp[31:0], buffer_wdata1_buf[95:0]};
            4'd13: buffer_wdata1 <= {buffer_wdata1_temp[23:0], buffer_wdata1_buf[103:0]};
            4'd14: buffer_wdata1 <= {buffer_wdata1_temp[15:0], buffer_wdata1_buf[111:0]};
            4'd15: buffer_wdata1 <= {buffer_wdata1_temp[7:0],  buffer_wdata1_buf[119:0]};
            default: buffer_wdata1 <= buffer_wdata1;
        endcase
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wdata2_buf <= 120'h0;
    end else if(calc_trans_en) begin
        buffer_wdata2_buf <= 120'h0;
    end else if(left_data_sram_lu_rd2_1p) begin
        buffer_wdata2_buf <= left_data_sram_lu_rdata[119:0];
    end else if(left_data_sram_ch0_rd2_1p) begin
        buffer_wdata2_buf <= left_data_sram_ch0_rdata[119:0];
    end else if(left_data_sram_ch1_rd2_1p) begin
        buffer_wdata2_buf <= left_data_sram_ch1_rdata[119:0];
    end else if(data_load_en && sw_bitdepth == 2'd0) begin
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata2_buf <= {88'h0, buffer_wdata2_temp[31:0]};
            4'd4:  buffer_wdata2_buf <= {56'h0, buffer_wdata2_temp[31:0], buffer_wdata2_buf[31:0]};
            4'd8:  buffer_wdata2_buf <= {24'h0, buffer_wdata2_temp[31:0], buffer_wdata2_buf[63:0]};
            4'd12: buffer_wdata2_buf <= 120'h0;
            default: buffer_wdata2_buf <= buffer_wdata2_buf;
        endcase
    end else if(data_load_en && sw_bitdepth == 2'd1) begin
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata2_buf <= {80'h0, buffer_wdata2_temp[39:0]};
            4'd1:  buffer_wdata2_buf <= {72'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[7:0]};
            4'd2:  buffer_wdata2_buf <= {64'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[15:0]};
            4'd3:  buffer_wdata2_buf <= {56'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[23:0]};
            4'd4:  buffer_wdata2_buf <= {48'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[31:0]};
            4'd5:  buffer_wdata2_buf <= {40'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[39:0]};
            4'd6:  buffer_wdata2_buf <= {32'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[47:0]};
            4'd7:  buffer_wdata2_buf <= {24'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[55:0]};
            4'd8:  buffer_wdata2_buf <= {16'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[63:0]};
            4'd9:  buffer_wdata2_buf <= { 8'h0, buffer_wdata2_temp[39:0], buffer_wdata2_buf[71:0]};
            4'd10: buffer_wdata2_buf <= {       buffer_wdata2_temp[39:0], buffer_wdata2_buf[79:0]};
            4'd11: buffer_wdata2_buf <= {       buffer_wdata2_temp[31:0], buffer_wdata2_buf[87:0]};
            4'd12: buffer_wdata2_buf <= {112'h0, buffer_wdata2_temp[39:32]};
            4'd13: buffer_wdata2_buf <= {104'h0, buffer_wdata2_temp[39:24]};
            4'd14: buffer_wdata2_buf <= { 96'h0, buffer_wdata2_temp[39:16]};
            4'd15: buffer_wdata2_buf <= { 88'h0, buffer_wdata2_temp[39:8]};
            default: buffer_wdata2_buf <= buffer_wdata2_buf;
        endcase
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wdata2 <= 128'h0;
    end else if(calc_trans_en) begin
        buffer_wdata2 <= 128'h0;
    end else if(write_buffer_done && (|data_load_offset[3:0]) && tile_right_edge) begin
        buffer_wdata2 <= {8'h0, buffer_wdata2_buf};
    end else if(data_load_en && sw_bitdepth == 2'd0 && (data_load_offset[3:0] == 4'd12)) begin
        buffer_wdata2 <= {buffer_wdata2_temp[31:0], buffer_wdata2_buf[95:0]};
    end else if(data_load_en && sw_bitdepth == 2'd1) begin
        case(data_load_offset[3:0])
            4'd11: buffer_wdata2 <= {buffer_wdata2_temp[39:0], buffer_wdata2_buf[87:0]};
            4'd12: buffer_wdata2 <= {buffer_wdata2_temp[31:0], buffer_wdata2_buf[95:0]};
            4'd13: buffer_wdata2 <= {buffer_wdata2_temp[23:0], buffer_wdata2_buf[103:0]};
            4'd14: buffer_wdata2 <= {buffer_wdata2_temp[15:0], buffer_wdata2_buf[111:0]};
            4'd15: buffer_wdata2 <= {buffer_wdata2_temp[7:0],  buffer_wdata2_buf[119:0]};
            default: buffer_wdata2 <= buffer_wdata2;
        endcase
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wdata3_buf <= 120'h0;
    end else if(calc_trans_en) begin
        buffer_wdata3_buf <= 120'h0;
    end else if(left_data_sram_lu_rd3_1p) begin
        buffer_wdata3_buf <= left_data_sram_lu_rdata[119:0];
    end else if(left_data_sram_ch0_rd3_1p) begin
        buffer_wdata3_buf <= left_data_sram_ch0_rdata[119:0];
    end else if(left_data_sram_ch1_rd3_1p) begin
        buffer_wdata3_buf <= left_data_sram_ch1_rdata[119:0];
    end else if(data_load_en && sw_bitdepth == 2'd0) begin
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata3_buf <= {88'h0, buffer_wdata3_temp[31:0]};
            4'd4:  buffer_wdata3_buf <= {56'h0, buffer_wdata3_temp[31:0], buffer_wdata3_buf[31:0]};
            4'd8:  buffer_wdata3_buf <= {24'h0, buffer_wdata3_temp[31:0], buffer_wdata3_buf[63:0]};
            4'd12: buffer_wdata3_buf <= 120'h0;
            default: buffer_wdata3_buf <= buffer_wdata3_buf;
        endcase
    end else if(data_load_en && sw_bitdepth == 2'd1) begin
        case(data_load_offset[3:0])
            4'd0:  buffer_wdata3_buf <= {80'h0, buffer_wdata3_temp[39:0]};
            4'd1:  buffer_wdata3_buf <= {72'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[7:0]};
            4'd2:  buffer_wdata3_buf <= {64'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[15:0]};
            4'd3:  buffer_wdata3_buf <= {56'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[23:0]};
            4'd4:  buffer_wdata3_buf <= {48'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[31:0]};
            4'd5:  buffer_wdata3_buf <= {40'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[39:0]};
            4'd6:  buffer_wdata3_buf <= {32'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[47:0]};
            4'd7:  buffer_wdata3_buf <= {24'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[55:0]};
            4'd8:  buffer_wdata3_buf <= {16'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[63:0]};
            4'd9:  buffer_wdata3_buf <= { 8'h0, buffer_wdata3_temp[39:0], buffer_wdata3_buf[71:0]};
            4'd10: buffer_wdata3_buf <= {       buffer_wdata3_temp[39:0], buffer_wdata3_buf[79:0]};
            4'd11: buffer_wdata3_buf <= {       buffer_wdata3_temp[31:0], buffer_wdata3_buf[87:0]};
            4'd12: buffer_wdata3_buf <= {112'h0, buffer_wdata3_temp[39:32]};
            4'd13: buffer_wdata3_buf <= {104'h0, buffer_wdata3_temp[39:24]};
            4'd14: buffer_wdata3_buf <= { 96'h0, buffer_wdata3_temp[39:16]};
            4'd15: buffer_wdata3_buf <= { 88'h0, buffer_wdata3_temp[39:8]};
            default: buffer_wdata3_buf <= buffer_wdata3_buf;
        endcase
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        buffer_wdata3 <= 128'h0;
    end else if(calc_trans_en) begin
        buffer_wdata3 <= 128'h0;
    end else if(write_buffer_done && (|data_load_offset[3:0]) && tile_right_edge) begin
        buffer_wdata3 <= {8'h0, buffer_wdata3_buf};
    end else if(data_load_en && sw_bitdepth == 2'd0 && (data_load_offset[3:0] == 4'd12)) begin
        buffer_wdata3 <= {buffer_wdata3_temp[31:0], buffer_wdata3_buf[95:0]};
    end else if(data_load_en && sw_bitdepth == 2'd1) begin
        case(data_load_offset[3:0])
            4'd11: buffer_wdata3 <= {buffer_wdata3_temp[39:0], buffer_wdata3_buf[87:0]};
            4'd12: buffer_wdata3 <= {buffer_wdata3_temp[31:0], buffer_wdata3_buf[95:0]};
            4'd13: buffer_wdata3 <= {buffer_wdata3_temp[23:0], buffer_wdata3_buf[103:0]};
            4'd14: buffer_wdata3 <= {buffer_wdata3_temp[15:0], buffer_wdata3_buf[111:0]};
            4'd15: buffer_wdata3 <= {buffer_wdata3_temp[7:0],  buffer_wdata3_buf[119:0]};
            default: buffer_wdata3 <= buffer_wdata3;
        endcase
    end
end

assign buffer_data_fifo_wr = buffer_wr;   //凑满16B时，写；或者在tile的右侧
assign buffer_data_fifo_wdata0 = {buffer_wr_last, data_strb, buffer_wdata0}; //写入的数据结构最后一个数据标志 选通信号 写数据
assign buffer_data_fifo_wdata1 = {buffer_wr_last, data_strb, buffer_wdata1};
assign buffer_data_fifo_wdata2 = {buffer_wr_last, data_strb, buffer_wdata2};
assign buffer_data_fifo_wdata3 = {buffer_wr_last, data_strb, buffer_wdata3};

assign buffer_data_fifo_rd0 = pp_trans_send_w_vld && pp_trans_send_w_rdy && (read_line_cnt == 2'd0); //从fifo读使能信号，4个fifo轮流都
assign buffer_data_fifo_rd1 = pp_trans_send_w_vld && pp_trans_send_w_rdy && (read_line_cnt == 2'd1);
assign buffer_data_fifo_rd2 = pp_trans_send_w_vld && pp_trans_send_w_rdy && (read_line_cnt == 2'd2);
assign buffer_data_fifo_rd3 = pp_trans_send_w_vld && pp_trans_send_w_rdy && (read_line_cnt == 2'd3);

g2_fifo_rb #(.FIFO_DATA_WIDTH(145),.FIFO_DEPTH(14)) u_buffer_data_fifo0(
.clk              (clk),
.resetn           (rst_n),
.fifo_synch_reset (sw_dec_en),
.fifo_write_e_lz  (buffer_data_fifo_wr) ,
.fifo_write_data  (buffer_data_fifo_wdata0),
.fifo_read_e_lz   (buffer_data_fifo_rd0),
.fifo_validread_am (),
.fifo_validwrite_vz(),
.fifo_validread_vz (),
.fifo_read_data   (buffer_data_fifo_rdata0));

g2_fifo_rb #(.FIFO_DATA_WIDTH(145),.FIFO_DEPTH(14)) u_buffer_data_fifo1(
.clk              (clk),
.resetn           (rst_n),
.fifo_synch_reset (sw_dec_en),
.fifo_write_e_lz  (buffer_data_fifo_wr) ,
.fifo_write_data  (buffer_data_fifo_wdata1),
.fifo_read_e_lz   (buffer_data_fifo_rd1),
.fifo_validread_am (),
.fifo_validwrite_vz(),
.fifo_validread_vz (),
.fifo_read_data   (buffer_data_fifo_rdata1));

g2_fifo_rb #(.FIFO_DATA_WIDTH(145),.FIFO_DEPTH(14)) u_buffer_data_fifo2(
.clk              (clk),
.resetn           (rst_n),
.fifo_synch_reset (sw_dec_en),
.fifo_write_e_lz  (buffer_data_fifo_wr) ,
.fifo_write_data  (buffer_data_fifo_wdata2),
.fifo_read_e_lz   (buffer_data_fifo_rd2),
.fifo_validread_am (),
.fifo_validwrite_vz(),
.fifo_validread_vz (),
.fifo_read_data   (buffer_data_fifo_rdata2));

g2_fifo_rb #(.FIFO_DATA_WIDTH(145),.FIFO_DEPTH(14)) u_buffer_data_fifo3(
.clk              (clk),
.resetn           (rst_n),
.fifo_synch_reset (sw_dec_en),
.fifo_write_e_lz  (buffer_data_fifo_wr) ,
.fifo_write_data  (buffer_data_fifo_wdata3),
.fifo_read_e_lz   (buffer_data_fifo_rd3),
.fifo_validread_am (),
.fifo_validwrite_vz(),
.fifo_validread_vz (),
.fifo_read_data   (buffer_data_fifo_rdata3));

/****************************/

//assign is_chroma = (block_type == 2'd1);
//assign address_base = is_chroma ? {sw_c_base_haddr, sw_c_base_laddr} : {sw_y_base_haddr, sw_y_base_laddr};
//assign line_stride = is_chroma ? sw_c_line_stride : sw_y_line_stride;

always @(posedge clk) begin
    if(!rst_n) begin
        is_chroma <= 1'b0;
        address_base <= {(PP2SRV_AWADDR_WIDTH){1'b0}};
        line_stride <= 16'h0;
    end else if(read_ctrl_en) begin
        is_chroma <= (block_type == 2'd1) || (block_type == 2'd2);   //判断是不是uv数据
        address_base <= (block_type == 2'd2) ?                       //根据block类型，选择不同的DDR起始地址
        {sw_c1_base_haddr, sw_c1_base_laddr} : (block_type == 2'd1) ?
        {sw_c0_base_haddr, sw_c0_base_laddr} : {sw_y_base_haddr, sw_y_base_laddr};
        line_stride <= (block_type == 2'd0) ? sw_y_line_stride : sw_c_line_stride;  // 每一行数据在DDR中的跨度（stride）
    end
end

assign block_pixel_width_x4 = {block_pixel_width, 2'h0};
assign block_pixel_width_x5 = block_pixel_width_x4 + block_pixel_width;



assign block_pixel_height_div4 = block_pixel_height[6:2]; //高度方向有多少个4x4块
//blovk_line_16bytes_calc表示每行有多少个16byte，10bit时每5个像素10byte，每8个像素16byte；8bit时每4个像素16byte
assign final_data_amount_calc = {3'b0, block_line_16bytes_calc[3:0], 4'h0};//相当于x16,也即是有多少bytes
assign trans_slot_number_calc = block_pixel_height_div4;//等下看具体作用

//assign max_burst_bytes = (sw_bitdepth == 2'b0) ? 11'd256 : 11'd240;

//assign block_start_x_x4 = {block_start_x, 2'h0};
//assign block_start_x_x5 = block_start_x_x4 + block_start_x;
input sw_org_x;
input sw_org_y;
assign block_start_x_8bit = block_start_x;
assign block_start_x_10bit = block_start_x + block_start_x_div4;

assign block_start_x_use = (sw_bitdepth == 2'b0) ? {1'b0, block_start_x_8bit} : block_start_x_10bit;
assign block_start_x_align16 = {block_start_x_use[13:4], 4'h0};
assign sw_org_x_x4 = {sw_org_x, 2'h0};
assign sw_org_x_x5 = sw_org_x_x4 + sw_org_x;
assign block_start_x_address = {2'h0, block_start_x_align16};//block在tile中的起点，对齐到16Byte
assign sw_org_x_address = (sw_bitdepth == 2'b0) ? {1'h0, sw_org_x_x4} : sw_org_x_x5; //原图起始x偏移（byte单位）
//addr = base + y * stride + x
always @(posedge clk) begin
    if(!rst_n) begin
        start_x_address <= 16'h0;
        start_y_address <= 32'h0;
    end else if(calc_trans_en) begin
        start_x_address <= sw_org_x_address + block_start_x_address;
        start_y_address <= (block_start_y + (sw_org_y >> is_chroma)) * line_stride;
    end
end
//当前block在ddr中的起始地址，等下算burst用
assign block_start_address_calc = start_x_address + start_y_address;

//treu_l有33位，true_h有32位，address_offset有32位，address_base有64位，所以这里要分开算，防止溢出  可以直接相加，结构优化
assign true_address_l = address_base[31:0] + address_offset;
assign true_address_h = address_base[63:32] + true_address_l[32];

assign true_address = {true_address_h[31:0], true_address_l[31:0]};
assign pp_trans_send_aw_addr = true_address;
always @(posedge clk) begin
    if(!rst_n) begin
        final_data_amount <= 11'h0;   //本次要传多少字节
        trans_slot_number <= 5'h0;    //分成多少个burst传输
        //block_start_address <= {(PP2SRV_AWADDR_WIDTH){1'b0}};
    end else if(!sw_dec_en) begin   //没使能，清零
        final_data_amount <= 11'h0;
        trans_slot_number <= 5'h0;
        //block_start_address <= {(PP2SRV_AWADDR_WIDTH){1'b0}};
    end else if(ctrl_update_en) begin  //参数更新，清除配置
        final_data_amount <= 11'h0;
        trans_slot_number <= 5'h0;
        //block_start_address <= {(PP2SRV_AWADDR_WIDTH){1'b0}};
    end else if(calc_trans_en) begin  //计算传输参数  final_data_amount每行的4x4需要传输多少次
        final_data_amount <= final_data_amount_calc;
        trans_slot_number <= trans_slot_number_calc; //trans_slot_number需要传输多少次final_data_amount才能把整个block传输完
        //block_start_address <= block_start_address_calc;
    end
end
//address_offset  block在DDR中的起点
always @(posedge clk) begin
    if(!rst_n) begin
        address_offset <= {(32){1'b0}};
    end else if(ctrl_update_en) begin
        address_offset <= {(32){1'b0}};
    end else if(calc_burst_en && (block_line_cnt == 5'd0)) begin
        address_offset <= block_start_address_calc;
    end else if(pp_trans_send_aw_vld && pp_trans_send_aw_rdy) begin  //每发一次aw地址，就加一次stride
        address_offset <= address_offset + line_stride;
    end
end


always @(posedge clk) begin
    if(!rst_n) begin
        read_line_cnt <= 2'b0;
    end else if(pp_trans_send_w_vld && pp_trans_send_w_rdy && pp_trans_send_w_last) begin   //每发完一行的最后一个数据 +1
        read_line_cnt <= read_line_cnt + 2'b1;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        block_line_cnt <= 5'h0;
    end else if(ctrl_update_en) begin
        block_line_cnt <= 5'h0;
    end else if(pp_trans_send_w_vld && pp_trans_send_w_rdy && pp_trans_send_w_last && (read_line_cnt == 2'd3)) begin  //每写完4行数据 +1
        block_line_cnt <= block_line_cnt + 1'b1;
    end
end

assign trans_slot_number_m1 = trans_slot_number - 1'b1;
assign block_done = (block_line_cnt == trans_slot_number_m1);  //当前block传输完成

assign trans_send_idle = (qstate == IDLE);

reg  frame_data_send_done_flag_d0;
reg  frame_data_send_done_flag_d1;
reg  frame_data_send_done_flag_d2;
reg  frame_data_send_done_flag_d3;

always @(posedge clk) begin
    if(!rst_n) begin
        frame_data_send_done_flag_d0 <= 1'b0;
    end else if(!sw_dec_en) begin
        frame_data_send_done_flag_d0 <= 1'b0;
    end else if(block_finish && picture_ready) begin
        frame_data_send_done_flag_d0 <= 1'b1;
    end else if(qstate == IDLE && pp_interleave_ctrl_in_vld) begin
        frame_data_send_done_flag_d0 <= 1'b0;
    end
end

always @(posedge clk) begin
    if(!rst_n) begin
        frame_data_send_done_flag_d1 <= 1'b0;
        frame_data_send_done_flag_d2 <= 1'b0;
        frame_data_send_done_flag_d3 <= 1'b0;
    end else begin
        frame_data_send_done_flag_d1 <= frame_data_send_done_flag_d0;
        frame_data_send_done_flag_d2 <= frame_data_send_done_flag_d1;
        frame_data_send_done_flag_d3 <= frame_data_send_done_flag_d2;
    end
end
//延迟4拍
assign frame_data_send_done_flag = frame_data_send_done_flag_d3;

ram_rws_136x120 u_left_data_sram_lu(
.clk           (clk),
.rst_n         (rst_n),
.ra            (left_data_sram_lu_raddr[7:0]),
.re            (left_data_sram_lu_ren),
.dout          (left_data_sram_lu_rdata[119:0]),
.wa            (left_data_sram_lu_waddr[7:0]),
.we            (left_data_sram_lu_wen),
.di            (left_data_sram_lu_wdata[119:0]),
.pwrbus_ram_pd (pwrbus_ram_pd)
);

ram_rws_72x120 u_left_data_sram_ch0(
.clk           (clk),
.rst_n         (rst_n),
.ra            (left_data_sram_ch0_raddr[6:0]),
.re            (left_data_sram_ch0_ren),
.dout          (left_data_sram_ch0_rdata[119:0]),
.wa            (left_data_sram_ch0_waddr[6:0]),
.we            (left_data_sram_ch0_wen),
.di            (left_data_sram_ch0_wdata[119:0]),
.pwrbus_ram_pd (pwrbus_ram_pd)
);

ram_rws_72x120 u_left_data_sram_ch1(
.clk           (clk),
.rst_n         (rst_n),
.ra            (left_data_sram_ch1_raddr[6:0]),
.re            (left_data_sram_ch1_ren),
.dout          (left_data_sram_ch1_rdata[119:0]),
.wa            (left_data_sram_ch1_waddr[6:0]),
.we            (left_data_sram_ch1_wen),
.di            (left_data_sram_ch1_wdata[119:0]),
.pwrbus_ram_pd (pwrbus_ram_pd)
);

endmodule
//Local Variable:
//verilog-library-directories:()
//verilog-library-extensions:()
//End:
///* AUTO_LISP(setq verilog-auto-output-ignore-regexp
//      (verilog-regexp-words `(
//  )))*/

