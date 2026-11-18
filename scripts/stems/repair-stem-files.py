#!/usr/bin/env python3
"""Make STEM files exported before 2026-10-28 readable by Mixxx 2.6.

AVAssetWriter wrote `mdat` with a 64-bit size, which Mixxx misreads, so it
never found the stem manifest. This rewrites that 16-byte header in place as
an 8-byte `free` box plus a 32-bit `mdat` header (what StemFile.swift now
writes). Nothing else in the file changes.

  find ~/Downloads/Music -name "*.stem.mp4" -print0 | xargs -0 python3 repair-stem-files.py
"""
import os, struct, sys

for path in sys.argv[1:]:
    name = os.path.basename(path)
    with open(path, "r+b") as f:
        ftyp_size, ftyp = struct.unpack(">I4s", f.read(8))
        if ftyp != b"ftyp":
            print("skip (not MP4):", name); continue
        f.seek(ftyp_size)
        size, kind = struct.unpack(">I4s", f.read(8))
        if kind != b"mdat" or size != 1:
            print("ok already:", name); continue
        big, = struct.unpack(">Q", f.read(8))
        if big - 8 >= 2**32 or ftyp_size + big > os.path.getsize(path):
            print("skip (unexpected size):", name); continue
        f.seek(ftyp_size)
        f.write(struct.pack(">I4sI4s", 8, b"free", big - 8, b"mdat"))
        print("fixed:", name)
