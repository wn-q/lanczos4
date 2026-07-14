`ifndef CHIP_MEM_POWER_CTRL
    `define CHIP_MEM_POWER_CTRL 1
`endif

module ram_rws_64x128 (
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
input [5:0] ra;
input re;
output [127:0] dout;
input [5:0] wa;
input we;
input [127:0] di;
input [`CHIP_MEM_POWER_CTRL-1:0] pwrbus_ram_pd;

`ifndef USE_REAL_SRAM_CELL
reg [127:0] dout;
reg [127:0] M [63:0];

always @(posedge clk) begin
    if (we)
        M[wa] <= di;
end

always @(posedge clk) begin
    if (re)
        dout <= M[ra];
end

`else
codec_mem2p64x128ns u0_memview_sram (
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
    .test_expr(we && re && (wa == ra))
);
`endif

endmodule
