#!/usr/bin/env python3
"""
Generate the deterministic 2x downscale reference matrix used by
tb_downscale_image_ref.v.

This script intentionally mirrors the current RTL testbench:
  - source image: 64x64, 10-bit deterministic function
  - destination image: 32x32
  - scale_q8 = 512
  - phase precision: Q9, 1/512
  - coefficient format: signed Q2.14
  - tap order: -3, -2, -1, 0, +1, +2, +3, +4
  - rounding: add 1<<27, then arithmetic shift right 28

Run:
  python gen_downscale_2x_ref_matrix.py

Optional:
  python gen_downscale_2x_ref_matrix.py > ref_matrix.txt
"""

from __future__ import annotations

import re
from pathlib import Path


SRC_W = 64
SRC_H = 64
DST_W = 32
DST_H = 32
PIXEL_MAX = 1023
SCALE_Q8 = 512
COEF_TABLE = Path(__file__).with_name("pp_downscale_lanczos4_coef_rom_table.vh")
TAP_OFFSETS = [-3, -2, -1, 0, 1, 2, 3, 4]


def clip(value: int, lo: int, hi: int) -> int:
    if value < lo:
        return lo
    if value > hi:
        return hi
    return value


def source_pixel(x: int, y: int) -> int:
    """Same deterministic 10-bit source image as tb_downscale_image_ref.v."""
    value = (x * 17) + (y * 29) + (x * y * 3) + ((x ^ y) * 5) + 37
    return value & PIXEL_MAX


def parse_verilog_signed_decimal(text: str) -> int:
    """Parse forms like 16'sd123 and -16'sd123."""
    text = text.strip().rstrip(";")
    match = re.fullmatch(r"(-)?\s*16'sd(\d+)", text)
    if not match:
        raise ValueError(f"Unsupported coefficient literal: {text}")
    sign = -1 if match.group(1) else 1
    return sign * int(match.group(2))


def load_coef_table(path: Path) -> list[list[int]]:
    """Return coef[phase][tap] from the generated Verilog include file."""
    table: list[list[int] | None] = [None] * 512
    phase: int | None = None
    cur = [0] * 8

    phase_re = re.compile(r"\s*9'd(\d+):\s*begin")
    coef_re = re.compile(r"\s*coef([0-7])\s*=\s*([^;]+);")

    for line in path.read_text(encoding="utf-8").splitlines():
        phase_match = phase_re.match(line)
        if phase_match:
            phase = int(phase_match.group(1))
            cur = [0] * 8
            continue

        coef_match = coef_re.match(line)
        if coef_match and phase is not None:
            idx = int(coef_match.group(1))
            cur[idx] = parse_verilog_signed_decimal(coef_match.group(2))
            continue

        if phase is not None and line.strip() == "end":
            table[phase] = cur[:]
            phase = None

    missing = [idx for idx, item in enumerate(table) if item is None]
    if missing:
        raise RuntimeError(f"Missing coefficient phases: {missing[:8]}")

    return [item for item in table if item is not None]


def src_coord_q9(dst: int) -> int:
    # RTL formula: src_q9 = scale_q8 * (2*dst + 1) - 256
    return SCALE_Q8 * ((2 * dst) + 1) - 256


def lanczos4_pixel(dst_x: int, dst_y: int, coef_table: list[list[int]]) -> int:
    src_x_q9 = src_coord_q9(dst_x)
    src_y_q9 = src_coord_q9(dst_y)

    center_x = src_x_q9 >> 9
    center_y = src_y_q9 >> 9
    phase_x = src_x_q9 & 0x1FF
    phase_y = src_y_q9 & 0x1FF

    coef_x = coef_table[phase_x]
    coef_y = coef_table[phase_y]

    h_sum: list[int] = []
    for row_idx, y_off in enumerate(TAP_OFFSETS):
        src_y = clip(center_y + y_off, 0, SRC_H - 1)
        row_sum = 0
        for col_idx, x_off in enumerate(TAP_OFFSETS):
            src_x = clip(center_x + x_off, 0, SRC_W - 1)
            row_sum += source_pixel(src_x, src_y) * coef_x[col_idx]
        h_sum.append(row_sum)

    v_sum = 0
    for row_idx in range(8):
        v_sum += h_sum[row_idx] * coef_y[row_idx]

    rounded_int = (v_sum + (1 << 27)) >> 28
    return clip(rounded_int, 0, PIXEL_MAX)


def main() -> None:
    coef_table = load_coef_table(COEF_TABLE)
    matrix = [
        [lanczos4_pixel(x, y, coef_table) for x in range(DST_W)]
        for y in range(DST_H)
    ]

    print("PY_REF_DOWNSCALE_IMAGE_BEGIN")
    for y, row in enumerate(matrix):
        values = " ".join(str(pixel) for pixel in row)
        print(f"DST_ROW {y:02d}: {values}")
    print("PY_REF_DOWNSCALE_IMAGE_END")


if __name__ == "__main__":
    main()
