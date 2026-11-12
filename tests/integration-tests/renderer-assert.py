#!/usr/bin/env python3
"""Assertions for the OpenCode renderer tests; standard library only."""

import json
import struct
import sys
import zlib
from pathlib import Path


def check(condition, message):
    if not condition:
        raise ValueError(message)


def make_code(mode, root, marker):
    if mode == "execute":
        code = f"print({marker!r})\n"
    else:
        image = str(root / "render.png")
        code = (
            "from paraview.simple import *\n"
            "sphere = Sphere()\n"
            "view = GetActiveViewOrCreate('RenderView')\n"
            "view.ViewSize = [256, 256]\n"
            "view.UseColorPaletteForBackground = 0\n"
            "view.Background = [0.05, 0.05, 0.05]\n"
            "display = Show(sphere, view)\n"
            "display.DiffuseColor = [0.9, 0.25, 0.1]\n"
            "view.ResetCamera()\n"
            "Render(view)\n"
            f"SaveScreenshot({image!r}, view, ImageResolution=[256, 256])\n"
            f"print({marker!r})\n"
        )
    (root / "code.py").write_text(code)


def tool_output_text(state):
    """Join the V2 tool-state text chunks into one output string."""
    chunks = state.get("content")
    check(isinstance(chunks, list), "Tool state carries no content chunks")
    return "".join(
        item.get("text", "")
        for item in chunks
        if isinstance(item, dict) and item.get("type") == "text"
    )


def unwrap(value):
    if isinstance(value, str):
        value = json.loads(value)
    check(isinstance(value, dict), "Tool output is not a JSON object")
    if "returncode" in value:
        return value
    check(not value.get("isError", False), "MCP result reports isError")
    if isinstance(value.get("structuredContent"), dict):
        return unwrap(value["structuredContent"])
    for item in value.get("content", []):
        if item.get("type") == "text":
            try:
                return unwrap(item["text"])
            except (ValueError, TypeError):
                continue
    raise ValueError("Cannot find renderer JSON result in tool output")


def validate_png(path):
    data = path.read_bytes()
    check(data[:8] == b"\x89PNG\r\n\x1a\n", "Invalid PNG signature")
    offset = 8
    compressed = bytearray()
    header = None
    ended = False
    while offset < len(data):
        check(offset + 12 <= len(data), "Truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4 : offset + 8]
        end = offset + 8 + size
        check(end + 4 <= len(data), "Truncated PNG payload")
        body = data[offset + 8 : end]
        crc = struct.unpack_from(">I", data, end)[0]
        check(zlib.crc32(kind + body) & 0xFFFFFFFF == crc, "PNG CRC mismatch")
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed.extend(body)
        elif kind == b"IEND":
            ended = True
            break
        offset = end + 4
    check(ended and header is not None, "Missing PNG header/end")
    width, height, depth, color, compression, filtering, interlace = header
    check((width, height) == (256, 256), "Unexpected image dimensions")
    check(
        depth == 8 and color in (2, 6) and interlace == 0,
        "Expected noninterlaced 8-bit RGB/RGBA PNG",
    )
    check(compression == 0 and filtering == 0, "Unsupported PNG encoding")
    channels = 3 if color == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    check(len(raw) == height * (stride + 1), "Invalid decoded PNG length")
    previous = bytearray(stride)
    colors = set()
    for y in range(height):
        base = y * (stride + 1)
        filter_type = raw[base]
        row = bytearray(raw[base + 1 : base + 1 + stride])
        check(filter_type in range(5), "Invalid PNG row filter")
        for i in range(stride):
            a = row[i - channels] if i >= channels else 0
            b = previous[i]
            c = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                predictor = a
            elif filter_type == 2:
                predictor = b
            elif filter_type == 3:
                predictor = (a + b) // 2
            elif filter_type == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else b if pb <= pc else c
            else:
                predictor = 0
            row[i] = (row[i] + predictor) & 255
        colors.update(bytes(row[x : x + 3]) for x in range(0, stride, channels))
        previous = row
    check(
        len(colors) > 16, "Image is solid or has insufficient pixel variation"
    )
    (path.parent / "image-validation.json").write_text(
        json.dumps(
            {
                "width": width,
                "height": height,
                "distinct_rgb_colors": len(colors),
                "crc_valid": True,
                "decoded": True,
            },
            indent=2,
        )
        + "\n"
    )


def validate_result(mode, root, marker):
    tools = json.loads((root / "tool-parts.json").read_text())
    check(len(tools) == 1, "Expected exactly one tool call")
    part = tools[0]
    check(
        part.get("name") == "pvpython_renderer_execute_code", "Unexpected tool"
    )
    state = part["state"]
    check(state.get("status") == "completed", "Tool did not complete")
    check(
        isinstance(state.get("input", {}).get("code"), str)
        and state["input"]["code"].rstrip("\r\n")
        == (root / "code.py").read_text().rstrip("\r\n"),
        "Model changed the supplied code; input contract not met",
    )
    result = unwrap(tool_output_text(state))
    (root / "renderer-result.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    required = {
        "returncode",
        "runner_stdout",
        "runner_stderr",
        "pvserver_stdout",
        "pvserver_stderr",
    }
    check(required <= result.keys(), "Missing renderer result fields")
    check(
        type(result["returncode"]) is int and result["returncode"] == 0,
        "Renderer returned a nonzero or invalid exit code",
    )
    for key in required - {"returncode"}:
        check(isinstance(result[key], str), f"Invalid {key}")
    check(
        marker in result["runner_stdout"],
        "Missing marker in actual runner stdout",
    )
    check(
        "Traceback (most recent call last)" not in result["runner_stderr"],
        "Runner stderr contains a traceback",
    )
    if mode == "render":
        validate_png(root / "render.png")


def main():
    action, mode, directory, marker = sys.argv[1:]
    root = Path(directory)
    if action == "make-code":
        make_code(mode, root, marker)
    elif action == "result":
        validate_result(mode, root, marker)
    else:
        raise ValueError("Unknown action")


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        KeyError,
        TypeError,
        OSError,
        zlib.error,
        struct.error,
    ) as exc:
        print(f"ASSERTION FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
