`timescale 1ns/1ps

// Lanczos4 coefficient ROM.
//
// phase_q9 uses 1/512 precision:
//   phase = phase_q9 / 512.0
//
// Coefficients use signed Q2.14:
//   real_coef = coef / 16384.0
//
// Tap order must match the 64-tap window order used by downscale_block_buffer:
//   coef0 -> offset -3
//   coef1 -> offset -2
//   coef2 -> offset -1
//   coef3 -> offset  0
//   coef4 -> offset +1
//   coef5 -> offset +2
//   coef6 -> offset +3
//   coef7 -> offset +4

module pp_downscale_lanczos4_coef_rom (
    input  wire [8:0] phase_q9,

    output reg signed [15:0] coef0,
    output reg signed [15:0] coef1,
    output reg signed [15:0] coef2,
    output reg signed [15:0] coef3,
    output reg signed [15:0] coef4,
    output reg signed [15:0] coef5,
    output reg signed [15:0] coef6,
    output reg signed [15:0] coef7
);

always @(*) begin
    case (phase_q9)
`include "pp_downscale_lanczos4_coef_rom_table.vh"
        default: begin
            // Safety default for unreachable phase values.
            coef0 = 16'sd0;
            coef1 = 16'sd0;
            coef2 = 16'sd0;
            coef3 = 16'sd16384;
            coef4 = 16'sd0;
            coef5 = 16'sd0;
            coef6 = 16'sd0;
            coef7 = 16'sd0;
        end
    endcase
end

endmodule
