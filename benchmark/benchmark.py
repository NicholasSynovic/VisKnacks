"""Benchmarking script for SciVisAgent outputs.

Compares an input file against a ground truth file and emits JSON results
to stdout by default, or to a file when --output is given.
"""

import argparse
import json
import math
import sys
from pathlib import Path

import imageio.v3 as iio
import numpy as np
from skimage.metrics import (
    peak_signal_noise_ratio,
    structural_similarity,
)

METRIC_CHOICES = ("psnr", "ssim")
DATA_RANGE = 255


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark an input file against a ground truth file.",
    )

    io_group = parser.add_argument_group("input/output")
    io_group.add_argument(
        "--input",
        required=True,
        type=Path,
        metavar="PATH",
        help="Path to the input file to evaluate",
    )
    io_group.add_argument(
        "--ground-truth",
        required=True,
        type=Path,
        metavar="PATH",
        help="Path to the ground truth file",
    )
    io_group.add_argument(
        "--output",
        type=Path,
        metavar="PATH",
        help="Write JSON results to this file (default: stdout)",
    )

    return parser.parse_args(argv)


def load_image(path: Path) -> np.ndarray:
    return np.asarray(iio.imread(path))


def compute_psnr(image: np.ndarray, ground_truth: np.ndarray) -> float:
    # Identical images give an infinite PSNR via a divide-by-zero; silence the
    # warning here and let the caller map the result to None.
    with np.errstate(divide="ignore"):
        return float(
            peak_signal_noise_ratio(
                ground_truth,
                image,
                data_range=DATA_RANGE,
            )
        )


def compute_ssim(image: np.ndarray, ground_truth: np.ndarray) -> float:
    channel_axis = -1 if ground_truth.ndim == 3 else None
    return float(
        structural_similarity(
            ground_truth,
            image,
            data_range=DATA_RANGE,
            channel_axis=channel_axis,
        )
    )


def _finite_or_none(value: float) -> float | None:
    """Map non-finite metrics (e.g. infinite PSNR) to None for valid JSON."""
    return value if math.isfinite(value) else None


def build_results(
    input_path: Path,
    ground_truth_path: Path,
    image: np.ndarray,
    ground_truth: np.ndarray,
) -> dict:
    computed: dict[str, float | None] = {}
    computed["psnr"] = _finite_or_none(compute_psnr(image, ground_truth))
    computed["ssim"] = _finite_or_none(compute_ssim(image, ground_truth))

    return {
        "input": str(input_path),
        "ground_truth": str(ground_truth_path),
        "results": computed,
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    for label, path in (
        ("input", args.input),
        ("ground-truth", args.ground_truth),
    ):
        if not path.is_file():
            print(
                f"error: {label} file does not exist: {path}",
                file=sys.stderr,
            )
            return 1

    try:
        image = load_image(args.input)
        ground_truth = load_image(args.ground_truth)
    except (OSError, ValueError) as exc:
        print(f"error: failed to read image: {exc}", file=sys.stderr)
        return 1

    if image.shape != ground_truth.shape:
        print(
            "error: image shape mismatch: "
            f"input {image.shape} != ground truth {ground_truth.shape}",
            file=sys.stderr,
        )
        return 1

    results = build_results(
        args.input,
        args.ground_truth,
        image,
        ground_truth,
    )
    payload = json.dumps(results, indent=4, allow_nan=False)

    if args.output is not None:
        args.output.write_text(payload)
    else:
        print(payload)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
