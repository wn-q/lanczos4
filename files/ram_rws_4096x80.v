`ifdef CHIP_MEM_POWER_CTRL
    `define CHIP_MEM_POWER_CTRL MEM_POWER_CTRL_BITS
`endif

module ram_rws_4096x80 (
    clk,
    rst_n,
    ra,
    re,
    dout,
    wa,
    we,
    di,
    pwrbus_ram_pd
);

parameter FORCE_CONTENTION_ASSERTION_RESET_ACTIVATE=1'b0;

input clk;
input rst_n;
input [11:0] ra;
input re;
output [79:0] dout;
input [11:0] wa;
input we;
input [79:0] di;
input [`CHIP_MEM_POWER_CTRL-1:0] pwrbus_ram_pd;
`ifndef USE_REAL_SRAM_CELL
reg [11:0] ra_d;
reg [79:0] dout;
reg [79:0] M [4095:0];  

always @(posedge clk) begin
    if(we)
        M[wa] <= di;   
end

always @(posedge clk) begin
    if(re)
        ra_d <= ra;
end

always @(posedge clk) begin
    if(re)
        dout <= M[ra];
end

`else
codec_mem2p4096x80ns u0_memview_sram (
    .CLKA(clk),
    .CLKB(clk),
    .RSTA(~rst_n),
    .RSTB(~rst_n),

    .MEA(we),
    .MEB(re),
    .WEA(we),
    .ADRA(wa),
    .ADRB(ra),
    .DA(di),
    .QB(dout),
    .MEM_POWER_CTRL(pwrbus_ram_pd)

);
`endif 
`ifndef VERIF_DEBUG_EN

assert_never usva_check_wr_rd_same_assert_never (
    .clk(clk),
    .reset(rst_n),
    .test_expr(we&&re&&(wa==ra))
);
`endif 
endmodule