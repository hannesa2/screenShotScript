#!/usr/bin/env python3
"""Writes a diff image: the actual screenshot with changed pixels painted red."""
import sys

from PIL import Image, ImageChops

TOLERANCE = 8


def main(expected_path, actual_path, diff_path):
    with Image.open(expected_path) as expected, Image.open(actual_path) as actual:
        expected = expected.convert("RGB")
        actual = actual.convert("RGB")
        if expected.size != actual.size:
            comparison = Image.new(
                "RGB", (expected.width + actual.width, max(expected.height, actual.height)), "red"
            )
            comparison.paste(expected, (0, 0))
            comparison.paste(actual, (expected.width, 0))
            comparison.save(diff_path)
            return
        red, green, blue = ImageChops.difference(expected, actual).point(
            lambda value: 255 if value > TOLERANCE else 0
        ).split()
        mask = ImageChops.lighter(ImageChops.lighter(red, green), blue)
        Image.composite(Image.new("RGB", actual.size, (255, 0, 0)), actual, mask).save(diff_path)


if __name__ == "__main__":
    main(*sys.argv[1:4])
