"""Generate the printable ChArUco marker board left on set for scale and alignment.

The board is 5 x 7 squares of 35 mm (175 x 245 mm), centred on A4 portrait.
Print at 100% scale ("actual size") and check the ruler with a tape measure.

Usage: python make_marker_board.py out.pdf
"""
import sys

import cv2
from PIL import Image, ImageDraw, ImageFont

DPI = 300
MM = DPI / 25.4
SQUARES_X, SQUARES_Y = 5, 7
SQUARE_MM, MARKER_MM = 35, 26
DICTIONARY = cv2.aruco.DICT_4X4_50
A4_MM = (210, 297)


def px(mm):
    return round(mm * MM)


def main(out_path):
    board = cv2.aruco.CharucoBoard(
        (SQUARES_X, SQUARES_Y),
        SQUARE_MM / 1000,
        MARKER_MM / 1000,
        cv2.aruco.getPredefinedDictionary(DICTIONARY),
    )
    board_px = (px(SQUARES_X * SQUARE_MM), px(SQUARES_Y * SQUARE_MM))
    board_img = board.generateImage(board_px, marginSize=0, borderBits=1)

    page = Image.new("L", (px(A4_MM[0]), px(A4_MM[1])), 255)
    left = (page.width - board_px[0]) // 2
    top = px(16)
    page.paste(Image.fromarray(board_img), (left, top))

    draw = ImageDraw.Draw(page)
    # 100 mm ruler under the board, to check the print scale.
    y = top + board_px[1] + px(8)
    draw.line([(left, y), (left + px(100), y)], fill=0, width=4)
    for mm in range(0, 101, 10):
        draw.line([(left + px(mm), y - px(3)), (left + px(mm), y)], fill=0, width=3)
    font = ImageFont.load_default(size=px(3.5))
    notes = [
        f"Ruler 100 mm, squares {SQUARE_MM} mm (ChArUco {SQUARES_X}x{SQUARES_Y}, DICT_4X4_50).",
        "Print at 100% scale and check the ruler. Keep flat (tape to card).",
        "Leave in the same place, out of the film shot, visible in every capture.",
    ]
    for i, line in enumerate(notes):
        draw.text((left, y + px(4) + i * px(5.5)), line, fill=0, font=font)
    page.save(out_path, resolution=DPI)


if __name__ == "__main__":
    main(sys.argv[1])
