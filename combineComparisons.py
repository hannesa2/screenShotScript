#!/usr/bin/env python3
"""Combines collected screenshot panels into horizontal comparison images."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw


def combine_comparisons(directory):
    directory = Path(directory)
    suffixes = ("expected", "diff", "actual")
    names = sorted(
        {
            path.stem.rsplit("-", 1)[0]
            for suffix in suffixes
            for path in directory.glob(f"*-{suffix}.png")
        }
    )
    for name in names:
        panels = []
        sources = []
        for suffix in suffixes:
            path = directory / f"{name}-{suffix}.png"
            if path.exists():
                with Image.open(path) as image:
                    panels.append(image.convert("RGBA"))
                sources.append(path)
            else:
                panels.append(None)

        width = max(panel.width for panel in panels if panel is not None)
        height = max(panel.height for panel in panels if panel is not None)
        comparison = Image.new(
            "RGB",
            (sum(panel.width if panel is not None else width for panel in panels), height),
            "white",
        )
        x = 0
        for suffix, panel in zip(suffixes, panels):
            if panel is None:
                ImageDraw.Draw(comparison).text(
                    (x + 8, 8), f"{suffix.capitalize()} unavailable", fill="black"
                )
                x += width
            else:
                comparison.paste(panel, (x, 0), panel)
                x += panel.width
        comparison.save(directory / f"{name}.png")
        for path in sources:
            path.unlink()


if __name__ == "__main__":
    combine_comparisons(sys.argv[1])
