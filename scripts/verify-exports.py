#!/usr/bin/env python3
"""Validate file depth, exact linear highlights, and PNG metadata independently."""
import json
import struct
import subprocess

subprocess.run(["./zig-out/bin/bSim", "validate-export"], check=True)
raw = subprocess.check_output([
    "ffmpeg", "-v", "error", "-i", "renders/export-check.exr",
    "-f", "rawvideo", "-pix_fmt", "gbrpf16le", "-",
])
values = struct.unpack("<" + str(len(raw) // 2) + "e", raw)
assert len(values) == 16 * 16 * 3
for index, expected in enumerate((2.0, 0.5, 4.0)):
    assert all(value == expected for value in values[index * 256:(index + 1) * 256])
info = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-show_entries", "stream=width,height,pix_fmt",
    "-of", "json", "renders/export-check.png",
]))["streams"][0]
assert info["pix_fmt"] == "rgba64be" and info["width"] == info["height"] == 16
print("Export checks passed: half-float highlights and 16-bit PNG depth")
