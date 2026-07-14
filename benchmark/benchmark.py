"""Benchmarking script for SciVisAgent outputs.

Compares an input file against a ground truth file and emits JSON results
to stdout by default, or to a file when --output is given.
"""

import argparse
import json
import sys
from pathlib import Path


def parse_args(argv: list[str] | None = None) -> argparse.Namespace | bool:
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

    args: argparse.Namespace = parser.parse_args(argv)

    for label, path in (
        ("input", args.input),
        ("ground-truth", args.ground_truth),
    ):
        if not path.is_file():
            print(
                f"error: {label} file does not exist: {path}",
                file=sys.stderr,
            )
            return False

    return args


def build_results(input_path: Path, ground_truth_path: Path) -> dict:
    return {
        "input": str(input_path),
        "ground_truth": str(ground_truth_path),
        "results": {},
    }


def main(argv: list[str] | None = None) -> int:
    args: argparse.Namespace | bool = parse_args(argv)

    if args is False:
        return 1

    results: dict = build_results(args.input, args.ground_truth)
    payload: str = json.dumps(results, indent=4)

    if args.output is not None:
        args.output.write_text(payload)
    else:
        print(payload)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
